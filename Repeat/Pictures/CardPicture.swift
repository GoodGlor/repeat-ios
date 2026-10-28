import Foundation
import CryptoKit
import ImageIO
import UIKit

/// A card's picture (#149): a link in the Sheet's `image` column, downloaded
/// during sync and shown on the question side.
///
/// The link is **not** a new attribute on `Note`. A column the app does not name
/// already arrives in `Note.extras` by its header (D1), is hashed with the rest
/// of the row, and is written back untouched by every push — so the `image`
/// column round-trips today with no schema change to the store that holds the
/// only copy of scheduling state. What this type adds is the meaning: which
/// extra is the picture, where its file lives, and that it is not a line of
/// text under the answer.
enum CardPicture {

    /// The header, as `HeaderMap.normalise` leaves it.
    static let column = "image"

    /// The note's picture link, if its `image` cell holds a web address.
    static func link(in extras: [String: String]) -> String? {
        guard let raw = extras[column]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return raw
    }

    /// Where to fetch a link from. A Google Drive **share** link opens a web page
    /// about the file, not the file, so it is rewritten to the download address.
    /// Every other link is fetched as written.
    ///
    /// A link copied from **Google Images** is the address of Google's preview
    /// page, with the picture's own address inside it (`imgres?…&imgurl=…`), and
    /// a Google search result is a redirect (`url?…&url=…`). Both are how links
    /// actually arrive — the owner's first five were all one or the other — so
    /// the address inside is fetched instead. A page inside is read for the
    /// picture it names, as any page is (`pagePicture`).
    static func downloadURL(for link: String) -> URL? {
        guard let url = URL(string: link) else { return nil }
        if let inner = googleWrapped(url) { return inner }
        guard url.host?.lowercased() == "drive.google.com" else { return url }

        // …/file/d/<id>/view?usp=sharing
        let parts = url.pathComponents
        if let d = parts.firstIndex(of: "d"), d > 0, parts[d - 1] == "file", d + 1 < parts.count {
            return driveDownload(id: parts[d + 1])
        }
        // …/open?id=<id>, …/uc?id=<id>&export=…
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
            return driveDownload(id: id)
        }
        return url
    }

    /// The web address inside a Google Images or Google redirect link, if any.
    private static func googleWrapped(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com")
                || host.hasPrefix("www.google.") || host.hasPrefix("google."),
              let name = ["/imgres": "imgurl", "/url": "url"][url.path],
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == name })?.value,
              let inner = URL(string: value),
              let scheme = inner.scheme?.lowercased(), scheme == "https" || scheme == "http",
              inner.host != nil
        else { return nil }
        return inner
    }

    /// The picture a **web page** stands for, from its `og:image` (or
    /// `twitter:image`) tag.
    ///
    /// A Gemini share link (`share.gemini.google/…`) and an ImgBB link
    /// (`ibb.co/…`) both open a page about the picture, not the picture — and
    /// both name it in `og:image`, the tag every site sets so a chat app can
    /// show a preview. Reading that tag, rather than one rule per site, is what
    /// makes both work, and any other site that sets it. The pages a link fails
    /// on (a Drive sign-in, a Google Images page with nothing in it) set no such
    /// tag, so they still fail rather than turning into someone's logo.
    ///
    /// - Parameter page: where the page was fetched from; a relative address in
    ///   the tag is read against it.
    static func pagePicture(in html: Data, page: URL) -> URL? {
        // Gemini's page carries ~800 KB of inline script before its `og:image`
        // (2026-09-23), so the cap is generous; it only stops a huge download
        // being searched whole. A page that is not UTF-8 still spells its tags
        // in ASCII.
        let head = html.prefix(4 * 1024 * 1024)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
        else { return nil }
        var found: [String: String] = [:]
        for tag in text.matches(of: #/<meta\s[^>]*>/#.ignoresCase()) {
            var attributes: [String: String] = [:]
            for attribute in tag.output.matches(of: #/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/#) {
                attributes[attribute.1.lowercased()] = String(attribute.2 ?? attribute.3 ?? "")
            }
            guard let name = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"], found[name] == nil
            else { continue }
            found[name] = content
        }
        for name in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            guard let raw = found[name].map(unescapingEntities)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw, relativeTo: page)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host != nil
            else { continue }
            return url
        }
        return nil
    }

    /// The few entities an address in an attribute is written with.
    private static func unescapingEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func driveDownload(id: String) -> URL? {
        var components = URLComponents(string: "https://drive.google.com/uc")
        components?.queryItems = [URLQueryItem(name: "export", value: "download"),
                                  URLQueryItem(name: "id", value: id)]
        return components?.url
    }

    /// The file a link is kept in, named by the link itself. A changed link is a
    /// different file, so "changed" needs no bookkeeping: the new one is missing
    /// and gets downloaded, and the old one is no longer wanted and gets removed.
    /// Two notes with the same link share one file.
    static func fileName(for link: String) -> String {
        let digest = SHA256.hash(data: Data(link.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}

/// The folder the pictures are kept in.
///
/// Application Support rather than Caches: iOS may empty Caches whenever it
/// likes, and the promise to the owner is that a synced deck studies with its
/// pictures **offline**.
struct PictureStore: Sendable {
    let directory: URL

    static func standard(fileManager: FileManager = .default) throws -> PictureStore {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return PictureStore(directory: base.appending(path: "Pictures", directoryHint: .isDirectory))
    }

    func fileURL(for link: String) -> URL {
        directory.appending(path: CardPicture.fileName(for: link), directoryHint: .notDirectory)
    }

    /// The file for a note's picture, when it has one and it is on the phone.
    func existingFile(for extras: [String: String]) -> URL? {
        guard let link = CardPicture.link(in: extras) else { return nil }
        let url = fileURL(for: link)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Pictures decoded for the screen at the size they are shown (#155).
///
/// A card list can hold thousands of rows, and a stored picture is up to
/// 1600 px: decoding it whole for a 44 pt thumbnail, on the main queue, on every
/// row that scrolls past, is how a list starts to stutter. So the decode asks
/// ImageIO for the size needed, runs off the main queue, and is cached — a row
/// that scrolls back is free.
enum PictureLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at file: URL, maxPixelSize: Int) async -> UIImage? {
        let key = "\(file.lastPathComponent)@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// A note's picture at `maxPixelSize`, when it has one on the phone.
    static func image(for extras: [String: String], maxPixelSize: Int) async -> UIImage? {
        guard let file = (try? PictureStore.standard())?.existingFile(for: extras) else { return nil }
        return await image(at: file, maxPixelSize: maxPixelSize)
    }
}
