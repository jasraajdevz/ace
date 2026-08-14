//
//  MoodHeuristics.swift
//  Ace
//
//  Reading the student without a model (§5, §9).
//
//  In Demo Mode there is no audio-emotion API, so Ace infers mood from what it
//  can measure locally: how they're doing, how fast they answer, how long they
//  pause, whether they keep leaving, and what they type. That turns out to be a
//  surprisingly good signal — a student on a five-answer streak answering in two
//  seconds is *visibly* different from one who's been staring at question three
//  for ninety seconds and has taken two hints.
//
//  Everything here is pure and deterministic, so it can be unit-tested, and
//  everything stays on the device.
//

import Foundation

enum MoodHeuristics {

    /// Latency above this suggests the student is stuck rather than thinking.
    static let stuckLatency: TimeInterval = 25
    /// Below this they're moving fast and confidently.
    static let fastLatency: TimeInterval = 6
    /// Idle beyond this means their attention has gone elsewhere.
    static let idleThreshold: TimeInterval = 75

    /// Words that carry mood when a student types them. Kept short and obvious —
    /// this is a nudge on top of the behavioural signal, not a sentiment model.
    private static let frustrationWords = [
        "ugh", "argh", "wtf", "stupid", "hate this", "makes no sense", "i give up",
        "this sucks", "confusing", "annoying", "impossible", "why is this"
    ]
    private static let confusionWords = [
        "i don't get", "i dont get", "i don't understand", "i dont understand",
        "what does", "how does", "i'm lost", "im lost", "no idea", "not sure",
        "can you explain", "wait what", "huh"
    ]
    private static let lowWords = [
        "tired", "exhausted", "can't focus", "cant focus", "overwhelmed",
        "too much", "behind", "failing", "stressed", "anxious", "worried",
        "alone", "sad", "crying"
    ]
    private static let energyWords = [
        "let's go", "lets go", "got it", "easy", "yes!", "nice", "i knew it",
        "next one", "keep going", "more", "ready"
    ]

    /// The main entry point. Behavioural signals dominate; text only nudges.
    static func read(signals: BehaviourSignals, text: String?) -> MoodReading {
        // 1. Distraction beats everything — if they're not here, nothing else
        //    we measured is current.
        if signals.idleSeconds > idleThreshold {
            return MoodReading(
                mood: .distracted,
                confidence: min(0.55 + signals.idleSeconds / 300, 0.95),
                rationale: "idle \(Int(signals.idleSeconds))s"
            )
        }
        if signals.appExits >= 2 && signals.idleSeconds > 20 {
            return MoodReading(mood: .distracted, confidence: 0.7,
                               rationale: "\(signals.appExits) app exits")
        }

        // 2. Explicit words the student typed.
        if let text, !text.isEmpty {
            let lower = text.lowercased()
            if let hit = lowWords.first(where: { lower.contains($0) }) {
                return MoodReading(mood: .low, confidence: 0.7, rationale: "said “\(hit)”")
            }
            if let hit = frustrationWords.first(where: { lower.contains($0) }) {
                return MoodReading(mood: .frustrated, confidence: 0.75, rationale: "said “\(hit)”")
            }
            if let hit = confusionWords.first(where: { lower.contains($0) }) {
                return MoodReading(mood: .confused, confidence: 0.7, rationale: "said “\(hit)”")
            }
            if let hit = energyWords.first(where: { lower.contains($0) }) {
                return MoodReading(mood: .energized, confidence: 0.6, rationale: "said “\(hit)”")
            }
        }

        // 3. Performance. A wrong streak plus slow answers is the classic
        //    struggle signature; it escalates from confused to frustrated.
        if signals.wrongStreak >= 3 {
            return MoodReading(
                mood: .frustrated,
                confidence: min(0.6 + Double(signals.wrongStreak - 3) * 0.1, 0.9),
                rationale: "\(signals.wrongStreak) wrong in a row"
            )
        }
        if signals.wrongStreak == 2 || signals.hintsTaken >= 2 {
            return MoodReading(mood: .confused, confidence: 0.65,
                               rationale: "\(signals.wrongStreak) wrong, \(signals.hintsTaken) hints")
        }
        if signals.lastResponseLatency > stuckLatency && signals.wrongStreak >= 1 {
            return MoodReading(mood: .confused, confidence: 0.6,
                               rationale: "slow answer after a miss")
        }

        // 4. Rolling.
        if signals.correctStreak >= 3 {
            return MoodReading(
                mood: .energized,
                confidence: min(0.6 + Double(signals.correctStreak - 3) * 0.08, 0.9),
                rationale: "\(signals.correctStreak) correct in a row"
            )
        }
        if signals.correctStreak >= 1 && signals.lastResponseLatency > 0
            && signals.lastResponseLatency < fastLatency {
            return MoodReading(mood: .focused, confidence: 0.55, rationale: "fast and correct")
        }

        // 5. Nothing decisive. Say so honestly rather than guessing — a
        //    low-confidence reading is ignored by the prosody matcher.
        return MoodReading(mood: .neutral, confidence: 0.3, rationale: "no strong signal")
    }

}
