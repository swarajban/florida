import Foundation

/// The small touches that can each be turned off in Settings › Feel. All default to on and are
/// read straight from `UserDefaults`, so views can bind them with `@AppStorage(key)`.
enum JoyPreference: String, CaseIterable, Identifiable {
    case pendingKeys, ghosts, currentProgress, offHours, freeGaps, blockSlide, accountRims
    case completionSound, completionBloom

    var id: String { rawValue }
    var key: String { "joy." + rawValue }

    var label: String {
        switch self {
        case .pendingKeys: "Show key sequences in progress (g …) in the status bar"
        case .ghosts: "Confirm each action with a one-second label"
        case .currentProgress: "Fill the current block as it runs and show it in the status bar"
        case .offHours: "Dim hours outside your schedules"
        case .freeGaps: "Show free time in your schedules (space lists what fits)"
        case .blockSlide: "Slide blocks to their new times when the schedule changes"
        case .accountRims: "Outline events in their Google account's color"
        case .completionSound: "Sound and trackpad tap when a task is done"
        case .completionBloom: "Done rows bloom in their category color as they fold away"
        }
    }
}

enum JoyPreferences {
    static func isOn(_ preference: JoyPreference, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: preference.key) != nil else { return true }
        return defaults.bool(forKey: preference.key)
    }
}
