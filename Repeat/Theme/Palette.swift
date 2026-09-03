import Scheduling
import SwiftUI
import UIKit

/// The app's colour and depth tokens, in both schemes (#87).
///
/// These started as a lift from `docs/anki-ios-mockup.html`, which #89 superseded.
///
/// **Tokens are semantic, not literal.** `surface` / `surfaceRaised` / `onSurface`
/// name a *role*. The literal names (`bg`, `paper`, `ink`) are the same colours
/// under their historical names — 83 call sites use them and renaming those would
/// have been the whole diff.
///
/// ## Why some colours come in two forms
///
/// A colour used as a **fill under white text** and the same colour used as **text
/// on the page** are not the same colour, and on a dark ground they cannot be. The
/// arithmetic is disjoint:
///
/// - to carry white text at 4.5:1, a fill needs relative luminance **≤ 0.183**;
/// - to *be* text at 4.5:1 on the dark page (`bg` dark, L = 0.012), a colour needs
///   luminance **≥ 0.229**.
///
/// There is no value in between, so no single token can do both jobs. In *light*
/// mode the two requirements happen to coincide — a dark green works as a fill and
/// as text on cream alike — which is why the app got away with one value per colour
/// for forty-four cards. Dark mode is where that stops working: every one of
/// `accent`, `again`, `hard`, `easy` and `streak` measured 3.1–3.4 : 1 as text on
/// the dark page, all of them below AA.
///
/// So each of those splits in two:
///
/// - **`accent`, `again`, `hard`, `good`, `easy`, `streak`** — the *on-surface*
///   form. Dynamic: dark in light mode, light in dark mode.
/// - **`accentFill`, `againFill`, …** — the *fill* form, carrying white. These are
///   **fixed**, identical in both schemes: a saturated mid-tone reads correctly on
///   cream and on charcoal alike, and white on it clears AA either way. Making them
///   dynamic too would have been two more values to get wrong for no gain.
///
/// `AccessibilityTests` measures every pair in **both** schemes, resolved through
/// `UITraitCollection`, so this cannot quietly regress the way #37's palette did.
enum Palette {

    /// Resolves per scheme, at draw time.
    ///
    /// A dynamic `UIColor` rather than an asset catalogue: every colour decision in
    /// this app has lived in this one file since card #1, the two schemes read
    /// side by side here, and — the deciding reason — a test can resolve one
    /// against an explicit `UITraitCollection` and measure it. Catalogue colours
    /// would have moved half the palette somewhere a test cannot see it.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    // MARK: - Surfaces

    static let bg = dynamic(light: 0xEEF1EC, dark: 0x121815)
    /// Lighter than `bg` in dark, where elevation cannot come from shadow: a black
    /// shadow on a near-black page is invisible, so a raised surface has to be
    /// raised by *lightness* instead. See `Elevation`.
    static let paper = dynamic(light: 0xFFFFFF, dark: 0x1C2521)
    static let ink = dynamic(light: 0x17211B, dark: 0xE9EFEB)
    static let ink2 = dynamic(light: 0x5F6B64, dark: 0xA6B2AB)
    static let line = dynamic(light: 0xDDE3DC, dark: 0x323E39)

    // MARK: - Accent

    /// The brand green **as text or tint on a surface**. 8.44:1 on `bg` in dark.
    static let accent = dynamic(light: 0x1E7558, dark: 0x5FC49B)
    /// A pale wash of the accent, carrying `accent` on top of it. 5.81:1 in dark.
    static let accentSoft = dynamic(light: 0xDFF0E8, dark: 0x1D3A2E)

    /// The brand green **as a fill under white**, and the dark end of the gradients
    /// Home and the Done screen are built from. Fixed in both schemes: 5.61:1 and
    /// 8.63:1 against white.
    ///
    /// The gradient runs `accentFill` → `accentFillDeep`, i.e. dark to darker, so
    /// white clears AA at every point of the ramp rather than on average. A
    /// *lighter* stop was tried first and measured 3.69:1 — a gradient's worst
    /// corner is the one nobody checks.
    static let accentFill = Color(hex: 0x1E7558)
    static let accentFillDeep = Color(hex: 0x14563F)

    // MARK: - Rating colours

    // §8 asks for adequate contrast on the four rating colours. As *text* on their
    // own soft backgrounds the originals measured 3.69 / 2.50 / 4.45 / 4.36 —
    // three failed WCAG AA for normal text and `hard` failed even the large-text
    // floor of 3.0, on a button pressed dozens of times a day. #37 darkened each
    // along its own hue until it cleared 4.5.
    //
    // #89 then inverted the buttons — the colour became the fill and the label
    // became white — and those same values carried over, because dark enough to
    // read *on* cream is dark enough to be read *against* by white.
    //
    // #87 is where the one-value-per-colour arrangement finally broke: see the
    // type comment. The `…Fill` values below are #37's, unchanged and fixed in
    // both schemes; the on-surface forms are new and only differ in dark.

    static let again = dynamic(light: 0xB13F32, dark: 0xEC8C7E)
    static let hard = dynamic(light: 0x8B5F15, dark: 0xE0B25E)
    static let good = dynamic(light: 0x1E7558, dark: 0x5FC49B)
    static let easy = dynamic(light: 0x37689D, dark: 0x84B4E8)

    static let againFill = Color(hex: 0xB13F32)
    static let hardFill = Color(hex: 0x8B5F15)
    static let goodFill = Color(hex: 0x1E7558)
    static let easyFill = Color(hex: 0x37689D)

    /// The pale amber behind Catch-up's button — the last survivor of the four
    /// `…Soft` fills. #89 made the rating buttons solid, which left the other three
    /// drawn by nothing, and an unused palette entry is what let the mockup go on
    /// describing a design the app had stopped having.
    static let hardSoft = dynamic(light: 0xFAEBCF, dark: 0x3A2E14)

    // MARK: - Semantic aliases (roles, for anything new)

    /// The page behind everything.
    static var surface: Color { bg }
    /// A card sitting on `surface`.
    static var surfaceRaised: Color { paper }
    /// Primary text on either surface.
    static var onSurface: Color { ink }
    /// Secondary text on either surface.
    static var onSurfaceMuted: Color { ink2 }
    /// Hairlines and disabled glyphs.
    static var separator: Color { line }

    // MARK: - Depth (#89)

    /// Shadows are `ink` at low opacity in light, so a neutral black does not grey
    /// the green-tinted surface it falls on. In **dark** they are true black: `ink`
    /// there is near-white, and a near-white shadow is a glow — the single worst
    /// way this port could have gone wrong, and invisible in any test.
    static let shadow = dynamic(light: 0x17211B, dark: 0x000000)

    // MARK: - Streak (#89)

    /// The streak's own colour, so it reads as earned rather than as another
    /// accent-green number. 5.37:1 on `paper` in light, 7.32:1 in dark; the first
    /// amber tried was 4.19:1 and would have failed the contrast test.
    static let streak = dynamic(light: 0xA85312, dark: 0xE7A26A)
    static let streakSoft = dynamic(light: 0xFDF0E4, dark: 0x38271A)

    /// `--r: 18px` in the mockup; the card itself uses 22.
    static let radius: CGFloat = 18
    static let cardRadius: CGFloat = 22
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// `#1F7A5C` as the Sheet's `colorHex` column writes it. Optional because the
    /// value is owner-typed: a malformed colour falls back rather than crashing.
    init?(hex string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Grade {
    var title: String {
        switch self {
        case .again: Localized.string("Знову")
        case .hard: Localized.string("Важко")
        case .good: Localized.string("Добре")
        case .easy: Localized.string("Легко")
        }
    }

    /// The grade drawn **as text or an icon on a surface** — the Done screen's
    /// tiles, the typed-answer diff, the "forgotten" count.
    var tint: Color {
        switch self {
        case .again: Palette.again
        case .hard: Palette.hard
        case .good: Palette.good
        case .easy: Palette.easy
        }
    }

    /// The grade drawn **as the rating button's fill**, under `onFill`.
    ///
    /// A separate token from `tint` since #87, not a duplicate of it: in dark
    /// `tint` becomes light so it can be read on the page, and white on a light
    /// fill fails. Fixed in both schemes — see `Palette`'s type comment for why the
    /// two roles cannot share a value.
    var fill: Color {
        switch self {
        case .again: Palette.againFill
        case .hard: Palette.hardFill
        case .good: Palette.goodFill
        case .easy: Palette.easyFill
        }
    }

    /// What goes on `fill`. Measured 5.79 / 5.61 / 5.61 / 5.79 : 1, both schemes.
    var onFill: Color { .white }

    /// The glyph on the button. Grading is a four-way decision made in a fraction
    /// of a second, and shape is faster to read than a word — the word stays for
    /// everyone who does not read the icon.
    var symbolName: String {
        switch self {
        case .again: "arrow.counterclockwise"
        case .hard: "tortoise.fill"
        case .good: "checkmark"
        case .easy: "hare.fill"
        }
    }
}
