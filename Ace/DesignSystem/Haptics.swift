//
//  Haptics.swift
//  Ace
//
//  Haptic choreography (§8).
//
//  Haptics are a language, not decoration. The vocabulary here is small on
//  purpose so that each pattern keeps its meaning: `.tap` always means "you
//  touched something", `.correct` always means "that was right". If every
//  interaction buzzed differently, none of them would communicate anything.
//
//  UIKit-only, so the whole implementation is behind `canImport(UIKit)` and the
//  call sites never need to care — on any platform without haptics these are
//  no-ops.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The haptic vocabulary.
enum Haptic {
    /// Any ordinary tap: a chip, a nav push, a selection.
    case tap
    /// A heavier, more consequential press: start session, capture photo.
    case press
    /// Moving between discrete values (picker, page).
    case selection
    /// Correct answer.
    case correct
    /// Wrong answer. Soft — a wrong answer is information, not a punishment.
    case incorrect
    /// Something finished well: quiz complete, goal met.
    case success
    /// Level up. The only pattern that's a sequence.
    case levelUp
    /// Gentle attention: a guardian nudge, a milestone check-in. Must never
    /// feel like an alarm.
    case nudge
    /// Something went wrong.
    case warning

    #if canImport(UIKit)
    /// Generators are cached because creating one per event drops the first
    /// haptic of a burst — the engine needs a moment to spin up.
    @MainActor private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    @MainActor private static let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    @MainActor private static let selectionGenerator = UISelectionFeedbackGenerator()
    @MainActor private static let notification = UINotificationFeedbackGenerator()
    #endif

    /// Play the pattern. Safe to call from anywhere; hops to the main actor and
    /// does nothing on platforms without haptics.
    func play() {
        #if canImport(UIKit)
        Task { @MainActor in
            // Respect the student's own setting first (Part 4 wires this to the
            // DND / low-stimulation surface).
            guard HapticSettings.shared.isEnabled else { return }

            switch self {
            case .tap:
                Self.impactLight.impactOccurred(intensity: 0.7)
            case .press:
                Self.impactMedium.impactOccurred()
            case .selection:
                Self.selectionGenerator.selectionChanged()
            case .correct:
                Self.impactRigid.impactOccurred(intensity: 0.85)
            case .incorrect:
                // Soft and single. Never a "failure" buzz.
                Self.impactSoft.impactOccurred(intensity: 0.6)
            case .success:
                Self.notification.notificationOccurred(.success)
            case .levelUp:
                // A rising three-beat. The one place a sequence is warranted.
                Self.impactSoft.impactOccurred(intensity: 0.5)
                try? await Task.sleep(for: .milliseconds(90))
                Self.impactMedium.impactOccurred(intensity: 0.75)
                try? await Task.sleep(for: .milliseconds(110))
                Self.notification.notificationOccurred(.success)
            case .nudge:
                Self.impactSoft.impactOccurred(intensity: 0.45)
            case .warning:
                Self.notification.notificationOccurred(.warning)
            }
        }
        #endif
    }

    /// Warm the haptic engine up before an interaction that will fire one.
    /// Calling this on `.onAppear` of an answer screen removes the ~50ms lag on
    /// the very first tap.
    static func prepare() {
        #if canImport(UIKit)
        Task { @MainActor in
            impactLight.prepare()
            impactMedium.prepare()
            notification.prepare()
            selectionGenerator.prepare()
        }
        #endif
    }
}

/// Student-controlled haptic switch. Lives here rather than in Settings so the
/// haptic layer has no upward dependency.
@MainActor
final class HapticSettings {
    static let shared = HapticSettings()
    private static let storageKey = "ace.haptics.enabled"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.storageKey) }
    }

    private init() {
        // Default on. `object(forKey:)` distinguishes "never set" from "set to
        // false", which `bool(forKey:)` alone cannot.
        if UserDefaults.standard.object(forKey: Self.storageKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.storageKey)
        }
    }
}
