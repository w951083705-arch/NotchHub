import AppKit
import IOKit.pwr_mgt
import IOKit.ps

// 移植自接电常醒 1.2（power-awake/main.swift）：策略、断言、合盖看门狗、移动时钟逻辑不变，
// 菜单栏改成灵动岛里的「常醒」页。

enum AwakeMode: String {
    case displayMaySleep, displayStaysOn
}

struct AwakePolicy {
    // 锁屏时不再强制亮屏；电量过低（充电器功率不足仍在掉电）时整体撤销。定时常醒不看是否接电。
    // 不息屏常醒（alwaysOn）：不论是否接电，电脑和屏幕都保持亮着。
    static func assertions(enabled: Bool, ac: Bool, lowBattery: Bool = false, locked: Bool = false,
                           timed: Bool = false, alwaysOn: Bool = false, mode: AwakeMode) -> (system: Bool, display: Bool) {
        let active = ((enabled && ac) || timed || alwaysOn) && !lowBattery
        return (active, active && !locked && (mode == .displayStaysOn || alwaysOn))
    }
}

final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    var active: Bool { id != 0 }
    func set(_ needed: Bool, type: String) -> Bool {
        if needed == active { return true }
        if !needed {
            let result = IOPMAssertionRelease(id)
            if result == kIOReturnSuccess { id = 0 }
            return result == kIOReturnSuccess
        }
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "NotchHub: keep awake" as CFString, &created)
        if result == kIOReturnSuccess { id = created }
        return result == kIOReturnSuccess
    }
    deinit { if active { IOPMAssertionRelease(id) } }
}

// 合盖不休眠：只能打开系统 SleepDisabled（root）。开启时用一次管理员密码启动 root 看门狗，由它独立判断电源：
// 接电时保持 1；电池供电时只有定时内保持 1；电量 ≤15% 且未充电时为 0；条件恢复后自动回到 1，不用再输密码。
// 控制文件被删除（关闭开关、正常退出）、本应用退出或崩溃、看门狗收到 TERM（关机）时恢复 0。
// 变成 0 时如果盖子是合上的，立刻让电脑睡眠，避免放进包里后继续发热。
// 控制文件内容：定时截止时间（epoch 秒），0 表示没有定时。
enum LidGuard {
    static let deadlineFile = NSHomeDirectory() + "/Library/Caches/NotchHub/lid-deadline"
    static let watchdog = """
    held=""
    apply() {
      [ "$held" = "$1" ] && return
      /usr/bin/pmset -a disablesleep "$1"
      held="$1"
      if [ "$1" = 0 ] && /usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q 'AppleClamshellState.*Yes'; then
        /usr/bin/pmset sleepnow
      fi
    }
    trap "apply 0" EXIT
    trap "exit" TERM HUP INT
    while /bin/kill -0 "$2" 2>/dev/null; do
      d=$(/bin/cat "$1" 2>/dev/null)
      case "$d" in ''|*[!0-9]*) break;; esac
      timed=0
      [ "$d" -gt "$(/bin/date +%s)" ] && timed=1
      b=$(/usr/bin/pmset -g batt)
      pct=$(printf '%s' "$b" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -n 1 | /usr/bin/tr -d '%')
      low=0
      case "$b" in *"; charging"*) ;; *) [ -n "$pct" ] && [ "$pct" -le 15 ] && low=1;; esac
      onac=1
      case "$b" in *"Battery Power"*) onac=0;; esac
      if [ "$low" = 1 ]; then apply 0
      elif [ "$onac" = 1 ] || [ "$timed" = 1 ]; then apply 1
      else apply 0
      fi
      /bin/sleep 3 & wait $!
    done
    """

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func writeDeadline(_ date: Date?) {
        try? FileManager.default.createDirectory(atPath: (deadlineFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? String(Int(date?.timeIntervalSince1970 ?? 0)).write(toFile: deadlineFile, atomically: true, encoding: .utf8)
    }

    static func clear() { try? FileManager.default.removeItem(atPath: deadlineFile) }

    /// 弹出系统管理员密码框；成功返回 nil，否则返回错误说明（用户点取消时为空字符串）。
    static func start(until date: Date?, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String? {
        writeDeadline(date)
        let command = "/bin/sh -c \(quote(watchdog)) sh \(quote(deadlineFile)) \(pid) >/dev/null 2>&1 &"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges "
                      + "with prompt \"NotchHub 需要临时关闭系统睡眠，以便合盖后任务继续运行。拔电、关闭开关或退出后自动恢复。\"")?
            .executeAndReturnError(&error)
        if let error {
            clear()
            if error[NSAppleScript.errorNumber] as? Int == -128 { return "" }
            return error[NSAppleScript.errorMessage] as? String ?? "授权未完成"
        }
        return nil
    }

    static func sleepDisabled() -> Bool {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.hasSuffix("1") }
    }

    static func restoreLeftover() -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges "
            + "with prompt \"上次合盖常醒没有正常结束，系统睡眠仍被关闭。NotchHub 需要恢复系统睡眠设置。\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
}

final class ClockView: NSView {
    let started = Date()
    var dismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let seconds = Date().timeIntervalSince(started)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = formatter.string(from: Date())
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .light),
            .foregroundColor: NSColor(white: 0.27, alpha: 1)
        ]
        let size = text.size(withAttributes: attributes)
        let width = max(0, bounds.width - size.width - 100)
        let height = max(0, bounds.height - size.height - 100)
        let point = NSPoint(x: 50 + width * (0.5 + 0.48 * sin(seconds / 37)),
                            y: 50 + height * (0.5 + 0.48 * cos(seconds / 51)))
        text.draw(at: point, withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) { dismiss?() }
    override func rightMouseDown(with event: NSEvent) { dismiss?() }
    override func keyDown(with event: NSEvent) { dismiss?() }
    override func scrollWheel(with event: NSEvent) { dismiss?() }
}

final class AwakeController: ObservableObject {
    @Published private(set) var ac = false
    @Published private(set) var lowBattery = false
    @Published private(set) var failed = false
    @Published private(set) var deadline: Date?
    // lidOn：本应用启动的看门狗在工作。sleepDisabledNow：系统实际的 SleepDisabled。
    @Published private(set) var lidOn = false
    @Published private(set) var sleepDisabledNow = false
    @Published private(set) var systemHeld = false
    @Published var enabled = UserDefaults.standard.object(forKey: "awake.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "awake.enabled"); refresh() }
    }
    @Published var mode = AwakeMode(rawValue: UserDefaults.standard.string(forKey: "awake.mode") ?? "") ?? .displayMaySleep {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "awake.mode"); refresh() }
    }
    // 不息屏常醒：可选时长（分钟，0 = 不限时），到点自动关闭。
    @Published private(set) var alwaysOn = false
    @Published private(set) var alwaysOnUntil: Date?
    @Published private(set) var alwaysOnTotal: TimeInterval = 0
    @Published private(set) var alwaysOnMinutes = UserDefaults.standard.object(forKey: "awake.alwaysOnMinutes") as? Int ?? 60
    @Published private(set) var displayHeld = false
    @Published private(set) var timedTotal: TimeInterval = 0

    private let systemAssertion = SleepAssertion()
    private let displayAssertion = SleepAssertion()
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var locked = false
    private var lastDismiss = Date()
    private var clockShown = Date()
    private var lidSettleUntil = Date.distantPast
    private var lidMisses = 0
    var onAlert: ((String, String) -> Void)?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AwakeController>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenLocked), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenUnlocked), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // 上次合盖常醒没有正常结束（例如中途重启，看门狗随之消失）时，SleepDisabled 会一直保留。
        if FileManager.default.fileExists(atPath: LidGuard.deadlineFile) {
            LidGuard.clear()
            if LidGuard.sleepDisabled() && !LidGuard.restoreLeftover() {
                onAlert?("系统睡眠仍被关闭", "可在终端执行 sudo pmset -a disablesleep 0 恢复。")
            }
        }
        refresh()
    }

    private var lidSettling: Bool { Date() < lidSettleUntil }
    /// 合盖不休眠此刻确实生效。
    var lidActive: Bool { lidOn && sleepDisabledNow }
    /// SleepDisabled=1 但不是本应用开启的（其他工具或手动 pmset）。
    var lidExternal: Bool { sleepDisabledNow && !lidOn && !lidSettling }
    /// 开关显示值，和系统实际状态一致。
    var lidSwitch: Bool { lidOn || lidExternal }
    var lidDetail: String {
        if lidExternal { return "系统睡眠被其他程序关闭 · 关掉开关可恢复（需管理员密码）" }
        if !lidOn { return "合盖后任务继续跑 · 需管理员密码 · 放包里注意散热" }
        if lowBattery { return "已暂停 · 电量过低，充电后自动恢复" }
        if !sleepDisabledNow { return ac || deadline != nil ? "正在生效…" : "已暂停 · 电池供电，接电后自动恢复" }
        return deadline != nil ? "已生效 · 定时内电池也有效，低于 15% 暂停 · 注意散热" : "已生效 · 拔电自动暂停，退出后恢复 · 注意散热"
    }

    var statusText: String {
        if failed { return "防休眠请求失败，请重新启动" }
        if lowBattery { return "电量过低且未在充电，已恢复系统原策略" }
        if alwaysOn { return ac ? "不息屏常醒中，屏幕保持亮着" : "电池供电，不息屏常醒中" }
        if deadline != nil { return lidActive ? "定时常醒中，合盖也保持唤醒" : "定时常醒中，电池供电也有效" }
        if !ac { return "电池供电，使用系统原策略" }
        if lidActive { return "接通电源，合盖也保持运行" }
        return enabled ? "接通电源，电脑保持运行" : "接通电源，已暂停"
    }

    func startAlwaysOn(minutes: Int) {
        alwaysOnMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "awake.alwaysOnMinutes")
        alwaysOn = true
        alwaysOnUntil = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        alwaysOnTotal = TimeInterval(minutes * 60)
        refresh()
    }

    func setAlwaysOn(_ on: Bool) {
        if on { startAlwaysOn(minutes: alwaysOnMinutes) } else { stopAlwaysOn(); refresh() }
    }

    private func stopAlwaysOn() { alwaysOn = false; alwaysOnUntil = nil; alwaysOnTotal = 0 }

    var remainingShort: String? {
        guard let deadline else { return nil }
        let minutes = max(0, Int(ceil(deadline.timeIntervalSinceNow / 60)))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private func readPower() -> (ac: Bool, lowBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() else { return (false, false) }
        var low = false
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            if !charging && cap * 100 / max <= 15 { low = true }
        }
        return (source as String == kIOPSACPowerValue, low)
    }

    private func schedule(_ interval: TimeInterval) {
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        (ac, lowBattery) = readPower()
        if let deadline, Date() >= deadline || lowBattery { endTimed() }
        if alwaysOn, lowBattery || (alwaysOnUntil.map { Date() >= $0 } ?? false) { stopAlwaysOn() }
        let desired = AwakePolicy.assertions(enabled: enabled, ac: ac, lowBattery: lowBattery, locked: locked,
                                             timed: deadline != nil, alwaysOn: alwaysOn, mode: mode)
        let sysOK = systemAssertion.set(desired.system, type: kIOPMAssertionTypeNoIdleSleep)
        let displayOK = displayAssertion.set(desired.display, type: kIOPMAssertionTypeNoDisplaySleep)
        failed = !sysOK || !displayOK
        systemHeld = systemAssertion.active
        displayHeld = displayAssertion.active
        syncLid()
        let anyEvent = CGEventType(rawValue: UInt32.max)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        // 时钟窗口不是键盘窗口，收不到输入事件；改用系统闲置时间判断：显示后有任何输入即收起。
        if !windows.isEmpty && idle < Date().timeIntervalSince(clockShown) - 0.5 { hideClock() }
        if (locked || failed) && !windows.isEmpty { hideClock() }
        if desired.display && mode == .displayStaysOn && !locked && !failed && idle >= 120 && Date().timeIntervalSince(lastDismiss) >= 120 && windows.isEmpty { showClock() }
        windows.forEach { $0.contentView?.needsDisplay = true }
        schedule(!windows.isEmpty ? 1 : desired.display && mode == .displayStaysOn ? 5 : lidSettling ? 2 : lidOn || deadline != nil || alwaysOnUntil != nil ? 10 : 60)
    }

    func startTimed(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        deadline = end
        timedTotal = TimeInterval(minutes * 60)
        if lidOn { LidGuard.writeDeadline(end) }      // 看门狗每 3 秒读取截止时间，不必再输密码
        refresh()
    }

    func stopTimed() { endTimed(); refresh() }

    private func endTimed() {
        deadline = nil
        timedTotal = 0
        if lidOn { LidGuard.writeDeadline(nil) }   // 开关仍开着，回到「接电时生效」
    }

    func setLid(_ on: Bool) {
        lidMisses = 0
        lidSettleUntil = Date().addingTimeInterval(6)
        if on {
            if !lidOn {
                if let error = LidGuard.start(until: deadline) {
                    if !error.isEmpty { onAlert?("合盖不休眠未开启", "没有取得管理员授权，合盖后会照常休眠。\n" + error) }
                } else { lidOn = true }
            }
        } else if lidOn {
            LidGuard.clear()   // 看门狗 3 秒内恢复 disablesleep 0，不用密码
            lidOn = false
        } else if lidExternal, !LidGuard.restoreLeftover() {
            onAlert?("系统睡眠仍被关闭", "可在终端执行 sudo pmset -a disablesleep 0 恢复。")
        }
        refresh()
    }

    // 开关状态以系统实际值为准；看门狗被杀或被外部改回时，开关跟着关掉并提示。
    private func syncLid() {
        let actual = LidGuard.sleepDisabled()
        if actual != sleepDisabledNow { sleepDisabledNow = actual }
        guard lidOn, !lidSettling else { return }
        if !actual && !lowBattery && (ac || deadline != nil) {
            lidMisses += 1
            if lidMisses >= 2 {
                lidMisses = 0
                LidGuard.clear()
                lidOn = false
                onAlert?("合盖不休眠已关闭", "系统睡眠被恢复了（看门狗退出或被其他程序改动），合盖后会照常休眠。需要的话请重新打开开关。")
            }
        } else { lidMisses = 0 }
    }

    func previewClock() { showClock() }

    private func showClock() {
        guard windows.isEmpty, !locked else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ClockView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.dismiss = { [weak self] in self?.hideClock() }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
        }
        clockShown = Date()
        schedule(1)
    }

    private func hideClock() {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.close() }
        windows.removeAll()
        lastDismiss = Date()
    }

    @objc func screenLocked() { locked = true; refresh() }
    @objc func screenUnlocked() { locked = false; lastDismiss = Date(); refresh() }
    @objc func woke() { lastDismiss = Date(); refresh() }

    func shutdown() {
        timer?.invalidate()
        hideClock()
        if lidOn { LidGuard.clear() }
        _ = displayAssertion.set(false, type: kIOPMAssertionTypeNoDisplaySleep)
        _ = systemAssertion.set(false, type: kIOPMAssertionTypeNoIdleSleep)
    }
}
