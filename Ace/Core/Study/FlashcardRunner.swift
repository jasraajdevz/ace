//
//  FlashcardRunner.swift
//  Ace
//
//  The state machine behind a flashcard session.
//
//  Two behaviours here are worth more than the rest of the file:
//
//  • **Ordering is spaced repetition, not deck order.** Cards you're about to
//    forget come first (see `SpacedRepetition.ordered`). A deck reviewed in the
//    order it was created is just a list.
//
//  • **Forgotten cards come back in the same sitting.** A card you blanked on
//    is re-queued behind the remaining cards rather than deferred to tomorrow,
//    because the whole point of the session is to fix it now. It can only come
//    back once, so a card you keep missing can't trap you in a loop.
//

import Foundation

/// A card plus the review state it arrived with.
struct ScheduledCard: Sendable, Equatable, Identifiable {
    var card: Flashcard
    var state: ReviewState

    var id: UUID { card.id }
}

/// The outcome of grading one card.
struct RecallOutcome: Sendable, Equatable {
    var cardID: UUID
    var grade: RecallGrade
    /// The updated review state to persist.
    var newState: ReviewState
    var xp: XPEvent
    /// True when the card was pushed back into this session's queue.
    var wasRequeued: Bool
    /// A short line from Ace. Warm on a miss — forgetting is the mechanism, not
    /// a failure.
    var comment: String
}

struct FlashcardRunner: Sendable {

    /// The working queue, ordered at init and appended to on a lapse.
    private(set) var queue: [ScheduledCard]
    private(set) var index: Int = 0
    private(set) var isRevealed = false
    /// Final grade per card. A re-queued card overwrites its earlier entry.
    private(set) var grades: [UUID: RecallGrade] = [:]
    /// Cards already given a second chance, so nothing loops forever.
    private var requeuedIDs: Set<UUID> = []
    private(set) var reviewedCount = 0

    private let startedAt: Date
    /// Number of cards in the original deck, for progress reporting.
    let deckSize: Int

    init(cards: [ScheduledCard], now: Date = Date()) {
        self.queue = SpacedRepetition.ordered(cards, state: \.state, now: now)
        self.deckSize = cards.count
        self.startedAt = now
    }

    /// Convenience for a freshly generated deck with no review history.
    init(newCards: [Flashcard], now: Date = Date()) {
        self.init(cards: newCards.map { ScheduledCard(card: $0, state: .new) }, now: now)
    }

    // MARK: - State

    var currentCard: ScheduledCard? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var isFinished: Bool { index >= queue.count }

    /// 0...1. Uses the *original* deck size so re-queued cards don't make the
    /// bar jump backwards — nothing is more demoralising than progress that
    /// un-progresses.
    var progress: Double {
        guard deckSize > 0 else { return 1 }
        return min(Double(grades.count) / Double(deckSize), 1)
    }

    var position: String {
        "\(min(index + 1, queue.count)) of \(queue.count)"
    }

    /// How many cards still to see, including re-queued ones.
    var remaining: Int { max(0, queue.count - index) }

    // MARK: - Actions

    mutating func reveal() {
        isRevealed = true
    }

    /// Grade the current card and move on.
    mutating func grade(_ grade: RecallGrade, now: Date = Date()) -> RecallOutcome? {
        guard let scheduled = currentCard else { return nil }

        let newState = SpacedRepetition.advance(scheduled.state, grade: grade, now: now)
        grades[scheduled.id] = grade
        reviewedCount += 1

        // A forgotten card gets one more go before the session ends.
        var requeued = false
        if grade == .forgot, !requeuedIDs.contains(scheduled.id) {
            requeuedIDs.insert(scheduled.id)
            queue.append(ScheduledCard(card: scheduled.card, state: newState))
            requeued = true
        }

        index += 1
        isRevealed = false

        return RecallOutcome(
            cardID: scheduled.id,
            grade: grade,
            newState: newState,
            xp: .reviewedFlashcard(grade),
            wasRequeued: requeued,
            comment: Self.comment(for: grade, requeued: requeued)
        )
    }

    /// Put the current card back without grading it — used when the student
    /// leaves mid-session.
    mutating func rewind() {
        index = max(0, index - 1)
        isRevealed = false
    }

    // MARK: - Result

    var summary: FlashcardSummary {
        FlashcardSummary(
            deckSize: deckSize,
            reviewed: reviewedCount,
            easy: grades.values.filter { $0 == .easy }.count,
            hard: grades.values.filter { $0 == .hard }.count,
            forgotten: grades.values.filter { $0 == .forgot }.count
        )
    }

    func elapsed(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(startedAt)
    }

    /// Ace's line after a grade. Never scolds a lapse.
    private static func comment(for grade: RecallGrade, requeued: Bool) -> String {
        switch grade {
        case .easy:
            return "Locked in."
        case .hard:
            return "Got there. That one's worth another look soon."
        case .forgot:
            return requeued
                ? "No problem — that's exactly what these are for. I'll bring it back before we finish."
                : "Still fuzzy. We'll keep it near the front."
        }
    }
}

/// What the student sees at the end of a flashcard session.
struct FlashcardSummary: Sendable, Equatable {
    var deckSize: Int
    var reviewed: Int
    var easy: Int
    var hard: Int
    var forgotten: Int

    var known: Int { easy + hard }

    /// Share of the deck recalled without blanking.
    var recallRate: Double {
        let graded = easy + hard + forgotten
        return graded == 0 ? 0 : Double(known) / Double(graded)
    }

    /// The headline. Encouraging at every level — a bad round is information,
    /// not a verdict (§10).
    var headline: String {
        switch recallRate {
        case 0.9...: "You've basically got this deck."
        case 0.7..<0.9: "Solid. A few still need work."
        case 0.4..<0.7: "Good session — the shaky ones are obvious now."
        case 0..<0.4 where forgotten > 0: "Early days with this one. That's what reviewing is for."
        default: "Session done."
        }
    }
}
