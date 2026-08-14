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

        let snapshot = WidgetSnapshot(
            level: level,
            levelTitle: levelTitle,
            levelProgress: levelProgress,
            totalXP: totalXP,
            streakDays: streak.current,
            lastStudyDay: streak.lastStudyDay,
            repairsAvailable: streak.repairsAvailable,
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

    // The streak's display state and the widget's copy both live in `Shared`
    // now — see `StreakClock` and `WidgetCopy`. They used to be computed here,
    // frozen into the snapshot, and then read hours or days later.
}
