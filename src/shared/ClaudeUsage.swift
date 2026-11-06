// 来源：APIQuota 1.11.0 ClaudeUsage.swift（原样复用）
import Foundation

// Claude 订阅额度（5 小时窗口 + 本周）。
// 没有公开接口可用 API Key 查询，读取两处本机文件，取较新者：
//   1) ~/.agenthud/claude-usage.json：Claude 会话定时写入的快照（含重置时间）
//   2) Claude 桌面 App 的 plan-usage-history.json：App 自己的采样（fh/sd 百分比，无重置时间）
struct ClaudeWindow: Codable, Equatable {
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    /// 采样没有重置时间时的上限：采样时刻 + 窗口长度，过了这个时间窗口一定已经滚动
    var latestReset: Date? = nil
    var expired: Bool { (resetsAt ?? latestReset).map { $0 <= Date() } ?? false }
    // 过了重置时间的窗口视为满额（推断值，resetText 会标明）
    var remaining: Double { expired ? 100 : max(0, min(100, 100 - usedPercent)) }
    var text: String { String(format: "%.0f%%", remaining.rounded(.down)) }
    var resetText: String {
        if expired { return "已重置，待更新" }
        guard let resetsAt else { return "重置时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(resetsAt) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: resetsAt) + " 重置"
    }
}

struct ClaudeUsage: Codable, Equatable {
    var plan: String
    var windows: [ClaudeWindow]
    var updated: Date
    /// 更紧的那个窗口：哪个先用完看哪个
    var binding: ClaudeWindow? { windows.min { $0.remaining < $1.remaining } }
}

enum ClaudeReader {
    static var snapshotURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agenthud/claude-usage.json") }
    static var historyURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json") }

    static func load() -> ClaudeUsage? {
        let snapshot = (try? Data(contentsOf: snapshotURL)).flatMap(parseSnapshot)
        guard let history = (try? Data(contentsOf: historyURL)).flatMap(parseHistory),
              history.updated > (snapshot?.updated ?? .distantPast) else { return snapshot }
        return merge(snapshot: snapshot, history: history)
    }

    /// 采样更新：用采样的百分比。快照的重置时间只有晚于采样时刻才属于同一窗口，
    /// 否则那个窗口早已滚动，沿用会把新采样误判成「已重置」而显示满额。
    static func merge(snapshot: ClaudeUsage?, history: ClaudeUsage) -> ClaudeUsage {
        let resets = Dictionary(uniqueKeysWithValues: (snapshot?.windows ?? []).map { ($0.title, $0.resetsAt) })
        return ClaudeUsage(plan: snapshot?.plan ?? "",
                           windows: history.windows.map { w in
                               let carried = (resets[w.title] ?? nil).flatMap { $0 > history.updated ? $0 : nil }
                               return ClaudeWindow(title: w.title, usedPercent: w.usedPercent, resetsAt: carried, latestReset: w.latestReset)
                           },
                           updated: history.updated)
    }

    static func parseSnapshot(_ data: Data) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = obj["updated"] as? Double, updated.isFinite else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? {
            if let n = value as? Double { return Date(timeIntervalSince1970: n) }
            guard let s = value as? String else { return nil }
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        var windows: [ClaudeWindow] = []
        for (key, title) in [("fiveHour", "5 小时"), ("week", "本周")] {
            guard let w = obj[key] as? [String: Any], let used = w["usedPercent"] as? Double, used.isFinite else { continue }
            windows.append(ClaudeWindow(title: title, usedPercent: used, resetsAt: date(w["resetsAt"])))
        }
        guard !windows.isEmpty else { return nil }
        return ClaudeUsage(plan: obj["plan"] as? String ?? "", windows: windows, updated: Date(timeIntervalSince1970: updated))
    }

    static func parseHistory(_ data: Data) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]] else { return nil }
        let latest = samples.compactMap { s -> (Double, [String: Any])? in
            guard let t = s["t"] as? Double, let u = s["u"] as? [String: Any], !u.isEmpty else { return nil }
            return (t, u)
        }.max { $0.0 < $1.0 }
        guard let (t, u) = latest else { return nil }
        let sampled = Date(timeIntervalSince1970: t / 1000)
        var windows: [ClaudeWindow] = []
        if let fh = u["fh"] as? Double { windows.append(ClaudeWindow(title: "5 小时", usedPercent: fh, resetsAt: nil, latestReset: sampled.addingTimeInterval(5 * 3600))) }
        if let sd = u["sd"] as? Double { windows.append(ClaudeWindow(title: "本周", usedPercent: sd, resetsAt: nil, latestReset: sampled.addingTimeInterval(7 * 86400))) }
        guard !windows.isEmpty else { return nil }
        return ClaudeUsage(plan: "", windows: windows, updated: sampled)
    }
}

func claudeSelfTest() {
    let snap = ClaudeReader.parseSnapshot(Data(#"{"updated":1793388584,"plan":"Pro","fiveHour":{"usedPercent":29,"resetsAt":"2099-10-30T23:30:00.165Z"},"week":{"usedPercent":16,"resetsAt":"2099-11-02T01:00:00Z"}}"#.utf8))!
    precondition(snap.windows.count == 2 && snap.binding?.title == "5 小时" && snap.binding?.remaining == 71)
    let past = ClaudeWindow(title: "5 小时", usedPercent: 90, resetsAt: Date(timeIntervalSinceNow: -60))
    precondition(past.remaining == 100)
    let sampleMs = Int(Date().timeIntervalSince1970 * 1000) - 60_000
    let hist = ClaudeReader.parseHistory(Data(#"{"version":2,"samples":[{"t":1,"u":{}},{"t":\#(sampleMs),"u":{"fh":40,"sd":70}}]}"#.utf8))!
    precondition(hist.binding?.title == "本周" && hist.updated == Date(timeIntervalSince1970: Double(sampleMs) / 1000))
    precondition(ClaudeReader.parseSnapshot(Data(#"{"updated":1}"#.utf8)) == nil)
    // 回归：旧快照的重置时间已过，不能让新采样显示满额（曾显示 100% · 重置时间未知）
    let now = Date()
    let oldSnap = ClaudeUsage(plan: "Pro", windows: [ClaudeWindow(title: "5 小时", usedPercent: 57, resetsAt: now.addingTimeInterval(-86400)),
                                                     ClaudeWindow(title: "本周", usedPercent: 20, resetsAt: now.addingTimeInterval(-3600))], updated: now.addingTimeInterval(-90000))
    let fresh = ClaudeUsage(plan: "", windows: [ClaudeWindow(title: "5 小时", usedPercent: 15, resetsAt: nil, latestReset: now.addingTimeInterval(4 * 3600)),
                                                ClaudeWindow(title: "本周", usedPercent: 23, resetsAt: nil, latestReset: now.addingTimeInterval(86400))], updated: now.addingTimeInterval(-60))
    let merged = ClaudeReader.merge(snapshot: oldSnap, history: fresh)
    precondition(merged.windows.map(\.remaining) == [85, 77] && merged.binding?.title == "本周" && merged.plan == "Pro")
    // 同一窗口内的未来重置时间仍然沿用
    let liveSnap = ClaudeUsage(plan: "Pro", windows: [ClaudeWindow(title: "5 小时", usedPercent: 10, resetsAt: now.addingTimeInterval(600))], updated: now.addingTimeInterval(-3600))
    precondition(ClaudeReader.merge(snapshot: liveSnap, history: fresh).windows[0].resetsAt != nil)
    // 采样超过 5 小时：窗口一定滚动过，不再显示旧百分比
    let rolled = ClaudeWindow(title: "5 小时", usedPercent: 90, resetsAt: nil, latestReset: now.addingTimeInterval(-1))
    precondition(rolled.remaining == 100 && rolled.resetText == "已重置，待更新")
    print("通过：Claude 快照、采样、过期窗口、更紧窗口选择与旧重置时间合并。")
}
