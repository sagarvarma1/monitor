import AppIntents
import SwitchboardCore

/// Allow / Deny / Always from the Lock Screen or Dynamic Island. A LiveActivityIntent runs in the app's process
/// (in the background), which writes the answer to iCloud; the Mac picks it up and answers Claude Code.
struct DecideIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer a permission prompt"
    static var isDiscoverable = false

    @Parameter(title: "Session") var sessionID: String
    @Parameter(title: "Request") var decisionID: String
    @Parameter(title: "Decision") var decision: String

    init() {}

    init(sessionID: String, decisionID: String, decision: PhoneCommand.Kind) {
        self.sessionID = sessionID
        self.decisionID = decisionID
        self.decision = decision.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let kind = PhoneCommand.Kind(rawValue: decision) else { return .result() }
        try await Cloud.send(PhoneCommand(kind: kind, sessionID: sessionID, decisionID: decisionID))
        return .result()
    }
}
