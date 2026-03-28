import SwiftUI

enum FocusOverlayState: Equatable, Sendable {
    case focus
    case transitioning
    case drift
    case activeDrift
    case hyperfocus

    var color: Color {
        switch self {
        case .focus:         return Color(hex: "30D158")
        case .transitioning: return Color(hex: "FFD60A")
        case .drift:         return Color(hex: "FF9F0A")
        case .activeDrift:   return Color(hex: "FF375F")
        case .hyperfocus:    return Color(hex: "BF5AF2")
        }
    }

    var label: String {
        switch self {
        case .focus:         return "In flow"
        case .transitioning: return "Transitioning"
        case .drift:         return "Drifting"
        case .activeDrift:   return "Lost focus"
        case .hyperfocus:    return "Hyperfocus"
        }
    }
}

struct FocusScore: Sendable {
    let value: Double
    let switchCount: Int
    let uniqueApps: Int
    let currentSessionMinutes: Double
    let state: FocusOverlayState
    let computedAt: Date
}

private extension Color {
    init(hex: String) {
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
