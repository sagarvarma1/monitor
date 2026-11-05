import AppKit
import SwiftUI
import SwitchboardCore

/// Behind-window blur that stays "active" even though the app never is. Pre-Tahoe fallback for Liquid Glass.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .blocked: return Color(red: 0.95, green: 0.27, blue: 0.25)
        case .review: return Color(red: 0.98, green: 0.76, blue: 0.18)
        case .working: return Color(red: 0.25, green: 0.80, blue: 0.40)
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a HUD blur with a hairline edge before that.
    @ViewBuilder
    func glassSurface(_ shape: RoundedRectangle, tint: Color?, interactive: Bool) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(ZStack { VisualEffect(); tint ?? .clear })
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14)))
        }
    }
}

// MARK: - Root

private struct ModeSizeKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Reports this view's ideal size under a mode key, so the glass can size itself to the incoming
    /// content only (an outgoing view still occupies layout space while it fades).
    func reportSize(_ key: String) -> some View {
        fixedSize().background(GeometryReader { Color.clear.preference(key: ModeSizeKey.self, value: [key: $0.size]) })
    }
}

/// One glass surface that morphs between a pill, a peek (one session that just needs you) and the full list.
struct PanelRoot: View {
    /// Transparent margin around the glass so its shadow and press bounce aren't clipped by the window.
    static let margin: CGFloat = 12
    /// Widest the glass gets (the expanded list); the window is sized to fit it.
    static let maxWidth: CGFloat = 340

    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject var setup: Setup
    var onFocus: (String) -> Void
    var onDecide: (String, PermissionDecision) -> Void
    var onReply: (String, String) -> Void
    /// The glass's resting size, so the window can hit-test (and detect hover) against it.
    var onSize: (CGSize) -> Void

    @State private var sizes: [String: CGSize] = [:]
    @State private var glassSize: CGSize = .zero

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    private var mode: UIState.Mode {
        // A peek for a session that has since gone away falls back to the pill.
        if case .peek(let id) = ui.mode, !store.sessions.contains(where: { $0.id == id }) { return .compact }
        return ui.mode
    }

    var body: some View {
        let mode = self.mode
        let corner = ui.corner
        let shape = RoundedRectangle(cornerRadius: mode == .compact ? glassSize.height / 2 : 20, style: .continuous)
        Color.clear
            .frame(width: glassSize.width, height: glassSize.height)
            .overlay(alignment: corner.alignment) {
                ZStack(alignment: corner.alignment) { content(mode) }
            }
            .clipShape(shape)
            .glassSurface(shape, tint: tint(mode), interactive: mode != .expanded)
            .animation(Self.spring, value: mode)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .onPreferenceChange(ModeSizeKey.self) { sizes = $0; resize(mode) }
            .onChange(of: mode) { resize($0) }
    }

    @ViewBuilder
    private func content(_ mode: UIState.Mode) -> some View {
        let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.94, anchor: ui.corner.unitPoint))
        switch mode {
        case .compact:
            CompactPill(store: store, unseen: ui.unseenDone)
                .reportSize(mode.key)
                .onTapGesture { ui.pinned = true }
                .transition(transition)
        case .peek(let id):
            if let session = store.sessions.first(where: { $0.id == id }) {
                PeekView(session: session, onDecide: { onDecide(id, $0) })
                    .reportSize(mode.key)
                    .onTapGesture { ui.endPeek(); onFocus(id) }
                    .transition(transition)
            }
        case .done(let ids):
            let sessions = ids.compactMap { id in store.sessions.first { $0.id == id } }
            if !sessions.isEmpty {
                let last = sessions[sessions.count - 1]
                DoneFlash(sessions: sessions,
                          onReply: store.replyable.contains(last.id) ? { ui.endDone(); ui.replyingID = last.id } : nil)
                    .reportSize(mode.key)
                    .onTapGesture {
                        ui.endDone()
                        if let last = sessions.last { ui.unseenDone.remove(last.id); onFocus(last.id) }
                    }
                    .transition(transition)
            }
        case .expanded:
            ExpandedPanel(store: store, ui: ui, setup: setup, onFocus: onFocus, onDecide: onDecide, onReply: onReply)
                .reportSize(mode.key)
                .transition(transition)
        }
    }

    private func resize(_ mode: UIState.Mode) {
        guard let target = sizes[mode.key], target != glassSize else { return }
        withAnimation(Self.spring) { glassSize = target }
        onSize(target)
    }

    /// Color the glass only when it carries meaning: red while something is blocked on you.
    private func tint(_ mode: UIState.Mode) -> Color? {
        switch mode {
        case .peek(let id):
            let status = store.sessions.first { $0.id == id }?.status
            return status == .blocked ? SessionStatus.blocked.color.opacity(0.22) : nil
        case .compact:
            return store.blockedCount > 0 ? SessionStatus.blocked.color.opacity(0.16) : nil
        case .done:
            return SessionStatus.review.color.opacity(0.14)
        case .expanded:
            return nil
        }
    }
}

// MARK: - Pill

struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 7
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status.color.opacity(status == .blocked ? 0.8 : 0), radius: 3)
            .opacity(status == .blocked && dim ? 0.45 : 1)
            .onAppear {
                guard status == .blocked else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct CompactPill: View {
    @ObservedObject var store: SessionStore
    var unseen: Set<String> = []
    private let maxDots = 6

    var body: some View {
        let sessions = store.sessions
        HStack(spacing: 8) {
            if store.serverError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SessionStatus.blocked.color)
                    .help(store.serverError ?? "")
            }
            if sessions.isEmpty {
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 3) {
                    ForEach(sessions.prefix(maxDots)) { session in
                        StatusDot(status: session.status)
                            .id("\(session.id)-\(session.status)")
                            .overlay(unseen.contains(session.id) ? UnseenRing() : nil)
                    }
                    if sessions.count > maxDots {
                        Text("+\(sessions.count - maxDots)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
            Text(label).font(.system(size: 12, weight: .semibold))
            if let since = oldestWait {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(IdleMath.format(context.date.timeIntervalSince(since)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        .contentShape(Rectangle())
        .help("Hover to see sessions, click to keep open")
    }

    /// The most urgent color wins: "2 need you" beats "1 to review" beats "3 working".
    private var label: String {
        let blocked = store.blockedCount
        let review = store.sessions.filter { $0.status == .review }.count
        if blocked > 0 { return "\(blocked) need\(blocked == 1 ? "s" : "") you" }
        if review > 0 { return "\(review) to review" }
        if !store.sessions.isEmpty { return "\(store.sessions.count) working" }
        return "No sessions"
    }

    /// Longest wait among sessions of the most urgent color (sessions are already sorted that way).
    private var oldestWait: Date? {
        guard let top = store.sessions.first, top.status.isWaiting else { return nil }
        return top.waitingSince
    }
}

/// A thin ring around a finished session's dot until you've looked at it.
struct UnseenRing: View {
    var body: some View {
        Circle()
            .strokeBorder(SessionStatus.review.color.opacity(0.9), lineWidth: 1.2)
            .padding(-3)
            .transition(.scale(scale: 1.6).combined(with: .opacity))
    }
}

// MARK: - Done flash

/// "api-server is done": the pill widens a little, a band of light sweeps once across the glass, then it settles.
/// No sound and no banner; the dot keeps a ring afterwards so it can't be missed.
struct DoneFlash: View {
    let sessions: [Session]
    /// Set when the (latest) finished session can take a reply from the pill.
    var onReply: (() -> Void)?
    @State private var checkIn = false
    @State private var sweep: CGFloat = -1

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SessionStatus.review.color)
                .scaleEffect(checkIn ? 1 : 0.4)
                .opacity(checkIn ? 1 : 0)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("ready for review")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if let onReply {
                Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left.fill") }
                    .buttonStyle(DecisionButtonStyle(fill: nil))
                    .help("Reply without leaving what you're doing")
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .overlay(sheen)
        .contentShape(Rectangle())
        .help("Click to open")
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.12)) { checkIn = true }
            withAnimation(.easeInOut(duration: 1.1).delay(0.2)) { sweep = 1.4 }
        }
    }

    private var title: String {
        guard sessions.count > 1 else { return "\(sessions[0].name) is done" }
        return "\(sessions.count) sessions done"
    }

    /// One soft diagonal band of light crossing the glass, like light catching it.
    private var sheen: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.38), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45)
                .rotationEffect(.degrees(18))
                .offset(x: sweep * geo.size.width)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Peek

/// What a session that just turned red (or finished) needs, shown for a few seconds. Click to jump to it.
struct PeekView: View {
    let session: Session
    var onDecide: (PermissionDecision) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: session.status, size: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let branch = session.branch, !branch.isEmpty {
                        Text(branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    if let since = session.waitingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(IdleMath.format(context.date.timeIntervalSince(since)))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(session.need)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if session.decisionID != nil {
                    ApprovalDetail(text: session.detail).padding(.top, 2)
                    DecisionButtons(alwaysRule: session.alwaysRule, onDecide: onDecide).padding(.top, 4)
                } else {
                    Text("Click to open")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 300, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Expanded

struct ExpandedPanel: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject var setup: Setup
    var onFocus: (String) -> Void
    var onDecide: (String, PermissionDecision) -> Void
    var onReply: (String, String) -> Void

    /// Header, footer and a notice; whatever is left of the room from the pill's corner goes to the list.
    private let chrome: CGFloat = 120
    private let rowHeight: CGFloat = 46
    private var listHeight: CGFloat { max(rowHeight * 2, ui.maxHeight - chrome) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.serverError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(SessionStatus.blocked.color)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            setupNotice
            if store.sessions.isEmpty {
                VStack(spacing: 4) {
                    Text("No active Claude Code sessions").font(.system(size: 12))
                    Text("Sessions appear here once their hooks fire").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else if CGFloat(store.sessions.count) * rowHeight > listHeight {
                ScrollView(.vertical) { rows }.frame(height: listHeight)
            } else {
                rows
            }
            footer
        }
        .frame(width: PanelRoot.maxWidth)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(store.sessions) { session in
                SessionRow(session: session, expanded: ui.expandedID == session.id,
                           onTap: { toggle(session.id) },
                           onFocus: { onFocus(session.id) },
                           onDismiss: { store.dismiss(session.id) },
                           onDetails: { ui.pinned = false; ui.openDashboard?(session.id) },
                           onDecide: { onDecide(session.id, $0) },
                           reply: store.replyable.contains(session.id)
                               ? ReplyState(open: ui.replyingID == session.id,
                                            onOpen: { ui.replyingID = session.id },
                                            onSend: { onReply(session.id, $0) },
                                            onCancel: { ui.replyingID = nil })
                               : nil)
            }
        }
        .padding(.horizontal, 6)
    }

    private func toggle(_ id: String) {
        withAnimation(PanelRoot.spring) { ui.expandedID = ui.expandedID == id ? nil : id }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Switchboard").font(.system(size: 13, weight: .semibold))
            counts
            Spacer()
            Button {
                ui.pinned.toggle()
            } label: {
                Image(systemName: ui.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(ui.pinned ? "Unpin (collapses when the pointer leaves)" : "Keep open")
            Button {
                ui.pinned = false
                ui.openDashboard?(nil)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("Open the dashboard")
            Menu {
                Button("Open Dashboard") { ui.pinned = false; ui.openDashboard?(nil) }
                Button("Settings…") { ui.pinned = false; ui.openSettings?() }
                Divider()
                Button("Quit Switchboard") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 7)
    }

    /// At most one line about setup, most important first.
    @ViewBuilder
    private var setupNotice: some View {
        if case .invalidSettings(let message) = setup.hooks {
            notice("exclamationmark.triangle.fill", message, color: SessionStatus.blocked.color)
        } else if !setup.hooksEnabled {
            notice("bolt.slash", "Not connected to Claude Code. Turn it on in the ⋯ menu.", color: .secondary)
        } else if setup.loginItem == .requiresApproval {
            noticeButton("person.badge.clock", "Allow Switchboard to open at login", action: setup.openLoginItemSettings)
        } else if setup.restartHint {
            noticeButton("arrow.clockwise", "Connected. Sessions appear on their next action (restart any that don't).") { setup.restartHint = false }
        }
    }

    private func notice(_ icon: String, _ text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .padding(.horizontal, 14).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeButton(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private var counts: some View {
        HStack(spacing: 6) {
            ForEach([SessionStatus.blocked, .review, .working], id: \.self) { status in
                let n = store.sessions.filter { $0.status == status }.count
                if n > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                        Text("\(n)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
            }
        }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                Text("Idle today: \(Int(store.idleToday(now: context.date) / 60)) min")
                Spacer()
                Text("⌥S hides")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 10)
        }
    }
}

struct SessionRow: View {
    let session: Session
    let expanded: Bool
    var onTap: () -> Void
    var onFocus: () -> Void
    var onDismiss: () -> Void
    var onDetails: () -> Void
    var onDecide: (PermissionDecision) -> Void
    /// Set when this finished session can take a reply from the pill.
    var reply: ReplyState?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(status: session.status, size: 8)
                    .id(session.status)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let branch = session.branch, !branch.isEmpty {
                            Text(branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Text(session.need.isEmpty ? " " : session.need)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let since = session.waitingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(IdleMath.format(context.date.timeIntervalSince(since)))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(session.status == .blocked ? session.status.color : .secondary)
                    }
                }
            }
            if session.decisionID != nil {
                ApprovalDetail(text: session.detail).padding(.leading, 16)
                DecisionButtons(alwaysRule: session.alwaysRule, onDecide: onDecide).padding(.leading, 16)
            }
            if expanded { details }
            if let reply {
                Group {
                    if reply.open {
                        ReplyField(onSend: reply.onSend, onCancel: reply.onCancel)
                    } else {
                        Button(action: reply.onOpen) { Label("Reply", systemImage: "arrowshape.turn.up.left.fill") }
                            .buttonStyle(DecisionButtonStyle(fill: nil))
                            .help("Send Claude its next message from here")
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(expanded ? 0.08 : hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.detail.isEmpty {
                ScrollView {
                    Group {
                        if session.detail.hasPrefix("{") || session.detail.contains("\n  \"") {
                            Text(session.detail).font(.system(size: 11, design: .monospaced))  // a tool call's JSON input
                        } else {
                            MarkdownText(source: session.detail)  // Claude's reply
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(session.cwd)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack {
                Button("Go to session", action: onFocus)
                    .controlSize(.small)
                Button("Details", action: onDetails)
                    .controlSize(.small)
                    .help("Activity, tasks and files in the dashboard")
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
                    .help("Remove this row (e.g. if the session was killed without exiting)")
            }
        }
        .padding(.leading, 16)
    }
}

/// Answers a waiting permission prompt. Claude Code's own prompt stays up in the terminal meanwhile;
/// whichever answer comes first wins.
/// The whole request, next to Allow: a one-line summary could hide the part of a command that matters.
/// Hidden characters are shown as visible stand-ins (see SafeText), with a warning when there are any.
struct ApprovalDetail: View {
    let text: String

    var body: some View {
        let revealed = SafeText.reveal(text)
        VStack(alignment: .leading, spacing: 4) {
            if revealed.hiddenCount > 0 { HiddenCharactersWarning(count: revealed.hiddenCount, size: 10.5) }
            ScrollView {
                Text(revealed.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

struct HiddenCharactersWarning: View {
    let count: Int
    var size: CGFloat = 11

    var body: some View {
        Label("\(count) hidden or text-reordering character\(count == 1 ? "" : "s"), shown as ⟨U+…⟩ or ␛. The request may not be what it looks like.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(SessionStatus.review.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DecisionButtons: View {
    var alwaysRule: String?
    var onDecide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            buttons
            if let alwaysRule {
                Text("Always adds: \(alwaysRule)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Deny") { onDecide(.deny) }
                .buttonStyle(DecisionButtonStyle(fill: nil))
                .help("Deny; Claude is told you said no and carries on")
            Button("Allow") { onDecide(.allow) }
                .buttonStyle(DecisionButtonStyle(fill: SessionStatus.working.color))
                .help("Allow this once")
            if alwaysRule != nil {
                Button("Always") { onDecide(.allowAlways) }
                    .buttonStyle(DecisionButtonStyle(fill: nil))
                    .help("Allow, and add the rule shown below so Claude Code stops asking for this")
            }
        }
    }
}

/// System bordered buttons draw as inactive (gray) in a panel that never becomes key, so these draw themselves.
struct DecisionButtonStyle: ButtonStyle {
    let fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fill == nil ? Color.primary : Color.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill ?? Color.primary.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct ReplyState {
    var open: Bool
    var onOpen: () -> Void
    var onSend: (String) -> Void
    var onCancel: () -> Void
}

/// Inline follow-up for a finished session. Return sends, Esc cancels. The text wakes Claude through the
/// session's waiting Stop hook, exactly as if it had been typed in the terminal.
struct ReplyField: View {
    var onSend: (String) -> Void
    var onCancel: () -> Void
    /// The pill wants the cursor in it right away; the dashboard shouldn't grab focus just by showing a session.
    var autofocus = true
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Reply to Claude…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand(perform: onCancel)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08)))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(trimmed.isEmpty ? Color.secondary : SessionStatus.working.color)
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .help("Send (Return)")
        }
        .onAppear {
            // The panel becomes key a beat after the field appears.
            if autofocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
        }
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
    }
}

/// Claude's replies are Markdown: headings, (nested) lists, code blocks and inline styling, laid out compactly
/// for the panel's 11pt text.
struct MarkdownText: View {
    let source: String
    /// Body size; headings and code scale from it. 11 suits the pill, the dashboard reads better larger.
    var size: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.5) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: size))
        .lineSpacing(size > 11 ? 2 : 0)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: size + (level <= 2 ? 1.5 : 0.5), weight: .semibold))
                .padding(.top, 3)
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: marker == "•" ? 8 : 14, alignment: .trailing)
                Text(inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .code(let text):
            Text(text)
                .font(.system(size: size - 0.5, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        case .rule:
            Divider().opacity(0.5).padding(.vertical, 2)
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bold, italic, `code` and links; falls back to the raw text if it doesn't parse. Only web links stay
    /// clickable: a file: or app-scheme link in a reply could open or run something.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in styled.runs {
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                styled[run.range].link = nil
            }
        }
        return styled
    }
}
