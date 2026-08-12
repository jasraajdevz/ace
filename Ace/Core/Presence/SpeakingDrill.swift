//
//  SpeakingDrill.swift
//  Ace
//
//  "Explain it to me out loud."
//
//  The single most reliable way to find out whether you actually understand
//  something is to try to say it. This scores an attempt on three axes and,
//  crucially, names *one* thing to fix — a list of six weaknesses is a list
//  nobody acts on.
//
//    • **Clarity**    — did they use the real terms, in sentences that hold
//                       together, without drowning in filler?
//    • **Structure**  — is there an order? A definition, then a mechanism, then
//                       a consequence beats three facts in a heap.
//    • **Confidence** — hedging and hesitation, from both the words and (in
//                       Live Mode) the voice.
//
//  Everything is computed from the transcript plus the acoustic features already
//  extracted for voice matching, so this works identically keyless and live —
//  the voice features simply sharpen the confidence score when available.
//

import Foundation

/// One scored attempt at explaining something.
struct SpeakingScore: Sendable, Equatable, Codable {
    /// 0...1 each.
    var clarity: Double
    var structure: Double
    var confidence: Double

    /// The headline number, 0...100. Weighted toward clarity because that's
    /// what actually indicates understanding; confidence is the softest signal
    /// and is weighted least.
    var overall: Int {
        Int(((clarity * 0.45 + structure * 0.35 + confidence * 0.20) * 100).rounded())
    }

    var band: Band {
        switch overall {
        case 80...: .strong
        case 60..<80: .solid
        case 38..<60: .developing
        default: .early
        }
    }

    enum Band: String, Sendable, Codable {
        case early, developing, solid, strong

        var headline: String {
            switch self {
            case .strong: "You know this one."
            case .solid: "That held together well."
            case .developing: "The idea's there — the words aren't yet."
            case .early: "Good — saying it badly is how you find the gaps."
            }
        }
    }

    static let zero = SpeakingScore(clarity: 0, structure: 0, confidence: 0)
}

/// The full result: score, the one thing to work on, and what went well.
struct SpeakingFeedback: Sendable, Equatable {
    var score: SpeakingScore
    /// What they did well. Always present — feedback that opens with a
    /// criticism gets heard as "that was bad" and nothing after it lands.
    var strength: String
    /// The single most useful improvement.
    var focus: String
    /// Terms from the material they never mentioned.
    var missedTerms: [String]
    /// Seconds spoken.
    var duration: TimeInterval

    var isTooShort: Bool { duration < 8 }
}

enum SpeakingDrillScorer {

    /// Words that add nothing. A few are fine; a lot means thinking out loud
    /// rather than explaining.
    private static let fillers: Set<String> = [
        "um", "uh", "erm", "like", "basically", "literally", "actually",
        "just", "kind", "sort", "stuff", "things", "whatever", "yeah",
        "okay", "right", "anyway", "obviously"
    ]

    /// Hedges. One is honest; five is someone who doesn't believe themselves.
    private static let hedges: Set<String> = [
        "maybe", "probably", "possibly", "perhaps", "guess", "think",
        "might", "somewhat", "somehow", "unsure", "dunno", "suppose"
    ]

    /// Connectives that show an argument being built rather than recited.
    private static let structureMarkers: Set<String> = [
        "first", "firstly", "then", "next", "after", "finally", "lastly",
        "because", "since", "therefore", "so", "which", "means", "causes",
        "results", "leads", "why", "however", "whereas", "unlike", "whereas",
        "example", "instance", "starts", "begins", "ends"
    ]

    /// Score an explanation.
    ///
    /// - Parameters:
    ///   - transcript: what they said.
    ///   - sourceText: the material, for the terms they should have reached for.
    ///   - voice: acoustic features, when Live Mode had the microphone.
    ///   - duration: seconds spoken.
    static func score(transcript: String,
                      sourceText: String,
                      voice: VoiceReading = .none,
                      duration: TimeInterval) -> SpeakingFeedback {

        let words = TextAnalysis.words(in: transcript)
        let sentences = TextAnalysis.sentences(in: transcript)
        let keyTerms = TextAnalysis.keyTerms(in: sourceText, limit: 12)

        // Nothing to score.
        guard words.count >= 8 else {
            return SpeakingFeedback(
                score: .zero,
                strength: "You started, which is the hard bit.",
                focus: "Have another go and keep talking for at least twenty seconds — even if it comes out messy. Messy is fine; short tells me nothing.",
                missedTerms: keyTerms.prefix(3).map(\.term),
                duration: duration
            )
        }

        // --- Clarity -------------------------------------------------------
        // Did they reach for the material's own vocabulary, and did they get
        // there without wading through filler?
        let mentioned = keyTerms.filter { term in
            transcript.range(of: term.term, options: .caseInsensitive) != nil
        }
        let termCoverage = keyTerms.isEmpty
            ? 0.6                                   // no terms to hit — don't punish
            : min(Double(mentioned.count) / Double(min(keyTerms.count, 5)), 1)

        let fillerCount = words.filter { fillers.contains($0) }.count
        let fillerRatio = Double(fillerCount) / Double(words.count)
        let fillerPenalty = min(fillerRatio * 3.5, 0.5)

        // Very short sentences read as a list; very long ones as a ramble.
        let meanSentenceWords = sentences.isEmpty
            ? Double(words.count)
            : Double(words.count) / Double(sentences.count)
        let lengthFit = 1 - min(abs(meanSentenceWords - 15) / 22, 0.7)

        let clarity = clamp(termCoverage * 0.6 + lengthFit * 0.4 - fillerPenalty)

        // --- Structure ------------------------------------------------------
        let markerCount = words.filter { structureMarkers.contains($0) }.count
        // Roughly one connective per sentence is a well-built explanation.
        let markerScore = min(Double(markerCount) / max(Double(sentences.count), 2), 1)

        // Did they define before describing? Openers like "X is…" are the
        // signature of an explanation that starts in the right place.
        let opensWithDefinition = TextAnalysis.definitions(in: sentences.first ?? "") != nil
        let hasMultipleSentences = sentences.count >= 2

        let structure = clamp(
            markerScore * 0.55
            + (opensWithDefinition ? 0.25 : 0)
            + (hasMultipleSentences ? 0.20 : 0)
        )

        // --- Confidence -------------------------------------------------------
        let hedgeCount = words.filter { hedges.contains($0) }.count
        let hedgeRatio = Double(hedgeCount) / Double(words.count)
        var confidence = clamp(1 - hedgeRatio * 6)

        // Sound sharpens it, when we heard them.
        if voice.isReliable {
            confidence = clamp(confidence * 0.65
                               + (1 - min(voice.hesitation * 1.6, 1)) * 0.35)
        }
        // Trailing off is its own tell.
        if transcript.trimmed.hasSuffix("...") || transcript.trimmed.hasSuffix("…") {
            confidence = clamp(confidence - 0.1)
        }

        let score = SpeakingScore(clarity: clarity, structure: structure, confidence: confidence)
        let missed = keyTerms
            .filter { term in transcript.range(of: term.term, options: .caseInsensitive) == nil }
            .prefix(3)
            .map(\.term)

        return SpeakingFeedback(
            score: score,
            strength: strength(for: score, mentionedCount: mentioned.count),
            focus: focus(for: score, missed: Array(missed), fillerRatio: fillerRatio,
                         hedgeRatio: hedgeRatio, sentenceCount: sentences.count),
            missedTerms: Array(missed),
            duration: duration
        )
    }

    // MARK: - Feedback

    /// Name something real. Generic praise is worse than none.
    private static func strength(for score: SpeakingScore, mentionedCount: Int) -> String {
        let best = max(score.clarity, max(score.structure, score.confidence))

        if best == score.clarity && mentionedCount > 0 {
            return "You used the actual vocabulary — that's the part most people skip."
        }
        if best == score.structure {
            return "It had a shape: you took me through it in order rather than listing facts."
        }
        if best == score.confidence {
            return "You said it like you meant it, which counts for more than it sounds like."
        }
        return "You got through it without stopping. That's the hard part."
    }

    /// The one thing to fix — whichever axis is weakest, made concrete.
    private static func focus(for score: SpeakingScore,
                              missed: [String],
                              fillerRatio: Double,
                              hedgeRatio: Double,
                              sentenceCount: Int) -> String {

        let weakest = min(score.clarity, min(score.structure, score.confidence))

        if weakest == score.clarity {
            if !missed.isEmpty {
                let list = missed.joined(separator: ", ")
                return "You never said \(list). Go again and build the explanation around \(missed[0]) — if you can't use the word, you don't own it yet."
            }
            if fillerRatio > 0.12 {
                return "There's a lot of “like” and “basically” in there. Say it again slower, and let the pauses be silent — silence sounds far more certain than filler."
            }
            return "Tighten the sentences. One idea each, and stop when the idea's finished."
        }

        if weakest == score.structure {
            if sentenceCount <= 1 {
                return "It came out as one long sentence. Try it as three: what it is, how it works, why it matters."
            }
            return "Add the joins. “Because”, “which means”, “so” — those words are the difference between knowing facts and understanding something."
        }

        if hedgeRatio > 0.08 {
            return "You hedged a lot — “I think”, “maybe”, “sort of”. Say the next one as a flat statement, even if you're not sure. You'll spot the wrong bits far faster."
        }
        return "Say it once more without pausing to check yourself. It's more solid than it feels."
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Progress over time

/// Tracks whether speaking is getting better (§Part 4: "tracks improvement over
/// time"). Comparing the recent few against the earlier few is more honest than
/// last-vs-first, which turns one good day into "improving".
struct SpeakingHistory: Sendable, Equatable {
    private(set) var scores: [SpeakingScore] = []

    init(scores: [SpeakingScore] = []) { self.scores = scores }

    mutating func record(_ score: SpeakingScore) {
        scores.append(score)
        if scores.count > 40 { scores.removeFirst(scores.count - 40) }
    }

    var attempts: Int { scores.count }
    var latest: SpeakingScore? { scores.last }

    var best: SpeakingScore? {
        scores.max { $0.overall < $1.overall }
    }

    /// Change in the average overall score, recent versus earlier.
    /// Nil until there are enough attempts to say anything honest.
    var trend: Int? {
        guard scores.count >= 4 else { return nil }
        let split = scores.count / 2
        let earlier = scores.prefix(split)
        let recent = scores.suffix(scores.count - split)
        let earlierMean = earlier.map(\.overall).reduce(0, +) / max(earlier.count, 1)
        let recentMean = recent.map(\.overall).reduce(0, +) / max(recent.count, 1)
        return recentMean - earlierMean
    }

    /// The line shown on the drill screen.
    var trendSummary: String {
        guard let trend else {
            return attempts == 0
                ? "First time explaining this out loud."
                : "\(attempts) attempt\(attempts == 1 ? "" : "s") so far — a couple more and I can tell you if it's improving."
        }
        switch trend {
        case 6...: return "Clearly better than when you started — up \(trend) points."
        case 2..<6: return "Creeping up. \(trend) points better than your early attempts."
        case -2...1: return "Holding steady. Consistency is its own result."
        default: return "A bit below your earlier attempts — often just tiredness. Worth another go tomorrow."
        }
    }
}
