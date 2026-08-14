//
//  AceWidgetViews.swift
//  AceWidget
//
//  The home-screen companion (§3): streak, XP, and one warm line.
//
//  Design rules, and they're stricter than the app's:
//
//  • **It must never look broken.** The widget renders whatever snapshot is in
//    the shared container, including the empty one. There is no loading state,
//    no spinner and no "—" anywhere.
//  • **It must never nag.** The nudge line is written by the app
//    (`WidgetBridge.nudge`) and every branch of it is an invitation. No
//    countdowns, no "don't lose your streak" (§10).
//  • **It must be cheap.** No database, no images, no network — one small JSON
//    blob read from `UserDefaults`. See `WidgetSnapshot`.
//
//  Colours are duplicated from the app's `Ink` tokens rather than shared,
//  because pulling the whole design system into the extension would drag in
//  SwiftData and UIKit for the sake of six hex values.
//

import SwiftUI
import WidgetKit

// MARK: - Palette

/// The subset of `Ink` the widget needs. Keep in sync with
/// `Ace/DesignSystem/Theme.swift`.
enum WidgetInk {
    static let background = Color(red: 0.039, green: 0.039, blue: 0.067)
    static let surfaceRaised = Color(red: 0.114, green: 0.114, blue: 0.169)
    static let textPrimary = Color(red: 0.961, green: 0.961, blue: 0.980)
    static let textSecondary = Color(red: 0.663, green: 0.663, blue: 0.749)
    static let textTertiary = Color(red: 0.431, green: 0.431, blue: 0.522)
    static let accent = Color(red: 0.486, green: 0.361, blue: 1.0)
    static let accentAlt = Color(red: 0.133, green: 0.827, blue: 0.933)
    static let flame = Color(red: 1.0, green: 0.592, blue: 0.322)
    static let success = Color(red: 0.204, green: 0.827, blue: 0.600)

    static let brandGradient = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The streak flame's colour, which is the one place the widget carries
    /// state visually.
    static func streakTint(_ state: StreakDisplayState) -> Color {
        switch state {
        case .safeToday: flame
        case .atRisk: flame.opacity(0.75)
        case .repairable: accentAlt
        case .broken, .none: textTertiary
        }
    }
}

// MARK: - Small

/// Level ring, streak, and the nudge. The whole thing has to read at a glance
/// from arm's length, so it carries three facts and no more.
struct AceSmallWidgetView: View {
    let snapshot: WidgetSnapshot
    /// The date this entry represents, not "now". A timeline entry scheduled for
    /// midnight is built in advance and rendered then, so asking the clock would
    /// give the wrong day.
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .stroke(WidgetInk.surfaceRaised, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(snapshot.levelProgress, 1)))
                        .stroke(WidgetInk.brandGradient,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(snapshot.level)")
                        .font(.system(size: 17, design: .rounded).weight(.heavy))
                        .foregroundStyle(WidgetInk.textPrimary)
                        .monospacedDigit()
                }
                .frame(width: 44, height: 44)

                Spacer(minLength: 0)

                if snapshot.streakDays > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("\(snapshot.streakDays)")
                            .font(.system(size: 14, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                    }
                    .foregroundStyle(WidgetInk.streakTint(snapshot.streakState(at: now)))
                }
            }

            Spacer(minLength: 6)

            Text(snapshot.nudge(at: now))
                .font(.system(size: 13, design: .rounded).weight(.semibold))
                .foregroundStyle(WidgetInk.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary(snapshot, now: now)))
    }
}

// MARK: - Medium

/// Adds what they were last working on, and the XP total.
struct AceMediumWidgetView: View {
    let snapshot: WidgetSnapshot
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(WidgetInk.surfaceRaised, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(snapshot.levelProgress, 1)))
                        .stroke(WidgetInk.brandGradient,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -1) {
                        Text("\(snapshot.level)")
                            .font(.system(size: 22, design: .rounded).weight(.heavy))
                            .foregroundStyle(WidgetInk.textPrimary)
                            .monospacedDigit()
                        Text("LEVEL")
                            .font(.system(size: 7, design: .rounded).weight(.heavy))
                            .tracking(1.2)
                            .foregroundStyle(WidgetInk.textTertiary)
                    }
                }
                .frame(width: 62, height: 62)

                Spacer(minLength: 4)

                Text(snapshot.levelTitle)
                    .font(.system(size: 11, design: .rounded).weight(.semibold))
                    .foregroundStyle(WidgetInk.textSecondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if snapshot.streakDays > 0 {
                        Label {
                            Text("\(snapshot.streakDays)")
                                .font(.system(size: 15, design: .rounded).weight(.heavy))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(WidgetInk.streakTint(snapshot.streakState(at: now)))
                    }

                    Label {
                        Text("\(snapshot.totalXP)")
                            .font(.system(size: 15, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(WidgetInk.accentAlt)

                    Spacer(minLength: 0)
                }

                Text(snapshot.nudge(at: now))
                    .font(.system(size: 15, design: .rounded).weight(.semibold))
                    .foregroundStyle(WidgetInk.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if !snapshot.lastSourceTitle.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 9, weight: .semibold))
                            Text(snapshot.lastSourceTitle)
                                .font(.system(size: 11, design: .rounded).weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(WidgetInk.textTertiary)
                    }
                    Spacer(minLength: 0)
                    QuickCaptureButton()
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary(snapshot, now: now)))
    }
}

// MARK: - Shared

/// One spoken sentence covering the whole widget, so VoiceOver doesn't read it
/// as a pile of disconnected numbers.
func accessibilitySummary(_ snapshot: WidgetSnapshot, now: Date = Date()) -> String {
    var parts: [String] = ["Ace. Level \(snapshot.level), \(snapshot.levelTitle)."]
    if snapshot.streakDays > 0 {
        parts.append("\(snapshot.streakDays) day streak.")
    }
    parts.append(snapshot.nudge(at: now))
    return parts.joined(separator: " ")
}
