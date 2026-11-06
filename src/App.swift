import AppKit
import SwiftUI
import Combine

// ============================================================
// 灵动岛窗口：固定在刘海处的透明面板。
// 面板本身比灵动岛大（留出展开动画的空间），只有鼠标落在当前灵动岛形状内时才接收事件，其余区域点击穿透。
// ============================================================

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandController {
    let model: IslandModel
    let panel: IslandPanel
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var bag = Set<AnyCancellable>()
    private var screen: NSScreen?

    init(stores: Stores) {
        model = stores.island
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: IslandModel.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: IslandRoot(stores: stores))
        host.frame = NSRect(origin: .zero, size: IslandModel.canvas)
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.track() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] e in self?.track(); return e }) { monitors.append(m) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        model.$mode.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.track() }
        }.store(in: &bag)
    }

    /// 优先放在带刘海的内建屏上。
    func layout() {
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        screen = target
        if target.safeAreaInsets.top > 0, let l = target.auxiliaryTopLeftArea, let r = target.auxiliaryTopRightArea {
            model.notch = CGSize(width: target.frame.width - l.width - r.width, height: target.safeAreaInsets.top)
        } else {
            model.notch = CGSize(width: 180, height: max(24, target.frame.maxY - target.visibleFrame.maxY))
        }
        let f = target.frame
        panel.setFrame(NSRect(x: f.midX - IslandModel.canvas.width / 2, y: f.maxY - IslandModel.canvas.height,
                              width: IslandModel.canvas.width, height: IslandModel.canvas.height), display: true)
    }

    private func islandRect(_ mode: IslandMode) -> NSRect {
        guard let f = screen?.frame else { return .zero }
        let s = model.size(mode)
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func track() {
        let p = NSEvent.mouseLocation
        let inside = islandRect(model.mode).insetBy(dx: -4, dy: -4).contains(p)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        switch model.mode {
        case .collapsed:
            if inside { schedule(0.12) { [weak self] in self?.model.mode = .peek } } else { cancel() }
        case .peek, .expanded:
            if inside || model.pinned || NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) { cancel() }
            else { schedule(model.mode == .peek ? 0.25 : 0.5) { [weak self] in self?.model.mode = .collapsed } }
        case .approval, .alert:
            cancel()
        }
    }

    private func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            // 触发前再确认一次鼠标位置，避免快速划过时误展开/误收起
            guard let self else { return }
            let inside = self.islandRect(self.model.mode).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
            if (self.model.mode == .collapsed) == inside { work() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancel() { pending?.cancel(); pending = nil }

    var mouseInside: Bool { islandRect(model.mode).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: IslandController?
    var stores: Stores!
    var server: ApprovalServer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "NotchHub")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }

        let approvals = ApprovalCenter()
        let awake = AwakeController()
        stores = Stores(island: IslandModel(), quota: QuotaStore(), agents: AgentMonitor(), awake: awake,
                        approvals: approvals, tokens: TokenStore(), proxy: ProxyStore(), tools: ToolStore())
        let server = ApprovalServer(center: approvals)
        stores.approvalReady = server.start()
        self.server = server

        awake.onAlert = { title, text in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "知道了"); alert.runModal()
        }
        awake.start()
        stores.quota.start()
        stores.agents.start()
        stores.tokens.start()
        stores.proxy.start()
        controller = IslandController(stores: stores)
        // 调试用：-show expanded -tab 额度，直接展开到指定页（截图检查）
        let args = UserDefaults.standard
        if let tab = args.string(forKey: "tab").flatMap(IslandTab.init(rawValue:)) { stores.island.tab = tab }
        switch args.string(forKey: "show") {
        case "peek": stores.island.mode = .peek; stores.island.pinned = true
        case "expanded": stores.island.mode = .expanded; stores.island.pinned = true
        case "alert": stores.quota.resetNotified()
        default: break
        }

        // 有审批请求时自动展开成审批卡，处理完收起。
        let island = stores.island
        approvals.$pending.receive(on: RunLoop.main).sink { req in
            if req != nil {
                if island.mode != .approval { NSSound(named: "Glass")?.play() }
                island.mode = .approval
            } else if island.mode == .approval {
                island.mode = .collapsed
            }
        }.store(in: &bag)

        // 额度跌破提醒线：从刘海弹出提醒卡，12 秒后鼠标不在卡上就收起（审批优先）。
        stores.quota.$alerts.receive(on: RunLoop.main).sink { [weak self] alerts in
            guard !alerts.isEmpty, island.mode != .approval else { return }
            island.alertRows = alerts.count
            island.mode = .alert
            NSSound(named: "Funk")?.play()
            self?.scheduleAlertDismiss()
        }.store(in: &bag)
    }

    private func scheduleAlertDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.stores.island.mode == .alert else { return }
            if self.controller?.mouseInside == true { self.scheduleAlertDismiss(); return }
            self.stores.quota.alerts = []
            self.stores.island.mode = .collapsed
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stores?.awake.shutdown()
    }
}

@main struct NotchHubMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            for enabled in [false, true] { for ac in [false, true] { for low in [false, true] { for locked in [false, true] {
                for mode in [AwakeMode.displayMaySleep, .displayStaysOn] {
                    let r = AwakePolicy.assertions(enabled: enabled, ac: ac, lowBattery: low, locked: locked, mode: mode)
                    precondition(r.system == (enabled && ac && !low))
                    precondition(r.display == (enabled && ac && !low && !locked && mode == .displayStaysOn))
                    precondition(AwakePolicy.assertions(enabled: enabled, ac: ac, lowBattery: low, locked: locked, timed: true, mode: mode).system == !low)
                    let on = AwakePolicy.assertions(enabled: enabled, ac: ac, lowBattery: low, locked: locked, alwaysOn: true, mode: mode)
                    precondition(on.system == !low && on.display == (!low && !locked))
                }
            } } } }
            do { try selfTest(); try codexSelfTest(); claudeSelfTest(); try workBuddySelfTest(); try localGuardSelfTest() }
            catch { print("测试失败：\(error)"); exit(1) }
            print("通过：常醒策略组合。")
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
