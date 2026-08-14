//
//  AceApp.swift
//  Ace
//
//  Entry point. Sets up the SwiftData container, the app state (which owns the
//  AI provider), and hands off to `RootView`.
//

import SwiftUI
import SwiftData
import AVFoundation

@main
struct AceApp: App {

    /// The one `AppState` for the whole app. It starts on `MockAIProvider`, so
    /// the app is fully functional with no key, no account and no network (§5).
    @State private var appState = AppState()
    /// Owned here so it outlives any one screen — see the note at `.environment`.
    @State private var presence = PresenceCoordinator()
    /// Held for the app's lifetime; StoreKit cancels the listener if it isn't.
    @State private var transactionListener: Task<Void, Never>?

    /// The SwiftData stack.
    ///
    /// Built here rather than with the `.modelContainer(for:)` modifier so a
    /// failure has somewhere to go: if the on-disk store is corrupt or
    /// incompatible we fall back to an in-memory container. The student gets a
    /// working app instead of a launch crash, which is always the right trade.
    private let container: ModelContainer

    init() {
        let schema = Schema(AceSchema.models)
        do {
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            )
        } catch {
            // Last resort — never crash on launch.
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }

        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                // Presence is app-scoped, not screen-scoped.
                //
                // It used to be `@State` inside `BodyDoubleView`, which meant the
                // body-double session, the goal, the Guardian, Do Not Disturb and
                // the focus music all existed only while that one screen was on
                // top — and the quiz, flashcard and tutor screens had no way to
                // reach any of it. Setting a goal of "10 questions" and then going
                // to the quiz meant nothing counted, because `recordProgress` had
                // no reachable receiver.
                .environment(presence)
                // Dark-only by design — see DECISIONS.md.
                .preferredColorScheme(.dark)
                .tint(Ink.accent)
                .task {
                    // Warm the feedback layers so the first tap isn't silent
                    // and the first haptic isn't late.
                    SoundCuePlayer.shared.prepare()
                    Haptic.prepare()

                    // Renewals and revocations that happen outside the app.
                    // The returned Task has to be held or it is cancelled
                    // immediately on release.
                    if transactionListener == nil {
                        transactionListener = appState.store.startTransactionListener()
                    }
                }
        }
        .modelContainer(container)
    }

    /// Set up audio once, at launch.
    ///
    /// `.playback` with `.mixWithOthers` and `.duckOthers` means Ace's voice
    /// lowers the student's music rather than stopping it — which is the
    /// behaviour Part 4's focus music depends on, and the polite default
    /// regardless.
    private func configureAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // A device that won't give us an audio session still runs — it just
            // won't speak. Handled gracefully at every call site.
        }
        #endif
    }
}

// MARK: - Root

/// Decides between onboarding and the app, and owns nothing else.
@MainActor
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Query private var profiles: [Profile]

    @State private var didBootstrap = false
    @State private var importNotice: String?
    @State private var shouldOpenCapture = false
    @Environment(\.scenePhase) private var scenePhase

    private var profile: Profile? { profiles.first }

    var body: some View {
        Group {
            if let profile {
                if profile.hasCompletedOnboarding {
                    HomeView(profile: profile)
                        .transition(.opacity)
                } else {
                    OnboardingView(profile: profile)
                        .transition(.opacity)
                }
            } else {
                // The very first frame, before the profile row exists. A
                // designed splash rather than a blank screen — it matches the
                // launch screen exactly, so the handoff is invisible.
                LaunchPlaceholder()
            }
        }
        .aceAnimation(Motion.smooth, value: profile?.hasCompletedOnboarding)
        // Anything shared into Ace from another app is picked up here, on the
        // way back to the front (§Part 5).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, profile?.hasCompletedOnboarding == true else { return }
            Task { await drainSharedContent() }
        }
        .overlay(alignment: .top) {
            if let importNotice {
                Text(importNotice)
                    .font(Typeface.footnote)
                    .foregroundStyle(Ink.textPrimary)
                    .padding(.vertical, Space.s)
                    .padding(.horizontal, Space.l)
                    .background(Ink.surfaceRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
                    .elevation(.medium)
                    .padding(.top, Space.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .aceAnimation(Motion.smooth, value: importNotice)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true

            let profile = ProfileStore.fetchOrCreate(in: modelContext)
            _ = ProgressStore.fetchOrCreate(in: modelContext)
            DemoContent.installIfNeeded(in: modelContext)
            appState.apply(profile.settings)
            WidgetBridge.refresh(from: modelContext)
            await appState.store.refreshEntitlements()
            await drainSharedContent()
        }
    }

    /// Import anything the share extension left behind, and honour a quick-
    /// capture tap from the widget.
    private func drainSharedContent() async {
        // The widget's capture button asks for the camera; consuming the request
        // here means it survives a cold launch.
        if QuickCaptureRequest.consume() {
            shouldOpenCapture = true
        }

        guard ShareInbox.hasPendingItems else { return }
        let result = await ShareImporter.drain(
            into: modelContext,
            provider: appState.provider,
            gradeLevel: appState.gradeLevel,
            safety: appState.safety
        )
        guard let message = result.message else { return }
        importNotice = message
        Feedback.complete()

        try? await Task.sleep(for: .seconds(3))
        importNotice = nil
    }
}

/// Matches the static launch screen so the transition into the app is seamless.
struct LaunchPlaceholder: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Ink.background.ignoresSafeArea()
            AceMark(size: 96)
                .scaleEffect(pulse ? 1.0 : 0.94)
                .opacity(pulse ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityLabel(Text("Ace is starting"))
    }
}
