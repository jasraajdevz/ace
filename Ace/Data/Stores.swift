//
//  Stores.swift
//  Ace
//
//  Small helpers for the singleton-ish rows — the profile and the lifetime
//  progress record. Both are "there is exactly one of these" tables, and both
//  need to exist from the very first launch, so the fetch-or-create pattern is
//  factored out here rather than repeated at every call site.
//

import Foundation
import SwiftData

enum ProfileStore {
    /// The student's profile, created on first access.
    @MainActor
    static func fetchOrCreate(in context: ModelContext) -> Profile {
        let descriptor = FetchDescriptor<Profile>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let profile = Profile()
        context.insert(profile)
        try? context.save()
        return profile
    }
}

enum ProgressStore {
    /// Lifetime progress, created on first access.
    @MainActor
    static func fetchOrCreate(in context: ModelContext) -> ProgressRecord {
        let descriptor = FetchDescriptor<ProgressRecord>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let record = ProgressRecord()
        context.insert(record)
        try? context.save()
        return record
    }
}

// MARK: - Demo content

/// Loads the bundled demo decks.
///
/// Two finished decks ship with the app — one 5th-grade science, one college
/// level — so a brand-new install has something real in it. An empty first
/// launch is the fastest way to lose someone (§5).
enum DemoContent {

    static let bundledDeckNames = ["demo_photosynthesis", "demo_neural_networks"]

    /// Decode the bundled decks. Returns an empty array rather than throwing —
    /// a missing demo file should never stop the app launching.
    static func loadDecks() -> [DemoDeck] {
        bundledDeckNames.compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(DemoDeck.self, from: data)
        }
    }

    /// Insert the demo decks as real sources, once, on first launch.
    ///
    /// They're ordinary `StudySource` rows — a student can quiz on them, delete
    /// them, or ignore them. Nothing about them is special-cased downstream.
    @MainActor
    static func installIfNeeded(in context: ModelContext) {
        let key = "ace.demoContentInstalled"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        for deck in loadDecks() {
            let source = StudySource(
                title: deck.title,
                kind: .demo,
                rawText: deck.sourceText,
                cleanedText: deck.sourceText,
                studentNote: deck.subtitle,
                subject: Subject(storageKey: deck.subject),
                confidence: 1.0
            )
            context.insert(source)

            for card in deck.flashcards {
                let stored = StoredFlashcard(card)
                stored.source = source
                context.insert(stored)
            }

            if !deck.quiz.isEmpty {
                let quiz = StoredQuiz(deck.quiz)
                quiz.source = source
                context.insert(quiz)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
