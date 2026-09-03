import SwiftUI

/// A button that acknowledges the press (#89).
///
/// `.buttonStyle(.plain)` — which the rating row and every card-shaped button in
/// the app used — gives no feedback at all: the finger goes down, nothing moves,
/// and the only confirmation is the screen changing afterwards. On the rating row
/// that is the difference between a control and a picture of one.
///
/// Scale rather than opacity, because these buttons are solid colour: fading a
/// filled button toward the page reads as "disabled", and shrinking it reads as
/// "pressed".
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            // Reduce Motion still gets feedback, just not movement.
            .opacity(configuration.isPressed && reduceMotion ? 0.82 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
