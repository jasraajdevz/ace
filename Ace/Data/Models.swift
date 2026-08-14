//
//  Models.swift
//  Ace
//
//  SwiftData persistence.
//
//  A deliberate pattern runs through this file: the `@Model` classes store
//  *primitives* (strings, ints, dates, and JSON blobs) and expose the rich
//  types from `Core/` through computed properties.
//
//  Why: SwiftData persists enums and structs only if they're Codable, and it
//  handles schema migration far more gracefully for primitives. Keeping the
//  storage layer dumb means `Core/` stays free to evolve — and it's why `Core/`
//  can be unit-tested without a database at all.
//

import Foundation
import SwiftData

// MARK: - Profile

/// The student. Exactly one of these exists.
@Model
final class Profile {
    /// Optional — Ace works fine without knowing a name.
    var name: String = ""
    var gradeLevelRaw: String = GradeLevel.grade9.rawValue
    /// `Subject.storageKey` values.
    var subjectKeys: [String] = []
    var voicePersonaID: String = VoiceRoster.default.id
    var supportRegionRaw: String = SupportRegion.unitedStates.rawValue
    var createdAt: Date = Date()
    var hasCompletedOnboarding: Bool = false

    init() {}

    // MARK: Typed accessors

    var gradeLevel: GradeLevel {
        get { GradeLevel(rawValue: gradeLevelRaw) ?? .grade9 }
        set { gradeLevelRaw = newValue.rawValue }
    }

    var subjects: [Subject] {
        get { subjectKeys.compactMap(Subject.init(storageKey:)) }
        set { subjectKeys = newValue.map(\.storageKey) }
    }

    var voicePersona: VoicePersona {
        get { VoiceRoster.persona(id: voicePersonaID) }
        set { voicePersonaID = newValue.id }
    }

    var supportRegion: SupportRegion {
        get { SupportRegion(rawValue: supportRegionRaw) ?? .unitedStates }
        set { supportRegionRaw = newValue.rawValue }
    }

    /// First name only, for greetings. Empty when we don't have one.
    var firstName: String {
        String(name.split(separator: " ").first ?? "")
    }

    var greetingName: String {
        firstName.isEmpty ? "there" : firstName
    }

    /// The plain snapshot everything outside the persistence layer works with.
    var settings: StudentSettings {
        StudentSettings(name: name,
                        gradeLevel: gradeLevel,
                        subjects: subjects,
                        voicePersonaID: voicePersonaID,
                        supportRegion: supportRegion)
    }
}

// MARK: - Source

/// A piece of study material the student captured.
@Model
final class StudySource {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var kindRaw: String = SourceKind.pastedText.rawValue
    /// What the recogniser produced, before cleaning. Kept so we can re-clean
    /// with an improved pipeline later without asking for the photo again.
    var rawText: String = ""
    /// What the tutor actually works from.
    var cleanedText: String = ""
    /// "studying photosynthesis, test Friday"
    var studentNote: String = ""
    var subjectKey: String?
    var createdAt: Date = Date()
    var lastOpenedAt: Date?
    /// Average OCR confidence, 0...1. Used to warn about a bad scan.
    var recognitionConfidence: Double = 1.0
    /// Thumbnail of the captured page, for the source list. Stored externally so
    /// the main store stays small and queries stay fast.
    @Attribute(.externalStorage) var thumbnailData: Data?

    /// Deleting a source takes its generated material with it — an orphaned
    /// deck with no source is confusing and un-actionable.
    @Relationship(deleteRule: .cascade, inverse: \StoredFlashcard.source)
    var flashcards: [StoredFlashcard] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredQuiz.source)
    var quizzes: [StoredQuiz] = []

    init(title: String, kind: SourceKind, rawText: String, cleanedText: String,
         studentNote: String = "", subject: Subject? = nil, confidence: Double = 1.0) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.studentNote = studentNote
        self.subjectKey = subject?.storageKey
        self.createdAt = Date()
        self.recognitionConfidence = confidence
    }

    var kind: SourceKind {
        get { SourceKind(rawValue: kindRaw) ?? .pastedText }
        set { kindRaw = newValue.rawValue }
    }

    var subject: Subject? {
        get { subjectKey.flatMap(Subject.init(storageKey:)) }
        set { subjectKey = newValue?.storageKey }
    }

    /// A one-line preview for the source list.
    var preview: String {
        let flat = cleanedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 120 ? flat : String(flat.prefix(120)) + "…"
    }

    var wordCount: Int {
        cleanedText.split(separator: " ").count
    }

    /// Below this the scan is too poor to build a quiz from and we say so.
    var isLowConfidence: Bool { recognitionConfidence < 0.55 }
}

// MARK: - Flashcards

@Model
final class StoredFlashcard {
    @Attribute(.unique) var id: UUID = UUID()
    var front: String = ""
    var back: String = ""
    var context: String?
    var createdAt: Date = Date()

    // Spaced-repetition state, flattened. Mirrors `ReviewState` in Core.
    var intervalDays: Double = 0
    var easeFactor: Double = 2.5
    var repetitions: Int = 0
    var dueDate: Date = Date.distantPast
    var lastReviewed: Date?
    /// Lifetime counters, for the "cards you keep missing" view.
    var timesSeen: Int = 0
    var timesForgotten: Int = 0

    var source: StudySource?

    init(front: String, back: String, context: String? = nil) {
        self.id = UUID()
        self.front = front
        self.back = back
        self.context = context
        self.createdAt = Date()
    }

    convenience init(_ card: Flashcard) {
        self.init(front: card.front, back: card.back, context: card.context)
        self.id = card.id
    }

    var reviewState: ReviewState {
        get {
            var state = ReviewState()
            state.intervalDays = intervalDays
            state.easeFactor = easeFactor
            state.repetitions = repetitions
            state.dueDate = dueDate
            state.lastReviewed = lastReviewed
            return state
        }
        set {
            intervalDays = newValue.intervalDays
            easeFactor = newValue.easeFactor
            repetitions = newValue.repetitions
            dueDate = newValue.dueDate
            lastReviewed = newValue.lastReviewed
        }
    }

    var asValue: Flashcard {
        Flashcard(id: id, front: front, back: back, context: context)
    }

    /// Apply a recall grade and update the counters.
    func record(_ grade: RecallGrade, now: Date = Date()) {
        reviewState = SpacedRepetition.advance(reviewState, grade: grade, now: now)
        timesSeen += 1
        if grade == .forgot { timesForgotten += 1 }
    }
}

// MARK: - Quizzes

@Model
final class StoredQuiz {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    /// Questions are stored as encoded JSON rather than as a child model.
    ///
    /// A quiz is always read and written whole — there is no query that wants
    /// "all questions across all quizzes" — so a relationship would buy nothing
    /// and cost a third level of SwiftData graph management.
    var questionsData: Data = Data()

    // Best attempt so far, for the source list.
    var attemptCount: Int = 0
    var bestScore: Double = 0
    var lastAttemptedAt: Date?

    var source: StudySource?

    init(_ quiz: Quiz) {
        self.id = quiz.id
        self.title = quiz.title
        self.createdAt = Date()
        self.questions = quiz.questions
    }

    var questions: [QuizQuestion] {
        get {
            (try? JSONDecoder().decode([QuizQuestion].self, from: questionsData)) ?? []
        }
        set {
            questionsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var asValue: Quiz {
        Quiz(id: id, title: title, questions: questions)
    }

    func recordAttempt(score: Double, at date: Date = Date()) {
        attemptCount += 1
        bestScore = max(bestScore, score)
        lastAttemptedAt = date
    }
}

// MARK: - Sessions

/// One sitting. Written at the start and closed at the end, so an app that gets
/// killed mid-session still leaves a record we can reason about.
@Model
final class StudySession {
    @Attribute(.unique) var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var sourceID: UUID?
    var sourceTitle: String = ""
    /// The goal set with Ace ("let's go till chapter 4"). Part 4 fills this in.
    var goalText: String = ""
    var goalMet: Bool = false

    var xpEarned: Int = 0
    var questionsAnswered: Int = 0
    var correctCount: Int = 0
    var flashcardsReviewed: Int = 0
    var hintsTaken: Int = 0
    /// How many times the student left the app during this session. Feeds the
    /// Guardian's return nudge in Part 4.
    var appExits: Int = 0
    /// Last mood we read, for the session summary.
    var endingMoodRaw: String = Mood.neutral.rawValue
    /// True if the crisis net engaged at any point during the session.
    ///
    /// Recorded on the row so a future history view can honour it without
    /// needing the `SafetyCoordinator` that was live at the time. Suppression
    /// *during* the session is that coordinator's job, not this flag's.
    var safetyEngaged: Bool = false

    init(sourceID: UUID? = nil, sourceTitle: String = "") {
        self.id = UUID()
        self.startedAt = Date()
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
    }

    var endingMood: Mood {
        get { Mood(rawValue: endingMoodRaw) ?? .neutral }
        set { endingMoodRaw = newValue.rawValue }
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var minutes: Int { max(0, Int(duration / 60)) }

    var isActive: Bool { endedAt == nil }

    var accuracy: Double {
        questionsAnswered == 0 ? 0 : Double(correctCount) / Double(questionsAnswered)
    }
}

// MARK: - Progress

/// Lifetime totals. A single row.
@Model
final class ProgressRecord {
    var totalXP: Int = 0
    var sessionsCompleted: Int = 0
    var totalStudyMinutes: Int = 0
    var sourcesCaptured: Int = 0
    var questionsAnswered: Int = 0
    var questionsCorrect: Int = 0

    // Streak state, flattened from `StreakState`.
    var streakCurrent: Int = 0
    var streakLongest: Int = 0
    var lastStudyDay: Date?
    var streakRepairsAvailable: Int = 1
    var lastRepairEarnedDay: Date?

    init() {}

    var level: Int { LevelCurve.level(forXP: totalXP) }
    var levelProgress: Double { LevelCurve.progress(forXP: totalXP) }
    var xpToNextLevel: Int { LevelCurve.xpRemaining(forXP: totalXP) }
    var levelTitle: String { LevelCurve.title(forLevel: level) }

    var streak: StreakState {
        get {
            var state = StreakState()
            state.current = streakCurrent
            state.longest = streakLongest
            state.lastStudyDay = lastStudyDay
            state.repairsAvailable = streakRepairsAvailable
            state.lastRepairEarnedDay = lastRepairEarnedDay
            return state
        }
        set {
            streakCurrent = newValue.current
            streakLongest = newValue.longest
            lastStudyDay = newValue.lastStudyDay
            streakRepairsAvailable = newValue.repairsAvailable
            lastRepairEarnedDay = newValue.lastRepairEarnedDay
        }
    }

    var accuracy: Double {
        questionsAnswered == 0 ? 0 : Double(questionsCorrect) / Double(questionsAnswered)
    }

    /// Award XP and return whether the student levelled up, so the caller can
    /// fire the celebration.
    @discardableResult
    func award(_ event: XPEvent) -> Bool {
        let before = level
        totalXP += event.amount
        return level > before
    }

    /// Record that studying happened today.
    func recordStudyDay(now: Date = Date()) {
        streak = StreakEngine.record(streak, now: now)
    }
}

// MARK: - Schema

enum AceSchema {
    /// Everything the container knows about. Adding a model here is the only
    /// step needed to persist it.
    static let models: [any PersistentModel.Type] = [
        Profile.self,
        StudySource.self,
        StoredFlashcard.self,
        StoredQuiz.self,
        StudySession.self,
        ProgressRecord.self
    ]
}
