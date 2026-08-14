//
//  PersistenceChecks.swift
//  Ace — headless persistence harness
//
//  Runs the SwiftData-bound layer for real, against the in-memory store in
//  `Tools/gen/swiftdata_shim.swift`. Assembled and executed by
//  `Tools/gen/harness_data.py`.
//
//  This covers the logic that the type-check can only prove *compiles*:
//    • does `fetchOrCreate` create exactly once, or once per call
//    • does XP actually land on the record, and is a level-up detected
//    • is gamification genuinely suppressed when the crisis net is engaged
//    • does the demo content install twice on a second launch
//    • does a flashcard's spaced-repetition state survive a round trip
//    • does a quiz remember its best score rather than its last
//    • does the share importer create sources, and skip unsafe ones
//
//  What it deliberately does NOT assert: cascade deletes, relationship inverse
//  maintenance, `@Attribute(.unique)` enforcement. Those are real-framework
//  behaviours the shim doesn't emulate, and asserting on them here would be
//  testing the shim rather than the app.
//

import Foundation

@MainActor
enum PersistenceChecks {

    // MARK: - Stores

    static let stores = CheckSuite(name: "Persistence — stores") { run in
        let context = ModelContext()

        // --- fetchOrCreate creates exactly once ----------------------------
        let profile = ProfileStore.fetchOrCreate(in: context)
        run.expectEqual(context.count(of: Profile.self), 1, "one profile created")

        let again = ProfileStore.fetchOrCreate(in: context)
        run.expect(profile === again, "the SAME profile comes back, not a second one")
        run.expectEqual(context.count(of: Profile.self), 1,
                        "a second call must not create a duplicate profile")

        let progress = ProgressStore.fetchOrCreate(in: context)
        run.expectEqual(context.count(of: ProgressRecord.self), 1, "one progress record")
        run.expect(ProgressStore.fetchOrCreate(in: context) === progress,
                   "progress is a singleton too")

        run.expect(context.saveCount > 0, "creating a record saves")

        // --- Profile round-trips its typed accessors ---------------------------
        profile.name = "Sam Okafor"
        profile.gradeLevel = .grade11
        profile.subjects = [.science, .other("Music Theory")]
        profile.voicePersona = VoiceRoster.persona(id: "atlas")
        profile.supportRegion = .unitedKingdom

        run.expectEqual(profile.gradeLevel, .grade11, "grade level round-trips through its raw value")
        run.expectEqual(profile.subjects.count, 2, "both subjects survive")
        run.expect(profile.subjects.contains(where: { $0.storageKey == "other:Music Theory" }),
                   "a custom subject survives storage")
        run.expectEqual(profile.voicePersona.id, "atlas", "persona round-trips")
        run.expectEqual(profile.supportRegion, .unitedKingdom, "region round-trips")
        run.expectEqual(profile.firstName, "Sam", "first name only")
        run.expectEqual(profile.greetingName, "Sam", "greeting uses the first name")

        // The plain snapshot everything outside persistence works with.
        let settings = profile.settings
        run.expectEqual(settings.gradeLevel, .grade11, "settings carry the grade")
        run.expectEqual(settings.voicePersonaID, "atlas", "settings carry the persona")
        run.expectEqual(settings.supportRegion, .unitedKingdom, "settings carry the region")

        // A profile with no name must not produce a dangling greeting.
        profile.name = ""
        run.expectEqual(profile.greetingName, "there", "no name falls back gracefully")

        // --- Unknown stored values degrade rather than crash ---------------------
        profile.gradeLevelRaw = "not-a-grade"
        run.expectEqual(profile.gradeLevel, .grade9,
                        "an unrecognised stored grade falls back to a default")
        profile.supportRegionRaw = "ZZ"
        run.expectEqual(profile.supportRegion, .unitedStates,
                        "an unrecognised region falls back to the default")
        profile.subjectKeys = ["math", "garbage", "other:"]
        run.expectEqual(profile.subjects.count, 1,
                        "unparseable subject keys are dropped, not crashed on")
    }

    // MARK: - Models

    static let models = CheckSuite(name: "Persistence — models") { run in

        // --- StudySource ---------------------------------------------------
        let long = String(repeating: "photosynthesis ", count: 40)
        let source = StudySource(title: "Chapter 4", kind: .documentScan,
                                 rawText: long, cleanedText: long,
                                 studentNote: "test Friday", subject: .science,
                                 confidence: 0.91)

        run.expectEqual(source.kind, .documentScan, "kind round-trips")
        run.expectEqual(source.subject?.storageKey, "science", "subject round-trips")
        run.expect(source.wordCount > 30, "word count computed, got \(source.wordCount)")
        run.expect(source.preview.count <= 121, "preview is truncated, got \(source.preview.count)")
        run.expect(source.preview.hasSuffix("…"), "and marked as truncated")
        run.expect(!source.isLowConfidence, "0.91 is not low confidence")

        let poor = StudySource(title: "Blurry", kind: .cameraPhoto,
                               rawText: "x", cleanedText: "x", confidence: 0.3)
        run.expect(poor.isLowConfidence, "0.3 is low confidence — the student is warned")
        run.expect(!poor.preview.hasSuffix("…"), "a short preview is not truncated")

        let empty = StudySource(title: "", kind: .pastedText, rawText: "", cleanedText: "")
        run.expectEqual(empty.wordCount, 0, "empty source has no words, and does not crash")
        run.expectEqual(empty.preview, "", "empty preview")

        // --- StoredFlashcard: spaced repetition must survive the model ---------
        let card = StoredFlashcard(front: "What is glucose?", back: "A sugar.")
        run.expect(card.reviewState.isNew, "a fresh card is new")
        run.expect(card.reviewState.isDue, "and due immediately")
        run.expectEqual(card.timesSeen, 0, "never seen")

        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        card.record(.easy, now: reference)
        run.expectEqual(card.timesSeen, 1, "seen once")
        run.expectEqual(card.repetitions, 1, "one repetition")
        run.expect(card.dueDate > reference, "scheduled into the future")
        run.expect(card.easeFactor > 2.5, "easy raises ease")
        run.expectEqual(card.timesForgotten, 0, "not forgotten")

        card.record(.forgot, now: reference)
        run.expectEqual(card.timesForgotten, 1, "a lapse is counted")
        run.expectEqual(card.repetitions, 0, "and resets the ladder")
        run.expect(card.easeFactor >= SpacedRepetition.minEase, "ease has a floor")

        // The flattened columns and the value type must agree in both directions.
        var injected = ReviewState.new
        injected.intervalDays = 12
        injected.easeFactor = 2.1
        injected.repetitions = 4
        injected.dueDate = reference
        card.reviewState = injected
        run.expectEqual(card.intervalDays, 12, "interval written through")
        run.expectEqual(card.easeFactor, 2.1, "ease written through")
        run.expectEqual(card.repetitions, 4, "repetitions written through")
        run.expectEqual(card.reviewState, injected, "and read back identically")

        // Value <-> model conversion.
        let value = Flashcard(front: "F", back: "B", context: "C")
        let stored = StoredFlashcard(value)
        run.expectEqual(stored.id, value.id, "id is preserved so grading can match it back")
        run.expectEqual(stored.asValue.front, "F", "front survives")
        run.expectEqual(stored.asValue.context, "C", "context survives")

        // --- StoredQuiz: questions ride as JSON ------------------------------------
        let quiz = Quiz(title: "Bio", questions: [
            QuizQuestion(prompt: "Q1", choices: ["a", "b", "c"], correctIndex: 2,
                         explanation: "because", hints: ["h1", "h2", "h3"])
        ])
        let storedQuiz = StoredQuiz(quiz)
        run.expectEqual(storedQuiz.id, quiz.id, "id preserved")
        run.expectEqual(storedQuiz.questions.count, 1, "question survives the JSON column")
        run.expectEqual(storedQuiz.questions.first?.correctIndex, 2, "correct index survives")
        run.expectEqual(storedQuiz.questions.first?.hints.count, 3, "hints survive")
        run.expectEqual(storedQuiz.asValue.title, "Bio", "converts back to a value")

        // Best score, not last score — a student who does worse on a retry must
        // not lose their record.
        storedQuiz.recordAttempt(score: 0.8, at: reference)
        run.expectEqual(storedQuiz.attemptCount, 1, "one attempt")
        run.expectEqual(storedQuiz.bestScore, 0.8, "best recorded")
        storedQuiz.recordAttempt(score: 0.4, at: reference)
        run.expectEqual(storedQuiz.attemptCount, 2, "two attempts")
        run.expectEqual(storedQuiz.bestScore, 0.8, "a worse retry must NOT lower the best")
        storedQuiz.recordAttempt(score: 0.95, at: reference)
        run.expectEqual(storedQuiz.bestScore, 0.95, "a better one does raise it")

        // A quiz with a corrupt JSON column must degrade, not crash.
        storedQuiz.questionsData = Data("not json".utf8)
        run.expectEqual(storedQuiz.questions.count, 0,
                        "unreadable question data yields an empty quiz rather than a crash")

        // --- ProgressRecord ------------------------------------------------------------
        let record = ProgressRecord()
        run.expectEqual(record.level, 1, "starts at level 1")
        run.expectEqual(record.accuracy, 0, "no answers means zero accuracy, not NaN")

        let leveled = record.award(.finishedQuiz(score: 1.0))
        run.expect(record.totalXP > 0, "XP landed on the record")
        run.expect(!leveled,
                   "a perfect quiz alone (50 XP) is below level 2 (60) — the curve is "
                   + "generous but not free")

        // A realistic first session does clear it, which is the property that
        // actually matters (§Part 2: the first session should feel rewarding).
        _ = record.award(.capturedSource)
        let nowLeveled = record.award(.dailyFirstSession)
        run.expect(nowLeveled || record.level >= 2,
                   "a first session — capture + daily + a quiz — should reach level 2, "
                   + "got \(record.totalXP) XP at level \(record.level)")

        var previousLevel = record.level
        var sawLevelUp = false
        for _ in 0..<40 {
            if record.award(.answeredCorrectly(streak: 2)) { sawLevelUp = true }
            run.expect(record.level >= previousLevel, "level never goes backwards")
            previousLevel = record.level
        }
        run.expect(sawLevelUp, "sustained XP should level up again")
        run.expectEqual(record.level, LevelCurve.level(forXP: record.totalXP),
                        "the record's level agrees with the curve")

        record.questionsAnswered = 10
        record.questionsCorrect = 7
        run.expectClose(record.accuracy, 0.7, tolerance: 0.001, "accuracy computed")

        // Streak round-trips through its flattened columns.
        var streak = StreakState.fresh
        streak.current = 9
        streak.longest = 14
        streak.repairsAvailable = 2
        streak.lastStudyDay = reference
        record.streak = streak
        run.expectEqual(record.streakCurrent, 9, "current written through")
        run.expectEqual(record.streakLongest, 14, "longest written through")
        run.expectEqual(record.streak, streak, "and reads back identically")

        record.recordStudyDay(now: reference.addingTimeInterval(86_400))
        run.expectEqual(record.streakCurrent, 10, "a study day extends the streak")

        // --- StudySession ------------------------------------------------------------------
        let session = StudySession(sourceID: source.id, sourceTitle: source.title)
        run.expect(session.isActive, "a new session is active")
        run.expectEqual(session.accuracy, 0, "no answers means zero accuracy, not NaN")
        session.questionsAnswered = 8
        session.correctCount = 6
        run.expectClose(session.accuracy, 0.75, tolerance: 0.001, "session accuracy")
        session.endedAt = Date()
        run.expect(!session.isActive, "closed once ended")
        session.endingMood = .energized
        run.expectEqual(session.endingMood, .energized, "mood round-trips")
    }

    // MARK: - SessionRecorder

    static let recorder = CheckSuite(name: "Persistence — session recorder") { run in

        // --- The happy path ------------------------------------------------
        do {
            let context = ModelContext()
            let celebrations = CelebrationCenter()
            let safety = SafetyCoordinator()
            let source = StudySource(title: "Chapter 4", kind: .pastedText,
                                     rawText: "x", cleanedText: "x")
            context.insert(source)

            let recorder = SessionRecorder(context: context, source: source,
                                           celebrations: celebrations, safety: safety)
            run.expectEqual(context.count(of: StudySession.self), 1,
                            "beginning a session creates exactly one session row")

            let progress = ProgressStore.fetchOrCreate(in: context)
            run.expectEqual(progress.streak.current, 1,
                            "starting a session records today as a study day")

            recorder.award(.answeredCorrectly(streak: 1))
            run.expect(recorder.sessionXP > 0, "session XP accumulated")
            run.expect(progress.totalXP > 0, "and landed on the lifetime record")

            recorder.recordAnswer(correct: true)
            recorder.recordAnswer(correct: false)
            run.expectEqual(progress.questionsAnswered, 2, "both answers counted")
            run.expectEqual(progress.questionsCorrect, 1, "only the correct one scored")

            recorder.recordFlashcard()
            recorder.recordHint()

            let before = progress.sessionsCompleted
            recorder.finish(mood: .focused)
            run.expectEqual(progress.sessionsCompleted, before + 1, "session counted on finish")

            // Finishing twice must not double-count.
            recorder.finish(mood: .focused)
            run.expectEqual(progress.sessionsCompleted, before + 1,
                            "finishing an already-closed session is a no-op")
        }

        // --- The session records what the student set out to do -------------------
        //
        // `goalText`, `goalMet` and `safetyEngaged` have been on `StudySession`
        // since the model was written, with doc comments describing behaviour
        // that depended on them, and nothing ever wrote a single one.
        do {
            let context = ModelContext()
            let safety = SafetyCoordinator()
            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: CelebrationCenter(), safety: safety)

            let goal = StudyGoal(target: .duration(minutes: 25), rawText: "25 minutes on chapter 4")
            recorder.finish(mood: .focused, goal: goal, metGoal: true)

            let sessions = (try? context.fetch(FetchDescriptor<StudySession>())) ?? []
            run.expectEqual(sessions.count, 1, "the session is stored")
            run.expectEqual(sessions.first?.goalText, "25 minutes on chapter 4",
                            "the goal is recorded in the student's own words")
            run.expectEqual(sessions.first?.goalMet, true, "a met goal is recorded as met")
            run.expectEqual(sessions.first?.safetyEngaged, false,
                            "a calm session records no safety event")
        }

        // An abandoned session must not record the goal as met.
        do {
            let context = ModelContext()
            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: CelebrationCenter(),
                                           safety: SafetyCoordinator())
            recorder.finish(mood: .low, goal: StudyGoal(target: .duration(minutes: 25),
                                                        rawText: "25 minutes"), metGoal: false)
            let session = (try? context.fetch(FetchDescriptor<StudySession>()))?.first
            run.expectEqual(session?.goalMet, false, "quitting early is not meeting the goal")
            run.expectEqual(session?.goalText, "25 minutes",
                            "the goal is still recorded — what they meant to do matters either way")
        }

        // A session where the crisis net engaged is flagged on the row itself.
        do {
            let context = ModelContext()
            let safety = SafetyCoordinator()
            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: CelebrationCenter(), safety: safety)
            safety.check("i want to kill myself")
            recorder.finish(mood: .low)
            let session = (try? context.fetch(FetchDescriptor<StudySession>()))?.first
            run.expectEqual(session?.safetyEngaged, true,
                            "the row carries the flag its own doc comment depends on")
        }

        // --- The crisis net suppresses everything ---------------------------------
        do {
            let context = ModelContext()
            let celebrations = CelebrationCenter()
            let safety = SafetyCoordinator()

            // Engage the net exactly as a real message would.
            let engaged = safety.check("i want to kill myself")
            run.expect(engaged, "the disclosure engages the safety net")
            run.expect(safety.isGamificationSuppressed, "and suppresses gamification")

            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: celebrations, safety: safety)
            let progress = ProgressStore.fetchOrCreate(in: context)

            run.expectEqual(progress.streak.current, 0,
                            "no streak is recorded while the safety net is engaged")

            recorder.award(.finishedQuiz(score: 1.0))
            run.expectEqual(recorder.sessionXP, 0, "NO XP is awarded during a safety event")
            run.expectEqual(progress.totalXP, 0, "and none lands on the record")
            run.expect(celebrations.currentToast == nil, "no XP toast")
            run.expect(celebrations.pendingLevelUp == nil, "and no level-up celebration")

            recorder.finish(mood: .low)
            run.expectEqual(progress.sessionsCompleted, 0,
                            "the session is not counted toward progress")
        }

        // --- A level-up is celebrated exactly once -----------------------------------
        do {
            let context = ModelContext()
            let celebrations = CelebrationCenter()
            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: celebrations,
                                           safety: SafetyCoordinator())

            // Enough for level 2 in one go.
            recorder.award(.finishedQuiz(score: 1.0))
            recorder.award(.capturedSource)
            recorder.award(.dailyFirstSession)

            let progress = ProgressStore.fetchOrCreate(in: context)
            run.expect(progress.level >= 2, "levelled up, at level \(progress.level)")
            run.expect(celebrations.pendingLevelUp != nil, "the level-up was celebrated")
            run.expectEqual(celebrations.pendingLevelUp?.level, progress.level,
                            "and celebrates the level actually reached")
        }

        // --- markSafetyEngaged silences a celebration already on screen ----------------
        do {
            let context = ModelContext()
            let celebrations = CelebrationCenter()
            let recorder = SessionRecorder(context: context, source: nil,
                                           celebrations: celebrations,
                                           safety: SafetyCoordinator())
            recorder.award(.finishedQuiz(score: 1.0))
            run.expect(celebrations.pendingLevelUp != nil || celebrations.currentToast != nil,
                       "something is celebrating")

            recorder.markSafetyEngaged()
            run.expect(celebrations.currentToast == nil,
                       "engaging the net clears the toast mid-flight")
            run.expect(celebrations.pendingLevelUp == nil,
                       "and the level-up — a celebration in that moment would be unforgivable")
        }
    }

    // MARK: - Demo content

    static let demoContent = CheckSuite(name: "Persistence — demo content") { run in
        let key = "ace.demoContentInstalled"
        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(false, forKey: key)

        let context = ModelContext()
        DemoContent.installIfNeeded(in: context)
        let installed = context.count(of: StudySource.self)

        // Note: the decks are read from the app bundle, which a CLI harness
        // doesn't have — so the count may legitimately be zero here. What is
        // being tested is the *idempotence*, which is the part that can bite.
        DemoContent.installIfNeeded(in: context)
        run.expectEqual(context.count(of: StudySource.self), installed,
                        "installing twice must not duplicate the demo decks")

        run.expect(UserDefaults.standard.bool(forKey: key),
                   "the install flag is set, so a second launch skips it")

        // The decks themselves are verified in `DemoDeckChecks`, which builds
        // them from the generator rather than the bundle.
        run.expect(DemoContent.bundledDeckNames.count == 2, "two decks are declared")
    }

    // MARK: - Share import

    static let shareImport = CheckSuite(name: "Persistence — share import") { run in
        // `ShareImporter.drain` is async and reads the App Group container,
        // which doesn't exist here — so this covers the parts that don't.
        let result = ShareImporter.Result()
        run.expect(!result.didImportAnything, "an empty result imported nothing")
        run.expect(result.message == nil, "and says nothing")

        var one = ShareImporter.Result()
        one.imported = [UUID()]
        run.expect(one.didImportAnything, "one import counts")
        run.expect(one.message?.contains("ready") == true, "and announces itself: \(one.message ?? "")")

        var many = ShareImporter.Result()
        many.imported = [UUID(), UUID(), UUID()]
        run.expect(many.message?.contains("3") == true, "plural message names the count")

        var failed = ShareImporter.Result()
        failed.failed = 2
        run.expect(failed.message != nil, "failures are surfaced")
        run.expect(failed.message?.lowercased().contains("try the text") == true,
                   "and suggest a way forward")

        // Something caught by the safety net is neither an import nor a failure.
        var skipped = ShareImporter.Result()
        skipped.skippedForSafety = 1
        run.expect(skipped.message == nil,
                   "content held back by the safety net must not be announced as an error")
    }
}
