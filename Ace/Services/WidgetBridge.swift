//
//  WidgetBridge.swift
//  Ace
//
//  The app's half of the widget contract.
//
//  One rule: **the widget's copy is written here, not in the widget.** All the
//  tone rules from §10 — encouraging, never guilt-tripping — live in the app
//  alongside everything else that speaks to the student. The widget just renders
//  the string it's given.
//

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum WidgetBridge {

    /// Publish the current state and ask the system to refresh the timeline.
    ///
    /// Called after anything that changes progress: capturing material,
    /// finishing a quiz, reviewing cards, ending a session.
    static func publish(level: Int,
                        levelTitle: String,
                        levelProgress: Double,
                        totalXP: Int,
                        streak: StreakState,
                        lastSourceTitle: String,
                        sourceCount: Int,
                        now: Date = Date()) {

        let status = StreakEngine.status(streak, now: now)

        let snapshot = WidgetSnapshot(
            level: level,
            levelTitle: levelTitle,
            levelProgress: levelProgress,
            totalXP: totalXP,
            streakDays: streak.current,
            streakStateRaw: displayState(for: status).rawValue,
            nudge: nudge(for: status, sourceCount: sourceCount, lastTitle: lastSourceTitle),
            lastSourceTitle: lastSourceTitle,
            sourceCount: sourceCount,
            lastUpdated: now
        )

        WidgetStore.write(snapshot)
        reloadTimelines()
    }

    /// Wipe the widget — used by "Reset everything" so a cleared app doesn't
    /// leave a ghost streak on the home screen.
    static func clear() {
        WidgetStore.clear()
        reloadTimelines()
    }

    private static func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Copy

    private static func displayState(for status: StreakStatus) -> StreakDisplayState {
        switch status {
        case .none: .none
        case .safeToday: .safeToday
        case .atRisk: .atRisk
        case .repairable: .repairable
        case .broken: .broken
        }
    }

    /// The one line on the widget.
    ///
    /// Every branch is an invitation. None of them is a countdown, a warning, or
    /// a reminder of what the student stands to lose — a home-screen widget that
    /// makes you feel bad every time you unlock your phone is a widget that gets
    /// deleted, and deserves to be (§10).
    static func nudge(for status: StreakStatus, sourceCount: Int, lastTitle: String) -> String {
        if sourceCount == 0 {
            return "Point Ace at something you're studying."
        }

        let subject = lastTitle.isEmpty ? "where you left off" : lastTitle

        switch status {
        case .none:
            return "Ready when you are."
        case .safeToday(let days):
            return days <= 1 ? "Day one down." : "\(days) days running."
        case .atRisk(let days):
            return days <= 1 ? "Pick up \(subject)?" : "\(days) days going — one session keeps it."
        case .repairable(let days):
            return "Your \(days)-day streak is still savable."
        case .broken:
            return "Fresh start whenever — \(subject) is waiting."
        }
    }
}
