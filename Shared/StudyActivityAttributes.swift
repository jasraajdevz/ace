//
//  StudyActivityAttributes.swift
//  Ace — SHARED between the app and the widget extension
//
//  The Live Activity's data contract (§Part 5).
//
//  A study session on the lock screen: the goal, how far through it you are, and
//  the streak. It exists so a student can put the phone face-down on the desk
//  and still see, at a glance, that the session is running — which is a small
//  thing that turns out to matter a lot for body doubling.
//
//  Guarded on `os(iOS)` rather than `canImport(ActivityKit)`: the module does
//  import on macOS, but every type in it is marked unavailable there — so the
//  canImport form compiles on this machine and fails on the type check.
//

import Foundation

#if os(iOS)
import ActivityKit

struct StudyActivityAttributes: ActivityAttributes {

    /// What changes while the activity is live.
    struct ContentState: Codable, Hashable {
        /// 0...1 through the goal. Zero for a landmark goal, which has no
        /// measurable end — the lock screen shows elapsed time instead.
        var progress: Double
        /// Minutes worked so far.
        var minutes: Int
        /// Questions answered, cards reviewed — whatever the goal counts.
        var completed: Int
        var target: Int
        var streakDays: Int
        /// One short line. Written by the app so all the tone rules stay in one
        /// place, exactly as with the widget.
        var status: String
        var isPaused: Bool
    }

    /// Fixed for the life of the activity.
    var goalText: String
    var isMeasurable: Bool
    var startedAt: Date
}

#endif
