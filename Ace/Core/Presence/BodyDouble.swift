//
//  BodyDouble.swift
//  Ace
//
//  Study-with-me: someone in the room with you (§3, Part 4).
//
//  Body doubling is a real thing that works — for a lot of people, especially
//  anyone with ADHD, the presence of another person working is the difference
//  between starting and not starting. The hard part is that the presence has to
//  be *quiet*. A companion that comments every two minutes is not company, it's
//  an interruption wearing company's clothes.
//
//  So the whole design here is about restraint:
//    • Three check-ins per session, at a quarter, half and three-quarters.
//    • Each one is a sentence. No questions unless the student is struggling —
//      a question demands a reply, and demanding a reply is not co-working.
//    • The presence surface shows a timer and almost nothing else.
//    • And the thing Ace says at the end points *outward*: this is company, not
//      a replacement for people (§10).
//

import Foundation

/// Where a body-double session is.
enum BodyDoublePhase: Sendable, Equatable {
    /// Agreeing what we're doing.
    case settingGoal
    /// Working.
    case working
    /// Paused — deliberately, by the student.
    case paused
    /// Done, one way or another.
    case finished(metGoal: Bool)

    var isActive: Bool {
        switch self {
        case .working, .paused: true
        case .settingGoal, .finished: false
        }
    }

    /// Whether the goal was actually reached. False for a session that never
    /// finished — abandoning one is not meeting it.
    var metGoal: Bool {
        if case .finished(let met) = self { return met }
        return false
    }
}

/// Something Ace says during the session, unprompted.
struct PresenceMessage: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        /// The opening line after the goal is set.
        case opening
        /// A quarter/half/three-quarter check-in.
        case milestone
        /// They've been going a long time without a break.
        case breakSuggestion
        /// They came back after leaving the app.
        case welcomeBack
        /// The session ended.
        case closing
    }

    var id: UUID = UUID()
    var kind: Kind
    var text: String
    /// True when Ace should speak it aloud as well as show it. Most check-ins
    /// are silent — a voice interrupting concentration is worse than a line of
    /// text appearing at the edge of vision.
    var isSpoken: Bool
}

/// Runs a body-double session.
///
/// Pure value type driven by an injected clock, so the whole arc — goal,
/// milestones, break suggestion, ending — is tested in milliseconds rather than
/// by sitting through twenty-five minutes.
struct BodyDoubleSession: Sendable {

    private(set) var phase: BodyDoublePhase = .settingGoal
    private(set) var goal: StudyGoal?
    private(set) var startedAt: Date?
    /// Milestones already announced, so none fires twice.
    private(set) var announcedMilestones: Set<Milestone> = []
    private(set) var didSuggestBreak = false

    /// Countable progress the student has made — questions answered, cards
    /// reviewed. The session screen feeds this in.
    private(set) var countCompleted: Int = 0

    /// Total time paused, subtracted from elapsed.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    /// After this long without a break, Ace mentions one. Once.
    static let breakSuggestionAfter: TimeInterval = 50 * 60

    init() {}

    // MARK: - Lifecycle

    /// Agree the goal and start.
    mutating func begin(goal: StudyGoal, now: Date = Date()) -> PresenceMessage {
        self.goal = goal
        self.startedAt = now
        self.phase = .working
        self.announcedMilestones = []
        self.countCompleted = 0
        self.pausedTotal = 0
        self.pausedAt = nil

        return PresenceMessage(kind: .opening, text: openingLine(for: goal), isSpoken: true)
    }

    mutating func pause(now: Date = Date()) {
        guard phase == .working else { return }
        phase = .paused
        pausedAt = now
    }

    mutating func resume(now: Date = Date()) {
        guard phase == .paused else { return }
        if let pausedAt { pausedTotal += now.timeIntervalSince(pausedAt) }
        self.pausedAt = nil
        phase = .working
    }

    /// End the session.
    mutating func finish(now: Date = Date()) -> PresenceMessage {
        let met = progress(now: now).isComplete || goal?.isMeasurable == false
        phase = .finished(metGoal: met)
        return PresenceMessage(kind: .closing,
                               text: closingLine(metGoal: met, minutes: elapsedMinutes(now: now)),
                               isSpoken: true)
    }

    /// The student says a landmark goal is done.
    mutating func markLandmarkReached(now: Date = Date()) -> PresenceMessage {
        phase = .finished(metGoal: true)
        return PresenceMessage(kind: .closing,
                               text: closingLine(metGoal: true, minutes: elapsedMinutes(now: now)),
                               isSpoken: true)
    }

    // MARK: - Progress

    mutating func recordCompletion(_ amount: Int = 1) {
        countCompleted += amount
    }

    func elapsed(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        let pausedSoFar = pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, now.timeIntervalSince(startedAt) - pausedSoFar)
    }

    func elapsedMinutes(now: Date = Date()) -> Int {
        Int(elapsed(now: now) / 60)
    }

    func progress(now: Date = Date()) -> GoalProgress {
        guard let goal else { return .none }
        switch goal.target {
        case .duration(let minutes):
            return GoalProgress(completed: elapsed(now: now), total: Double(minutes) * 60)
        case .count(let target, _):
            return GoalProgress(completed: Double(countCompleted), total: Double(target))
        case .landmark:
            return .none
        }
    }

    // MARK: - Ambient check-ins

    /// Called on a timer. Returns something to say, or nil — which is the
    /// common case and the point.
    mutating func tick(now: Date = Date()) -> PresenceMessage? {
        guard phase == .working, let goal else { return nil }

        // Goal reached.
        let current = progress(now: now)
        if current.isComplete {
            return finish(now: now)
        }

        // A milestone we haven't mentioned yet.
        if goal.isMeasurable,
           let milestone = Milestone.reached(at: current.fraction),
           !announcedMilestones.contains(milestone) {
            announcedMilestones.insert(milestone)
            return PresenceMessage(kind: .milestone,
                                   text: milestoneLine(milestone, goal: goal),
                                   isSpoken: false)
        }

        // Long stretch with no break. Suggested once, never insisted on.
        if !didSuggestBreak, elapsed(now: now) >= Self.breakSuggestionAfter {
            didSuggestBreak = true
            return PresenceMessage(kind: .breakSuggestion,
                                   text: breakLine(minutes: elapsedMinutes(now: now)),
                                   isSpoken: true)
        }

        // For a landmark goal there's nothing to measure, so Ace checks in on
        // time instead — but only twice in the first hour.
        if !goal.isMeasurable {
            let minutes = elapsedMinutes(now: now)
            if minutes >= 20, !announcedMilestones.contains(.half) {
                announcedMilestones.insert(.half)
                return PresenceMessage(kind: .milestone,
                                       text: "Twenty minutes in. Still with you.",
                                       isSpoken: false)
            }
            if minutes >= 40, !announcedMilestones.contains(.threeQuarters) {
                announcedMilestones.insert(.threeQuarters)
                return PresenceMessage(kind: .milestone,
                                       text: "Forty minutes. How's \(goal.displayText) looking?",
                                       isSpoken: false)
            }
        }

        return nil
    }

    // MARK: - Copy
    //
    // Every line below is written to sound like someone working alongside you,
    // not a coach. Short. No exclamation marks. No "you've got this!".

    private func openingLine(for goal: StudyGoal) -> String {
        switch goal.target {
        case .duration(let minutes):
            return "Right — \(minutes) minutes. I'll keep out of the way and check in a couple of times. Start when you're ready."
        case .count(let count, let unit):
            return "Okay, \(unit.label(count)). I'm here the whole way. Go when you want."
        case .landmark(let name):
            return "\(name.prefix(1).uppercased() + name.dropFirst()) it is. I'll sit with you — tell me when you get there."
        }
    }

    private func milestoneLine(_ milestone: Milestone, goal: StudyGoal) -> String {
        switch (milestone, goal.target) {
        case (.quarter, .duration):
            return "Quarter of the way. Going nicely."
        case (.half, .duration(let minutes)):
            return "Halfway — \(minutes / 2) minutes down."
        case (.threeQuarters, .duration):
            return "Three quarters. Home stretch."
        case (.quarter, .count(let total, let unit)):
            return "\(countCompleted) of \(unit.label(total)). Good pace."
        case (.half, .count(let total, _)):
            return "Halfway — \(countCompleted) of \(total)."
        case (.threeQuarters, .count(let total, _)):
            return "\(total - countCompleted) to go."
        default:
            return "Still here."
        }
    }

    private func breakLine(minutes: Int) -> String {
        "You've been at it \(minutes) minutes. Worth standing up for five — I'll hold the place."
    }

    /// The last thing Ace says.
    ///
    /// This is the one place a study app can quietly do something good, and §10
    /// asks for it directly: point outward. A companion that positions itself as
    /// the student's only company is doing harm, however warm it sounds.
    private func closingLine(metGoal: Bool, minutes: Int) -> String {
        let time = minutes <= 1 ? "" : " \(minutes) minutes of actual work."
        if metGoal {
            return "That's it — you did the thing you said you'd do.\(time) "
                + "Go tell someone, or go and do something else entirely. I'll be here next time."
        }
        return "Stopping there is fine.\(time) You showed up and did some, which is the part that's hard. "
            + "Come back to it when you want."
    }
}
