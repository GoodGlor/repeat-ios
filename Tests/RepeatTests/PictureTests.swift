import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Repeat

/// #149 — a picture on a card: a link in the Sheet's `image` column, downloaded
/// during sync, shown on the question side.
final class PictureTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PictureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var store: PictureStore { PictureStore(directory: directory) }

    /// A real PNG, `width`×`height`, so decoding and scaling are exercised.
    static func png(width: Int = 40, height: Int = 30) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// A fake network: each link answers with an image, a web page, or an error.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        var answers: [String: Result<Data, Error>] = [:]
        private(set) var requested: [URL] = []
        func fetch(_ url: URL) async throws -> Data {
            lock.lock(); requested.append(url); let answer = answers[url.absoluteString]; lock.unlock()
            guard let answer else { throw URLError(.fileDoesNotExist) }
            return try answer.get()
        }
    }

    private func sync(_ server: Server, maxPixelSize: Int = 1600) -> PictureSync {
        var sync = PictureSync(store: store, fetch: { try await server.fetch($0) })
        sync.maxPixelSize = maxPixelSize
        return sync
    }

    // MARK: - The link

    func testOnlyAWebAddressInTheImageColumnIsAPicture() {
        XCTAssertEqual(CardPicture.link(in: ["image": "  https://example.com/a.jpg "]), "https://example.com/a.jpg")
        XCTAssertEqual(CardPicture.link(in: ["image": "http://example.com/a.png"]), "http://example.com/a.png")
        for bad in ["", "   ", "a cat", "ftp://example.com/a.jpg", "file:///tmp/a.jpg", "https://"] {
            XCTAssertNil(CardPicture.link(in: ["image": bad]), bad)
        }
        XCTAssertNil(CardPicture.link(in: ["вимова": "https://example.com/a.jpg"]), "only the image column")
    }

    /// A Drive share link opens a page about the file; the download address is
    /// the file itself.
    func testDriveShareLinksAreFetchedFromTheDownloadAddress() {
        let expected = "https://drive.google.com/uc?export=download&id=1AbC-d_E"
        for link in ["https://drive.google.com/file/d/1AbC-d_E/view?usp=sharing",
                     "https://drive.google.com/file/d/1AbC-d_E/view",
                     "https://drive.google.com/open?id=1AbC-d_E",
                     "https://drive.google.com/uc?id=1AbC-d_E&export=view"] {
            XCTAssertEqual(CardPicture.downloadURL(for: link)?.absoluteString, expected, link)
        }
        XCTAssertEqual(CardPicture.downloadURL(for: "https://example.com/p/cat.jpg?x=1")?.absoluteString,
                       "https://example.com/p/cat.jpg?x=1", "any other link is fetched as written")
    }

    /// The owner's first real links (2026-09-18) were copied from Google
    /// Images: the address of Google's preview **page**, with the picture's own
    /// address inside it as `imgurl`. That is the picture to fetch.
    func testAGoogleImagesLinkIsFetchedFromThePictureInsideIt() {
        let copied = "https://www.google.com/imgres?q=accept&imgurl=https%3A%2F%2Fcdn-icons-png.flaticon.com%2F512%2F4315%2F4315445.png&imgrefurl=https%3A%2F%2Fwww.flaticon.com%2Ffree-icon%2Faccept_4315445&docid=WBOs-iFnifVdeM&tbnid=4F4ebwqwTuC7YM&w=512&h=512&hcb=2"
        XCTAssertEqual(CardPicture.downloadURL(for: copied)?.absoluteString,
                       "https://cdn-icons-png.flaticon.com/512/4315/4315445.png")
        XCTAssertEqual(CardPicture.downloadURL(for: "https://www.google.com.ua/imgres?imgurl=https%3A%2F%2Fa.example%2Fb.jpg")?.absoluteString,
                       "https://a.example/b.jpg", "any Google domain")
        // Google's redirect link: follow it to where it points, which works
        // when that is a picture (a page there still fails, as any page does).
        XCTAssertEqual(CardPicture.downloadURL(for: "https://www.google.com/url?sa=t&url=https%3A%2F%2Fa.example%2Fc.png&ved=x")?.absoluteString,
                       "https://a.example/c.png")
        // No picture inside: fetched as written, and fails as a page.
        XCTAssertEqual(CardPicture.downloadURL(for: "https://www.google.com/imgres?q=accept")?.absoluteString,
                       "https://www.google.com/imgres?q=accept")
        XCTAssertEqual(CardPicture.downloadURL(for: "https://www.google.com/imgres?imgurl=javascript%3Aalert(1)")?.absoluteString,
                       "https://www.google.com/imgres?imgurl=javascript%3Aalert(1)", "only a web address inside counts")
    }

    /// A Gemini share link and an ImgBB link each open a page about the
    /// picture, naming it in `og:image`. The markup is as both served it on
    /// 2026-09-23, trimmed.
    func testAPageIsReadForThePictureItNames() {
        let gemini = """
            <meta property="og:title" content="Gemini"/>
            <meta property="og:image" itemprop="image" content="https://lh3.googleusercontent.com/gg/EXAMPLE123=s1024-rj"/>
            <meta name="twitter:image" content="https://lh3.googleusercontent.com/gg/other=s1024-rj"/>
            """
        XCTAssertEqual(CardPicture.pagePicture(in: Data(gemini.utf8), page: URL(string: "https://gemini.google.com/share/0a1b2c3d4e5f")!)?.absoluteString,
                       "https://lh3.googleusercontent.com/gg/EXAMPLE123=s1024-rj", "og:image before twitter:image")
        // The real page puts ~800 KB of inline script ahead of the tag.
        let late = "<script>" + String(repeating: "x", count: 900 * 1024) + "</script>" + gemini
        XCTAssertEqual(CardPicture.pagePicture(in: Data(late.utf8), page: URL(string: "https://gemini.google.com/share/0a1b2c3d4e5f")!)?.absoluteString,
                       "https://lh3.googleusercontent.com/gg/EXAMPLE123=s1024-rj", "a tag far down the head is still found")

        let imgbb = """
            <META CONTENT='https://i.ibb.co/XyZw5678/Gemini-Generated-Image.jpg?a=1&amp;b=2' PROPERTY='og:image' />
            <meta property="og:image:width" content="2816" />
            """
        XCTAssertEqual(CardPicture.pagePicture(in: Data(imgbb.utf8), page: URL(string: "https://ibb.co/AbCd1234")!)?.absoluteString,
                       "https://i.ibb.co/XyZw5678/Gemini-Generated-Image.jpg?a=1&b=2", "any case, any attribute order, entities read")

        XCTAssertEqual(CardPicture.pagePicture(in: Data(#"<meta property="og:image" content="/p/cat.png">"#.utf8),
                                               page: URL(string: "https://example.com/page/1")!)?.absoluteString,
                       "https://example.com/p/cat.png", "a relative address is read against the page")
        for page in ["<html>Sign in</html>",
                     #"<meta property="og:image" content="javascript:alert(1)">"#,
                     #"<meta property="og:image" content="  ">"#] {
            XCTAssertNil(CardPicture.pagePicture(in: Data(page.utf8), page: URL(string: "https://example.com/")!), page)
        }
    }

    func testAChangedLinkIsADifferentFileAndTheSameLinkIsTheSameFile() {
        XCTAssertEqual(CardPicture.fileName(for: "https://a/1.jpg"), CardPicture.fileName(for: "https://a/1.jpg"))
        XCTAssertNotEqual(CardPicture.fileName(for: "https://a/1.jpg"), CardPicture.fileName(for: "https://a/2.jpg"))
        XCTAssertTrue(CardPicture.fileName(for: "https://a/1.jpg").hasSuffix(".jpg"))
    }

    /// The link is the picture; it is never a line of text under the answer.
    func testTheImageColumnIsNotShownAsAnExtraLine() throws {
        let ctx = ModelContext(try ModelStore.container(inMemory: true))
        let deck = Deck(sheetTitle: "Verbs", sheetId: 0); ctx.insert(deck)
        let note = Note(deck: deck, front: "linger", back: "затримуватися",
                        extras: ["вимова": "/ˈlɪŋɡə/", "image": "https://example.com/cup.jpg"],
                        extraOrder: ["вимова", "image"])
        XCTAssertEqual(note.displayExtras.map(\.key), ["вимова"])
    }

    // MARK: - The pass

    func testMissingPicturesAreDownloadedScaledDownAndKept() async throws {
        let server = Server()
        server.answers["https://example.com/big.png"] = .success(Self.png(width: 400, height: 200))
        let result = await sync(server, maxPixelSize: 100).run(links: ["https://example.com/big.png"])

        XCTAssertEqual(result, PictureSyncResult(downloaded: 1, failed: 0, removed: 0))
        let file = store.fileURL(for: "https://example.com/big.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let size = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(size[kCGImagePropertyPixelWidth] as? Int, 100, "scaled to the long side")
        XCTAssertEqual(size[kCGImagePropertyPixelHeight] as? Int, 50)
        XCTAssertEqual(store.existingFile(for: ["image": "https://example.com/big.png"]), file)
    }

    func testAPictureAlreadyOnThePhoneIsNotFetchedAgain() async throws {
        let server = Server()
        server.answers["https://example.com/a.png"] = .success(Self.png())
        _ = await sync(server).run(links: ["https://example.com/a.png"])
        let again = await sync(server).run(links: ["https://example.com/a.png"])

        XCTAssertEqual(again, PictureSyncResult())
        XCTAssertEqual(server.requested.count, 1)
    }

    /// A changed link downloads the new file; the old one, and one whose cell
    /// was cleared, are deleted.
    func testFilesNoLinkWantsAreRemoved() async throws {
        let server = Server()
        for name in ["a", "b", "c"] { server.answers["https://example.com/\(name).png"] = .success(Self.png()) }
        _ = await sync(server).run(links: ["https://example.com/a.png", "https://example.com/b.png"])

        let result = await sync(server).run(links: ["https://example.com/c.png"])
        XCTAssertEqual(result, PictureSyncResult(downloaded: 1, failed: 0, removed: 2))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, [CardPicture.fileName(for: "https://example.com/c.png")])
    }

    /// A Drive file that was never shared answers with a sign-in page, status
    /// 200. That, a dead link and a network error are each one failure, and
    /// none of them stops the others.
    func testAFailedLinkIsSkippedAndTriedAgainNextTime() async throws {
        let server = Server()
        server.answers["https://example.com/ok.png"] = .success(Self.png())
        server.answers["https://example.com/page"] = .success(Data("<html>Sign in</html>".utf8))
        server.answers["https://example.com/offline"] = .failure(URLError(.notConnectedToInternet))
        let links: Set<String> = ["https://example.com/ok.png", "https://example.com/page",
                                  "https://example.com/offline", "https://example.com/gone"]

        let first = await sync(server).run(links: links)
        XCTAssertEqual(first, PictureSyncResult(downloaded: 1, failed: 3, removed: 0))
        XCTAssertNil(store.existingFile(for: ["image": "https://example.com/page"]), "a web page is not a picture")

        server.answers["https://example.com/offline"] = .success(Self.png())
        let second = await sync(server).run(links: links)
        XCTAssertEqual(second, PictureSyncResult(downloaded: 1, failed: 2, removed: 0), "the next pass retries")
    }

    /// A link to a page is kept under the **link**, holding the picture the
    /// page names — so the Sheet's cell stays what the owner pasted. A page
    /// naming a page is not followed further.
    func testALinkToAPageDownloadsThePictureItNames() async throws {
        let server = Server()
        server.answers["https://ibb.co/AbCd1234"] = .success(Data(#"<meta property="og:image" content="https://i.ibb.co/x/a.png">"#.utf8))
        server.answers["https://i.ibb.co/x/a.png"] = .success(Self.png())
        server.answers["https://example.com/one"] = .success(Data(#"<meta property="og:image" content="https://example.com/two">"#.utf8))
        server.answers["https://example.com/two"] = .success(Data(#"<meta property="og:image" content="https://example.com/b.png">"#.utf8))
        server.answers["https://example.com/b.png"] = .success(Self.png())

        let result = await sync(server).run(links: ["https://ibb.co/AbCd1234", "https://example.com/one"])

        XCTAssertEqual(result, PictureSyncResult(downloaded: 1, failed: 1, removed: 0))
        XCTAssertNotNil(store.existingFile(for: ["image": "https://ibb.co/AbCd1234"]))
        XCTAssertFalse(server.requested.map(\.absoluteString).contains("https://example.com/b.png"), "one step only")
    }

    // MARK: - #155: shown small in a list

    /// Decoded at the size asked for, not the stored size, and cached: the
    /// second ask for the same file and size is the same image.
    func testAPictureIsDecodedAtTheSizeShownAndCached() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "big.png")
        try Self.png(width: 400, height: 200).write(to: file)

        let decoded = await PictureLoader.image(at: file, maxPixelSize: 100)
        let small = try XCTUnwrap(decoded)
        XCTAssertEqual(small.cgImage?.width, 100)
        XCTAssertEqual(small.cgImage?.height, 50)
        let again = await PictureLoader.image(at: file, maxPixelSize: 100)
        XCTAssertTrue(again === small, "the second ask is the cached image")
        let missing = await PictureLoader.image(at: directory.appending(path: "none.png"), maxPixelSize: 100)
        XCTAssertNil(missing)
    }

    // MARK: - Through a real sync run

    /// Pull a row with a link and the picture is on the phone when the run
    /// ends; change the link and the next pull swaps the file; edit the card on
    /// the phone and the push writes the link back untouched.
    func testASyncBringsThePicturesAndAPushKeepsTheLink() async throws {
        let id = UUID()
        let header = SheetSyncHarness.header + ["image"]
        let row = { (link: String) in SheetSyncHarness.row(id, front: "linger", back: "затримуватися") + [link] }
        let stub = SheetStub(rows: ["Verbs": [header, row("https://example.com/cup.png")]])
        let server = Server()
        server.answers["https://example.com/cup.png"] = .success(Self.png())
        server.answers["https://example.com/mug.png"] = .success(Self.png())
        let container = try ModelStore.container(inMemory: true)
        let client = try SheetSyncHarness.makeClient(stub)
        let actor = SyncActor(container: container, makeClient: { client },
                              pictures: sync(server))

        let first = await actor.sync(.pullToRefresh)
        XCTAssertTrue(first.didRun, "\(first.verdict)")
        XCTAssertEqual(first.pictures.downloaded, 1)
        XCTAssertNotNil(store.existingFile(for: ["image": "https://example.com/cup.png"]))

        stub.rows["Verbs"] = [header, row("https://example.com/mug.png")]
        let second = await actor.sync(.pullToRefresh)
        XCTAssertEqual(second.pictures, PictureSyncResult(downloaded: 1, failed: 0, removed: 1))

        // An edit on the phone, pushed.
        let context = ModelContext(container)
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<Note>()).first)
        note.back = "баритися"
        note.refreshContentHash()
        note.pendingUpload = true
        try context.save()
        let pushed = await actor.sync(.contentEdited)
        XCTAssertTrue(pushed.didRun, "\(pushed.verdict)")
        let written = try String(decoding: JSONSerialization.data(withJSONObject: stub.updates), as: UTF8.self)
        XCTAssertTrue(written.contains("баритися"), "the edit was not pushed: \(written)")
        XCTAssertTrue(written.contains("https:\\/\\/example.com\\/mug.png") || written.contains("https://example.com/mug.png"),
                      "the push dropped the image cell: \(written)")
    }
}
