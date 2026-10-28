import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What one picture pass did (#149).
struct PictureSyncResult: Sendable, Equatable {
    var downloaded = 0
    var failed = 0
    var removed = 0
}

/// Brings the picture folder in line with the Sheet's links, at the end of a sync.
///
/// Downloads every linked picture that is not on the phone yet, and removes every
/// file no live note links to any more. So when a sync finishes, studying needs
/// no network. A link that fails (not shared publicly, deleted, offline, not an
/// image) is counted and skipped; the card shows without its picture and the
/// next sync tries again. A picture never fails the sync.
struct PictureSync: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    var store: PictureStore?
    var fetch: Fetch
    /// Stored at most this many pixels on the long side. A phone screen is about
    /// 1200 wide; a 4000-pixel photo from a camera is ten times the bytes for
    /// nothing the card can show.
    var maxPixelSize = 1600
    var concurrency = 4

    /// `store` is `nil` only when Application Support cannot be created, and
    /// then there is nowhere to keep a picture: the pass does nothing.
    init(store: PictureStore? = try? .standard(), fetch: @escaping Fetch = PictureSync.urlSessionFetch) {
        self.store = store
        self.fetch = fetch
    }

    /// - Parameter links: every live note's picture link. The caller must pass
    ///   the **complete** set: anything not in it is deleted.
    func run(links: Set<String>) async -> PictureSyncResult {
        guard let store else { return PictureSyncResult() }
        var result = PictureSyncResult()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: store.directory, withIntermediateDirectories: true)

        // Remove first, so a folder that outgrew its links is back to size
        // before anything new arrives.
        let wanted = Set(links.map(CardPicture.fileName(for:)))
        let present = (try? fileManager.contentsOfDirectory(atPath: store.directory.path)) ?? []
        for name in present where !wanted.contains(name) {
            if (try? fileManager.removeItem(at: store.directory.appending(path: name))) != nil {
                result.removed += 1
            }
        }

        let missing = links.filter { !fileManager.fileExists(atPath: store.fileURL(for: $0).path) }.sorted()
        await withTaskGroup(of: Bool.self) { group in
            var pending = missing[...]
            func next() {
                guard let link = pending.popFirst() else { return }
                group.addTask { await download(link, into: store) }
            }
            for _ in 0..<concurrency { next() }
            for await ok in group {
                if ok { result.downloaded += 1 } else { result.failed += 1 }
                if Task.isCancelled { group.cancelAll(); break }
                next()
            }
        }
        return result
    }

    private func download(_ link: String, into store: PictureStore) async -> Bool {
        guard let url = CardPicture.downloadURL(for: link),
              let data = try? await fetch(url)
        else { return false }
        var jpeg = Self.shrink(data, maxPixelSize: maxPixelSize)
        // A page instead of a picture: fetch the picture the page names, once.
        // One step only — a page naming another page is not followed further.
        if jpeg == nil, let picture = CardPicture.pagePicture(in: data, page: url),
           let pictureData = try? await fetch(picture) {
            jpeg = Self.shrink(pictureData, maxPixelSize: maxPixelSize)
        }
        guard let jpeg else { return false }
        // Atomic, so a pass cut short never leaves half a file that later passes
        // would take for a finished one.
        return (try? jpeg.write(to: store.fileURL(for: link), options: .atomic)) != nil
    }

    /// Decodes, scales down and re-encodes as JPEG. `nil` for anything that is
    /// not an image — which is also how a Drive link that was never shared
    /// publicly shows up: Google answers with a sign-in **web page**, status 200.
    static func shrink(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static let urlSessionFetch: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
