import AppKit
import SwiftUI
import ServiceManagement

// ============================================================
// 状态与尺寸
// ============================================================

enum IslandMode { case collapsed, peek, expanded, approval, alert }

enum IslandTab: String, CaseIterable, Identifiable {
    case quota = "额度", agents = "智能体", tools = "工具", awake = "常醒"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .quota: return "gauge.with.dots.needle.67percent"
        case .agents: return "sparkles"
        case .tools: return "square.grid.2x2"
        case .awake: return "bolt.badge.clock"
        }
    }
}

final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .collapsed
    @Published var tab: IslandTab = IslandTab(rawValue: UserDefaults.standard.string(forKey: "island.tab") ?? "") ?? .quota {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "island.tab") }
    }
    @Published var notch = CGSize(width: 185, height: 32)
    @Published var pinned = false          // 固定展开：鼠标移开也不收起

    static let flare: CGFloat = 8          // 顶部两侧向外翻的圆角
    @Published var alertRows = 1
    static let canvas = CGSize(width: 760, height: 440)

    func size(_ mode: IslandMode) -> CGSize {
        switch mode {
        case .collapsed: return CGSize(width: notch.width, height: notch.height)   // 收起时与刘海重合，不显示两侧胶囊
        case .peek: return CGSize(width: max(540, notch.width + 340), height: notch.height + 80)
        case .expanded: return CGSize(width: 700, height: notch.height + 330)
        case .approval: return CGSize(width: 580, height: notch.height + 178)
        case .alert: return CGSize(width: 520, height: notch.height + 64 + CGFloat(min(alertRows, 6)) * 40)
        }
    }
    var size: CGSize { size(mode) }
    var bottomRadius: CGFloat { mode == .collapsed ? 10 : 26 }
}

struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// ============================================================
// 根视图
// ============================================================

struct Stores {
    let island: IslandModel
    let quota: QuotaStore
    let agents: AgentMonitor
    let awake: AwakeController
    let approvals: ApprovalCenter
    let tokens: TokenStore
    let proxy: ProxyStore
    let tools: ToolStore
    var approvalReady = false
}

struct IslandRoot: View {
    let stores: Stores
    @ObservedObject var model: IslandModel

    init(stores: Stores) { self.stores = stores; self.model = stores.island }

    var body: some View {
        let size = model.size
        let shape = NotchShape(top: IslandModel.flare, bottom: model.bottomRadius)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(model.mode == .collapsed ? 0 : 0.5), radius: 22, y: 10)
            content
                .frame(width: size.width - IslandModel.flare * 2, height: size.height, alignment: .top)
                .clipShape(Rectangle())
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .onTapGesture { if model.mode == .collapsed || model.mode == .peek { model.mode = .expanded } }
        .contextMenu { IslandMenu(stores: stores) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder var content: some View {
        switch model.mode {
        case .collapsed:
            Color.clear
        case .peek:
            PeekView(stores: stores, quota: stores.quota, agents: stores.agents, awake: stores.awake, model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .expanded:
            ExpandedView(stores: stores, model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .approval:
            ApprovalView(center: stores.approvals, model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        case .alert:
            QuotaAlertView(quota: stores.quota, model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

struct IslandMenu: View {
    let stores: Stores
    var body: some View {
        Button("刷新数据") { Task { await stores.quota.refresh() }; stores.tokens.refresh(force: true); stores.proxy.refresh() }
        Button(SMAppService.mainApp.status == .enabled ? "✓ 登录后自动启动" : "登录后自动启动") {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            else { try? SMAppService.mainApp.register() }
        }
        Divider()
        Button("退出 NotchHub") { NSApp.terminate(nil) }
    }
}

// ============================================================
// 通用小部件
// ============================================================

struct Pulse: View {
    let color: Color
    var size: CGFloat = 7
    var active = true
    @State private var on = false
    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.45)).frame(width: size, height: size)
                    .scaleEffect(on ? 2.1 : 1).opacity(on ? 0 : 1)
            }
            Circle().fill(active ? color : color.opacity(0.35)).frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct MiniRing: View {
    let fraction: Double
    let color: Color
    var width: CGFloat = 2.5
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: width)
            Circle().trim(from: 0, to: min(1, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .opacity(fraction > 0.005 ? 1 : 0)
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

struct Card<Content: View>: View {
    var highlight: Color? = nil
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight?.opacity(0.7) ?? Color.white.opacity(0.06), lineWidth: 1))
    }
}

extension Font {
    static func island(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// ============================================================
// 悬停：速览
// ============================================================

struct PeekView: View {
    let stores: Stores
    @ObservedObject var quota: QuotaStore
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var awake: AwakeController
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: model.notch.height - 4)
            HStack(spacing: 6) {
                ForEach(quota.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(item.color).frame(width: 5, height: 5)
                            Text(item.name).font(.island(10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Text(item.value).font(.island(14, .semibold)).monospacedDigit()
                            .foregroundStyle(item.low ? Palette.warn : .white).lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 12) {
                ForEach(agents.agents) { a in
                    HStack(spacing: 3) {
                        Pulse(color: a.color, size: 5, active: a.state == .working).opacity(a.state == .off ? 0.4 : 1)
                        Text(a.name).font(.island(10.5)).foregroundStyle(.white.opacity(a.state == .off ? 0.35 : 0.75))
                    }
                }
                Spacer()
                Text(awake.alwaysOn ? (awake.alwaysOnUntil.map { "不息屏剩余 " + AwakeTab.clock($0.timeIntervalSinceNow) } ?? "不息屏常醒中")
                     : awake.remainingShort.map { "常醒剩余 " + $0 } ?? (awake.systemHeld ? "接电常醒中" : "常醒关闭"))
                    .font(.island(10.5)).foregroundStyle(awake.deadline != nil ? Palette.warn : .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
    }
}

// ============================================================
// 展开：四个标签页
// ============================================================

struct ExpandedView: View {
    let stores: Stores
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(IslandTab.allCases) { tab in
                        Button { model.tab = tab } label: {
                            HStack(spacing: 4) {
                                Image(systemName: tab.symbol).font(.system(size: 10, weight: .semibold))
                                Text(tab.rawValue).font(.island(11.5, .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.16) : .clear))
                            .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: model.notch.width + 8)
                HeaderActions(stores: stores, quota: stores.quota, model: model)
            }
            .frame(height: model.notch.height)
            .padding(.horizontal, 12)

            Group {
                switch model.tab {
                case .quota: QuotaTab(quota: stores.quota)
                case .agents: AgentsTab(stores: stores, agents: stores.agents, tokens: stores.tokens, proxy: stores.proxy, approvals: stores.approvals)
                case .tools: ToolsTab(tools: stores.tools)
                case .awake: AwakeTab(awake: stores.awake)
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct HeaderActions: View {
    let stores: Stores
    @ObservedObject var quota: QuotaStore
    @ObservedObject var model: IslandModel
    @State private var spin = false
    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await quota.refresh() }; stores.tokens.refresh(force: true); stores.proxy.refresh()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(quota.refreshing ? 360 : 0))
                    .animation(quota.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: quota.refreshing)
            }
            .buttonStyle(.plain).help("刷新")
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.pinned ? Palette.warn : .white.opacity(0.6))
            }
            .buttonStyle(.plain).help(model.pinned ? "取消固定" : "固定展开")
            Button { model.pinned = false; model.mode = .collapsed } label: {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).help("收起")
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

// MARK: 额度

struct QuotaTab: View {
    @ObservedObject var quota: QuotaStore
    @State private var editing = UserDefaults.standard.bool(forKey: "editAlerts")   // 调试：-editAlerts YES
    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    var body: some View {
        VStack(spacing: 10) {
            if editing {
                AlertSettings(quota: quota).frame(height: 234)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(quota.items) { item in
                        Button { if let url = item.url { NSWorkspace.shared.open(url) } } label: { QuotaTile(item: item, rule: quota.rule(item.id)) }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                let lows = quota.items.filter(\.low)
                if lows.isEmpty {
                    Label("额度都充足", systemImage: "checkmark.circle").foregroundStyle(Palette.ok.opacity(0.8))
                } else {
                    Label(lows.map(\.name).joined(separator: "、") + " 额度偏低", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
                }
                Spacer()
                Text(quota.lastCheck.map { "检查于 " + DateFormatter.hm.string(from: $0) + " · 每 5 分钟刷新" } ?? "正在读取…")
                    .foregroundStyle(.white.opacity(0.35))
                Button { quota.promptAPIKeys() } label: {
                    Label("API Key", systemImage: "key")
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                Button { editing.toggle() } label: {
                    Label(editing ? "完成" : "提醒设置", systemImage: editing ? "checkmark" : "bell.badge")
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(editing ? 0.2 : 0.1)))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .font(.island(10.5))
        }
    }
}

struct AlertSettings: View {
    @ObservedObject var quota: QuotaStore
    let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("低于提醒线时，灵动岛会弹出提醒（每次跌破只提醒一次，回升后重新生效）")
                .font(.island(10.5)).foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(quota.items) { item in row(item) }
            }
        }
    }
    func row(_ item: QuotaItem) -> some View {
        let unit = QuotaUnit.of(item.id)
        let rule = Binding(get: { quota.rule(item.id) }, set: { quota.rules[item.id] = $0 })
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.island(12.5, .medium))
                Text("当前 " + item.value).font(.island(9.5)).foregroundStyle(item.low ? Palette.warn : .white.opacity(0.4))
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                stepButton("minus") { rule.wrappedValue.threshold = max(0, rule.wrappedValue.threshold - unit.step) }
                Text("低于 " + unit.text(rule.wrappedValue.threshold)).font(.island(11, .medium)).monospacedDigit()
                    .frame(minWidth: 78).foregroundStyle(rule.wrappedValue.enabled ? .white : .white.opacity(0.35))
                stepButton("plus") { rule.wrappedValue.threshold = min(unit.maxValue, rule.wrappedValue.threshold + unit.step) }
            }
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .disabled(!rule.wrappedValue.enabled)
            Toggle("", isOn: rule.enabled).toggleStyle(IslandSwitch(tint: Palette.warn)).frame(width: 40)
        }
        .padding(.horizontal, 10).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
    func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
    }
}

struct QuotaTile: View {
    let item: QuotaItem
    var rule: AlertRule? = nil
    var body: some View {
        Card(highlight: item.low ? Palette.warn : nil) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3, height: 12)
                    Text(item.name).font(.island(12, .medium)).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if item.stale { Text("旧").font(.island(9, .bold)).foregroundStyle(.white.opacity(0.4)) }
                    if let rule, rule.enabled {
                        Label(QuotaUnit.of(item.id).text(rule.threshold), systemImage: "bell")
                            .font(.island(9.5)).foregroundStyle(item.low ? Palette.warn : .white.opacity(0.35))
                    }
                }
                Text(item.value).font(.island(24, .semibold)).monospacedDigit()
                    .foregroundStyle(item.low ? Palette.warn : .white).lineLimit(1).minimumScaleFactor(0.6)
                if let f = item.fraction { Bar(fraction: f, color: item.low ? Palette.warn : item.color) }
                Text(item.detail).font(.island(10)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
        }
        .frame(height: 112)
        .contentShape(Rectangle())
    }
}

extension DateFormatter {
    static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
}

// MARK: 智能体 HUD

struct AgentsTab: View {
    let stores: Stores
    @ObservedObject var agents: AgentMonitor
    @ObservedObject var tokens: TokenStore
    @ObservedObject var proxy: ProxyStore
    @ObservedObject var approvals: ApprovalCenter

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("智能体").font(.island(11, .medium)).foregroundStyle(.white.opacity(0.5))
                        ForEach(agents.agents) { a in
                            HStack(spacing: 8) {
                                Pulse(color: a.color, size: 7, active: a.state == .working).opacity(a.state == .off ? 0.35 : 1)
                                Text(a.name).font(.island(13, .medium)).foregroundStyle(.white.opacity(a.state == .off ? 0.4 : 0.92))
                                Spacer()
                                Text(a.state == .working && a.sessions > 1 ? "\(a.sessions) 个会话" : a.stateText)
                                    .font(.island(10.5)).foregroundStyle(a.state == .working ? a.color : .white.opacity(0.4))
                            }
                        }
                    }
                }
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: stores.approvalReady ? "checkmark.shield.fill" : "shield.slash")
                            .foregroundStyle(stores.approvalReady ? Palette.ok : Palette.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stores.approvalReady ? "审批通道就绪" : "审批通道未启动").font(.island(12, .medium))
                            Text(stores.approvalReady ? "已处理 \(approvals.history.count) 次 · 允许 \(approvals.history.filter { $0 == "allowed-once" }.count)"
                                 : "另一个 Agent HUD 正在占用通道").font(.island(10)).foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                    }
                }
                .frame(height: 58)
            }
            .frame(width: 250)

            VStack(spacing: 10) {
                Card { TokenPanel(data: tokens.data, error: tokens.error) }
                Card { ProxyRow(info: proxy.info, live: proxy.live) }.frame(height: 58)
            }
        }
    }
}

struct TokenPanel: View {
    let data: TokenData?
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("24 小时 Token").font(.island(11, .medium)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let data { Text(rateText(data.lastHour, data.prevHour)).font(.island(10)).foregroundStyle(.white.opacity(0.4)) }
            }
            if let data {
                let claude = data.claudeTotal24h ?? 0
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(compactTokens(data.dshTotal24h + data.codexTotal24h + claude)).font(.island(26, .semibold)).monospacedDigit()
                    legend("Claude", Palette.claude, claude)
                    legend("Codex", Palette.codex, data.codexTotal24h)
                    legend("DSH", Palette.dsh, data.dshTotal24h)
                }
                GeometryReader { g in
                    let hours = data.hours
                    let w = g.size.width / CGFloat(max(1, hours.count))
                    let scale = g.size.height / data.maxHour
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(hours) { h in
                            VStack(spacing: 1) {
                                Spacer(minLength: 0)
                                segment(Palette.dsh, h.dsh * scale)
                                segment(Palette.codex, h.codex * scale)
                                segment(Palette.claude, h.claude * scale)
                                if h.total <= 0 { RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.1)).frame(height: 2) }
                            }
                            .frame(width: max(1, w - 3)).frame(width: w)
                        }
                    }
                }
                HStack {
                    Text("24 小时前"); Spacer(); Text("现在")
                }
                .font(.island(9)).foregroundStyle(.white.opacity(0.3))
            } else {
                Spacer()
                Text(error ?? "正在采集 DSH / Codex 会话…").font(.island(12)).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
        }
    }
    @ViewBuilder func segment(_ color: Color, _ height: CGFloat) -> some View {
        if height > 0.5 { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(height: max(1.5, height)) }
    }
    func legend(_ name: String, _ color: Color, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).foregroundStyle(.white.opacity(0.5))
            Text(compactTokens(value)).foregroundStyle(.white.opacity(0.85)).monospacedDigit()
        }
        .font(.island(11))
    }
}

struct ProxyRow: View {
    let info: ProxyInfo?
    let live: ProxyLive?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(live == nil ? .white.opacity(0.35) : Palette.workbuddy)
            VStack(alignment: .leading, spacing: 2) {
                Text(live?.node.isEmpty == false ? live!.node : (info?.node.isEmpty == false ? info!.node : "代理未连接"))
                    .font(.island(12, .medium)).lineLimit(1)
                Text([live.map { $0.modeName + ($0.tun ? " · TUN" : "") }, live?.delay.map { "\($0) ms" }]
                        .compactMap { $0 }.joined(separator: " · ").ifEmpty("Clash Verge"))
                    .font(.island(10)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            if let info {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "剩余 %.0f GB", info.remainingGB)).font(.island(11, .medium)).monospacedDigit()
                    Bar(fraction: info.remainingFraction, color: info.remainingFraction < 0.15 ? Palette.warn : Palette.workbuddy).frame(width: 90)
                }
            }
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: 工具

struct ToolsTab: View {
    @ObservedObject var tools: ToolStore
    @State private var editing = UserDefaults.standard.bool(forKey: "editTools")   // 调试：-editTools YES
    let columns = [GridItem(.adaptive(minimum: 84, maximum: 100), spacing: 8)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(tools.tools) { item in
                    Button { if !editing { tools.launch(item) } } label: {
                        ToolTile(name: item.name, sub: item.kind == .command ? item.target : nil, wiggle: editing) { Image(nsImage: item.icon).resizable() }
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topLeading) {
                        if editing {
                            Button { withAnimation(.spring(response: 0.3)) { tools.remove(item) } } label: {
                                Image(systemName: "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(Circle().fill(Color.red))
                                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 2))
                            }
                            .buttonStyle(.plain).offset(x: -6, y: -6).help("从常用里移除（不会卸载应用）")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if editing {
                            HStack(spacing: 18) {
                                arrow("chevron.left") { tools.move(item, by: -1) }
                                arrow("chevron.right") { tools.move(item, by: 1) }
                            }
                            .offset(y: -7)
                        }
                    }
                    .contextMenu {
                        Button("左移") { tools.move(item, by: -1) }
                        Button("右移") { tools.move(item, by: 1) }
                        Divider()
                        Button("移除「\(item.name)」") { tools.remove(item) }
                    }
                }
                if !editing {
                    Button { AddMenu.show(tools) } label: {
                        ToolTile(name: "添加", sub: nil) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                                Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.spring(response: 0.3), value: tools.tools)
            Spacer()
            HStack {
                Text(editing ? "点红色 − 从常用里移除（不会卸载应用）· 箭头调整顺序" : "点击打开 · 右键也可调整顺序或移除")
                    .font(.island(10.5)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                if editing {
                    Button("恢复默认") { withAnimation { tools.resetDefaults() } }.buttonStyle(PillButton())
                }
                Button { withAnimation(.spring(response: 0.3)) { editing.toggle() } } label: {
                    Label(editing ? "完成" : "编辑", systemImage: editing ? "checkmark" : "slider.horizontal.3")
                }
                .buttonStyle(PillButton(selected: editing))
            }
        }
    }
    func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 20, height: 16).background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// 「添加」弹出菜单：直接用 NSMenu，SwiftUI Menu 会丢掉磁贴样式。
final class AddMenu: NSObject {
    static let shared = AddMenu()
    private var tools: ToolStore?
    @MainActor static func show(_ tools: ToolStore) {
        shared.tools = tools
        let menu = NSMenu()
        let app = NSMenuItem(title: "添加应用…", action: #selector(addApp), keyEquivalent: "")
        let cmd = NSMenuItem(title: "添加终端命令…", action: #selector(addCommand), keyEquivalent: "")
        [app, cmd].forEach { $0.target = shared; menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @MainActor @objc func addApp() { tools?.promptAddApp() }
    @MainActor @objc func addCommand() { tools?.promptAddCommand() }
}

struct ToolTile<Icon: View>: View {
    let name: String
    let sub: String?
    var wiggle = false
    @ViewBuilder let icon: Icon
    @State private var hover = false
    @State private var tilt = false
    var body: some View {
        VStack(spacing: 6) {
            icon.frame(width: 46, height: 46)
            Text(name).font(.island(11, .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if let sub { Text(sub).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).lineLimit(1) }
        }
        .padding(.bottom, wiggle ? 22 : 0)
        .frame(width: 84, height: wiggle ? 114 : 92)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.1 : 0.04)))
        .scaleEffect(hover && !wiggle ? 1.04 : 1)
        .rotationEffect(.degrees(wiggle ? (tilt ? 1.6 : -1.6) : 0))
        .animation(.easeOut(duration: 0.15), value: hover)
        .onChange(of: wiggle) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { tilt = true } }
            else { withAnimation(.easeOut(duration: 0.1)) { tilt = false } }
        }
        .onAppear { if wiggle { withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) { tilt = true } } }
        .onHover { hover = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: 常醒

struct AwakeTab: View {
    @ObservedObject var awake: AwakeController
    let presets = [(30, "30 分钟"), (60, "1 小时"), (120, "2 小时"), (240, "4 小时")]

    var body: some View {
        HStack(spacing: 12) {
            Card(highlight: awake.deadline != nil ? Palette.warn : nil) {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ZStack {
                            let screenTimer = awake.alwaysOnUntil
                            let active = screenTimer ?? awake.deadline
                            let total = screenTimer != nil ? awake.alwaysOnTotal : awake.timedTotal
                            let fraction = active.map { max(0, $0.timeIntervalSinceNow) / max(1, total) } ?? (awake.systemHeld ? 1 : 0)
                            MiniRing(fraction: fraction, color: screenTimer != nil || (awake.alwaysOn && active == nil) ? Palette.workbuddy : awake.deadline != nil ? Palette.warn : Palette.ok, width: 7)
                            VStack(spacing: 2) {
                                if let active {
                                    Text(Self.clock(active.timeIntervalSinceNow)).font(.island(22, .semibold)).monospacedDigit()
                                    Text(screenTimer != nil ? "不息屏剩余" : "常醒剩余").font(.island(10)).foregroundStyle(.white.opacity(0.45))
                                } else {
                                    Image(systemName: awake.displayHeld ? "sun.max.fill" : awake.systemHeld ? "bolt.fill" : "moon.zzz").font(.system(size: 24))
                                        .foregroundStyle(awake.displayHeld ? Palette.workbuddy : awake.systemHeld ? Palette.ok : .white.opacity(0.4))
                                    Text(awake.displayHeld ? "屏幕常亮" : awake.systemHeld ? "保持唤醒" : "系统原策略").font(.island(10)).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                        .frame(width: 128, height: 128)
                    }
                    Text(awake.statusText).font(.island(10.5)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 210)

            Card {
                VStack(alignment: .leading, spacing: 11) {
                    Toggle(isOn: $awake.enabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("接电常醒").font(.island(13, .medium))
                            Text("接通电源时阻止闲置休眠，拔电即恢复").font(.island(10)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .toggleStyle(IslandSwitch())

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(get: { awake.alwaysOn }, set: { awake.setAlwaysOn($0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("不息屏常醒").font(.island(13, .medium))
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Text(awake.alwaysOn ? (awake.alwaysOnUntil.map { "剩余 " + Self.clock($0.timeIntervalSinceNow) + " · 到点自动关闭" } ?? "不限时 · 手动关闭")
                                         : "断电也保持唤醒、屏幕不熄灭 · 电量低于 15% 自动停止")
                                        .font(.island(10)).monospacedDigit()
                                        .foregroundStyle(awake.alwaysOn ? Palette.workbuddy : .white.opacity(0.4))
                                }
                            }
                        }
                        .toggleStyle(IslandSwitch(tint: Palette.workbuddy))
                        HStack(spacing: 6) {
                            ForEach(presets + [(0, "不限时")], id: \.0) { minutes, title in
                                Button(title) { awake.startAlwaysOn(minutes: minutes) }
                                    .buttonStyle(PillButton(selected: awake.alwaysOn && awake.alwaysOnMinutes == minutes))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("定时常醒 · 电池供电也有效").font(.island(11, .medium)).foregroundStyle(.white.opacity(0.6))
                        HStack(spacing: 6) {
                            ForEach(presets, id: \.0) { minutes, title in
                                Button(title) { awake.startTimed(minutes: minutes) }.buttonStyle(PillButton())
                            }
                            Button("自定义") { Self.askCustom(awake) }.buttonStyle(PillButton())
                            if awake.deadline != nil {
                                Button("取消") { awake.stopTimed() }.buttonStyle(PillButton(tint: Palette.warn))
                            }
                        }
                    }

                    Toggle(isOn: Binding(get: { awake.lidSwitch }, set: { awake.setLid($0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("合盖不休眠").font(.island(12.5, .medium))
                            Text(awake.lidDetail)
                                .font(.island(10)).foregroundStyle(awake.lidSwitch ? Palette.warn : .white.opacity(0.4))
                        }
                    }
                    .toggleStyle(IslandSwitch(tint: Palette.warn))

                    HStack(spacing: 6) {
                        Text("屏幕").font(.island(11, .medium)).foregroundStyle(.white.opacity(0.6))
                        Button("按原设置熄灭") { awake.mode = .displayMaySleep }.buttonStyle(PillButton(selected: awake.mode == .displayMaySleep))
                        Button("持续亮屏 + 移动时钟") { awake.mode = .displayStaysOn }.buttonStyle(PillButton(selected: awake.mode == .displayStaysOn))
                        Spacer()
                        Button("预览时钟") { awake.previewClock() }.buttonStyle(.plain).font(.island(10.5)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    @MainActor static func askCustom(_ awake: AwakeController) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "定时常醒"
        alert.informativeText = "保持唤醒多少分钟？（1–1440）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "例如 90"
        alert.accessoryView = field
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let minutes = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...1440).contains(minutes) else {
            let bad = NSAlert(); bad.messageText = "时长无效"; bad.informativeText = "请输入 1 到 1440 之间的整数分钟。"; bad.runModal()
            return
        }
        awake.startTimed(minutes: minutes)
    }
}

struct IslandSwitch: ToggleStyle {
    var tint: Color = Palette.ok
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center) {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? tint : Color.white.opacity(0.16)).frame(width: 34, height: 20)
                Circle().fill(.white).frame(width: 16, height: 16).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

struct PillButton: ButtonStyle {
    var tint: Color? = nil
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.island(11, .medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : (tint ?? .white).opacity(configuration.isPressed ? 0.25 : 0.1)))
            .foregroundStyle(tint ?? .white.opacity(selected ? 1 : 0.8))
            .contentShape(Capsule())
    }
}

// ============================================================
// 额度提醒卡
// ============================================================

struct QuotaAlertView: View {
    @ObservedObject var quota: QuotaStore
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: model.notch.height - 6)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn)
                Text("额度提醒").font(.island(13.5, .semibold))
                Text("\(quota.alerts.count) 项低于提醒线").font(.island(12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            ForEach(quota.alerts.prefix(6)) { item in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3, height: 14)
                    Text(item.name).font(.island(12.5, .medium)).frame(width: 84, alignment: .leading)
                    Text(item.value).font(.island(15, .semibold)).monospacedDigit().foregroundStyle(Palette.warn)
                    Text("提醒线 " + QuotaUnit.of(item.id).text(quota.rule(item.id).threshold)).font(.island(10.5)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if let url = item.url {
                        Button("去看看") { NSWorkspace.shared.open(url) }.buttonStyle(PillButton())
                    }
                }
                .frame(height: 32)
            }
            HStack {
                Text("可在「额度 → 提醒设置」里调整").font(.island(10)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button("知道了") { quota.alerts = []; model.mode = .collapsed }.buttonStyle(PillButton(selected: true))
            }
        }
        .padding(.horizontal, 18)
    }
}

// ============================================================
// 审批卡
// ============================================================

struct ApprovalView: View {
    @ObservedObject var center: ApprovalCenter
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: model.notch.height - 6)
            if let req = center.pending {
                HStack(spacing: 8) {
                    Pulse(color: Palette.warn, size: 7)
                    Text(req.agent).font(.island(13, .semibold))
                    Text("请求执行 \(req.tool)").font(.island(13)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(max(0, Int(req.expires.timeIntervalSinceNow))) 秒").font(.island(11)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                    }
                }
                ScrollView {
                    Text(req.command.isEmpty ? "（无命令内容）" : req.command)
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(10)
                .frame(height: 62)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                if !req.reason.isEmpty && req.reason != req.command {
                    Text(req.reason).font(.island(11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button { center.decide("rejected") } label: {
                        Text("拒绝").font(.island(12.5, .semibold)).frame(width: 92, height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Button { center.decide("allowed-once") } label: {
                        Text("允许一次").font(.island(12.5, .semibold)).foregroundStyle(.black).frame(width: 110, height: 30)
                            .background(Capsule().fill(Palette.ok))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
    }
}
