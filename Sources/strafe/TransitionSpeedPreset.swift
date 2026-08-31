/// Fixed synthetic-swipe velocities exposed by the menu-bar app.
///
/// These affect only strafe's replacement gesture. They do not change the
/// macOS-wide Desktop transition setting and intentionally are not persisted.
enum TransitionSpeedPreset: Int, CaseIterable {
    case normal
    case fast
    case faster
    case fastest
    case instant

    var title: String {
        switch self {
        case .normal: "Normal"
        case .fast: "Fast"
        case .faster: "Faster"
        case .fastest: "Fastest"
        case .instant: "Instant"
        }
    }

    var velocity: Double {
        switch self {
        case .normal: 40.0
        case .fast: 50.0
        case .faster: 60.0
        case .fastest: 80.0
        case .instant: 2000.0
        }
    }
}
