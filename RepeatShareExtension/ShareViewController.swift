import UIKit
import SwiftUI

/// §7.3: capture from anywhere on the phone.
///
/// Writes a file into the App Group container and finishes. It deliberately does
/// **not** open SwiftData: two processes on one SQLite store is not a risk worth
/// taking for a quick capture, and an extension is killed in seconds. The app
/// ingests on its next launch or foreground (#23), which is also why this works
/// with the main app not running — nothing here needs it.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var capture = SharedCapture()

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
                .flatMap { $0.attachments ?? [] }
            capture = await SharedCapture.read(from: providers)
            present()
        }
    }

    private func present() {
        let view = ShareSheet(
            capture: capture,
            decks: SharedDecks.read()?.decks ?? [],
            onSave: { [weak self] drop in
                self?.write(drop)
                self?.finish()
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func write(_ drop: InboxDrop) {
        guard AppGroup.prepare(), let inbox = AppGroup.inboxURL else { return }
        try? drop.write(to: inbox)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.goodglor.repeat.share", code: NSUserCancelledError))
    }
}
