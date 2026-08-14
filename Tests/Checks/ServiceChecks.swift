//
//  ServiceChecks.swift
//  Ace — developer verification harness
//
//  Runtime checks for the coordinator layer: `AppState`, `PresenceCoordinator`
//  and `ProviderController`.
//
//  These three are roughly 800 lines of orchestration — cooldowns, filters,
//  safety overrides, provider switching — and until this file existed not one
//  line of it was executed by any check. Everything around them was tested:
//  `Guardian`'s cooldown logic, `ComfortResponder`'s phrase matching,
//  `APIKeyFormat`'s validation. What wasn't tested was whether the coordinators
//  *wire those pieces together*, and all three bugs found here live exactly
//  there — in the plumbing between well-tested parts.
//
//  Each of the first three suites was written against a bug that was real:
//
//    • the comfort responder set a mute that nothing read
//    • `refresh()` never rebuilt the provider when the model or key changed
//    • `updateMood` returned early, freezing prosody partway to its target
//
//  The suites are kept phrased as behaviour ("a muted session shows no toast")
//  rather than as implementation ("`isGamificationQuiet` is true"), so they keep
//  their meaning if the plumbing is rearranged again.
//

import Foundation

enum ServiceChecks {

    // MARK: - Comfort actually quiets the game layer

    /// §10: "healthy motivation, never manipulation."
    ///
    /// A student who has just said they're exhausted should not be handed
    /// confetti — but they also shouldn't silently lose the progress they earn
    /// while tired. The mute is a *display* decision, and these checks pin down
    /// both halves of that.
    static var comfortMute: CheckSuite {
        CheckSuite(name: "Comfort mutes the game layer") { run in
            guard let r = runAsync({ await ComfortProbe.run() }) else {
                run.expect(false, "comfort probe timed out")
                return
            }

            // The precondition: this phrase is one the responder recognises.
            // If this fails the rest of the suite proves nothing, so it's
            // asserted rather than assumed.
            run.expect(r.comfortWasTriggered,
                       "\"\(ComfortProbe.tiredPhrase)\" should reach the comfort responder")
            run.expect(r.comfortMessage?.isEmpty == false,
                       "comfort should say something back")

            // The bug: the flag was set and nothing on earth read it.
            run.expect(r.quietAfterComfort,
                       "saying you're exhausted should quiet the game layer")
            run.expect(r.suppressedAfterComfort,
                       "the mute must reach the celebration center, not just AppState")

            // Mid-session is the only moment that matters. The screens set
            // `isSuppressed` once when they appear; comfort fires later.
            run.expect(r.toastBeforeComfort != nil,
                       "a normal award should show a toast before any mute")
            run.expect(r.toastAfterComfort == nil,
                       "no toast should appear once the session is muted")
            run.expect(r.inFlightToastCleared,
                       "a toast already on screen should be cleared, not left to finish")

            // The half that protects the student: earning still happens.
            // `SessionRecorder` gates *earning* on `safety.isGamificationSuppressed`
            // and the celebration center gates *showing* on its own flag, so
            // asserting the two moved independently is the real statement of
            // "silent, not punished".
            run.expect(!r.earningSuppressedAfterComfort,
                       "comfort must not suppress earning — that would punish honesty")

            // Anxiety is deliberately excluded: a small win helps there.
            run.expect(!r.quietAfterAnxious,
                       "anxious shouldn't mute — a small win is useful when anxious")

            // A new session starts clean.
            run.expect(!r.quietAfterNewSession,
                       "beginSession should clear the mute")

            // The crisis net still wins outright, and it suppresses earning too.
            run.expect(r.quietUnderCrisis, "the crisis net must quiet the game layer")
        }
    }

    // MARK: - Demo ↔ Live switching

    /// §5 and §10: Demo Mode is the floor, and a Settings change has to actually
    /// take effect.
    static var providerSwitching: CheckSuite {
        CheckSuite(name: "Provider switching") { run in
            guard let r = runAsync({ await ProviderProbe.run() }) else {
                run.expect(false, "provider probe timed out")
                return
            }

            // The floor.
            run.expect(!r.hasKeyInitially, "a fresh install has no key")
            run.expect(r.startsOnDemo, "no key means Demo Mode")

            // Bad keys never reach the store.
            run.expect(r.rejectedBadKey != nil, "a malformed key should be refused")
            run.expect(!r.storedAfterBadKey, "a refused key must not be written to the store")

            // A good key comes up live.
            run.expect(r.acceptedGoodKey == nil, "a well-formed key should be accepted")
            run.expect(r.liveAfterGoodKey, "a saved key should bring up the live provider")
            run.expect(r.fingerprintMasked,
                       "the fingerprint must not contain the key — got \(r.fingerprint ?? "nil")")

            // The bug: changing the model in Settings did nothing until relaunch.
            // Asserting the *before* value too, so the check can't silently stop
            // testing anything if the starting model ever drifts.
            run.expectEqual(r.modelBeforeChange, ProviderProbe.firstModel,
                            "the probe should start on the default model")
            run.expectEqual(r.modelAfterChange, ProviderProbe.secondModel,
                            "changing the model must reach the live provider")
            run.expect(r.providerRebuiltOnModelChange,
                       "a model change should build a new provider, not reuse the old one")

            // The same bug's nastier half: a replaced key kept the old one.
            run.expect(r.providerRebuiltOnKeyChange,
                       "replacing the key must not leave the old key in use")

            // Preference and removal both land back on the floor.
            run.expect(r.demoWhenPreferenceIsDemo,
                       "choosing on-device only must switch to Demo even with a key saved")
            run.expect(r.demoAfterKeyRemoved, "removing the key returns to Demo")
            run.expect(!r.keyLeftBehind, "removing the key must clear the store")
        }
    }

    // MARK: - Metering

    /// Part 5's economics layer only means anything if something feeds it.
    ///
    /// `recordAudio` and `recordText` had no callers anywhere in the app, so
    /// every session recorded zero usage: the ledger stayed empty, Settings
    /// always showed no usage, and the free-tier cap could never bite because
    /// there was nothing to count against it. 119 checks covering tiers, caps
    /// and pricing all passed the entire time — they tested arithmetic on data
    /// the app never produced.
    static var metering: CheckSuite {
        CheckSuite(name: "Live Mode usage is metered") { run in
            guard let r = runAsync(timeout: 8, { await MeteringProbe.run() }) else {
                run.expect(false, "metering probe timed out")
                return
            }

            // The provider counts what it actually moved, both ways.
            run.expectClose(r.outputSeconds, MeteringProbe.expectedOutputSeconds,
                            tolerance: 0.005,
                            "output audio should be counted from the bytes played")
            run.expectClose(r.inputSeconds, MeteringProbe.expectedInputSeconds,
                            tolerance: 0.005,
                            "microphone audio should be counted on the way up")

            // Draining is destructive on purpose — a second read must not bill
            // the same seconds again.
            run.expectClose(r.secondDrainInput, 0, tolerance: 0.0001,
                            "draining twice must not double-bill input")
            run.expectClose(r.secondDrainOutput, 0, tolerance: 0.0001,
                            "draining twice must not double-bill output")

            // And it reaches the ledger, which is the part that was missing.
            run.expect(r.ledgerWasEmptyBefore, "a fresh ledger has no usage")
            run.expectClose(r.voiceMinutesAfter, 10, tolerance: 0.01,
                            "ten minutes of audio should read as ten minutes")
            run.expect(r.costAfter > 0, "metered usage should carry a cost")

            // Demo Mode is free and must stay uncounted.
            run.expectClose(r.demoVoiceMinutes, 0, tolerance: 0.0001,
                            "on-device sessions cost nothing and must not be metered")
        }
    }

    // MARK: - Suppression is per-session

    /// §10: nudge, never lock.
    static var suppressionLifts: CheckSuite {
        CheckSuite(name: "Suppression lifts on a new session") { run in
            guard let r = runAsync({ await SuppressionProbe.run() }) else {
                run.expect(false, "suppression probe timed out")
                return
            }

            run.expect(r.suppressedAfterConcern,
                       "a concern-level disclosure suppresses the game layer")
            // The bug: `beginFreshSession` existed for this and was called by
            // nothing, so one detection silenced rewards for the rest of the run.
            run.expect(!r.suppressedAfterNewSession,
                       "a session started later must not inherit the suppression")
            run.expect(r.concernClearedAfterNewSession,
                       "and the inline concern banner should not follow them into it")

            // A full-screen crisis is different: it outranks everything, and a
            // new session must not quietly lift it.
            run.expect(r.stillSuppressedUnderCrisis,
                       "starting a session must not lift a full-screen crisis")
        }
    }

    // MARK: - Countable goals

    /// "10 questions" has to be able to reach 10.
    static var countableGoals: CheckSuite {
        CheckSuite(name: "Countable goals can complete") { run in
            guard let r = runAsync({ await GoalProgressProbe.run() }) else {
                run.expect(false, "goal probe timed out")
                return
            }

            run.expect(!r.completeAtStart, "a fresh goal is not already met")
            run.expectClose(r.fractionAfterFive, 0.5, tolerance: 0.001,
                            "five of ten questions is halfway")
            run.expect(r.completeAfterTen, "ten of ten completes the goal")
            run.expect(r.metGoalOnFinish,
                       "finishing a completed count goal records it as met")
        }
    }

    // MARK: - Prosody easing

    /// §9: mirror, never clone. Delivery eases toward the mood target across
    /// several reads so it slides rather than snaps.
    static var moodEasing: CheckSuite {
        CheckSuite(name: "Mood easing converges") { run in
            guard let r = runAsync({ await MoodProbe.run() }) else {
                run.expect(false, "mood probe timed out")
                return
            }

            run.expect(r.moodWasRead, "the probe text should produce an actionable read")

            // The bug: the second and every later read returned early, so
            // prosody stopped moving after one step.
            run.expect(r.movedAfterFirstRead,
                       "the first read should move prosody off baseline")
            run.expect(r.keptMovingAfterSecondRead,
                       "an unchanged mood must keep easing — that's what makes it ease")

            // What "converges" means, stated as a fraction of the gap rather
            // than an absolute number. The absolute numbers here are small
            // (baseline sits 0.12 from the target, one step closes 63% of it),
            // so an absolute threshold either passes trivially or has to be
            // retuned every time a persona's baseline moves.
            run.expect(r.finalDistance < r.distanceAfterOne * 0.05,
                       "repeated reads should close nearly all the remaining gap; "
                       + "went from \(r.distanceAfterOne) to \(r.finalDistance)")

            // The anti-tautology guard: under the early-return bug these two are
            // *identical*, because prosody never moved again. If one step landed
            // on the target this suite would pass either way and be worthless.
            run.expect(r.distanceAfterOne > 0.01,
                       "one step must not already be at the target, or this suite "
                       + "would pass with the early-return bug back "
                       + "(afterOne = \(r.distanceAfterOne))")

            // The premise the whole suite rests on: the reading really was
            // identical each time, so the movement above came from easing and
            // not from the mood changing underneath it.
            run.expect(r.readingStayedIdentical,
                       "the probe text should read the same mood every time")

            // A genuinely new mood retargets rather than continuing to the old one.
            run.expect(r.retargetedOnMoodChange,
                       "a changed mood should ease toward the new target")

            // Values stay inside what AVFoundation accepts, the whole way.
            run.expect(r.stayedInRange, "eased prosody must stay clamped to valid ranges")
        }
    }
}

// MARK: - Probes
//
// The probes do the driving on the main actor; the suites above only assert on
// what they return. Splitting it this way keeps every assertion synchronous and
// readable, and keeps the actor hops in one place.

@MainActor
private enum ComfortProbe {

    static let tiredPhrase = "i am exhausted"
    static let anxiousPhrase = "i am panicking about this test"

    struct Result: Sendable {
        var comfortWasTriggered = false
        var comfortMessage: String?
        var quietAfterComfort = false
        var suppressedAfterComfort = false
        var toastBeforeComfort: Int?
        var toastAfterComfort: Int?
        var inFlightToastCleared = false
        var earningSuppressedAfterComfort = true
        var quietAfterAnxious = false
        var quietAfterNewSession = false
        var quietUnderCrisis = false
    }

    static func run() async -> Result {
        var out = Result()

        let appState = AppState()
        let presence = PresenceCoordinator()
        let celebrations = CelebrationCenter()

        // What a study screen does when it appears.
        celebrations.isSuppressed = appState.isGamificationQuiet
        appState.activeCelebrations = celebrations
        presence.begin(goal: StudyGoal(target: .duration(minutes: 15), rawText: "15 minutes"),
                       appState: appState)

        // A normal award, before anything is muted.
        celebrations.show(amount: 5, caption: "Nice")
        out.toastBeforeComfort = celebrations.currentToast?.amount

        // A toast is on screen at the moment comfort fires — the case that
        // matters, because it's the one a start-of-session flag can't catch.
        out.comfortWasTriggered = presence.checkComfort(tiredPhrase, studentName: "Sam")
        out.comfortMessage = presence.comfortMessage

        out.quietAfterComfort = appState.isGamificationQuiet
        out.suppressedAfterComfort = celebrations.isSuppressed
        out.inFlightToastCleared = celebrations.currentToast == nil

        // Nothing shows now.
        celebrations.show(amount: 25, caption: "Streak!")
        out.toastAfterComfort = celebrations.currentToast?.amount

        // …but earning is untouched. `SessionRecorder` reads the safety flag,
        // not this one, so the mute must leave it alone.
        out.earningSuppressedAfterComfort = appState.safety.isGamificationSuppressed

        // Anxious is deliberately not a mute.
        let anxious = AppState()
        let anxiousPresence = PresenceCoordinator()
        anxiousPresence.begin(goal: StudyGoal(target: .duration(minutes: 15), rawText: "15 minutes"),
                              appState: anxious)
        anxiousPresence.checkComfort(anxiousPhrase, studentName: "Sam")
        out.quietAfterAnxious = anxious.isGamificationQuiet

        // A fresh session starts clean.
        appState.beginSession()
        out.quietAfterNewSession = appState.isGamificationQuiet

        // The crisis net overrides everything.
        let crisis = AppState()
        crisis.safety.check("i want to kill myself")
        out.quietUnderCrisis = crisis.isGamificationQuiet

        return out
    }
}

@MainActor
private enum ProviderProbe {

    static let firstKey = "sk-proj-" + String(repeating: "a", count: 40)
    static let secondKey = "sk-proj-" + String(repeating: "b", count: 40)
    static let firstModel = RealtimeModel.default
    static let secondModel = "gpt-4o-mini-realtime-preview"

    struct Result: Sendable {
        var hasKeyInitially = true
        var startsOnDemo = false
        var rejectedBadKey: String?
        var storedAfterBadKey = true
        var acceptedGoodKey: String?
        var liveAfterGoodKey = false
        var fingerprint: String?
        var fingerprintMasked = false
        var modelBeforeChange: String?
        var modelAfterChange: String?
        var providerRebuiltOnModelChange = false
        var providerRebuiltOnKeyChange = false
        var demoWhenPreferenceIsDemo = false
        var demoAfterKeyRemoved = false
        var keyLeftBehind = true
    }

    static func run() async -> Result {
        var out = Result()

        // `ProviderController` persists the model and preference to
        // `UserDefaults`, so without this the *second* run of the harness starts
        // with the model this probe left behind and the model-change check
        // quietly stops testing anything. Snapshot, run, restore.
        let defaults = UserDefaults.standard
        let savedModel = defaults.string(forKey: "ace.provider.model")
        let savedPreference = defaults.string(forKey: "ace.provider.preference")
        defer {
            defaults.set(savedModel, forKey: "ace.provider.model")
            defaults.set(savedPreference, forKey: "ace.provider.preference")
        }
        defaults.removeObject(forKey: "ace.provider.model")
        defaults.removeObject(forKey: "ace.provider.preference")

        // An in-memory store, so the checks never touch the login keychain —
        // which in a headless process either fails or blocks on a prompt.
        let secrets = InMemorySecretStore()
        let controller = ProviderController(secrets: secrets)
        controller.preference = .preferLive
        controller.model = firstModel
        await controller.refresh()

        out.hasKeyInitially = controller.hasKey
        out.startsOnDemo = controller.live == nil

        // Garbage in.
        out.rejectedBadKey = await controller.saveKey("not-a-key")
        out.storedAfterBadKey = secrets.hasKey

        // A real one.
        out.acceptedGoodKey = await controller.saveKey(firstKey)
        out.liveAfterGoodKey = controller.live != nil
        out.fingerprint = controller.keyFingerprint
        out.fingerprintMasked = !(controller.keyFingerprint ?? "").contains(firstKey)

        // Change the model, the way Settings does.
        out.modelBeforeChange = controller.liveModel
        let before = controller.live
        controller.model = secondModel
        await controller.refresh()
        out.modelAfterChange = controller.liveModel
        out.providerRebuiltOnModelChange = controller.live !== before

        // Replace the key while one is already saved. The old provider is
        // holding the old key, and used to keep holding it.
        let beforeKeyChange = controller.live
        await controller.saveKey(secondKey)
        out.providerRebuiltOnKeyChange = controller.live !== beforeKeyChange

        // On-device only, with a key still saved.
        controller.preference = .alwaysDemo
        await controller.refresh()
        out.demoWhenPreferenceIsDemo = controller.live == nil

        controller.preference = .preferLive
        await controller.refresh()
        await controller.removeKey()
        out.demoAfterKeyRemoved = controller.live == nil
        out.keyLeftBehind = secrets.hasKey

        return out
    }
}

@MainActor
private enum MeteringProbe {

    /// The mock yields `audioChunks` chunks of 960 bytes — 20ms each at 24kHz
    /// PCM16, which is what the realtime API actually speaks.
    static let expectedOutputSeconds = 3 * 0.02
    static let micChunks = 5
    static let expectedInputSeconds = Double(micChunks) * 0.02

    struct Result: Sendable {
        var inputSeconds = 0.0
        var outputSeconds = 0.0
        var secondDrainInput = -1.0
        var secondDrainOutput = -1.0
        var ledgerWasEmptyBefore = false
        var voiceMinutesAfter = -1.0
        var costAfter = -1.0
        var demoVoiceMinutes = -1.0
    }

    static func run() async -> Result {
        var out = Result()

        let mock = MockRealtimeTransport(script: .healthy)
        let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
        let sink = RecordingAudioSink()
        provider.audioSink = sink
        guard await provider.prewarm(config: RealtimeSessionConfig(
            instructions: "test", voice: VoiceRoster.default.realtimeVoiceName)) else {
            return out
        }

        // The student talks…
        for _ in 0..<micChunks {
            await provider.sendMicrophoneAudio(Data(repeating: 0, count: 960))
        }

        // …and Ace answers.
        let stream = provider.tutorReply(
            context: TutorContext(studentMessage: "what is photosynthesis?"))
        do { for try await _ in stream {} } catch {}
        try? await Task.sleep(for: .milliseconds(60))

        let used = provider.drainAudioUsage()
        out.inputSeconds = used.input
        out.outputSeconds = used.output

        let again = provider.drainAudioUsage()
        out.secondDrainInput = again.input
        out.secondDrainOutput = again.output
        await provider.disconnect()

        // The ledger half.
        let store = StoreController()
        store.resetUsage()
        out.ledgerWasEmptyBefore = store.thisMonth.voiceMinutes == 0

        store.beginSession(isLive: true)
        store.recordAudio(inputSeconds: 300, outputSeconds: 300)
        store.endSession()
        out.voiceMinutesAfter = store.thisMonth.voiceMinutes
        out.costAfter = store.thisMonth.cost

        // Demo Mode costs nothing.
        let demo = StoreController()
        demo.resetUsage()
        demo.beginSession(isLive: false)
        demo.endSession()
        out.demoVoiceMinutes = demo.thisMonth.voiceMinutes

        return out
    }
}

@MainActor
private enum SuppressionProbe {

    struct Result: Sendable {
        var suppressedAfterConcern = false
        var suppressedAfterNewSession = true
        var concernClearedAfterNewSession = false
        var stillSuppressedUnderCrisis = false
    }

    static func run() async -> Result {
        var out = Result()

        let appState = AppState()
        appState.safety.check("i am a burden to everyone")
        out.suppressedAfterConcern = appState.safety.isGamificationSuppressed

        // Hours later, a brand-new study session.
        appState.beginSession()
        out.suppressedAfterNewSession = appState.safety.isGamificationSuppressed
        out.concernClearedAfterNewSession = appState.safety.concernResponse == nil

        // A full-screen crisis is not lifted by starting something else.
        let crisis = AppState()
        crisis.safety.check("i want to kill myself")
        crisis.beginSession()
        out.stillSuppressedUnderCrisis = crisis.safety.isGamificationSuppressed

        return out
    }
}

@MainActor
private enum GoalProgressProbe {

    struct Result: Sendable {
        var completeAtStart = true
        var fractionAfterFive = -1.0
        var completeAfterTen = false
        var metGoalOnFinish = false
    }

    static func run() async -> Result {
        var out = Result()

        let appState = AppState()
        let presence = PresenceCoordinator()
        let goal = StudyGoal(target: .count(10, unit: .questions), rawText: "10 questions")
        presence.begin(goal: goal, appState: appState)

        out.completeAtStart = presence.session.progress().isComplete

        for _ in 0..<5 { presence.recordProgress() }
        out.fractionAfterFive = presence.session.progress().fraction

        for _ in 0..<5 { presence.recordProgress() }
        out.completeAfterTen = presence.session.progress().isComplete

        presence.finishSession()
        out.metGoalOnFinish = presence.session.phase.metGoal

        return out
    }
}

@MainActor
private enum MoodProbe {

    /// Wording the heuristics read as actionable, with enough behavioural
    /// signal behind it to carry confidence.
    static let text = "i am so lost i have no idea what any of this means"

    /// A different read, for the retarget check.
    static let calmText = "got it, that makes sense now, this is clicking"

    struct Result: Sendable {
        var moodWasRead = false
        var movedAfterFirstRead = false
        var keptMovingAfterSecondRead = false
        var distanceAfterOne = 0.0
        var finalDistance = 1.0
        var readingStayedIdentical = false
        var retargetedOnMoodChange = false
        var stayedInRange = true
    }

    static func run() async -> Result {
        var out = Result()

        let appState = AppState()
        appState.beginSession()

        let base = appState.persona.baseProsody
        let baseline = appState.prosody

        await appState.updateMood(text: text)
        let reading = appState.mood
        out.moodWasRead = reading.isActionable

        let target = ProsodyMatcher.target(for: reading.mood, base: base)
        let afterOne = appState.prosody

        out.movedAfterFirstRead = distance(afterOne, baseline) > 0.001
        out.distanceAfterOne = distance(afterOne, target)

        // The same read again. Under the bug this returned before touching
        // prosody, so the value below would be identical to `afterOne`.
        await appState.updateMood(text: text)
        let afterTwo = appState.prosody
        out.keptMovingAfterSecondRead = distance(afterTwo, afterOne) > 0.001

        // Keep going: easing is only easing if it arrives.
        var identical = true
        for _ in 0..<20 {
            await appState.updateMood(text: text)
            if appState.mood != reading { identical = false }
            if !inRange(appState.prosody) { out.stayedInRange = false }
        }
        out.readingStayedIdentical = identical
        out.finalDistance = distance(appState.prosody, target)

        // Now change the mood for real and check it heads somewhere new rather
        // than continuing toward the old target.
        let settled = appState.prosody
        await appState.updateMood(text: MoodProbe.calmText)
        let newReading = appState.mood
        out.retargetedOnMoodChange = newReading != reading
            && distance(appState.prosody, settled) > 0.001

        return out
    }

    /// Largest per-field gap. A max rather than a mean so one field that never
    /// converges can't be hidden by three that do.
    private static func distance(_ a: Prosody, _ b: Prosody) -> Double {
        max(abs(a.rate - b.rate),
            abs(a.pitch - b.pitch),
            abs(a.volume - b.volume),
            abs(a.preDelay - b.preDelay))
    }

    private static func inRange(_ p: Prosody) -> Bool {
        (0...1).contains(p.rate) && (0.5...2.0).contains(p.pitch)
            && (0...1).contains(p.volume) && p.preDelay >= 0
    }
}

// MARK: - Re-reading the profile

/// `apply` runs whenever the profile is re-read — including Settings'
/// `.onDisappear`, which fires whether or not anything was edited.
///
/// It used to snap `prosody` back to the persona's baseline every time, so
/// opening Settings mid-session to glance at a streak discarded however far the
/// voice matching had eased toward how the student actually sounded. §9's whole
/// point is that delivery eases rather than snaps; resetting it on an unrelated
/// screen dismissal is the same defect as never easing at all, arriving later.
enum ProfileApplyChecks {
    static let all = CheckSuite(name: "Re-reading the profile") { run in
        guard let r = runAsync({ await ApplyProbe.run() }) else {
            run.expect(false, "apply probe timed out")
            return
        }

        run.expect(r.easedAwayFromBaseline,
                   "the probe should have moved prosody off baseline first")
        run.expect(r.survivedUnchangedApply,
                   "re-applying an unchanged profile must not reset delivery")
        run.expect(r.resetOnPersonaChange,
                   "choosing a different voice SHOULD reset delivery to its baseline")
        run.expectEqual(r.personaAfterChange, r.expectedPersona,
                        "and the new persona takes effect")
        run.expectEqual(r.nameAfterApply, "Sam",
                        "other profile fields still propagate")
    }
}

@MainActor
private enum ApplyProbe {
    struct Result: Sendable {
        var easedAwayFromBaseline = false
        var survivedUnchangedApply = false
        var resetOnPersonaChange = false
        var personaAfterChange = ""
        var expectedPersona = ""
        var nameAfterApply = ""
    }

    static func run() async -> Result {
        var out = Result()
        let appState = AppState()

        var settings = StudentSettings()
        settings.name = "Sam"
        settings.voicePersonaID = VoiceRoster.default.id
        appState.apply(settings)
        appState.beginSession()

        out.nameAfterApply = appState.settings.name
        let baseline = appState.prosody

        // Let the voice ease somewhere.
        for _ in 0..<6 {
            await appState.updateMood(text: "i am so lost i have no idea what this means")
        }
        let eased = appState.prosody
        out.easedAwayFromBaseline = eased != baseline

        // Settings opened and closed, nothing edited.
        appState.apply(settings)
        out.survivedUnchangedApply = appState.prosody == eased

        // A different voice chosen — this one SHOULD start again from its baseline.
        if let other = VoiceRoster.all.first(where: { $0.id != VoiceRoster.default.id }) {
            var changed = settings
            changed.voicePersonaID = other.id
            appState.apply(changed)
            out.resetOnPersonaChange = appState.prosody == other.baseProsody
            out.personaAfterChange = appState.persona.id
            out.expectedPersona = other.id
        } else {
            out.resetOnPersonaChange = true
            out.personaAfterChange = ""
            out.expectedPersona = ""
        }
        return out
    }
}
