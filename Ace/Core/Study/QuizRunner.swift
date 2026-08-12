//
//  QuizRunner.swift
//  Ace
//
//  The state machine behind a quiz run.
//
//  Kept as a pure value type with no SwiftUI and no database, so the whole
//  scoring and hint-ladder behaviour can be tested exhaustively. The view owns
//  one of these and does nothing but render it and forward taps.
//
//  The pedagogy encoded here, and the reason for each choice:
//
//  • **Only the first attempt scores.** Retries are unlimited and encouraged —
//    a student who gets it on the third try has learned something, and cutting
//    them off after one guess teaches nothing. But if retries counted, the
//    score would just measure persistence.
//
//  • **A wrong answer is never a dead end.** It costs nothing, still earns XP
//    for the attempt, and Ace responds with a hint rather than the answer.
//
//  • **Hints are a ladder, not a switch.** Each one narrows without revealing.
//    The answer only appears when the student has climbed the whole ladder or
//    explicitly asks — see `SocraticEngine`.
//

import Foundation

/// What happened when the student answered.
struct AnswerOutcome: Sendable, Equatable {
    var wasCorrect: Bool
    /// True only when they got it right on the very first try — this is what
    /// the score is built from.
    var scoredCorrect: Bool
    /// What Ace says back.
    var reply: SocraticReply
    /// XP earned by this action, before any suppression.
    var xp: XPEvent
    /// Correct answers in a row across the quiz, after this answer.
    var streak: Int
}

/// One question's history within a run.
struct QuestionRecord: Sendable, Equatable {
    var questionID: UUID
    var attempts: Int = 0
    var hintsTaken: Int = 0
    var scoredCorrect: Bool = false
    var wasAnswered: Bool = false
    var wasRevealed: Bool = false
    /// Seconds from the question appearing to the first answer.
    var firstResponseLatency: TimeInterval = 0
}

/// Runs one quiz.
struct QuizRunner: Sendable {

    let quiz: Quiz
    let gradeLevel: GradeLevel

    private(set) var currentIndex: Int = 0
    private(set) var records: [QuestionRecord] = []
    private(set) var correctStreak: Int = 0
    private(set) var longestStreak: Int = 0
    /// Selected choice for the current question, so the view can show it.
    private(set) var selectedChoice: Int?
    /// Hints revealed so far on the current question.
    private(set) var visibleHints: [String] = []
    /// Set once the answer has been shown for the current question.
    private(set) var isAnswerRevealed = false

    private let startedAt: Date
    private var questionShownAt: Date

    init(quiz: Quiz, gradeLevel: GradeLevel, now: Date = Date()) {
        self.quiz = quiz
        self.gradeLevel = gradeLevel
        self.startedAt = now
        self.questionShownAt = now
        self.records = quiz.questions.map { QuestionRecord(questionID: $0.id) }
    }

    // MARK: - Reading the current state

    var currentQuestion: QuizQuestion? {
        quiz.questions.indices.contains(currentIndex) ? quiz.questions[currentIndex] : nil
    }

    var currentRecord: QuestionRecord? {
        records.indices.contains(currentIndex) ? records[currentIndex] : nil
    }

    var questionNumber: Int { currentIndex + 1 }
    var questionCount: Int { quiz.questions.count }

    /// 0...1 through the quiz. Counts the current question as in-progress so the
    /// bar moves the moment you answer rather than only when you advance.
    var progress: Double {
        guard questionCount > 0 else { return 0 }
        let answered = records.filter(\.wasAnswered).count
        return min(Double(answered) / Double(questionCount), 1)
    }

    var isFinished: Bool {
        records.allSatisfy(\.wasAnswered)
    }

    var isOnLastQuestion: Bool { currentIndex >= questionCount - 1 }

    /// True when the current question has been dealt with and the student can
    /// move on.
    var canAdvance: Bool {
        currentRecord.map { $0.wasAnswered } ?? false
    }

    /// More hints available for this question?
    var hasMoreHints: Bool {
        guard let question = currentQuestion else { return false }
        // The last hint is held back — it's the reveal's job, not a hint's.
        return visibleHints.count < max(0, question.hints.count - 1) && !isAnswerRevealed
    }

    // MARK: - Actions

    /// Answer the current question.
    mutating func answer(_ choiceIndex: Int, now: Date = Date()) -> AnswerOutcome? {
        guard let question = currentQuestion,
              records.indices.contains(currentIndex),
              question.choices.indices.contains(choiceIndex)
        else { return nil }

        // Question already settled (answered correctly, or revealed) — ignore
        // stray taps rather than corrupting the record. Note this checks
        // `wasAnswered`, not `scoredCorrect`: a question solved on the second
        // attempt is settled even though it didn't score.
        if records[currentIndex].wasAnswered { return nil }

        let isFirstAttempt = records[currentIndex].attempts == 0
        if isFirstAttempt {
            records[currentIndex].firstResponseLatency = now.timeIntervalSince(questionShownAt)
        }
        records[currentIndex].attempts += 1
        selectedChoice = choiceIndex

        let correct = question.isCorrect(choiceIndex)
        // Taking hints doesn't zero the score, but it does mean this wasn't an
        // unaided win — so it doesn't extend the streak either.
        let unaided = isFirstAttempt && records[currentIndex].hintsTaken == 0
        let scored = correct && unaided

        if correct {
            records[currentIndex].wasAnswered = true
            records[currentIndex].scoredCorrect = scored
            if scored {
                correctStreak += 1
                longestStreak = max(longestStreak, correctStreak)
            }
        } else {
            correctStreak = 0
        }

        let reply = SocraticEngine.feedback(
            correct: correct,
            question: question,
            attemptCount: records[currentIndex].attempts - 1,
            mood: inferredMood,
            streak: correctStreak
        )

        return AnswerOutcome(
            wasCorrect: correct,
            scoredCorrect: scored,
            reply: reply,
            xp: correct ? .answeredCorrectly(streak: correctStreak) : .attemptedAnswer,
            streak: correctStreak
        )
    }

    /// Take the next hint. Returns nil when the ladder is exhausted.
    mutating func takeHint() -> String? {
        guard hasMoreHints,
              let question = currentQuestion,
              records.indices.contains(currentIndex),
              question.hints.indices.contains(visibleHints.count)
        else { return nil }

        let hint = question.hints[visibleHints.count]
        visibleHints.append(hint)
        records[currentIndex].hintsTaken += 1
        return hint
    }

    /// "Just tell me." Always honoured — see §10.
    mutating func revealAnswer() -> SocraticReply? {
        guard let question = currentQuestion, records.indices.contains(currentIndex) else {
            return nil
        }
        isAnswerRevealed = true
        records[currentIndex].wasRevealed = true
        records[currentIndex].wasAnswered = true
        records[currentIndex].scoredCorrect = false
        selectedChoice = question.correctIndex
        correctStreak = 0

        return SocraticEngine.reply(
            for: question,
            attemptCount: records[currentIndex].attempts,
            askedForAnswer: true,
            mood: inferredMood,
            gradeLevel: gradeLevel
        )
    }

    /// Move to the next question. Returns false when the quiz is over.
    @discardableResult
    mutating func advance(now: Date = Date()) -> Bool {
        guard currentIndex < questionCount - 1 else { return false }
        currentIndex += 1
        selectedChoice = nil
        visibleHints = []
        isAnswerRevealed = false
        questionShownAt = now
        return true
    }

    /// Jump to the first unanswered question — used when resuming.
    mutating func skipToUnanswered(now: Date = Date()) {
        if let next = records.firstIndex(where: { !$0.wasAnswered }) {
            currentIndex = next
            selectedChoice = nil
            visibleHints = []
            isAnswerRevealed = false
            questionShownAt = now
        }
    }

    // MARK: - Result

    func result(now: Date = Date()) -> QuizResult {
        QuizResult(
            quizID: quiz.id,
            correctCount: records.filter(\.scoredCorrect).count,
            totalCount: questionCount,
            missedQuestionIDs: records.filter { $0.wasAnswered && !$0.scoredCorrect }.map(\.questionID),
            elapsed: now.timeIntervalSince(startedAt)
        )
    }

    /// Behavioural evidence for the mood heuristics, assembled from the run.
    var signals: BehaviourSignals {
        var out = BehaviourSignals()
        out.correctStreak = correctStreak
        out.wrongStreak = wrongStreak
        out.hintsTaken = currentRecord?.hintsTaken ?? 0
        out.lastResponseLatency = lastLatency
        let latencies = records.filter { $0.firstResponseLatency > 0 }.map(\.firstResponseLatency)
        out.averageResponseLatency = latencies.isEmpty
            ? 0 : latencies.reduce(0, +) / Double(latencies.count)
        return out
    }

    /// Consecutive questions where the student's first attempt was wrong.
    ///
    /// Counts any question they've *had a go at* — not just settled ones.
    /// Someone who missed three first attempts in a row is struggling whether or
    /// not they went back and corrected them, and that's exactly the moment the
    /// Guardian needs to notice (§Part 4).
    private var wrongStreak: Int {
        var count = 0
        for record in records.prefix(currentIndex + 1).reversed() {
            guard record.attempts > 0 || record.wasRevealed else { continue }
            if record.scoredCorrect { break }
            count += 1
        }
        return count
    }

    private var lastLatency: TimeInterval {
        records.prefix(currentIndex + 1).last { $0.firstResponseLatency > 0 }?.firstResponseLatency ?? 0
    }

    private var inferredMood: Mood {
        MoodHeuristics.read(signals: signals, text: nil).mood
    }

    // MARK: - Re-running

    /// Build a follow-up quiz from the questions that were missed.
    ///
    /// Re-running the whole quiz wastes time on what the student already knows;
    /// this is the version worth doing again. Returns nil when nothing was
    /// missed.
    func missedQuestionsQuiz() -> Quiz? {
        let missed = records.filter { $0.wasAnswered && !$0.scoredCorrect }.map(\.questionID)
        guard !missed.isEmpty else { return nil }
        let questions = quiz.questions.filter { missed.contains($0.id) }
        guard !questions.isEmpty else { return nil }
        return Quiz(title: "\(quiz.title) — the tricky ones", questions: questions)
    }
}
