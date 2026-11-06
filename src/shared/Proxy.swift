// 来源：AgentHUD 交互恢复版 Model.swift（Clash 代理读取）
import Foundation
struct ProxyInfo: Equatable {
    var name: String = "订阅"
    var upload: Double = 0
    var download: Double = 0
    var total: Double = 0
    var expire: Date? = nil
    var node: String = ""
    var group: String = ""
    var url: String = ""
    var updated: Date? = nil

    var used: Double { upload + download }
    var usedGB: Double { used / 1_073_741_824 }
    var totalGB: Double { total / 1_073_741_824 }
    var remainingGB: Double { max(0, total - used) / 1_073_741_824 }
    var remainingFraction: Double {
        guard total > 0 else { return 0 }
        return max(0, min(1, 1 - used / total))
    }
}

// MARK: - Clash 实时状态（通过 verge-mihomo 的 unix socket）

struct ProxyLive: Equatable {
    var mode: String = "rule"        // rule / global / direct
    var tun: Bool = false
    var systemProxy: Bool = false
    var node: String = ""
    var nodeType: String = ""
    var delay: Int? = nil
    var updated: Date = Date()
    var modeName: String {
        switch mode {
        case "global": return "全局"
        case "direct": return "直连"
        default: return "规则"
        }
    }
}

enum ClashAPI {
    static let sock = ProcessInfo.processInfo.environment["AGENTHUD_CLASH_SOCKET"] ?? "/tmp/verge/verge-mihomo.sock"

    static var secret: String {
        let p = NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n") where line.hasPrefix("secret:") {
            return String(line.dropFirst("secret:".count)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"\'"))
        }
        return ""
    }

    static func call(_ path: String, method: String = "GET", body: String? = nil) -> Data? {
        // 密钥经 stdin 的 curl 配置传入：放在命令行参数里，其他进程用 ps 就能看到。
        var args = ["-s", "--fail", "--unix-socket", sock, "-m", "2", "-K", "-"]
        if let body {
            args += ["-X", method, "-H", "Content-Type: application/json", "-d", body]
        } else if method != "GET" {
            args += ["-X", method]
        }
        args.append("http://localhost\(path)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        let out = Pipe(), input = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let quoted = secret.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try? input.fileHandleForWriting.write(contentsOf: Data("header = \"Authorization: Bearer \(quoted)\"\n".utf8))
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    static func setMode(_ mode: String) -> Bool {
        call("/configs", method: "PATCH", body: "{\"mode\":\"\(mode)\"}") != nil
    }

    /// groupName: profiles.yaml 里 selected.name，例如「自动选择」
    static func load(groupName: String) -> ProxyLive? {
        guard let cfgData = call("/configs"),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else { return nil }
        var live = ProxyLive()
        live.mode = (cfg["mode"] as? String) ?? "rule"
        if let tun = cfg["tun"] as? [String: Any] { live.tun = (tun["enable"] as? Bool) ?? false }

        // verge.yaml 里的系统代理开关
        let vp = NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge.yaml"
        if let text = try? String(contentsOfFile: vp, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("enable_system_proxy:") {
                live.systemProxy = line.contains("true")
            }
        }

        guard let pxData = call("/proxies"),
              let pxRoot = try? JSONSerialization.jsonObject(with: pxData) as? [String: Any],
              let proxies = pxRoot["proxies"] as? [String: Any] else { return live }

        let selectedGroup = live.mode == "global" ? "GLOBAL" : groupName
        let group = proxies[selectedGroup] as? [String: Any]
        let nodeName = (group?["now"] as? String) ?? selectedGroup
        live.node = nodeName
        if let n = proxies[nodeName] as? [String: Any] {
            live.nodeType = (n["type"] as? String) ?? ""
        }
        // 延迟探测
        if let enc = nodeName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))),
           let d = call("/proxies/\(enc)/delay?timeout=2500&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let ms = obj["delay"] as? Int {
            live.delay = ms
        }
        live.updated = Date()
        return live
    }
}

enum ProxyReader {
    static func load() -> ProxyInfo? {
        let path = NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles.yaml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var info = ProxyInfo()
        var current = ""
        var inItem = false
        var inExtra = false
        var gotExtra = false
        var gotNode = false
        var inSelected = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if inExtra && indent <= 2 && !t.isEmpty { inExtra = false }
            if t.hasPrefix("current:") {
                current = String(t.dropFirst("current:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if t.hasPrefix("- uid:") {
                let uid = String(t.dropFirst("- uid:".count)).trimmingCharacters(in: .whitespaces)
                inItem = (uid == current)
                inSelected = false
                inExtra = false
                continue
            }
            guard inItem else { continue }
            if t == "extra:" { inExtra = true; continue }
            if t == "selected:" { inExtra = false; inSelected = true; continue }
            func num(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }
            if inExtra {
                if t.hasPrefix("upload:") { info.upload = num(String(t.dropFirst(7))) ?? 0; gotExtra = true }
                else if t.hasPrefix("download:") { info.download = num(String(t.dropFirst(9))) ?? 0; gotExtra = true }
                else if t.hasPrefix("total:") { info.total = num(String(t.dropFirst(6))) ?? 0; gotExtra = true }
                else if t.hasPrefix("expire:") {
                    if let v = num(String(t.dropFirst(7))), v > 0 { info.expire = Date(timeIntervalSince1970: v) }
                }
            } else if t.hasPrefix("url:") && info.url.isEmpty {
                info.url = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("updated:") && info.updated == nil {
                if let v = Double(t.dropFirst(8).trimmingCharacters(in: .whitespaces)), v > 0 {
                    info.updated = Date(timeIntervalSince1970: v)
                }
            } else if t.hasPrefix("name:") && info.name == "订阅" {
                let n = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty && n != "null" { info.name = n }
            } else if inSelected && t.hasPrefix("name:") && info.group.isEmpty {
                info.group = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("now:") && !gotNode {
                let n = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty && n != "null" { info.node = n; gotNode = true }
            }
        }
        guard gotExtra, info.total > 0 else { return nil }
        return info
    }
}
