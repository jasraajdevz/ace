//
//  StudyComponents.swift
//  Ace
//
//  Shared components used across the study loop: the quiz choice row, Ace's
//  reply bubble, the flip card, the recall buttons and the small conversation
//  pieces.
//
//  They live in the design system rather than beside the screens that use them
//  for two reasons: the quiz, flashcard and tutor surfaces must look like one
//  product, and being here means they are compiled and type-checked by the
//  command-line build (DECISIONS.md D1) — unlike the screens themselves, which
//  are bound to SwiftData.
//

import SwiftUI

// MARK: - Choice row

/// One answer option.
struct ChoiceRow: View {
    enum State { case neutral, correct, incorrect }

    let text: String
    let state: State
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)

                Text(text)
                    .font(Typeface.body)
                    .foregroundStyle(Ink.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(border, lineWidth: state == .neutral ? 1 : 1.5)
            )
            .scaleEffect(state == .correct && !reduceMotion ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .aceAnimation(Motion.snappy, value: state)
        .accessibilityLabel(Text(text))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch state {
        case .neutral: "circle"
        case .correct: "checkmark.circle.fill"
        case .incorrect: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .neutral: Ink.textTertiary
        case .correct: Ink.success
        case .incorrect: Ink.danger
        }
    }

    private var background: Color {
        switch state {
        case .neutral: Ink.surface
        case .correct: Ink.successSoft
        case .incorrect: Ink.dangerSoft
        }
    }

    private var border: Color {
        switch state {
        case .neutral: Ink.stroke
        case .correct: Ink.success.opacity(0.55)
        case .incorrect: Ink.danger.opacity(0.45)
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .neutral: ""
        case .correct: "Correct answer"
        case .incorrect: "Your answer, incorrect"
        }
    }
}

// MARK: - Ace's reply

/// What Ace says, inline. Styled differently for a hint than for an answer so
/// the student can see at a glance whether they've been given the answer.
struct AceReplyBubble: View {
    let text: String
    var isHint: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            AceMark(size: 26)
            Text(text)
                .font(Typeface.callout)
                .foregroundStyle(Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.l)
        .background(isHint ? Ink.surfaceRaised : Ink.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(isHint ? Ink.stroke : Ink.accent.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Ace says: \(text)"))
    }
}


// MARK: - The card

/// A card that flips in 3D between its two faces.
struct FlipCard: View {
    let front: String
    let back: String
    let context: String?
    let isRevealed: Bool
    let flip: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Under Reduce Motion the faces cross-fade instead of rotating.
            if reduceMotion {
                face(isRevealed ? back : front,
                     subtitle: isRevealed ? context : nil,
                     isBack: isRevealed)
            } else {
                face(front, subtitle: nil, isBack: false)
                    .opacity(flip < 90 ? 1 : 0)
                face(back, subtitle: context, isBack: true)
                    .opacity(flip < 90 ? 0 : 1)
                    // Counter-rotate so the back isn't mirrored.
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(reduceMotion ? 0 : flip), axis: (x: 0, y: 1, z: 0))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isRevealed ? "Answer: \(back)" : "Prompt: \(front)"))
    }

    private func face(_ text: String, subtitle: String?, isBack: Bool) -> some View {
        VStack(spacing: Space.l) {
            Text(isBack ? "ANSWER" : "PROMPT")
                .font(.system(size: 10, design: .rounded).weight(.heavy))
                .tracking(2)
                .foregroundStyle(isBack ? Ink.success : Ink.textTertiary)

            Text(text)
                .font(Typeface.title3)
                .foregroundStyle(Ink.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(isBack ? Ink.successSoft : Ink.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(isBack ? Ink.success.opacity(0.4) : Ink.stroke, lineWidth: 1)
        )
        .elevation(.medium)
    }
}

/// One of the three recall buttons.
struct GradeButton: View {
    let grade: RecallGrade
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(grade.displayName)
                    .font(Typeface.footnote)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(grade.displayName))
    }

    private var symbol: String {
        switch grade {
        case .forgot: "xmark"
        case .hard: "arrow.clockwise"
        case .easy: "checkmark"
        }
    }
}


// MARK: - Pieces

/// One line of conversation.
struct TurnBubble: View {
    let turn: TutorTurn

    var body: some View {
        switch turn.speaker {
        case .ace:
            AceReplyBubble(text: turn.text, isHint: turn.isHint)
        case .student:
            HStack {
                Spacer(minLength: Space.xxl)
                Text(turn.text)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textPrimary)
                    .padding(.vertical, Space.m)
                    .padding(.horizontal, Space.l)
                    .background(Ink.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .accessibilityLabel(Text("You said: \(turn.text)"))
            }
        }
    }
}

/// The three dots while Ace thinks. Short-lived by design — if this is on screen
/// for more than a beat, something is wrong.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.m) {
            AceMark(size: 26)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Ink.textTertiary)
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 0.6 : (phase == index ? 1 : 0.3))
                }
            }
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.l)
            .background(Ink.surfaceRaised, in: Capsule())
            Spacer(minLength: 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.45).repeatForever()) { phase = 1 }
        }
        .task {
            guard !reduceMotion else { return }
            // Cycle the highlighted dot.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                phase = (phase + 1) % 3
            }
        }
        .accessibilityLabel(Text("Ace is thinking"))
    }
}

/// A one-tap thing to say.
struct QuickReply: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(Typeface.caption)
            }
            .foregroundStyle(Ink.textSecondary)
            .padding(.vertical, Space.s)
            .padding(.horizontal, Space.m)
            .background(Ink.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}


// MARK: - Study action card

/// One entry point into the study loop.
struct StudyActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    var isPreparing: Bool = false
    var isPrimary: Bool = false
    var isCompact: Bool = false
    let action: () -> Void

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Group {
                if isCompact { compactBody } else { wideBody }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPrimary ? tint.opacity(0.14) : Ink.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(isPrimary ? tint.opacity(0.4) : Ink.stroke, lineWidth: 1)
            )
            .scaleEffect(isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isPreparing ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .aceAnimation(Motion.snappy, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title). \(detail)"))
        .accessibilityAddTraits(.isButton)
    }

    private var wideBody: some View {
        HStack(spacing: Space.l) {
            icon(size: 50, glyph: 22)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(Typeface.bodyEmphasis)
                    .foregroundStyle(Ink.textPrimary)
                Text(detail)
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Ink.textTertiary)
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            icon(size: 40, glyph: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typeface.subheadline)
                    .foregroundStyle(Ink.textPrimary)
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(size: CGFloat, glyph: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: size, height: size)
            if isPreparing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(tint)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: glyph, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
    }
}
