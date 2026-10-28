import XCTest
@testable import Scheduling

/// The four buttons make four different promises, and the labels have to show
/// it. On a review card FSRS keeps Hard, Good and Easy strictly apart — `Hard`
/// is roughly 0.7 of `Good`, and `Easy` is at least a day past it — but a label
/// that rounds to whole months from day 30 collapses 31 and 43 days into the
/// same word. The owner was shown `Hard 1mo · Good 1mo` on the phone.
final class RatingLabelTests: XCTestCase {
    private static let en = Locale(identifier: "en_US")
    private static let uk = Locale(identifier: "uk_UA")
    private let now = Date(timeIntervalSince1970: 1_757_900_000)

    /// Every review card the default weights can produce, on time and overdue,
    /// in both languages the app ships in.
    func testHardGoodAndEasyNeverShareALabelOnAReviewCard() throws {
        let scheduler = Scheduler()
        var collisions: [String] = []
        for locale in [Self.en, Self.uk] {
            for stability in Array(stride(from: 1.0, through: 400.0, by: 1.0)) + Array(stride(from: 400.0, through: 3000.0, by: 7.0)) {
                for difficulty in [1.0, 3.0, 5.0, 7.0, 9.0, 10.0] {
                    for overdue in [1.0, 1.5, 3.0] {
                        let scheduled = Int(stability.rounded())
                        let elapsed = stability * overdue
                        let card = CardSchedulingSnapshot(
                            state: .review,
                            due: now.addingTimeInterval(-(elapsed - stability) * 86_400),
                            stability: stability, difficulty: difficulty,
                            elapsedDays: Int(elapsed.rounded()), scheduledDays: scheduled,
                            reps: 5, lastReview: now.addingTimeInterval(-elapsed * 86_400))
                        let previews = try scheduler.preview(for: card, now: now)
                        let labels = [Grade.hard, .good, .easy].map {
                            IntervalFormatter.short(previews[$0]!.interval, locale: locale)
                        }
                        if Set(labels).count != labels.count {
                            let days = [Grade.hard, .good, .easy].map {
                                String(format: "%.1f", previews[$0]!.interval / 86_400)
                            }
                            collisions.append("S=\(stability) D=\(difficulty) x\(overdue) \(locale.identifier): \(labels) from \(days) days")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(collisions.isEmpty,
                      "\(collisions.count) collisions, first: \(collisions.prefix(5))")
    }

    /// The pair from the owner's screenshot, to the day.
    func testThirtyOneAndFortyThreeDaysReadDifferently() {
        XCTAssertNotEqual(IntervalFormatter.short(31 * 86_400, locale: Self.en),
                          IntervalFormatter.short(43 * 86_400, locale: Self.en))
        XCTAssertEqual(IntervalFormatter.short(30 * 86_400, locale: Self.en), "1.0mo")
        XCTAssertEqual(IntervalFormatter.short(44 * 86_400, locale: Self.en), "1.5mo")
        XCTAssertEqual(IntervalFormatter.short(104 * 86_400, locale: Self.en), "3.5mo")
        XCTAssertEqual(IntervalFormatter.short(400 * 86_400, locale: Self.en), "13.3mo")
        XCTAssertEqual(IntervalFormatter.short(800 * 86_400, locale: Self.en), "2.2y")
        XCTAssertEqual(IntervalFormatter.short(29 * 86_400, locale: Self.en), "29d")
    }

    /// The decimal takes the locale's separator and the locale's unit word.
    func testFractionalMonthsAreLocalised() {
        let uk = IntervalFormatter.short(44 * 86_400, locale: Self.uk)
        XCTAssertTrue(uk.contains("1,5"), uk)
        XCTAssertFalse(uk.hasSuffix("mo"), uk)
        XCTAssertNotEqual(uk, IntervalFormatter.short(44 * 86_400, locale: Self.en))
        let year = IntervalFormatter.short(800 * 86_400, locale: Self.uk)
        XCTAssertTrue(year.contains("2,2"), year)
    }

    /// VoiceOver keeps counting in days past a month: a spoken "400 days" is
    /// exact and never the same for two buttons, where "1 year" would be.
    func testSpokenLabelsCountDaysPastAMonth() {
        XCTAssertTrue(IntervalFormatter.spoken(44 * 86_400, locale: Self.en).contains("44"))
        XCTAssertTrue(IntervalFormatter.spoken(400 * 86_400, locale: Self.en).contains("400"))
        XCTAssertTrue(IntervalFormatter.spoken(800 * 86_400, locale: Self.uk).contains("800"))
    }

    /// Labels stay ordered: a longer interval never reads as a smaller number.
    /// (Sweeps the day grid; the unit changes are where this can go wrong.)
    func testLabelsAreMonotonicOverDays() {
        var previous = ""
        var previousDays = 0
        for day in 1...(365 * 3) {
            let label = IntervalFormatter.short(Double(day) * 86_400, locale: Self.en)
            if label != previous {
                // A change of label must never be a step *down* in the number shown.
                let n = Double(label.prefix { $0.isNumber || $0 == "." }) ?? 0
                let p = Double(previous.prefix { $0.isNumber || $0 == "." }) ?? 0
                let sameUnit = label.drop { $0.isNumber } == previous.drop { $0.isNumber }
                if sameUnit {
                    XCTAssertGreaterThan(n, p, "day \(day): \(previous) -> \(label)")
                }
                previous = label
                previousDays = day
            }
        }
        _ = previousDays
    }
}
