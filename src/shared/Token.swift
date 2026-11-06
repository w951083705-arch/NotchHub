// 来源：AgentHUD 交互恢复版 Token.swift（24h token 数据）；NotchHub 增加 Claude Code 一列
import Foundation
import SwiftUI

// ============================================================
// Token 24h 数据（由 tools/token-collector.py 生成）
// ============================================================

struct TokenHour: Codable, Identifiable {
    var id: Double { t }
    let t: Double
    let dsh: Double
    let codex: Double
    var claude: Double = 0
    var date: Date { Date(timeIntervalSince1970: t) }
    var total: Double { dsh + codex + claude }
    enum CodingKeys: String, CodingKey { case t, dsh, codex, claude }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        dsh = try c.decode(Double.self, forKey: .dsh)
        codex = try c.decode(Double.self, forKey: .codex)
        claude = try c.decodeIfPresent(Double.self, forKey: .claude) ?? 0
    }
}

struct TokenData: Codable {
    let hours: [TokenHour]
    let dshTotal24h: Double
    let codexTotal24h: Double
    var claudeTotal24h: Double? = nil
    let lastHour: Double
    let prevHour: Double
    let dshEvents: Int
    let codexEvents: Int
    let updated: Double

    var maxHour: Double { max(1, hours.map(\.total).max() ?? 1) }
    var peakHour: TokenHour? { hours.max(by: { $0.total < $1.total }) }
}

final class TokenStore: ObservableObject {
    @Published var data: TokenData?
    private var lastRun: Date = .distantPast
    private var running = false
    private var timer: Timer?
    @Published var error: String?

    func start() {
        guard timer == nil else { return }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    deinit { timer?.invalidate() }

    static func collector() -> String? {
        guard let res = Bundle.main.resourcePath else { return nil }
        let p = res + "/token-collector.py"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static let outputPath = NSHomeDirectory() + "/Library/Caches/NotchHub/tokens.json"
    /// /usr/bin/python3 只是占位程序：没装命令行工具时运行它会弹系统安装框。
    static var pythonAvailable: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func refresh(force: Bool = false) {
        // 先读现成的
        if let d = Self.load() { data = d }
        let age = Date().timeIntervalSince(lastRun)
        guard !running, force || age > 90 else { return }
        running = true
        lastRun = Date()
        guard let script = Self.collector() else { running = false; error = "采集脚本缺失"; return }
        guard Self.pythonAvailable else { running = false; error = "需要 Xcode 命令行工具（xcode-select --install）"; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script]
            p.environment = ProcessInfo.processInfo.environment.merging(["AGENTHUD_TOKEN_OUTPUT": Self.outputPath]) { _, new in new }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var failure: String?
            do {
                try p.run()
                let deadline = Date().addingTimeInterval(60)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if p.isRunning { p.terminate(); failure = "采集超时" }
                else if p.terminationStatus != 0 { failure = "采集失败，请检查本地会话和 Python 环境" }
            } catch { failure = "无法启动采集器" }
            let d = failure == nil ? Self.load() : nil
            let resultError = failure ?? (d == nil ? "采集结果无法读取" : nil)
            DispatchQueue.main.async {
                if let d { self?.data = d }
                self?.error = resultError
                self?.running = false
            }
        }
    }

    static func load() -> TokenData? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) else { return nil }
        return try? JSONDecoder().decode(TokenData.self, from: raw)
    }
}

// MARK: - 数字格式化

func compactTokens(_ v: Double) -> String {
    if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.1fk", v / 1_000) }
    return String(format: "%.0f", v)
}

func rateText(_ last: Double, _ prev: Double) -> String {
    guard prev > 1 else { return last > 0 ? "↑ 新增 \(compactTokens(last))" : "—" }
    let delta = (last - prev) / prev * 100
    let arrow = delta >= 0 ? "↑" : "↓"
    return "\(arrow) \(String(format: "%.0f", abs(delta)))% 本小时 / 上小时"
}

// ============================================================
// 24h 柱状图
// ============================================================
