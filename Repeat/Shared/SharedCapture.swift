import Foundation
import UniformTypeIdentifiers

/// What the Share Extension was handed (§7.3).
public struct SharedCapture: Equatable, Sendable {
    public var text = ""
    public var sourceURL: String?

    public init(text: String = "", sourceURL: String? = nil) {
        self.text = text
        self.sourceURL = sourceURL
    }

    /// Reads text **and** URL, not one or the other.
    ///
    /// A Safari selection arrives as two attachments: the selected words and the
    /// page they came from. Taking only the first — which is what the scaffold
    /// did — either loses the words or loses the source, and §7.3 asks for both.
    ///
    /// Lives in shared code rather than the extension so it can be tested: it is
    /// the one piece of the extension with a decision in it.
    public static func read(from providers: [NSItemProvider]) async -> SharedCapture {
        var capture = SharedCapture()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
               let url = loaded as? URL ?? (loaded as? String).flatMap(URL.init(string:)) {
                // A file URL is a shared document, not anybody's source.
                if !url.isFileURL { capture.sourceURL = url.absoluteString }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let loaded = try? await provider.loadItem(
                   forTypeIdentifier: UTType.plainText.identifier),
               let text = loaded as? String, !text.isEmpty {
                capture.text = text
            }
        }

        // Sharing a bare link: the URL is the only thing there is to remember.
        if capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let source = capture.sourceURL {
            capture.text = source
        }
        return capture
    }
}
