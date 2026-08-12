//
//  StudyTypes.swift
//  Ace
//
//  Value types for the study material Ace generates: quizzes, flashcards and
//  the spaced-repetition state that rides along with each card.
//

import Foundation

// MARK: - Source

/// Where a piece of study material came from.
enum SourceKind: String, Codable, CaseIterable, Sendable {
    case cameraPhoto
    case documentScan
    case photoLibrary
    case pastedText
    case demo

    var displayName: String {
        switch self {
        case .cameraPhoto: "Photo"
        case .documentScan: "Scan"
        case .photoLibrary: "Library"
        case .pastedText: "Text"
        case .demo: "Demo"
        }
    }

    var symbolName: String {
        switch self {
        case .cameraPhoto: "camera.fill"
        case .documentScan: "doc.viewfinder"
        case .photoLibrary: "photo.on.rectangle.angled"
        case .pastedText: "text.alignleft"
        case .demo: "sparkles"
        }
    }
}

// MARK: - Quiz

/// One multiple-choice question.
struct QuizQuestion: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var prompt: String
    /// Shuffled at generation time; `correctIndex` points into this array.
    var choices: [String]
    var correctIndex: Int
    /// Shown after answering — this is where the teaching happens, so it is
    /// never optional in generated content.
    var explanation: String
    /// Progressive hints, shortest nudge first. Socratic mode hands these out
    /// one at a time instead of revealing the answer.
    var hints: [String]

    var correctAnswer: String {
        guard choices.indices.contains(correctIndex) else { return "" }
        return choices[correctIndex]
    }

    func isCorrect(_ index: Int) -> Bool { index == correctIndex }
}

/// A generated quiz over one source.
struct Quiz: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var questions: [QuizQuestion]

    var isEmpty: Bool { questions.isEmpty }
}

/// The outcome of one attempt, used for grading and XP.
struct QuizResult: Sendable, Equatable {
    var quizID: UUID
    var correctCount: Int
    var totalCount: Int
    /// Indices of questions the student got wrong — these come back sooner.
    var missedQuestionIDs: [UUID]
    var elapsed: TimeInterval

    var score: Double {
        totalCount == 0 ? 0 : Double(correctCount) / Double(totalCount)
    }

    var percentText: String { "\(Int((score * 100).rounded()))%" }
}

// MARK: - Flashcards

/// One card. `front` is the prompt, `back` is the answer.
struct Flashcard: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var front: String
    var back: String
    /// Optional sentence the term came from — context makes recall stick.
    var context: String?
}

/// How well the student recalled a card. Deliberately three buttons, not five:
/// more options make people stop and think about the grading instead of the
/// material.
enum RecallGrade: Int, Codable, Sendable, CaseIterable {
    case forgot = 0
    case hard = 1
    case easy = 2

    var displayName: String {
        switch self {
        case .forgot: "Forgot"
        case .hard: "Hard"
        case .easy: "Easy"
        }
    }
}

/// Spaced-repetition bookkeeping for a single card.
///
/// This is a deliberately simplified SM-2: one ease factor, one interval, one
/// repetition count. It is not trying to beat Anki — it's trying to put the
/// cards you keep missing back in front of you sooner, and be readable while
/// doing it.
struct ReviewState: Codable, Sendable, Equatable {
    /// Days until the next review.
    var intervalDays: Double = 0
    /// How easy the card is for this student. Higher = seen less often.
    var easeFactor: Double = 2.5
    /// Consecutive successful recalls.
    var repetitions: Int = 0
    var dueDate: Date = .distantPast
    var lastReviewed: Date?

    static let new = ReviewState()

    var isDue: Bool { dueDate <= Date() }
    var isNew: Bool { repetitions == 0 && lastReviewed == nil }
}

enum SpacedRepetition {

    /// Minimum and maximum ease, so one bad day can't bury a card forever and
    /// one lucky streak can't make it vanish for a year.
    static let minEase: Double = 1.3
    static let maxEase: Double = 2.8
    static let maxIntervalDays: Double = 180

    /// Apply a recall grade and return the updated state.
    static func advance(_ state: ReviewState, grade: RecallGrade, now: Date = Date()) -> ReviewState {
        var next = state
        next.lastReviewed = now

        switch grade {
        case .forgot:
            // Reset the ladder but keep some of the ease — a single lapse
            // shouldn't make a card permanently "hard".
            next.repetitions = 0
            next.easeFactor = max(minEase, state.easeFactor - 0.20)
            next.intervalDays = 0        // same session
        case .hard:
            next.repetitions = state.repetitions + 1
            next.easeFactor = max(minEase, state.easeFactor - 0.14)
            next.intervalDays = state.repetitions == 0 ? 1 : max(1, state.intervalDays * 1.2)
        case .easy:
            next.repetitions = state.repetitions + 1
            next.easeFactor = min(maxEase, state.easeFactor + 0.10)
            switch state.repetitions {
            case 0: next.intervalDays = 1
            case 1: next.intervalDays = 3
            default: next.intervalDays = state.intervalDays * next.easeFactor
            }
        }

        next.intervalDays = min(next.intervalDays, maxIntervalDays)
        next.dueDate = now.addingTimeInterval(next.intervalDays * 86_400)
        return next
    }

    /// Order a deck for a study run: overdue first (most overdue leading), then
    /// brand-new cards, then everything else by due date.
    static func ordered<T>(_ items: [T],
                           state: (T) -> ReviewState,
                           now: Date = Date()) -> [T] {
        items.sorted { lhs, rhs in
            let l = state(lhs), r = state(rhs)
            let lDue = l.dueDate <= now, rDue = r.dueDate <= now

            if lDue != rDue { return lDue }            // due before not-due
            if lDue && rDue {
                if l.isNew != r.isNew { return !l.isNew }  // overdue before new
                return l.dueDate < r.dueDate               // most overdue first
            }
            return l.dueDate < r.dueDate
        }
    }
}

// MARK: - Bundled demo decks

/// Shape of the JSON in `Resources/DemoDecks/`. Bundling two finished decks is
/// what makes the very first launch look alive instead of empty.
struct DemoDeck: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var gradeLevel: GradeLevel
    var subject: String
    var sourceText: String
    var flashcards: [Flashcard]
    var quiz: Quiz
}
