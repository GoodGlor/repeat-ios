import XCTest
import SwiftUI
import WidgetKit
@testable import Repeat

/// #111 — the widget's two home-screen layouts, rendered and attached.
///
/// The card's second acceptance line asks for a simulator screenshot of the small
/// and medium widgets. It is written as a human step because until this card the
/// layouts lived in `RepeatWidget/`, which no test in this repo can reach. They
/// live under `Repeat/WidgetUI` now, so the suite shoots them itself — four
/// images, both families, both schemes, on every run.
///
/// What this still cannot prove: that WidgetKit lays them out identically inside a
/// real widget host, or anything at all about the owner's phone, where the App
/// Group entitlement is refused and the file is never written.
@MainActor
final class WidgetRenderTests: XCTestCase {

    /// Representative point sizes for a large iPhone. WidgetKit picks the real
    /// ones per device; these are for looking at, not for asserting against.
    /// WidgetKit's default content margin on iOS.
    private static let widgetContentMargin: CGFloat = 16

    private let smallSize = CGSize(width: 170, height: 170)
    private let mediumSize = CGSize(width: 364, height: 170)

    private let working = WidgetSnapshot(due: 12, goalDone: 18, goalTarget: 30, streak: 9)
    private let stale = WidgetSnapshot(due: nil, goalDone: 0, goalTarget: 0, streak: nil)

    // MARK: - The images

    func testTheSmallAndMediumLayoutsRenderInBothSchemes() throws {
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            try shoot(snapshot: working, family: .systemSmall,
                      size: smallSize, dark: dark, name: "widget-small-\(scheme)")
            try shoot(snapshot: working, family: .systemMedium,
                      size: mediumSize, dark: dark, name: "widget-medium-\(scheme)")
        }
    }

    /// The state that is easiest to ship broken, because it is the one nobody
    /// sets up by hand: no file, or a file from another day.
    func testTheStaleLayoutsRenderToo() throws {
        try shoot(snapshot: stale, family: .systemSmall,
                  size: smallSize, dark: false, name: "widget-small-stale")
        try shoot(snapshot: stale, family: .systemMedium,
                  size: mediumSize, dark: false, name: "widget-medium-stale")
    }

    /// The family really does choose a layout. Without this, a view that ignored
    /// its `family` would pass every test above by drawing the small face twice.
    func testTheMediumFamilyDrawsSomethingOtherThanTheSmallOne() throws {
        let asMedium = try render(snapshot: working, family: .systemMedium,
                                  size: mediumSize, dark: false)
        let asSmall = try render(snapshot: working, family: .systemSmall,
                                 size: mediumSize, dark: false)
        XCTAssertNotEqual(asMedium.pngData(), asSmall.pngData(),
                          "the same pixels for both families means `family` is unread")
    }

    // MARK: - The ring's colour

    /// `Palette` imports `Scheduling` and belongs to the app alone, so the ring's
    /// green is restated in `DueCountView`. This is what stops the two drifting —
    /// **in both schemes**, because the ring is dynamic for the same reason
    /// `Palette.accent` is: the light value is unreadable on the dark container.
    func testTheRingIsTheAppsOwnGreenInBothSchemes() {
        func components(_ color: Color, _ style: UIUserInterfaceStyle) -> [CGFloat] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let ring = components(DueCountView.ringTint, style)
            let palette = components(Palette.accent, style)
            for (index, channel) in ["red", "green", "blue", "alpha"].enumerated() {
                XCTAssertEqual(ring[index], palette[index], accuracy: 0.004,
                               "the ring's \(channel) has drifted from Palette.accent")
            }
        }
    }

    // MARK: - Harness

    @discardableResult
    private func shoot(snapshot: WidgetSnapshot, family: WidgetFamily,
                       size: CGSize, dark: Bool, name: String) throws -> UIImage {
        let image = try render(snapshot: snapshot, family: family, size: size, dark: dark)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // A blank square is the way this test fails silently: the attachment is
        // there, the assertion passes, and nobody notices the host never rendered.
        XCTAssertGreaterThan(try distinctColours(in: image), 3,
                             "\(name) is effectively blank — the host did not render")
        return image
    }

    private func render(snapshot: WidgetSnapshot, family: WidgetFamily,
                        size: CGSize, dark: Bool) throws -> UIImage {
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(
            rootView: DueCountView(snapshot: snapshot, family: family)
                // WidgetKit insets a widget's content by default. Without the
                // same inset here the ring sits flush against the left edge and
                // the image flatters a layout that would never look like that.
                .padding(Self.widgetContentMargin)
                .frame(width: size.width, height: size.height)
        )
        host.overrideUserInterfaceStyle = style
        // A `UIHostingController` in a window at the origin inherits the screen's
        // safe-area inset — about 60pt on this device — which pushed every layout
        // down and hung the bottom of it outside the frame. A widget has no safe
        // area. Without this line the images are of a container the widget never
        // gets, and the first three rounds of "fixing the layout" were chasing it.
        host.safeAreaRegions = []
        // `containerBackground(for: .widget)` draws nothing outside a widget host,
        // so the ground is supplied here. It is the only thing the harness adds.
        host.view.backgroundColor = dark ? .black : .white
        host.view.frame = CGRect(origin: .zero, size: size)

        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    private func distinctColours(in image: UIImage) throws -> Int {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(UInt32(pixels[index]) << 24 | UInt32(pixels[index + 1]) << 16
                        | UInt32(pixels[index + 2]) << 8 | UInt32(pixels[index + 3]))
        }
        return seen.count
    }
}
