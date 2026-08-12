//
//  TutorChecks.swift
//  Ace — verification harness
//
//  The Socratic rule is Ace's signature behaviour, so it gets tested like a
//  safety property: the answer must not leak before the student has earned it,
//  and an explicit request must always be honoured.
//

import Foundation

enum TutorChecks {

    private static let sampleQuestion = QuizQuestion(
        prompt: "________ is the green pigment that absorbs light energy.",
        choices: ["Chlorophyll", "Glucose", "Stomata", "Respiration"],
        correctIndex: 0,
        explanation: "Chlorophyll — the green pigment that absorbs light energy.",
        hints: [
            "Think about the part that deals with pigment.",
            "It starts with “C” and it's 11 letters.",
            "It's the one that means: the green pigment that absorbs light energy."
        ]
    )

    static let socratic = CheckSuite(name: "Socratic tutor") { run in
        let question = sampleQuestion
        let answer = question.correctAnswer.lowercased()

        // --- The core rule -------------------------------------------------
        // On a first attempt, with no request for the answer, the answer must
        // NOT appear — in any mood.
        for mood in Mood.allCases {
            let reply = SocraticEngine.reply(for: question, attemptCount: 0,
                                             askedForAnswer: false, mood: mood,
                                             gradeLevel: .grade9)
            run.expect(!reply.text.lowercased().contains(answer),
                       "answer leaked on first attempt in mood \(mood): \(reply.text)")
            run.expect(reply.isHint, "first attempt must be a hint, not an answer (\(mood))")
        }

        // Climbing the ladder: more attempts eventually reveals.
        var revealedAt: Int?
        for attempt in 0...6 {
            let reply = SocraticEngine.reply(for: question, attemptCount: attempt,
                                             askedForAnswer: false, mood: .neutral,
                                             gradeLevel: .grade9)
            if reply.rung == .reveal && revealedAt == nil { revealedAt = attempt }
        }
        run.expect(revealedAt != nil, "the ladder must eventually reveal the answer")
        run.expect((revealedAt ?? 99) >= 3,
                   "must not reveal before the 4th attempt in a neutral mood, revealed at \(revealedAt ?? -1)")

        // Each rung must be reached in order and never skip backwards.
        var previous = SocraticRung.orient
        for attempt in 0...4 {
            let rung = SocraticEngine.rung(attemptCount: attempt, askedForAnswer: false, mood: .neutral)
            run.expect(rung >= previous, "rung went backwards at attempt \(attempt)")
            previous = rung
        }

        // --- "Just tell me" must always be honoured --------------------------
        for phrase in ["just tell me", "Just tell me!", "can you give me the answer",
                       "what's the answer", "i give up", "show me the answer"] {
            run.expect(SocraticEngine.isAskingForAnswer(phrase),
                       "did not recognise a request for the answer: “\(phrase)”")
        }
        for phrase in ["can you give me a hint", "i don't get it", "what does this mean",
                       "tell me more about photosynthesis"] {
            run.expect(!SocraticEngine.isAskingForAnswer(phrase),
                       "misread a normal question as a demand for the answer: “\(phrase)”")
        }

        let onRequest = SocraticEngine.reply(for: question, attemptCount: 0,
                                             askedForAnswer: true, mood: .neutral,
                                             gradeLevel: .grade9)
        run.expectEqual(onRequest.rung, .reveal, "an explicit request must reveal immediately")
        run.expect(onRequest.text.contains(question.correctAnswer),
                   "the reveal must actually contain the answer")
        run.expect(onRequest.text.contains(question.explanation),
                   "the reveal must explain, not just state")
        run.expect(!onRequest.isHint, "a reveal is not a hint")

        // --- Struggling students climb faster ---------------------------------
        let neutralRung = SocraticEngine.rung(attemptCount: 1, askedForAnswer: false, mood: .neutral)
        for gentleMood: Mood in [.frustrated, .low, .confused] {
            let gentleRung = SocraticEngine.rung(attemptCount: 1, askedForAnswer: false, mood: gentleMood)
            run.expect(gentleRung > neutralRung,
                       "a struggling student (\(gentleMood)) should get more help, not the same")
        }

        // --- Feedback tone ------------------------------------------------------
        let wrongWhenFrustrated = SocraticEngine.feedback(correct: false, question: question,
                                                          attemptCount: 1, mood: .frustrated, streak: 0)
        run.expect(!wrongWhenFrustrated.text.lowercased().contains(answer),
                   "wrong-answer feedback must not leak the answer")
        for harsh in ["wrong", "incorrect", "no.", "failed", "bad"] {
            run.expect(!wrongWhenFrustrated.text.lowercased().hasPrefix(harsh),
                       "must not lead with the mistake: \(wrongWhenFrustrated.text)")
        }

        let correctFeedback = SocraticEngine.feedback(correct: true, question: question,
                                                      attemptCount: 0, mood: .energized, streak: 4)
        run.expect(correctFeedback.text.contains("4"), "a streak should be acknowledged")

        // Correct-with-a-streak should still probe for reasoning — getting it
        // right by elimination isn't understanding.
        let probing = SocraticEngine.feedback(correct: true, question: question,
                                              attemptCount: 0, mood: .neutral, streak: 3)
        run.expect(probing.text.lowercased().contains("why"),
                   "should ask for the reasoning behind a correct answer")

        // --- Openers ---------------------------------------------------------------
        // Every mood must produce a non-empty, distinct-feeling opener, and the
        // gentle moods must not sound peppy.
        for mood in Mood.allCases {
            let reply = SocraticEngine.reply(for: question, attemptCount: 0,
                                             askedForAnswer: false, mood: mood, gradeLevel: .grade5)
            run.expect(!reply.text.isEmpty, "\(mood) produced an empty reply")
            run.expect(reply.text.count > 20, "\(mood) reply is too thin: \(reply.text)")
        }
        let lowReply = SocraticEngine.reply(for: question, attemptCount: 0, askedForAnswer: false,
                                            mood: .low, gradeLevel: .grade9)
        for peppy in ["let's go", "quick one", "next!"] {
            run.expect(!lowReply.text.lowercased().contains(peppy),
                       "must not sound peppy at a low student: \(lowReply.text)")
        }

        // --- Grade-level register ----------------------------------------------------
        let youngReveal = SocraticEngine.reply(for: question, attemptCount: 0, askedForAnswer: true,
                                               mood: .neutral, gradeLevel: .grade5)
        let collegeReveal = SocraticEngine.reply(for: question, attemptCount: 0, askedForAnswer: true,
                                                 mood: .neutral, gradeLevel: .college)
        run.expect(youngReveal.text != collegeReveal.text,
                   "a 5th grader and a college student should not get identical wording")
    }

    // MARK: - Mood heuristics

    static let mood = CheckSuite(name: "Mood heuristics") { run in

        // --- Clear signals ----------------------------------------------------
        var rolling = BehaviourSignals.none
        rolling.correctStreak = 5
        let energised = MoodHeuristics.read(signals: rolling, text: nil)
        run.expectEqual(energised.mood, .energized, "5 correct in a row reads as energised")
        run.expect(energised.isActionable, "a clear streak should be actionable")

        var struggling = BehaviourSignals.none
        struggling.wrongStreak = 4
        let frustrated = MoodHeuristics.read(signals: struggling, text: nil)
        run.expectEqual(frustrated.mood, .frustrated, "4 wrong in a row reads as frustrated")

        var mildlyStuck = BehaviourSignals.none
        mildlyStuck.wrongStreak = 2
        run.expectEqual(MoodHeuristics.read(signals: mildlyStuck, text: nil).mood, .confused,
                        "2 wrong reads as confused, not yet frustrated")

        var gone = BehaviourSignals.none
        gone.idleSeconds = 200
        run.expectEqual(MoodHeuristics.read(signals: gone, text: nil).mood, .distracted,
                        "long idle reads as distracted")

        // Distraction must win over performance — a stale streak isn't current.
        var goneButWinning = BehaviourSignals.none
        goneButWinning.idleSeconds = 200
        goneButWinning.correctStreak = 6
        run.expectEqual(MoodHeuristics.read(signals: goneButWinning, text: nil).mood, .distracted,
                        "idle must outrank a stale streak")

        // --- Text signals --------------------------------------------------------
        run.expectEqual(MoodHeuristics.read(signals: .none, text: "ugh this makes no sense").mood,
                        .frustrated, "frustration words")
        run.expectEqual(MoodHeuristics.read(signals: .none, text: "i don't get it").mood,
                        .confused, "confusion words")
        run.expectEqual(MoodHeuristics.read(signals: .none, text: "i'm so tired").mood,
                        .low, "low-energy words")
        run.expectEqual(MoodHeuristics.read(signals: .none, text: "let's go, next one").mood,
                        .energized, "energy words")

        // Low outranks frustration when both appear — the gentler read is the
        // safer one to act on.
        run.expectEqual(MoodHeuristics.read(signals: .none, text: "ugh i'm exhausted").mood,
                        .low, "low should win over frustration")

        // --- Honest uncertainty ----------------------------------------------------
        let noSignal = MoodHeuristics.read(signals: .none, text: nil)
        run.expectEqual(noSignal.mood, .neutral, "no signal reads as neutral")
        run.expect(!noSignal.isActionable,
                   "no signal must NOT be actionable — Ace should not change personality on a guess")
        run.expect(!noSignal.rationale.isEmpty, "every reading needs a rationale for the debug HUD")

        // Every reading, from any input, must carry a rationale and a valid
        // confidence.
        let inputs: [(BehaviourSignals, String?)] = [
            (.none, nil), (.none, ""), (rolling, "nice"), (struggling, "ugh"),
            (gone, nil), (mildlyStuck, "i don't get it")
        ]
        for (signals, text) in inputs {
            let reading = MoodHeuristics.read(signals: signals, text: text)
            run.expect(reading.confidence >= 0 && reading.confidence <= 1,
                       "confidence out of range: \(reading.confidence)")
            run.expect(!reading.rationale.isEmpty, "missing rationale")
        }

        // --- Guardian thresholds (Part 4 relies on these) -------------------------
        // Must NOT be paranoid: one wrong answer is not a crisis of confidence.
        var oneWrong = BehaviourSignals.none
        oneWrong.wrongStreak = 1
        run.expect(!MoodHeuristics.shouldOfferHelp(signals: oneWrong),
                   "one wrong answer must not trigger an intervention")
        var oneHint = BehaviourSignals.none
        oneHint.hintsTaken = 1
        run.expect(!MoodHeuristics.shouldOfferHelp(signals: oneHint),
                   "taking one hint is normal, not a struggle signal")
        run.expect(!MoodHeuristics.shouldOfferHelp(signals: .none),
                   "a fresh session must not trigger an intervention")

        // Must fire on genuine struggle.
        run.expect(MoodHeuristics.shouldOfferHelp(signals: struggling),
                   "3+ wrong in a row should offer help")
        var manyHints = BehaviourSignals.none
        manyHints.hintsTaken = 3
        run.expect(MoodHeuristics.shouldOfferHelp(signals: manyHints), "3 hints should offer help")
        var longPause = BehaviourSignals.none
        longPause.lastResponseLatency = 90
        run.expect(MoodHeuristics.shouldOfferHelp(signals: longPause), "a 90s pause should offer help")

        // Return nudge.
        run.expect(MoodHeuristics.shouldNudgeBack(signals: gone), "long idle should nudge back")
        run.expect(!MoodHeuristics.shouldNudgeBack(signals: .none), "a fresh session must not nudge")
    }
}
