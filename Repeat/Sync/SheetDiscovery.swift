import Foundation
import SwiftData
import GoogleSheets
import Scheduling

/// What one discovery pass learned about the spreadsheet (§4.3 step 1, §3.1).
struct DiscoveryResult: Equatable {
    /// Decks that parsed, with the header map their rows must be read through.
    var readable: [String: HeaderMap] = [:]
    /// Decks skipped, and why — shown under "Needs attention" on Home (§4.6).
    var malformed: [String: String] = [:]
    var reconciliation = DeckReconciler.Outcome()
    /// Scheduling configuration the Sheet owns (§5.1).
    var schedulerConfig = SchedulerConfig()
    /// What `_meta` actually supplied, as opposed to what defaulted. The
    /// difference matters: Settings has to show a retention slider the Sheet is
    /// overriding as overridden, rather than letting it look broken.
    var metaOverrides = SchedulingOverrides()
    /// Problems with `_meta` itself, also surfaced rather than swallowed.
    var metaProblems: [String] = []
    /// Whether the `_log` tab exists yet. The phone creates it on the first push
    /// (#17) rather than requiring the owner to have set it up.
    var hasLogSheet = false
}

/// Reads the spreadsheet's shape: which tabs are decks, how each deck's columns
/// are laid out, and what `_meta` says.
struct SheetDiscovery {
    let client: SheetsClient

    init(client: SheetsClient) {
        self.client = client
    }

    /// - Note: one deck's bad header must not stop the others. §4.6 requires the
    ///   broken deck to be skipped and flagged while the rest sync normally.
    func run(in context: ModelContext, now: Date = .now) async throws -> DiscoveryResult {
        var result = DiscoveryResult()

        let properties = try await client.sheetProperties()
        result.reconciliation = try DeckReconciler.reconcile(properties: properties, in: context, now: now)

        let deckTitles = properties.filter { !$0.isReserved }.map(\.title)
        let hasMeta = properties.contains { $0.title == MetaSheet.title }
        result.hasLogSheet = properties.contains { $0.title == MetaSheet.logTitle }

        // Header rows for every deck plus `_meta` in one request — the same
        // batching §4.3 step 2 uses for the rows themselves.
        var ranges = deckTitles.map { headerRange(for: $0) }
        if hasMeta { ranges.append("\(quote(MetaSheet.title))!A:B") }

        let fetched = try await client.batchGet(ranges: ranges)
        var byTitle = Dictionary(fetched.map { ($0.sheetTitle, $0) }, uniquingKeysWith: { first, _ in first })

        if hasMeta, let meta = byTitle[MetaSheet.title] {
            applyMeta(MetaSheet.parse(rows: meta.values), to: &result)
        }

        for title in deckTitles {
            let header = byTitle[title]?.values.first ?? []
            do {
                result.readable[title] = try HeaderMap(headerRow: header)
            } catch let failure as HeaderMap.Failure {
                result.malformed[title] = failure.description
            }
        }

        // Record the reason on the deck so Home can show it without re-running
        // discovery.
        for deck in try context.fetch(FetchDescriptor<Deck>()) {
            deck.malformedReason = result.malformed[deck.sheetTitle]
        }

        return result
    }

    /// `_meta` is advisory: a bad value must not stop the sync, but it must not
    /// be applied silently either (§5.1).
    private func applyMeta(_ meta: MetaSheet, to result: inout DiscoveryResult) {
        if let raw = meta.rawFSRSParams {
            do {
                let weights = try SchedulerConfig.weights(fromMeta: raw)
                result.schedulerConfig.weights = weights
                result.metaOverrides.weights = weights
            } catch {
                result.metaProblems.append("fsrs_params: \(error)")
            }
        }
        if let raw = meta.rawDesiredRetention {
            do {
                let retention = try SchedulerConfig.retention(fromMeta: raw)
                result.schedulerConfig.desiredRetention = retention
                result.metaOverrides.retention = retention
            } catch {
                result.metaProblems.append("desired_retention: \(error)")
            }
        }
    }

    /// Only row 1 — the header. Pulling every row here would double the data
    /// fetched for a 5 000-row sheet.
    private func headerRange(for title: String) -> String {
        "\(quote(title))!1:1"
    }

    /// A1 notation quotes titles containing spaces or punctuation, doubling any
    /// apostrophe.
    private func quote(_ title: String) -> String {
        let needsQuoting = title.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        guard needsQuoting else { return title }
        return "'\(title.replacingOccurrences(of: "'", with: "''"))'"
    }
}
