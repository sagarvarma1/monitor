import ActivityKit
import SwiftUI
import SwitchboardCore
import WidgetKit

@main
struct SwitchboardLiveBundle: WidgetBundle {
    var body: some Widget { SwitchboardLiveActivity() }
}

/// The pill, on the phone: dots and a headline in the Dynamic Island, the most urgent session (with Allow/Deny
/// when it's waiting on a prompt) when expanded, and a short list on the Lock Screen.
struct SwitchboardLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SwitchboardActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.sessions.first.map { Links.session($0.id) })
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusDots(state: state, max: 6).padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.worst?.color ?? .white)
                        .padding(.trailing, 6).padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let top = state.sessions.first {
                        SessionLine(session: top, prominent: true).padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                StatusDots(state: state, max: 3)
            } compactTrailing: {
                CompactTrailing(state: state)
            } minimal: {
                Circle().fill(state.worst?.color ?? .gray).frame(width: 9, height: 9)
            }
            .widgetURL(state.sessions.first.map { Links.session($0.id) })
            .keylineTint(state.worst?.color ?? .white)
        }
    }
}

struct StatusDots: View {
    let state: LiveState
    let max: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(state.sessions.prefix(max)) { s in
                Circle().fill(s.sessionStatus.color).frame(width: 7, height: 7)
            }
        }
    }
}

/// The longest wait while something needs you (a live timer, no pushes needed), otherwise the working count.
struct CompactTrailing: View {
    let state: LiveState

    var body: some View {
        if let top = state.sessions.first, top.sessionStatus.isWaiting, let since = top.waitingSince {
            Text(Date(timeIntervalSince1970: since), style: .timer)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(top.sessionStatus.color)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 46)
        } else {
            Text("\(state.working)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(SessionStatus.working.color)
        }
    }
}

struct SessionLine: View {
    let session: LiveSession
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(session.sessionStatus.color).frame(width: 8, height: 8)
                Text(session.name).font(.system(size: prominent ? 15 : 13, weight: .semibold)).lineLimit(1)
                if let branch = session.branch {
                    Text(branch).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let since = session.waitingSince {
                    Text(Date(timeIntervalSince1970: since), style: .timer)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(session.status == 0 ? session.sessionStatus.color : .white.opacity(0.6))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                }
            }
            Text(session.need)
                .font(.system(size: prominent ? 13 : 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(prominent ? 2 : 1)
            if prominent { actions }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var actions: some View {
        if let decisionID = session.decisionID {
            HStack(spacing: 8) {
                Button(intent: DecideIntent(sessionID: session.id, decisionID: decisionID, decision: .deny)) { Text("Deny") }
                    .buttonStyle(CapsuleButtonStyle())
                Button(intent: DecideIntent(sessionID: session.id, decisionID: decisionID, decision: .allow)) { Text("Allow") }
                    .buttonStyle(CapsuleButtonStyle(fill: SessionStatus.working.color))
                Button(intent: DecideIntent(sessionID: session.id, decisionID: decisionID, decision: .allowAlways)) { Text("Always") }
                    .buttonStyle(CapsuleButtonStyle())
            }
        } else if session.canReply {
            Link(destination: Links.reply(session.id)) {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
        }
    }
}

struct LockScreenView: View {
    let state: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Switchboard").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(state.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(state.worst?.color ?? .white)
            }
            ForEach(Array(state.sessions.prefix(3).enumerated()), id: \.element.id) { index, session in
                SessionLine(session: session, prominent: index == 0)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}
