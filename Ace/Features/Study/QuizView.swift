//
//  QuizView.swift
//  Ace
//
//  The drill screen.
//
//  All the rules live in `QuizRunner` (which is fully tested); this file renders
//  it and forwards taps. The only judgement calls here are visual ones:
//
//  • The choice you picked stays visible and marked, right or wrong. Hiding it
//    makes a wrong answer feel like it never happened, which is the opposite of
//    what you want — you learn from seeing what you chose next to what was true.
//  • Ace's reply lands under the question, not in a modal. Nothing interrupts.
//  • "Hint" and "Just tell me" are always on screen. Making a student hunt for
//    help is a way of refusing it.
//

import SwiftUI
import SwiftData

@MainActor
struct QuizView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let source: StudySource
    let storedQuiz: StoredQuiz
    let gradeLevel: GradeLevel

    @State private var runner: QuizRunner
    @State private var recorder: SessionRecorder?
    @State private var aceReply: String?
    @State private var isReplyAHint = false
    @State private var isFinished = false
    @State private var celebrations = CelebrationCenter()

    init(source: StudySource, storedQuiz: StoredQuiz, gradeLevel: GradeLevel) {
        self.source = source
        self.storedQuiz = storedQuiz
        self.gradeLevel = gradeLevel
        _runner = State(initialValue: QuizRunner(quiz: storedQuiz.asValue, gradeLevel: gradeLevel))
    }

    var body: some View {
        ZStack {
            // The quiz surface stays still. Drifting blobs behind a question you
            // are trying to think about is decoration competing with focus (§8).
            AuraBackground(tint: Ink.accentAlt, isStill: true)

            if isFinished {
                QuizResultsView(
                    result: runner.result(),
                    followUp: runner.missedQuestionsQuiz(),
                    sessionXP: recorder?.sessionXP ?? 0,
                    onRedoMissed: startFollowUp,
                    onDone: finishAndLeave
                )
                .transition(.opacity)
            } else {
                quizContent
                    .transition(.opacity)
            }
        }
        .navigationTitle(storedQuiz.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop") { finishAndLeave() }
                    .foregroundStyle(Ink.textSecondary)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .aceAnimation(Motion.smooth, value: isFinished)
        .celebrations(celebrations)
        .safetyNet()
        .task { startSession() }
        .onDisappear { Task { await appState.stopSpeaking() } }
    }

    // MARK: - The question

    @ViewBuilder private var quizContent: some View {
        if let question = runner.currentQuestion {
            VStack(spacing: 0) {
                progressHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        Text(question.prompt)
                            .font(Typeface.title3)
                            .foregroundStyle(Ink.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)

                        choices(for: question)

                        if !runner.visibleHints.isEmpty {
                            hints
                        }

                        if let aceReply {
                            AceReplyBubble(text: aceReply, isHint: isReplyAHint)
                                .transition(.opacity.combined(with: .offset(y: 8)))
                        }

                        Color.clear.frame(height: Space.xxl)
                    }
                    .aceScreenPadding()
                    .padding(.top, Space.l)
                }
                .scrollIndicators(.hidden)

                actionBar(for: question)
            }
            .aceAnimation(Motion.smooth, value: aceReply)
            .aceAnimation(Motion.snappy, value: runner.currentIndex)
        } else {
            AceEmptyState(
                systemImage: "questionmark.circle",
                title: "No questions here",
                message: "There wasn't enough in this material to build a quiz from. Try adding a fuller page.",
                actionTitle: "Back",
                action: { dismiss() }
            )
        }
    }

    private var progressHeader: some View {
        VStack(spacing: Space.s) {
            HStack {
                Text("Question \(runner.questionNumber) of \(runner.questionCount)")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                Spacer()
                if runner.correctStreak >= 2 {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(runner.correctStreak) in a row")
                            .font(Typeface.caption)
                    }
                    .foregroundStyle(Ink.flame)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            AceProgressBar(progress: runner.progress, height: 6)
        }
        .aceScreenPadding()
        .padding(.top, Space.s)
        .aceAnimation(Motion.snappy, value: runner.correctStreak)
    }

    private func choices(for question: QuizQuestion) -> some View {
        VStack(spacing: Space.m) {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                ChoiceRow(
                    text: choice,
                    state: state(for: index, in: question),
                    isEnabled: !(runner.currentRecord?.wasAnswered ?? false)
                ) {
                    answer(index)
                }
            }
        }
    }

    private func state(for index: Int, in question: QuizQuestion) -> ChoiceRow.State {
        let settled = runner.currentRecord?.wasAnswered ?? false

        if settled && index == question.correctIndex { return .correct }
        if runner.selectedChoice == index {
            return question.isCorrect(index) ? .correct : .incorrect
        }
        return .neutral
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(runner.visibleHints.enumerated()), id: \.offset) { index, hint in
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.warning)
                    Text(hint)
                        .font(Typeface.callout)
                        .foregroundStyle(Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.warningSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .transition(.opacity.combined(with: .offset(y: 6)))
                .accessibilityLabel(Text("Hint \(index + 1). \(hint)"))
            }
        }
        .aceAnimation(Motion.smooth, value: runner.visibleHints.count)
    }

    private func actionBar(for question: QuizQuestion) -> some View {
        VStack(spacing: Space.m) {
            if runner.canAdvance {
                AceButton(
                    title: runner.isOnLastQuestion ? "See how you did" : "Next question",
                    systemImage: runner.isOnLastQuestion ? "flag.checkered" : "arrow.right"
                ) {
                    next()
                }
            } else {
                HStack(spacing: Space.m) {
                    AceButton(title: "Hint", systemImage: "lightbulb",
                              kind: .secondary, isEnabled: runner.hasMoreHints) {
                        takeHint()
                    }
                    AceButton(title: "Just tell me", kind: .ghost) {
                        reveal()
                    }
                }
            }
        }
        .aceScreenPadding()
        .padding(.bottom, Space.l)
        .padding(.top, Space.s)
        .background(.ultraThinMaterial)
        .aceAnimation(Motion.snappy, value: runner.canAdvance)
    }

    // MARK: - Actions

    private func startSession() {
        guard recorder == nil else { return }
        recorder = SessionRecorder(context: modelContext, source: source,
                                   celebrations: celebrations, safety: appState.safety)
        celebrations.isSuppressed = appState.isGamificationQuiet
        appState.activeCelebrations = celebrations
        appState.beginSession()
    }

    private func answer(_ index: Int) {
        guard let outcome = runner.answer(index) else { return }

        outcome.wasCorrect ? Feedback.correct() : Feedback.incorrect()
        recorder?.recordAnswer(correct: outcome.scoredCorrect)
        recorder?.award(outcome.xp)

        aceReply = outcome.reply.text
        isReplyAHint = outcome.reply.isHint

        speak(outcome.reply.text)
        refreshMood()
    }

    private func takeHint() {
        guard let hint = runner.takeHint() else { return }
        Feedback.tap()
        recorder?.recordHint()
        aceReply = nil
        speak(hint)
        refreshMood()
    }

    private func reveal() {
        guard let reply = runner.revealAnswer() else { return }
        Feedback.tap()
        recorder?.recordAnswer(correct: false)
        aceReply = reply.text
        isReplyAHint = false
        speak(reply.text)
    }

    private func next() {
        aceReply = nil
        if runner.advance() {
            Feedback.tap()
        } else {
            finishQuiz()
        }
    }

    private func finishQuiz() {
        let result = runner.result()
        storedQuiz.recordAttempt(score: result.score)
        recorder?.award(.finishedQuiz(score: result.score))
        try? modelContext.save()
        Feedback.complete()
        isFinished = true
        Task { await appState.stopSpeaking() }
    }

    /// Restart the runner on just the questions that were missed.
    private func startFollowUp() {
        guard let followUp = runner.missedQuestionsQuiz() else { return }
        runner = QuizRunner(quiz: followUp, gradeLevel: gradeLevel)
        aceReply = nil
        isFinished = false
        Feedback.tap()
    }

    private func finishAndLeave() {
        recorder?.finish(mood: appState.mood.mood)
        Task { await appState.stopSpeaking() }
        dismiss()
    }

    private func speak(_ text: String) {
        Task { await appState.say(text) }
    }

    /// Feed the run's behavioural signals into the mood read, so Ace's delivery
    /// tracks how the quiz is actually going (§9).
    private func refreshMood() {
        appState.signals = runner.signals
        Task { await appState.updateMood() }
    }
}
