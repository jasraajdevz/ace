//
//  SpeakingDrillView.swift
//  Ace
//
//  "Explain it to me."
//
//  Record, transcribe, score, and say the one thing worth fixing. The scoring
//  lives in `SpeakingDrillScorer` (fully tested); this screen's job is to make
//  the act of talking feel low-stakes enough that people actually do it.
//
//  Which is mostly about what *isn't* here: no countdown, no minimum length, no
//  score until you've finished, and an explicit "that was rubbish, delete it"
//  escape. Recording yourself explaining something you half-understand is
//  uncomfortable; the UI should not add to that.
//

import SwiftUI
import SwiftData

@MainActor
struct SpeakingDrillView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let source: StudySource

    @State private var stage: Stage = .ready
    @State private var voice = VoiceSessionController()
    @State private var transcript = ""
    @State private var feedback: SpeakingFeedback?
    @State private var history = SpeakingHistory()
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var recorder: SessionRecorder?
    @State private var celebrations = CelebrationCenter()
    @State private var problem: String?

    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private enum Stage: Equatable {
        case ready
        case recording
        case scoring
        case scored
    }

    var body: some View {
        ZStack {
            AuraBackground(tint: Ink.warning, isStill: stage == .recording)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    prompt

                    switch stage {
                    case .ready:
                        readyState
                    case .recording:
                        recordingState
                    case .scoring:
                        AceLoadingState(message: "Listening back…", rows: 3)
                    case .scored:
                        if let feedback { scoredState(feedback) }
                    }

                    if let problem {
                        Text(problem)
                            .font(Typeface.footnote)
                            .foregroundStyle(Ink.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .aceScreenPadding()
                .padding(.top, Space.l)
                .padding(.bottom, Space.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Explain it")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onReceive(clock) { _ in
            if stage == .recording, let startedAt {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        .aceAnimation(Motion.smooth, value: stage)
        .celebrations(celebrations)
        .safetyNet()
        .task { start() }
        .onDisappear { finish() }
    }

    // MARK: - Sections

    private var prompt: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AceScreenTitle(
                title: promptText,
                subtitle: "Out loud, in your own words. It's meant to come out messy — that's how you find the gaps."
            )

            if history.attempts > 0 {
                Text(history.trendSummary)
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Built from the material's own top term, so the drill is about something
    /// specific rather than "explain the chapter".
    private var promptText: String {
        let terms = TextAnalysis.keyTerms(in: source.cleanedText, limit: 1)
        guard let top = terms.first else { return "Explain what you just read." }
        return "Explain \(top.term)."
    }

    private var readyState: some View {
        VStack(spacing: Space.l) {
            AceButton(title: "Start talking", systemImage: "mic.fill") { beginRecording() }

            Text("Nothing is saved except the score. Ace transcribes on your device.")
                .font(Typeface.caption)
                .foregroundStyle(Ink.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var recordingState: some View {
        VStack(spacing: Space.l) {
            VoiceListeningBar(level: voice.level,
                              isStudentSpeaking: voice.isStudentSpeaking) {
                endRecording()
            }

            Text(timeText)
                .font(Typeface.numeric(.title2))
                .foregroundStyle(Ink.textSecondary)
                .frame(maxWidth: .infinity)

            // No minimum, no countdown — but a gentle marker at the point where
            // an explanation usually becomes scoreable.
            if elapsed < 15 {
                Text("Keep going — twenty seconds or so gives me something to work with.")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            AceButton(title: "Done", systemImage: "stop.fill", kind: .secondary) {
                endRecording()
            }
        }
    }

    private func scoredState(_ feedback: SpeakingFeedback) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // The headline, then the three axes.
            VStack(alignment: .leading, spacing: Space.m) {
                Text(feedback.score.band.headline)
                    .font(Typeface.title2)
                    .foregroundStyle(Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                AceCard {
                    VStack(spacing: Space.m) {
                        axis("Clarity", feedback.score.clarity, Ink.accent)
                        axis("Structure", feedback.score.structure, Ink.accentAlt)
                        axis("Confidence", feedback.score.confidence, Ink.success)
                    }
                }
            }

            // What went well — always first.
            VStack(alignment: .leading, spacing: Space.s) {
                Label("What worked", systemImage: "checkmark.circle.fill")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.success)
                Text(feedback.strength)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one thing to fix.
            VStack(alignment: .leading, spacing: Space.s) {
                Label("Next time", systemImage: "arrow.right.circle.fill")
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.warning)
                Text(feedback.focus)
                    .font(Typeface.callout)
                    .foregroundStyle(Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !feedback.missedTerms.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("You didn't mention")
                        .font(Typeface.footnote)
                        .foregroundStyle(Ink.textTertiary)
                    FlowLayout(spacing: Space.s) {
                        ForEach(feedback.missedTerms, id: \.self) { term in
                            Text(term)
                                .font(Typeface.caption)
                                .foregroundStyle(Ink.textSecondary)
                                .padding(.vertical, Space.s)
                                .padding(.horizontal, Space.m)
                                .background(Ink.surfaceRaised, in: Capsule())
                        }
                    }
                }
            }

            if !transcript.isEmpty {
                DisclosureGroup("What I heard") {
                    Text(transcript)
                        .font(Typeface.reading)
                        .foregroundStyle(Ink.textSecondary)
                        .padding(.top, Space.s)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Ink.textTertiary)
                .font(Typeface.footnote)
            }

            VStack(spacing: Space.m) {
                AceButton(title: "Go again", systemImage: "arrow.counterclockwise") {
                    reset()
                }
                AceButton(title: "Done", kind: .ghost) { dismiss() }
            }
        }
    }

    private func axis(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(label)
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textSecondary)
                Spacer()
                Text("\(Int((value * 100).rounded()))")
                    .font(Typeface.numeric(.footnote))
                    .foregroundStyle(Ink.textPrimary)
            }
            AceProgressBar(progress: value, height: 6,
                           tint: LinearGradient(colors: [tint, tint.opacity(0.55)],
                                                startPoint: .leading, endPoint: .trailing),
                           showsGlow: false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(Int(value * 100)) out of 100"))
    }

    private var timeText: String {
        String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    }

    // MARK: - Actions

    private func start() {
        guard recorder == nil else { return }
        recorder = SessionRecorder(context: modelContext, source: source,
                                   celebrations: celebrations, safety: appState.safety)
        celebrations.isSuppressed = appState.isGamificationQuiet
        appState.activeCelebrations = celebrations
        appState.beginSession()
        history = SpeakingHistoryStore.load(for: source)
    }

    private func beginRecording() {
        problem = nil
        transcript = ""
        elapsed = 0

        Task {
            let started = await voice.start(appState: appState)
            if started {
                // The clock starts when the microphone does, not when the button
                // was tapped. `voice.start` requests permission, and on first use
                // that system prompt can sit on screen for several seconds —
                // every one of which used to count as speaking time, inflating
                // both the scored duration and the "was that long enough" gate.
                startedAt = Date()
                stage = .recording
                Feedback.press()
            } else {
                problem = voice.problem
                    ?? "Ace needs the microphone for this. Typing works everywhere else."
                Feedback.warning()
            }
        }
    }

    private func endRecording() {
        stage = .scoring
        Feedback.tap()

        Task {
            await voice.stop()
            let spoken = elapsed

            // In Live Mode the realtime session has already transcribed them; in
            // Demo Mode `transcribe` falls through to on-device recognition.
            let heard = (try? await appState.provider.transcribe(audio: Data())) ?? ""
            transcript = heard

            // Anything the student said goes through the safety net before it's
            // scored, stored, or replied to (§10).
            if appState.safety.check(heard) {
                stage = .ready
                return
            }

            let result = SpeakingDrillScorer.score(
                transcript: heard,
                sourceText: source.cleanedText,
                voice: appState.providers.live?.voiceReading ?? .none,
                duration: spoken
            )
            feedback = result
            history.record(result.score)
            SpeakingHistoryStore.save(history, for: source)

            if !result.isTooShort {
                recorder?.award(.explainedOutLoud(clarity: result.score.clarity))
            }
            stage = .scored
            Feedback.complete()

            // Ace says the one thing to work on — hearing feedback about
            // speaking lands better than reading it.
            await appState.say(result.strength + " " + result.focus)
        }
    }

    private func reset() {
        feedback = nil
        transcript = ""
        elapsed = 0
        stage = .ready
    }

    private func finish() {
        Task {
            await voice.stop()
            await appState.stopSpeaking()
        }
        recorder?.finish(mood: appState.mood.mood)
    }
}

// MARK: - History storage

/// Speaking history per source.
///
/// Stored in `UserDefaults` rather than SwiftData: it's a handful of numbers per
/// source, it's read once when the drill opens, and adding a model + migration
/// for it would be more machinery than the data deserves.
enum SpeakingHistoryStore {

    private static func key(for source: StudySource) -> String {
        // Shared with `AppReset`, which sweeps this prefix. Written out twice,
        // the sweep would keep passing while cleaning nothing.
        AppReset.speakingHistoryPrefix + source.id.uuidString
    }

    static func load(for source: StudySource) -> SpeakingHistory {
        guard let data = UserDefaults.standard.data(forKey: key(for: source)),
              let scores = try? JSONDecoder().decode([SpeakingScore].self, from: data) else {
            return SpeakingHistory()
        }
        return SpeakingHistory(scores: scores)
    }

    static func save(_ history: SpeakingHistory, for source: StudySource) {
        guard let data = try? JSONEncoder().encode(history.scores) else { return }
        UserDefaults.standard.set(data, forKey: key(for: source))
    }
}
