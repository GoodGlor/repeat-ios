import Foundation
import SwiftData
import Scheduling
import UIKit

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

    /// A history whose longest streak is an *older* run, so today's session
    /// overtakes it: three days 8–6 days ago, a gap, three days 3–1 days ago.
    /// Finishing a session today makes the current run four — a new record —
    /// while the backlog seed's unbroken fortnight would only be extended.
    static func seedRecordHistory(_ context: ModelContext, reviewsPerDay: Int = 5, now: Date = .now) {
        let calendar = Calendar.current
        guard seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first != nil
        else { return }
        for day in [8, 7, 6, 3, 2, 1] {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            for index in 0..<reviewsPerDay {
                guard let log = try? ReviewLog(
                    cardId: "record-\(day)-\(index)", direction: .forward,
                    rating: Grade.good.rawValue, reviewedAt: date,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(), uploaded: true
                ) else { continue }
                context.insert(log)
            }
        }
        try? context.save()
    }

    /// #112's layout check: a history that makes a finished session fill all
    /// five of `Celebration`'s lines at once.
    ///
    /// Fourteen days reviewed, 15 to 2 days ago, and nothing yesterday — so two
    /// freezes are earned and Home's settle spends one on yesterday (freeze).
    /// Seven Good a day is 98 × 3 = 294 XP, level 1, and the session's ten Easy
    /// add 40 and cross 300 (level). Today's run bridges the frozen day past the
    /// fourteen-day record, and ten reviews beat a best day of seven (record).
    /// Finishing the plan closes the goal, and the streak and perfect-session
    /// badges come with it.
    static func seedFullCelebration(_ context: ModelContext, now: Date = .now) {
        let calendar = Calendar.current
        guard seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first != nil
        else { return }
        for day in 2...15 {
            guard let date = calendar.date(byAdding: .day, value: -day, to: now) else { continue }
            for index in 0..<7 {
                guard let log = try? ReviewLog(
                    cardId: "celebration-\(day)-\(index)", direction: .forward,
                    rating: Grade.good.rawValue, reviewedAt: date,
                    elapsedDays: 1, scheduledDays: 1, stateBefore: .review,
                    prevState: CardSchedulingSnapshot(), uploaded: true
                ) else { continue }
                context.insert(log)
            }
        }
        try? context.save()
    }

    /// #144: the sample deck with real tags instead of one "sample" on every
    /// note — two verbs, five adjectives and one note with no tag, so the deck
    /// screen's filter has every kind of choice to offer.
    static func seedTags(_ context: ModelContext) {
        guard let deck = seedIfEmpty(context) else { return }
        let verbs: Set<String> = ["linger", "dwindle"]
        for note in deck.notes {
            note.tags = note.front == "wary" ? [] : verbs.contains(note.front) ? ["verbs"] : ["adjectives"]
            note.refreshContentHash()
            note.lastSyncedHash = note.contentHash
        }
        try? context.save()
    }

    /// A second deck with every §5.3 bucket in it, beside the sample deck that
    /// has none reviewed. Six known — four crossed the 21-day line seconds ago
    /// (this month whatever the date), two crossed forty days ago and were
    /// reviewed again since — three learning, two new. The crossings are
    /// written as `_log` rows with the card's state *before* them, which is
    /// what `Mastery.becameKnown` reads.
    static func seedMastery(_ context: ModelContext, now: Date = .now) {
        guard seedIfEmpty(context) ?? (try? context.fetch(FetchDescriptor<Deck>()))?.first != nil
        else { return }
        let deck = Deck(sheetTitle: "Англійська — прикметники", sheetId: 1,
                        colorHex: "#37689D", newCardsPerDay: 15, sortOrder: 1)
        context.insert(deck)

        func note(_ front: String, _ back: String, row: Int) -> Card? {
            let made = Note(deck: deck, front: front, back: back, sheetRow: 8000 + row)
            context.insert(made)
            return context.syncCards(for: made, now: now).first
        }
        func crossing(_ card: Card, at: Date, prevStability: Double) {
            guard let log = try? ReviewLog(
                cardId: card.id, direction: card.direction, rating: Grade.good.rawValue,
                reviewedAt: at, elapsedDays: 5, scheduledDays: 30, stateBefore: .review,
                prevState: CardSchedulingSnapshot(state: .review, due: at, stability: prevStability,
                                                  difficulty: 5, elapsedDays: 5, scheduledDays: 10,
                                                  reps: 5, lastReview: at.addingTimeInterval(-5 * 86_400)),
                uploaded: true
            ) else { return }
            context.insert(log)
        }
        func known(_ card: Card, stability: Double, lastReview: Date, dueInDays: Double) {
            card.state = .review
            card.reps = 6
            card.difficulty = 5
            card.stability = stability
            card.lastReview = lastReview
            card.due = now.addingTimeInterval(dueInDays * 86_400)
        }

        let thisMonth = [("harbour", "гавань"), ("meadow", "лука"), ("stubborn", "впертий"), ("gentle", "лагідний")]
        for (index, word) in thisMonth.enumerated() {
            guard let card = note(word.0, word.1, row: index) else { continue }
            let at = now.addingTimeInterval(-Double(index + 1) * 1)
            known(card, stability: 30, lastReview: at, dueInDays: 20)
            crossing(card, at: at, prevStability: 10)
        }

        let earlier = [("candle", "свічка"), ("river", "річка")]
        for (index, word) in earlier.enumerated() {
            guard let card = note(word.0, word.1, row: 10 + index) else { continue }
            let recent = now.addingTimeInterval(-5 * 60)
            known(card, stability: 40, lastReview: recent, dueInDays: 25)
            crossing(card, at: now.addingTimeInterval(-40 * 86_400), prevStability: 10)
            crossing(card, at: recent, prevStability: 25)
        }

        let learning = [("pebble", "камінець"), ("whisper", "шепіт"), ("crumble", "кришитися")]
        for (index, word) in learning.enumerated() {
            guard let card = note(word.0, word.1, row: 20 + index) else { continue }
            card.state = .review
            card.reps = 2
            card.difficulty = 6
            card.stability = 6
            card.lastReview = now.addingTimeInterval(-2 * 86_400)
            card.due = now.addingTimeInterval(3 * 86_400)
        }

        for (index, word) in [("lantern", "ліхтар"), ("orchard", "сад")].enumerated() {
            _ = note(word.0, word.1, row: 30 + index)
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
        // #112: a freeze surviving a reset would let one UI test's streak bridge a
        // gap in the next one's.
        try? context.delete(model: StreakFreeze.self)
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

    /// #149: the first sample card with a picture, as a sync would leave it —
    /// the link in the `image` extra and the file already downloaded — so the
    /// study screen can be seen without a network or a real Sheet.
    static func seedPictures(_ context: ModelContext) {
        guard let deck = seedIfEmpty(context),
              let note = deck.notes.first(where: { $0.front == "reluctant" }),
              let store = try? PictureStore.standard() else { return }
        let link = "https://example.com/repeat-sample/reluctant.jpg"
        note.extras[CardPicture.column] = link
        if !note.extraOrder.contains(CardPicture.column) { note.extraOrder.append(CardPicture.column) }
        note.refreshContentHash()
        note.lastSyncedHash = note.contentHash
        try? context.save()

        // A drawn landscape, 1200×800: a real JPEG of phone size.
        let size = CGSize(width: 1200, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            let cg = renderer.cgContext
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [UIColor(red: 0.87, green: 0.94, blue: 0.91, alpha: 1).cgColor,
                                          UIColor(red: 0.62, green: 0.80, blue: 0.72, alpha: 1).cgColor] as CFArray,
                                 locations: [0, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(red: 0.98, green: 0.85, blue: 0.55, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 820, y: 120, width: 180, height: 180))
            UIColor(red: 0.12, green: 0.46, blue: 0.35, alpha: 1).setFill()
            let hill = UIBezierPath()
            hill.move(to: CGPoint(x: 0, y: 560))
            hill.addCurve(to: CGPoint(x: 1200, y: 520), controlPoint1: CGPoint(x: 400, y: 380),
                          controlPoint2: CGPoint(x: 800, y: 700))
            hill.addLine(to: CGPoint(x: 1200, y: 800)); hill.addLine(to: CGPoint(x: 0, y: 800)); hill.close()
            hill.fill()
        }
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try? image.jpegData(compressionQuality: 0.8)?.write(to: store.fileURL(for: link), options: .atomic)
    }
    #endif
}