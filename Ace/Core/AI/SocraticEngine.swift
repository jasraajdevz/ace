//
//  SocraticEngine.swift
//  Ace
//
//  Ace's teaching brain in Demo Mode.
//
//  The signature behaviour from §3 and §10: guide with questions and hints, one
//  step at a time, and reveal the full solution only after the student has
//  attempted it or explicitly asked. This engine encodes that as a ladder:
//
//      rung 0 — orient      "what's the question actually asking?"
//      rung 1 — narrow      point at the part of the source that matters
//      rung 2 — shape       give the shape of the answer, not the answer
//      rung 3 — nearly      the definition without the label
//      rung 4 — reveal      the answer, with the reasoning
//
//  A student climbs one rung per attempt. Saying "just tell me" jumps straight
//  to rung 4 — because refusing a direct request is not teaching, it's
//  stonewalling, and it's the fastest way to make someone close the app.
//
//  Part 3 swaps this for the realtime model, which gets the same ladder as
//  instructions. Keeping the rule here — in testable, provider-free code —
//  means the teaching behaviour can't silently change when the provider does.
//

import Foundation

/// One rung of the ladder.
enum SocraticRung: Int, Sendable, CaseIterable, Comparable {
    case orient = 0
    case narrow = 1
    case shape = 2
    case nearly = 3
    case reveal = 4

    static func < (lhs: SocraticRung, rhs: SocraticRung) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// True when the answer itself may appear in the reply.
    var revealsAnswer: Bool { self == .reveal }
}

/// What the tutor decided to say and why.
struct SocraticReply: Sendable, Equatable {
    var text: String
    var rung: SocraticRung
    /// True when this was a hint rather than an answer — the UI styles it
    /// differently and the session counts it.
    var isHint: Bool { !rung.revealsAnswer }
}

enum SocraticEngine {

    /// Phrases that mean "stop teaching, just give it to me". Honouring these
    /// is a feature.
    private static let surrenderPhrases = [
        "just tell me", "tell me the answer", "give me the answer", "what's the answer",
        "what is the answer", "i give up", "show me the answer", "just show me",
        "stop asking", "i don't want a hint", "skip it", "reveal"
    ]

    /// Does the student's message ask for the answer outright?
    static func isAskingForAnswer(_ message: String) -> Bool {
        let lower = message.lowercased()
        return surrenderPhrases.contains { lower.contains($0) }
    }

    /// Which rung to speak from.
    ///
    /// - `attemptCount` is how many times they've had a go at this question.
    /// - An explicit request jumps to `.reveal` regardless.
    static func rung(attemptCount: Int, askedForAnswer: Bool, mood: Mood) -> SocraticRung {
        if askedForAnswer { return .reveal }

        // A frustrated or low student climbs faster. Making someone who is
        // already struggling work through four rungs is not Socratic, it's
        // cruel.
        let acceleration = mood.wantsGentleness ? 1 : 0
        let raw = min(attemptCount + acceleration, SocraticRung.allCases.count - 1)
        return SocraticRung(rawValue: max(0, raw)) ?? .orient
    }

    /// Build a reply for a quiz question the student is stuck on.
    ///
    /// `hints` come from the generated question, so the wording is grounded in
    /// the student's own material rather than invented.
    static func reply(for question: QuizQuestion,
                      attemptCount: Int,
                      askedForAnswer: Bool,
                      mood: Mood,
                      gradeLevel: GradeLevel) -> SocraticReply {
        let rung = rung(attemptCount: attemptCount, askedForAnswer: askedForAnswer, mood: mood)
        let opener = self.opener(for: mood, rung: rung)

        switch rung {
        case .orient:
            return SocraticReply(
                text: "\(opener) Before you answer — say back what the question is actually asking. What's it looking for?",
                rung: rung
            )
        case .narrow:
            let hint = question.hints.first ?? "Look at the sentence it came from."
            return SocraticReply(text: "\(opener) \(hint) What do you notice?", rung: rung)
        case .shape:
            let hint = question.hints.count > 1 ? question.hints[1] : "Think about the shape of the answer."
            return SocraticReply(text: "\(opener) \(hint) Which option fits that?", rung: rung)
        case .nearly:
            let hint = question.hints.count > 2 ? question.hints[2] : "You're close."
            return SocraticReply(text: "\(opener) \(hint) Go with your gut.", rung: rung)
        case .reveal:
            let answer = question.correctAnswer
            let because = question.explanation
            return SocraticReply(
                text: "It's \(answer). \(because) \(closer(for: gradeLevel))",
                rung: rung
            )
        }
    }

    /// Response to an answer the student gave.
    static func feedback(correct: Bool,
                         question: QuizQuestion,
                         attemptCount: Int,
                         mood: Mood,
                         streak: Int) -> SocraticReply {
        if correct {
            let praise: String
            switch streak {
            case 0, 1: praise = "That's it."
            case 2: praise = "Two for two."
            case 3...4: praise = "\(streak) in a row — you've got the pattern."
            default: praise = "\(streak) straight. You're rolling."
            }
            // Even on a correct answer we ask for the reasoning. Getting it
            // right by elimination and getting it right by understanding look
            // identical on a multiple-choice question.
            let probe = attemptCount == 0 && streak >= 2
                ? " Say why in one sentence — I want to hear the reasoning."
                : ""
            return SocraticReply(text: praise + probe, rung: .reveal)
        }

        // Wrong. Never lead with the mistake.
        let softener: String
        switch mood {
        case .frustrated, .low:
            softener = "Not that one — and this is a genuinely awkward question."
        case .confused:
            softener = "Not quite. Let's back up a step."
        default:
            softener = "Not that one. Good instinct though —"
        }
        return SocraticReply(text: "\(softener) have another look.", rung: .orient)
    }

    // MARK: - Voice

    /// The opening beat, matched to mood (§9). Small thing, big difference —
    /// the same hint lands completely differently after "Okay, deep breath"
    /// versus "Right, next!".
    private static func opener(for mood: Mood, rung: SocraticRung) -> String {
        switch mood {
        case .energized:
            return ["Right —", "Okay, quick one.", "Let's go."].rotating(rung.rawValue)
        case .focused, .neutral:
            return ["Okay.", "Alright.", "Right."].rotating(rung.rawValue)
        case .confused:
            return ["No stress — let's slow this down.", "Okay, smaller step.", "Let's take this apart."].rotating(rung.rawValue)
        case .frustrated:
            return ["Deep breath — this one's fiddly.", "Okay, forget the question for a second.", "Nearly there, honestly."].rotating(rung.rawValue)
        case .low:
            return ["Hey — no rush at all.", "We can take this slowly.", "One small piece."].rotating(rung.rawValue)
        case .distracted:
            return ["Back with me?", "Okay — right here.", "Quick one."].rotating(rung.rawValue)
        }
    }

    /// The line after a reveal. Keeps the door open instead of closing the loop.
    private static func closer(for gradeLevel: GradeLevel) -> String {
        switch gradeLevel.band {
        case .elementary, .middle:
            return "Want to try the next one, or should I ask you this one again later?"
        case .high, .college:
            return "Worth re-deriving it yourself before the next question — that's what makes it stick."
        }
    }
}

private extension Array where Element == String {
    /// Pick deterministically by index so the same situation reads the same way
    /// twice, but consecutive rungs don't repeat the same opener.
    func rotating(_ index: Int) -> String {
        isEmpty ? "" : self[((index % count) + count) % count]
    }
}
