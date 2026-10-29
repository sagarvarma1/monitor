import ActivityKit
import SwitchboardCore

/// The Live Activity's type. The Mac starts it with push-to-start, so this type name and the `title` attribute
/// must match what PhoneBridge sends ("attributes-type": "SwitchboardActivityAttributes").
struct SwitchboardActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveState
    var title: String
}
