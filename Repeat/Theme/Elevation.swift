import SwiftUI

/// Depth, as three named levels rather than a shadow written out at each call
/// site (#89).
///
/// The old design had one shadow, on the study card, spelled inline. Everything
/// else was a flat fill on a flat background, which is what made the app read as
/// a wireframe: with no elevation, a tappable card and a section of the page look
/// identical.
///
/// Two stacked shadows per level, not one. A single large-radius shadow reads as
/// fog; a tight, nearly-opaque one gives the edge its contact with the surface and
/// a wide, faint one gives the object its height. This is the cheapest way to make
/// a rectangle look like it is *on* something.
enum Elevation {
    /// A row or chip. Barely off the page.
    case low
    /// A card the finger will land on.
    case medium
    /// The thing the whole screen is about.
    case high

    fileprivate var contact: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .low: (0.05, 2, 1)
        case .medium: (0.07, 3, 1)
        case .high: (0.09, 4, 2)
        }
    }

    fileprivate var ambient: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .low: (0.04, 8, 3)
        case .medium: (0.07, 16, 8)
        case .high: (0.12, 26, 16)
        }
    }
}

extension View {
    /// Raises the view off the surface.
    ///
    /// Applied to the *shape*, not to a container — a shadow on a view whose
    /// background is drawn by a modifier further down the chain silhouettes the
    /// text as well, which is the usual way SwiftUI shadows go wrong.
    func elevated(_ level: Elevation) -> some View {
        let contact = level.contact
        let ambient = level.ambient
        return self
            .shadow(color: Palette.shadow.opacity(contact.opacity),
                    radius: contact.radius, x: 0, y: contact.y)
            .shadow(color: Palette.shadow.opacity(ambient.opacity),
                    radius: ambient.radius, x: 0, y: ambient.y)
    }
}
