//
//  FlashcardResultsView.swift
//  Ace
//
//  The end of a flashcard session.
//
//  Split into its own file (away from `FlashcardView`, which is bound to
//  SwiftData) so it can be compiled and type-checked by the command-line build.
//

import SwiftUI

@MainActor
struct FlashcardResultsView: View {
    let summary: FlashcardSummary
    let sessionXP: Int
    let onDone: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                Spacer(minLength: Space.xxl)

                ZStack {
                    Circle()
                        .fill(Ink.success.opacity(0.14))
                        .frame(width: 96, height: 96)
                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Ink.success)
                }

                VStack(spacing: Space.s) {
                    Text(summary.headline)
                        .font(Typeface.title2)
                        .foregroundStyle(Ink.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("\(summary.reviewed) card\(summary.reviewed == 1 ? "" : "s") reviewed")
                        .font(Typeface.callout)
                        .foregroundStyle(Ink.textSecondary)
                }

                if !appState.safety.isGamificationSuppressed {
                    AceCard {
                        HStack {
                            AceStat(value: "\(summary.easy)", label: "easy",
                                    systemImage: "checkmark", tint: Ink.success)
                            Spacer(minLength: 0)
                            AceStat(value: "\(summary.hard)", label: "hard",
                                    systemImage: "arrow.clockwise", tint: Ink.warning)
                            Spacer(minLength: 0)
                            AceStat(value: "\(summary.forgotten)", label: "forgot",
                                    systemImage: "xmark", tint: Ink.danger)
                            Spacer(minLength: 0)
                            AceStat(value: "+\(sessionXP)", label: "XP",
                                    systemImage: "bolt.fill", tint: Ink.accentAlt)
                        }
                    }

                    if summary.forgotten > 0 {
                        Text("The ones you blanked on will come back sooner next time — that's the whole trick.")
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Space.l)

                AceButton(title: "Done", systemImage: "checkmark", action: onDone)
            }
            .aceScreenPadding()
            .padding(.bottom, Space.xxl)
        }
        .scrollIndicators(.hidden)
    }
}
