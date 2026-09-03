import XCTest
@testable import Repeat

/// #101 — the half of the localisation class that a catalogue test cannot see.
///
/// #93 added a sweep over the **compiled English table**, which fails on any value
/// still containing Cyrillic. It is worth having and it is structurally blind to the
/// bug that mattered: a `Text(String)` literal never reaches the catalogue at all,
/// so there is no English value to inspect and the sweep goes green over sixteen
/// wrong strings. I said as much when writing it, then fixed only what I could see.
///
/// The only detector for "a literal in the source that never reached the catalogue"
/// reads the **source**. `#filePath` gives that at compile time.
final class SourceLocalizationTests: XCTestCase {

    /// Literals that are Ukrainian on purpose: card *content*, not interface copy.
    /// Kept short and justified, because an allowlist is where this kind of test
    /// goes to die.
    private static let contentNotCopy: Set<String> = [
        // The answer on onboarding's demo card — the thing being taught.
        "повсюдний",
    ]

    /// Files that exist to hold sample material rather than to talk to anyone.
    private static let dataFiles: Set<String> = [
        "SampleData.swift",     // seeded decks and cards
        "RepeatApp.swift",      // the canned autofill payload behind -autofillDemoOnLaunch
    ]

    private func repoRoot() throws -> URL {
        // …/Tests/RepeatTests/SourceLocalizationTests.swift → …/
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RepeatTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        url.standardize()
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path)
        else {
            throw XCTSkip("sources are not on disk at \(url.path) — run from a checkout")
        }
        return url
    }

    /// Collapses interpolation and format specifiers, so a source literal
    /// `"\(n) карток"` and a catalogue key `"%lld карток"` compare equal.
    private func normalized(_ text: String) -> String {
        var out = ""
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if depth == 0, rest.hasPrefix("\\(") {
                depth = 1
                index = text.index(index, offsetBy: 2)
                out.append("\u{0}")
                continue
            }
            if depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        for specifier in ["%lld", "%ld", "%d", "%@", "%.1f", "%f"] {
            out = out.replacingOccurrences(of: specifier, with: "\u{0}")
        }
        // App Intents titles are extracted as `Додати ${front} до ${deck}`, so a
        // source literal written `\(\.$front)` has to collapse to the same shape or
        // every intent looks untranslated.
        while let open = out.range(of: "${"), let close = out.range(of: "}", range: open.upperBound..<out.endIndex) {
            out.replaceSubrange(open.lowerBound..<close.upperBound, with: "\u{0}")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func englishKeys(in root: URL) throws -> Set<String> {
        let url = root.appendingPathComponent("Repeat/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let strings = ((json as? [String: Any])?["strings"] as? [String: Any]) ?? [:]
        var translated: Set<String> = []
        for (key, value) in strings {
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            if localizations?["en"] != nil { translated.insert(normalized(key)) }
        }
        XCTAssertGreaterThan(translated.count, 100,
                             "read only \(translated.count) translated keys — the catalogue "
                             + "is not being found, so this test proves nothing")
        return translated
    }

    /// Every Cyrillic literal the app draws has an English translation.
    ///
    /// This is the test that would have caught onboarding: `title(_:)` and `body(_:)`
    /// returned `String`, so nothing about them existed anywhere except the source.
    func testEveryUkrainianLiteralInTheSourceIsTranslated() throws {
        let root = try repoRoot()
        let translated = try englishKeys(in: root)

        let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Repeat"),
                                                     includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .filter { !Self.dataFiles.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(sources.count, 40, "found \(sources.count) sources — not scanning")

        let cyrillic = CharacterSet(charactersIn: "\u{0400}"..."\u{04FF}")
        var offenders: [String] = []

        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            var debugDepth = 0
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments say nothing to the reader of the app. `#Preview` bodies
                // are not shipped either, and by convention sit at the end of a file.
                if trimmed.hasPrefix("//") { continue }
                if trimmed.hasPrefix("#Preview") { break }
                // Neither is anything behind `#if DEBUG`: the sample conflict Home
                // seeds for a screenshot is fixture text, not copy.
                if trimmed.hasPrefix("#if DEBUG") { debugDepth += 1; continue }
                if debugDepth > 0 {
                    if trimmed.hasPrefix("#if") { debugDepth += 1 }
                    if trimmed.hasPrefix("#endif") { debugDepth -= 1 }
                    continue
                }

                for literal in Self.literals(in: line) {
                    guard literal.rangeOfCharacter(from: cyrillic) != nil else { continue }
                    if Self.contentNotCopy.contains(literal) { continue }
                    if translated.contains(normalized(literal)) { continue }
                    offenders.append("\(url.lastPathComponent):\(number + 1)  \(literal)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "these Ukrainian literals never reach an English reader:\n"
                      + offenders.sorted().joined(separator: "\n"))
    }

    /// Double-quoted literals on a line, with escapes respected.
    private static func literals(in line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inside = false
        var escaped = false
        for character in line {
            if escaped { if inside { current.append("\\"); current.append(character) }; escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                if inside { result.append(current); current = "" }
                inside.toggle()
                continue
            }
            if inside { current.append(character) }
        }
        return result
    }
}
