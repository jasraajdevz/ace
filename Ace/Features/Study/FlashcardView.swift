//
//  FlashcardView.swift
//  Ace
//
//  The flashcard drill.
//
//  The interaction is deliberately two-step — reveal, then grade — because the
//  grade is only meaningful if you commit to an answer *before* seeing the back.
//  A single "next" button would let you skim, which feels productive and teaches
//  nothing.
//
//  The card flips in 3D. It's the one piece of pure delight in the drill loop,
//  and it's the standard mental model for a flashcard, so it earns its frames.
//

import SwiftUI
import SwiftData

@MainActor
struct FlashcardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let source: StudySource
    let storedCards: [StoredFlashcard]

    @State private var runner: FlashcardRunner
    @State private var recorder: SessionRecorder?
    @State private var celebrations = CelebrationCenter()
    @State private var comment: String?
    @State private var flip: Double = 0

    init(source: StudySource, storedCards: [StoredFlashcard]) {
        self.source = source
        self.storedCards = storedCards
        let scheduled = storedCards.map {
            ScheduledCard(card: $0.asValue, state: $0.reviewState)
        }
        _runner = State(initialValue: FlashcardRunner(cards: scheduled))
    }

    var body: some View {
        ZStack {
            AuraBackground(tint: Ink.success, isStill: true)

            if runner.isFinished {
                FlashcardResultsView(
                    summary: runner.summary,
                    sessionXP: recorder?.sessionXP ?? 0,
                    onDone: finishAndLeave
                )
                .transition(.opacity)
            } else {
                cardContent
            }
        }
        .navigationTitle("Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop") { finishAndLeave() }
                    .foregroundStyle(Ink.textSecondary)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .aceAnimation(Motion.smooth, value: runner.isFinished)
        .celebrations(celebrations)
        .safetyNet()
        .task { startSession() }
        .onDisappear { Task { await appState.stopSpeaking() } }
    }

    // MARK: - Card

    @ViewBuilder private var cardContent: some View {
        if let scheduled = runner.currentCard {
            VStack(spacing: 0) {
                header

                Spacer(minLength: Space.l)

                FlipCard(
                    front: scheduled.card.front,
                    back: scheduled.card.back,
                    context: scheduled.card.context,
                    isRevealed: runner.isRevealed,
                    flip: flip
                )
                .aceScreenPadding()
                .onTapGesture { reveal() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(runner.isRevealed ? "" : "Tap to reveal the answer"))

                if let comment {
                    Text(comment)
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Space.l)
                        .aceScreenPadding()
                        .transition(.opacity)
                }

                Spacer(minLength: Space.l)

                controls
            }
            .aceAnimation(Motion.smooth, value: comment)
        } else {
            AceEmptyState(
                systemImage: "rectangle.on.rectangle",
                title: "No cards yet",
                message: "There wasn't enough in this material to build a deck from. Try a fuller page.",
                actionTitle: "Back",
                action: { dismiss() }
            )
        }
    }

    private var header: some View {
        VStack(spacing: Space.s) {
            HStack {
                Text(runner.position)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                Spacer()
                Text("\(runner.remaining) to go")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
            }
            AceProgressBar(progress: runner.progress, height: 6,
                           tint: LinearGradient(colors: [Ink.success, Ink.accentAlt],
                                                startPoint: .leading, endPoint: .trailing))
        }
        .aceScreenPadding()
        .padding(.top, Space.s)
    }

    @ViewBuilder private var controls: some View {
        if runner.isRevealed {
            VStack(spacing: Space.s) {
                Text("How did that go?")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textTertiary)

                HStack(spacing: Space.m) {
                    GradeButton(grade: .forgot, tint: Ink.danger) { grade(.forgot) }
                    GradeButton(grade: .hard, tint: Ink.warning) { grade(.hard) }
                    GradeButton(grade: .easy, tint: Ink.success) { grade(.easy) }
                }
            }
            .aceScreenPadding()
            .padding(.bottom, Space.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            AceButton(title: "Show answer", systemImage: "eye") { reveal() }
                .aceScreenPadding()
                .padding(.bottom, Space.xl)
        }
    }

    // MARK: - Actions

    private func startSession() {
        guard recorder == nil else { return }
        recorder = SessionRecorder(context: modelContext, source: source,
                                   celebrations: celebrations, safety: appState.safety)
        celebrations.isSuppressed = appState.safety.isGamificationSuppressed
        appState.beginSession()
        speakFront()
    }

    private func reveal() {
        guard !runner.isRevealed else { return }
        Feedback.tap()
        runner.reveal()
        withAnimation(Motion.smooth) { flip = 180 }

        if let back = runner.currentCard?.card.back {
            Task { await appState.say(back) }
        }
    }

    private func grade(_ grade: RecallGrade) {
        guard let outcome = runner.grade(grade) else { return }

        switch grade {
        case .easy: Feedback.correct()
        case .hard: Feedback.tap()
        case .forgot: Feedback.incorrect()
        }

        // Persist the new review state on the matching model.
        if let stored = storedCards.first(where: { $0.id == outcome.cardID }) {
            stored.record(grade)
        }
        recorder?.recordFlashcard()
        recorder?.award(outcome.xp)
        try? modelContext.save()

        comment = outcome.comment
        flip = 0

        if runner.isFinished {
            finishDeck()
        } else {
            speakFront()
        }
    }

    private func finishDeck() {
        Feedback.complete()
        recorder?.award(.finishedQuiz(score: runner.summary.recallRate))
        Task { await appState.stopSpeaking() }
    }

    private func finishAndLeave() {
        recorder?.finish(mood: appState.mood.mood)
        Task { await appState.stopSpeaking() }
        dismiss()
    }

    /// Read the prompt aloud. Hearing the question and answering out loud is
    /// most of what makes flashcards work.
    private func speakFront() {
        guard let front = runner.currentCard?.card.front else { return }
        Task { await appState.say(front) }
    }
}
