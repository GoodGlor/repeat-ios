import SwiftUI

/// Home's sync line (§6.2). Subtle by design: sync is background work, and the
/// line only earns attention when something needs the owner.
struct SyncStatusLine: View {
    let status: SyncCoordinator.Status
    let lastSyncedAt: Date?
    /// Passed in so the line re-renders as time passes and so tests can pin it.
    var now: Date = .now
    var onOpenSettings: (() -> Void)?

    private var line: SyncStatusFormatter.Line {
        SyncStatusFormatter.line(status: status, lastSyncedAt: lastSyncedAt, now: now)
    }

    var body: some View {
        let line = line
        HStack(spacing: 6) {
            Image(systemName: line.symbol)
                .imageScale(.small)
                .symbolEffect(.pulse, isActive: status == .syncing)
            Text(line.text)
            if line.linksToSettings, onOpenSettings != nil {
                Spacer(minLength: 8)
                Text("Налаштування").underline()
            }
        }
        .font(.footnote)
        .foregroundStyle(tint(line.tone))
        .contentShape(.rect)
        .onTapGesture { if line.linksToSettings { onOpenSettings?() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.text)
        .accessibilityAddTraits(line.linksToSettings ? .isButton : [])
    }

    private func tint(_ tone: SyncStatusFormatter.Tone) -> Color {
        switch tone {
        case .normal: Palette.ink2
        case .waiting: Palette.ink2
        case .attention: Palette.again
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        SyncStatusLine(status: .idle, lastSyncedAt: .now.addingTimeInterval(-120))
        SyncStatusLine(status: .offline, lastSyncedAt: nil)
        SyncStatusLine(status: .syncing, lastSyncedAt: nil)
        SyncStatusLine(status: .failed(message: "Немає доступу до таблиці.", needsAttention: true),
                       lastSyncedAt: nil, onOpenSettings: {})
    }
    .padding()
}
