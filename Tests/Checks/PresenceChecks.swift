//
//  PresenceChecks.swift
//  Ace — verification harness
//
//  Part 4: goals, body doubling, the Guardian, comfort, Do Not Disturb, focus
//  music and speaking drills.
//
//  The heaviest testing goes on the behavioural guarantees rather than the
//  arithmetic, because those are the ones that would quietly rot:
//    • DND never removes a capability (§10: nudge, never cage)
//    • comfort comes before the bridge back to work, always
//    • the Guardian is late and quiet, not paranoid
//    • the safety net still fires through every one of these surfaces
//

import Foundation

// MARK: - Goals

enum GoalChecks {
    static let all = CheckSuite(name: "Study goals") { run in

        // --- Durations -------------------------------------------------------
        let durations: [(String, Int)] = [
            ("25 minutes", 25), ("25 mins", 25), ("45 min", 45),
            ("an hour", 60), ("1 hour", 60), ("2 hours", 120),
            ("half an hour", 30), ("half hour", 30),
            ("let's go for 30 minutes", 30), ("twenty minutes", 20),
            ("fifteen mins", 15)
        ]
        for (input, expected) in durations {
            let goal = GoalParser.parse(input)
            if case .duration(let minutes) = goal.target {
                run.expectEqual(minutes, expected, "“\(input)”")
            } else {
                run.expect(false, "“\(input)” should parse as a duration, got \(goal.target)")
            }
        }

        // --- Counts -----------------------------------------------------------
        let counts: [(String, Int, GoalTarget.CountUnit)] = [
            ("10 questions", 10, .questions),
            ("do 20 cards", 20, .cards),
            ("five questions", 5, .questions),
            ("15 flashcards", 15, .cards),
            ("3 pages", 3, .pages)
        ]
        for (input, expectedCount, expectedUnit) in counts {
            let goal = GoalParser.parse(input)
            if case .count(let count, let unit) = goal.target {
                run.expectEqual(count, expectedCount, "“\(input)” count")
                run.expectEqual(unit, expectedUnit, "“\(input)” unit")
            } else {
                run.expect(false, "“\(input)” should parse as a count, got \(goal.target)")
            }
        }

        // --- Landmarks ---------------------------------------------------------
        // The example straight from the brief.
        let chapter = GoalParser.parse("let's go till chapter 4")
        if case .landmark(let name) = chapter.target {
            run.expectEqual(name, "chapter 4", "the lead-in must be stripped")
        } else {
            run.expect(false, "“let's go till chapter 4” must be a landmark, got \(chapter.target)")
        }
        run.expectEqual(chapter.rawText, "let's go till chapter 4",
                        "the student's own words are kept verbatim")
        run.expect(!chapter.isMeasurable, "a landmark isn't measurable")

        for input in ["until I understand mitosis", "finish the essay",
                      "get through the reading", "whatever feels right"] {
            let goal = GoalParser.parse(input)
            if case .landmark = goal.target {
                run.expect(true, "“\(input)”")
            } else {
                run.expect(false, "“\(input)” should be a landmark, got \(goal.target)")
            }
            run.expect(!goal.displayText.isEmpty, "“\(input)” needs display text")
        }

        // Parsing never fails — an unparseable goal is still a goal.
        run.expect(!GoalParser.parse("").displayText.isEmpty, "empty falls back to a default")
        run.expect(!GoalParser.parse("aaaaa").displayText.isEmpty, "junk is still a goal")
        run.expect(!GoalParser.parse("!!!").displayText.isEmpty, "punctuation is still a goal")

        // --- Display ------------------------------------------------------------
        run.expectEqual(GoalParser.parse("60 minutes").displayText, "1 hour", "an hour reads as an hour")
        run.expectEqual(GoalParser.parse("120 minutes").displayText, "2 hours", "two hours")
        run.expectEqual(GoalParser.parse("1 question").displayText, "1 question", "singular")
        run.expectEqual(GoalParser.parse("2 questions").displayText, "2 questions", "plural")

        // --- Milestones -----------------------------------------------------------
        run.expect(Milestone.reached(at: 0.1) == nil, "nothing before a quarter")
        run.expectEqual(Milestone.reached(at: 0.30), .quarter, "quarter")
        run.expectEqual(Milestone.reached(at: 0.55), .half, "half")
        run.expectEqual(Milestone.reached(at: 0.99), .threeQuarters, "three quarters")
        run.expectEqual(Milestone.allCases.count, 3,
                        "three check-ins per session — this is co-working, not a fitness app")

        // --- Progress maths ---------------------------------------------------------
        run.expectEqual(GoalProgress(completed: 5, total: 10).fraction, 0.5, "half")
        run.expectEqual(GoalProgress(completed: 20, total: 10).fraction, 1, "clamped at 1")
        run.expectEqual(GoalProgress.none.fraction, 0, "no total is zero, not NaN")
        run.expect(!GoalProgress.none.isComplete, "an unmeasurable goal is never auto-complete")
        run.expect(GoalProgress(completed: 10, total: 10).isComplete, "complete")
    }
}

// MARK: - Body double

enum BodyDoubleChecks {
    static let all = CheckSuite(name: "Body double sessions") { run in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

        // --- The full arc -----------------------------------------------------
        var session = BodyDoubleSession()
        run.expectEqual(session.phase, .settingGoal, "starts by agreeing a goal")
        run.expect(session.tick(now: start) == nil, "nothing happens before a goal is set")

        let goal = GoalParser.parse("40 minutes")
        let opening = session.begin(goal: goal, now: start)
        run.expectEqual(session.phase, .working, "working after begin")
        run.expectEqual(opening.kind, .opening, "opening message")
        run.expect(opening.isSpoken, "the opening is said out loud")
        run.expect(opening.text.contains("40"), "the opening references the goal")

        // Nothing at all for the first quarter — that's the point.
        run.expect(session.tick(now: at(1)) == nil, "silent at 1 minute")
        run.expect(session.tick(now: at(5)) == nil, "silent at 5 minutes")

        let quarter = session.tick(now: at(11))
        run.expectEqual(quarter?.kind, .milestone, "quarter check-in at 25%")
        run.expect(quarter?.isSpoken == false,
                   "check-ins are silent — a voice interrupting concentration is worse than text")

        run.expect(session.tick(now: at(12)) == nil, "a milestone fires once, not repeatedly")

        let half = session.tick(now: at(21))
        run.expectEqual(half?.kind, .milestone, "half")
        run.expect(half?.text.contains("20") == true, "half of 40 minutes is mentioned")

        let threeQuarters = session.tick(now: at(31))
        run.expectEqual(threeQuarters?.kind, .milestone, "three quarters")

        // Goal reached → the session closes itself.
        let done = session.tick(now: at(41))
        run.expectEqual(done?.kind, .closing, "reaching the goal ends the session")
        run.expectEqual(session.phase, .finished(metGoal: true), "finished, goal met")

        // The closing line must point outward (§10).
        let closing = (done?.text ?? "").lowercased()
        run.expect(closing.contains("someone") || closing.contains("something else"),
                   "the closing line must point the student outward, not deeper in: “\(done?.text ?? "")”")

        // --- Counting goals -------------------------------------------------------
        var counting = BodyDoubleSession()
        _ = counting.begin(goal: GoalParser.parse("8 questions"), now: start)
        run.expectEqual(counting.progress(now: start).fraction, 0, "starts at zero")

        for _ in 0..<2 { counting.recordCompletion() }
        let countQuarter = counting.tick(now: at(3))
        run.expectEqual(countQuarter?.kind, .milestone, "2 of 8 crosses a quarter")

        for _ in 0..<6 { counting.recordCompletion() }
        let countDone = counting.tick(now: at(9))
        run.expectEqual(countDone?.kind, .closing, "8 of 8 finishes")

        // --- Landmark goals: time-based check-ins instead -----------------------------
        var landmark = BodyDoubleSession()
        _ = landmark.begin(goal: GoalParser.parse("let's go till chapter 4"), now: start)
        run.expectEqual(landmark.progress(now: at(10)), .none,
                        "a landmark goal has no measurable progress")
        run.expect(landmark.tick(now: at(5)) == nil, "quiet early on")
        run.expect(landmark.tick(now: at(21))?.kind == .milestone, "checks in at 20 minutes")
        run.expect(landmark.tick(now: at(41))?.kind == .milestone, "and again at 40")

        let reached = landmark.markLandmarkReached(now: at(50))
        run.expectEqual(reached.kind, .closing, "the student says when a landmark is done")
        run.expectEqual(landmark.phase, .finished(metGoal: true), "counts as met")

        // --- Break suggestion -----------------------------------------------------------
        var marathon = BodyDoubleSession()
        _ = marathon.begin(goal: GoalParser.parse("3 hours"), now: start)
        // Consume the milestones so they don't mask the break suggestion.
        for minute in [46.0, 91.0] { _ = marathon.tick(now: at(minute)) }
        var sawBreak = false
        for minute in stride(from: 51.0, to: 140.0, by: 5) {
            if marathon.tick(now: at(minute))?.kind == .breakSuggestion { sawBreak = true; break }
        }
        run.expect(sawBreak, "a long session should suggest a break")

        // ...but only once. Nagging is the failure mode.
        var nagCount = 0
        for minute in stride(from: 141.0, to: 175.0, by: 5) {
            if marathon.tick(now: at(minute))?.kind == .breakSuggestion { nagCount += 1 }
        }
        run.expectEqual(nagCount, 0, "the break is suggested once, never repeated")

        // --- Pausing --------------------------------------------------------------------
        var pausing = BodyDoubleSession()
        _ = pausing.begin(goal: GoalParser.parse("30 minutes"), now: start)
        pausing.pause(now: at(10))
        run.expectEqual(pausing.phase, .paused, "paused")
        run.expect(pausing.tick(now: at(20)) == nil, "no check-ins while paused")
        pausing.resume(now: at(20))
        run.expectEqual(pausing.phase, .working, "resumed")
        // 10 minutes of work, 10 minutes paused, so at wall-clock 20 the session
        // should read ~10 minutes.
        run.expectEqual(pausing.elapsedMinutes(now: at(20)), 10,
                        "paused time must not count toward the goal")

        // --- Stopping early is not a failure ----------------------------------------------
        var early = BodyDoubleSession()
        _ = early.begin(goal: GoalParser.parse("60 minutes"), now: start)
        let stopped = early.finish(now: at(12))
        run.expectEqual(early.phase, .finished(metGoal: false), "goal not met")
        let stoppedText = stopped.text.lowercased()
        run.expect(stoppedText.contains("fine") || stoppedText.contains("showed up"),
                   "stopping early must be met with acceptance: “\(stopped.text)”")
        for guilt in ["only", "just", "failed", "should have", "gave up", "quit"] {
            run.expect(!stoppedText.contains(guilt),
                       "no guilt language when someone stops early: “\(guilt)”")
        }

        // --- Every message must be real copy -------------------------------------------------
        for goalText in ["25 minutes", "10 questions", "let's go till chapter 4"] {
            var probe = BodyDoubleSession()
            let message = probe.begin(goal: GoalParser.parse(goalText), now: start)
            run.expect(message.text.count > 25, "thin opening for “\(goalText)”")
            run.expect(!message.text.contains("!"),
                       "co-working copy shouldn't shout: “\(message.text)”")
        }
    }
}

// MARK: - Guardian

enum GuardianChecks {
    static let all = CheckSuite(name: "Guardian — struggle and focus") { run in
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // --- Restraint: the most important property ---------------------------
        let guardian = Guardian()
        run.expectEqual(guardian.evaluate(signals: .none, mood: .unknown, now: now), .none,
                        "a fresh session must be left alone")

        var oneWrong = BehaviourSignals()
        oneWrong.wrongStreak = 1
        run.expectEqual(guardian.evaluate(signals: oneWrong, mood: .unknown, now: now), .none,
                        "one wrong answer is not an event")

        var twoWrong = BehaviourSignals()
        twoWrong.wrongStreak = 2
        run.expectEqual(guardian.evaluate(signals: twoWrong, mood: .unknown, now: now), .none,
                        "two wrong answers is still just studying")

        var oneHint = BehaviourSignals()
        oneHint.hintsTaken = 1
        run.expectEqual(guardian.evaluate(signals: oneHint, mood: .unknown, now: now), .none,
                        "taking a hint is the system working, not a problem")

        var shortPause = BehaviourSignals()
        shortPause.lastResponseLatency = 25
        run.expectEqual(guardian.evaluate(signals: shortPause, mood: .unknown, now: now), .none,
                        "25 seconds is thinking, not being stuck")

        // A frustrated read on its own must not interrupt — it changes how Ace
        // speaks, which the tutor already handles.
        run.expectEqual(guardian.evaluate(signals: .none,
                                          mood: MoodReading(mood: .frustrated, confidence: 0.9),
                                          now: now),
                        .none,
                        "a mood alone is not grounds to interrupt")

        // --- Escalation ---------------------------------------------------------
        var struggling = BehaviourSignals()
        struggling.wrongStreak = 3
        run.expectEqual(guardian.evaluate(signals: struggling, mood: .unknown, now: now), .offerHint,
                        "three in a row earns an offer of help")

        struggling.wrongStreak = 4
        run.expectEqual(guardian.evaluate(signals: struggling, mood: .unknown, now: now), .easeOff,
                        "four escalates to easier material")

        struggling.wrongStreak = 5
        run.expectEqual(guardian.evaluate(signals: struggling, mood: .unknown, now: now), .suggestBreak,
                        "five means stop, not try harder")

        var hintHeavy = BehaviourSignals()
        hintHeavy.hintsTaken = 3
        run.expectEqual(guardian.evaluate(signals: hintHeavy, mood: .unknown, now: now), .reexplain,
                        "three hints means the explanation is the problem")

        var stuck = BehaviourSignals()
        stuck.lastResponseLatency = 70
        run.expectEqual(guardian.evaluate(signals: stuck, mood: .unknown, now: now), .offerHint,
                        "a long silence earns an offer")

        var idle = BehaviourSignals()
        idle.idleSeconds = 120
        run.expectEqual(guardian.evaluate(signals: idle, mood: .unknown, now: now), .checkIn,
                        "going quiet earns a check-in")

        // Escalation must not skip backwards.
        var ladder = Guardian()
        ladder.recordNudge(.offerHint, now: now)
        var stillStruggling = BehaviourSignals()
        stillStruggling.wrongStreak = 3
        run.expectEqual(ladder.evaluate(signals: stillStruggling, mood: .unknown,
                                        now: now.addingTimeInterval(Guardian.cooldown + 1)),
                        .reexplain,
                        "repeating the same offer is how a nudge becomes nagging")

        // --- Cooldown -------------------------------------------------------------
        var cooling = Guardian()
        cooling.recordNudge(.offerHint, now: now)
        run.expect(!cooling.canIntervene(now: now.addingTimeInterval(10)),
                   "must not interrupt again ten seconds later")
        run.expect(cooling.canIntervene(now: now.addingTimeInterval(Guardian.cooldown + 1)),
                   "may interrupt again after the cooldown")
        run.expectEqual(cooling.evaluate(signals: struggling, mood: .unknown,
                                         now: now.addingTimeInterval(5)),
                        .none,
                        "the cooldown suppresses even a strong signal")

        // --- Giving up -------------------------------------------------------------
        var persistent = Guardian()
        var time = now
        for _ in 0..<Guardian.maxNudgesPerSession {
            persistent.recordNudge(.offerHint, now: time)
            time = time.addingTimeInterval(Guardian.cooldown + 1)
        }
        run.expect(!persistent.canIntervene(now: time),
                   "after being ignored repeatedly, Ace stops offering — that's an answer")
        run.expectEqual(persistent.evaluate(signals: struggling, mood: .unknown, now: time), .none,
                        "and stays quiet even under a strong signal")

        persistent.reset()
        run.expect(persistent.canIntervene(now: time), "a new session starts fresh")

        // --- Coming back ------------------------------------------------------------
        // This one bypasses the cooldown: greeting a return late is worse than
        // not at all.
        var busy = Guardian()
        busy.recordNudge(.suggestBreak, now: now)
        run.expectEqual(busy.evaluate(signals: .none, mood: .unknown, didJustReturn: true,
                                      now: now.addingTimeInterval(2)),
                        .welcomeBack,
                        "a return is always greeted, cooldown or not")

        // --- The copy ------------------------------------------------------------------
        for action: GuardianAction in [.offerHint, .reexplain, .easeOff, .suggestBreak,
                                       .welcomeBack, .checkIn] {
            guard let nudge = Guardian.nudge(for: action, mood: .neutral) else {
                run.expect(false, "\(action) produced no nudge")
                continue
            }
            run.expect(!nudge.message.isEmpty, "\(action) needs a message")
            run.expect(!nudge.acceptTitle.isEmpty, "\(action) needs an accept label")

            // NUDGE, NEVER CAGE. Nothing may be phrased as a requirement.
            let lower = nudge.message.lowercased()
            for coercive in ["you must", "you have to", "you need to stop",
                             "locked", "blocked", "not allowed", "can't continue"] {
                run.expect(!lower.contains(coercive),
                           "coercive language in \(action): “\(nudge.message)”")
            }
            // And nothing may shame.
            for shaming in ["again?", "still not", "you keep", "why haven't", "disappointing"] {
                run.expect(!lower.contains(shaming),
                           "shaming language in \(action): “\(nudge.message)”")
            }
        }
        run.expect(Guardian.nudge(for: .none, mood: .neutral) == nil, ".none produces nothing")

        // A struggling student gets softer wording.
        let gentle = Guardian.nudge(for: .offerHint, mood: .low)
        let plain = Guardian.nudge(for: .offerHint, mood: .neutral)
        run.expect(gentle?.message != plain?.message,
                   "the wording should follow the mood")

        // The welcome back must never comment on where they went or for how
        // long — that's surveillance, not company.
        for away in [10.0, 120.0, 900.0] {
            let welcome = Guardian.nudge(for: .welcomeBack, mood: .neutral,
                                         goalText: "chapter 4", awaySeconds: away)
            let text = (welcome?.message ?? "").lowercased()
            run.expect(text.contains("chapter 4"), "the return should point back at the goal")
            for surveillance in ["minutes away", "you were gone", "you left the",
                                 "you went", "youtube", "distracted", "another app",
                                 "you were away"] {
                run.expect(!text.contains(surveillance),
                           "must not comment on where they went: “\(welcome?.message ?? "")”")
            }
        }

        // --- Declining ---------------------------------------------------------------------
        var declining = Guardian()
        declining.recordDeclined(.suggestBreak)
        run.expect(declining.wasDeclined(.suggestBreak), "a declined offer is remembered")
        run.expect(!declining.wasDeclined(.offerHint), "and doesn't leak to other offers")
    }
}

// MARK: - Comfort

enum ComfortChecks {
    static let all = CheckSuite(name: "Comfort responses") { run in

        // --- Reading the feeling ----------------------------------------------
        let cases: [(String, ComfortResponder.Feeling)] = [
            ("i'm so tired", .tired),
            ("i am exhausted", .tired),
            ("i can't focus at all", .tired),
            ("my brain is fried", .tired),
            ("there's just too much", .overwhelmed),
            ("i'm so behind", .overwhelmed),
            ("i'll never finish this", .overwhelmed),
            ("i'm studying alone", .lonely),
            ("i have nobody to ask", .lonely),
            ("i'm going to fail", .anxious),
            ("i'm so stressed", .anxious),
            ("i'm freaking out", .anxious)
        ]
        for (input, expected) in cases {
            run.expectEqual(ComfortResponder.read(input), expected, "“\(input)”")
        }

        // Ordinary study talk must not trigger comfort.
        for neutral in ["what is photosynthesis", "i don't understand question 7",
                        "can you quiz me", "this chapter is long", "next one"] {
            run.expect(ComfortResponder.read(neutral) == nil,
                       "“\(neutral)” should not read as distress")
        }
        run.expect(ComfortResponder.read("") == nil, "empty")

        // --- Comfort first, bridge second --------------------------------------
        for feeling in [ComfortResponder.Feeling.tired, .overwhelmed, .lonely, .anxious] {
            let response = ComfortResponder.respond(to: feeling, studentName: "Sam")
            run.expect(response.count > 60, "\(feeling) response is too thin")

            let lower = response.lowercased()

            // Never guilt-trip, never pile on (§10).
            for bad in ["you still have", "you've only done", "you should", "you need to finish",
                        "streak", "don't give up now", "push through", "no excuses"] {
                run.expect(!lower.contains(bad),
                           "\(feeling) response must not pressure: found “\(bad)”")
            }

            // The bridge must be an offer, not an instruction.
            run.expect(lower.contains("want") || lower.contains("if you")
                         || lower.contains("we can") || lower.contains("pick one"),
                       "\(feeling) must offer rather than instruct: “\(response)”")
        }

        // Tiredness must give explicit permission to stop.
        let tired = ComfortResponder.respond(to: .tired).lowercased()
        run.expect(tired.contains("stop") || tired.contains("sleep") || tired.contains("go"),
                   "being tired is a real reason to stop, and Ace should say so")

        // Loneliness must point OUTWARD (§10) — this is the one that matters most.
        let lonely = ComfortResponder.respond(to: .lonely).lowercased()
        run.expect(lonely.contains("person") || lonely.contains("someone")
                     || lonely.contains("message"),
                   "the lonely response must point toward real human connection: “\(lonely)”")
        for possessive in ["you have me", "i'm all you need", "you don't need anyone",
                           "i'm your friend", "i'll always be here for you"] {
            run.expect(!lonely.contains(possessive),
                       "must never position itself as a replacement for people: “\(possessive)”")
        }

        // The name is used when we have one, and nothing breaks when we don't.
        run.expect(ComfortResponder.respond(to: .tired, studentName: "Alex").contains("Alex"),
                   "uses the student's name")
        run.expect(!ComfortResponder.respond(to: .tired, studentName: "").contains("  "),
                   "no name must not leave a double space")

        // --- Gamification muting ------------------------------------------------------
        run.expect(ComfortResponder.shouldMuteGamification(for: .tired), "tired mutes the game")
        run.expect(ComfortResponder.shouldMuteGamification(for: .overwhelmed), "overwhelmed mutes")
        run.expect(ComfortResponder.shouldMuteGamification(for: .lonely), "lonely mutes")
        run.expect(!ComfortResponder.shouldMuteGamification(for: .anxious),
                   "anxiety is the one case where a small win genuinely helps")

        // --- Comfort must never shadow the crisis net -------------------------------------
        // Anything the safety service catches is ITS business, not comfort's.
        let service = CrisisSafetyService()
        for phrase in ["i want to kill myself", "i wish i was dead", "i hate myself",
                       "everyone would be better off without me"] {
            run.expect(service.evaluate(phrase).severity >= .concern,
                       "the safety net must still catch “\(phrase)” — comfort never replaces it")
        }
    }
}

// MARK: - Do Not Disturb and music

enum FocusModeChecks {
    static let all = CheckSuite(name: "Do Not Disturb and focus music") { run in

        // --- THE guarantee: DND never removes a capability ------------------
        // §10: "it never blocks the app or the studying".
        for state in [DoNotDisturbState.off, .on,
                      DoNotDisturbState(quietsAceChatter: true, quietsFeedback: true,
                                        calmsInterface: true, requestsSystemFocus: true,
                                        isOn: true)] {
            for (capability, allowed) in state.capabilities {
                run.expect(allowed,
                           "Do Not Disturb must never disable “\(capability)” — nudge, never cage")
            }
            run.expectEqual(state.capabilities.count, 9, "the capability list must stay complete")
            run.expect(state.capabilities["study"] == true, "studying is always available")
            run.expect(state.capabilities["turnDNDOff"] == true,
                       "the student can always turn it off again")
        }

        // --- Message filtering ---------------------------------------------------
        let on = DoNotDisturbState.on
        run.expect(on.allows(.safety),
                   "the crisis net ALWAYS gets through — no mode may silence it (§10)")
        run.expect(on.allows(.directReply),
                   "an answer to something the student asked always gets through")
        run.expect(!on.allows(.ambient), "check-ins are quieted")
        run.expect(!on.allows(.celebration), "XP toasts are quieted")
        run.expect(!on.allows(.nudge), "Guardian nudges are quieted")

        let off = DoNotDisturbState.off
        for importance: MessageImportance in [.safety, .directReply, .ambient, .celebration, .nudge] {
            run.expect(off.allows(importance), "with DND off, everything is allowed")
        }

        // A partially-configured DND still lets safety through.
        var partial = DoNotDisturbState.on
        partial.quietsAceChatter = false
        run.expect(partial.allows(.ambient), "not quieting chatter means chatter is allowed")
        run.expect(partial.allows(.safety), "safety is unconditional")

        run.expect(!DoNotDisturbState.on.explanation.isEmpty, "the toggle explains itself")
        run.expect(DoNotDisturbState.off.explanation.lowercased().contains("never stops"),
                   "the off-state copy must promise it won't block studying")

        // --- Music mixing --------------------------------------------------------------
        var mix = MusicMix(userVolume: 0.5)
        run.expectEqual(mix.effectiveVolume, 0.5, "not ducking = the set volume")

        mix.isDucking = true
        run.expect(mix.effectiveVolume < 0.5, "ducking lowers the music")
        run.expect(mix.effectiveVolume > 0,
                   "but never to silence — music that vanishes and returns is more distracting than one that dips")
        run.expectClose(mix.effectiveVolume, 0.5 * MusicMix.duckFactor, tolerance: 0.001,
                        "duck factor applied")

        // Ducking fast, recovering slowly, is what makes it unnoticeable.
        var ducking = MusicMix(userVolume: 0.4, isDucking: true)
        let duckRamp = ducking.rampDuration
        ducking.isDucking = false
        run.expect(duckRamp < ducking.rampDuration,
                   "ducking must be faster than recovery")

        for volume in [-1.0, 0.0, 0.5, 1.0, 2.0] {
            let clamped = MusicMix(userVolume: volume).effectiveVolume
            run.expect(clamped >= 0 && clamped <= 1, "volume \(volume) must clamp, got \(clamped)")
        }

        // --- The generated score -------------------------------------------------------------
        for scene in FocusScene.allCases {
            run.expect(!scene.displayName.isEmpty, "\(scene) needs a name")
            run.expect(!scene.detail.isEmpty, "\(scene) needs a description")
            run.expect(!scene.symbolName.isEmpty, "\(scene) needs an icon")

            let score = AmbientScore(scene: scene)
            let events = score.events(windowSeconds: 30, seed: 42)

            if scene == .off {
                run.expect(events.isEmpty, "the off scene produces no sound")
                continue
            }

            run.expect(!events.isEmpty, "\(scene) must produce notes")

            // Everything must be inside the window, audible, and in a sane range.
            for event in events {
                run.expect(event.time >= 0 && event.time <= 30,
                           "\(scene): note at \(event.time)s is outside the window")
                run.expect(event.frequency > 40 && event.frequency < 2_000,
                           "\(scene): \(event.frequency)Hz is outside the musical range")
                run.expect(event.gain > 0 && event.gain <= 0.35,
                           "\(scene): gain \(event.gain) — background music must stay background")
                run.expect(event.duration > 0, "\(scene): zero-length note")
                run.expect(event.attack >= 0, "\(scene): negative attack")
            }

            // Sorted, so the renderer can stream them.
            let times = events.map(\.time)
            run.expectEqual(times, times.sorted(), "\(scene): events must be time-ordered")

            // Density: this is background music. More than ~4 notes a second is
            // a composition, not a bed.
            run.expect(Double(events.count) / 30 < 4,
                       "\(scene): \(events.count) notes in 30s is too busy for background")

            // Deterministic given a seed, and different given a different one —
            // that's what makes it never loop.
            let repeated = score.events(windowSeconds: 30, seed: 42)
            run.expectEqual(events, repeated, "\(scene): same seed, same music")
            let different = score.events(windowSeconds: 30, seed: 43)
            run.expect(events != different, "\(scene): a new seed must produce new music")
        }

        // Every generated pitch must be in the scale — there is no wrong note in
        // a pentatonic scale, which is exactly why one was chosen.
        let scaleFrequencies = Set((0..<5).flatMap { degree in
            (0...3).map { AmbientScore.frequency(degree: degree, octave: $0) }
        })
        for scene in [FocusScene.drift, .warmth, .pulse, .rain] {
            for event in AmbientScore(scene: scene).events(windowSeconds: 60, seed: 7) {
                run.expect(scaleFrequencies.contains(where: { abs($0 - event.frequency) < 0.01 }),
                           "\(scene): \(event.frequency)Hz is not in the scale")
            }
        }
    }
}

// MARK: - Speaking drills

enum SpeakingDrillChecks {
    static let all = CheckSuite(name: "Speaking drills") { run in
        let source = SourceTutorChecks.source

        // --- A good explanation ----------------------------------------------
        let good = """
        Photosynthesis is the process plants use to make their own food. \
        It works because chlorophyll captures energy from sunlight inside the \
        chloroplast. That energy is then used to turn carbon dioxide and water \
        into glucose, which the plant stores as food. Oxygen is released as a \
        waste product, which is why plants matter so much to the air.
        """
        let strong = SpeakingDrillScorer.score(transcript: good, sourceText: source, duration: 32)
        run.expect(strong.score.overall >= 60,
                   "a genuinely good explanation should score well, got \(strong.score.overall)")
        run.expect(strong.score.clarity > 0.5, "clarity: it used the real terms")
        run.expect(strong.score.structure > 0.4, "structure: it has because/then/which")
        run.expect(!strong.strength.isEmpty, "must name a strength")
        run.expect(!strong.focus.isEmpty, "must name one thing to work on")

        // --- A poor one -------------------------------------------------------
        let vague = """
        Um so basically it's like the plant sort of does the thing with the sun \
        and stuff and then like maybe it makes food I think? Kind of.
        """
        let weak = SpeakingDrillScorer.score(transcript: vague, sourceText: source, duration: 14)
        run.expect(weak.score.overall < strong.score.overall,
                   "vague must score below precise: \(weak.score.overall) vs \(strong.score.overall)")
        run.expect(weak.score.confidence < 0.7, "hedging should cost confidence")
        run.expect(!weak.missedTerms.isEmpty, "should name terms they never reached for")

        // Even a bad attempt must open with something real, not a criticism.
        run.expect(!weak.strength.isEmpty, "a weak attempt still gets a genuine strength")
        // Whole words, not substrings — "badly" in "saying it badly is how you
        // find the gaps" is encouragement, and a substring check would flag it.
        func containsWord(_ haystack: String, _ word: String) -> Bool {
            let padded = " " + haystack.lowercased()
                .map { $0.isLetter ? $0 : " " }
                .reduce(into: "") { $0.append($1) } + " "
            return padded.contains(" \(word) ")
        }
        for harsh in ["bad", "poor", "wrong", "failed", "weak", "terrible"] {
            run.expect(!containsWord(weak.strength, harsh),
                       "the strength must be a strength: “\(weak.strength)”")
            run.expect(!containsWord(weak.score.band.headline, harsh),
                       "the headline must not be harsh: “\(weak.score.band.headline)”")
        }

        // --- Too short ---------------------------------------------------------
        let stub = SpeakingDrillScorer.score(transcript: "It's photosynthesis.",
                                             sourceText: source, duration: 3)
        run.expectEqual(stub.score.overall, 0, "four words is not an explanation")
        run.expect(stub.isTooShort, "flagged as too short")
        run.expect(stub.focus.lowercased().contains("twenty seconds")
                     || stub.focus.lowercased().contains("keep talking"),
                   "should ask for more, specifically: “\(stub.focus)”")

        run.expectEqual(SpeakingDrillScorer.score(transcript: "", sourceText: source, duration: 0)
                            .score.overall, 0, "empty scores zero, not NaN")

        // --- The focus is the WEAKEST axis, made concrete --------------------------
        // No structure: one long run-on with the right words.
        let noStructure = "chlorophyll chloroplast glucose photosynthesis oxygen stomata plants leaf light energy sugar food"
        let structureFeedback = SpeakingDrillScorer.score(transcript: noStructure,
                                                          sourceText: source, duration: 20)
        run.expect(structureFeedback.score.structure < structureFeedback.score.clarity,
                   "a word-list should score worse on structure than clarity")

        // Every focus line must be actionable — it must tell them what to DO.
        for transcript in [good, vague, noStructure] {
            let feedback = SpeakingDrillScorer.score(transcript: transcript,
                                                     sourceText: source, duration: 25)
            let focus = feedback.focus.lowercased()
            run.expect(focus.contains("try") || focus.contains("go again")
                         || focus.contains("say") || focus.contains("add")
                         || focus.contains("tighten") || focus.contains("build"),
                       "the focus must be an instruction, not an observation: “\(feedback.focus)”")
        }

        // --- Voice features sharpen confidence ---------------------------------------
        let hesitant = VoiceReading(relativeEnergy: 0.9, relativePace: 0.8,
                                    hesitation: 0.7, variability: 0.3, speechSeconds: 20)
        let fluentVoice = VoiceReading(relativeEnergy: 1.0, relativePace: 1.0,
                                       hesitation: 0.05, variability: 0.2, speechSeconds: 20)
        let withHesitation = SpeakingDrillScorer.score(transcript: good, sourceText: source,
                                                       voice: hesitant, duration: 30)
        let withFluency = SpeakingDrillScorer.score(transcript: good, sourceText: source,
                                                    voice: fluentVoice, duration: 30)
        run.expect(withHesitation.score.confidence < withFluency.score.confidence,
                   "audible hesitation should lower confidence")

        // No voice data must not penalise — Demo Mode has to score fairly.
        let noVoice = SpeakingDrillScorer.score(transcript: good, sourceText: source, duration: 30)
        run.expect(noVoice.score.confidence > 0.3,
                   "keyless drills must still score confidence sensibly, got \(noVoice.score.confidence)")

        // --- Score bounds -----------------------------------------------------------------
        for transcript in [good, vague, noStructure, "a b c", ""] {
            let feedback = SpeakingDrillScorer.score(transcript: transcript,
                                                     sourceText: source, duration: 20)
            let score = feedback.score
            for (name, value) in [("clarity", score.clarity), ("structure", score.structure),
                                  ("confidence", score.confidence)] {
                run.expect(value >= 0 && value <= 1, "\(name) out of range: \(value)")
            }
            run.expect(score.overall >= 0 && score.overall <= 100,
                       "overall out of range: \(score.overall)")
            run.expect(!score.band.headline.isEmpty, "every band needs a headline")
        }

        // --- Improvement over time -----------------------------------------------------------
        var history = SpeakingHistory()
        run.expect(history.trend == nil, "no trend from nothing")
        run.expect(history.trendSummary.contains("First time"), "first-time copy")

        for _ in 0..<2 { history.record(SpeakingScore(clarity: 0.3, structure: 0.3, confidence: 0.3)) }
        run.expect(history.trend == nil, "two attempts is not a trend")
        run.expect(history.trendSummary.contains("2 attempt"), "counts attempts honestly")

        for _ in 0..<2 { history.record(SpeakingScore(clarity: 0.8, structure: 0.8, confidence: 0.8)) }
        run.expect((history.trend ?? 0) > 0, "clear improvement should register")
        run.expect(history.trendSummary.lowercased().contains("better"), "and be said out loud")

        var declining = SpeakingHistory()
        for _ in 0..<2 { declining.record(SpeakingScore(clarity: 0.9, structure: 0.9, confidence: 0.9)) }
        for _ in 0..<2 { declining.record(SpeakingScore(clarity: 0.4, structure: 0.4, confidence: 0.4)) }
        run.expect((declining.trend ?? 0) < 0, "a decline should register")
        // ...but must not be delivered as a failure.
        let declineText = declining.trendSummary.lowercased()
        run.expect(declineText.contains("tiredness") || declineText.contains("tomorrow"),
                   "a dip should be explained kindly: “\(declining.trendSummary)”")

        run.expect(history.best != nil, "tracks a best")
        run.expect(history.latest != nil, "tracks the latest")

        // The window is bounded so a long history can't grow forever.
        var long = SpeakingHistory()
        for _ in 0..<100 { long.record(.zero) }
        run.expect(long.attempts <= 40, "history is capped, got \(long.attempts)")
    }
}

// MARK: - The crisis net, through voice

/// §Part 4 checklist: "crisis net now verified across voice too".
///
/// This matters because a speech transcript looks nothing like typed text.
/// Whisper and `SFSpeechRecognizer` produce run-on sentences with no
/// punctuation, no capitalisation to speak of, spelled-out contractions, and
/// verbal filler left in. A safety net tuned on typed input can quietly fail on
/// spoken input, and nobody would notice until it mattered.
enum VoiceSafetyChecks {
    static let all = CheckSuite(name: "Crisis net — spoken transcripts") { run in
        let service = CrisisSafetyService()

        // How a recogniser actually renders a disclosure: no punctuation, filler
        // left in, contractions expanded or not depending on the engine.
        let spokenCrisis = [
            "i want to kill myself",
            "um i i think i want to kill myself",
            "yeah so like i honestly want to die",
            "i dont want to be here anymore",
            "i do not want to be here any more",
            "i guess i just want to die i dont know",
            "erm i've been thinking about suicide a lot",
            "i feel suicidal and i dont know what to do",
            "everyone would be better off without me honestly",
            "i've been cutting myself again",
            "i wish i was dead sorry"
        ]
        for transcript in spokenCrisis {
            run.expectEqual(service.evaluate(transcript).severity, .crisis,
                            "MISSED in speech: “\(transcript)”")
        }

        // Spoken distress that should register as concern.
        for transcript in [
            "i hate myself so much right now",
            "um i feel really hopeless",
            "i am so depressed lately",
            "nobody cares about me at all"
        ] {
            run.expectEqual(service.evaluate(transcript).severity, .concern,
                            "spoken distress missed: “\(transcript)”")
        }

        // Spoken *coursework* must stay silent. A speaking drill about Macbeth
        // or the Somme has to be safe to record.
        let spokenCoursework = [
            "so macbeth kills duncan in act two because of the prophecy",
            "um the black death killed about a third of europe i think",
            "apoptosis is basically programmed cell death",
            "so ophelias death is often read as a suicide by critics",
            "the reaction kills the enzyme by denaturing it",
            "romeo and juliet both die at the end obviously",
            "erm photosynthesis is how plants make their own food",
            "i dont really get why the cells die off during metamorphosis"
        ]
        for transcript in spokenCoursework {
            run.expectEqual(service.evaluate(transcript).severity, .none,
                            "FALSE ALARM on spoken coursework: “\(transcript)”")
        }

        // Transcripts arrive without terminal punctuation and often as one long
        // run-on. Neither may change the verdict.
        let punctuated = service.evaluate("I want to kill myself.")
        let unpunctuated = service.evaluate("i want to kill myself")
        run.expectEqual(punctuated.severity, unpunctuated.severity,
                        "punctuation must not change the verdict")

        let runOn = "so i was reading chapter four and i couldnt focus and honestly "
            + "i want to kill myself and then i tried the questions again"
        run.expectEqual(service.evaluate(runOn).severity, .crisis,
                        "a disclosure buried in a run-on transcript must still be caught")

        // A recogniser that drops apostrophes must not open a hole.
        for variant in ["i dont want to be alive", "i don't want to be alive",
                        "i cant do this anymore", "i can't do this anymore"] {
            run.expectEqual(service.evaluate(variant).severity, .crisis,
                            "apostrophe handling: “\(variant)”")
        }

        // Comfort must not shadow a crisis in speech either — these are worded
        // like tiredness but are disclosures.
        run.expectEqual(service.evaluate("i am so tired of being alive").severity, .crisis,
                        "“tired of being alive” is a disclosure, not tiredness")
        run.expectEqual(ComfortResponder.read("i am tired"), .tired,
                        "plain tiredness still reads as tiredness")

        // The scoring path must be reachable with a crisis transcript without
        // exploding — the drill screen checks safety BEFORE scoring, but the
        // scorer must be robust regardless.
        let scored = SpeakingDrillScorer.score(transcript: "i want to kill myself",
                                               sourceText: SourceTutorChecks.source,
                                               duration: 12)
        run.expect(scored.score.overall >= 0, "scoring a crisis transcript must not crash")

        // --- Ending a session is not the same as meeting the goal ----------------
        //
        // `BodyDoubleView.end()` used to award the goal bonus every time the
        // student pressed End, including thirty seconds in. The value it needed
        // was already sitting in the phase.
        run.expect(!BodyDoublePhase.settingGoal.metGoal, "no goal met before starting")
        run.expect(!BodyDoublePhase.working.metGoal, "no goal met while still working")
        run.expect(!BodyDoublePhase.paused.metGoal, "no goal met while paused")
        run.expect(!BodyDoublePhase.finished(metGoal: false).metGoal,
                   "a session finished short of the goal did not meet it")
        run.expect(BodyDoublePhase.finished(metGoal: true).metGoal,
                   "a session finished at the goal met it")

        do {
            // Quitting one minute into a 25-minute goal.
            var session = BodyDoubleSession()
            _ = session.begin(goal: StudyGoal(target: .duration(minutes: 25),
                                              rawText: "25 minutes"))
            _ = session.finish()
            run.expect(!session.phase.metGoal,
                       "ending a 25-minute goal immediately must not count as met")

            // The counterpart: sit out the whole 25 minutes and it does count.
            var completed = BodyDoubleSession()
            let started = Date()
            _ = completed.begin(goal: StudyGoal(target: .duration(minutes: 25),
                                                rawText: "25 minutes"), now: started)
            _ = completed.finish(now: started.addingTimeInterval(26 * 60))
            run.expect(completed.phase.metGoal, "sitting out the full goal meets it")
        }
    }
}
