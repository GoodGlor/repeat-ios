import SwiftUI

/// Dynamic Type for the design's own point sizes (§8, #37).
///
/// `Font.system(size:)` is a **fixed** size — it ignores Dynamic Type entirely.
/// Twenty-two of them had accumulated, concentrated in the study flow, so a
/// reader at XXL saw exactly the same 12pt rating caption as a reader at the
/// default. Switching them all to text styles would have thrown away the visual
/// design; `@ScaledMetric` keeps each size exactly as drawn at the default
/// setting and scales it from there.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

extension View {
    /// The scaling counterpart of `.font(.system(size:weight:))`.
    ///
    /// `relativeTo` picks which text style's curve the size follows: display
    /// numerals grow more slowly than captions, which is what keeps a 64pt
    /// counter on screen at XXL while a 12pt label still becomes readable.
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, relativeTo: style))
    }
}
