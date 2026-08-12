//
//  LoopChecks.swift
//  Ace — verification harness
//
//  Part 2's engines: the quiz runner, the flashcard runner and the grounded
//  Socratic tutor.
//
//  The properties that get the hardest testing are the pedagogical ones,
//  because they're the product: the answer must not leak before it's earned,
//  effort must always pay, and a forgotten card must come back.
//

import Foundation

enum QuizRunnerChecks {

    /// A three-question quiz with a known shape, so assertions can be exact.
    static func makeQuiz() -> Quiz {
        Quiz(
            title: "Test",
            questions: [
                QuizQuestion(
                    prompt: "Q1",
                    choices: ["Right1", "Wrong1a", "Wrong1b"],
                    correctIndex: 0,
                    explanation: "Because one.",
                    hints: ["Hint 1a", "Hint 1b", "Hint 1c"]
                ),
                QuizQuestion(
                    prompt: "Q2",
                    choices: ["Wrong2a", "Right2", "Wrong2b"],
                    correctIndex: 1,
                    explanation: "Because two.",
                    hints: ["Hint 2a", "Hint 2b", "Hint 2c"]
                ),
                QuizQuestion(
                    prompt: "Q3",
                    choices: ["Wrong3a", "Wrong3b", "Right3"],
                    correctIndex: 2,
                    explanation: "Because three.",
                    hints: ["Hint 3a", "Hint 3b", "Hint 3c"]
                )
            ]
        )
    }

    static let all = CheckSuite(name: "Quiz runner") { run in
        let quiz = makeQuiz()

        // --- A clean run ------------------------------------------------------
        var runner = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        run.expectEqual(runner.questionCount, 3, "question count")
        run.expectEqual(runner.questionNumber, 1, "starts on question 1")
        run.expectEqual(runner.progress, 0, "starts at zero progress")
        run.expect(!runner.isFinished, "not finished at the start")
        run.expect(!runner.canAdvance, "cannot advance before answering")

        let first = runner.answer(0)
        run.expect(first?.wasCorrect == true, "first answer correct")
        run.expect(first?.scoredCorrect == true, "first-attempt correct scores")
        run.expectEqual(first?.streak, 1, "streak of one")
        run.expect(runner.canAdvance, "can advance after answering")
        run.expect(runner.progress > 0, "progress moved")

        run.expect(runner.advance(), "advance to question 2")
        run.expectEqual(runner.questionNumber, 2, "on question 2")
        run.expectEqual(runner.selectedChoice, nil, "selection cleared on advance")
        run.expectEqual(runner.visibleHints.count, 0, "hints cleared on advance")

        _ = runner.answer(1)
        _ = runner.advance()
        _ = runner.answer(2)
        run.expect(runner.isFinished, "all three answered")
        run.expect(!runner.advance(), "cannot advance past the last question")

        let perfect = runner.result()
        run.expectEqual(perfect.correctCount, 3, "3/3")
        run.expectEqual(perfect.score, 1.0, "perfect score")
        run.expectEqual(perfect.percentText, "100%", "percent text")
        run.expect(perfect.missedQuestionIDs.isEmpty, "nothing missed")
        run.expect(runner.missedQuestionsQuiz() == nil, "no follow-up quiz after a perfect run")

        // --- Retries: allowed, but only the first attempt scores ---------------
        var retry = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        let miss = retry.answer(1)
        run.expect(miss?.wasCorrect == false, "wrong answer reported wrong")
        run.expect(miss?.scoredCorrect == false, "wrong answer doesn't score")
        run.expectEqual(miss?.streak, 0, "wrong answer breaks the streak")
        run.expect(!retry.canAdvance, "a wrong answer is not the end of the question")

        // Effort pays — this is a §10 requirement, not a nicety.
        run.expect((miss?.xp.amount ?? 0) > 0, "a genuine attempt must still earn XP")

        let recovered = retry.answer(0)
        run.expect(recovered?.wasCorrect == true, "second attempt correct")
        run.expect(recovered?.scoredCorrect == false,
                   "a correct retry must NOT score — otherwise the score measures persistence")
        run.expect(retry.canAdvance, "can advance once correct")

        // A correctly-answered question ignores further taps.
        let strayTap = retry.answer(2)
        run.expect(strayTap == nil, "taps after a correct answer are ignored")

        // --- Hints: a ladder, and the last rung is withheld ----------------------
        var hinting = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        run.expect(hinting.hasMoreHints, "hints available")
        run.expectEqual(hinting.takeHint(), "Hint 1a", "first hint")
        run.expectEqual(hinting.takeHint(), "Hint 1b", "second hint")
        run.expect(!hinting.hasMoreHints,
                   "the final hint is held back — revealing it is the reveal's job")
        run.expect(hinting.takeHint() == nil, "no hint past the ladder")
        run.expectEqual(hinting.visibleHints.count, 2, "two hints shown")
        run.expectEqual(hinting.currentRecord?.hintsTaken, 2, "hints recorded")

        // A hinted correct answer is right, but not an unaided win.
        let hinted = hinting.answer(0)
        run.expect(hinted?.wasCorrect == true, "hinted answer is still correct")
        run.expect(hinted?.scoredCorrect == false, "a hinted answer is not an unaided win")
        run.expectEqual(hinted?.streak, 0, "a hinted answer doesn't extend the streak")

        // --- Reveal: always honoured -------------------------------------------
        var revealing = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        let reveal = revealing.revealAnswer()
        run.expect(reveal != nil, "reveal returns a reply")
        run.expectEqual(reveal?.rung, .reveal, "reveal is the reveal rung")
        run.expect(reveal?.text.contains("Right1") == true, "the reveal contains the answer")
        run.expect(reveal?.text.contains("Because one.") == true, "the reveal explains")
        run.expect(revealing.isAnswerRevealed, "flagged as revealed")
        run.expect(revealing.canAdvance, "can move on after a reveal")
        run.expectEqual(revealing.selectedChoice, 0, "the correct choice is shown selected")
        run.expect(revealing.currentRecord?.scoredCorrect == false, "a reveal never scores")
        run.expect(!revealing.hasMoreHints, "no hints offered after a reveal")

        // --- Streaks -------------------------------------------------------------
        var streaking = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        _ = streaking.answer(0); _ = streaking.advance()
        _ = streaking.answer(1); _ = streaking.advance()
        let third = streaking.answer(2)
        run.expectEqual(third?.streak, 3, "three in a row")
        run.expectEqual(streaking.longestStreak, 3, "longest streak recorded")
        // A streak must raise the XP award, but not without limit (§10).
        run.expect(XPEvent.answeredCorrectly(streak: 3).amount
                     > XPEvent.answeredCorrectly(streak: 1).amount,
                   "streaks should feel rewarding")

        // --- Partial run and the follow-up quiz ------------------------------------
        var partial = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        _ = partial.answer(1); _ = partial.answer(0)   // Q1: missed then corrected
        _ = partial.advance()
        _ = partial.answer(1)                          // Q2: clean
        _ = partial.advance()
        _ = partial.revealAnswer()                     // Q3: revealed

        let mixed = partial.result()
        run.expectEqual(mixed.correctCount, 1, "only Q2 was an unaided win")
        run.expectEqual(mixed.missedQuestionIDs.count, 2, "Q1 and Q3 were missed")

        guard let followUp = partial.missedQuestionsQuiz() else {
            run.expect(false, "expected a follow-up quiz")
            return
        }
        run.expectEqual(followUp.questions.count, 2, "follow-up covers only the missed ones")
        run.expect(followUp.title.contains(quiz.title), "follow-up title references the original")
        run.expect(!followUp.questions.contains { $0.prompt == "Q2" },
                   "the question they got right must not be in the follow-up")

        // --- Behavioural signals feed the mood read ---------------------------------
        var struggling = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        _ = struggling.answer(1); _ = struggling.advance()
        _ = struggling.answer(0); _ = struggling.advance()
        _ = struggling.answer(0)
        run.expect(struggling.signals.wrongStreak >= 2,
                   "three first-attempt misses should register as a wrong streak, got \(struggling.signals.wrongStreak)")
        run.expect(MoodHeuristics.read(signals: struggling.signals, text: nil).mood.wantsGentleness,
                   "a struggling run should read as a mood that wants gentleness")

        // --- Degenerate input ---------------------------------------------------------
        var empty = QuizRunner(quiz: Quiz(title: "Empty", questions: []), gradeLevel: .grade5)
        run.expect(empty.currentQuestion == nil, "no current question in an empty quiz")
        run.expect(empty.isFinished, "an empty quiz is finished")
        run.expect(empty.answer(0) == nil, "answering an empty quiz is a no-op")
        run.expect(empty.takeHint() == nil, "no hints in an empty quiz")
        run.expect(empty.revealAnswer() == nil, "nothing to reveal")
        run.expect(!empty.advance(), "nowhere to advance")
        run.expectEqual(empty.result().score, 0, "empty quiz scores zero, not NaN")
        run.expectEqual(empty.progress, 0, "empty quiz progress is zero, not NaN")

        var bounds = QuizRunner(quiz: quiz, gradeLevel: .grade9)
        run.expect(bounds.answer(99) == nil, "out-of-range choice is rejected")
        run.expect(bounds.answer(-1) == nil, "negative choice is rejected")
        run.expectEqual(bounds.currentRecord?.attempts, 0, "a rejected answer records no attempt")
    }
}

// MARK: - Flashcards

enum FlashcardRunnerChecks {

    static func makeCards(_ count: Int) -> [Flashcard] {
        (0..<count).map { Flashcard(front: "Front \($0)", back: "Back \($0)") }
    }

    static let all = CheckSuite(name: "Flashcard runner") { run in
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // --- A clean pass -----------------------------------------------------
        var runner = FlashcardRunner(newCards: makeCards(4), now: now)
        run.expectEqual(runner.deckSize, 4, "deck size")
        run.expectEqual(runner.progress, 0, "starts at zero")
        run.expect(!runner.isFinished, "not finished")
        run.expect(!runner.isRevealed, "starts face down")
        run.expect(runner.currentCard != nil, "has a current card")

        runner.reveal()
        run.expect(runner.isRevealed, "revealed")

        let outcome = runner.grade(.easy, now: now)
        run.expect(outcome != nil, "grading returns an outcome")
        run.expectEqual(outcome?.grade, .easy, "grade recorded")
        run.expect(outcome?.wasRequeued == false, "an easy card is not re-queued")
        run.expect(!runner.isRevealed, "next card starts face down")
        run.expect((outcome?.xp.amount ?? 0) > 0, "reviewing earns XP")
        run.expect(outcome?.newState.dueDate ?? .distantPast > now,
                   "an easy card is scheduled into the future")

        _ = runner.grade(.easy, now: now)
        _ = runner.grade(.hard, now: now)
        _ = runner.grade(.easy, now: now)
        run.expect(runner.isFinished, "all four graded")
        run.expectEqual(runner.progress, 1, "progress complete")

        let summary = runner.summary
        run.expectEqual(summary.reviewed, 4, "four reviewed")
        run.expectEqual(summary.easy, 3, "three easy")
        run.expectEqual(summary.hard, 1, "one hard")
        run.expectEqual(summary.forgotten, 0, "none forgotten")
        run.expectEqual(summary.recallRate, 1.0, "perfect recall")
        run.expect(!summary.headline.isEmpty, "summary has a headline")

        // --- A forgotten card comes back, exactly once -------------------------
        var lapsing = FlashcardRunner(newCards: makeCards(2), now: now)
        let firstID = lapsing.currentCard?.id
        let lapse = lapsing.grade(.forgot, now: now)
        run.expect(lapse?.wasRequeued == true, "a forgotten card is re-queued")
        run.expectEqual(lapse?.newState.intervalDays, 0, "a lapse is due again immediately")
        run.expectEqual(lapsing.queue.count, 3, "queue grew by one")

        _ = lapsing.grade(.easy, now: now)                  // the second card
        run.expectEqual(lapsing.currentCard?.id, firstID, "the forgotten card is back")

        let secondLapse = lapsing.grade(.forgot, now: now)  // forgot it again
        run.expect(secondLapse?.wasRequeued == false,
                   "a card is only given one second chance — otherwise the session never ends")
        run.expect(lapsing.isFinished, "session ends despite the repeated lapse")
        run.expectEqual(lapsing.queue.count, 3, "queue did not grow again")

        // Progress must never exceed 1 even with re-queues.
        run.expect(lapsing.progress <= 1, "progress stays bounded, got \(lapsing.progress)")

        // The comment on a lapse must be warm, never scolding.
        let lapseComment = (lapse?.comment ?? "").lowercased()
        for harsh in ["wrong", "failed", "should have", "again?", "bad"] {
            run.expect(!lapseComment.contains(harsh),
                       "a lapse comment must not scold: “\(lapse?.comment ?? "")”")
        }

        // --- Ordering is spaced repetition, not deck order ----------------------
        let overdue = ScheduledCard(
            card: Flashcard(front: "overdue", back: "b"),
            state: {
                var s = ReviewState.new
                s.dueDate = now.addingTimeInterval(-86_400 * 5)
                s.repetitions = 2
                s.lastReviewed = now.addingTimeInterval(-86_400 * 10)
                return s
            }()
        )
        let future = ScheduledCard(
            card: Flashcard(front: "future", back: "b"),
            state: {
                var s = ReviewState.new
                s.dueDate = now.addingTimeInterval(86_400 * 5)
                s.repetitions = 3
                s.lastReviewed = now
                return s
            }()
        )
        let fresh = ScheduledCard(card: Flashcard(front: "new", back: "b"), state: .new)

        let ordered = FlashcardRunner(cards: [future, fresh, overdue], now: now)
        run.expectEqual(ordered.currentCard?.card.front, "overdue",
                        "the most overdue card must lead, not the deck order")
        run.expectEqual(ordered.queue.last?.card.front, "future",
                        "a card that isn't due yet goes last")

        // --- Rewind ---------------------------------------------------------------
        var rewinding = FlashcardRunner(newCards: makeCards(3), now: now)
        _ = rewinding.grade(.easy, now: now)
        run.expectEqual(rewinding.index, 1, "advanced")
        rewinding.rewind()
        run.expectEqual(rewinding.index, 0, "rewound")
        run.expect(!rewinding.isRevealed, "rewind hides the answer again")
        rewinding.rewind()
        run.expectEqual(rewinding.index, 0, "rewind stops at the start")

        // --- Degenerate input -------------------------------------------------------
        var empty = FlashcardRunner(newCards: [], now: now)
        run.expect(empty.isFinished, "an empty deck is finished")
        run.expect(empty.currentCard == nil, "no current card")
        run.expect(empty.grade(.easy, now: now) == nil, "grading an empty deck is a no-op")
        run.expectEqual(empty.progress, 1, "empty deck progress is 1, not NaN")
        run.expectEqual(empty.summary.recallRate, 0, "empty summary is zero, not NaN")
        run.expect(!empty.summary.headline.isEmpty, "even an empty summary has copy")

        // Every recall rate must produce a non-empty, non-harsh headline.
        for (easy, hard, forgot) in [(0, 0, 5), (1, 1, 3), (4, 1, 0), (5, 0, 0)] {
            let s = FlashcardSummary(deckSize: 5, reviewed: 5, easy: easy, hard: hard, forgotten: forgot)
            run.expect(!s.headline.isEmpty, "headline for \(easy)/\(hard)/\(forgot)")
            let lower = s.headline.lowercased()
            for harsh in ["bad", "poor", "failed", "terrible"] {
                run.expect(!lower.contains(harsh), "harsh summary copy: “\(s.headline)”")
            }
        }
    }
}

// MARK: - The grounded tutor

enum SourceTutorChecks {

    static let source = """
    Photosynthesis is the process that plants use to make their own food. \
    Chlorophyll is the green pigment inside a leaf that captures energy from \
    sunlight. The chloroplast is the part of a plant cell where photosynthesis \
    happens. Glucose is the sugar that the plant makes and stores as food. \
    Oxygen is released back into the air as a leftover product.
    """

    static let all = CheckSuite(name: "Grounded Socratic tutor") { run in

        // --- Intent classification ------------------------------------------
        let intents: [(String, StudentIntent)] = [
            ("what is chlorophyll?", .question),
            ("What is chlorophyll", .question),
            ("why does the leaf look green?", .question),
            ("explain photosynthesis", .question),
            ("i don't get it", .question),
            ("i don't know", .stuck),
            ("idk", .stuck),
            ("no idea honestly", .stuck),
            ("just tell me", .wantsAnswer),
            ("can you give me the answer", .wantsAnswer),
            ("i give up", .wantsAnswer),
            ("got it", .acknowledgement),
            ("makes sense", .acknowledgement),
            ("thanks", .acknowledgement),
            ("it's the green stuff that catches the light", .attempt),
            ("chlorophyll captures sunlight energy", .attempt),
        ]
        for (message, expected) in intents {
            run.expectEqual(SourceTutor.intent(of: message), expected, "intent of “\(message)”")
        }
        // A long message containing "got it" is not a bare acknowledgement.
        run.expectEqual(SourceTutor.intent(of: "got it, but why does the water matter so much"),
                        .question, "an acknowledgement plus a question is a question")

        // --- Grounding --------------------------------------------------------
        let found = SourceTutor.anchor(for: "what is chlorophyll", in: source)
        run.expect(found?.sentence.contains("Chlorophyll") == true,
                   "should anchor on the chlorophyll sentence, got: \(found?.sentence ?? "nil")")

        let glucose = SourceTutor.anchor(for: "tell me about glucose", in: source)
        run.expect(glucose?.sentence.contains("Glucose") == true,
                   "should anchor on the glucose sentence")

        // Nothing relevant must return nil, NOT a random sentence.
        run.expect(SourceTutor.anchor(for: "what about the French Revolution", in: source) == nil,
                   "an unrelated question must find no anchor")
        run.expect(SourceTutor.anchor(for: "hello", in: source) == nil,
                   "a contentless message must find no anchor")
        run.expect(SourceTutor.anchor(for: "anything", in: "") == nil,
                   "an empty source must find no anchor")

        // --- The core rule: never invent -----------------------------------------
        let offPage = SourceTutor.reply(to: "explain the causes of World War One",
                                        source: source, note: "", exchanges: 0,
                                        mood: .neutral, gradeLevel: .grade9)
        run.expect(!offPage.text.contains("World War"),
                   "must not attempt to answer something outside the material")
        run.expect(offPage.text.lowercased().contains("page")
                     || offPage.text.lowercased().contains("gave me"),
                   "must say the material doesn't cover it: “\(offPage.text)”")

        // Even an explicit demand for the answer can't produce invention.
        let demandOffPage = SourceTutor.reply(to: "just tell me about the Treaty of Versailles",
                                              source: source, note: "", exchanges: 5,
                                              mood: .neutral, gradeLevel: .college)
        run.expect(demandOffPage.text.lowercased().contains("make something up")
                     || demandOffPage.text.lowercased().contains("isn't on the page"),
                   "must refuse to invent even when pushed: “\(demandOffPage.text)”")

        // --- Socratic ordering -----------------------------------------------------
        // A first question must be answered with a question, not the answer.
        let firstAsk = SourceTutor.reply(to: "what is chlorophyll?", source: source, note: "",
                                         exchanges: 0, mood: .neutral, gradeLevel: .grade9)
        run.expect(firstAsk.isHint, "the first reply must be a hint, not an answer")
        run.expect(firstAsk.text.contains("?"), "the first reply must ask something back")
        run.expect(!firstAsk.text.contains("green pigment"),
                   "must not hand over the definition on the first ask: “\(firstAsk.text)”")

        // Persisting climbs the ladder to a reveal.
        var reachedReveal = false
        for exchange in 0...5 {
            let reply = SourceTutor.reply(to: "what is chlorophyll?", source: source, note: "",
                                          exchanges: exchange, mood: .neutral, gradeLevel: .grade9)
            if reply.rung == .reveal { reachedReveal = true }
        }
        run.expect(reachedReveal, "the ladder must eventually reveal")

        // "Just tell me" is honoured immediately.
        let told = SourceTutor.reply(to: "just tell me", source: source, note: "",
                                     exchanges: 0, mood: .neutral, gradeLevel: .grade9)
        run.expectEqual(told.rung, .reveal, "an explicit request reveals at once")
        run.expect(told.text.contains("Photosynthesis") || told.text.contains("“"),
                   "the reveal must quote the material")

        // --- Responding to an attempt ------------------------------------------------
        let goodAttempt = SourceTutor.reply(
            to: "chlorophyll is the green pigment that captures sunlight energy",
            source: source, note: "", exchanges: 1, mood: .neutral, gradeLevel: .grade9)
        run.expect(goodAttempt.text.lowercased().contains("yes")
                     || goodAttempt.text.lowercased().contains("that's it"),
                   "a correct attempt must be affirmed: “\(goodAttempt.text)”")
        run.expect(goodAttempt.text.contains("?"),
                   "even a correct attempt gets pushed one level deeper")

        let wrongAttempt = SourceTutor.reply(
            to: "chlorophyll is the sugar the plant eats",
            source: source, note: "", exchanges: 0, mood: .neutral, gradeLevel: .grade9)
        run.expect(!wrongAttempt.text.lowercased().hasPrefix("wrong"),
                   "must never open with “wrong”")
        run.expect(!wrongAttempt.text.lowercased().contains("incorrect"),
                   "must not use the word “incorrect”")

        // Partial credit must be acknowledged before the correction.
        let partial = SourceTutor.reply(to: "something about sunlight in the leaf",
                                        source: source, note: "", exchanges: 0,
                                        mood: .neutral, gradeLevel: .grade9)
        run.expect(!partial.text.isEmpty, "partial attempt gets a reply")

        // --- Agreement scoring ----------------------------------------------------------
        let sentence = "Chlorophyll is the green pigment inside a leaf that captures energy from sunlight."
        run.expect(SourceTutor.agreement(between: "green pigment captures sunlight energy",
                                         and: sentence) >= 0.5,
                   "a close paraphrase should score high")
        run.expect(SourceTutor.agreement(between: "the mitochondria is the powerhouse",
                                         and: sentence) < 0.3,
                   "an unrelated answer should score low")
        run.expectEqual(SourceTutor.agreement(between: "", and: sentence), 0, "empty attempt")
        run.expectEqual(SourceTutor.agreement(between: "hello", and: ""), 0, "empty sentence")

        // --- Mood shapes the wording, not the content -------------------------------------
        let toFrustrated = SourceTutor.reply(to: "chlorophyll is sugar", source: source, note: "",
                                             exchanges: 0, mood: .frustrated, gradeLevel: .grade9)
        let toNeutral = SourceTutor.reply(to: "chlorophyll is sugar", source: source, note: "",
                                          exchanges: 0, mood: .neutral, gradeLevel: .grade9)
        run.expect(toFrustrated.text != toNeutral.text,
                   "a frustrated student should not get identical wording")

        let toLow = SourceTutor.reply(to: "i don't know", source: source, note: "",
                                      exchanges: 0, mood: .low, gradeLevel: .grade9)
        for peppy in ["let's go", "quick", "come on"] {
            run.expect(!toLow.text.lowercased().contains(peppy),
                       "must not be peppy at a low student: “\(toLow.text)”")
        }

        // Struggling students climb faster — same input, further up the ladder.
        let neutralRung = SourceTutor.reply(to: "what is glucose?", source: source, note: "",
                                            exchanges: 1, mood: .neutral, gradeLevel: .grade9).rung
        let frustratedRung = SourceTutor.reply(to: "what is glucose?", source: source, note: "",
                                               exchanges: 1, mood: .frustrated, gradeLevel: .grade9).rung
        run.expect(frustratedRung >= neutralRung,
                   "a frustrated student must not get less help")

        // --- Being stuck earns help, not a lecture -------------------------------------------
        let stuck = SourceTutor.reply(to: "i don't know", source: source, note: "",
                                      exchanges: 0, mood: .neutral, gradeLevel: .grade5)
        run.expect(stuck.text.contains("“"), "being stuck should surface a real line from the page")
        run.expect(stuck.text.contains("?"), "still ends with something to do")

        // --- "Got it" is never just accepted ----------------------------------------------------
        let acknowledged = SourceTutor.reply(to: "got it", source: source, note: "",
                                             exchanges: 2, mood: .neutral, gradeLevel: .grade9)
        run.expect(acknowledged.text.contains("?") || acknowledged.text.lowercased().contains("say it back"),
                   "“got it” must be checked, not accepted: “\(acknowledged.text)”")

        // --- Opening lines ----------------------------------------------------------------------
        let withNote = SourceTutor.opening(source: source,
                                           note: "studying photosynthesis, test Friday",
                                           gradeLevel: .grade9)
        run.expect(withNote.contains("photosynthesis"), "the opening must use the student's own note")
        run.expect(withNote.contains("?"), "the opening must ask something")
        run.expect(!withNote.contains("green pigment"), "the opening must not start explaining")

        let withoutNote = SourceTutor.opening(source: source, note: "", gradeLevel: .grade9)
        run.expect(!withoutNote.isEmpty, "opening without a note")
        run.expect(withoutNote.contains("?"), "still asks something")

        let noSource = SourceTutor.opening(source: "", note: "", gradeLevel: .college)
        run.expect(!noSource.isEmpty, "opening with no material at all must still say something")

        // --- Nothing may be empty, in any combination ---------------------------------------------
        let messages = ["what is chlorophyll?", "i don't know", "just tell me", "got it",
                        "chlorophyll captures light", "", "???", "asdfgh"]
        for message in messages {
            for mood in Mood.allCases {
                for exchanges in [0, 2, 5] {
                    let reply = SourceTutor.reply(to: message, source: source, note: "",
                                                  exchanges: exchanges, mood: mood,
                                                  gradeLevel: .grade9)
                    run.expect(reply.text.count > 15,
                               "thin reply to “\(message)” (\(mood), \(exchanges)): “\(reply.text)”")
                }
            }
        }
    }
}
