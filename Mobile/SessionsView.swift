import SwiftUI
import SwitchboardCore

struct SessionsView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        NavigationStack {
            List {
                Section { status }
                if model.sessions.isEmpty {
                    Section {
                        Text("No active Claude Code sessions")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                } else {
                    Section {
                        ForEach(model.sessions) { session in
                            SessionCard(session: session, answered: session.decisionID.map(model.answered.contains) ?? false,
                                        onDecide: { model.decide(session, $0) },
                                        onReply: { model.replying = session })
                        }
                    }
                }
            }
            .navigationTitle("Switchboard")
            .refreshable { await model.refresh() }
            .sheet(item: $model.replying) { session in
                ReplySheet(session: session) { model.reply(session, $0) }
                    .presentationDetents([.height(260), .medium])
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.macOnline ? SessionStatus.working.color : Color.secondary).frame(width: 8, height: 8)
                Text(model.macOnline ? "Connected to \(model.macName ?? "your Mac")" : "Waiting for your Mac")
                    .font(.subheadline.weight(.medium))
            }
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(SessionStatus.blocked.color)
            }
            if !LiveActivityTokens.shared.hasActivity {
                Button("Show on Lock Screen & Dynamic Island") { LiveActivityTokens.shared.startNow(with: model.sessions) }
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionCard: View {
    let session: LiveSession
    let answered: Bool
    var onDecide: (PhoneCommand.Kind) -> Void
    var onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(session.sessionStatus.color).frame(width: 9, height: 9)
                Text(session.name).font(.headline).lineLimit(1)
                if let branch = session.branch {
                    Text(branch).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let since = session.waitingSince {
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(session.status == 0 ? session.sessionStatus.color : .secondary)
                }
            }
            Text(session.need).font(.subheadline).foregroundStyle(.secondary)
            if session.decisionID != nil {
                if answered {
                    Text("Sent to your Mac…").font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Button("Deny") { onDecide(.deny) }.buttonStyle(.bordered)
                        Button("Allow") { onDecide(.allow) }.buttonStyle(.borderedProminent).tint(SessionStatus.working.color)
                        Button("Always") { onDecide(.allowAlways) }.buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            } else if session.canReply {
                Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left.fill") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ReplySheet: View {
    let session: LiveSession
    var onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply to \(session.name)").font(.headline)
            TextField("Tell Claude what to do next…", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            Button {
                onSend(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("Send").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
        .onAppear { focused = true }
    }
}
