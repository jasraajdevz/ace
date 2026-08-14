//
//  WidgetSnapshot.swift
//  Ace — SHARED between the app and the widget extension
//
//  This file is compiled into BOTH targets. It is the entire contract between
//  them, and it is deliberately tiny: a few numbers and a string.
//
//  Why not share the SwiftData store instead? Because a widget timeline reload
//  happens on the system's schedule, in a separate process, with a hard memory
//  ceiling. Spinning up a `ModelContainer` to answer "what's the streak?" is
//  slow, fragile, and a well-known way to get a widget killed. Writing a flat
//  snapshot when progress changes is both faster and impossible to get wrong.
//

import Foundation

/// Everything the widget knows.
struct WidgetSnapshot: Codable, Equatable, Sendable {

    var level: Int
    var levelTitle: String
    /// 0...1 through the current level.
    var levelProgress: Double
    var totalXP: Int
    var streakDays: Int
    /// The day the streak was last extended, and whether a repair is in hand.
    ///
    /// The *ingredients* rather than the conclusion. A stored
    /// `streakStateRaw` was written by the app at publish time and then frozen,
    /// so the widget rendered yesterday's answer to a question whose answer
    /// changes at midnight — and refreshing hourly just re-rendered the same
    /// stale string.
    var lastStudyDay: Date?
    var repairsAvailable: Int
    /// Title of the last thing they studied, for the medium widget.
    var lastSourceTitle: String
    var sourceCount: Int
    var lastUpdated: Date

    // MARK: Defaults

    /// What a brand-new install shows. Never blank, never a spinner — a widget
    /// on the home screen with nothing in it is worse than no widget.
    static let empty = WidgetSnapshot(
        level: 1,
        levelTitle: "Getting started",
        levelProgress: 0,
        totalXP: 0,
        streakDays: 0,
        lastStudyDay: nil,
        repairsAvailable: 1,
        lastSourceTitle: "",
        sourceCount: 0,
        lastUpdated: .distantPast
    )

    /// Sample data for the widget gallery. Shows the product at its best without
    /// pretending to be the student's real numbers.
    static let preview = WidgetSnapshot(
        level: 7,
        levelTitle: "Regular",
        levelProgress: 0.62,
        totalXP: 1_240,
        streakDays: 12,
        lastStudyDay: Date(timeIntervalSince1970: 1_760_000_000),
        repairsAvailable: 1,
        lastSourceTitle: "Photosynthesis",
        sourceCount: 4,
        lastUpdated: Date(timeIntervalSince1970: 1_786_000_000)
    )

    /// The streak state *as of now*, not as of the last publish.
    func streakState(at now: Date = Date(), calendar: Calendar = .current) -> StreakDisplayState {
        StreakClock.state(lastStudyDay: lastStudyDay,
                          repairsAvailable: repairsAvailable,
                          now: now, calendar: calendar)
    }

    /// The one line on the widget, written for the day it is being read on.
    func nudge(at now: Date = Date(), calendar: Calendar = .current) -> String {
        WidgetCopy.nudge(state: streakState(at: now, calendar: calendar),
                         days: streakDays,
                         sourceCount: sourceCount,
                         lastTitle: lastSourceTitle)
    }

    /// True when there's nothing real to show yet.
    var isEmpty: Bool { sourceCount == 0 && totalXP == 0 }
}

/// The widget's view of the streak. A flattened `StreakStatus` — the widget
/// doesn't need the associated values, only the colour and icon to use.
/// Where a streak stands, given a date.
///
/// Lives in `Shared` so the app and the widget cannot disagree about it. The
/// app used to own this arithmetic and hand the widget a conclusion; the
/// conclusion then aged badly, because "is the streak safe" is a question whose
/// answer changes at midnight whether or not anybody republished.
enum StreakClock {
    static func state(lastStudyDay: Date?,
                      repairsAvailable: Int,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> StreakDisplayState {
        guard let last = lastStudyDay.map({ calendar.startOfDay(for: $0) }) else { return .none }
        let today = calendar.startOfDay(for: now)
        switch calendar.dateComponents([.day], from: last, to: today).day ?? 0 {
        case ..<0, 0: return .safeToday
        case 1: return .atRisk
        case 2 where repairsAvailable > 0: return .repairable
        default: return .broken
        }
    }
}

/// The widget's words.
///
/// Also shared, and for the same reason: the copy is chosen by streak state, so
/// leaving it in the app would have left the flame recomputing at midnight while
/// the line under it still said "12 days running". Disagreeing with itself is
/// worse than being stale.
///
/// Every branch is an invitation. None is a countdown, a warning, or a reminder
/// of what the student stands to lose — a home-screen widget that makes you feel
/// bad every time you unlock your phone is one that gets deleted, and deserves
/// to be (§10).
enum WidgetCopy {
    static func nudge(state: StreakDisplayState,
                      days: Int,
                      sourceCount: Int,
                      lastTitle: String) -> String {
        if sourceCount == 0 { return "Point Ace at something you're studying." }
        let subject = lastTitle.isEmpty ? "where you left off" : lastTitle
        switch state {
        case .none: return "Ready when you are."
        case .safeToday: return days <= 1 ? "Day one down." : "\(days) days running."
        case .atRisk:
            return days <= 1 ? "Pick up \(subject)?" : "\(days) days going — one session keeps it."
        case .repairable: return "Your \(days)-day streak is still savable."
        case .broken: return "Fresh start whenever — \(subject) is waiting."
        }
    }
}

enum StreakDisplayState: String, Codable, Sendable {
    case none
    case safeToday
    case atRisk
    case repairable
    case broken
}

// MARK: - Where it lives

/// The App Group and keys shared by both targets.
///
/// If the App Group isn't provisioned (it needs a paid Apple Developer account),
/// `defaults` falls back to the process's own `UserDefaults`. The app then still
/// works perfectly and the widget simply shows its empty state — nothing
/// crashes and nothing is blocked. See README.
enum WidgetStore {

    static let appGroupID = "group.com.acestudy.Ace"
    private static let snapshotKey = "ace.widget.snapshot"

    /// The shared container, or the local one when the group is unavailable.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// True when the shared container is actually reachable. Surfaced in
    /// Settings so the failure is visible rather than mysterious.
    static var isSharedContainerAvailable: Bool {
        UserDefaults(suiteName: appGroupID) != nil
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func read() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
    }
}
