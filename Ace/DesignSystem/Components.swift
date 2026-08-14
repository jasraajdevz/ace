//
//  Components.swift
//  Ace
//
//  The shared component library. If a screen needs a button, a card, a chip or
//  a progress bar, it comes from here — that's what keeps forty screens looking
//  like one app.
//
//  Every component: uses only `Theme.swift` tokens, has a spring micro-
//  interaction, respects Reduce Motion, and carries VoiceOver labelling.
//

import SwiftUI

// MARK: - Buttons

/// Visual weight of a button. Each screen should have exactly one `.primary`.
enum AceButtonStyleKind {
    case primary     // gradient fill — the one thing to do
    case secondary   // outlined surface — the alternative
    case ghost       // text only — tertiary actions
    case destructive
}

struct AceButton: View {
    let title: String
    var systemImage: String?
    var kind: AceButtonStyleKind = .primary
    var isLoading: Bool = false
    var isEnabled: Bool = true
    var fillsWidth: Bool = true
    let action: () -> Void

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard isEnabled, !isLoading else { return }
            Feedback.press()
            action()
        } label: {
            HStack(spacing: Space.s) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                        .scaleEffect(0.85)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(isLoading ? "Working…" : title)
                    .font(Typeface.bodyEmphasis)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.vertical, Space.l)
            .padding(.horizontal, Space.xl)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Ink.sheenGradient)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                    .opacity(kind == .ghost ? 0 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .elevation(kind == .primary && isEnabled ? .medium : .none)
            .glow(kind == .primary && isEnabled && !isPressed ? .accent : .none)
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .aceAnimation(Motion.snappy, value: isPressed)
        // A long-press gesture with zero minimum duration gives us press state
        // without swallowing the button's own tap.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isLoading ? Text("Working") : Text(""))
    }

    @ViewBuilder private var background: some View {
        switch kind {
        // A vertical ramp rather than the brand gradient: the primary button is
        // a *control*, and it should read as a lit surface. The brand gradient
        // is diagonal and stays reserved for the mark and level-ups, so it keeps
        // meaning something.
        case .primary: Ink.accentGradient
        case .secondary: Ink.surfaceGradient(Ink.surfaceRaised)
        case .ghost: Color.clear
        case .destructive: Ink.dangerSoft
        }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary: Ink.textOnAccent
        case .secondary: Ink.textPrimary
        case .ghost: Ink.textSecondary
        case .destructive: Ink.danger
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: Ink.stroke
        case .ghost: .clear
        case .destructive: Ink.danger.opacity(0.35)
        }
    }
}

// MARK: - Card

/// The standard container.
///
/// Three things together make it read as a raised object on a near-black
/// ground, and it needs all three: a fill that falls off slightly toward the
/// bottom, a sheen along the top edge, and a border that is brighter at the top
/// than the bottom. Shadow alone does almost nothing at these ground values —
/// there is no room below near-black for a shadow to darken into.
struct AceCard<Content: View>: View {
    var padding: CGFloat = Space.l
    var fill: Color = Ink.surface
    var elevation: Elevation = .low
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surfaceGradient(fill))
            .overlay(shape.fill(Ink.sheenGradient).blendMode(.plusLighter))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Ink.strokeHighlight, Ink.stroke],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .elevation(elevation)
    }
}

/// A card that responds to being tapped. Separate type so a plain `AceCard`
/// never accidentally becomes an accessibility button.
struct AceTappableCard<Content: View>: View {
    let action: () -> Void
    var accessibilityLabel: String
    @ViewBuilder var content: Content

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Feedback.tap()
            action()
        } label: {
            AceCard { content }
                .scaleEffect(isPressed && !reduceMotion ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .aceAnimation(Motion.snappy, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Chip

/// A selectable pill. Used for subjects, grade levels, filters.
struct AceChip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool
    var tint: Color = Ink.accent
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Feedback.selection()
            action()
        } label: {
            HStack(spacing: Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(Typeface.subheadline)
            }
            .foregroundStyle(isSelected ? Ink.textOnAccent : Ink.textSecondary)
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.l)
            .background(isSelected ? tint : Ink.surfaceRaised)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : Ink.stroke, lineWidth: 1)
            )
            .scaleEffect(isSelected && !reduceMotion ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .aceAnimation(Motion.snappy, value: isSelected)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Progress

/// A progress bar with weight to it: the fill springs into place and carries a
/// soft glow at the leading edge.
struct AceProgressBar: View {
    /// 0...1
    let progress: Double
    var height: CGFloat = 12
    var tint: LinearGradient = Ink.brandGradient
    var showsGlow: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Ink.surfaceRaised)

                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geometry.size.width * clamped))
                    .overlay(alignment: .trailing) {
                        if showsGlow && clamped > 0.02 && !reduceMotion {
                            Circle()
                                .fill(.white.opacity(0.55))
                                .frame(width: height * 0.5, height: height * 0.5)
                                .blur(radius: height * 0.35)
                                .padding(.trailing, height * 0.2)
                        }
                    }
            }
        }
        .frame(height: height)
        .aceAnimation(Motion.smooth, value: clamped)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(Int((clamped * 100).rounded())) percent"))
    }
}

/// A ring, for level progress and session timers.
struct AceProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var tint: LinearGradient = Ink.brandGradient

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Ink.surfaceRaised, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .aceAnimation(Motion.smooth, value: clamped)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(Int((clamped * 100).rounded())) percent"))
    }
}

// MARK: - Headers

struct AceSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(Typeface.title3)
                    .foregroundStyle(Ink.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textTertiary)
                }
            }
            Spacer(minLength: Space.m)
            if let actionTitle, let action {
                Button(actionTitle) {
                    Feedback.tap()
                    action()
                }
                .font(Typeface.footnote)
                .foregroundStyle(Ink.accent)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Designed states (§8: no default-grey anything)

/// The empty state. Every list in Ace has one of these — never a blank screen.
struct AceEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack {
                Circle()
                    .fill(Ink.accentSoft)
                    .frame(width: 84, height: 84)
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Ink.accent)
            }

            VStack(spacing: Space.s) {
                Text(title)
                    .font(Typeface.title3)
                    .foregroundStyle(Ink.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                AceButton(title: actionTitle, kind: .secondary, fillsWidth: false, action: action)
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The loading state. A shimmering placeholder that matches the shape of what's
/// coming, rather than a spinner on grey.
struct AceLoadingState: View {
    var message: String = "Getting that ready…"
    var rows: Int = 3

    @State private var shimmerPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(0..<rows, id: \.self) { index in
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(Ink.surfaceRaised)
                    .frame(height: index == 0 ? 22 : 16)
                    .frame(maxWidth: index == rows - 1 ? 180 : .infinity, alignment: .leading)
                    .overlay(shimmer)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }
        }
        .padding(Space.l)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmerPhase = 2
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(message))
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var shimmer: some View {
        if reduceMotion {
            Color.clear
        } else {
            GeometryReader { geometry in
                LinearGradient(
                    colors: [.clear, Ink.textPrimary.opacity(0.07), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geometry.size.width * 0.6)
                .offset(x: shimmerPhase * geometry.size.width)
            }
        }
    }
}

/// The error state. Always says what happened, what it means, and what to do —
/// never a raw error string.
struct AceErrorState: View {
    let title: String
    let message: String
    var retryTitle: String = "Try again"
    var onRetry: (() -> Void)?
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.l) {
            ZStack {
                Circle()
                    .fill(Ink.warningSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Ink.warning)
            }

            VStack(spacing: Space.s) {
                Text(title)
                    .font(Typeface.title3)
                    .foregroundStyle(Ink.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Space.s) {
                if let onRetry {
                    AceButton(title: retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                }
                if let secondaryTitle, let onSecondary {
                    AceButton(title: secondaryTitle, kind: .ghost, action: onSecondary)
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Ambient background

/// The signature background: a near-black ground with two slow-drifting colour
/// blooms. It's what stops every screen reading as flat black, and it costs one
/// blurred shape per bloom.
///
/// Under Reduce Motion the blooms are placed but never animate.
struct AuraBackground: View {
    var tint: Color = Ink.accent
    var secondaryTint: Color = Ink.accentAlt
    /// Turns the drift off — used on the calm/DND surface and during quizzes.
    var isStill: Bool = false

    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { !isStill && !reduceMotion }

    var body: some View {
        ZStack {
            Ink.background

            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: drift ? -90 : -130, y: drift ? -220 : -170)

            Circle()
                .fill(secondaryTint.opacity(0.13))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: drift ? 140 : 110, y: drift ? 240 : 300)
        }
        .ignoresSafeArea()
        .onAppear {
            guard animates else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small pieces

/// A label/value stat, used across Home, results and Settings.
struct AceStat: View {
    let value: String
    let label: String
    var systemImage: String?
    var tint: Color = Ink.accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(value)
                    .font(Typeface.numeric(.title2))
                    .foregroundStyle(Ink.textPrimary)
            }
            Text(label)
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value)"))
    }
}

/// A small badge — "Demo Mode", "Live", counts.
struct AceBadge: View {
    let text: String
    // Declared before `tint` to match the `title, systemImage, …` order every
    // other component uses — Swift's memberwise initialiser requires arguments
    // in declaration order, so an inconsistent order here is a compile error at
    // the call site rather than a style nit.
    var systemImage: String?
    var tint: Color = Ink.accent

    var body: some View {
        HStack(spacing: Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(Typeface.captionEmphasis)
        }
        .foregroundStyle(tint)
        .padding(.vertical, 5)
        .padding(.horizontal, Space.m)
        .background(tint.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityLabel(Text(text))
    }
}

/// Screen title block used at the top of full-screen flows.
struct AceScreenTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .aceDisplay()
                .foregroundStyle(Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Layout helpers

extension View {
    /// Standard horizontal screen inset.
    func aceScreenPadding() -> some View {
        padding(.horizontal, Space.screen)
    }

    /// Applies the app background behind a screen's content.
    func aceBackground(tint: Color = Ink.accent, isStill: Bool = false) -> some View {
        background(AuraBackground(tint: tint, isStill: isStill))
    }
}
