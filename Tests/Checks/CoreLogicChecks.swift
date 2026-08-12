//
//  CoreLogicChecks.swift
//  Ace — verification harness
//
//  Covers the OCR text cleaner, the on-device study-material generator, the XP
//  and streak engines, and the voice/prosody matcher.
//

import Foundation

// MARK: - Text cleaning

enum TextCleanerChecks {
    static let all = CheckSuite(name: "OCR text cleaner") { run in

        // Hard-wrapped paragraph with a hyphen split across lines — the single
        // most common OCR artefact on a textbook page.
        let wrapped = [
            "Photosynthesis is the process by which green plants",
            "and some other organisms use sunlight to synthes-",
            "ise foods from carbon dioxide and water."
        ]
        let joined = SourceTextCleaner.joinWrappedLines(wrapped)
        run.expect(joined.contains("synthesise"),
                   "hyphenated word must be healed, got: \(joined)")
        run.expect(!joined.contains("synthes-"), "leftover hyphen")
        run.expect(!joined.contains("\n"), "wrapped lines must join into one")

        // A real hyphenated compound followed by a capital must survive.
        let compound = SourceTextCleaner.joinWrappedLines(["well-", "Known scientists"])
        run.expect(compound.contains("well-Known"),
                   "capitalised continuation should keep the hyphen, got: \(compound)")

        // Page furniture.
        run.expect(SourceTextCleaner.isPageFurniture("87"), "bare page number")
        run.expect(SourceTextCleaner.isPageFurniture("- 87 -"), "decorated page number")
        run.expect(SourceTextCleaner.isPageFurniture("Page 12"), "'Page 12'")
        run.expect(SourceTextCleaner.isPageFurniture("   "), "whitespace")
        run.expect(SourceTextCleaner.isPageFurniture("|||"), "no letters")
        run.expect(!SourceTextCleaner.isPageFurniture("Mitosis"),
                   "a short heading is NOT furniture")
        run.expect(!SourceTextCleaner.isPageFurniture("The cell divides into two."),
                   "prose is not furniture")

        // Headings.
        run.expect(SourceTextCleaner.isHeading("CHAPTER FOUR"), "all caps heading")
        run.expect(SourceTextCleaner.isHeading("Chapter 4"), "chapter heading")
        run.expect(SourceTextCleaner.isHeading("The Light Reactions"), "title case heading")
        run.expect(!SourceTextCleaner.isHeading("The plant absorbs light energy."),
                   "a full sentence is not a heading")

        // List items.
        run.expectEqual(SourceTextCleaner.listItemBody("• Chlorophyll absorbs light"),
                        "Chlorophyll absorbs light", "bullet")
        run.expectEqual(SourceTextCleaner.listItemBody("1. First step"), "First step", "numbered")
        run.expectEqual(SourceTextCleaner.listItemBody("2) Second step"), "Second step", "paren numbered")
        run.expect(SourceTextCleaner.listItemBody("Not a list item") == nil, "plain line")

        // Smart quotes and dashes normalised.
        let smart = SourceTextCleaner.normalizeWhitespace("\u{201C}Hello\u{201D} \u{2014} she said")
        run.expect(smart.contains("\"Hello\""), "curly quotes normalised, got: \(smart)")
        run.expect(!smart.contains("\u{2014}"), "em dash normalised")

        // Whitespace collapse.
        run.expectEqual(SourceTextCleaner.normalizeWhitespace("  too    many   spaces  "),
                        "too many spaces", "collapse runs")

        // Full pipeline on a realistic scanned page.
        let page = [
            "CHAPTER 4",
            "Photosynthesis",
            "87",
            "Photosynthesis is the process by which plants convert",
            "light energy into chemical energy.",
            "The reaction takes place in the chloroplast.",
            "• Chlorophyll absorbs light",
            "• Water is split into oxygen",
            "Page 87"
        ]
        let blocks = SourceTextCleaner.blocks(from: page)
        run.expect(!blocks.contains { $0.text == "87" }, "page number survived cleaning")
        run.expect(!blocks.contains { $0.text == "Page 87" }, "footer survived cleaning")
        run.expect(blocks.contains { $0.kind == .heading && $0.text == "CHAPTER 4" },
                   "chapter heading missing")
        run.expect(blocks.contains { $0.kind == .listItem && $0.text == "Chlorophyll absorbs light" },
                   "list item missing")
        run.expect(blocks.contains { $0.kind == .paragraph && $0.text.contains("chemical energy") },
                   "paragraph missing or not joined")

        // --- Phrase splitting (drives both TTS rhythm and the reply stream) ---
        let spoken = PhraseSplitter.phrases(in: "Okay. What do you think it means? Take your time.")
        run.expectEqual(spoken.count, 3, "should split on sentence ends, got \(spoken)")
        run.expect(spoken.contains { $0.hasSuffix("?") }, "question mark preserved")

        // Short lists must not be machine-gunned into fragments.
        let shortList = PhraseSplitter.phrases(in: "Red, green, blue.")
        run.expectEqual(shortList.count, 1, "a short list stays one phrase, got \(shortList)")

        // A long clause does earn a pause.
        let longClause = PhraseSplitter.phrases(in: "The plant absorbs light through its leaves, and then it converts that light into sugar.")
        run.expect(longClause.count >= 2, "a long clause should break, got \(longClause)")

        // A long unpunctuated run must still be chunked.
        let runOn = PhraseSplitter.phrases(in: Array(repeating: "word", count: 60).joined(separator: " "))
        run.expect(runOn.count >= 3, "a 60-word run must be chunked, got \(runOn.count) phrases")
        run.expect(runOn.allSatisfy { $0.split(separator: " ").count <= 26 },
                   "no chunk may exceed the phrase ceiling")

        run.expectEqual(PhraseSplitter.phrases(in: "").count, 0, "empty text yields no phrases")
        run.expectEqual(PhraseSplitter.phrases(in: "   ").count, 0, "whitespace yields no phrases")
        // Nothing may be lost in the split.
        let source = "First sentence. Second one! Third?"
        let rejoined = PhraseSplitter.phrases(in: source).joined(separator: " ")
        run.expectEqual(rejoined, source, "splitting must be lossless")

        // Empty input must not crash or produce junk.
        run.expectEqual(SourceTextCleaner.blocks(from: []).count, 0, "empty input")
        run.expectEqual(SourceTextCleaner.blocks(from: ["", "  ", "9"]).count, 0, "junk only")
        run.expectEqual(SourceTextCleaner.clean(text: ""), "", "empty text")
    }
}

// MARK: - Study material generation

enum StudyGeneratorChecks {

    /// A realistic 5th-grade science passage — the kind of thing that comes off
    /// a worksheet photo.
    static let sciencePassage = """
    Photosynthesis is the process by which plants make their own food using \
    light. Chlorophyll is the green pigment that absorbs light energy inside \
    the leaf. The chloroplast is the organelle where photosynthesis takes \
    place. Plants take in carbon dioxide through tiny openings called stomata. \
    Glucose is the sugar that plants make and store as food. Oxygen is released \
    as a waste product of photosynthesis. Respiration is the process cells use \
    to release energy from glucose.
    """

    static let all = CheckSuite(name: "Study material generator") { run in

        // --- Sentence splitting -------------------------------------------
        let sentences = TextAnalysis.sentences(in: sciencePassage)
        run.expect(sentences.count >= 6, "expected 6+ sentences, got \(sentences.count)")

        let withAbbrev = TextAnalysis.sentences(in: "Plants need light, e.g. from the sun. They also need water to survive.")
        run.expectEqual(withAbbrev.count, 2, "'e.g.' must not split a sentence")
        run.expect(withAbbrev.first?.contains("e.g.") == true, "'e.g.' must be restored intact")

        // --- Definition extraction ----------------------------------------
        let def = TextAnalysis.definitions(in: "Chlorophyll is the green pigment that absorbs light energy.")
        run.expectEqual(def?.term, "Chlorophyll", "definition subject")
        run.expect(def?.definition.contains("green pigment") == true, "definition body")

        // A long-subject sentence is not a definition.
        run.expect(TextAnalysis.definitions(in: "One of the main reasons the reaction stops is a lack of water.") == nil,
                   "long subject must not be treated as a definition")
        // A pure-stopword subject is not a definition.
        run.expect(TextAnalysis.definitions(in: "This is a good example of the process.") == nil,
                   "stopword-only subject rejected")

        // --- Key terms ------------------------------------------------------
        let terms = TextAnalysis.keyTerms(in: sciencePassage)
        run.expect(terms.count >= 5, "expected 5+ key terms, got \(terms.count)")
        let termNames = Set(terms.map { $0.term.lowercased() })
        for expected in ["photosynthesis", "chlorophyll", "chloroplast", "glucose"] {
            run.expect(termNames.contains(expected), "missing key term “\(expected)”")
        }
        // Stopwords must never become terms.
        for banned in ["the", "is", "and", "that"] {
            run.expect(!termNames.contains(banned), "stopword “\(banned)” leaked into key terms")
        }

        // --- Flashcards -----------------------------------------------------
        let generator = StudyMaterialGenerator(gradeLevel: .grade5)
        let cards = generator.flashcards(from: sciencePassage, title: "Photosynthesis")
        run.expect(cards.count >= 4, "expected 4+ flashcards, got \(cards.count)")
        for card in cards {
            run.expect(!card.front.isEmpty, "empty card front")
            run.expect(!card.back.isEmpty, "empty card back")
            run.expect(card.front != card.back, "front and back identical: \(card.front)")
        }
        // Definition cards should read as questions.
        run.expect(cards.contains { $0.front.hasPrefix("What is") },
                   "expected at least one 'What is X?' card")
        // Cloze cards must actually contain a blank and must not leak the answer.
        for card in cards where card.front.contains("________") {
            run.expect(!card.front.lowercased().contains(card.back.lowercased()),
                       "cloze card leaks its answer: \(card.front)")
        }

        // --- Quiz -----------------------------------------------------------
        let quiz = generator.quiz(from: sciencePassage, title: "Photosynthesis", questionCount: 6)
        run.expect(quiz.questions.count >= 3,
                   "expected 3+ questions, got \(quiz.questions.count)")

        for question in quiz.questions {
            run.expect(!question.prompt.isEmpty, "empty prompt")
            run.expectEqual(question.choices.count, GradeLevel.grade5.quizChoiceCount,
                            "choice count for 5th grade")
            run.expect(question.choices.indices.contains(question.correctIndex),
                       "correctIndex \(question.correctIndex) out of range")
            run.expectEqual(Set(question.choices).count, question.choices.count,
                            "duplicate choices in: \(question.choices)")
            run.expect(!question.explanation.isEmpty, "every question must teach something")
            run.expectEqual(question.hints.count, 3, "expected 3 escalating hints")

            // The Socratic rule: the first two hints must never contain the
            // answer outright.
            let answer = question.correctAnswer.lowercased()
            run.expect(!question.hints[0].lowercased().contains(answer),
                       "hint 1 gives away “\(answer)”: \(question.hints[0])")
            run.expect(!question.hints[1].lowercased().contains(answer),
                       "hint 2 gives away “\(answer)”: \(question.hints[1])")

            // Cloze prompts must not contain the answer either.
            if question.prompt.contains("________") {
                run.expect(!question.prompt.lowercased().contains(answer),
                           "prompt leaks the answer: \(question.prompt)")
            }
        }

        // --- Determinism ----------------------------------------------------
        // Same input must give the same deck, or a student re-opening a quiz
        // sees the answers move around.
        let again = generator.quiz(from: sciencePassage, title: "Photosynthesis", questionCount: 6)
        run.expectEqual(again.questions.map(\.prompt), quiz.questions.map(\.prompt),
                        "quiz generation must be deterministic (prompts)")
        run.expectEqual(again.questions.map(\.choices), quiz.questions.map(\.choices),
                        "quiz generation must be deterministic (choice order)")

        // The correct answer must not always be in the same slot.
        let collegeGen = StudyMaterialGenerator(gradeLevel: .college)
        let bigQuiz = collegeGen.quiz(from: sciencePassage + " " + sciencePassage,
                                      title: "Bio", questionCount: 8)
        if bigQuiz.questions.count >= 4 {
            let positions = Set(bigQuiz.questions.map(\.correctIndex))
            run.expect(positions.count >= 2,
                       "correct answer is always at index \(positions) — choices aren't shuffling")
        }

        // College level gets 4 choices.
        if let first = bigQuiz.questions.first {
            run.expectEqual(first.choices.count, 4, "college choice count")
        }

        // --- Degenerate input ------------------------------------------------
        let emptyQuiz = generator.quiz(from: "", title: "Nothing")
        run.expect(emptyQuiz.isEmpty, "empty source must give an empty quiz, not a crash")
        run.expectEqual(generator.flashcards(from: "", title: "Nothing").count, 0, "empty flashcards")
        let tinyQuiz = generator.quiz(from: "Hi.", title: "Tiny")
        run.expect(tinyQuiz.isEmpty, "one fragment must not produce questions")

        // --- Blanking ---------------------------------------------------------
        let blanked = generator.blank("Chlorophyll", in: "Chlorophyll absorbs light energy in the leaf.")
        run.expect(blanked?.contains("________") == true, "blank inserted")
        run.expect(blanked?.contains("Chlorophyll") == false, "term removed")
        run.expect(generator.blank("Missing", in: "Short one.") == nil,
                   "too-short sentence must be rejected")

        // --- Seeded RNG is actually deterministic ------------------------------
        var g1 = SeededGenerator(seed: 42)
        var g2 = SeededGenerator(seed: 42)
        run.expectEqual(g1.next(), g2.next(), "same seed, same sequence")
        var g3 = SeededGenerator(seed: 43)
        var g4 = SeededGenerator(seed: 42)
        run.expect(g4.next() != g3.next(), "different seeds differ")
        run.expectEqual("abc".stableSeed, "abc".stableSeed, "stable seed is stable")
        run.expect("abc".stableSeed != "abd".stableSeed, "stable seed distinguishes strings")
    }
}

// MARK: - Progression

enum ProgressionChecks {
    static let all = CheckSuite(name: "XP, levels and streaks") { run in

        // --- Level curve ------------------------------------------------------
        run.expectEqual(LevelCurve.level(forXP: 0), 1, "zero XP is level 1")
        run.expect(LevelCurve.totalXP(forLevel: 1) == 0, "level 1 costs nothing")
        run.expect(LevelCurve.totalXP(forLevel: 2) < LevelCurve.totalXP(forLevel: 3),
                   "curve must be monotonic")

        // Monotonic and consistent across the whole curve.
        var previous = -1
        for level in 1...LevelCurve.maxLevel {
            let cost = LevelCurve.totalXP(forLevel: level)
            run.expect(cost > previous, "level \(level) cost \(cost) not greater than \(previous)")
            previous = cost
            run.expectEqual(LevelCurve.level(forXP: cost), level,
                            "XP \(cost) should be exactly level \(level)")
        }

        // Progress is bounded and sensible.
        for xp in [0, 1, 59, 60, 61, 500, 5_000, 100_000] {
            let p = LevelCurve.progress(forXP: xp)
            run.expect(p >= 0 && p <= 1, "progress out of range at \(xp) XP: \(p)")
        }
        run.expectEqual(LevelCurve.progress(forXP: LevelCurve.totalXP(forLevel: 5)), 0,
                        "landing exactly on a level starts that level at 0%")
        run.expect(LevelCurve.xpRemaining(forXP: 0) > 0, "level 1 has XP remaining")
        run.expectEqual(LevelCurve.xpRemaining(forXP: LevelCurve.totalXP(forLevel: LevelCurve.maxLevel)), 0,
                        "max level has nothing remaining")
        run.expectEqual(LevelCurve.level(forXP: 999_999_999), LevelCurve.maxLevel,
                        "level is capped")

        // The first session should feel generous: capturing a source plus a
        // finished quiz should clear level 2.
        let firstSessionXP = XPEvent.capturedSource.amount
            + XPEvent.dailyFirstSession.amount
            + XPEvent.finishedQuiz(score: 0.8).amount
        run.expect(LevelCurve.level(forXP: firstSessionXP) >= 2,
                   "first session (\(firstSessionXP) XP) should reach level 2+")

        // --- XP values ---------------------------------------------------------
        run.expect(XPEvent.attemptedAnswer.amount > 0,
                   "effort must pay — a wrong attempt still earns XP")
        run.expect(XPEvent.answeredCorrectly(streak: 0).amount > XPEvent.attemptedAnswer.amount,
                   "correct should beat incorrect")
        run.expect(XPEvent.answeredCorrectly(streak: 20).amount
                     <= XPEvent.answeredCorrectly(streak: 5).amount,
                   "streak bonus must cap so streaks don't dominate the economy")
        run.expect(XPEvent.reviewedFlashcard(.forgot).amount > 0,
                   "forgetting a card still counts as showing up")
        run.expect(XPEvent.finishedQuiz(score: 1.0).amount > XPEvent.finishedQuiz(score: 0.0).amount,
                   "better scores pay more")
        for event: XPEvent in [.capturedSource, .attemptedAnswer, .metGoal, .dailyFirstSession,
                               .finishedSession(minutes: 25), .explainedOutLoud(clarity: 0.5)] {
            run.expect(event.amount > 0, "\(event) must award XP")
            run.expect(!event.caption.isEmpty, "\(event) needs a caption")
        }
        run.expectEqual(XPEvent.finishedSession(minutes: 600).amount,
                        XPEvent.finishedSession(minutes: 60).amount,
                        "session XP caps — no reward for leaving the app open all night")

        // --- Streaks -----------------------------------------------------------
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)   // fixed reference
        func day(_ n: Int) -> Date { day0.addingTimeInterval(Double(n) * 86_400) }

        // First session.
        var streak = StreakEngine.record(.fresh, now: day(0), calendar: calendar)
        run.expectEqual(streak.current, 1, "first session starts the streak")
        run.expectEqual(streak.longest, 1, "longest tracks current")

        // Same day twice must not double count.
        streak = StreakEngine.record(streak, now: day(0).addingTimeInterval(3600), calendar: calendar)
        run.expectEqual(streak.current, 1, "two sessions in one day count once")

        // Consecutive days.
        streak = StreakEngine.record(streak, now: day(1), calendar: calendar)
        streak = StreakEngine.record(streak, now: day(2), calendar: calendar)
        run.expectEqual(streak.current, 3, "three consecutive days")

        // Missing one day spends a repair rather than resetting.
        let repairsBefore = streak.repairsAvailable
        streak = StreakEngine.record(streak, now: day(4), calendar: calendar)  // skipped day 3
        run.expectEqual(streak.current, 4, "one free repair keeps the streak alive")
        run.expectEqual(streak.repairsAvailable, repairsBefore - 1, "repair was spent")

        // Missing another day with no repairs left resets — but records longest.
        var noRepairs = streak
        noRepairs.repairsAvailable = 0
        let longestBefore = noRepairs.longest
        noRepairs = StreakEngine.record(noRepairs, now: day(8), calendar: calendar)
        run.expectEqual(noRepairs.current, 1, "streak resets without a repair")
        run.expectEqual(noRepairs.longest, longestBefore, "longest is remembered")

        // Repairs are earned back through consistency, capped at 2.
        var consistent = StreakState.fresh
        for d in 0..<21 {
            consistent = StreakEngine.record(consistent, now: day(d), calendar: calendar)
        }
        run.expectEqual(consistent.current, 21, "21 consecutive days")
        run.expect(consistent.repairsAvailable <= 2, "repairs are capped at 2")
        run.expect(consistent.repairsAvailable >= 1, "consistency earns repairs back")

        // Clock going backwards (timezone travel) must not destroy a streak.
        var traveller = StreakEngine.record(.fresh, now: day(5), calendar: calendar)
        traveller = StreakEngine.record(traveller, now: day(4), calendar: calendar)
        run.expectEqual(traveller.current, 1, "backwards clock leaves the streak alone")

        // --- Status ------------------------------------------------------------
        run.expectEqual(StreakEngine.status(.fresh, now: day(0), calendar: calendar), .none, "no history")
        var todayState = StreakEngine.record(.fresh, now: day(10), calendar: calendar)
        run.expectEqual(StreakEngine.status(todayState, now: day(10), calendar: calendar),
                        .safeToday(1), "studied today")
        run.expectEqual(StreakEngine.status(todayState, now: day(11), calendar: calendar),
                        .atRisk(1), "studied yesterday")
        run.expectEqual(StreakEngine.status(todayState, now: day(12), calendar: calendar),
                        .repairable(1), "missed one day, repair available")
        todayState.repairsAvailable = 0
        run.expectEqual(StreakEngine.status(todayState, now: day(12), calendar: calendar),
                        .broken(previous: 1), "missed one day, no repair")

        // Every nudge must be non-empty and free of guilt language.
        let statuses: [StreakStatus] = [.none, .safeToday(5), .atRisk(5), .repairable(5), .broken(previous: 5)]
        for status in statuses {
            run.expect(!status.nudge.isEmpty, "\(status) has no nudge copy")
            let lower = status.nudge.lowercased()
            for guilt in ["don't lose", "you'll lose", "hurry", "last chance", "failed", "disappointed"] {
                run.expect(!lower.contains(guilt),
                           "guilt language in streak copy “\(status.nudge)”: \(guilt)")
            }
        }

        // --- Spaced repetition ---------------------------------------------------
        let now = day(100)
        let fresh = ReviewState.new
        run.expect(fresh.isNew, "a new card reads as new")
        run.expect(fresh.isDue, "a new card is due immediately")

        let easy1 = SpacedRepetition.advance(fresh, grade: .easy, now: now)
        run.expectEqual(easy1.repetitions, 1, "first easy recall")
        run.expectEqual(easy1.intervalDays, 1, "first easy interval is 1 day")
        run.expect(easy1.easeFactor > fresh.easeFactor, "easy raises ease")

        let easy2 = SpacedRepetition.advance(easy1, grade: .easy, now: now)
        run.expectEqual(easy2.intervalDays, 3, "second easy interval is 3 days")
        let easy3 = SpacedRepetition.advance(easy2, grade: .easy, now: now)
        run.expect(easy3.intervalDays > easy2.intervalDays, "intervals keep growing")

        let forgot = SpacedRepetition.advance(easy3, grade: .forgot, now: now)
        run.expectEqual(forgot.repetitions, 0, "forgetting resets the ladder")
        run.expectEqual(forgot.intervalDays, 0, "forgotten cards come back this session")
        run.expect(forgot.easeFactor >= SpacedRepetition.minEase, "ease has a floor")

        // Ease can't be driven below the floor no matter how bad the run is.
        var punished = ReviewState.new
        for _ in 0..<50 { punished = SpacedRepetition.advance(punished, grade: .forgot, now: now) }
        run.expect(punished.easeFactor >= SpacedRepetition.minEase, "ease floor holds under repetition")

        // Interval can't run away either.
        var rewarded = ReviewState.new
        for _ in 0..<50 { rewarded = SpacedRepetition.advance(rewarded, grade: .easy, now: now) }
        run.expect(rewarded.intervalDays <= SpacedRepetition.maxIntervalDays,
                   "interval is capped at \(SpacedRepetition.maxIntervalDays) days")
        run.expect(rewarded.easeFactor <= SpacedRepetition.maxEase, "ease ceiling holds")

        // Ordering: overdue first, then new, then future.
        struct Card { let name: String; let state: ReviewState }
        func state(due: Date, reps: Int, reviewed: Date?) -> ReviewState {
            var s = ReviewState.new
            s.dueDate = due
            s.repetitions = reps
            s.lastReviewed = reviewed
            return s
        }
        let deck = [
            Card(name: "future", state: state(due: now.addingTimeInterval(86_400 * 5), reps: 3, reviewed: now)),
            Card(name: "new", state: .new),
            Card(name: "overdue", state: state(due: now.addingTimeInterval(-86_400 * 3), reps: 2, reviewed: now)),
            Card(name: "slightly-overdue", state: state(due: now.addingTimeInterval(-3600), reps: 1, reviewed: now)),
        ]
        let ordered = SpacedRepetition.ordered(deck, state: \.state, now: now).map(\.name)
        run.expectEqual(ordered.first, "overdue", "most overdue card leads, got \(ordered)")
        run.expectEqual(ordered.last, "future", "not-yet-due card trails, got \(ordered)")
        run.expect(ordered.firstIndex(of: "slightly-overdue")! < ordered.firstIndex(of: "new")!,
                   "overdue beats brand new, got \(ordered)")
    }
}

// MARK: - Voice

enum VoiceChecks {
    static let all = CheckSuite(name: "Voice roster and prosody matching") { run in

        // --- Roster integrity --------------------------------------------------
        run.expect(VoiceRoster.all.count >= 5, "need a real roster, got \(VoiceRoster.all.count)")

        let ids = VoiceRoster.all.map(\.id)
        run.expectEqual(Set(ids).count, ids.count, "duplicate persona ids")

        run.expect(!VoiceRoster.personas(presenting: .masculine).isEmpty,
                   "roster must include male voices")
        run.expect(!VoiceRoster.personas(presenting: .feminine).isEmpty,
                   "roster must include female voices")

        for persona in VoiceRoster.all {
            run.expect(!persona.displayName.isEmpty, "\(persona.id): no name")
            run.expect(!persona.blurb.isEmpty, "\(persona.id): every voice needs a personality blurb")
            run.expect(!persona.previewLine.isEmpty, "\(persona.id): no preview line")
            run.expect(!persona.systemVoiceCandidates.isEmpty,
                       "\(persona.id): needs at least one system voice candidate")
            run.expect(!persona.realtimeVoiceName.isEmpty, "\(persona.id): no realtime voice")
            let clamped = persona.baseProsody.clamped
            run.expectEqual(clamped, persona.baseProsody,
                            "\(persona.id): base prosody is outside the safe range")
        }

        // Unknown id falls back rather than crashing.
        run.expectEqual(VoiceRoster.persona(id: "does-not-exist").id, VoiceRoster.default.id,
                        "unknown persona id falls back to the default")
        run.expectEqual(VoiceRoster.persona(id: nil).id, VoiceRoster.default.id, "nil id falls back")
        run.expectEqual(VoiceRoster.persona(id: "atlas").id, "atlas", "known id resolves")

        // --- Clamping ------------------------------------------------------------
        let wild = Prosody(rate: 99, pitch: -5, volume: 40, preDelay: 100).clamped
        run.expect(wild.rate <= 0.75 && wild.rate >= 0.2, "rate clamped, got \(wild.rate)")
        run.expect(wild.pitch >= 0.6 && wild.pitch <= 1.8, "pitch clamped, got \(wild.pitch)")
        run.expect(wild.volume <= 1.0 && wild.volume > 0, "volume clamped, got \(wild.volume)")
        run.expect(wild.preDelay <= 0.6, "pre-delay clamped, got \(wild.preDelay)")

        // --- Mood matching --------------------------------------------------------
        let base = Prosody(rate: 0.5, pitch: 1.0, volume: 1.0)

        let confused = ProsodyMatcher.target(for: .confused, base: base)
        run.expect(confused.rate < base.rate, "confusion must slow Ace down")
        run.expect(confused.preDelay > base.preDelay, "confusion must add a beat of space")

        let energized = ProsodyMatcher.target(for: .energized, base: base)
        run.expect(energized.rate > base.rate, "energy must be matched, not flattened")

        let low = ProsodyMatcher.target(for: .low, base: base)
        run.expect(low.rate < base.rate, "low mood must slow down")
        run.expect(low.volume < base.volume, "low mood must soften")
        run.expect(low.pitch < base.pitch, "low mood must not sound chirpy")

        let frustrated = ProsodyMatcher.target(for: .frustrated, base: base)
        run.expect(frustrated.rate < base.rate, "frustration must slow down")
        run.expect(frustrated.pitch < base.pitch,
                   "never sound cheerful at a frustrated student — it reads as mocking")

        run.expectEqual(ProsodyMatcher.target(for: .neutral, base: base), base,
                        "neutral is the baseline")
        run.expectEqual(ProsodyMatcher.target(for: .focused, base: base), base,
                        "focused means stay out of the way")

        // --- Easing ---------------------------------------------------------------
        // A low-confidence reading should barely move delivery.
        let weak = MoodReading(mood: .energized, confidence: 0.1)
        run.expect(!weak.isActionable, "a 0.1-confidence read must not be actionable")
        let afterWeak = ProsodyMatcher.next(current: base, base: base, reading: weak)
        run.expect(abs(afterWeak.rate - base.rate) < 0.02,
                   "a weak read must not change delivery, moved to \(afterWeak.rate)")

        // A confident reading moves toward the target but never overshoots it.
        let strong = MoodReading(mood: .confused, confidence: 0.95)
        let afterStrong = ProsodyMatcher.next(current: base, base: base, reading: strong)
        let goal = ProsodyMatcher.target(for: .confused, base: base)
        run.expect(afterStrong.rate < base.rate, "confident read must move delivery")
        run.expect(afterStrong.rate >= goal.rate - 0.001,
                   "must not overshoot the target: \(afterStrong.rate) vs goal \(goal.rate)")

        // Repeated application converges and always stays in the safe range.
        var current = base
        for _ in 0..<40 {
            current = ProsodyMatcher.next(current: current, base: base, reading: strong)
            run.expectEqual(current, current.clamped, "prosody left the safe range during easing")
        }
        run.expect(abs(current.rate - goal.rate) < 0.05,
                   "should converge on the goal, ended at \(current.rate) vs \(goal.rate)")

        // With no signal, delivery drifts back to the persona baseline.
        var drifting = ProsodyMatcher.target(for: .energized, base: base)
        for _ in 0..<40 {
            drifting = ProsodyMatcher.next(current: drifting, base: base, reading: .unknown)
        }
        run.expect(abs(drifting.rate - base.rate) < 0.01,
                   "no signal should return to baseline, ended at \(drifting.rate)")

        // --- Mood metadata ----------------------------------------------------------
        for mood in Mood.allCases {
            run.expect(!mood.displayName.isEmpty, "\(mood) needs a display name")
        }
        run.expect(Mood.low.wantsGentleness, "low mood wants gentleness")
        run.expect(Mood.frustrated.wantsGentleness, "frustration wants gentleness")
        run.expect(!Mood.energized.wantsGentleness, "energised does not want gentleness")

        // Confidence is clamped on construction.
        run.expectEqual(MoodReading(mood: .low, confidence: 9).confidence, 1, "confidence clamps high")
        run.expectEqual(MoodReading(mood: .low, confidence: -9).confidence, 0, "confidence clamps low")

        // --- Grade level metadata -----------------------------------------------------
        for grade in GradeLevel.allCases {
            run.expect(!grade.displayName.isEmpty, "\(grade) needs a display name")
            run.expect(!grade.shortName.isEmpty, "\(grade) needs a short name")
            run.expect(grade.targetSentenceWords > 0, "\(grade) needs a sentence target")
            run.expect(grade.quizChoiceCount >= 3, "\(grade) needs at least 3 choices")
        }
        run.expect(GradeLevel.grade5.targetSentenceWords < GradeLevel.college.targetSentenceWords,
                   "explanations must get more sophisticated with grade level")
        run.expectEqual(GradeLevel.grade5.band, .elementary, "5th grade band")
        run.expectEqual(GradeLevel.grade7.band, .middle, "7th grade band")
        run.expectEqual(GradeLevel.grade11.band, .high, "11th grade band")

        // --- Subject round-tripping ------------------------------------------------------
        for subject in Subject.presets {
            run.expectEqual(Subject(storageKey: subject.storageKey), subject,
                            "\(subject.displayName) must round-trip through storage")
            run.expect(!subject.symbolName.isEmpty, "\(subject.displayName) needs an icon")
        }
        let custom = Subject.other("Music Theory")
        run.expectEqual(Subject(storageKey: custom.storageKey), custom, "custom subject round-trips")
        run.expect(Subject(storageKey: "nonsense") == nil, "unknown storage key returns nil")
        run.expect(Subject(storageKey: "other:") == nil, "empty custom name returns nil")
    }
}
