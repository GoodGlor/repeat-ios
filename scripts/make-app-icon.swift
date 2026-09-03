import AppKit

// Repeat's app icon (#99), drawn rather than sourced.
//
//   swift scripts/make-app-icon.swift \
//       Repeat/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//
// A script rather than a binary someone once exported: the icon is then reviewable
// as a diff, regenerable when the brand colour moves, and impossible to lose. The
// palette is the app's own — `accentFill` → `accentFillDeep`, the same ramp Home's
// hero and the Done button use — so `AppIconTests` can assert the icon is still the
// app's green rather than trusting that it was.
let size = 1024.0
let accent      = NSColor(srgbRed: 0x1E/255, green: 0x75/255, blue: 0x58/255, alpha: 1)
let accentDeep  = NSColor(srgbRed: 0x14/255, green: 0x56/255, blue: 0x3F/255, alpha: 1)

// An explicit bitmap, not `NSImage.lockFocus()`: on a Retina Mac the latter
// renders at the screen's scale and silently produces a 2048px file for a
// 1024pt canvas, which Xcode then rejects as the wrong size.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Background: the same top-leading → bottom-trailing ramp as Home's hero.
let gradient = NSGradient(starting: accent, ending: accentDeep)!
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -45)

// Two stacked cards — the same metaphor as the Decks tab, so the icon and the
// tab bar say the same thing. The back card is the deck; the front one is the
// card you are looking at.
func card(_ rect: NSRect, radius: CGFloat, fill: NSColor, rotation: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: rotation * .pi / 180)
    ctx.translateBy(x: -rect.midX, y: -rect.midY)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    ctx.restoreGState()
}

let w = 672.0, h = 476.0
let cx = size / 2, cy = size / 2 + 8   // a touch high, so it sits optically centred

// Both cards share a centre and differ only by rotation, so the deck peeks out
// evenly on every side. Offsetting one of them instead left the back card
// overhanging at the lower left, which read as a mistake rather than as a stack.
let bounds = NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

card(bounds, radius: 56, fill: NSColor.white.withAlphaComponent(0.30), rotation: -8)
card(bounds, radius: 56, fill: .white, rotation: 0)

// Two rules: a flashcard has a question and an answer, and at 40pt these read as
// "text" without pretending to be letters. The second is shorter and paler — the
// answer, still to come.
let front = bounds
accent.withAlphaComponent(0.85).setFill()
let ruleH = 44.0
NSBezierPath(roundedRect: NSRect(x: front.minX + 84, y: front.midY + 34,
                                 width: front.width - 168, height: ruleH),
             xRadius: ruleH / 2, yRadius: ruleH / 2).fill()
accent.withAlphaComponent(0.42).setFill()
NSBezierPath(roundedRect: NSRect(x: front.minX + 84, y: front.midY - 70,
                                 width: (front.width - 168) * 0.55, height: ruleH),
             xRadius: ruleH / 2, yRadius: ruleH / 2).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
