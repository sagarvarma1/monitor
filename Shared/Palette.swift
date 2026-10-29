import SwiftUI
import SwitchboardCore

extension SessionStatus {
    /// Same red / yellow / green as the Mac pill.
    var color: Color {
        switch self {
        case .blocked: return Color(red: 0.95, green: 0.27, blue: 0.25)
        case .review: return Color(red: 0.98, green: 0.76, blue: 0.18)
        case .working: return Color(red: 0.25, green: 0.80, blue: 0.40)
        }
    }
}

enum Links {
    static func session(_ id: String) -> URL { URL(string: "switchboard://session/\(id)")! }
    static func reply(_ id: String) -> URL { URL(string: "switchboard://reply/\(id)")! }
}

/// Capsule buttons that read well on the Lock Screen and the black Dynamic Island.
struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fill == nil ? Color.white : Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(fill ?? Color.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
