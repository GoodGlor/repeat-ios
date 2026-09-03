import Foundation
import SwiftData
import Scheduling

/// The hard-coded deck milestone 1 reviews against, before the Sheet exists
/// (spec §9, milestone 1). Seeded once into an empty store; #14's pull replaces
/// it with real content.
enum SampleData {
    static let deckTitle = "Англійська — дієслова"

    @discardableResult
    static func seedIfEmpty(_ context: ModelContext) -> Deck? {
        let existing = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        guard existing.isEmpty else { return existing.first }

        let deck = Deck(sheetTitle: deckTitle, sheetId: 0, colorHex: "#1F7A5C", newCardsPerDay: 15)
        context.insert(deck)

        let rows: [(String, String, String?, [String: String], Bool)] = [
            ("reluctant", "неохочий", "He was reluctant to admit the mistake.", ["вимова": "/rɪˈlʌktənt/"], true),
            ("thorough", "ретельний", "She gave the report a thorough review.", [:], false),
            ("brittle", "крихкий", "The old rope had gone brittle.", [:], false),
            ("linger", "затримуватися", "The smell of coffee lingered in the room.", [:], true),
            ("scarce", "дефіцитний", "Fresh water was scarce that summer.", [:], false),
            ("blunt", "прямолінійний", "Her answer was blunt but fair.", ["вимова": "/blʌnt/"], false),
            ("wary", "насторожений", "He was wary of easy promises.", [:], false),
            ("dwindle", "меншати", "Their savings dwindled over the winter.", [:], false),
        ]

        for (index, row) in rows.enumerated() {
            let note = Note(
                deck: deck,
                front: row.0,
                back: row.1,
                example: row.2,
                tags: ["sample"],
                reverse: row.4,
                extras: row.3,
                extraOrder: Array(row.3.keys).sorted(),
                sheetRow: index
            )
            context.insert(note)
            context.syncCards(for: note)
        }

        try? context.save()
        return deck
    }

    #if DEBUG
    /// A backlog big enough to trigger §5.3's offer, plus the two weeks of
    /// history it is measured against. Debug only — this writes review logs that
    /// never happened, which is fine for a screenshot and wrong for anything
    /// else.
    static func seedBacklog(
        _ context: ModelContext,
        overdue: Int = 120,
        historyPerDay: Int = 10,
        now: Date = .now
    ) {
        let calendar = Calendar.current
        guard let deck = seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first
        else { return }

        for index in 0..<overdue {
            let note = Note(deck: deck, front: "word \(index)", back: "слово \(index)",
                            sheetRow: 1000 + index)
            context.insert(note)
            for card in context.syncCards(for: note, now: now) {
                card.state = .review
                card.due = now.addingTimeInterval(-3600 * Double(index % 48 + 1))
                card.stability = Double(index % 40 + 1) * 2
                card.difficulty = 5
                card.reps = 3
                card.lastReview = calendar.date(byAdding: .day, value: -3, to: now)
            }
        }

        for day in 1...CatchUp.averagingDays {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            for index in 0..<historyPerDay {
                guard let log = try? ReviewLog(
                    cardId: "history-\(day)-\(index)", direction: .forward,
                    rating: Grade.good.rawValue, reviewedAt: date,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(), uploaded: true
                ) else { continue }
                context.insert(log)
            }
        }
        try? context.save()
    }

    /// A handful of cards past §5.4's threshold, for the Home section.
    static func seedLeeches(_ context: ModelContext, count: Int = 2, now: Date = .now) {
        guard let deck = seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first
        else { return }
        let words = [("ubiquitous", "всюдисущий"), ("perfunctory", "поверховий"),
                     ("obsequious", "улесливий")]
        for index in 0..<min(count, words.count) {
            let note = Note(deck: deck, front: words[index].0, back: words[index].1,
                            sheetRow: 5000 + index)
            context.insert(note)
            for card in context.syncCards(for: note, now: now) {
                card.state = .review
                card.lapses = 8 + index * 3
                card.stability = 1.5
                card.difficulty = 9
                card.isSuspended = true
            }
        }
        try? context.save()
    }

    /// Sentences with gaps (#88), so the shape can be seen without waiting for the
    /// owner's spreadsheet to contain one.
    ///
    /// The first is the card #88 was filed with, verbatim. The rest exercise the
    /// edges the parse has to survive: a gap at the start of the sentence, a back
    /// with no explanation after the answer, and a long sentence that must wrap
    /// rather than shrink.
    static func seedGapCards(_ context: ModelContext, now: Date = .now) {
        guard let deck = seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first
        else { return }
        let rows = [
            ("I decided ___ enable thinking mode.",
             "to — decided to enable (decide + to + дієслово)"),
            ("___ is the tallest mountain in the world.",
             "Everest"),
            ("She has been working here ___ two thousand and nineteen, which is longer than anyone else on the team.",
             "since — since + точка в часі, for + тривалість"),
        ]
        for (index, row) in rows.enumerated() {
            let note = Note(deck: deck, front: row.0, back: row.1, sheetRow: 6000 + index)
            context.insert(note)
            for card in context.syncCards(for: note, now: now) {
                // Due reviews rather than new, so a session started from a debug
                // argument opens on one of these instead of behind ten ordinary
                // words. Reviewed cards carry the evidence of their review — see
                // #84: `lastReview` is what the queue reads as "not new".
                card.state = .review
                card.reps = 3
                card.stability = 12
                card.difficulty = 6
                card.lastReview = now.addingTimeInterval(-3 * 86_400)
                card.due = now.addingTimeInterval(-60)
            }
        }
        try? context.save()
    }

    /// One extra card that becomes due a few seconds from now (#98).
    ///
    /// A learning card's timer expiring while the app sits in the background is
    /// the ordinary, every-day version of "the store changed and Home did not
    /// notice" — and unlike a Google sync it can be reproduced in a test without a
    /// spreadsheet, a network or a stub.
    static func seedSoonDue(_ context: ModelContext, inSeconds: TimeInterval = 6, now: Date = .now) {
        guard let deck = seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first
        else { return }
        let note = Note(deck: deck, front: "soon", back: "незабаром", sheetRow: 7000)
        context.insert(note)
        for card in context.syncCards(for: note, now: now) {
            card.state = .learning
            card.reps = 1
            card.stability = 1
            card.difficulty = 6
            card.lastReview = now
            card.due = now.addingTimeInterval(inSeconds)
        }
        try? context.save()
    }

    /// Wipes every model, so a UI test starts from a known empty store (#39).
    static func eraseEverything(_ context: ModelContext) {
        try? context.delete(model: ReviewLog.self)
        try? context.delete(model: Card.self)
        try? context.delete(model: Note.self)
        try? context.delete(model: Deck.self)
        try? context.delete(model: InboxItem.self)
        try? context.delete(model: SyncConflict.self)
        try? context.save()
        // The introduced-today counter lives in the logs that were just deleted,
        // so the new-card allowance resets with them — which is the point: a UI
        // test that seeds a deck must actually be able to study it.
    }

    /// A few days of nightly backups, so §8's list has something in it to
    /// screenshot without waiting a week.
    static func seedBackups(_ context: ModelContext, now: Date = .now, days: Int = 3) {
        let calendar = Calendar.current
        for day in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            try? BackupRunner.run(in: context, now: date)
        }
    }

    #endif
}