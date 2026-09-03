# Repeat — iOS Spaced-Repetition App
## Implementation Specification

Version 1.1 · Personal-use app, no App Store distribution

Changes in 1.1: the four questions in §10 are resolved (see §10 for the decisions and
their reasoning). Affected sections: §3.1, §3.2, §4.3, §4.4, §5.1, §6.3, §6.6, §8.

---

## 1. Overview

Repeat is a personal flashcard app for iPhone. Card content lives in a Google Sheet (one worksheet per deck) that the owner edits either in Google Sheets or in the app. Review scheduling uses FSRS-6. The app is offline-first, sideloaded via Xcode onto a single device.

### 1.1 Goals
- Daily review session that takes under 10 minutes and starts with one tap.
- Adding a card takes seconds from anywhere on the phone.
- Google Sheet is the single source of truth for card **content**; the phone is the single source of truth for **scheduling state**.
- Scheduling quality on par with modern Anki (FSRS-6), with user-tunable parameters.

### 1.2 Non-goals
- Multi-user accounts, App Store review, in-app purchases.
- Anki `.apkg` import/export (may be added later as a Python script that writes to the Sheet).
- Rich card templates, HTML/LaTeX rendering, images or audio attachments in v1.
- Sync with AnkiWeb.

---

## 2. Platform and stack

| Concern | Decision |
|---|---|
| Target | iOS 17+, iPhone only, portrait |
| Language / UI | Swift 5.10+, SwiftUI |
| Local storage | SwiftData (SQLite-backed) |
| Scheduling | `open-spaced-repetition/swift-fsrs` (FSRS-6) via Swift Package Manager |
| Remote store | Google Sheets API v4 (REST, no Google SDK) |
| Auth to Sheets | Google service account; JWT signed on device (RS256 via `SecKeyCreateSignature`); key stored in Keychain |
| AI autofill | Anthropic Messages API (`POST /v1/messages`), model id configurable in Settings |
| Speech | `AVSpeechSynthesizer` (offline) |
| Widgets / notifications | WidgetKit, `UNUserNotificationCenter` |
| Extensions | Share Extension target (App Group for shared container) |
| Concurrency | Swift Concurrency (`async/await`, actors); network and sync isolated in a `SyncActor` |
| Min. testing | Unit tests for sync merge rules and scheduling wrappers; UI tests for the study loop |

---

## 3. Data model

### 3.1 Google Sheet layout

One spreadsheet. Each worksheet (tab) is a deck, except reserved tabs prefixed with `_`.

**Deck worksheet — columns (row 1 is the header, exact names):**

| Column | Type | Required | Notes |
|---|---|---|---|
| `id` | string (UUID v4) | yes* | *App fills it in if a manually added row is missing it |
| `front` | string | yes | Question / prompt. Plain text; `\n` allowed |
| `back` | string | yes | Answer |
| `example` | string | no | Usage example, shown under the answer |
| `tags` | string | no | Comma-separated |
| `reverse` | `TRUE`/`FALSE` | no | If TRUE, also generate a back→front card. Default FALSE |
| `updated_at` | ISO 8601 UTC | no | App writes it; used as a tiebreaker only |
| `deleted` | `TRUE`/`FALSE` | no | Soft delete from the app. Rows physically removed in Sheets are treated the same |

Rows with empty `front` **and** `back` are ignored. Column order is not significant; the app resolves columns by header name.

**Extra columns (D1).** Any header not listed above is an *extra*: its value is carried
through to the phone and displayed under the answer, in header order (§6.3). Adding a
`pronunciation` or `synonyms` column in Sheets therefore needs no app change. Rules:

- Header names are matched case-insensitively and trimmed; a duplicate header after
  normalisation is a malformed deck (§4.6).
- An extra with an empty value renders nothing — no blank line.
- Extras are part of the content hash (§3.2), so editing one propagates like any edit.
- The phone never invents extra columns, and never reorders or removes them on push.
- `example` stays a first-class field rather than an extra, because §6.3 gives it its own
  placement and styling under the answer.

**Reserved worksheets:**

- `_log` — append-only review log. Columns: `card_id, direction (fwd|rev), rating (1–4), reviewed_at (ISO UTC), elapsed_days, scheduled_days, state_before (new|learning|review|relearning)`. Written by the phone only. Input for the FSRS optimizer.
- `_meta` — key/value. Keys used: `schema_version`, `fsrs_params` (JSON array of 21 floats, optional), `desired_retention` (default 0.9).

### 3.2 Local SwiftData models

```swift
@Model final class Deck {
  @Attribute(.unique) var sheetTitle: String   // worksheet name
  var sheetId: Int                              // gid, for range addressing
  var colorHex: String
  var newCardsPerDay: Int = 15
  var sortOrder: Int
  @Relationship(deleteRule: .cascade) var notes: [Note]
}

@Model final class Note {                        // one Sheet row
  @Attribute(.unique) var id: UUID
  var deck: Deck
  var front: String
  var back: String
  var example: String?
  var tags: [String]
  var reverse: Bool
  var extras: [String: String]                  // D1: columns not in §3.1, keyed by header
  var extraOrder: [String]                      // header order, for display
  var contentHash: String                       // sha256 over front|back|example|tags|reverse
                                                //   then each extra as key|value in extraOrder
  var updatedAt: Date
  var isDeleted: Bool
  var pendingUpload: Bool                       // created/edited locally, not yet pushed
  @Relationship(deleteRule: .cascade) var cards: [Card]
}

@Model final class Card {                        // one schedulable direction of a Note
  @Attribute(.unique) var id: String            // "\(note.id)#fwd" or "#rev"
  var note: Note
  var direction: Direction                      // .forward | .reverse
  // FSRS state — mirrors swift-fsrs Card
  var state: CardState                          // new / learning / review / relearning
  var due: Date
  var stability: Double
  var difficulty: Double
  var elapsedDays: Int
  var scheduledDays: Int
  var reps: Int
  var lapses: Int
  var lastReview: Date?
  var isSuspended: Bool                         // leech or manual
}

@Model final class ReviewLog {
  var cardId: String
  var rating: Int
  var reviewedAt: Date
  var elapsedDays: Int
  var scheduledDays: Int
  var stateBefore: CardState
  var uploaded: Bool
  // snapshot of Card before the review, for undo:
  var prevState: Data                           // encoded Card scheduling fields
}

@Model final class InboxItem {                   // quick capture, no answer yet
  var id: UUID; var text: String; var createdAt: Date; var sourceURL: String?
}
```

Rule: **`Note` fields come from the Sheet; `Card` fields never leave the phone** (except via `_log`).

Reverse cards share one `Note` (D2): a row with `reverse=TRUE` yields two `Card`s,
`#fwd` and `#rev`, scheduled independently against the same content. Editing the row
updates both directions at once, so they cannot drift apart.

---

## 4. Sync

### 4.1 Auth

- Service-account JSON is pasted once into Settings → stored in Keychain (`kSecAttrAccessibleAfterFirstUnlock`). Never logged.
- **Amended by #78 — the key *may* be bundled, for this owner's own builds.** This app has one user, and re-pasting the key after every install and every simulator wipe bought nothing. `Config/DefaultConnection.json` (gitignored, generated by `scripts/set-default-connection.sh`) is copied into the app bundle and seeded into the Keychain on first launch. Three constraints hold the original intent:
  - The key is **still never in git.** That is the rule that matters: a repository is cloned, backed up and scanned, and a key in its history is permanent.
  - Seeding runs **once**, recorded by `google.defaultConnectionSeeded`, so deleting the key in Settings is not undone by the next launch, and a key or spreadsheet id the owner set by hand is never overwritten.
  - The payload is optional. With the file absent — a clean clone, CI, anyone else's checkout — the app behaves exactly as the bullet above describes.
  - **Accepted cost:** a bundled key is extractable from an `.ipa`. Fine for a personal build; **rotate the key before distributing the app to anyone.**
- Access token: build JWT `{iss, scope: https://www.googleapis.com/auth/spreadsheets, aud: https://oauth2.googleapis.com/token, iat, exp}`, sign RS256 with the private key, exchange at the token endpoint. Cache token in memory until 5 min before expiry.
- Spreadsheet ID is a Settings field. The sheet must be shared with the service-account email (editor).

### 4.2 Triggers

1. App becomes active (throttled: not more than once per 10 min unless pull-to-refresh).
2. Pull-to-refresh on Home.
3. After a card is created/edited in the app (push only, debounced 3 s).
4. After a study session ends (push `_log`).
5. Background refresh (`BGAppRefreshTask`) once a day if the app hasn't been opened.

Sync never blocks the UI. Home shows a subtle "Synced 2 min ago" / "Offline — changes will sync later" line.

### 4.3 Pull algorithm

1. `GET spreadsheets/{id}?fields=sheets.properties` → list of worksheets. Create/rename/delete local `Deck`s to match (tabs starting with `_` skipped). A deleted tab soft-deletes its notes (cards kept 30 days for recovery, then purged).
2. `GET spreadsheets/{id}/values:batchGet?ranges=<every deck tab>` in one request.
3. For each row:
   - No `id` → generate UUID, mark row for **write-back** of the id (batched at step 5).
   - `id` unknown locally → create `Note` + `Card`(s).
   - `id` known → compute `contentHash`; if changed, update `Note` content, including extras and their header order (D1). **Card scheduling untouched.** If `reverse` flipped, add/remove the reverse `Card` (removed cards are deleted along with their logs remaining in `_log`).
   - Row missing locally-known `id`, or `deleted=TRUE` → soft-delete `Note`, suspend cards.
4. Notes that are `pendingUpload` locally are not overwritten by the pull in this run (push wins once, then normal rules apply).
5. Write back generated ids with `values:batchUpdate` (`RAW` input).

### 4.4 Push algorithm

- New notes: `values:append` to the deck tab, `USER_ENTERED`, one call per deck per sync.
- Edited notes: locate row by scanning the `id` column fetched in the last pull (row index cached; re-fetch the `id` column if the cached index doesn't match). `values:update` the row. Extra columns are written back at the header position they were read from; the phone never adds, reorders or drops a column (D1).
- Deleted notes: set `deleted=TRUE` on the row (never delete rows from the phone).
- `_log`: append all `ReviewLog` rows with `uploaded=false`, then mark uploaded. Chunked ≤ 500 rows per request.

### 4.5 Conflict rules (fixed, no prompts)

| Situation | Winner |
|---|---|
| Same note edited in Sheet and app since last sync | Sheet content wins; app edit is discarded and shown in a "Sync conflicts" list so it can be re-applied |
| Row deleted in Sheet, reviewed on phone meanwhile | Delete wins; log stays in `_log` |
| Sheet unreachable | Everything queues; app fully usable offline |

### 4.6 Failure handling

- Quota / 5xx: exponential backoff (1, 2, 4, 8 min), max 5 tries, then wait for next trigger.
- Malformed header (missing `front` or `back` column): deck is skipped and flagged on Home with the reason.
- Auth failure: banner "Google Sheet access failed — check the service account key", link to Settings.

---

## 5. Scheduling

### 5.1 Engine

- `swift-fsrs`, FSRS-6, `desired_retention` default 0.90 (Settings slider 0.80–0.95).
- **FSRS-6 is opt-in and easy to miss.** The library's `defaultW` is the 19-element FSRS-5
  vector, kept for test parity; FSRS-6 is selected by passing the 21-element
  `FSRSDefaults.defaultWv6`. The package is pinned to a revision rather than a tag because
  no release contains FSRS-6 (see the repo README).
- Parameters: default FSRS-6 weights, overridable by `_meta.fsrs_params` (so the optimizer
  output can be pasted into the sheet without a rebuild). `_meta.fsrs_params` **must be
  exactly 21 floats**; the app rejects any other length with a "Needs attention" entry
  rather than applying it. `FSRSAlgorithmVersion.detect` treats any non-21 length as v5, so
  a 20-float paste would otherwise silently downgrade every future interval.
- Learning steps for new cards: `1m, 10m` (short-term scheduler). Relearning step after a
  lapse: `10m` (D3). These are the library's own defaults, so no custom step machinery is
  needed. Steps are not a pure UI setting: when the relearning-step count exceeds 1 the
  library derives a tighter ceiling for `w[17]`/`w[18]`, so changing them changes parameter
  clamping too. Revisit once the optimizer has run on real `_log` data.
- Rating → FSRS grade: Again=1, Hard=2, Good=3, Easy=4.
- Same-day repeats stay in the session queue; cards due later today do not.

### 5.2 Daily queue

Built once when a session starts (and rebuilt on resume if the day changed):

1. **Due reviews** — all cards with `due <= now` and `state != new`, ordered by `due` ascending, then random within the same day.
2. **New cards** — up to `newCardsPerDay` per deck (default 15, global cap 30), in sheet row order.
3. **Learning** cards re-enter the queue when their intra-day timer expires.

Home shows: total due, estimated minutes (due × avg seconds per card, from the last 200 logs, default 20 s).

### 5.3 Catch-up mode

If due reviews > 2 × the 14-day average daily count (and > 50), Home offers **"Spread over 3 days"**. Accepting reschedules the excess by moving `due` forward 1–2 days (FSRS `reschedule` keeps stability), picking the cards with the highest retrievability first, so the most fragile memories are reviewed today.

### 5.4 Leeches

A card with `lapses >= 8` is marked a leech: suspended, shown in Home under "Needs attention" with actions **Rewrite** (opens editor, resets lapses to 0 and unsuspends) or **Delete**.

### 5.5 Undo

The last rating in the session can be undone (button + shake gesture). Restores the `Card` snapshot from `ReviewLog.prevState`, deletes that log entry (if not yet uploaded; if uploaded, appends a `rating=0` "undo" row to `_log`), and puts the card back at the front of the queue.

---

## 6. Screens and flows

Design reference: **`Repeat/Theme/Palette.swift`**, with `AccessibilityTests` holding it to account. `anki-ios-mockup.html` was the reference through M0–M7 and is kept as a record, but #89 chose a warmer, more app-like direction and the file is marked superseded — do not copy values out of it. Copy is Ukrainian in the UI; the spec uses English labels for clarity.

### 6.1 Onboarding (first launch only, 3 screens, skippable)
1. "Recall, don't reread" — shows a real card component, explains tap-to-reveal.
2. "Rate honestly" — the four buttons with the interval preview under each.
3. "10 minutes a day" — streak calendar, explains that skipped days accumulate.
Then → **Settings setup** sheet: paste service-account JSON, paste spreadsheet ID, test connection, first sync. Onboarding can be replayed from Settings.

### 6.2 Home
- Greeting, big due count, estimated minutes, primary button **Start review** (disabled state when 0 due: "All done — see you tomorrow").
- Deck list: color swatch, title, card count / new today, due badge. Tap deck → study that deck only. Swipe → Deck settings (new cards/day, color, suspend all).
- "Needs attention" section (leeches, sync conflicts, malformed decks) — hidden when empty.
- Sync status line; pull-to-refresh.
- Tab bar: Decks · Add · Stats.

### 6.3 Study
- Top: close, progress bar, `n / total`.
- Card fills the screen; front centered, "Tap to reveal" hint. Tap or swipe up reveals back + example, then any extra columns as secondary lines in header order (D1); the four rating buttons appear only after reveal (prevents accidental grading).
- Each button shows the next interval (`1m`, `10m`, `3d`, `12d`), computed live from FSRS for that card.
- Gestures (optional, on by default): swipe left = Again, right = Good; long-press reveal = play TTS.
- Haptics: light on reveal, notification-warning on Again.
- Undo button top-right (enabled after first rating).
- Auto-TTS toggle per deck: speak `front` on show.
- Type-answer mode per deck: text field replaces tap-to-reveal; on submit shows diff against `back`, then the same four buttons.
- Session end → **Done** screen: reviewed / forgotten / streak, buttons **Back to decks**, **Add new cards**.

### 6.4 Add card
- Deck chips (last used preselected), Front, Back, Example, Reverse toggle.
- **Autofill** button next to Back: sends `front` + deck title to the Anthropic API and fills `back` and `example`. Prompt asks for JSON `{back, example}` only; response is parsed defensively; failure shows "Couldn't autofill" and keeps the fields editable. Never called automatically.
- **Save and add another** (fields clear, Front focused, toast "Saved") / **Done**.
- Inbox section: quick-captured items; tap opens them in the form with Front prefilled.

### 6.5 Stats (minimal)
- Streak, reviews last 7 / 30 days, retention (Good+Easy ÷ all, last 30 days), 7-day forecast bar chart of due cards, per-deck counts. All computed from local `ReviewLog` and `Card`.

### 6.6 Settings
- Google: service-account JSON (masked), spreadsheet ID, test connection, "Sync now", "Re-download everything" (wipes notes, keeps scheduling by card id).
- Recovery: "Restore from backup" (pick one of the last 7 snapshots) and "Rebuild scheduling from `_log`" (D4) — the latter warns that it replaces all local scheduling state and shows how many log rows will be replayed.
- Scheduling: desired retention, global new-card cap, learning steps, leech threshold.
- Reminder: time picker, on/off.
- AI autofill: API key (Keychain), model id, on/off.
- Replay onboarding. Export local DB (share sheet). App version.

---

## 7. System integrations

### 7.1 Widgets (WidgetKit)
- Lock-screen circular + rectangular and Home-screen small: due count, deep link `repeat://study`. Timeline refreshes at midnight and after each session via `WidgetCenter.reloadAllTimelines()`.

### 7.2 Notifications
- One local notification per day at the chosen time, body "N cards to review". Scheduled at session end for the next day; **cancelled** if the queue is already empty at that time (checked in the background refresh task). No notification is ever sent when due = 0.

### 7.3 Share Extension
- Accepts plain text and URLs. Shows a minimal sheet: text (prefilled with the shared selection), deck picker, **Add to inbox** / **Save as card** (opens autofill if enabled). Writes to the App Group container; the main app picks it up on next launch.

### 7.4 Shortcuts / Action button
- App Intents: `AddCardIntent(front:deck:)`, `StartReviewIntent()`, `DueCountIntent()`. Enables Action-button and Siri use.

---

## 8. Non-functional requirements

- **Offline-first**: every screen works with no network; sync is additive.
- **Performance**: study screen transitions < 100 ms; queue build for 10k cards < 300 ms on device; sync of 5k rows < 10 s on Wi-Fi.
- **Data safety** (D4): two independent recovery paths, no iCloud Drive mirror.
  1. *Snapshot* — nightly automatic export of `Card` scheduling fields to a `_backup` JSON
     file in the app's Documents folder (last 7 kept), restorable from Settings. iOS
     already includes Documents in iCloud device backup, so this is off-device for free;
     the files must therefore **not** be marked `isExcludedFromBackup`.
  2. *Replay* — `_log` in the Sheet is a complete review history, and fuzz is disabled, so
     replaying it through FSRS reproduces every card's due date deterministically. This
     survives losing the device entirely, which a local snapshot does not. Exposed as
     "Rebuild scheduling from `_log`" in Settings (§6.6).

  Replay is the stronger guarantee and the reason an iCloud Drive mirror was dropped: it
  covers the case the mirror was meant to cover, at lower cost, using data the app already
  writes. Restoring a snapshot is still preferred when available, because it is exact and
  instant; replay is the fallback when there is no snapshot to restore.
- **Security**: all secrets in Keychain; no third-party analytics; network calls only to `googleapis.com` and `api.anthropic.com`.
- **Accessibility**: Dynamic Type up to XXL on all text; VoiceOver labels on rating buttons include the interval; reduced-motion disables the flip animation.
- **Localization**: UI strings in a `Localizable.xcstrings` catalog; Ukrainian primary, English fallback.

---

## 9. Milestones

| # | Deliverable | Acceptance |
|---|---|---|
| 1 | SwiftData models, FSRS wrapper, study loop with local sample data | Can review a hard-coded deck end to end, intervals shown, undo works |
| 2 | Google Sheets read-only sync | Decks and cards appear from the sheet; edits in the sheet propagate; ids written back |
| 3 | Two-way sync + `_log` | Cards added in-app appear in the sheet; log rows appended; offline queue drains |
| 4 | Home, Add, Done, Settings, onboarding | Matches mockup; first-run setup completes without Xcode |
| 5 | Widget, notification, Share Extension, App Intents | Widget count matches Home; reminder fires only when due > 0 |
| 6 | Autofill, TTS, type-answer, catch-up, leeches, Stats | Each feature toggleable; no crashes on API failure |
| 7 | Backup/restore, tests, polish | Restore from `_backup` reproduces due dates exactly; rebuild from `_log` reproduces them too (D4) |

---

## 10. Resolved decisions

The four questions this section used to hold are settled. Each decision is recorded with the
reasoning, so a later reader can tell what was chosen deliberately from what was never
considered. Referenced elsewhere in the spec as D1–D4.

### D1 — Extra Sheet columns are displayed, not ignored

*Question: should `example` be optional per deck, or should the Sheet allow arbitrary extra
columns shown as secondary lines?*

**Decision: any header not in §3.1 is an extra, carried to the phone and displayed under the
answer in header order.** `example` stays first-class because §6.3 gives it its own placement.

The Sheet is the source of truth for content, and this keeps that true for *kinds* of content
too — a `pronunciation` column can be added in Sheets without an app change, the same reason
`fsrs_params` lives in `_meta`. The alternative works, but makes every new kind of content a
spec change and a rebuild. Cost is contained: `Note` gains `extras` and `extraOrder`, and the
content hash covers them. See §3.1, §3.2, §4.3, §4.4, §6.3.

### D2 — Reverse cards share one Note

*Question: share one `Note` (as specified) or duplicate rows in the Sheet?*

**Decision: keep the shared `Note`.** A row with `reverse=TRUE` produces `#fwd` and `#rev`
Cards, scheduled independently against one piece of content.

Duplication's only real advantage is legibility in Sheets, which the `reverse` column already
provides. Against it: content must be edited twice, so the two directions can silently drift
apart — the failure would be invisible in the app and annoying to repair in the Sheet. The
`Card.id` scheme in §3.2 was already designed around sharing; duplicating would leave the
`#fwd`/`#rev` suffix vestigial.

### D3 — Learning steps stay at 1m / 10m

*Question: keep Anki-style `1m 10m`, or trust FSRS-6 short-term scheduling with no fixed
steps?*

**Decision: keep `1m, 10m` for learning and `10m` for relearning.**

These are the pinned library revision's own defaults (`FSRSDefaults.defaultLearningSteps`,
`defaultRelearningSteps`), so the familiar behaviour is also the zero-effort one. The mockup
already draws `1m` and `10m` on the rating buttons. The decision is not free to revisit later:
relearning-step count above 1 tightens the `w[17]`/`w[18]` ceiling, so steps and parameter
clamping are coupled. Worth reopening once the optimizer has run on real `_log` data, which is
the point at which there is evidence rather than preference. See §5.1.

### D4 — No iCloud Drive mirror; rebuild from `_log` instead

*Question: is a `_backup` mirror to iCloud Drive wanted, given the device is the only holder
of scheduling state?*

**Decision: no mirror. Keep the local nightly `_backup` snapshot, and add "Rebuild scheduling
from `_log`" to Settings.**

The mirror was meant to cover losing the device. Two things already cover it better. iOS
includes the app's Documents folder in iCloud device backup, so the snapshot is off-device
without any entitlement — provided the files are not marked `isExcludedFromBackup`. And `_log`
in the Sheet is a full review history; with fuzz disabled, replaying it through FSRS
reproduces every due date deterministically. Replay survives losing the phone *and* having
iCloud Backup switched off, which the mirror would not have improved on, and it reuses data
the app already writes rather than adding a container and conflict handling.

Snapshot restore stays the preferred path when a snapshot exists — it is exact and instant.
Replay is the fallback. See §8, §6.6.

---

## Appendix A — Autofill prompt (initial)

System: *You fill in flashcards. Reply with JSON only: `{"back": string, "example": string}`. `back` is a concise answer in Ukrainian; `example` is one short sentence in the source language using the term. No markdown.*

User: `Deck: {deck title}\nFront: {front}`

Parse: strip code fences, `JSONDecoder`; on failure retry once with "Reply with valid JSON only." appended.

## Appendix B — Sheet example

```
id     | front     | back      | example                                | tags  | reverse | pronunciation
3f1c…  | reluctant | неохочий  | He was reluctant to admit the mistake. | verbs | TRUE    | /rɪˈlʌktənt/
       | thorough  | ретельний |                                        |       |         |
```

Second row has no id → app assigns one on next sync.

`pronunciation` is not in §3.1, so it is an extra (D1): carried to the phone and shown under
the answer, below `example`. The second row leaves it empty, which renders nothing. The first
row has `reverse=TRUE`, so it produces two independently scheduled cards from this single row
(D2).
