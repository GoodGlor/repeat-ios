import XCTest
import SwiftUI
import Scheduling
@testable import Repeat

/// #37 — §8's accessibility line. Layout at XXL and VoiceOver navigation need a
/// device (that is #39), but the two things that *can* be pinned down here are
/// the ones that regressed silently: contrast ratios, which are arithmetic, and
/// the spoken text on the controls a session cannot be completed without.
final class AccessibilityTests: XCTestCase {

    // MARK: - Contrast

    /// Both schemes, always (#87).
    ///
    /// Every contrast test below runs twice. Dark mode is exactly where a palette
    /// regresses silently: a value that clears AA on cream commonly fails on
    /// charcoal, and nothing on screen says so — #37 had to remove a 2.50:1 rating
    /// colour that had shipped for eight cards.
    private static let schemes: [(name: String, style: UIUserInterfaceStyle)] = [
        ("light", .light), ("dark", .dark)
    ]

    /// WCAG relative luminance, from the sRGB components the app actually ships.
    ///
    /// **Resolved against an explicit trait collection.** Since #87 the palette is
    /// dynamic `UIColor`, and reading its components without saying which scheme
    /// you mean returns whichever one `UITraitCollection.current` happens to hold
    /// in a test process — so a "both schemes" test would have measured one scheme
    /// twice and passed.
    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        let resolved = UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func contrast(_ foreground: Color, on background: Color,
                          _ style: UIUserInterfaceStyle) -> Double {
        let a = luminance(foreground, style), b = luminance(background, style)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func assertAA(_ foreground: Color, on background: Color,
                          _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for (scheme, style) in Self.schemes {
            let ratio = contrast(foreground, on: background, style)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(name) in \(scheme) is \(String(format: "%.2f", ratio)):1 — AA needs 4.5:1",
                file: file, line: line
            )
        }
    }

    /// The card's line, and the one that was actually broken: the four rating
    /// colours measured 3.69 / 2.50 / 4.45 / 4.36 against their own backgrounds.
    ///
    /// #89 inverted the button — the colour is the fill, the label is white — so
    /// this measures the pair the app **draws today**. `fill` is fixed across
    /// schemes, which is the whole reason it is a separate token from `tint`.
    func testEveryRatingLabelMeetsWCAGAAOnItsButton() {
        for grade in Grade.allCases {
            assertAA(grade.onFill, on: grade.fill, "\(grade) label on its button")
        }
    }

    /// The other half of #87's split: the same four grades drawn as *text* on the
    /// page, which is where a single-value palette failed. In dark, `again`, `hard`
    /// and `easy` measured 3.1–3.4 : 1 before they were given light variants.
    func testEveryRatingColourIsLegibleAsTextOnBothSurfaces() {
        for grade in Grade.allCases {
            assertAA(grade.tint, on: Palette.bg, "\(grade) as text on bg")
            assertAA(grade.tint, on: Palette.paper, "\(grade) as text on paper")
        }
    }

    func testBodyAndSecondaryTextMeetWCAGAA() {
        let pairs: [(String, Color, Color)] = [
            ("ink on bg", Palette.ink, Palette.bg),
            ("ink on paper", Palette.ink, Palette.paper),
            ("ink2 on bg", Palette.ink2, Palette.bg),
            ("ink2 on paper", Palette.ink2, Palette.paper),
            ("accent on bg", Palette.accent, Palette.bg),
            ("accent on paper", Palette.accent, Palette.paper),
            ("accent on accentSoft", Palette.accent, Palette.accentSoft),
            // The one `…Soft` fill #89 left standing: Catch-up's button.
            ("hard on hardSoft", Palette.hard, Palette.hardSoft),
        ]
        for (name, foreground, background) in pairs {
            assertAA(foreground, on: background, name)
        }
    }

    /// #89 put white on two gradients — Home's hero and the Done screen's primary
    /// button — and a gradient has no single contrast ratio.
    ///
    /// Both stops are asserted, because the failure mode is specific and easy to
    /// miss: the first ramp tried ran `accentFill` → a *lighter* green, whose bright
    /// end measured 3.69:1 against white. A screenshot would not have caught it,
    /// since the worst corner of a gradient is the one nobody looks at.
    func testWhiteClearsAAAtBothEndsOfTheHeroGradient() {
        assertAA(.white, on: Palette.accentFill, "white on accentFill")
        assertAA(.white, on: Palette.accentFillDeep, "white on accentFillDeep")
    }

    /// #89's streak colour, in all three places it is drawn.
    func testStreakColourMeetsWCAGAAWhereverItIsDrawn() {
        assertAA(Palette.streak, on: Palette.streakSoft, "streak on streakSoft")
        assertAA(Palette.streak, on: Palette.bg, "streak on bg")
        assertAA(Palette.streak, on: Palette.paper, "streak on paper")
    }

    /// The rating colours must also stay distinguishable from *each other*: a
    /// reader who cannot tell Again from Hard by hue is relying on position
    /// alone, and darkening four colours toward legibility is exactly the change
    /// that could collapse them together. Checked in both schemes, since #87 gave
    /// them a second set of values that could collapse independently.
    func testRatingColoursRemainDistinctFromOneAnother() {
        for (scheme, style) in Self.schemes {
            let tints = Grade.allCases.map(\.tint)
            for (i, a) in tints.enumerated() {
                for b in tints[(i + 1)...] {
                    let separation = abs(luminance(a, style) - luminance(b, style))
                    let hueDistance = distance(a, b, style)
                    XCTAssertTrue(separation > 0.02 || hueDistance > 0.15,
                                  "two rating colours are nearly identical in \(scheme)")
                }
            }
        }
    }

    private func distance(_ a: Color, _ b: Color, _ style: UIUserInterfaceStyle) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(a).resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(b).resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return sqrt(pow(Double(r1 - r2), 2) + pow(Double(g1 - g2), 2) + pow(Double(b1 - b2), 2))
    }

    /// The palette must actually *have* two schemes.
    ///
    /// Every contrast test above would pass a palette that ignored dark mode
    /// entirely — light values measured twice still clear 4.5:1. This is the test
    /// that fails if `dynamic(light:dark:)` is ever quietly replaced by a constant,
    /// which is the one way the whole card could regress while staying green.
    func testTheSurfacesActuallyDifferBetweenSchemes() {
        let pairs: [(String, Color)] = [
            ("bg", Palette.bg), ("paper", Palette.paper),
            ("ink", Palette.ink), ("line", Palette.line),
        ]
        for (name, color) in pairs {
            let light = luminance(color, .light)
            let dark = luminance(color, .dark)
            XCTAssertNotEqual(light, dark, accuracy: 0.0,
                              "\(name) is the same colour in both schemes")
        }
        XCTAssertLessThan(luminance(Palette.bg, .dark), 0.1, "the dark page is not dark")
        XCTAssertGreaterThan(luminance(Palette.bg, .light), 0.5, "the light page is not light")
        // Elevation in dark comes from lightness, not shadow: a raised surface has
        // to be lighter than the page it sits on, or the card disappears into it.
        XCTAssertGreaterThan(luminance(Palette.paper, .dark), luminance(Palette.bg, .dark),
                             "a raised surface must be lighter than the page in dark")
    }

    /// A near-white shadow is a glow.
    ///
    /// `shadow` was `ink`, which is correct in light and catastrophic in dark where
    /// `ink` is the *text* colour. Nothing else in the suite would have caught it.
    func testTheShadowIsDarkInBothSchemes() {
        for (scheme, style) in Self.schemes {
            XCTAssertLessThan(luminance(Palette.shadow, style), 0.05,
                              "the shadow is light in \(scheme) — it would render as a glow")
        }
    }

    // MARK: - What VoiceOver says

    /// §8: "VoiceOver labels on rating buttons include the interval". The label
    /// is built from the preview, so a card whose previews have not loaded must
    /// still name the button rather than reading as an unlabelled control.
    func testRatingLabelsCarryTheIntervalAndSurviveAMissingPreview() throws {
        for grade in Grade.allCases {
            XCTAssertFalse(grade.title.isEmpty, "\(grade) has no spoken name")
        }

        // Built through the real scheduler rather than a hand-made value: the
        // spoken interval is what the button will actually say.
        let previews = try? Scheduler().preview(for: CardSchedulingSnapshot())
        let preview = try XCTUnwrap(previews?[.good])
        let withPreview = StudyView.ratingLabel(grade: .good, preview: preview)
        XCTAssertTrue(withPreview.contains(Grade.good.title), withPreview)
        XCTAssertTrue(withPreview.contains(preview.spokenLabel), withPreview)
        XCTAssertFalse(preview.spokenLabel.isEmpty, "the interval must be spoken, not just shown")

        let withoutPreview = StudyView.ratingLabel(grade: .good, preview: nil)
        XCTAssertTrue(withoutPreview.contains(Grade.good.title), withoutPreview)
        XCTAssertFalse(withoutPreview.hasSuffix(", "), "a missing preview left a dangling comma")
    }
}
