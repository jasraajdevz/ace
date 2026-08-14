//
//  PresenceComponents.swift
//  Ace
//
//  The visual language of company: the presence banner, the Guardian nudge, the
//  comfort card, the focus-music picker and the Do Not Disturb toggle.
//
//  These are the quietest components in the app on purpose. Everything here
//  appears *beside* what the student is doing, never on top of it, and every one
//  of them can be ignored without consequence.
//

import SwiftUI

// MARK: - Presence banner

/// A body-double check-in. Small, low-contrast, self-dismissing.
struct PresenceBanner: View {
    let message: PresenceMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Circle()
                .fill(Ink.accent.opacity(0.7))
                .frame(width: 6, height: 6)

            Text(message.text)
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if message.kind == .closing || message.kind == .breakSuggestion {
                Button("Okay", action: onDismiss)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.accent)
            }
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.l)
        .background(Ink.surface.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Ink.stroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message.text))
    }
}

// MARK: - Guardian nudge

/// An offer of help. Two buttons: take it, or don't.
///
/// The decline is a real, equal-weight button rather than a small ✕, because a
/// nudge you can't comfortably refuse isn't a nudge.
struct GuardianNudgeCard: View {
    let nudge: GuardianNudge
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(nudge.message)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: Space.m) {
                Button(nudge.acceptTitle) {
                    Feedback.tap()
                    onAccept()
                }
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textOnAccent)
                .padding(.vertical, Space.s)
                .padding(.horizontal, Space.l)
                .background(tint, in: Capsule())

                Button("Not now") {
                    Feedback.tap()
                    onDismiss()
                }
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textSecondary)
                .padding(.vertical, Space.s)
                .padding(.horizontal, Space.l)
                .background(Ink.surfaceRaised, in: Capsule())

                Spacer(minLength: 0)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch nudge.action {
        case .offerHint: "lightbulb"
        case .reexplain: "arrow.triangle.2.circlepath"
        case .easeOff: "arrow.down.right.circle"
        case .suggestBreak: "cup.and.saucer"
        case .welcomeBack: "hand.wave"
        case .checkIn: "ear"
        case .none: "circle"
        }
    }

    private var tint: Color {
        switch nudge.action {
        case .suggestBreak: Ink.calm
        case .welcomeBack: Ink.accent
        case .easeOff, .reexplain: Ink.accentAlt
        default: Ink.warning
        }
    }
}

// MARK: - Comfort

/// The response to "I'm exhausted".
///
/// Uses the *care* palette rather than the brand one — the same surface family
/// as the crisis screen. When Ace is being kind rather than useful, it should
/// look different.
struct ComfortCard: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.careAccent)
                Spacer(minLength: 0)
            }

            Text(message)
                .font(Typeface.callout)
                .foregroundStyle(Ink.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Button("Thanks", action: onDismiss)
                .font(Typeface.footnote)
                .foregroundStyle(Ink.careAccent)
                .padding(.top, Space.xs)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.careSurface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Ink.careAccent.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }
}

// MARK: - Do Not Disturb

/// The one-tap toggle.
///
/// The label always says what it will do, because a control that quiets things
/// needs to be unambiguous about what it *doesn't* do.
struct DoNotDisturbToggle: View {
    let state: DoNotDisturbState
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.m) {
                ZStack {
                    Circle()
                        .fill(state.isOn ? Ink.calm.opacity(0.22) : Ink.surfaceRaised)
                        .frame(width: 40, height: 40)
                    Image(systemName: state.isOn ? "moon.fill" : "moon")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(state.isOn ? Ink.calm : Ink.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isOn ? "Quiet mode on" : "Quiet mode")
                        .font(Typeface.subheadline)
                        .foregroundStyle(Ink.textPrimary)
                    Text(state.explanation)
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.isOn ? Ink.calm.opacity(0.08) : Ink.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(state.isOn ? Ink.calm.opacity(0.3) : Ink.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(state.isOn ? "Quiet mode, on" : "Quiet mode, off"))
        .accessibilityHint(Text(state.explanation))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Focus music

/// Scene picker plus volume.
struct FocusMusicPicker: View {
    let current: FocusScene
    let volume: Double
    let onSelect: (FocusScene) -> Void
    // Deliberately NOT `@Sendable`, despite the strict-concurrency warning that
    // `Binding`'s setter wants one. Both callers legitimately mutate main-actor
    // state inside it — `SettingsView` its own `@State`, `BodyDoubleView` the
    // music player — and marking it `@Sendable` makes those call sites a
    // compile error rather than making anything safer.
    //
    // The honest fix is `@Binding var volume`, which removes the closure
    // entirely. That needs a stored `volume` on `FocusMusicPlayer`, which today
    // only exposes `setVolume(_:)`. Logged as a known exception in
    // Tools/gen/check_concurrency.sh rather than annotated around.
    let onVolume: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            FlowLayout(spacing: Space.s) {
                ForEach(FocusScene.allCases) { scene in
                    AceChip(title: scene.displayName,
                            systemImage: scene.symbolName,
                            isSelected: current == scene,
                            tint: Ink.calm) {
                        onSelect(scene)
                    }
                }
            }

            if current != .off {
                Text(current.detail)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)

                HStack(spacing: Space.m) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.textTertiary)
                    Slider(value: Binding(get: { volume }, set: onVolume), in: 0...1)
                        .tint(Ink.calm)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Music volume"))
                .accessibilityValue(Text("\(Int(volume * 100)) percent"))

                Text("Music ducks under Ace's voice and keeps playing through quizzes.")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Session timer

/// The big quiet number on the body-double surface.
///
/// Monospaced digits so it doesn't jitter, and no colour change as time runs
/// out — a timer that turns red is a timer that creates pressure, which is the
/// opposite of what co-working is for.
struct SessionTimer: View {
    let elapsed: TimeInterval
    let progress: Double
    let goalText: String
    let isMeasurable: Bool

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack {
                if isMeasurable {
                    AceProgressRing(progress: progress, lineWidth: 6,
                                    tint: LinearGradient(colors: [Ink.calm, Ink.accentAlt],
                                                         startPoint: .top, endPoint: .bottom))
                        .frame(width: 190, height: 190)
                } else {
                    Circle()
                        .stroke(Ink.surfaceRaised, lineWidth: 6)
                        .frame(width: 190, height: 190)
                }

                VStack(spacing: Space.xs) {
                    Text(timeText)
                        .font(.system(size: 44, design: .rounded).weight(.semibold))
                        .foregroundStyle(Ink.textPrimary)
                        .monospacedDigit()
                    Text(goalText)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Int(elapsed / 60)) minutes into \(goalText)"))
    }

    private var timeText: String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
