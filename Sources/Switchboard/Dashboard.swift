import AppKit
import SwiftUI
import SwitchboardCore
import UniformTypeIdentifiers

/// Which session the dashboard shows; the pill can ask for one.
final class DashboardNav: ObservableObject {
    @Published var selectedID: String?
}

/// Follows one session's transcript, re-reading what's been appended every second while the dashboard shows it.
@MainActor
final class TranscriptModel: ObservableObject {
    @Published private(set) var summary = TranscriptSummary()
    private var reader: TranscriptReader?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "switchboard.transcript")

    func watch(_ path: String) {
        guard reader?.path != path else { return }
        summary = TranscriptSummary()
        reader = TranscriptReader(path: path)
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reader = nil
    }

    private func refresh() {
        guard let reader else { return }
        queue.async {
            let summary = reader.update()  // the first read of a big transcript takes a moment; keep it off main
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reader === reader, self.summary != summary else { return }
                self.summary = summary
            }
        }
    }
}

// MARK: - Shared styling

/// The dashboard's few type and spacing decisions, in one place.
private enum DS {
    static let body: CGFloat = 13
    static let small: CGFloat = 11.5
    static let readable: CGFloat = 760          // longest comfortable line in the feed and composer
    static let inspectorWidth: CGFloat = 280
    static let radius: CGFloat = 12
    static let hairline = Color.primary.opacity(0.08)
    static let fill = Color.primary.opacity(0.045)
}

extension SessionStatus {
    /// How the dashboard groups and labels sessions.
    var title: String {
        switch self {
        case .blocked: return "Needs you"
        case .review: return "Ready for review"
        case .working: return "Working"
        }
    }
}

// MARK: - Window

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var nav: DashboardNav
    var onFocus: (String) -> Void

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, selection: $nav.selectedID)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let session = store.sessions.first(where: { $0.id == nav.selectedID }) {
                SessionDetailView(session: session, store: store, onFocus: onFocus)
            } else {
                EmptyState(icon: store.sessions.isEmpty ? "sparkles.rectangle.stack" : "sidebar.left",
                           title: store.sessions.isEmpty ? "No sessions yet" : "Pick a session",
                           message: store.sessions.isEmpty
                               ? "Start Claude Code in any terminal. Sessions show up here as soon as they do something."
                               : "Choose a session on the left to follow it, answer it, or message it.")
            }
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 520, idealHeight: 700)
        .onAppear(perform: selectFirstIfNeeded)
        // Keep something selected: the first session to arrive, or the next one when the selected one ends.
        .onChange(of: store.sessions.map(\.id)) { _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        guard !store.sessions.contains(where: { $0.id == nav.selectedID }) else { return }
        nav.selectedID = store.sessions.first?.id
    }
}

// MARK: - Sidebar

/// Sessions grouped the way you act on them: what needs you, what's ready to look at, what's still going.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach([SessionStatus.blocked, .review, .working], id: \.self) { status in
                let group = store.sessions.filter { $0.status == status }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { SidebarRow(session: $0).tag($0.id) }
                    } header: {
                        HStack(spacing: 6) {
                            Text(status.title)
                            Text("\(group.count)").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Clear of the traffic lights: the title bar is transparent and the list runs up under it.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 10) }
        .overlay {
            if store.sessions.isEmpty {
                Text("No active sessions").font(.callout).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.system(size: 10))
                Text("Waited on you today: \(IdleMath.format(store.idleToday(now: context.date)))")
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .help("Time sessions spent waiting for you today")
    }
}

struct SidebarRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StatusDot(status: session.status, size: 8).id(session.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.name).font(.system(size: DS.body, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let since = session.waitingSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(IdleMath.format(context.date.timeIntervalSince(since)))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(session.status == .blocked ? session.status.color : .secondary)
                        }
                    }
                }
                Text(session.need).font(.system(size: DS.small)).foregroundStyle(.secondary).lineLimit(2)
                if let branch = session.branch, !branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).lineLimit(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    let session: Session
    @ObservedObject var store: SessionStore
    var onFocus: (String) -> Void
    @StateObject private var transcript = TranscriptModel()
    @AppStorage("detailShowsTerminal") private var showsTerminal = false
    @AppStorage("dashboardInspector") private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if session.decisionID != nil {
                ApprovalCard(session: session) { store.decide(session.id, $0) }
                    .padding(.horizontal, 20).padding(.bottom, 14)
            } else if session.status == .blocked {
                AnswerInTerminalCard(session: session) { onFocus(session.id) }
                    .padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if showsTerminal {
                        TerminalMirrorView(session: session).id(session.id)
                    } else {
                        ActivityFeed(items: transcript.summary.items)
                    }
                    ChatComposer(session: session, store: store).id(session.id)
                }
                .frame(maxWidth: .infinity)
                if showsInspector {
                    Divider()
                    SessionInspector(session: session, summary: transcript.summary)
                        .frame(width: DS.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // The title bar is transparent; the header shares its row with the traffic lights instead of sitting below.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: session.transcriptFile) { transcript.watch(session.transcriptFile) }
        .onDisappear { transcript.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(session.name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                if let branch = session.branch, !branch.isEmpty {
                    Chip(text: branch, icon: "arrow.triangle.branch")
                }
                Spacer(minLength: 12)
                Picker("View", selection: $showsTerminal) {
                    Image(systemName: "text.bubble").help("Activity").tag(false)
                    Image(systemName: "terminal").help("Live terminal").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { onFocus(session.id) } label: {
                    Label("Open Terminal", systemImage: "arrow.up.forward.app")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Bring this session's terminal to the front (⌘O)")
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showsInspector ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)")
            }
            HStack(spacing: 6) {
                StatusDot(status: session.status, size: 7).id(session.status)
                Text(session.status.title).foregroundStyle(statusTextColor).fontWeight(.medium)
                if let since = session.waitingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("for \(IdleMath.format(context.date.timeIntervalSince(since)))").foregroundStyle(.secondary)
                    }
                }
                // When blocked, the card below says what's needed; don't say it twice.
                if session.status != .blocked {
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.need).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// The status colors are tuned for dots; as text, yellow needs to be darker to read on a light background.
    private var statusTextColor: Color {
        switch session.status {
        case .working: return .secondary
        case .blocked: return session.status.color
        case .review: return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.98, green: 0.76, blue: 0.18, alpha: 1)
                : NSColor(srgbRed: 0.72, green: 0.49, blue: 0.0, alpha: 1)
        })
        }
    }
}

/// A permission prompt answered from here: the whole request, so nothing hides behind a summary, then the choice.
struct ApprovalCard: View {
    let session: Session
    var onDecide: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(session.need, systemImage: "hand.raised.fill")
                .font(.system(size: DS.body, weight: .semibold))
                .foregroundStyle(SessionStatus.blocked.color)
            ScrollView {
                Text(session.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            HStack(spacing: 8) {
                Text("Claude Code's prompt is also up in the terminal. Whichever you answer first wins.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Deny") { onDecide(.deny) }
                Button("Always Allow") { onDecide(.allowAlways) }
                    .help("Allow, and add the rule Claude Code suggests so it stops asking for this")
                Button("Allow") { onDecide(.allow) }
                    .buttonStyle(.borderedProminent)
                    .tint(SessionStatus.working.color)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
            .fill(SessionStatus.blocked.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
            .strokeBorder(SessionStatus.blocked.color.opacity(0.25)))
    }
}

/// Questions and plan approvals need a real answer in the terminal.
struct AnswerInTerminalCard: View {
    let session: Session
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(session.need, systemImage: "questionmark.bubble.fill")
                    .font(.system(size: DS.body, weight: .semibold))
                    .foregroundStyle(SessionStatus.blocked.color)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Answer in Terminal", action: onOpen).buttonStyle(.borderedProminent)
            }
            if !session.detail.isEmpty {
                ScrollView {
                    MarkdownText(source: session.detail, size: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
            .fill(SessionStatus.blocked.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
            .strokeBorder(SessionStatus.blocked.color.opacity(0.25)))
    }
}

// MARK: - Activity

/// The session as a conversation: your prompts, Claude's replies, and the tool calls between them, newest last.
struct ActivityFeed: View {
    let items: [ActivityItem]
    @State private var expanded: Set<String> = []

    /// A prompt, a reply, or a run of tool calls between them.
    enum Block: Identifiable {
        case message(ActivityItem)
        case tools([ActivityItem])
        var id: String {
            switch self {
            case .message(let item): return item.id
            case .tools(let run): return "run-" + run[0].id
            }
        }
    }

    static func blocks(_ items: [ActivityItem]) -> [Block] {
        var out: [Block] = []
        var run: [ActivityItem] = []
        for item in items {
            if isTool(item) { run.append(item); continue }
            if !run.isEmpty { out.append(.tools(run)); run = [] }
            out.append(.message(item))
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var body: some View {
        let blocks = Self.blocks(items)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        Group {
                            switch block {
                            case .message(let item):
                                row(item, startsGroup: true)
                            case .tools(let run) where run.count < 3:
                                ForEach(Array(run.enumerated()), id: \.element.id) { i, item in row(item, startsGroup: i == 0) }
                            case .tools(let run):
                                ToolRun(run: run, isLatest: index == blocks.count - 1,
                                        open: expanded.contains(block.id),
                                        onToggle: { toggle(block.id) },
                                        row: { item in AnyView(row(item, startsGroup: false)) })
                            }
                        }
                        .id(block.id)
                    }
                }
                .frame(maxWidth: DS.readable)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if items.isEmpty {
                    EmptyState(icon: "text.bubble", title: "Nothing yet",
                               message: "Prompts, replies and tool calls appear here as the session runs.")
                }
            }
            .onChange(of: items.last?.id) { _ in
                guard let last = Self.blocks(items).last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear { if let last = blocks.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
    }

    private func row(_ item: ActivityItem, startsGroup: Bool) -> some View {
        FeedRow(item: item, expanded: expanded.contains(item.id), startsGroup: startsGroup) { toggle(item.id) }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.remove(id) == nil { expanded.insert(id) }
        }
    }

    static func isTool(_ item: ActivityItem) -> Bool {
        if case .tool = item.kind { return true }
        return false
    }
}

/// Three or more tool calls in a row, folded into one line ("12 steps · Bash, Edit, Read"). The run that's still
/// going keeps its latest call in view.
struct ToolRun: View {
    let run: [ActivityItem]
    let isLatest: Bool
    let open: Bool
    var onToggle: () -> Void
    var row: (ActivityItem) -> AnyView

    private var toolNames: String {
        var seen: [String] = []
        for item in run {
            if case .tool(let name) = item.kind, !seen.contains(name) { seen.append(name) }
        }
        let shown = seen.prefix(4).map { $0.hasPrefix("mcp__") ? "MCP" : $0 }
        return shown.joined(separator: ", ") + (seen.count > 4 ? "…" : "")
    }

    private var failures: Int { run.filter(\.failed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14)
                Text("\(run.count) steps").fontWeight(.medium)
                Text(toolNames).foregroundStyle(.tertiary).lineLimit(1)
                if failures > 0 {
                    Text("\(failures) failed").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SessionStatus.blocked.color)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            if open {
                ForEach(run) { row($0) }
            } else if isLatest, let last = run.last {
                row(last)
            }
        }
        .padding(.top, 14)
    }
}

struct FeedRow: View {
    let item: ActivityItem
    let expanded: Bool
    /// Tool calls in a row sit tight together; anything else gets breathing room above it.
    let startsGroup: Bool
    var onTap: () -> Void

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            switch item.kind {
            case .prompt: prompt
            case .reply: reply
            case .tool(let name): tool(name)
            }
        }
        .padding(.top, startsGroup ? 14 : 1)
    }

    private var time: String { item.time.map(Self.clock.string(from:)) ?? "" }

    private func caption(_ who: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(who).fontWeight(.semibold)
            Text(time).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("You", icon: "person.crop.circle.fill", tint: .accentColor)
            Text(item.detail.isEmpty ? item.title : item.detail)
                .font(.system(size: DS.body))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        }
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Claude", icon: "sparkle", tint: Color(red: 0.85, green: 0.47, blue: 0.34))
            MarkdownText(source: item.detail.isEmpty ? item.title : item.detail, size: DS.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tool(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.icon(for: name))
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.failed ? SessionStatus.blocked.color : Color.secondary)
                    .frame(width: 14)
                Text(item.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                if item.failed {
                    Text("failed").font(.system(size: 10, weight: .semibold)).foregroundStyle(SessionStatus.blocked.color)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(item.detail.isEmpty ? 0 : 1)
            }
            if expanded, !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.fill))
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(expanded ? DS.fill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { onTap() } }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Write": return "square.and.pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "AskUserQuestion": return "questionmark.bubble"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": return "checklist"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

// MARK: - Inspector

/// The essentials up top (progress, cost, changes); the long tables fold away until you want them.
struct SessionInspector: View {
    let session: Session
    let summary: TranscriptSummary
    @AppStorage("inspectorCostOpen") private var costOpen = false
    @AppStorage("inspectorTokensOpen") private var tokensOpen = false
    @AppStorage("inspectorToolsOpen") private var toolsOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                overview
                if !summary.todos.isEmpty { tasks }
                files
                VStack(alignment: .leading, spacing: 10) {
                    if summary.requests > 0 {
                        DisclosureGroup(isExpanded: $costOpen) { costDetail.padding(.top, 6) } label: { groupLabel("Cost breakdown") }
                    }
                    DisclosureGroup(isExpanded: $tokensOpen) { tokenDetail.padding(.top, 6) } label: { groupLabel("Tokens") }
                    if !summary.tools.isEmpty {
                        DisclosureGroup(isExpanded: $toolsOpen) { toolDetail.padding(.top, 6) } label: { groupLabel("Tools used") }
                    }
                }
                folder
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // Overview: four numbers worth a glance.
    private var overview: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            Metric(label: "Est. cost", value: summary.requests > 0 ? dollars(summary.cost.total) : "–")
                .help("At Anthropic's API rates. A subscription isn't billed per token; this is what the same usage would cost on the API.")
            Metric(label: "Context", value: shortTokens(summary.contextTokens))
                .help("How much the latest request sent, including cache.")
            Metric(label: "Active", value: summary.activeSeconds > 0 ? IdleMath.format(summary.activeSeconds) : "–")
                .help("Time with activity in the transcript. Gaps over 5 minutes count as idle.")
            Metric(label: "Changes", value: summary.linesAdded + summary.linesRemoved > 0
                   ? "+\(summary.linesAdded) −\(summary.linesRemoved)" : "–")
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            let done = summary.todos.filter { $0.status == .completed }.count
            HStack {
                sectionTitle("Tasks")
                Spacer()
                Text("\(done) of \(summary.todos.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(1, summary.todos.count)))
                .tint(SessionStatus.working.color)
            ForEach(summary.todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: todo.status == .completed ? "checkmark.circle.fill"
                          : todo.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(todo.status == .completed ? SessionStatus.working.color
                                         : todo.status == .inProgress ? SessionStatus.review.color : .secondary)
                    Text(todo.text)
                        .font(.system(size: 12))
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        .fontWeight(todo.status == .inProgress ? .medium : .regular)
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Files changed")
                Spacer()
                if !summary.files.isEmpty {
                    Text("\(summary.files.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if summary.files.isEmpty {
                Text("None yet").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(summary.files.prefix(30)) { file in
                Button { FileOpener.openSafely(file.path) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Text(relative(file.path)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        if file.added > 0 || file.removed > 0 { lineCounts(file.added, file.removed) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(file.path)
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                }
            }
        }
    }

    private var costDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            stat("Output", dollars(summary.cost.output))
            stat("Cache read", dollars(summary.cost.cacheRead))
            stat("Cache write", dollars(summary.cost.cacheWrite))
            stat("Input, uncached", dollars(summary.cost.input))
            if summary.prompts > 0 { stat("Per prompt", dollars(summary.cost.total / Double(summary.prompts))) }
            if summary.activeSeconds > 60 { stat("Per active hour", dollars(summary.cost.total / summary.activeSeconds * 3600)) }
            if summary.costByModel.count > 1 {
                subheading("By model")
                ForEach(summary.costByModel) { stat($0.model, dollars($0.cost)) }
            }
            let priciest = summary.turns.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }.prefix(5)
            if !priciest.isEmpty {
                subheading("Most expensive prompts")
                ForEach(Array(priciest)) { turn in
                    stat(turn.prompt, dollars(turn.cost)).help("\(turn.prompt)\n\(turn.requests) requests")
                }
            }
            if summary.unpricedRequests > 0 {
                Text("\(summary.unpricedRequests) requests left out: no price for that model.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
    }

    private var tokenDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            stat("Output", shortTokens(summary.outputTokens))
            stat("Input, uncached", shortTokens(summary.inputTokens))
            stat("Cache read", shortTokens(summary.cacheReadTokens))
            stat("Cache write", shortTokens(summary.cacheWriteTokens))
            stat("Requests", "\(summary.requests)")
            stat("Prompts", "\(summary.prompts)")
            if let model = summary.model { stat("Model", model) }
        }
    }

    private var toolDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(summary.tools) { tool in
                HStack(spacing: 6) {
                    Text(toolName(tool.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if tool.failed > 0 {
                        Text("\(tool.failed) failed").font(.system(size: 10.5)).foregroundStyle(SessionStatus.blocked.color)
                    }
                    Text("\(tool.calls)").font(.system(size: 12).monospacedDigit())
                }
                .help(tool.name)
            }
        }
    }

    private var folder: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        } label: {
            Label((session.cwd as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                .font(.system(size: 11)).lineLimit(1).truncationMode(.head)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show in Finder")
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
    }

    private func subheading(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12).monospacedDigit())
        }
    }

    private func lineCounts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(SessionStatus.working.color)
            Text("−\(removed)").foregroundStyle(SessionStatus.blocked.color)
        }
        .font(.system(size: 10.5).monospacedDigit())
    }

    private func dollars(_ amount: Double) -> String {
        String(format: amount < 1 ? "$%.3f" : "$%.2f", amount)
    }

    private func shortTokens(_ n: Int) -> String {
        if n == 0 { return "–" }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// "mcp__github__create_issue" reads as "github: create_issue".
    private func toolName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count >= 3 && parts[0] == "mcp" ? "\(parts[1]): \(parts[2...].joined(separator: "__"))" : name
    }

    private func relative(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasPrefix(session.cwd) ? "." + dir.dropFirst(session.cwd.count) : dir
    }
}

// MARK: - Small pieces

struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.fill))
    }
}

struct Chip: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.fill))
        .overlay(Capsule().strokeBorder(DS.hairline))
    }
}

/// A calm, centred placeholder (ContentUnavailableView needs macOS 14).
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

enum FileOpener {
    /// Opens documents in their app; anything that could run (a .command, an app, an executable) is only shown in
    /// Finder, since a session can write files with any name and contents.
    static func openSafely(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let risky: Set<String> = ["app", "command", "tool", "terminal", "workflow", "scpt", "applescript", "scptd", "jar",
                                  "pkg", "mpkg", "dmg", "webloc", "inetloc", "fileloc", "action", "prefpane", "osax"]
        let type = UTType(filenameExtension: url.pathExtension)
        let document = type.map { $0.conforms(to: .text) || $0.conforms(to: .image) || $0.conforms(to: .pdf) } ?? false
        if document, !risky.contains(url.pathExtension.lowercased()), !FileManager.default.isExecutableFile(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
