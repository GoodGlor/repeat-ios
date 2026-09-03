import XCTest
import UIKit
@testable import Repeat

/// #99 — the app shipped with the placeholder icon from card #1 until card #99.
///
/// Nothing caught it because nothing looked: a simulator screenshot shows the app's
/// *screens*, never its icon, and `AppIcon.appiconset/Contents.json` declared a slot
/// while naming no file — which is a perfectly valid catalogue that produces nothing.
final class AppIconTests: XCTestCase {

    /// The host application's bundle. These tests run inside the app, so
    /// `Bundle.main` is the thing that would be installed.
    private var app: Bundle { Bundle.main }

    func testTheAppDeclaresAnIcon() throws {
        let icons = try XCTUnwrap(app.infoDictionary?["CFBundleIcons"] as? [String: Any],
                                  "no CFBundleIcons — the catalogue produced no icon")
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String])
        XCTAssertFalse(files.isEmpty, "CFBundleIconFiles is empty")
    }

    /// Declaring one is not shipping one. This is the half that was actually broken:
    /// the slot existed, the artwork did not.
    func testTheDeclaredIconIsActuallyInTheBundle() throws {
        let icons = try XCTUnwrap(app.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        let name = try XCTUnwrap((primary["CFBundleIconFiles"] as? [String])?.first)

        let image = try XCTUnwrap(UIImage(named: name, in: app, compatibleWith: nil),
                                  "\(name) is declared but no image of that name is in the bundle")
        XCTAssertGreaterThanOrEqual(image.size.width * image.scale, 120,
                                    "the shipped icon is smaller than the 60pt @2x slot")
        XCTAssertEqual(image.size.width, image.size.height, "an app icon must be square")
    }

    /// The icon is drawn by `scripts/make-app-icon.swift` from the app's own palette,
    /// so a change to the brand colour that forgets the icon is visible as a diff
    /// rather than as a mismatch nobody notices. Sampling the corner is the cheapest
    /// way to hold that: it is the gradient's dark end, `accentFillDeep`.
    func testTheIconUsesTheAppsOwnGreen() throws {
        let icons = try XCTUnwrap(app.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        let name = try XCTUnwrap((primary["CFBundleIconFiles"] as? [String])?.first)
        let image = try XCTUnwrap(UIImage(named: name, in: app, compatibleWith: nil))
        let cg = try XCTUnwrap(image.cgImage)

        // Bottom-right pixel: the deep end of the ramp, and far from the card.
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: -CGFloat(cg.width) + 1, y: 0,
                                     width: CGFloat(cg.width), height: CGFloat(cg.height)))

        XCTAssertGreaterThan(pixel[1], pixel[0], "the icon's corner is not green-dominant")
        XCTAssertGreaterThan(pixel[1], pixel[2], "the icon's corner is not green-dominant")
    }
}
