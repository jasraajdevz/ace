//
//  AppState.swift
//  Ace
//
//  The one object every screen reaches for. Holds the current AI provider, the
//  active profile's derived settings, and the safety coordinator.
//
//  Deliberately small: this is a *coordinator*, not a god object. Anything that
//  belongs to a single screen lives in that screen's view model.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppState {

    // MARK: Provider

    /// Owns the Demo ↔ Live switch. Screens never touch this — they read
    /// `provider`, which is whatever is currently correct.
    let providers: ProviderController

    /// The AI provider in use right now.
    var provider: AIProvider { providers.current }

    var providerMode: AIProviderMode { provider.mode }

    /// The live provider's connection quality, when Live Mode is up.
    var connectionQuality: ConnectionQuality {
        providers.live?.connectionQuality ?? .offline
    }

    var isLiveAvailable: Bool { providers.live?.isReady ?? false }

    // MARK: The student

    /// A snapshot of the profile. Mirrored here so screens deep in the study
    /// loop can read the grade level and voice without having to be handed the
    /// `Profile` object — the tutor needs the register, not the database row.
    private(set) var settings = StudentSettings()

    var gradeLevel: GradeLevel { settings.gradeLevel }

    // MARK: Voice

    /// The persona the student picked. Mirrored here so views don't have to
    /// reach into SwiftData for something they read on every frame.
    var persona: VoicePersona = VoiceRoster.default

    /// The delivery Ace is currently using, eased toward the mood target rather
    /// than snapped (§9).
    private(set) var prosody: Prosody = VoiceRoster.default.baseProsody

    /// The latest read on the student.
    private(set) var mood: MoodReading = .unknown

    /// True while Ace is speaking, so the UI can show the waveform and the
    /// barge-in affordance.
    private(set) var isSpeaking = false

    /// Set by the comfort responder: quiet the game layer without the full
    /// crisis suppression. Somebody who just said they're exhausted does not
    /// need an XP toast (§10).
    ///
    /// Note what this does *not* do: it never stops progress being recorded.
    /// The crisis net suppresses earning as well as showing, but admitting to
    /// being tired is not a reason to lose a streak — that would punish honesty,
    /// which is the opposite of the point. XP still accrues; it just does so
    /// silently.
    var celebrationsMuted = false {
        didSet {
            guard celebrationsMuted != oldValue else { return }
            activeCelebrations?.isSuppressed = isGamificationQuiet
            // Clear anything already on screen. If a toast was mid-flight when
            // they said they were done, letting it finish is the wrong answer.
            if celebrationsMuted { activeCelebrations?.silence() }
        }
    }

    /// The celebration center for the session in progress.
    ///
    /// Registered by the study screens so a mute decided *mid-session* still
    /// lands. Setting `isSuppressed` once when the screen appears — which is all
    /// that used to happen — misses the comfort moment entirely, because comfort
    /// is triggered by something the student says while studying.
    weak var activeCelebrations: CelebrationCenter?

    /// True when the game layer must stay quiet: the crisis net engaged, or the
    /// comfort responder judged this a bad moment for confetti.
    ///
    /// Every display-side gate reads this rather than `safety` alone. There were
    /// once fourteen call sites checking crisis suppression and none checking
    /// the comfort mute, which is how a mute that nothing honoured survived.
    var isGamificationQuiet: Bool {
        safety.isGamificationSuppressed || celebrationsMuted
    }

    /// Ducks the focus music under Ace's voice. Wired by `PresenceCoordinator`
    /// so neither the music nor the voice has to know about the other.
    var onSpeakingChanged: ((Bool) -> Void)?

    // MARK: Economics

    /// Metering, entitlements and the paywall (Part 5). The paywall is off by
    /// default, so this behaves as Unlimited until the flag is flipped.
    let store: StoreController

    // MARK: Safety

    let safety: SafetyCoordinator

    // MARK: Session-scoped signals

    /// Behavioural evidence for the mood heuristics. Reset per session.
    var signals = BehaviourSignals()

    // MARK: Init

    /// `providers` is optional rather than defaulted: a default argument is
    /// evaluated at the *call site*, which may be nonisolated, and
    /// `ProviderController` is main-actor isolated. Building it inside the
    /// (isolated) initialiser keeps that correct.
    init(providers: ProviderController? = nil) {
        self.providers = providers ?? ProviderController()
        self.safety = SafetyCoordinator()
        self.store = StoreController()
    }

    /// Called once the profile is loaded, and again whenever it changes.
    ///
    /// Takes a plain value rather than the SwiftData `Profile` on purpose:
    /// `AppState` has no business knowing how the student is stored.
    func apply(_ settings: StudentSettings) {
        self.settings = settings
        store.hasOwnKey = providers.hasKey
        persona = VoiceRoster.persona(id: settings.voicePersonaID)
        prosody = persona.baseProsody
        safety.region = settings.supportRegion
        safety.studentName = settings.name
    }

    // MARK: Speaking

    /// Speak a line in Ace's current voice.
    ///
    /// Every spoken line goes through here rather than touching the provider
    /// directly, so mood-matched prosody and the speaking flag are applied
    /// exactly once, in one place.
    func say(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSpeaking = true
        onSpeakingChanged?(true)
        defer {
            isSpeaking = false
            onSpeakingChanged?(false)
        }

        // Duck the UI sound cues while Ace talks so they never collide.
        SoundCuePlayer.shared.gain = 0.35
        defer { SoundCuePlayer.shared.gain = 1.0 }

        try? await provider.speak(text, persona: persona, prosody: prosody)
    }

    /// Cut Ace off immediately. This is the barge-in path (§7).
    func stopSpeaking() async {
        await provider.stopSpeaking()
        isSpeaking = false
        onSpeakingChanged?(false)
        SoundCuePlayer.shared.gain = 1.0
    }

    /// Preview a persona without committing to it.
    func preview(_ candidate: VoicePersona) async {
        await stopSpeaking()
        isSpeaking = true
        defer { isSpeaking = false }
        try? await provider.speak(candidate.previewLine,
                                  persona: candidate,
                                  prosody: candidate.baseProsody)
    }

    // MARK: Mood

    /// Update the mood read and ease delivery toward it.
    ///
    /// In Live Mode this also re-configures the realtime session, so the model's
    /// own delivery and turn-taking follow how the student sounds (§9) — not
    /// just the local speech synthesiser's.
    func updateMood(text: String? = nil,
                    subject: Subject? = nil,
                    sourceText: String = "",
                    studentNote: String = "") async {
        let reading = await provider.readEmotion(audio: nil, text: text, signals: signals)
        let changed = reading != mood
        mood = reading

        // Ease on *every* read, not only when the label changes.
        //
        // `ProsodyMatcher.next` deliberately moves partway toward the target so
        // delivery slides rather than snaps (§9) — which means it has to be
        // called repeatedly to arrive. Returning early on an unchanged reading
        // meant it ran once per mood *change* and then froze roughly halfway
        // there, so voice matching was permanently weaker than designed.
        prosody = ProsodyMatcher.next(current: prosody, base: persona.baseProsody, reading: reading)

        // Re-sending the session config, on the other hand, only makes sense
        // when something actually changed — that's a network round trip.
        if changed, reading.isActionable {
            await providers.adapt(to: reading, settings: settings, subject: subject,
                                  sourceText: sourceText, studentNote: studentNote)
        }
    }

    /// Open the realtime session before the student needs it — the single
    /// biggest contributor to hitting the §7 latency budget.
    func prewarmVoice(subject: Subject?, sourceText: String, studentNote: String) async {
        _ = await providers.prewarmForSession(
            settings: settings, subject: subject,
            sourceText: sourceText, studentNote: studentNote, mood: mood
        )
    }

    func endVoiceSession() async {
        await providers.endSession()
        store.endSession()
    }

    /// Whether Live Mode may be used right now — the cap, when the paywall is on.
    var canUseRealtimeVoice: Bool { store.canUseRealtimeVoice }

    /// Reset per-session behavioural signals, and start metering.
    func beginSession() {
        store.beginSession(isLive: providerMode == .live)
        signals = BehaviourSignals()
        mood = .unknown
        prosody = persona.baseProsody
        celebrationsMuted = false
    }
}

// MARK: - Safety coordinator

/// Owns the crisis net's *state*: what was detected, and what the UI must show.
///
/// Detection itself lives in `CrisisSafetyService` (pure, unit-tested). This
/// class is the thin bridge between that and SwiftUI, and it is the only thing
/// screens need to talk to.
@MainActor
@Observable
final class SafetyCoordinator {

    private let service = CrisisSafetyService()

    /// Where to point the student for help. Set from the profile.
    var region: SupportRegion = SupportRegion.fromDeviceRegion(Locale.current.region?.identifier)
    var studentName: String = ""

    /// The full-screen crisis response, when one is active. While this is
    /// non-nil the app must show nothing else.
    private(set) var crisisResponse: CrisisResponse?

    /// The inline, lower-key response for `.concern` signals.
    private(set) var concernResponse: CrisisResponse?

    /// True whenever XP, streaks, quizzes and celebration must be suppressed.
    /// Every gamification call site checks this.
    private(set) var isGamificationSuppressed = false

    /// Check a piece of free text or a voice transcript.
    ///
    /// Returns true when the text triggered *something*, so the caller can skip
    /// whatever it was about to do (send the message to the tutor, award XP,
    /// advance the quiz) and let the safety surface take over.
    @discardableResult
    func check(_ text: String) -> Bool {
        let signal = service.evaluate(text)
        guard let response = CrisisResponder.response(for: signal,
                                                      region: region,
                                                      studentName: studentName) else {
            return false
        }

        isGamificationSuppressed = true

        if response.requiresFullScreen {
            // Kill every non-essential sound and haptic. A celebration chime in
            // this moment would be unforgivable.
            Feedback.setMuted(true)
            crisisResponse = response
        } else {
            concernResponse = response
        }
        return true
    }

    /// The student said they're okay. We take them at their word and return the
    /// app to normal — but never automatically, and never on a timer.
    func acknowledgeCrisis() {
        crisisResponse = nil
        Feedback.setMuted(false)
        // Gamification stays suppressed for the rest of the session. Going
        // straight back to "🔥 4 day streak!" after that conversation would be
        // grotesque.
    }

    func dismissConcern() {
        concernResponse = nil
    }

    /// Clear suppression. Called when a *new* session starts, never mid-session.
    func beginFreshSession() {
        isGamificationSuppressed = false
        concernResponse = nil
    }
}
