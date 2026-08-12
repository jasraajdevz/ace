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

    /// The live AI provider. Swapping this is how Demo → Live works, and
    /// nothing above this line needs to know it happened.
    private(set) var provider: AIProvider

    var providerMode: AIProviderMode { provider.mode }

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

    // MARK: Safety

    let safety: SafetyCoordinator

    // MARK: Session-scoped signals

    /// Behavioural evidence for the mood heuristics. Reset per session.
    var signals = BehaviourSignals()

    // MARK: Init

    init(provider: AIProvider = MockAIProvider()) {
        self.provider = provider
        self.safety = SafetyCoordinator()
    }

    /// Called once the profile is loaded, and again whenever it changes.
    ///
    /// Takes a plain value rather than the SwiftData `Profile` on purpose:
    /// `AppState` has no business knowing how the student is stored.
    func apply(_ settings: StudentSettings) {
        self.settings = settings
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
        defer { isSpeaking = false }

        // Duck the UI sound cues while Ace talks so they never collide.
        SoundCuePlayer.shared.gain = 0.35
        defer { SoundCuePlayer.shared.gain = 1.0 }

        try? await provider.speak(text, persona: persona, prosody: prosody)
    }

    /// Cut Ace off immediately. This is the barge-in path (§7).
    func stopSpeaking() async {
        await provider.stopSpeaking()
        isSpeaking = false
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
    func updateMood(text: String? = nil) async {
        let reading = await provider.readEmotion(audio: nil, text: text, signals: signals)
        mood = reading
        prosody = ProsodyMatcher.next(current: prosody, base: persona.baseProsody, reading: reading)
    }

    /// Reset per-session behavioural signals.
    func beginSession() {
        signals = BehaviourSignals()
        mood = .unknown
        prosody = persona.baseProsody
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
