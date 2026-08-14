//
//  FocusMode.swift
//  Ace
//
//  Do Not Disturb, and the music underneath it.
//
//  The DND requirement in §10 is unusually specific and worth reading twice:
//  *"It quiets the world; it never blocks the app or the studying."* So this is
//  the opposite of a screen-time lock. Everything it does is subtractive — it
//  removes noise. There is no state in this file that can prevent any action,
//  and there's a test that proves it by asserting every capability stays
//  available in every mode.
//
//  The music is generated rather than shipped: see `AmbientScore`.
//

import Foundation

// MARK: - Do Not Disturb

/// What Do Not Disturb turns off.
///
/// Each flag removes a source of noise. None of them removes a capability —
/// that distinction is the entire point.
struct DoNotDisturbState: Sendable, Equatable, Codable {

    /// Ace's own non-essential lines: milestone check-ins, XP toasts, nudges
    /// that aren't about being stuck.
    var quietsAceChatter: Bool = true
    /// UI sound cues and haptics.
    var quietsFeedback: Bool = true
    /// Drops the animated background and celebration particles, and desaturates
    /// the palette. A low-stimulation surface (§Part 4).
    var calmsInterface: Bool = true
    /// Asks the system to suppress notifications while a session is running.

    var isOn: Bool = false

    static let off = DoNotDisturbState(isOn: false)
    static let on = DoNotDisturbState(isOn: true)

    /// Everything the student can still do. Every entry is `true`, always —
    /// this exists so the guarantee is checkable rather than aspirational.
    var capabilities: [String: Bool] {
        [
            "study": true,
            "startSession": true,
            "answerQuestions": true,
            "reviewFlashcards": true,
            "talkToAce": true,
            "captureMaterial": true,
            "openSettings": true,
            "leaveTheApp": true,
            "turnDNDOff": true
        ]
    }

    /// Whether a given message should be shown while DND is on.
    ///
    /// The exceptions are the point: anything from the safety net, and anything
    /// that's a direct answer to something the student asked, always gets
    /// through. Quieting the world must never quiet the one message that matters.
    func allows(_ kind: MessageImportance) -> Bool {
        guard isOn, quietsAceChatter else { return true }
        switch kind {
        case .safety, .directReply: return true
        case .ambient, .celebration, .nudge: return false
        }
    }

    /// What the toggle says it will do — written so nobody has to guess.
    var explanation: String {
        isOn
            ? "Notifications quieted, sounds off, animation dialled down. Everything still works — nothing is locked."
            : "One tap quiets notifications, sounds and Ace's small talk. It never stops you studying."
    }
}

/// How important a message is, for DND filtering.
enum MessageImportance: Sendable, Equatable {
    /// The crisis net. Always shown, in every mode, no exceptions (§10).
    case safety
    /// A direct answer to something the student just did or asked.
    case directReply
    /// A body-double check-in.
    case ambient
    /// XP, level-ups, streaks.
    case celebration
    /// A Guardian intervention.
    case nudge
}

// MARK: - Focus music

/// The generated ambience tracks.
///
/// Nothing is shipped as an audio file. Each scene is a procedural score
/// (`AmbientScore`) rendered live, which means: no licensing question at all,
/// no megabytes in the bundle, and no loop seam — the music genuinely never
/// repeats, which is the thing that makes looped study music grating after
/// twenty minutes.
enum FocusScene: String, Sendable, CaseIterable, Codable, Identifiable {
    case off
    case drift
    case rain
    case pulse
    case warmth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "None"
        case .drift: "Drift"
        case .rain: "Rain"
        case .pulse: "Pulse"
        case .warmth: "Warmth"
        }
    }

    var detail: String {
        switch self {
        case .off: "Silence"
        case .drift: "Slow pads, no rhythm. The quietest one."
        case .rain: "Soft rain and a low hum."
        case .pulse: "A gentle beat to work to."
        case .warmth: "Low, warm chords. Good late at night."
        }
    }

    var symbolName: String {
        switch self {
        case .off: "speaker.slash"
        case .drift: "wind"
        case .rain: "cloud.rain"
        case .pulse: "waveform.path"
        case .warmth: "flame"
        }
    }
}

/// Volume policy for the music.
///
/// The requirement is that music ducks under Ace's voice and *keeps playing
/// through quizzes* — stopping it at every screen change would be worse than
/// not having it.
struct MusicMix: Sendable, Equatable {
    /// What the student set, 0...1.
    var userVolume: Double = 0.35
    /// True while Ace is speaking.
    var isDucking: Bool = false

    /// How far down the music goes under speech. Deep enough that words are
    /// clearly on top, shallow enough that the music doesn't vanish and
    /// reappear — a music bed that disappears entirely is more distracting
    /// than one that dips.
    static let duckFactor: Double = 0.22

    /// The gain to actually apply.
    var effectiveVolume: Double {
        let base = min(max(userVolume, 0), 1)
        return isDucking ? base * Self.duckFactor : base
    }

    /// Ramp time, seconds. Ducking fast and recovering slowly is what makes it
    /// unnoticeable; the reverse sounds like a broken radio.
    var rampDuration: TimeInterval { isDucking ? 0.12 : 0.55 }
}

// MARK: - The score

/// Generates the note events for a scene.
///
/// Pure and deterministic given a seed, so the music is testable — which sounds
/// odd until you consider the ways generated audio goes wrong: notes outside the
/// scale, everything landing on the same beat, density creeping up until it's no
/// longer background. All of that is checkable arithmetic.
struct AmbientScore: Sendable {

    /// One note to play.
    struct Event: Sendable, Equatable {
        /// Seconds from the start of the window.
        var time: TimeInterval
        /// Hz.
        var frequency: Double
        /// Seconds.
        var duration: TimeInterval
        /// 0...1.
        var gain: Double
        /// Softer attack for pads, sharper for the pulse.
        var attack: TimeInterval
    }

    let scene: FocusScene

    /// A pentatonic minor scale. There is no wrong note in a pentatonic scale,
    /// which is exactly what generative background music needs: any combination
    /// the generator lands on is consonant.
    private static let semitones = [0, 3, 5, 7, 10]
    /// Root, low enough to sit under speech rather than compete with it.
    private static let rootHz: Double = 110      // A2

    init(scene: FocusScene) { self.scene = scene }

    /// Frequency of a scale degree, `octave` octaves up.
    static func frequency(degree: Int, octave: Int) -> Double {
        let index = ((degree % semitones.count) + semitones.count) % semitones.count
        let semitone = semitones[index] + 12 * octave
        return rootHz * pow(2, Double(semitone) / 12)
    }

    /// Build the events for one window of music.
    ///
    /// Called repeatedly with an advancing seed, so the piece keeps evolving and
    /// never loops.
    func events(windowSeconds: TimeInterval, seed: UInt64) -> [Event] {
        var generator = SeededGenerator(seed: seed)
        guard scene != .off else { return [] }

        switch scene {
        case .off:
            return []

        case .drift:
            // Long overlapping pads. Sparse: roughly one new note every 4s.
            return pad(count: Int(windowSeconds / 4), window: windowSeconds,
                       octaveRange: 1...2, durationRange: 6...11,
                       gain: 0.16, attack: 1.6, generator: &generator)

        case .warmth:
            // Lower and denser than drift, with a fatter attack.
            return pad(count: Int(windowSeconds / 3), window: windowSeconds,
                       octaveRange: 0...1, durationRange: 7...13,
                       gain: 0.19, attack: 2.2, generator: &generator)

        case .rain:
            // The noise bed is synthesised separately; this adds an occasional
            // low tone so it isn't just hiss.
            return pad(count: max(1, Int(windowSeconds / 9)), window: windowSeconds,
                       octaveRange: 0...1, durationRange: 8...14,
                       gain: 0.10, attack: 3.0, generator: &generator)

        case .pulse:
            // A steady beat plus a sustaining pad underneath.
            var out: [Event] = []
            let beat: TimeInterval = 0.75          // 80bpm — under a resting heart rate
            var time: TimeInterval = 0
            while time < windowSeconds {
                let degree = Int.random(in: 0..<Self.semitones.count, using: &generator)
                out.append(Event(time: time,
                                 frequency: Self.frequency(degree: degree, octave: 2),
                                 duration: 0.28, gain: 0.11, attack: 0.008))
                time += beat
            }
            out += pad(count: Int(windowSeconds / 6), window: windowSeconds,
                       octaveRange: 0...1, durationRange: 5...9,
                       gain: 0.14, attack: 1.4, generator: &generator)
            return out.sorted { $0.time < $1.time }
        }
    }

    private func pad(count: Int,
                     window: TimeInterval,
                     octaveRange: ClosedRange<Int>,
                     durationRange: ClosedRange<Double>,
                     gain: Double,
                     attack: TimeInterval,
                     generator: inout SeededGenerator) -> [Event] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            // Spread across the window with jitter, so notes don't land on a
            // grid — a grid is audible and makes ambient music sound mechanical.
            let slot = window * Double(index) / Double(count)
            let jitter = Double.random(in: -0.4...0.4, using: &generator)
            return Event(
                time: max(0, min(slot + jitter, window)),
                frequency: Self.frequency(
                    degree: Int.random(in: 0..<Self.semitones.count, using: &generator),
                    octave: Int.random(in: octaveRange, using: &generator)
                ),
                duration: Double.random(in: durationRange, using: &generator),
                gain: gain,
                attack: attack
            )
        }.sorted { $0.time < $1.time }
    }
}
