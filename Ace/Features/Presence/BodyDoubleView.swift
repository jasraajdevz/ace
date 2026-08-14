//
//  BodyDoubleView.swift
//  Ace
//
//  Study-with-me.
//
//  The whole screen is a timer, a goal, and a lot of empty space. That's the
//  design: the point of body doubling is that somebody is *there*, not that
//  something is happening. Anything on this surface competing for attention
//  would defeat it.
//
//  Everything else on screen appears only when it has a reason to: a check-in,
//  a Guardian offer, a comfort card. Each one is small, low-contrast, and
//  ignorable.
//

import SwiftUI
import SwiftData

@MainActor
struct BodyDoubleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let source: StudySource?

    @Environment(PresenceCoordinator.self) private var presence
    @State private var recorder: SessionRecorder?
    @State private var celebrations = CelebrationCenter()
    @State private var goalDraft = ""
    @State private var now = Date()
    @State private var isShowingMusic = false
    @FocusState private var isGoalFocused: Bool

    /// Refreshes the clock. One second is plenty — this is a study timer, not a
    /// stopwatch.
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Quiet mode drains the colour out of the surface (§Part 4:
            // "calm the UI into a low-stimulation study surface").
            if presence.doNotDisturb.isOn && presence.doNotDisturb.calmsInterface {
                Ink.calmBackground.ignoresSafeArea()
            } else {
                AuraBackground(tint: Ink.calm, secondaryTint: Ink.accentAlt,
                               isStill: presence.isSessionActive)
            }

            switch presence.session.phase {
            case .settingGoal:
                goalSetting
            case .working, .paused:
                workingSurface
            case .finished:
                finishedSurface
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if presence.isSessionActive {
                    Button {
                        presence.toggleDoNotDisturb()
                    } label: {
                        Image(systemName: presence.doNotDisturb.isOn ? "moon.fill" : "moon")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(presence.doNotDisturb.isOn ? Ink.calm : Ink.textSecondary)
                    }
                    .accessibilityLabel(Text(presence.doNotDisturb.isOn
                                             ? "Quiet mode on" : "Quiet mode off"))
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onReceive(clock) { now = $0 }
        .presenceLifecycle(presence)
        .celebrations(celebrations)
        .safetyNet()
        .aceAnimation(Motion.smooth, value: presence.session.phase)
        .onDisappear { end() }
    }

    // MARK: - Setting the goal

    private var goalSetting: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                AceScreenTitle(
                    title: "What are we doing?",
                    subtitle: "Tell me the plan and I'll sit with you while you do it. I'll stay quiet unless you need me."
                )

                // `prompt` precedes `axis` — SwiftUI's initialiser is
                // `TextField(_:text:prompt:axis:)`.
                TextField("",
                          text: $goalDraft,
                          prompt: Text("let's go till chapter 4")
                            .foregroundStyle(Ink.textTertiary),
                          axis: .vertical)
                    .font(Typeface.title3)
                    .foregroundStyle(Ink.textPrimary)
                    .lineLimit(1...3)
                    .focused($isGoalFocused)
                    .padding(Space.l)
                    .background(Ink.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .strokeBorder(isGoalFocused ? Ink.calm : Ink.stroke, lineWidth: 1)
                    )
                    .aceAnimation(Motion.snappy, value: isGoalFocused)
                    .accessibilityLabel(Text("Your goal for this session"))

                FlowLayout(spacing: Space.s) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        AceChip(title: suggestion, isSelected: false, tint: Ink.calm) {
                            goalDraft = suggestion
                        }
                    }
                }

                AceButton(title: "Start", systemImage: "play.fill") { begin() }

                DoNotDisturbToggle(state: presence.doNotDisturb) {
                    presence.toggleDoNotDisturb()
                }

                musicSection
            }
            .aceScreenPadding()
            .padding(.top, Space.l)
            .padding(.bottom, Space.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var suggestions: [String] {
        var out = ["25 minutes", "45 minutes", "10 questions"]
        if let title = source?.title, !title.isEmpty {
            out.insert("finish \(title)", at: 0)
        }
        return out
    }

    // MARK: - Working

    private var workingSurface: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            SessionTimer(
                elapsed: presence.session.elapsed(now: now),
                progress: presence.session.progress(now: now).fraction,
                goalText: presence.goal?.displayText ?? "",
                isMeasurable: presence.goal?.isMeasurable ?? false
            )
            .opacity(presence.session.phase == .paused ? 0.45 : 1)

            // Everything below appears only when there's a reason.
            VStack(spacing: Space.m) {
                if let comfort = presence.comfortMessage {
                    ComfortCard(message: comfort) { presence.dismissComfort() }
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if let nudge = presence.activeNudge {
                    GuardianNudgeCard(nudge: nudge,
                                      onAccept: { accept() },
                                      onDismiss: { presence.dismissNudge() })
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                if let message = presence.presenceMessage {
                    PresenceBanner(message: message) { presence.dismissPresenceMessage() }
                        .transition(.opacity)
                }
            }
            .aceScreenPadding()
            .aceAnimation(Motion.smooth, value: presence.activeNudge?.id)
            .aceAnimation(Motion.smooth, value: presence.presenceMessage?.id)
            .aceAnimation(Motion.smooth, value: presence.comfortMessage)

            Spacer()

            controls
        }
    }

    private var controls: some View {
        VStack(spacing: Space.m) {
            if presence.goal?.isMeasurable == false {
                AceButton(title: "I got there", systemImage: "checkmark",
                          kind: .secondary) {
                    presence.markLandmarkReached()
                }
            }

            HStack(spacing: Space.m) {
                AceButton(title: presence.session.phase == .paused ? "Resume" : "Pause",
                          systemImage: presence.session.phase == .paused ? "play.fill" : "pause.fill",
                          kind: .secondary) {
                    presence.session.phase == .paused
                        ? presence.resumeSession()
                        : presence.pauseSession()
                }

                AceButton(title: "Finish", kind: .ghost) { presence.finishSession() }
            }

            Button {
                Feedback.tap()
                isShowingMusic.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: presence.music.scene.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(presence.music.scene == .off ? "Add some sound"
                                                      : presence.music.scene.displayName)
                        .font(Typeface.caption)
                }
                .foregroundStyle(Ink.textTertiary)
            }
            .buttonStyle(.plain)

            if isShowingMusic {
                musicSection.transition(.opacity)
            }
        }
        .aceScreenPadding()
        .padding(.bottom, Space.xl)
        .aceAnimation(Motion.smooth, value: isShowingMusic)
    }

    private var musicSection: some View {
        FocusMusicPicker(
            current: presence.music.scene,
            volume: presence.music.mix.userVolume,
            onSelect: { presence.music.play($0) },
            onVolume: { presence.music.setVolume($0) }
        )
    }

    // MARK: - Finished

    private var finishedSurface: some View {
        VStack(spacing: Space.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Ink.calm.opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Ink.calm)
            }

            if let message = presence.presenceMessage {
                Text(message.text)
                    .font(Typeface.body)
                    .foregroundStyle(Ink.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .aceScreenPadding()
            }

            AceCard {
                HStack {
                    AceStat(value: "\(presence.session.elapsedMinutes(now: now))",
                            label: "minutes", systemImage: "clock", tint: Ink.calm)
                    Spacer(minLength: 0)
                    if let recorder {
                        AceStat(value: "+\(recorder.sessionXP)", label: "XP",
                                systemImage: "bolt.fill", tint: Ink.accentAlt)
                    }
                }
            }
            .aceScreenPadding()

            Spacer()

            AceButton(title: "Done") { dismiss() }
                .aceScreenPadding()
                .padding(.bottom, Space.xl)
        }
    }

    // MARK: - Actions

    private func begin() {
        let goal = GoalParser.parse(goalDraft.isBlank ? "25 minutes" : goalDraft)

        // The goal is free text the student typed, so it goes through the
        // safety net like everything else (§10).
        guard !appState.safety.check(goal.rawText) else { return }

        recorder = SessionRecorder(context: modelContext, source: source,
                                   celebrations: celebrations, safety: appState.safety)
        celebrations.isSuppressed = appState.isGamificationQuiet
        appState.activeCelebrations = celebrations
        appState.beginSession()
        isGoalFocused = false
        presence.begin(goal: goal, appState: appState)
        Feedback.press()
    }

    private func accept() {
        let action = presence.acceptNudge()
        switch action {
        case .suggestBreak:
            presence.pauseSession()
        case .welcomeBack, .checkIn, .offerHint, .reexplain, .easeOff, .none:
            // The study surfaces own the teaching actions; from here, taking
            // the offer simply acknowledges it.
            break
        }
    }

    private func end() {
        if presence.isSessionActive { presence.finishSession() }

        // `finishSession` has just worked out whether the goal was reached —
        // use it. Awarding the goal bonus unconditionally, which is what used to
        // happen, paid the student for quitting thirty seconds in and made the
        // reward mean nothing (§10).
        let metGoal = presence.session.phase.metGoal
        if metGoal { recorder?.award(.metGoal) }
        recorder?.finish(mood: appState.mood.mood, goal: presence.goal, metGoal: metGoal)
        presence.music.stop()
        Task { await appState.stopSpeaking() }
    }
}
