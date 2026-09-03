import UIKit

/// §6.3: light on reveal, notification-warning on Again.
enum Haptics {
    static func reveal() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func again() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
