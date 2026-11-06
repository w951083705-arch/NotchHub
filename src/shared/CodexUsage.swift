// 来源：APIQuota 1.11.0 CodexUsage.swift（原样复用）
import Foundation

struct CodexWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var title: String {
        guard let minutes = windowDurationMins else { return "当前周期" }
        if minutes == 10080 { return "本周" }
        if minutes == 1440 { return "24 小时" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
    }
    var resetText: String {
        guard let resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: resetsAt)) + " 重置"
    }
    var expired: Bool { resetsAt.map { $0 <= Date().timeIntervalSince1970 } ?? false }
    var text: String { expired ? "待刷新" : String(format: "%.0f%%", remaining.rounded(.down)) }
}

struct CodexUsage: Codable {
    let windows: [CodexWindow]
    let updated: Date
    struct Bucket: Decodable { let primary: CodexWindow?; let secondary: CodexWindow? }
    struct Response: Decodable { let rateLimits: Bucket?; let rateLimitsByLimitId: [String: Bucket]? }
    static func parse(_ data: Data) throws -> CodexUsage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        // 多额度账户只取 Codex，不能把其他产品的额度混进来。
        let bucket = response.rateLimitsByLimitId.map { $0["codex"] } ?? response.rateLimits
        let windows = [bucket?.primary, bucket?.secondary].compactMap { $0 }
        guard !windows.isEmpty, windows.allSatisfy({ $0.usedPercent.isFinite }) else { throw CodexReadError.unavailable }
        return CodexUsage(windows: windows, updated: Date())
    }
}

enum CodexReadError: LocalizedError {
    case missingCLI, unavailable, connection, tampered
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex，请先安装并登录"
        case .unavailable: return "额度暂不可用，请确认 Codex 已登录"
        case .connection: return "Codex 查询失败，请检查网络或登录状态"
        case .tampered: return "Codex 文件权限异常，已拒绝读取"
        }
    }
}

enum CodexReader {
    static func fetch() async throws -> CodexUsage {
        try await Task.detached(priority: .utility) { try read() }.value
    }
    private static func read() throws -> CodexUsage {
        let candidates = [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw CodexReadError.missingCLI }
        let executable = URL(fileURLWithPath: path)
        // 安全加固：codex 承载本机登录态，被替换等同提权；校验真实文件属主与写权限后才调用。
        guard LocalFileGuard.trusted(executable.path) else { throw CodexReadError.tampered }
        let process = Process(); process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "quota_widget", "version": "1.4.0"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw CodexReadError.connection }
            buffer.append(chunk)
            guard buffer.count < 4_000_000 else { throw CodexReadError.connection }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw CodexReadError.unavailable }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    return try CodexUsage.parse(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}

func codexSelfTest() throws {
    let single = try CodexUsage.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":10080},"secondary":null}}"#.utf8))
    precondition(single.windows.count == 1 && single.windows[0].remaining == 77)
    let multi = try CodexUsage.parse(Data(#"{"rateLimits":{"primary":{"usedPercent":0}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":25,"windowDurationMins":10080}}}}"#.utf8))
    precondition(multi.windows.map(\.remaining) == [0, 75])
    do { _ = try CodexUsage.parse(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8)); preconditionFailure("缺失数据不能视作全额") } catch CodexReadError.unavailable {}
    precondition(CodexWindow(usedPercent: 110, windowDurationMins: nil, resetsAt: nil).remaining == 0)
    precondition(CodexWindow(usedPercent: 1, windowDurationMins: 300, resetsAt: 1).text == "待刷新")
    print("通过：Codex 剩余百分比、多周期、空值、越界与过期数据。")
}
