//
//  ShareInbox.swift
//  Ace — SHARED between the app and the share extension
//
//  Anywhere Mode: send anything to Ace from any app (§Part 5).
//
//  The design mirrors `WidgetSnapshot` and for the same reason. A share
//  extension is a separate process with a hard memory ceiling and a very short
//  life — it is killed the moment its UI dismisses. Standing up a
//  `ModelContainer`, running OCR and generating a deck inside it is a good way
//  to get terminated halfway through.
//
//  So the extension does the least possible: it writes the payload into the App
//  Group container and exits. The app drains the inbox the next time it's
//  frontmost, and does the real work there — where it has the SwiftData stack,
//  the generator, and no memory ceiling.
//
//  That also means sharing works while the app is closed, and nothing is lost
//  if the extension is killed mid-write: an item without its payload file is
//  simply skipped.
//

import Foundation

/// One thing waiting to be turned into study material.
struct ShareInboxItem: Codable, Sendable, Equatable, Identifiable {

    enum Payload: String, Codable, Sendable {
        case text
        case image
        case pdf
        case url
    }

    var id: UUID
    var payload: Payload
    /// Filename inside the inbox directory. Nil for `.text` and `.url`, which
    /// carry their content inline.
    var filename: String?
    /// Inline content for text and URLs.
    var inlineText: String?
    /// What the sending app called it, when it said.
    var suggestedTitle: String?
    var receivedAt: Date

    init(payload: Payload,
         filename: String? = nil,
         inlineText: String? = nil,
         suggestedTitle: String? = nil,
         receivedAt: Date = Date()) {
        self.id = UUID()
        self.payload = payload
        self.filename = filename
        self.inlineText = inlineText
        self.suggestedTitle = suggestedTitle
        self.receivedAt = receivedAt
    }

    /// A title for the source Ace creates from this.
    var displayTitle: String {
        if let suggested = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return String(suggested.prefix(60))
        }
        if let text = inlineText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            // First line, or first few words.
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            return String(firstLine.prefix(60))
        }
        switch payload {
        case .image: return "Shared image"
        case .pdf: return "Shared PDF"
        case .url: return "Shared link"
        case .text: return "Shared text"
        }
    }
}

// MARK: - The inbox

/// Read and write the shared inbox.
///
/// Deliberately file-based rather than a database: two processes, one of which
/// may be killed at any moment, is exactly the situation where a directory of
/// small files beats anything with a write-ahead log.
enum ShareInbox {

    static let appGroupID = WidgetStore.appGroupID
    private static let manifestName = "share-inbox.json"
    private static let payloadDirectory = "ShareInbox"

    /// The shared container, when the App Group is provisioned.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Where payload files live.
    static var payloadsURL: URL? {
        containerURL?.appendingPathComponent(payloadDirectory, isDirectory: true)
    }

    private static var manifestURL: URL? {
        containerURL?.appendingPathComponent(manifestName)
    }

    // MARK: Writing (the extension)

    /// Add an item. Returns false when the App Group isn't available, which the
    /// extension surfaces rather than failing silently.
    @discardableResult
    static func add(_ item: ShareInboxItem, payload: Data? = nil) -> Bool {
        guard let manifestURL, let payloadsURL else { return false }

        do {
            try FileManager.default.createDirectory(at: payloadsURL,
                                                    withIntermediateDirectories: true)
            // Write the payload BEFORE the manifest entry. If the extension is
            // killed between the two, the app sees no entry — rather than an
            // entry pointing at a file that isn't there.
            if let payload, let filename = item.filename {
                try payload.write(to: payloadsURL.appendingPathComponent(filename))
            }

            var items = load()
            items.append(item)
            // A cap, so a runaway share loop can't fill the container.
            if items.count > 40 { items.removeFirst(items.count - 40) }
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: Reading (the app)

    static func load() -> [ShareInboxItem] {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let items = try? JSONDecoder().decode([ShareInboxItem].self, from: data) else {
            return []
        }
        return items
    }

    static var hasPendingItems: Bool { !load().isEmpty }

    /// The bytes for an item, if it had any.
    static func payload(for item: ShareInboxItem) -> Data? {
        guard let filename = item.filename, let payloadsURL else { return nil }
        return try? Data(contentsOf: payloadsURL.appendingPathComponent(filename))
    }

    /// Take everything and clear the inbox atomically-enough.
    ///
    /// The manifest is cleared first: if the app crashes mid-drain, the student
    /// loses one shared item rather than getting it imported twice on every
    /// launch forever.
    static func drain() -> [ShareInboxItem] {
        let items = load()
        guard !items.isEmpty else { return [] }
        clearManifest()
        return items
    }

    /// Delete an item's payload file once it's been imported.
    static func discardPayload(for item: ShareInboxItem) {
        guard let filename = item.filename, let payloadsURL else { return }
        try? FileManager.default.removeItem(at: payloadsURL.appendingPathComponent(filename))
    }

    static func clearManifest() {
        guard let manifestURL else { return }
        try? Data("[]".utf8).write(to: manifestURL)
    }

    /// Remove everything, payloads included. Used by "Reset everything".
    static func clearAll() {
        clearManifest()
        guard let payloadsURL else { return }
        try? FileManager.default.removeItem(at: payloadsURL)
    }
}

// MARK: - Quick capture

/// What the widget's capture button asks the app to do.
///
/// Written to the App Group by an App Intent and read on launch, rather than
/// passed through the deep link, so the request survives a cold start.
enum QuickCaptureRequest {
    private static let key = "ace.quickCapture.requestedAt"

    static func request(at date: Date = Date()) {
        WidgetStore.defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    /// Consume a pending request. Requests older than a minute are ignored —
    /// the student clearly went elsewhere.
    static func consume(now: Date = Date()) -> Bool {
        let stamp = WidgetStore.defaults.double(forKey: key)
        guard stamp > 0 else { return false }
        WidgetStore.defaults.removeObject(forKey: key)
        return now.timeIntervalSince1970 - stamp < 60
    }
}
