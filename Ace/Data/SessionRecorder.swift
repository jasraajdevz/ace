//
//  SessionRecorder.swift
//  Ace
//
//  One object that owns everything a study session changes: the session row,
//  lifetime progress, XP, the streak, and the home-screen widget.
//
//  Every screen in the study loop talks to this instead of touching
//  `ProgressRecord` directly. That's what guarantees three things happen
//  *everywhere*, without each screen having to remember:
//
//    1. XP is never awarded while the crisis net is engaged (§10).
//    2. A level-up is always detected and celebrated exactly once.
//    3. The widget is republished after anything that changes it.
//

import Foundation
import SwiftData

@MainActor
final class SessionRecorder {

    private let context: ModelContext
    private let progress: ProgressRecord
    private let session: StudySession
    private unowned let celebrations: CelebrationCenter
    private unowned let safety: SafetyCoordinator

    /// Total XP earned in this session, for the results screen.
    private(set) var sessionXP = 0

    init(context: ModelContext,
         source: StudySource?,
         celebrations: CelebrationCenter,
         safety: SafetyCoordinator) {
        self.context = context
        self.celebrations = celebrations
        self.safety = safety
        self.progress = ProgressStore.fetchOrCreate(in: context)

        let session = StudySession(sourceID: source?.id, sourceTitle: source?.title ?? "")
        context.insert(session)
        self.session = session

        // Studying today counts, whatever else happens in the session.
        if !safety.isGamificationSuppressed {
            progress.recordStudyDay()
        }
        try? context.save()
    }

    // MARK: - Awarding

    /// Award XP, show the toast, and celebrate a level-up if one happened.
    ///
    /// Returns silently when the safety net is engaged — the caller doesn't need
    /// to check, and forgetting to check is exactly the kind of mistake that
    /// would put a level-up on screen at the worst possible moment.
    func award(_ event: XPEvent) {
        guard !safety.isGamificationSuppressed else { return }

        let leveledUp = progress.award(event)
        sessionXP += event.amount
        session.xpEarned += event.amount

        celebrations.award(event)
        if leveledUp {
            celebrations.celebrateLevelUp(
                level: progress.level,
                title: progress.levelTitle,
                progress: progress.levelProgress
            )
        }
        persist()
    }

    // MARK: - Recording what happened

    func recordAnswer(correct: Bool) {
        session.questionsAnswered += 1
        progress.questionsAnswered += 1
        if correct {
            session.correctCount += 1
            progress.questionsCorrect += 1
        }
        persist()
    }

    func recordHint() {
        session.hintsTaken += 1
        persist()
    }

    func recordFlashcard() {
        session.flashcardsReviewed += 1
        persist()
    }

    /// The crisis net engaged during this session. Mark it so the results screen
    /// shows no score, no XP and no celebration.
    func markSafetyEngaged() {
        session.safetyEngaged = true
        celebrations.silence()
        persist()
    }

    // MARK: - Finishing

    /// Close the session and publish the widget.
    func finish(mood: Mood = .neutral) {
        guard session.isActive else { return }
        session.endedAt = Date()
        session.endingMood = mood

        if !safety.isGamificationSuppressed {
            progress.sessionsCompleted += 1
            progress.totalStudyMinutes += session.minutes
            // Time spent is real effort and pays — capped inside `XPEvent` so
            // leaving the app open all night earns nothing extra.
            if session.minutes >= 1 {
                award(.finishedSession(minutes: session.minutes))
            }
        }
        persist()
    }

    /// Current progress values, for the results screen.
    var snapshot: (level: Int, levelProgress: Double, totalXP: Int, streak: Int) {
        (progress.level, progress.levelProgress, progress.totalXP, progress.streak.current)
    }

    var sessionSummary: (minutes: Int, answered: Int, correct: Int, cards: Int) {
        (session.minutes, session.questionsAnswered, session.correctCount, session.flashcardsReviewed)
    }

    // MARK: - Persistence

    private func persist() {
        try? context.save()
        publishWidget()
    }

    private func publishWidget() {
        let sources = (try? context.fetch(
            FetchDescriptor<StudySource>(sortBy: [SortDescriptor(\StudySource.createdAt, order: .reverse)])
        )) ?? []

        WidgetBridge.publish(
            level: progress.level,
            levelTitle: progress.levelTitle,
            levelProgress: progress.levelProgress,
            totalXP: progress.totalXP,
            streak: progress.streak,
            lastSourceTitle: session.sourceTitle.isEmpty
                ? (sources.first?.title ?? "") : session.sourceTitle,
            sourceCount: sources.count
        )
    }
}

// MARK: - Publishing outside a session

extension WidgetBridge {
    /// Refresh the widget from whatever is currently stored. Used on launch and
    /// after capture, where there's no session open.
    @MainActor
    static func refresh(from context: ModelContext) {
        let progress = ProgressStore.fetchOrCreate(in: context)
        let sources = (try? context.fetch(
            FetchDescriptor<StudySource>(sortBy: [SortDescriptor(\StudySource.createdAt, order: .reverse)])
        )) ?? []

        publish(
            level: progress.level,
            levelTitle: progress.levelTitle,
            levelProgress: progress.levelProgress,
            totalXP: progress.totalXP,
            streak: progress.streak,
            lastSourceTitle: sources.first?.title ?? "",
            sourceCount: sources.count
        )
    }
}

// MARK: - Getting study material

/// Fetches a source's quiz and flashcards, generating and persisting them the
/// first time.
///
/// Generation is idempotent and cached: a student who opens the same quiz twice
/// gets the same questions in the same order (the generator is seeded), which is
/// what makes "redo it" meaningful rather than a reshuffle.
enum StudyMaterialStore {

    @MainActor
    static func quiz(for source: StudySource,
                     gradeLevel: GradeLevel,
                     provider: AIProvider,
                     context: ModelContext) async throws -> StoredQuiz {
        if let existing = source.quizzes.first {
            return existing
        }
        let generated = try await provider.makeQuiz(
            from: .text(source.cleanedText),
            gradeLevel: gradeLevel,
            title: source.title,
            questionCount: 8
        )
        let stored = StoredQuiz(generated)
        stored.source = source
        context.insert(stored)
        try? context.save()
        return stored
    }

    @MainActor
    static func flashcards(for source: StudySource,
                           gradeLevel: GradeLevel,
                           provider: AIProvider,
                           context: ModelContext) async throws -> [StoredFlashcard] {
        if !source.flashcards.isEmpty {
            return source.flashcards
        }
        let generated = try await provider.makeFlashcards(
            from: .text(source.cleanedText),
            gradeLevel: gradeLevel,
            title: source.title,
            limit: 16
        )
        let stored = generated.map { card -> StoredFlashcard in
            let model = StoredFlashcard(card)
            model.source = source
            context.insert(model)
            return model
        }
        try? context.save()
        return stored
    }
}
