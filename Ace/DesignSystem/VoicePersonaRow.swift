//
//  VoicePersonaRow.swift
//  Ace
//
//  The voice picker row. Lives in the design system rather than in a screen
//  because both onboarding and Settings use it, and both must look identical —
//  picking a voice should feel like the same act wherever you do it.
//

import SwiftUI

/// One row in the voice picker: name, personality, and a live-preview button.
struct VoicePersonaRow: View {
    let persona: VoicePersona
    let isSelected: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            Feedback.tap()
            action()
        }) {
            HStack(spacing: Space.l) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Ink.accentSoft : Ink.surfaceRaised)
                        .frame(width: 46, height: 46)
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: isPlaying ? 17 : 14, weight: .bold))
                        .foregroundStyle(isSelected ? Ink.accent : Ink.textSecondary)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(persona.displayName)
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(Ink.textPrimary)
                        Text(persona.presentation.displayName)
                            .font(Typeface.caption)
                            .foregroundStyle(Ink.textTertiary)
                    }
                    Text(persona.blurb)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isSelected ? Ink.accent : Ink.stroke)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(isSelected ? Ink.accent.opacity(0.5) : Ink.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .aceAnimation(Motion.snappy, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(persona.displayName), \(persona.presentation.displayName). \(persona.blurb)"))
        .accessibilityHint(Text("Tap to hear a preview and select"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
