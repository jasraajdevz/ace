//
//  ShareImporter.swift
//  Ace
//
//  Turns whatever the share extension dropped in the inbox into real study
//  material (§Part 5, Anywhere Mode).
//
//  This runs in the app, where there's a SwiftData stack, Vision, the generator,
//  and no extension memory ceiling. The extension's only job was to get the
//  bytes across; all the work happens here.
//

import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum ShareImporter {

    /// What happened, so the UI can say something specific.
    struct Result: Sendable, Equatable {
        var imported: [UUID] = []
        var failed: Int = 0
        var skippedForSafety: Int = 0

        var didImportAnything: Bool { !imported.isEmpty }

        /// The line shown when the app comes to the front.
        var message: String? {
            if imported.count == 1 { return "Something you shared is ready." }
            if imported.count > 1 { return "\(imported.count) shared items are ready." }
            if failed > 0 { return "I couldn't read what you shared. Try the text instead." }
            return nil
        }
    }

    /// Drain the inbox and create sources.
    ///
    /// Called whenever the app becomes active. Cheap when the inbox is empty,
    /// which is almost always.
    @discardableResult
    static func drain(into context: ModelContext,
                      provider: AIProvider,
                      gradeLevel: GradeLevel,
                      safety: SafetyCoordinator) async -> Result {

        let items = ShareInbox.drain()
        guard !items.isEmpty else { return Result() }

        var result = Result()

        for item in items {
            defer { ShareInbox.discardPayload(for: item) }

            do {
                guard let source = try await makeSource(from: item,
                                                        provider: provider,
                                                        gradeLevel: gradeLevel,
                                                        safety: safety) else {
                    result.skippedForSafety += 1
                    continue
                }
                context.insert(source)
                result.imported.append(source.id)
            } catch {
                result.failed += 1
            }
        }

        if result.didImportAnything {
            let progress = ProgressStore.fetchOrCreate(in: context)
            if !safety.isGamificationSuppressed {
                progress.sourcesCaptured += result.imported.count
                progress.award(.capturedSource)
            }
            try? context.save()
            WidgetBridge.refresh(from: context)
        }

        return result
    }

    /// Build one source. Returns nil when the safety net caught the content.
    private static func makeSource(from item: ShareInboxItem,
                                   provider: AIProvider,
                                   gradeLevel: GradeLevel,
                                   safety: SafetyCoordinator) async throws -> StudySource? {

        var rawText = ""
        var cleaned = ""
        var confidence = 1.0
        var thumbnail: Data?

        switch item.payload {
        case .text, .url:
            let text = item.inlineText ?? ""
            guard !text.trimmed.isEmpty else { throw AIProviderError.noTextFound }
            rawText = text
            cleaned = SourceTextCleaner.clean(text: text)

        case .image:
            guard let data = ShareInbox.payload(for: item) else {
                throw AIProviderError.noTextFound
            }
            let recognised = try await provider.readText(from: data)
            guard recognised.isUsable else { throw AIProviderError.noTextFound }
            rawText = recognised.lines.joined(separator: "\n")
            cleaned = SourceTextCleaner.clean(lines: recognised.lines)
            confidence = recognised.confidence
            thumbnail = data

        case .pdf:
            guard let data = ShareInbox.payload(for: item) else {
                throw AIProviderError.noTextFound
            }
            let pages = try await PDFTextExtractor.read(data: data, provider: provider)
            guard !pages.isEmpty else { throw AIProviderError.noTextFound }
            rawText = pages.joined(separator: "\n")
            cleaned = SourceTextCleaner.clean(lines: pages)
        }

        guard !cleaned.trimmed.isEmpty else { throw AIProviderError.noTextFound }

        // Shared content is student-authored content too. A photographed diary
        // page or a pasted message must go through the net like anything else
        // (§10).
        if safety.check(cleaned) { return nil }

        let source = StudySource(
            title: item.displayTitle,
            kind: item.payload == .text || item.payload == .url ? .pastedText : .photoLibrary,
            rawText: rawText,
            cleanedText: cleaned,
            studentNote: "",
            subject: nil,
            confidence: confidence
        )
        source.thumbnailData = thumbnail
        return source
    }

}
