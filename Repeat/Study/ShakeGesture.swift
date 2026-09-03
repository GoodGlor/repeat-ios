import SwiftUI
import UIKit

/// Shake-to-undo (§5.5). UIKit delivers motion events to the responder chain and
/// SwiftUI exposes no hook for them, so the window republishes them as a
/// notification the view can observe.
extension UIDevice {
    static let didShakeNotification = Notification.Name("RepeatDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        NotificationCenter.default.post(name: UIDevice.didShakeNotification, object: nil)
    }
}

private struct ShakeModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: UIDevice.didShakeNotification)) { _ in
            action()
        }
    }
}

extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeModifier(action: action))
    }
}
