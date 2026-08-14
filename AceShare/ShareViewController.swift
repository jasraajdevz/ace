//
//  ShareViewController.swift
//  AceShare
//
//  The share sheet. Send a screenshot, a PDF, a link or a block of text to Ace
//  from anywhere on the phone (§Part 5, Anywhere Mode).
//
//  It does almost nothing on purpose. A share extension is a separate process
//  with a hard memory ceiling that is killed the instant its UI dismisses, so
//  running OCR and generating a deck inside it is a good way to be terminated
//  halfway through. It writes the payload to the App Group and exits; the app
//  does the work when it next comes to the front. See `ShareInbox`.
//
//  Written in UIKit rather than SwiftUI because the extension's job is a
//  400ms confirmation, and UIKit gets on screen faster with no hosting
//  controller in the way.
//

import UIKit
import UniformTypeIdentifiers
import Social

final class ShareViewController: UIViewController {

    private let card = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    // Colours duplicated from `Ink` — pulling the whole design system into an
    // extension would drag SwiftData and the app's dependencies with it for the
    // sake of four values.
    private let background = UIColor(red: 0.078, green: 0.078, blue: 0.106, alpha: 1)
    private let surface = UIColor(red: 0.114, green: 0.114, blue: 0.169, alpha: 1)
    private let accent = UIColor(red: 0.486, green: 0.361, blue: 1.0, alpha: 1)
    private let textPrimary = UIColor(red: 0.961, green: 0.961, blue: 0.980, alpha: 1)
    private let textSecondary = UIColor(red: 0.663, green: 0.663, blue: 0.749, alpha: 1)
    private let danger = UIColor(red: 1.0, green: 0.478, blue: 0.561, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        handleSharedContent()
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = .black.withAlphaComponent(0.35)

        card.backgroundColor = background
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "Sending to Ace…"
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = textPrimary
        titleLabel.textAlignment = .center

        detailLabel.text = "It'll be waiting when you open the app."
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = textSecondary
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        spinner.color = accent
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24)
        ])
    }

    private func finish(title: String, detail: String, success: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
            self.titleLabel.text = title
            self.detailLabel.text = detail
            // Both arms of this were `textPrimary`, so a failure looked exactly
            // like a success — the one moment the colour is carrying meaning.
            self.titleLabel.textColor = success ? self.textPrimary : self.danger

            // Long enough to read, short enough not to be in the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 0.9 : 2.2)) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    // MARK: - Extracting what was shared

    private func handleSharedContent() {
        guard ShareInbox.containerURL != nil else {
            // The App Group isn't provisioned — which happens on a free Apple
            // developer account. Say so plainly rather than failing silently.
            finish(title: "Can't reach Ace's storage",
                   detail: "Sharing needs the App Group capability. See the README.",
                   success: false)
            return
        }

        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        guard !attachments.isEmpty else {
            finish(title: "Nothing to send", detail: "That didn't contain anything Ace can read.",
                   success: false)
            return
        }

        // Every attachment we understand, not just the first: sharing five
        // screenshots at once is a legitimate thing to want, and each becomes
        // its own source.
        // `NSItemProvider` completion handlers fire on arbitrary queues, and
        // several attachments are in flight at once, so this counter is written
        // concurrently. `savedCount += 1` is a read-modify-write: unsynchronised,
        // it can lose increments and report "Sent 3 items" for five.
        let group = DispatchGroup()
        let countLock = NSLock()
        var savedCount = 0

        for provider in attachments {
            group.enter()
            process(provider) { didSave in
                if didSave {
                    countLock.lock()
                    savedCount += 1
                    countLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            countLock.lock()
            let savedCount = savedCount
            countLock.unlock()
            if savedCount > 0 {
                self.finish(title: savedCount == 1 ? "Sent to Ace" : "Sent \(savedCount) items to Ace",
                            detail: "Open Ace and it'll be ready.",
                            success: true)
            } else {
                self.finish(title: "Couldn't read that",
                            detail: "Ace handles text, links, images and PDFs.",
                            success: false)
            }
        }
    }

    private func process(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        // Ordered most-specific first: a PDF also conforms to `data`, and an
        // image shared from Safari often carries a URL too.
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            loadData(provider, type: UTType.pdf, payload: .pdf, ext: "pdf", completion: completion)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            loadImage(provider, completion: completion)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            loadURL(provider, completion: completion)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            loadText(provider, completion: completion)
        } else {
            completion(false)
        }
    }

    private func loadText(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
            let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                completion(false)
                return
            }
            completion(ShareInbox.add(ShareInboxItem(payload: .text, inlineText: text)))
        }
    }

    private func loadURL(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
            guard let url = item as? URL else {
                completion(false)
                return
            }
            // A file URL is content; a web URL is a reference. Both are useful,
            // but they're stored differently.
            if url.isFileURL, let data = try? Data(contentsOf: url) {
                let filename = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "dat" : url.pathExtension)"
                let payload: ShareInboxItem.Payload =
                    url.pathExtension.lowercased() == "pdf" ? .pdf : .image
                completion(ShareInbox.add(
                    ShareInboxItem(payload: payload, filename: filename,
                                   suggestedTitle: url.deletingPathExtension().lastPathComponent),
                    payload: data))
            } else {
                completion(ShareInbox.add(
                    ShareInboxItem(payload: .url, inlineText: url.absoluteString,
                                   suggestedTitle: url.host())))
            }
        }
    }

    private func loadImage(_ provider: NSItemProvider, completion: @escaping (Bool) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
            var data: Data?
            if let image = item as? UIImage {
                data = image.jpegData(compressionQuality: 0.9)
            } else if let url = item as? URL {
                data = try? Data(contentsOf: url)
            } else if let raw = item as? Data {
                data = raw
            }
            guard let data else {
                completion(false)
                return
            }
            let filename = "\(UUID().uuidString).jpg"
            completion(ShareInbox.add(
                ShareInboxItem(payload: .image, filename: filename), payload: data))
        }
    }

    private func loadData(_ provider: NSItemProvider,
                          type: UTType,
                          payload: ShareInboxItem.Payload,
                          ext: String,
                          completion: @escaping (Bool) -> Void) {
        provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
            var data: Data?
            var title: String?
            if let url = item as? URL {
                data = try? Data(contentsOf: url)
                title = url.deletingPathExtension().lastPathComponent
            } else if let raw = item as? Data {
                data = raw
            }
            guard let data else {
                completion(false)
                return
            }
            let filename = "\(UUID().uuidString).\(ext)"
            completion(ShareInbox.add(
                ShareInboxItem(payload: payload, filename: filename, suggestedTitle: title),
                payload: data))
        }
    }
}
