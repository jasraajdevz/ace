//
//  Guardian.swift
//  Ace
//
//  Noticing when it's going wrong, and doing something proportionate about it
//  (§3, Part 4).
//
//  Two halves:
//    • **Struggle-help** — wrong-answer streaks, long silences, a frustrated
//      tone. Ace re-explains, drops the difficulty, or suggests a break.
//    • **Focus-guard** — idle time and leaving the app. Ace greets the return
//      and points back at the work.
//
//  The rule that shapes every line of this file, from §10: **nudge, never
//  cage.** Nothing here blocks anything. There is no lockout, no timer you can't
//  skip, no "you can't leave until". Every intervention is a sentence the
//  student can ignore, and ignoring it has no consequence.
//
//  The second rule is restraint. "Smart thresholds, not paranoid" — an app that
//  asks if you're okay after every wrong answer gets muted within a day. So each
//  intervention has a cooldown, escalates rather than repeating, and gives up
//  rather than nagging.
//

import Foundation

// MARK: - What Ace can do about it

/// The Guardian's response, in escalating order of intervention.
enum GuardianAction: Sendable, Equatable {
    /// Nothing to do. By far the most common answer.
    case none
    /// Offer a hint on the current thing.
    case offerHint
    /// Explain it a different way.
    case reexplain
    /// Move to easier material for a bit.
    case easeOff
    /// Suggest stopping for five minutes.
    case suggestBreak
    /// They left and came back.
    case welcomeBack
    /// They've gone quiet for a while.
    case checkIn

    /// How intrusive this is, for cooldown purposes.
    var weight: Int {
        switch self {
        case .none: 0
        case .offerHint, .checkIn: 1
        case .reexplain, .welcomeBack: 2
        case .easeOff: 3
        case .suggestBreak: 4
        }
    }
}

/// A Guardian intervention: what to do and what to say.
struct GuardianNudge: Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var action: GuardianAction
    var message: String
    /// The label on the accept button. Always optional to take.
    var acceptTitle: String
    /// True when Ace should say this out loud rather than only show it.
    var isSpoken: Bool
}

// MARK: - The Guardian

/// Decides whether to intervene, and how.
///
/// A value type with an injected clock: every threshold and cooldown is
/// therefore testable without waiting.
struct Guardian: Sendable {

    // MARK: Thresholds
    //
    // Tuned to be *late* rather than early. Every one of these was chosen by
    // asking "would a good tutor say something here, or keep quiet?"

    /// Consecutive first-attempt misses before Ace offers help.
    static let struggleStreak = 3
    /// Hints taken on one question before Ace changes approach.
    static let hintCeiling = 3
    /// Silence on a single question before Ace checks in.
    static let stuckSeconds: TimeInterval = 60
    /// Idle before Ace assumes attention has gone.
    static let idleSeconds: TimeInterval = 90
    /// Minimum gap between any two interventions.
    static let cooldown: TimeInterval = 75
    /// After this many nudges in a session, Ace stops offering and waits to be
    /// asked. Being ignored three times is an answer.
    static let maxNudgesPerSession = 4

    // MARK: State

    private(set) var nudgeCount = 0
    private(set) var lastNudgeAt: Date?
    private(set) var lastAction: GuardianAction = .none
    /// Actions the student declined — Ace doesn't re-offer the same thing.
    private(set) var declined: Set<String> = []

    init() {}

    // MARK: - Deciding

    /// Should Ace say something?
    ///
    /// - Parameters:
    ///   - signals: behavioural evidence from the current session.
    ///   - mood: the fused mood read.
    ///   - didJustReturn: set once when the app comes back to the foreground.
    func evaluate(signals: BehaviourSignals,
                  mood: MoodReading,
                  didJustReturn: Bool = false,
                  now: Date = Date()) -> GuardianAction {

        // Coming back from another app is the one thing that bypasses the
        // cooldown: greeting someone's return late is worse than not at all.
        if didJustReturn { return .welcomeBack }

        guard canIntervene(now: now) else { return .none }

        // Escalation ladder. Each rung is only reached if the one below it
        // didn't help, which is what stops Ace repeating itself.
        if signals.wrongStreak >= Self.struggleStreak + 2 || signals.hintsTaken >= Self.hintCeiling + 2 {
            return .suggestBreak
        }
        if signals.wrongStreak >= Self.struggleStreak + 1 {
            return .easeOff
        }
        if signals.hintsTaken >= Self.hintCeiling {
            return .reexplain
        }
        if signals.wrongStreak >= Self.struggleStreak {
            return lastAction == .offerHint ? .reexplain : .offerHint
        }

        // Stuck without answering at all.
        if signals.lastResponseLatency >= Self.stuckSeconds {
            return .offerHint
        }

        // Gone quiet.
        if signals.idleSeconds >= Self.idleSeconds {
            return .checkIn
        }

        // A frustrated or low read on its own is not enough to interrupt —
        // it changes how Ace *speaks*, which the tutor already handles. Only
        // frustration plus evidence of being stuck earns an intervention.
        if mood.isActionable, mood.mood == .frustrated, signals.wrongStreak >= 2 {
            return .easeOff
        }

        return .none
    }

    /// Whether we're allowed to interrupt at all right now.
    func canIntervene(now: Date) -> Bool {
        guard nudgeCount < Self.maxNudgesPerSession else { return false }
        guard let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= Self.cooldown
    }

    // MARK: - Recording

    mutating func recordNudge(_ action: GuardianAction, now: Date = Date()) {
        guard action != .none else { return }
        nudgeCount += 1
        lastNudgeAt = now
        lastAction = action
    }

    /// The student said no. Don't offer that again this session.
    mutating func recordDeclined(_ action: GuardianAction) {
        declined.insert(String(describing: action))
    }

    func wasDeclined(_ action: GuardianAction) -> Bool {
        declined.contains(String(describing: action))
    }

    mutating func reset() {
        nudgeCount = 0
        lastNudgeAt = nil
        lastAction = .none
        declined.removeAll()
    }

    // MARK: - What to say

    /// Build the nudge. Mood shapes the wording; the action decides the offer.
    static func nudge(for action: GuardianAction,
                      mood: Mood,
                      goalText: String? = nil,
                      awaySeconds: TimeInterval = 0) -> GuardianNudge? {
        guard action != .none else { return nil }

        switch action {
        case .none:
            return nil

        case .offerHint:
            return GuardianNudge(
                action: action,
                message: mood.wantsGentleness
                    ? "This one's fiddly. Want a nudge in the right direction?"
                    : "Want a hint on this one?",
                acceptTitle: "Go on then",
                isSpoken: false
            )

        case .reexplain:
            return GuardianNudge(
                action: action,
                message: "I don't think I explained that well. Let me try it a completely different way.",
                acceptTitle: "Yes, try again",
                isSpoken: true
            )

        case .easeOff:
            return GuardianNudge(
                action: action,
                message: "Let's back off the difficulty for a minute and rebuild from something easier. Nothing lost.",
                acceptTitle: "Okay",
                isSpoken: true
            )

        case .suggestBreak:
            return GuardianNudge(
                action: action,
                message: "You've been grinding on this. Five minutes away from it will do more than five more minutes at it — I'll keep everything exactly where it is.",
                acceptTitle: "Take five",
                isSpoken: true
            )

        case .welcomeBack:
            return GuardianNudge(
                action: action,
                message: welcomeBackLine(goalText: goalText, awaySeconds: awaySeconds),
                acceptTitle: "Let's go",
                isSpoken: false
            )

        case .checkIn:
            return GuardianNudge(
                action: action,
                message: "Still there? No rush — just say when.",
                acceptTitle: "Here",
                isSpoken: false
            )
        }
    }

    /// The line when they come back from somewhere else.
    ///
    /// The brief asks for this specifically: they slipped off to a YouTube
    /// short, and the return should be warm and point back at the work. What it
    /// must never do is comment on where they went or how long they were gone —
    /// "you were away for 12 minutes" is surveillance, not company.
    private static func welcomeBackLine(goalText: String?, awaySeconds: TimeInterval) -> String {
        let target = goalText.map { " — \($0) is right there" } ?? ""

        switch awaySeconds {
        case ..<45:
            return "Right, where were we\(target)."
        case 45..<300:
            return "Welcome back\(target). Pick up where you left off?"
        default:
            return "Hey — good to see you\(target). Want to carry on, or start somewhere easier?"
        }
    }
}

// MARK: - Comfort

/// The gentler half of the Guardian: what Ace says when the student sounds
/// low, tired or alone — but has said nothing that trips the crisis net.
///
/// The ordering here is the whole design, and it comes straight from §10:
/// **comfort first, then a bridge back — never a guilt trip, never piling on.**
/// A study app that responds to "I'm exhausted" with "you've still got 6
/// questions left!" is actively unpleasant to use.
///
/// This runs *after* `CrisisSafetyService` and only when that returns `.none`.
/// Anything at `.concern` or above is that service's business, not this one's.
enum ComfortResponder {

    /// Things students say that deserve a human response rather than a hint.
    // NOTE: written filler-free. `SafetyTextNormalizer` strips intensifiers
    // ("so", "just", "really") before matching, so "i am so tired" would never
    // match a list entry that still contains "so".
    private static let tiredPhrases = [
        "i am tired", "i am exhausted", "i cannot focus",
        "cannot concentrate", "i am burnt out", "i am burned out", "no energy",
        "i have been up all night", "i did not sleep", "i cannot think straight",
        "my brain is fried", "i am fried", "i am done for today"
    ]

    private static let overwhelmedPhrases = [
        "too much", "i am overwhelmed", "i am behind",
        "i will never finish", "there is too much", "i cannot keep up",
        "everyone else gets it", "i am the only one who"
    ]

    private static let lonelyPhrases = [
        "on my own", "by myself", "nobody to ask", "no one to ask",
        "i have nobody", "i am studying alone", "wish someone was here",
        "no one helps me", "i have no one"
    ]

    private static let anxiousPhrases = [
        "i am going to fail", "i will fail", "i am scared", "i am panicking",
        "i am freaking out", "i am stressed", "i am worried about",
        "i am nervous about", "i am anxious"
    ]

    enum Feeling: String, Sendable, Equatable {
        case tired, overwhelmed, lonely, anxious
    }

    /// What did they just tell us? Nil when there's nothing to respond to.
    static func read(_ message: String) -> Feeling? {
        let text = SafetyTextNormalizer.normalize(message)
        guard text.count > 3 else { return nil }

        // Order matters: loneliness and anxiety get more specific answers than
        // tiredness, so they're checked first.
        if lonelyPhrases.contains(where: { text.contains(" \($0)") }) { return .lonely }
        if anxiousPhrases.contains(where: { text.contains(" \($0)") }) { return .anxious }
        if overwhelmedPhrases.contains(where: { text.contains(" \($0)") }) { return .overwhelmed }
        if tiredPhrases.contains(where: { text.contains(" \($0)") }) { return .tired }
        return nil
    }

    /// Comfort, then the bridge.
    ///
    /// Always two parts, always in that order, and the bridge is always an
    /// *offer* — never an instruction and never a reminder of what's left.
    static func respond(to feeling: Feeling, studentName: String = "") -> String {
        let name = studentName.trimmed.split(separator: " ").first.map { " \($0)" } ?? ""

        switch feeling {
        case .tired:
            return "Then you're tired, and that's a real reason to stop\(name). "
                + "Nothing here is more important than sleep. "
                + "If you want to do five more minutes of something easy, I'll pick something gentle — otherwise go."

        case .overwhelmed:
            return "That feeling is about the size of the pile, not about you. "
                + "You don't have to fix all of it tonight. "
                + "Pick one small piece with me and we'll do only that — the rest can wait."

        case .lonely:
            // The one place this must point outward. §10 is explicit: the
            // companion comforts and points toward real human connection.
            return "Studying on your own is genuinely harder, and I'm glad to sit with you while you do it. "
                + "I'd also say this: is there one person you could message? "
                + "Even someone doing a different subject in the same room helps more than I can. "
                + "Meanwhile — I'm here, and we can keep going as slowly as you like."

        case .anxious:
            return "That's a horrible feeling, and it's not a prediction. "
                + "Being scared of an exam and being unprepared for one aren't the same thing. "
                + "Want to do one question, just to see where you actually are? No score, no pressure."
        }
    }

    /// Whether the app should stop being a game for a bit.
    ///
    /// XP and streaks in the middle of "I'm exhausted" is the app talking over
    /// somebody. Not the full crisis suppression — just quiet.
    static func shouldMuteGamification(for feeling: Feeling) -> Bool {
        switch feeling {
        case .tired, .overwhelmed, .lonely: true
        case .anxious: false      // a small win is genuinely useful here
        }
    }
}
