import AppKit
import SwiftUI

// ============================================================
// 额度：DeepSeek / Kimi / GLM 余额，Codex / Claude 订阅剩余，WorkBuddy 积分
// ============================================================

enum QuotaUnit {
    case money, credits, percent
    var step: Double { switch self { case .money: return 1; case .credits: return 100; case .percent: return 5 } }
    var maxValue: Double { switch self { case .money: return 1000; case .credits: return 100_000; case .percent: return 100 } }
    func text(_ v: Double) -> String {
        switch self {
        case .money: return "¥\(Int(v))"
        case .credits: return "\(Int(v)) 积分"
        case .percent: return "\(Int(v))%"
        }
    }
    static func of(_ id: String) -> QuotaUnit { id == "workbuddy" ? .credits : (id == "codex" || id == "claude") ? .percent : .money }
}

/// 额度提醒规则：低于阈值时在灵动岛弹出提醒，回到阈值以上后重新生效。
struct AlertRule: Codable, Equatable {
    var enabled = true
    var threshold: Double
    static func defaults(_ id: String) -> AlertRule {
        switch QuotaUnit.of(id) {
        case .money: return AlertRule(threshold: 5)
        case .credits: return AlertRule(threshold: 100)
        case .percent: return AlertRule(threshold: 15)
        }
    }
}

struct QuotaItem: Identifiable {
    let id: String
    let name: String
    let color: Color
    let value: String
    let detail: String
    let fraction: Double?      // 订阅类剩余比例 0...1
    var level: Double? = nil   // 与阈值比较的数值：余额、积分或剩余百分比
    let low: Bool
    let stale: Bool
    let url: URL?
}

enum Palette {
    static let deepseek = Color(red: 0.36, green: 0.55, blue: 1.00)
    static let kimi = Color(red: 0.99, green: 0.73, blue: 0.26)
    static let glm = Color(red: 0.66, green: 0.55, blue: 0.98)
    static let codex = Color(red: 0.30, green: 0.84, blue: 0.70)
    static let claude = Color(red: 0.89, green: 0.52, blue: 0.38)
    static let workbuddy = Color(red: 0.36, green: 0.80, blue: 0.95)
    static let dsh = Color(red: 0.22, green: 0.84, blue: 0.61)
    static let warn = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let ok = Color(red: 0.35, green: 0.86, blue: 0.48)
}

@MainActor final class QuotaStore: ObservableObject {
    @Published var balances: [Provider: Snapshot] = [:]
    @Published var codex: CodexUsage?
    @Published var claude: ClaudeUsage?
    @Published var errors: [Provider: String] = [:]
    @Published var refreshing = false
    @Published var lastCheck: Date?
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    static let ids = ["deepseek", "kimi", "glm", "codex", "claude", "workbuddy"]
    @Published var rules: [String: AlertRule] = {
        let saved = (UserDefaults.standard.data(forKey: "alert.rules")).flatMap { try? JSONDecoder().decode([String: AlertRule].self, from: $0) } ?? [:]
        return Dictionary(uniqueKeysWithValues: QuotaStore.ids.map { ($0, saved[$0] ?? AlertRule.defaults($0)) })
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "alert.rules") }
            evaluate(popup: false)
        }
    }
    /// 新跌破阈值、需要弹出提醒的项目
    @Published var alerts: [QuotaItem] = []
    private var notified = Set(UserDefaults.standard.stringArray(forKey: "alert.notified") ?? [])

    func rule(_ id: String) -> AlertRule { rules[id] ?? AlertRule.defaults(id) }
    func isLow(_ id: String, _ level: Double?) -> Bool {
        let r = rule(id)
        guard r.enabled, let level else { return false }
        return level < r.threshold
    }

    /// 跌破阈值只提醒一次；回到阈值以上（或关闭该项提醒）后重新生效。
    func evaluate(popup: Bool) {
        var fresh: [QuotaItem] = []
        for item in items where item.level != nil {
            if item.low {
                if popup && !notified.contains(item.id) { notified.insert(item.id); fresh.append(item) }
            } else {
                notified.remove(item.id)
            }
        }
        defaults.set(Array(notified), forKey: "alert.notified")
        if !fresh.isEmpty { alerts = fresh }
    }

    /// 调试：清空已提醒记录，下次刷新重新判断
    func resetNotified() { notified.removeAll(); defaults.set([String](), forKey: "alert.notified") }

    func start() {
        for p in [Provider.deepseek, .kimi, .glm, .workbuddy] {
            if let data = defaults.data(forKey: "cache.\(p.rawValue)"), let s = try? JSONDecoder().decode(Snapshot.self, from: data) { balances[p] = s }
        }
        if let data = defaults.data(forKey: "cache.codex") { codex = try? JSONDecoder().decode(CodexUsage.self, from: data) }
        claude = ClaudeReader.load()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// APIQuota 仍在运行时直接读它的缓存（钥匙串授权在它的凭据助手上，避免重复弹授权框）。
    private func apiQuotaCache(_ p: Provider) -> Snapshot? {
        guard let bundle = LocalCompat.apiQuotaBundleID else { return nil }
        CFPreferencesAppSynchronize(bundle as CFString)
        guard let data = CFPreferencesCopyAppValue("cache.\(p.rawValue)" as CFString, bundle as CFString) as? Data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private var apiQuotaRunning: Bool {
        guard let bundle = LocalCompat.apiQuotaBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    private func store(_ p: Provider, _ s: Snapshot) {
        balances[p] = s; errors[p] = nil
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: "cache.\(p.rawValue)") }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastCheck = Date() }
        claude = ClaudeReader.load()
        if claude == nil { errors[.claude] = "未找到额度快照" } else { errors[.claude] = nil }

        async let codexTask: Result<CodexUsage, Error> = { do { return .success(try await CodexReader.fetch()) } catch { return .failure(error) } }()
        async let buddyTask: Result<Snapshot, Error> = { do { return .success(try await WorkBuddyReader.fetch()) } catch { return .failure(error) } }()

        for p in [Provider.deepseek, .kimi, .glm] {
            let cached = Vault.configured(p) ? nil : apiQuotaCache(p)
            if let cached, Date().timeIntervalSince(cached.updated) < 1200 || apiQuotaRunning {
                if cached.updated > (balances[p]?.updated ?? .distantPast) { store(p, cached) }
                continue
            }
            do {
                let result = try await Task.detached(priority: .utility) { () throws -> Snapshot in
                    guard let key = try Vault.read(p), !key.isEmpty else { throw QuotaError.missingKey }
                    return try await QuotaAPI.fetch(p, key: key)
                }.value
                store(p, result)
            } catch {
                if let cached { store(p, cached) }
                errors[p] = QuotaAPI.errorText(error)
            }
        }

        switch await codexTask {
        case .success(let value):
            codex = value; errors[.openai] = nil
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "cache.codex") }
        case .failure(let error): errors[.openai] = error.localizedDescription
        }
        switch await buddyTask {
        case .success(let value): store(.workbuddy, value)
        case .failure(let error): errors[.workbuddy] = error.localizedDescription
        }
        evaluate(popup: true)
    }

    /// 配置 DeepSeek / Kimi / GLM 的 API Key，保存在本机钥匙串。留空表示不修改。
    func promptAPIKeys() {
        NSApp.activate(ignoringOtherApps: true)
        let providers = [Provider.deepseek, .kimi, .glm]
        let alert = NSAlert()
        alert.messageText = "API Key"
        alert.informativeText = "只保存在本机钥匙串，只用来查询对应平台的余额。"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        var fields: [NSSecureTextField] = []
        for (i, p) in providers.enumerated() {
            let y = CGFloat(2 - i) * 32
            let label = NSTextField(labelWithString: p.name)
            label.frame = NSRect(x: 0, y: y + 3, width: 70, height: 18)
            let field = NSSecureTextField(frame: NSRect(x: 72, y: y, width: 248, height: 24))
            field.placeholderString = Vault.configured(p) ? "已配置，留空不修改" : "未配置"
            box.addSubview(label); box.addSubview(field); fields.append(field)
        }
        alert.accessoryView = box
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除全部")
        alert.window.initialFirstResponder = fields[0]
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }
        do {
            for (p, field) in zip(providers, fields) {
                if response == .alertThirdButtonReturn {
                    try Vault.delete(p); balances[p] = nil; errors[p] = nil
                    defaults.removeObject(forKey: "cache.\(p.rawValue)")
                } else if !field.stringValue.isEmpty { try Vault.save(field.stringValue, for: p) }
            }
        } catch {
            let failure = NSAlert(); failure.messageText = "保存失败"; failure.informativeText = QuotaAPI.errorText(error); failure.runModal()
        }
        Task { await refresh() }
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date) + " 同步"
    }

    private func moneyItem(_ p: Provider, color: Color) -> QuotaItem {
        let s = balances[p]
        let cny = s?.money.first { $0.currency == "CNY" } ?? s?.money.first
        let level = cny.map { NSDecimalNumber(decimal: $0.value).doubleValue }
        let low = isLow(p.rawValue, level)
        let stale = s.map { Date().timeIntervalSince($0.updated) > 1800 } ?? true
        return QuotaItem(id: p.rawValue, name: p.name, color: color, value: cny?.text ?? "—",
                         detail: errors[p].map { s == nil ? $0 : "旧数据 · " + $0 } ?? (p == .workbuddy ? "积分 · " : "余额 · ") + timeText(s?.updated),
                         fraction: nil, level: level, low: low, stale: stale, url: URL(string: p.dashboard))
    }

    var items: [QuotaItem] {
        var result = [moneyItem(.deepseek, color: Palette.deepseek), moneyItem(.kimi, color: Palette.kimi), moneyItem(.glm, color: Palette.glm)]
        let cw = codex?.windows.filter { !$0.expired }.min { $0.remaining < $1.remaining }
        result.append(QuotaItem(id: "codex", name: "Codex", color: Palette.codex, value: cw?.text ?? "—",
                                detail: cw.map { "\($0.title) · \($0.resetText)" } ?? errors[.openai] ?? "读取中",
                                fraction: cw.map { $0.remaining / 100 }, level: cw?.remaining, low: isLow("codex", cw?.remaining),
                                stale: codex.map { Date().timeIntervalSince($0.updated) > 1800 } ?? true,
                                url: URL(string: "https://chatgpt.com/codex/settings/usage")))
        let bw = claude?.binding
        result.append(QuotaItem(id: "claude", name: "Claude", color: Palette.claude, value: bw?.text ?? "—",
                                detail: bw.map { "\($0.title) · \($0.resetText) · \(claudeSyncText)" } ?? errors[.claude] ?? "读取中",
                                fraction: bw.map { $0.remaining / 100 }, level: bw?.remaining, low: isLow("claude", bw?.remaining),
                                stale: claude.map { Date().timeIntervalSince($0.updated) > 10800 } ?? true,
                                url: URL(string: Provider.claude.dashboard)))
        result.append(moneyItem(.workbuddy, color: Palette.workbuddy))
        return result
    }

    /// Claude 没有实时接口，标出数据时间，避免把旧采样当成当前值
    private var claudeSyncText: String {
        guard let date = claude?.updated else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date) + " 同步"
    }

    /// 收起态右侧显示：优先低额度，其次订阅里更紧的一项。
    var headline: QuotaItem? {
        let all = items
        return all.first { $0.low && $0.value != "—" }
            ?? all.filter { $0.fraction != nil && $0.value != "—" }.min { ($0.fraction ?? 1) < ($1.fraction ?? 1) }
            ?? all.first { $0.value != "—" }
    }
}

// ============================================================
// 智能体：进程是否在跑 + 会话文件最近是否在写
// ============================================================

enum AgentState: Int { case off, idle, working }

struct AgentStatus: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
    var state: AgentState = .off
    var lastActive: Date?
    var sessions = 0

    var stateText: String {
        switch state {
        case .working: return "工作中"
        case .idle: return lastActive.map { "空闲 · " + Self.ago($0) } ?? "空闲"
        case .off: return "未运行"
        }
    }
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s >= 86400 { return "\(s / 86400) 天前" }
        if s >= 3600 { return "\(s / 3600) 小时前" }
        return s >= 60 ? "\(s / 60) 分钟前" : "刚刚"
    }
}

final class AgentMonitor: ObservableObject {
    @Published var agents: [AgentStatus] = [
        AgentStatus(id: "claude", name: "Claude Code", color: Palette.claude),
        AgentStatus(id: "codex", name: "Codex", color: Palette.codex),
        AgentStatus(id: "dsh", name: "DSH", color: Palette.dsh),
        AgentStatus(id: "workbuddy", name: "WorkBuddy", color: Palette.workbuddy),
    ]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notchhub.agents", qos: .utility)
    static let workingWindow: TimeInterval = 45

    var running: [AgentStatus] { agents.filter { $0.state != .off } }
    var working: [AgentStatus] { agents.filter { $0.state == .working } }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.scan() }
    }

    private func scan() {
        queue.async { [weak self] in
            guard let self else { return }
            let procs = Self.processNames()
            let home = NSHomeDirectory()
            var next = self.agents
            func update(_ id: String, running: Bool, files: [Date]) {
                guard let i = next.firstIndex(where: { $0.id == id }) else { return }
                let latest = files.max()
                let recent = files.filter { Date().timeIntervalSince($0) < Self.workingWindow }.count
                next[i].lastActive = latest
                next[i].sessions = recent
                next[i].state = !running ? .off : recent > 0 ? .working : .idle
            }
            update("claude", running: procs.contains("claude"),
                   files: Self.mtimes(in: home + "/.claude/projects", depth: 2, suffix: ".jsonl"))
            update("codex", running: procs.contains("codex"), files: Self.codexFiles(home))
            update("dsh", running: procs.contains("dsh") || procs.contains("DeepSeek Harness"),
                   files: Self.mtimes(in: home + "/.dsh/sessions", depth: 3, suffix: ".zstd"))
            update("workbuddy", running: procs.contains("WorkBuddy"), files: [])
            DispatchQueue.main.async { if self.agents != next { self.agents = next } }
        }
    }

    static func processNames() -> Set<String> {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "comm="]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return Set(out.split(separator: "\n").map { ($0 as NSString).lastPathComponent })
    }

    /// 只看最近 1 天修改过的文件，返回修改时间。
    static func mtimes(in root: String, depth: Int, suffix: String) -> [Date] {
        let fm = FileManager.default
        var result: [Date] = []
        var level = [root]
        let cutoff = Date().addingTimeInterval(-86400)
        for d in 0..<depth {
            var nextLevel: [String] = []
            for dir in level {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let path = dir + "/" + name
                    guard let attrs = try? fm.attributesOfItem(atPath: path), let m = attrs[.modificationDate] as? Date else { continue }
                    if attrs[.type] as? FileAttributeType == .typeDirectory {
                        if d < depth - 1 && m > cutoff.addingTimeInterval(-86400 * 30) { nextLevel.append(path) }
                    } else if name.hasSuffix(suffix) && m > cutoff { result.append(m) }
                }
            }
            level = nextLevel
        }
        return result
    }

    static func codexFiles(_ home: String) -> [Date] {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
        return [Date(), Date().addingTimeInterval(-86400)].flatMap {
            mtimes(in: home + "/.codex/sessions/" + f.string(from: $0), depth: 1, suffix: ".jsonl")
        }
    }
}

// ============================================================
// 代理状态（Clash Verge）
// ============================================================

final class ProxyStore: ObservableObject {
    @Published var info: ProxyInfo?
    @Published var live: ProxyLive?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = ProxyReader.load()
            let live = ClashAPI.load(groupName: info?.group.isEmpty == false ? info!.group : "自动选择")
            DispatchQueue.main.async { self?.info = info; self?.live = live }
        }
    }
}

// ============================================================
// 常用工具：应用或终端命令，可自行添加
// ============================================================

struct ToolItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case app, command }
    var id = UUID().uuidString
    var name: String
    var kind: Kind
    var target: String          // .app 路径或命令

    var icon: NSImage {
        let path = kind == .app ? target : "/System/Applications/Utilities/Terminal.app"
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        return image
    }
}

final class ToolStore: ObservableObject {
    @Published var tools: [ToolItem] = []
    private let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchHub")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([ToolItem].self, from: data) { tools = list }
        else { tools = Self.defaults(); save() }
    }

    static func defaults() -> [ToolItem] {
        func app(_ name: String, _ candidates: [String]) -> ToolItem? {
            candidates.first { FileManager.default.fileExists(atPath: $0) }.map { ToolItem(name: name, kind: .app, target: $0) }
        }
        let home = NSHomeDirectory()
        return [
            app("Claude", ["/Applications/Claude.app"]),
            app("Codex", ["/Applications/Codex.app", home + "/Applications/Codex.app"]) ?? ToolItem(name: "Codex", kind: .command, target: "codex"),
            app("WorkBuddy", ["/Applications/WorkBuddy.app", home + "/Applications/WorkBuddy.app", home + "/Desktop/WorkBuddy.app"]),
            app("DeepSeek Harness", ["/Applications/DeepSeek Harness.app", home + "/Desktop/DeepSeek Harness.app"]),
        ].compactMap { $0 }
    }

    func save() { if let data = try? JSONEncoder().encode(tools) { try? data.write(to: url, options: .atomic) } }
    func add(_ item: ToolItem) { tools.append(item); save() }
    func resetDefaults() { tools = Self.defaults(); save() }
    func remove(_ item: ToolItem) { tools.removeAll { $0.id == item.id }; save() }
    func move(_ item: ToolItem, by offset: Int) {
        guard let i = tools.firstIndex(of: item) else { return }
        let j = max(0, min(tools.count - 1, i + offset))
        tools.swapAt(i, j); save()
    }

    func launch(_ item: ToolItem) {
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.target), configuration: NSWorkspace.OpenConfiguration())
        case .command:
            // 写成 .command 文件交给终端打开：不需要自动化权限，登录 shell 能找到 ~/.local/bin。
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NotchHub")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("tool-\(item.id).command")
            let script = "#!/bin/zsh -l\ncd ~\n\(item.target)\n"
            try? script.write(to: file, atomically: true, encoding: .utf8)
            chmod(file.path, 0o700)
            NSWorkspace.shared.open(file)
        }
    }

    @MainActor func promptAddApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            add(ToolItem(name: url.deletingPathExtension().lastPathComponent, kind: .app, target: url.path))
        }
    }

    @MainActor func promptAddCommand() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "添加终端命令"
        alert.informativeText = "点击后会在终端里运行这条命令。"
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        name.placeholderString = "名称，例如 DSH"
        let command = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        command.placeholderString = "命令，例如 dsh"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(name); box.addSubview(command)
        alert.accessoryView = box
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        let c = command.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !c.isEmpty else { return }
        add(ToolItem(name: n, kind: .command, target: c))
    }
}
