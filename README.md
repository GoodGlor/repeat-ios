# Repeat

Personal iOS spaced-repetition app. Card content lives in a Google Sheet (one worksheet per deck);
scheduling state lives on the phone (FSRS-6). Offline-first, sideloaded via Xcode — no App Store.

- **Platform:** iOS 17+, iPhone, portrait · Swift 5.10+ / SwiftUI / SwiftData
- **Scheduling:** [`swift-fsrs`](https://github.com/open-spaced-repetition/swift-fsrs) (FSRS-6)
- **Remote store:** Google Sheets API v4 (service account, JWT signed on device)
- **UI language:** Ukrainian primary, English fallback

## Docs

| File | What it is |
|---|---|
| [`docs/repeat-app-spec.md`](docs/repeat-app-spec.md) | Implementation specification v1.0 — data model, sync, scheduling, screens, milestones |
| [`docs/anki-ios-mockup.html`](docs/anki-ios-mockup.html) | Interactive design mockup (open in a browser) — the visual reference for all screens |

## Building

The Xcode project is **generated** — `project.yml` is the source of truth, `Repeat.xcodeproj`
is gitignored. Adding a file to the right folder on disk is enough; no project file to merge.

```sh
brew install xcodegen          # once
xcodegen generate              # after any project.yml change or target/file addition
open Repeat.xcodeproj
```

If `xcodebuild` reports that it requires Xcode, the active developer directory is pointing at
the Command Line Tools. Either `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
once, or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
xcodebuild -project Repeat.xcodeproj -scheme Repeat \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

### Signing

Simulator builds need no setup. For a device build, copy the template and fill in your Team ID:

```sh
cp Config/Local.xcconfig.template Config/Local.xcconfig
```

`Config/Local.xcconfig` is gitignored, so the Team ID never enters the repo.

> **App Groups require a paid Apple Developer Program membership.** On a free personal team the
> entitlement is rejected, `AppGroup.containerURL` returns `nil`, and the widget and Share
> Extension cannot exchange data with the app.

## Targets

| Target | Bundle ID | Purpose |
|---|---|---|
| `Repeat` | `com.goodglor.repeat` | The app. iOS 17+, iPhone, portrait. URL scheme `repeat://` |
| `RepeatWidget` | `com.goodglor.repeat.widget` | WidgetKit due count (spec §7.1) |
| `RepeatShareExtension` | `com.goodglor.repeat.share` | Quick capture from anywhere (spec §7.3) |
| `RepeatTests` | `com.goodglor.repeat.tests` | Unit tests |

All three share the App Group `group.com.goodglor.repeat`.

## The `Scheduling` package

`Packages/Scheduling` is a local Swift package that owns `swift-fsrs` outright. **The app does not
depend on the library and must not.** The reason is concrete: `swift-fsrs` exports `Card`,
`CardState` and `ReviewLog`, all names the app also declares, and its module cannot disambiguate
them — the package contains a *class* named `FSRS` which shadows the module, so `FSRS.Card`
resolves to a member of the class and fails to compile. Inside the package no such names exist, so
the library's types resolve cleanly.

The package exposes value types (`CardSchedulingSnapshot`, `Grade`, `SchedulingState`,
`GradePreview`, `GradeOutcome`) and the app maps its SwiftData models to them. The boundary is
enforced by the build rather than by convention.

```sh
cd Packages/Scheduling && swift test     # fast, no simulator needed
```

The FSRS dependency is pinned to an exact **revision**, not a tag, in the package's `Package.swift`.
Spec §5.1 requires FSRS-6 (21-parameter `w`), which is merged on `swift-fsrs` `main` but is not in
any release — the newest tag, `v5.0.0`, is FSRS-5 only. Revisit the pin when upstream tags a release
containing `BasicSchedulerV6`.

## Work tracking

Tasks are cards on the **Repeat iOS** project board, grouped by the milestones in §9 of the spec.
