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

// MARK: - Start over

/// "Start over" deleted the six model types and stopped.
///
/// Three things outlived it. The usage ledger, so a student at their free cap
/// could lose all their work and still be capped. The share inbox and its
/// payload files, so items shared before the reset were imported into the
/// "fresh" app afterwards. And every `ace.speaking.history.<uuid>` entry, whose
/// source had just been deleted — keyed to an id that no longer existed
/// anywhere, unreadable and unreclaimable, one more added per source forever.
///
/// That last one leaked on the ordinary path too: deleting a single source
/// never cleared its history either.
enum ResetChecks {
    static let all = CheckSuite(name: "Start over actually starts over") { run in
        let defaults = UserDefaults.standard
        let sourceA = UUID(), sourceB = UUID()
        let prefix = AppReset.speakingHistoryPrefix

        // Start from a known state. `UserDefaults.standard` is real and shared,
        // so a previous run — or a previous *failed* run — can leave entries
        // behind and make the counts below meaningless. An earlier version of
        // this check skipped it and reported "expected 2, got 3" the first time
        // anything left a key lying around.
        AppReset.clearAllSpeakingHistory()

        // Preferences that must survive, seeded first so the sweep can be shown
        // to leave them alone.
        let tierBefore = defaults.string(forKey: "ace.tier")
        defaults.set("plus", forKey: "ace.tier")
        defaults.set(false, forKey: "ace.sounds.enabled")

        defaults.set(true, forKey: "ace.demoContentInstalled")
        defaults.set(Data("ledger".utf8), forKey: "ace.usage.ledger")
        defaults.set(Date(), forKey: "ace.quickCapture.requestedAt")
        defaults.set(Data("scores".utf8), forKey: prefix + sourceA.uuidString)
        defaults.set(Data("scores".utf8), forKey: prefix + sourceB.uuidString)

        run.expectEqual(AppReset.speakingHistoryKeyCount(), 2, "two sources have history")

        // --- Deleting one source takes only its own history ---------------------
        AppReset.forget(sourceID: sourceA)
        run.expect(defaults.data(forKey: prefix + sourceA.uuidString) == nil,
                   "the deleted source's history goes with it")
        run.expect(defaults.data(forKey: prefix + sourceB.uuidString) != nil,
                   "and the other source keeps its own")
        run.expectEqual(AppReset.speakingHistoryKeyCount(), 1, "exactly one left")

        // --- Start over -----------------------------------------------------------
        AppReset.clearStoredState()

        run.expectEqual(AppReset.speakingHistoryKeyCount(), 0,
                        "no speaking history survives a reset — it would be keyed "
                        + "to sources that no longer exist")
        run.expect(defaults.data(forKey: "ace.usage.ledger") == nil,
                   "the usage ledger must not survive: a student at their cap "
                   + "would reset the app and still be capped")
        run.expect(defaults.object(forKey: "ace.demoContentInstalled") == nil,
                   "demo content installs again for a genuinely fresh app")
        run.expect(defaults.object(forKey: "ace.quickCapture.requestedAt") == nil,
                   "a pending widget capture must not fire into the fresh app")
        if ShareInbox.containerURL != nil {
            run.expectEqual(ShareInbox.load().count, 0, "the share inbox is emptied")
        }

        // --- What a reset must NOT take ------------------------------------------
        run.expectEqual(defaults.string(forKey: "ace.tier"), "plus",
                        "a subscription is not local data — wiping study material "
                        + "must never look like revoking something they paid for")
        run.expectEqual(defaults.bool(forKey: "ace.sounds.enabled"), false,
                        "someone who turned sound off did it for a reason a reset "
                        + "does not undo")

        // Put the machine back how it was found.
        if let tierBefore { defaults.set(tierBefore, forKey: "ace.tier") }
        else { defaults.removeObject(forKey: "ace.tier") }
        defaults.set(true, forKey: "ace.sounds.enabled")
    }
}

// MARK: - Telling the student what actually arrived

/// The import toast reported failures only when *nothing* succeeded.
///
/// Share five things, two in a format Ace can't read, and it said "3 shared
/// items are ready" — while `ShareInbox.drain()` had already cleared the
/// manifest, so the other two were gone. The student is told it all worked and
/// quietly loses two things. That message is the last chance they had to know.
enum ShareOutcomeChecks {
    static let all = CheckSuite(name: "What the import toast says") { run in
        func outcome(_ ok: Int, failed: Int = 0, skipped: Int = 0) -> ShareImportOutcome {
            ShareImportOutcome(imported: (0..<ok).map { _ in UUID() },
                               failed: failed, skippedForSafety: skipped)
        }

        // Nothing happened at all.
        run.expect(outcome(0).message == nil, "an empty inbox says nothing")

        // Clean successes.
        run.expectEqual(outcome(1).message, "Something you shared is ready.")
        run.expectEqual(outcome(4).message, "4 shared items are ready.")

        // Clean failures.
        run.expectEqual(outcome(0, failed: 1).message,
                        "I couldn't read what you shared. Try the text instead.")
        run.expectEqual(outcome(0, failed: 3).message,
                        "I couldn't read what you shared. Try the text instead.")

        // --- THE BUG: partial failure ------------------------------------------
        let partial = outcome(3, failed: 2)
        run.expect(partial.message?.contains("3") == true,
                   "a partial import still reports what arrived")
        run.expect(partial.message?.contains("2") == true,
                   "and must say how many did not — they are already gone from "
                   + "the inbox, so this is the only time the student can be told")

        let oneOfTwo = outcome(1, failed: 1)
        run.expect(oneOfTwo.message?.lowercased().contains("couldn't read") == true,
                   "one succeeded and one failed still mentions the failure")

        // Every mixed combination must name both numbers.
        for ok in 1...4 {
            for failed in 1...3 {
                let message = outcome(ok, failed: failed).message ?? ""
                run.expect(message.contains("\(ok)") || (ok == 1 && message.contains("One")),
                           "\(ok) ok / \(failed) failed must state the successes: “\(message)”")
                run.expect(message.contains("\(failed)") || (failed == 1 && message.contains("one")),
                           "\(ok) ok / \(failed) failed must state the failures: “\(message)”")
            }
        }

        // Safety-held items are deliberately never counted in the toast.
        run.expectEqual(outcome(2, skipped: 1).message, "2 shared items are ready.",
                        "the safety surface has already spoken; tallying it here "
                        + "afterwards would be crass")
        run.expect(outcome(0, skipped: 2).message == nil,
                   "and an import that was entirely held back says nothing extra")

        run.expect(outcome(2, failed: 1).didImportAnything, "some arrived")
        run.expect(!outcome(0, failed: 2).didImportAnything, "none arrived")
    }
}

// MARK: - What is due, and being told about it

/// Ace has had a real SM-2 scheduler since Part 2 and it reached nobody.
///
/// `ReviewState` carries an ease factor, an interval and a `dueDate`, all
/// computed correctly — and `dueDate` was read in exactly one place: a count
/// inside a single source's detail screen. There was no "what's due today"
/// anywhere, and not one call to `UNUserNotificationCenter` in the whole
/// project. Spaced repetition that never tells you it is time is a spreadsheet.
enum ReviewQueueChecks {

    private static func entry(_ title: String, dueDaysAgo: Double?,
                              isNew: Bool = false, now: Date) -> ReviewEntry {
        var state = ReviewState.new
        if !isNew {
            state.repetitions = 2
            state.lastReviewed = now
            state.dueDate = now.addingTimeInterval(-(dueDaysAgo ?? 0) * 86_400)
        }
        return ReviewEntry(id: UUID(), sourceID: UUID(uuidString:
            "00000000-0000-0000-0000-\(String(format: "%012d", abs(title.hashValue % 1_000_000)))")
            ?? UUID(), sourceTitle: title, state: state)
    }

    static let all = CheckSuite(name: "What's due today") { run in
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let day = 86_400.0

        // Overdue by 5 days, due today, due tomorrow, and never studied.
        var overdue = ReviewState.new
        overdue.repetitions = 3; overdue.lastReviewed = now
        overdue.dueDate = now.addingTimeInterval(-5 * day)
        var dueToday = ReviewState.new
        dueToday.repetitions = 1; dueToday.lastReviewed = now
        dueToday.dueDate = now.addingTimeInterval(-60)
        var later = ReviewState.new
        later.repetitions = 4; later.lastReviewed = now
        later.dueDate = now.addingTimeInterval(3 * day)

        let bio = UUID(), maths = UUID()
        let entries = [
            ReviewEntry(id: UUID(), sourceID: bio, sourceTitle: "Biology", state: overdue),
            ReviewEntry(id: UUID(), sourceID: bio, sourceTitle: "Biology", state: dueToday),
            ReviewEntry(id: UUID(), sourceID: maths, sourceTitle: "Maths", state: dueToday),
            ReviewEntry(id: UUID(), sourceID: maths, sourceTitle: "Maths", state: later),
            ReviewEntry(id: UUID(), sourceID: bio, sourceTitle: "Biology", state: .new),
        ]

        // --- What is due -----------------------------------------------------------
        let due = ReviewQueue.due(from: entries, now: now)
        run.expectEqual(due.count, 3, "three cards are due")
        run.expectEqual(due.first?.state.dueDate, overdue.dueDate,
                        "the most overdue card comes first — it is the one closest "
                        + "to being forgotten, which is the whole premise")
        run.expect(!due.contains { $0.state.isNew },
                   "a card never studied cannot be forgotten, so it is not 'due'")

        run.expectEqual(ReviewQueue.fresh(from: entries).count, 1, "one card is new")
        run.expectEqual(ReviewQueue.nextDue(from: entries, now: now), later.dueDate,
                        "the next wake-up is the soonest not-yet-due card")
        run.expectEqual(ReviewQueue.daysOverdue(from: entries, now: now), 5,
                        "five days behind on the oldest")

        // --- Grouped by source -----------------------------------------------------
        let groups = ReviewQueue.groups(from: entries, now: now)
        run.expectEqual(groups.count, 2, "two sources have work waiting")
        run.expectEqual(groups.first?.title, "Biology", "the biggest group leads")
        run.expectEqual(groups.first?.dueCount, 2, "Biology has two due")
        run.expectEqual(groups.last?.dueCount, 1, "Maths has one")
        run.expect(groups.allSatisfy { $0.dueCount > 0 },
                   "a source with nothing due is not listed at all")

        // Ordering must be stable, not however the dictionary hashed today.
        for _ in 0..<12 {
            run.expectEqual(ReviewQueue.groups(from: entries, now: now).map(\.title),
                            ["Biology", "Maths"], "group order is deterministic")
        }

        // --- Nothing due ------------------------------------------------------------
        let quiet = [ReviewEntry(id: UUID(), sourceID: bio, sourceTitle: "Biology", state: later)]
        run.expect(ReviewQueue.due(from: quiet, now: now).isEmpty, "nothing due yet")
        run.expect(ReviewQueue.summary(from: quiet, now: now) == nil,
                   "and nothing to say about it")
        run.expectEqual(ReviewQueue.daysOverdue(from: quiet, now: now), 0, "not behind")

        // --- The wording never scolds ----------------------------------------------
        let summary = ReviewQueue.summary(from: entries, now: now) ?? ""
        run.expect(summary.contains("3 cards"), "says how much: “\(summary)”")
        for word in ["behind", "!", "don't", "lose", "losing", "missed", "overdue", "failing"] {
            run.expect(!summary.lowercased().contains(word),
                       "review copy must invite, never scold: “\(summary)”")
        }

        // A fortnight away must not produce a number to feel bad about.
        var ancient = ReviewState.new
        ancient.repetitions = 2; ancient.lastReviewed = now
        ancient.dueDate = now.addingTimeInterval(-23 * day)
        let lapsed = [ReviewEntry(id: UUID(), sourceID: bio, sourceTitle: "Biology", state: ancient)]
        let lapsedLine = ReviewQueue.summary(from: lapsed, now: now) ?? ""
        run.expect(!lapsedLine.contains("23"),
                   "23 days away is not a number to put in front of someone: “\(lapsedLine)”")
        run.expect(lapsedLine.contains("1 card"), "but still says what is waiting")
    }
}

// MARK: - Reminders

/// Ace had no notifications of any kind — not one call to
/// `UNUserNotificationCenter` in the project — while computing a due date for
/// every card it had ever made. Reviewing "just before you'd forget" depended
/// entirely on the student happening to open the app on the right day.
///
/// The rules matter more than the plumbing, so they are what these check.
enum ReminderChecks {

    private final class FakeScheduler: ReminderScheduler, @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled: [(id: String, title: String, body: String, at: Date)] = []
        private(set) var cancelCount = 0

        var all: [(id: String, title: String, body: String, at: Date)] {
            lock.withLock { scheduled }
        }
        func requestAuthorization() async -> Bool { true }
        func cancelAll() async {
            lock.withLock { scheduled.removeAll(); cancelCount += 1 }
        }
        func schedule(id: String, title: String, body: String, at date: Date) async {
            lock.withLock { scheduled.append((id, title, body, date)) }
        }
    }

    static let all = CheckSuite(name: "Study reminders") { run in
        var calendar = Calendar(identifier: .gregorian)
        calendar = calendar
        let day = 86_400.0
        // 09:00, so "later today at 17:00" is still ahead.
        let morning = Date(timeIntervalSince1970: 1_780_034_400)

        func card(dueIn days: Double, isNew: Bool = false) -> ReviewEntry {
            var state = ReviewState.new
            if !isNew {
                state.repetitions = 2
                state.lastReviewed = morning
                state.dueDate = morning.addingTimeInterval(days * day)
            }
            return ReviewEntry(id: UUID(), sourceID: UUID(),
                               sourceTitle: "Biology", state: state)
        }

        // --- Something is waiting --------------------------------------------------
        let waiting = [card(dueIn: -1), card(dueIn: -0.2)]
        let plan = StudyReminders.plan(entries: waiting, now: morning, calendar: calendar)
        run.expect(plan != nil, "work waiting produces a reminder")
        run.expect(plan!.fireAt > morning, "which fires in the future")
        run.expect(plan!.body.contains("2 cards"), "and says what is waiting")

        // --- Nothing to do means nothing is sent -----------------------------------
        run.expect(StudyReminders.plan(entries: [], now: morning, calendar: calendar) == nil,
                   "an empty library gets no reminder — an app asking for attention "
                   + "with nothing to offer is one you turn notifications off for")
        run.expect(StudyReminders.plan(entries: [card(dueIn: 4, isNew: false)].filter { _ in false },
                                       now: morning, calendar: calendar) == nil,
                   "nor does an empty queue")
        run.expect(StudyReminders.plan(entries: [card(dueIn: 0, isNew: true)],
                                       now: morning, calendar: calendar) == nil,
                   "a library of only never-studied cards has nothing scheduled yet")

        // --- Nothing due yet: line one up for the day it wakes ---------------------
        let future = StudyReminders.plan(entries: [card(dueIn: 3)],
                                         now: morning, calendar: calendar)
        run.expect(future != nil, "a card due in three days still gets a reminder")
        run.expect(future!.fireAt > morning.addingTimeInterval(2 * day),
                   "scheduled for the day it comes due, not today")
        run.expect(future!.body.contains("1 card"), "and counts just that day's cards")

        // --- The crisis net outranks it --------------------------------------------
        run.expect(StudyReminders.plan(entries: waiting, now: morning,
                                       isSuppressed: true, calendar: calendar) == nil,
                   "no push about flashcards while the crisis net is engaged")

        // --- One reminder, never a pile --------------------------------------------
        if let outcome = runAsync({ () -> (Int, Int, Int) in
            let fake = FakeScheduler()
            for _ in 0..<5 {
                await StudyReminders.apply(
                    StudyReminders.plan(entries: waiting, now: morning, calendar: calendar),
                    using: fake)
            }
            let afterRepeats = fake.all.count
            // The student finishes their review; nothing is due any more.
            await StudyReminders.apply(
                StudyReminders.plan(entries: [], now: morning, calendar: calendar), using: fake)
            return (afterRepeats, fake.all.count, fake.cancelCount)
        }) {
            let (afterRepeats, afterDone, cancels) = outcome
            run.expectEqual(afterRepeats, 1,
                            "scheduling five times leaves one reminder, not five")
            run.expectEqual(afterDone, 0,
                            "finishing the review cancels it — nothing is more annoying "
                            + "than being reminded to do what you just did")
            run.expectEqual(cancels, 6, "every apply clears first")
        } else {
            run.expect(false, "reminder probe timed out")
        }

        // --- The copy invites ------------------------------------------------------
        for entries in [waiting, [card(dueIn: -20)], [card(dueIn: 2)]] {
            guard let p = StudyReminders.plan(entries: entries, now: morning,
                                              calendar: calendar) else { continue }
            for word in ["!", "don't", "streak", "lose", "behind", "missed", "urgent"] {
                run.expect(!p.body.lowercased().contains(word),
                           "a reminder must never pressure: “\(p.body)”")
                run.expect(!p.title.lowercased().contains(word),
                           "nor its title: “\(p.title)”")
            }
        }

        // --- The nudge hour --------------------------------------------------------
        let atNine = StudyReminders.nextOccurrence(ofHour: 17, after: morning, calendar: calendar)
        run.expect(atNine != nil && atNine! > morning, "17:00 today is still ahead at 09:00")
        let evening = morning.addingTimeInterval(11 * 3_600)   // 20:00
        let tomorrow = StudyReminders.nextOccurrence(ofHour: 17, after: evening, calendar: calendar)
        run.expect(tomorrow != nil && tomorrow! > evening,
                   "past the hour, it rolls to tomorrow rather than firing immediately")
    }
}
