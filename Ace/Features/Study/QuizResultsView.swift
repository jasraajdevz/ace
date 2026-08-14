//
//  QuizResultsView.swift
//  Ace
//
//  What you see when the quiz ends.
//
//  The design brief for this screen is one sentence: **make the next action
//  obvious and make it the useful one.** A results screen that just says "60%"
//  and offers "Done" wastes the most teachable moment in the whole loop. So the
//  primary button redoes only the questions you missed.
//
//  And per §10, the copy scales with the score without ever tipping into
//  disappointment. A bad round is information.
//

import SwiftUI

@MainActor
struct QuizResultsView: View {
    let result: QuizResult
    /// The missed-questions quiz, when there is one.
    let followUp: Quiz?
    let sessionXP: Int
    let onRedoMissed: () -> Void
    let onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var ringProgress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The safety net mutes every number on this screen (§10).
    private var isSuppressed: Bool { appState.isGamificationQuiet }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.xl) {
                Spacer(minLength: Space.xl)

                if isSuppressed {
                    quietSummary
                } else {
                    scoreRing
                    verdict
                    stats
                }

                Spacer(minLength: Space.l)
                actions
            }
            .aceScreenPadding()
            .padding(.bottom, Space.xxl)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            guard !isSuppressed else { return }
            if reduceMotion {
                ringProgress = result.score
            } else {
                withAnimation(.easeOut(duration: 0.9).delay(0.1)) {
                    ringProgress = result.score
                }
            }
        }
    }

    // MARK: - Pieces

    private var scoreRing: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 200, height: 200)
                .blur(radius: 36)

            AceProgressRing(progress: ringProgress, lineWidth: 12,
                            tint: LinearGradient(colors: [tint, tint.opacity(0.6)],
                                                 startPoint: .top, endPoint: .bottom))
                .frame(width: 176, height: 176)

            VStack(spacing: Space.xs) {
                Text(result.percentText)
                    .font(.system(size: 46, design: .rounded).weight(.heavy))
                    .foregroundStyle(Ink.textPrimary)
                    .monospacedDigit()
                Text("\(result.correctCount) of \(result.totalCount)")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textTertiary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Scored \(result.percentText), \(result.correctCount) of \(result.totalCount) correct"))
    }

    private var verdict: some View {
        VStack(spacing: Space.s) {
            Text(headline)
                .font(Typeface.title2)
                .foregroundStyle(Ink.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(Typeface.callout)
                .foregroundStyle(Ink.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var stats: some View {
        AceCard {
            HStack {
                AceStat(value: "+\(sessionXP)", label: "XP earned",
                        systemImage: "bolt.fill", tint: Ink.accentAlt)
                Spacer(minLength: 0)
                AceStat(value: "\(result.missedQuestionIDs.count)", label: "to revisit",
                        systemImage: "arrow.uturn.left", tint: Ink.warning)
                Spacer(minLength: 0)
                AceStat(value: timeText, label: "taken",
                        systemImage: "clock", tint: Ink.success)
            }
        }
    }

    /// What the results screen becomes after a safety event: no score, no XP,
    /// no celebration. Just a way out.
    private var quietSummary: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Ink.textSecondary)
            Text("That's the quiz done.")
                .font(Typeface.title3)
                .foregroundStyle(Ink.textPrimary)
            Text("No score today — it doesn't matter. Come back to it whenever you want.")
                .font(Typeface.callout)
                .foregroundStyle(Ink.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.xxl)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: Space.m) {
            if let followUp, !followUp.questions.isEmpty, !isSuppressed {
                AceButton(
                    title: "Redo the \(followUp.questions.count) you missed",
                    systemImage: "arrow.counterclockwise"
                ) {
                    onRedoMissed()
                }
                AceButton(title: "I'm done", kind: .ghost, action: onDone)
            } else {
                AceButton(title: "Done", systemImage: "checkmark", action: onDone)
            }
        }
    }

    // MARK: - Copy

    private var tint: Color {
        switch result.score {
        case 0.85...: Ink.success
        case 0.5..<0.85: Ink.accent
        default: Ink.warning
        }
    }

    private var headline: String {
        switch result.score {
        case 1.0: "Clean sweep."
        case 0.85..<1.0: "That's a strong round."
        case 0.6..<0.85: "Solid — and now you know the gaps."
        case 0.3..<0.6: "Good. The shaky bits are obvious now."
        default: "Early days with this one."
        }
    }

    private var subtitle: String {
        let missed = result.missedQuestionIDs.count
        if missed == 0 {
            return "Nothing left to revisit here. Worth trying a harder page."
        }
        if result.score < 0.4 {
            return "This is exactly what a first pass looks like. Let's go again on the \(missed) that got you."
        }
        return missed == 1
            ? "One question got you. Let's fix that one."
            : "\(missed) questions got you. Those are the ones worth another go."
    }

    private var timeText: String {
        let minutes = Int(result.elapsed / 60)
        let seconds = Int(result.elapsed) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
