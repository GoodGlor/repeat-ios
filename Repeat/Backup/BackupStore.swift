import Foundation

/// Where nightly snapshots live and how many are kept (§8).
///
/// Documents, **not** the App Group container. iOS includes an app's Documents
/// folder in iCloud device backup, which is what makes a local snapshot
/// off-device for free (D4) — and is the whole reason the iCloud Drive mirror
/// was dropped. Nothing here may set `isExcludedFromBackup`; `verifyIncluded`
/// exists to make that an assertion rather than a comment.
enum BackupStore {
    static let keepCount = 7
    static let prefix = "_backup-"
    static let fileExtension = "json"

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// One file per day. A second backup on the same day overwrites the first
    /// rather than consuming one of the seven slots — otherwise a week of heavy
    /// use could push out every older snapshot within a day.
    static func filename(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 0, day = parts.day ?? 0
        return String(format: "%@%04d-%02d-%02d.%@", prefix, year, month, day, fileExtension)
    }

    /// The date encoded in a backup's name, or `nil` if the name is not ours.
    ///
    /// Parsed from the name rather than read from the file's creation date: a
    /// restore from an iCloud device backup rewrites file dates, and sorting by
    /// them would then shuffle the history into arbitrary order.
    static func date(fromFilename name: String, calendar: Calendar = .current) -> Date? {
        guard name.hasPrefix(prefix), name.hasSuffix("." + fileExtension) else { return nil }
        let stamp = name.dropFirst(prefix.count).dropLast(fileExtension.count + 1)
        let parts = stamp.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Newest first.
    static func list(in directory: URL = directory, calendar: Calendar = .current) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .compactMap { url -> (URL, Date)? in
                guard let date = date(fromFilename: url.lastPathComponent, calendar: calendar)
                else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    @discardableResult
    static func write(_ backup: SchedulingBackup,
                      in directory: URL = directory,
                      calendar: Calendar = .current) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(
            filename(for: backup.createdAt, calendar: calendar)
        )
        try backup.encoded().write(to: url, options: .atomic)

        // Belt and braces: a file written where an excluded one stood inherits
        // nothing, but an explicit `false` also documents the requirement at the
        // only place that could break it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? url.setResourceValues(values)

        return url
    }

    static func read(_ url: URL) throws -> SchedulingBackup {
        try SchedulingBackup.decoded(from: Data(contentsOf: url))
    }

    /// Deletes everything past the newest `keepCount`. Returns what it removed.
    @discardableResult
    static func prune(keeping keepCount: Int = keepCount,
                      in directory: URL = directory,
                      calendar: Calendar = .current) -> [URL] {
        let stale = list(in: directory, calendar: calendar).dropFirst(keepCount)
        var removed: [URL] = []
        for url in stale where (try? FileManager.default.removeItem(at: url)) != nil {
            removed.append(url)
        }
        return removed
    }

    /// True when the file will ride along in an iCloud device backup — the
    /// property D4 depends on.
    static func isIncludedInDeviceBackup(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values?.isExcludedFromBackup != true
    }
}
