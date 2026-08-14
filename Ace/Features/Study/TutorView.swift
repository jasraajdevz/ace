//
//  TutorView.swift
//  Ace
//
//  Talking a page through with Ace.
//
//  This is the screen the whole product is named after, and the thing it has to
//  do better than a chatbot is *hold back*. Every reply here is produced by
//  `SourceTutor`, which is grounded in the student's own material and refuses
//  to answer before asking (§10). This file's job is to make that feel like a
//  conversation rather than a form.
//
//  Three details that carry most of the feel:
//
//  • Ace speaks every reply as it arrives, streaming — the text appears at the
//    pace it's being said, so reading and listening stay in sync.
//  • Tapping anywhere while Ace is talking cuts it off. That's the Demo-Mode
//    version of the barge-in that Part 3 makes real over the wire.
//  • The composer never blocks. There's no "Ace is typing" lockout; you can
//    interrupt mid-sentence, which is what people actually do with a tutor.
//

import SwiftUI
import SwiftData

@MainActor
struct TutorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(PresenceCoordinator.self) private var presence
    @Environment(\.dismiss) private var dismiss

    let source: StudySource
    let gradeLevel: GradeLevel

    @State private var turns: [TutorTurn] = []
    @State private var draft = ""
    @State private var recorder: SessionRecorder?
    @State private var celebrations = CelebrationCenter()
    /// Turns the student has spent on the current point — drives the hint ladder.
    @State private var exchanges = 0
    @State private var isThinking = false
    @State private var streamedText = ""
    @State private var voice = VoiceSessionController()
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ZStack {
            AuraBackground(tint: Ink.tint(for: appState.mood.mood))

            VStack(spacing: 0) {
                transcript
                composer
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionIndicator(quality: appState.connectionQuality,
                                    isLive: appState.providerMode == .live)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if appState.isSpeaking {
                    Button {
                        Task { await appState.stopSpeaking() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Ink.accent)
                    }
                    .accessibilityLabel(Text("Stop Ace speaking"))
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .celebrations(celebrations)
        .safetyNet()
        .task {
            start()
            // Open the realtime session now, not when they first speak. This is
            // the single biggest contributor to hitting the §7 TTFA budget.
            await appState.prewarmVoice(subject: source.subject,
                                        sourceText: source.cleanedText,
                                        studentNote: source.studentNote)
        }
        .onDisappear { leave() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    materialCard

                    ForEach(turns) { turn in
                        TurnBubble(turn: turn)
                            .id(turn.id)
                    }

                    if !streamedText.isEmpty {
                        AceReplyBubble(text: streamedText)
                            .id("streaming")
                    } else if isThinking {
                        ThinkingIndicator()
                            .id("thinking")
                    }

                    Color.clear.frame(height: Space.l).id("bottom")
                }
                .aceScreenPadding()
                .padding(.top, Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Any tap in the transcript cuts Ace off — the Demo-Mode barge-in.
            .onTapGesture {
                if appState.isSpeaking {
                    Task { await appState.stopSpeaking() }
                }
            }
            .onChange(of: turns.count) { _, _ in scroll(proxy) }
            .onChange(of: streamedText) { _, _ in scroll(proxy) }
        }
    }

    /// A collapsed reminder of what's being discussed, so the student can check
    /// the source without leaving the conversation.
    private var materialCard: some View {
        DisclosureGroup {
            Text(source.cleanedText)
                .font(Typeface.reading)
                .foregroundStyle(Ink.textSecondary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .padding(.top, Space.s)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.accent)
                Text(source.studentNote.isEmpty ? "The material" : source.studentNote)
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textSecondary)
                    .lineLimit(1)
            }
        }
        .tint(Ink.accent)
        .padding(Space.l)
        .background(Ink.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Ink.stroke, lineWidth: 1)
        )
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: Space.s) {
            // One-tap shortcuts for the two things students say most, so being
            // stuck never requires composing a sentence.
            if voice.isListening {
                VoiceListeningBar(level: voice.level,
                                  isStudentSpeaking: voice.isStudentSpeaking) {
                    toggleVoice()
                }
            } else if !isThinking {
                HStack(spacing: Space.s) {
                    QuickReply(title: "I don't know", systemImage: "questionmark") {
                        send("I don't know")
                    }
                    QuickReply(title: "Just tell me", systemImage: "arrow.right.to.line") {
                        send("Just tell me")
                    }
                    Spacer(minLength: 0)
                }
            }

            if let problem = voice.problem {
                Text(problem)
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.m) {
                // Talking is the point of the product, so the mic sits to the
                // left of the composer rather than hidden behind a menu.
                Button(action: toggleVoice) {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(voice.isListening ? Ink.textOnAccent : Ink.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(voice.isListening ? AnyShapeStyle(Ink.brandGradient)
                                                      : AnyShapeStyle(Ink.surface),
                                    in: Circle())
                        .overlay(Circle().strokeBorder(
                            voice.isListening ? .clear : Ink.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(voice.isListening ? "Stop talking" : "Talk out loud"))

                // `prompt` precedes `axis` — SwiftUI's initialiser is
                // `TextField(_:text:prompt:axis:)`.
                TextField("",
                          text: $draft,
                          prompt: Text("Say what you're thinking…")
                            .foregroundStyle(Ink.textTertiary),
                          axis: .vertical)
                    .font(Typeface.body)
                    .foregroundStyle(Ink.textPrimary)
                    .lineLimit(1...4)
                    .focused($isComposerFocused)
                    .padding(.vertical, Space.m)
                    .padding(.horizontal, Space.l)
                    .background(Ink.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(isComposerFocused ? Ink.accent : Ink.stroke, lineWidth: 1)
                    )
                    .aceAnimation(Motion.snappy, value: isComposerFocused)
                    .accessibilityLabel(Text("Your message"))
                    .onSubmit { send(draft) }

                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Ink.textOnAccent)
                        .frame(width: 44, height: 44)
                        .background(draft.isBlank ? AnyShapeStyle(Ink.surfaceActive)
                                                  : AnyShapeStyle(Ink.brandGradient),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.isBlank)
                .accessibilityLabel(Text("Send"))
            }
        }
        .aceScreenPadding()
        .padding(.vertical, Space.m)
        .background(.ultraThinMaterial)
        .aceAnimation(Motion.snappy, value: isThinking)
        .aceAnimation(Motion.smooth, value: voice.isListening)
    }

    // MARK: - Conversation

    private func start() {
        guard recorder == nil else { return }
        recorder = SessionRecorder(context: modelContext, source: source,
                                   celebrations: celebrations, safety: appState.safety)
        celebrations.isSuppressed = appState.isGamificationQuiet
        appState.activeCelebrations = celebrations
        appState.beginSession()

        let opening = SourceTutor.opening(
            source: source.cleanedText,
            note: source.studentNote,
            gradeLevel: gradeLevel
        )
        turns = [TutorTurn(speaker: .ace, text: opening)]
        Task { await appState.say(opening) }
    }

    private func send(_ text: String) {
        let message = text.trimmed
        guard !message.isEmpty, !isThinking else { return }

        // The safety net runs before the message reaches the tutor, is stored,
        // or earns anything (§10).
        if appState.safety.check(message) {
            recorder?.markSafetyEngaged()
            celebrations.isSuppressed = true
            draft = ""
            return
        }

        draft = ""
        isComposerFocused = false
        turns.append(TutorTurn(speaker: .student, text: message))
        Feedback.tap()

        // Some things a student says deserve a person, not a hint. This runs
        // after the crisis net and before the tutor, and takes over when it
        // fires — answering "I'm exhausted" with a Socratic question is the
        // wrong response to the actual message (§10).
        //
        // Nothing used to call this at all, so the whole comfort layer was
        // unreachable: the responder, its phrase matching and the mute it sets
        // were all tested and none of it ever ran.
        if presence.checkComfort(message, studentName: appState.settings.name) {
            if let comfort = presence.comfortMessage {
                turns.append(TutorTurn(speaker: .ace, text: comfort))
            }
            return
        }

        Task { await respond(to: message) }
    }

    private func respond(to message: String) async {
        isThinking = true
        streamedText = ""
        await appState.stopSpeaking()

        // Read the room before replying, so the wording matches how they sound.
        appState.signals.hintsTaken = exchanges
        await appState.updateMood(text: message,
                                  subject: source.subject,
                                  sourceText: source.cleanedText,
                                  studentNote: source.studentNote)

        let intent = SourceTutor.intent(of: message)
        let reply = SourceTutor.reply(
            to: message,
            source: source.cleanedText,
            note: source.studentNote,
            exchanges: exchanges,
            mood: appState.mood.mood,
            gradeLevel: gradeLevel
        )

        // Stream the text in at reading pace while Ace says it, so the two
        // arrive together. Part 3 replaces this with the real token stream.
        isThinking = false
        presence.evaluateGuardian(signals: appState.signals, mood: appState.mood)
        for phrase in PhraseSplitter.phrases(in: reply.text) {
            streamedText += (streamedText.isEmpty ? "" : " ") + phrase
            try? await Task.sleep(for: .milliseconds(90))
        }

        turns.append(TutorTurn(speaker: .ace, text: reply.text, isHint: reply.isHint))
        streamedText = ""

        await appState.say(reply.text)

        // A reveal resets the ladder — we're on to the next point now.
        exchanges = reply.rung == .reveal ? 0 : exchanges + 1

        // Engaging with the material is the behaviour worth rewarding, so an
        // attempt pays whether or not it was right.
        if intent == .attempt {
            recorder?.award(.attemptedAnswer)
        }
        if reply.isHint {
            recorder?.recordHint()
        }
    }

    private func leave() {
        recorder?.finish(mood: appState.mood.mood)
        Task {
            await voice.stop()
            await appState.stopSpeaking()
            await appState.endVoiceSession()
        }
    }

    /// Start or stop talking out loud.
    private func toggleVoice() {
        Task {
            if voice.isListening {
                await voice.stop()
                Feedback.tap()
            } else {
                // Cut Ace off the instant the student decides to talk — the
                // manual half of barge-in (§7).
                await appState.stopSpeaking()
                let started = await voice.start(appState: appState)
                started ? Feedback.press() : Feedback.warning()
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(Motion.smooth) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}
