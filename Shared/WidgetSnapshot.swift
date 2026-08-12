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
    /// Whether the streak is safe, at risk, or savable today.
    var streakStateRaw: String
    /// One warm line. Written by the app so all the tone rules live in one place.
    var nudge: String
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
        streakStateRaw: StreakDisplayState.none.rawValue,
        nudge: "Point Ace at something you're studying.",
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
        streakStateRaw: StreakDisplayState.safeToday.rawValue,
        nudge: "12 days running.",
        lastSourceTitle: "Photosynthesis",
        sourceCount: 4,
        lastUpdated: Date(timeIntervalSince1970: 1_786_000_000)
    )

    var streakState: StreakDisplayState {
        StreakDisplayState(rawValue: streakStateRaw) ?? .none
    }

    /// True when there's nothing real to show yet.
    var isEmpty: Bool { sourceCount == 0 && totalXP == 0 }
}

/// The widget's view of the streak. A flattened `StreakStatus` — the widget
/// doesn't need the associated values, only the colour and icon to use.
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
