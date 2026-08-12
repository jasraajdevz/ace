//
//  Progression.swift
//  Ace
//
//  XP, levels and streaks — the game layer (§3).
//
//  One rule shapes everything in this file, from §10: healthy motivation, never
//  manipulation. Concretely that means:
//    • XP is awarded for *effort*, not just for being right. A wrong answer you
//      actually attempted still pays.
//    • Streaks have a free repair. Missing a Tuesday should not cost a student
//      forty days of progress and make them feel worse than before they started.
//    • Nothing here ever runs while the crisis net is engaged — see
//      `CrisisSignal.suppressesGamification`.
//

import Foundation

// MARK: - XP

/// Every way to earn XP, in one place, so the economy stays legible.
enum XPEvent: Sendable, Equatable {
    case capturedSource
    case answeredCorrectly(streak: Int)
    case attemptedAnswer            // wrong, but they tried — effort pays
    case finishedQuiz(score: Double)
    case reviewedFlashcard(RecallGrade)
    case finishedSession(minutes: Int)
    case explainedOutLoud(clarity: Double)   // Part 4 speaking drills
    case metGoal
    case dailyFirstSession

    var amount: Int {
        switch self {
        case .capturedSource:
            return 15
        case .answeredCorrectly(let streak):
            // A gentle bonus that tops out fast: streaks should feel good, not
            // become the only thing worth chasing.
            return 10 + min(streak, 5) * 2
        case .attemptedAnswer:
            return 3
        case .finishedQuiz(let score):
            return 20 + Int((score * 30).rounded())
        case .reviewedFlashcard(let grade):
            switch grade {
            case .forgot: return 2      // still counts — you looked at it
            case .hard: return 4
            case .easy: return 6
            }
        case .finishedSession(let minutes):
            return min(minutes, 60) * 2
        case .explainedOutLoud(let clarity):
            return 25 + Int((clarity * 25).rounded())
        case .metGoal:
            return 75
        case .dailyFirstSession:
            return 25
        }
    }

    /// Short line for the XP toast.
    var caption: String {
        switch self {
        case .capturedSource: "New material"
        case .answeredCorrectly(let streak): streak >= 3 ? "\(streak) in a row" : "Correct"
        case .attemptedAnswer: "Good attempt"
        case .finishedQuiz: "Quiz complete"
        case .reviewedFlashcard: "Card reviewed"
        case .finishedSession: "Session complete"
        case .explainedOutLoud: "Explained it"
        case .metGoal: "Goal reached"
        case .dailyFirstSession: "Back at it"
        }
    }
}

// MARK: - Levels

/// The level curve.
///
/// Deliberately shallow early (three levels in the first session feels great)
/// and smoothly steeper later, with no wall. `xpForLevel` is the *total* XP
/// needed to reach that level.
enum LevelCurve {

    static let maxLevel = 60

    /// Total XP required to be at `level`. Level 1 starts at 0.
    static func totalXP(forLevel level: Int) -> Int {
        let l = max(1, min(level, maxLevel))
        guard l > 1 else { return 0 }
        // Quadratic-ish: 60, 150, 270, 420, ...
        let n = l - 1
        return 30 * n * (n + 1) / 2 + 30 * n
    }

    /// The level a given XP total corresponds to.
    static func level(forXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }
        var level = 1
        while level < maxLevel && totalXP(forLevel: level + 1) <= xp {
            level += 1
        }
        return level
    }

    /// Progress through the current level, 0...1.
    static func progress(forXP xp: Int) -> Double {
        let level = level(forXP: xp)
        guard level < maxLevel else { return 1 }
        let floorXP = totalXP(forLevel: level)
        let ceilXP = totalXP(forLevel: level + 1)
        guard ceilXP > floorXP else { return 1 }
        return min(max(Double(xp - floorXP) / Double(ceilXP - floorXP), 0), 1)
    }

    static func xpRemaining(forXP xp: Int) -> Int {
        let level = level(forXP: xp)
        guard level < maxLevel else { return 0 }
        return max(0, totalXP(forLevel: level + 1) - xp)
    }

    /// Titles the student unlocks. Encouraging, never condescending.
    static func title(forLevel level: Int) -> String {
        switch level {
        case ..<3: "Getting started"
        case 3..<6: "Warmed up"
        case 6..<10: "Regular"
        case 10..<15: "Consistent"
        case 15..<22: "Sharp"
        case 22..<30: "Locked in"
        case 30..<40: "Relentless"
        case 40..<50: "Formidable"
        default: "Ace"
        }
    }
}

// MARK: - Streaks

/// Daily streak state. All arithmetic is done in the student's own calendar so
/// a 1am study session counts for the right day.
struct StreakState: Codable, Sendable, Equatable {
    var current: Int = 0
    var longest: Int = 0
    var lastStudyDay: Date?
    /// One free miss, refilled after a week of consistency. This is the anti-
    /// guilt valve: the streak survives a bad day, so a bad day doesn't become
    /// a reason to quit.
    var repairsAvailable: Int = 1
    var lastRepairEarnedDay: Date?

    static let fresh = StreakState()
}

enum StreakEngine {

    /// Record a study day and return the updated streak.
    ///
    /// - Parameters:
    ///   - now: current time, injectable so tests aren't at the mercy of the clock.
    ///   - calendar: the student's calendar.
    static func record(_ state: StreakState,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> StreakState {
        var next = state
        let today = calendar.startOfDay(for: now)

        guard let last = state.lastStudyDay.map({ calendar.startOfDay(for: $0) }) else {
            // First ever session.
            next.current = 1
            next.longest = max(1, state.longest)
            next.lastStudyDay = today
            return next
        }

        let dayGap = calendar.dateComponents([.day], from: last, to: today).day ?? 0

        switch dayGap {
        case ..<0:
            // Clock moved backwards (timezone change). Leave the streak alone
            // rather than punishing someone for flying east.
            return next
        case 0:
            // Already counted today.
            return next
        case 1:
            next.current = state.current + 1
        case 2 where state.repairsAvailable > 0:
            // Missed exactly one day and has a repair — spend it silently and
            // keep the streak. The student is told, warmly, not billed.
            next.current = state.current + 1
            next.repairsAvailable = state.repairsAvailable - 1
        default:
            next.current = 1
        }

        next.longest = max(next.longest, next.current)
        next.lastStudyDay = today

        // Earn a repair back after every 7 consecutive days, capped at 2.
        if next.current > 0, next.current % 7 == 0 {
            let alreadyEarnedToday = state.lastRepairEarnedDay.map {
                calendar.isDate($0, inSameDayAs: today)
            } ?? false
            if !alreadyEarnedToday {
                next.repairsAvailable = min(next.repairsAvailable + 1, 2)
                next.lastRepairEarnedDay = today
            }
        }

        return next
    }

    /// Whether the streak is still alive without any action today. Used by the
    /// widget to decide between "you're on 12 days" and "keep 12 alive".
    static func status(_ state: StreakState,
                       now: Date = Date(),
                       calendar: Calendar = .current) -> StreakStatus {
        guard let last = state.lastStudyDay.map({ calendar.startOfDay(for: $0) }) else {
            return .none
        }
        let today = calendar.startOfDay(for: now)
        let gap = calendar.dateComponents([.day], from: last, to: today).day ?? 0
        switch gap {
        case ..<0, 0: return .safeToday(state.current)
        case 1: return .atRisk(state.current)
        case 2 where state.repairsAvailable > 0: return .repairable(state.current)
        default: return .broken(previous: state.current)
        }
    }
}

enum StreakStatus: Sendable, Equatable {
    case none
    /// Already studied today.
    case safeToday(Int)
    /// Studied yesterday — today keeps it going.
    case atRisk(Int)
    /// Missed a day, but a repair can save it.
    case repairable(Int)
    case broken(previous: Int)

    /// The line the widget and home screen show. Encouraging in every branch —
    /// never a guilt trip, never a countdown clock.
    var nudge: String {
        switch self {
        case .none: "Start something today."
        case .safeToday(let n): n <= 1 ? "Day one. Nice." : "\(n) days running."
        case .atRisk(let n): "\(n) days going — one session keeps it."
        case .repairable(let n): "Missed yesterday. Your \(n)-day streak is still savable."
        case .broken: "Fresh start whenever you're ready."
        }
    }
}
