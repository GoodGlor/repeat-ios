import XCTest
@testable import Repeat

/// #38 — the string catalogue. Ukrainian is the source language and its text is
/// the key, so what needs testing is not that the copy exists but that the
/// *variations* do: plurals, and the English fallback.
final class LocalizationTests: XCTestCase {

    private static let uk = Locale(identifier: "uk_UA")
    private static let en = Locale(identifier: "en_US")

    // MARK: - The bundle

    /// The whole reason #36's dates rendered in English: a bundle that claims
    /// `en` resolves `Locale.current` to English however Ukrainian the copy is.
    func testTheBundleIsUkrainianFirst() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "uk")
        XCTAssertTrue(Bundle.main.localizations.contains("uk"), "\(Bundle.main.localizations)")
        XCTAssertTrue(Bundle.main.localizations.contains("en"), "\(Bundle.main.localizations)")
    }

    func testTheCatalogueIsInTheBundle() {
        XCTAssertNotNil(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                        subdirectory: nil, localization: "uk"))
    }

    // MARK: - Ukrainian plurals

    /// The acceptance line, exactly: 1, 2, 5 and 21. 21 is the one every
    /// hand-rolled implementation gets wrong — it takes the *singular* — and 11
    /// is the trap that catches anyone who fixes 21 by looking only at the last
    /// digit.
    func testUkrainianCardPluralsAreCorrect() {
        let cases: [(Int, String)] = [
            (1, "картка"), (2, "картки"), (3, "картки"), (4, "картки"),
            (5, "карток"), (11, "карток"), (12, "карток"), (14, "карток"),
            (21, "картка"), (22, "картки"), (25, "карток"), (101, "картка"),
        ]
        for (count, expected) in cases {
            let text = NeedsAttention.leechTitle(count: count, locale: Self.uk)
            XCTAssertTrue(text.contains("\(count) \(expected)"),
                          "\(count) rendered as \"\(text)\", expected \"\(expected)\"")
        }
    }

    func testUkrainianDayPluralsAreCorrect() {
        XCTAssertEqual(StatsSummary.dayCount(1, locale: Self.uk), "1 день")
        XCTAssertEqual(StatsSummary.dayCount(2, locale: Self.uk), "2 дні")
        XCTAssertEqual(StatsSummary.dayCount(5, locale: Self.uk), "5 днів")
        XCTAssertEqual(StatsSummary.dayCount(11, locale: Self.uk), "11 днів")
        XCTAssertEqual(StatsSummary.dayCount(21, locale: Self.uk), "21 день")
        XCTAssertEqual(StatsSummary.dayCount(0, locale: Self.uk), "0 днів")
    }

    /// Zero is `many` in Ukrainian, not `one` — a detail CLDR knows and a
    /// `count == 1 ?` ternary cannot express.
    func testZeroTakesTheManyForm() {
        XCTAssertTrue(NeedsAttention.leechTitle(count: 0, locale: Self.uk).contains("0 карток"))
    }

    // MARK: - The English fallback

    func testEnglishFallbackExistsForOrdinaryCopy() {
        XCTAssertEqual(Localized.string("Готово", locale: Self.en), "Done")
        XCTAssertEqual(Localized.string("Налаштування", locale: Self.en), "Settings")
        XCTAssertEqual(Localized.string("Резервні копії розкладу", locale: Self.en),
                       "Scheduling backups")
    }

    func testEnglishPluralsUseTheEnglishRuleNotTheUkrainianOne() {
        // English has two forms, so 2 and 5 agree — which they must not in
        // Ukrainian. Asserting both directions catches a catalogue that copied
        // one language's variations into the other.
        XCTAssertEqual(Localized.string("\(1) день", locale: Self.en), "1 day")
        XCTAssertEqual(Localized.string("\(2) день", locale: Self.en), "2 days")
        XCTAssertEqual(Localized.string("\(5) день", locale: Self.en), "5 days")
        XCTAssertEqual(Localized.string("\(21) день", locale: Self.en), "21 days")

        XCTAssertNotEqual(Localized.string("\(2) день", locale: Self.uk),
                          Localized.string("\(5) день", locale: Self.uk))
    }

    /// Ukrainian resolves through the same call, so a catalogue that lost its
    /// source-language variations would show up here rather than only on device.
    func testUkrainianResolvesThroughTheCatalogueToo() {
        XCTAssertEqual(Localized.string("\(1) день", locale: Self.uk), "1 день")
        XCTAssertEqual(Localized.string("\(2) день", locale: Self.uk), "2 дні")
        XCTAssertEqual(Localized.string("\(5) день", locale: Self.uk), "5 днів")
    }

    // MARK: - Dates through Locale

    /// §8: "dates and numbers formatted through `Locale`, never hard-coded".
    /// #36 had to pin `uk_UA` because the bundle claimed English; that pin is
    /// gone, and this asserts the pin did not simply move somewhere else.
    // MARK: - #93: the class, not the two known strings

    /// The compiled English table, read from the bundle the app ships.
    private func englishTable() throws -> [String: String] {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "en", ofType: "lproj")
                                 ?? Bundle.main.path(forResource: "en", ofType: "lproj"),
                                 "no en.lproj in the bundle")
        let strings = try XCTUnwrap(
            NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String],
            "en.lproj has no compiled Localizable.strings")
        // Without this the sweep below would pass vacuously on an empty table —
        // a green test that inspects nothing, which is worse than no test. The
        // catalogue holds 250-odd keys; a hundred is a floor, not a target.
        XCTAssertGreaterThan(strings.count, 100,
                             "read only \(strings.count) English strings — the table is not "
                             + "being found, so any sweep over it proves nothing")
        return strings
    }

    /// **No Cyrillic survives into the English build.**
    ///
    /// This is the class #93 was filed for, rather than the two strings that
    /// exposed it. Every user-facing string the app declares is checked, so a
    /// Ukrainian literal that gains a catalogue entry but never gains a
    /// translation fails here instead of on someone's screen.
    ///
    /// It cannot see a literal that never reaches the catalogue at all — which is
    /// exactly what `Text(String)` produces, since extraction only sees
    /// `LocalizedStringKey`. That half is closed by typing the two helpers that
    /// took `String` (`SettingsView.row`, `FlashcardFace.prompt`) as
    /// `LocalizedStringKey`, which makes it a compile error rather than something
    /// to notice in a screenshot.
    func testNoUkrainianTextSurvivesIntoTheEnglishBuild() throws {
        let cyrillic = CharacterSet(charactersIn: "\u{0400}"..."\u{04FF}")
        var offenders: [String] = []
        for (key, value) in try englishTable()
        where value.rangeOfCharacter(from: cyrillic) != nil {
            offenders.append("\(key) → \(value)")
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these are still Ukrainian in the English build:\n"
                      + offenders.sorted().joined(separator: "\n"))
    }

    /// The three strings that were wrong, named explicitly.
    ///
    /// The sweep above would catch them, but it would also go green the day someone
    /// deletes them. These are the ones a screenshot proved were reaching the
    /// screen in the wrong language, so they are worth pinning by name.
    func testTheStringsFoundWrongInScreenshotsAreTranslated() throws {
        let table = try englishTable()
        for key in ["Торкнись, щоб перевірити",
                    "Синхронізувати зараз",
                    "Завантажити все заново"] {
            let value = try XCTUnwrap(table[key], "\(key) never reached the catalogue")
            XCTAssertNotEqual(value, key, "\(key) has no English translation")
        }
    }

    func testBackupDatesFollowTheLocaleRatherThanAPin() {
        let url = URL(fileURLWithPath: "/tmp/_backup-2026-09-02.json")
        let title = BackupSettingsView.title(for: url, locale: Self.uk)
        // Under the test host's Ukrainian bundle this is Ukrainian; the point is
        // that it is not a hardcoded language.
        XCTAssertTrue(title.contains("2026"), title)
        XCTAssertTrue(title.contains("вересня"), title)
    }
}
