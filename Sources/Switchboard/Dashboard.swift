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

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var nav: DashboardNav
    var onFocus: (String) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selectedID) {
                ForEach(store.sessions) { session in
                    SidebarRow(session: session).tag(session.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
            .overlay {
                if store.sessions.isEmpty {
                    Text("No active Claude Code sessions").font(.callout).foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let session = store.sessions.first(where: { $0.id == nav.selectedID }) {
                SessionDetailView(session: session, store: store, onFocus: onFocus)
            } else {
                Text(store.sessions.isEmpty ? "Sessions appear here once their hooks fire" : "Select a session")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, idealWidth: 1000, minHeight: 480, idealHeight: 640)
        .onAppear { if nav.selectedID == nil { nav.selectedID = store.sessions.first?.id } }
    }
}

struct SidebarRow: View {
    let session: Session

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(status: session.status, size: 8).id(session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let branch = session.branch, !branch.isEmpty {
                        Text(branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(session.need).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let since = session.waitingSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(IdleMath.format(context.date.timeIntervalSince(since)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(session.status == .blocked ? session.status.color : .secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct SessionDetailView: View {
    let session: Session
    @ObservedObject var store: SessionStore
    var onFocus: (String) -> Void
    @StateObject private var transcript = TranscriptModel()
    @AppStorage("detailShowsTerminal") private var showsTerminal = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Picker("View", selection: $showsTerminal) {
                        Text("Terminal").tag(true)
                        Text("Activity").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    .padding(8)
                    if showsTerminal {
                        TerminalMirrorView(session: session).id(session.id)
                    } else {
                        ActivityFeed(items: transcript.summary.items)
                    }
                    Divider()
                    ChatComposer(session: session, store: store).id(session.id)
                }
                Divider()
                SessionSidePanel(session: session, summary: transcript.summary)
                    .frame(width: 270)
            }
        }
        .task(id: session.transcriptFile) { transcript.watch(session.transcriptFile) }
        .onDisappear { transcript.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(status: session.status, size: 10).id(session.status)
                Text(session.name).font(.system(size: 20, weight: .semibold))
                if let branch = session.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Go to session") { onFocus(session.id) }
            }
            Text(session.need).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if session.decisionID != nil {
                DecisionButtons { store.decide(session.id, $0) }
            }
        }
        .padding(16)
    }
}

/// The session as it happened: your prompts, Claude's replies and every tool call, newest at the bottom.
struct ActivityFeed: View {
    let items: [ActivityItem]
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        FeedRow(item: item, expanded: expanded.contains(item.id)) {
                            if expanded.remove(item.id) == nil { expanded.insert(item.id) }
                        }
                        .id(item.id)
                    }
                }
                .padding(10)
            }
            .overlay {
                if items.isEmpty {
                    Text("No activity yet").foregroundStyle(.secondary)
                }
            }
            .onChange(of: items.last?.id) { last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear { if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FeedRow: View {
    let item: ActivityItem
    let expanded: Bool
    var onTap: () -> Void

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.time.map(Self.clock.string(from:)) ?? "")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(item.failed ? SessionStatus.blocked.color : iconColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: item.kind == .prompt ? .semibold : .regular))
                        .foregroundStyle(isTool ? Color.secondary : Color.primary)
                        .lineLimit(expanded ? nil : 1)
                    if item.failed {
                        Text("failed").font(.system(size: 10, weight: .semibold)).foregroundStyle(SessionStatus.blocked.color)
                    }
                }
                if expanded { detail }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(item.kind == .prompt ? Color.accentColor.opacity(0.09) : expanded ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var detail: some View {
        switch item.kind {
        case .reply:
            MarkdownText(source: item.detail)
        case .prompt:
            Text(item.detail).font(.system(size: 12)).textSelection(.enabled)
        case .tool:
            Text(item.detail)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }

    private var isTool: Bool {
        if case .tool = item.kind { return true }
        return false
    }

    private var iconColor: Color {
        switch item.kind {
        case .prompt: return .accentColor
        case .reply: return SessionStatus.review.color
        case .tool: return .secondary
        }
    }

    private var icon: String {
        switch item.kind {
        case .prompt: return "person.crop.circle.fill"
        case .reply: return "sparkle"
        case .tool(let name):
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
}

struct SessionSidePanel: View {
    let session: Session
    let summary: TranscriptSummary
    @State private var showAllTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !summary.todos.isEmpty { tasks }
                stats
                if summary.requests > 0 { costs }
                if !summary.tools.isEmpty { tools }
                tokenStats
                files
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 6) {
            let done = summary.todos.filter { $0.status == .completed }.count
            sectionTitle("Tasks", count: nil)
            ProgressView(value: Double(done), total: Double(max(1, summary.todos.count)))
                .tint(SessionStatus.working.color)
            ForEach(summary.todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: todo.status == .completed ? "checkmark.circle.fill"
                          : todo.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(todo.status == .completed ? SessionStatus.working.color
                                         : todo.status == .inProgress ? SessionStatus.review.color : .secondary)
                    Text(todo.text)
                        .font(.system(size: 12))
                        .strikethrough(todo.status == .completed)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Files changed", count: summary.files.count)
            if summary.files.isEmpty {
                Text("None yet").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(summary.files.prefix(30)) { file in
                Button {
                    Self.openSafely(file.path)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Text(relative(file.path)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        if file.added > 0 || file.removed > 0 {
                            lineCounts(file.added, file.removed)
                        }
                        if file.edits > 1 {
                            Text("×\(file.edits)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                        }
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

    private var stats: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Session")
            stat("Prompts", "\(summary.prompts)")
            stat("Tool calls", summary.failedToolCalls > 0
                 ? "\(summary.toolCalls) (\(summary.failedToolCalls) failed)" : "\(summary.toolCalls)")
            if summary.linesAdded > 0 || summary.linesRemoved > 0 {
                HStack {
                    Text("Lines changed").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    lineCounts(summary.linesAdded, summary.linesRemoved)
                }
            }
            if let model = summary.model { stat("Model", model) }
            if summary.activeSeconds > 0 {
                stat("Active", IdleMath.format(summary.activeSeconds))
                    .help("Time with activity in the transcript. Gaps over 5 minutes count as idle.")
            }
            if let started = summary.startedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    stat("Open for", IdleMath.format(context.date.timeIntervalSince(started)))
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
            } label: {
                Label(session.cwd, systemImage: "folder").font(.system(size: 11)).lineLimit(1).truncationMode(.head)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

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

    private var costs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Estimated cost")
                Spacer()
                Text(dollars(summary.cost.total)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .help("At Anthropic's API rates. A subscription isn't billed per token, so this shows what the same usage would cost on the API.")
            stat("Output", dollars(summary.cost.output))
            stat("Cache read", dollars(summary.cost.cacheRead))
            stat("Cache write", dollars(summary.cost.cacheWrite))
            stat("Input, uncached", dollars(summary.cost.input))
            if summary.requests > 0 { stat("Per request", dollars(summary.cost.total / Double(summary.requests))) }
            if summary.prompts > 0 { stat("Per prompt", dollars(summary.cost.total / Double(summary.prompts))) }
            if summary.activeSeconds > 60 { stat("Per active hour", dollars(summary.cost.total / summary.activeSeconds * 3600)) }
            if summary.costByModel.count > 1 {
                Text("By model").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(summary.costByModel) { stat($0.model, dollars($0.cost)) }
            }
            let priciest = summary.turns.filter { $0.cost > 0 }.sorted { $0.cost > $1.cost }.prefix(5)
            if !priciest.isEmpty {
                Text("Most expensive prompts").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(Array(priciest)) { turn in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(turn.prompt).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(dollars(turn.cost)).font(.system(size: 11.5).monospacedDigit())
                    }
                    .help("\(turn.prompt)\n\(turn.requests) requests")
                }
            }
            if summary.unpricedRequests > 0 {
                Text("\(summary.unpricedRequests) requests left out: no price for that model.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func dollars(_ amount: Double) -> String {
        String(format: amount < 1 ? "$%.3f" : "$%.2f", amount)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Tools", count: summary.tools.count)
            ForEach(showAllTools ? summary.tools : Array(summary.tools.prefix(8))) { tool in
                HStack(spacing: 6) {
                    Text(toolName(tool.name)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if tool.failed > 0 {
                        Text("\(tool.failed) failed").font(.system(size: 10.5)).foregroundStyle(SessionStatus.blocked.color)
                    }
                    Text("\(tool.calls)").font(.system(size: 12).monospacedDigit())
                }
                .help(tool.name)
            }
            if summary.tools.count > 8 {
                Button(showAllTools ? "Show fewer" : "Show all \(summary.tools.count)") { showAllTools.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var tokenStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Tokens")
            stat("Context now", tokens(summary.contextTokens))
                .help("How much the latest request sent, including cache.")
            stat("Output", tokens(summary.outputTokens))
            stat("Input, uncached", tokens(summary.inputTokens))
            stat("Cache read", tokens(summary.cacheReadTokens))
            stat("Cache write", tokens(summary.cacheWriteTokens))
            stat("Requests", "\(summary.requests)")
        }
    }

    private func lineCounts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(SessionStatus.working.color)
            Text("−\(removed)").foregroundStyle(SessionStatus.blocked.color)
        }
        .font(.system(size: 10.5).monospacedDigit())
    }

    /// "mcp__github__create_issue" reads as "github: create_issue".
    private func toolName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count >= 3 && parts[0] == "mcp" ? "\(parts[1]): \(parts[2...].joined(separator: "__"))" : name
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12).monospacedDigit())
        }
    }

    private func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM tokens", Double(n) / 1_000_000) }
        return n >= 1000 ? String(format: "%.1fk tokens", Double(n) / 1000) : "\(n) tokens"
    }

    private func relative(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasPrefix(session.cwd) ? "." + dir.dropFirst(session.cwd.count) : dir
    }
}
