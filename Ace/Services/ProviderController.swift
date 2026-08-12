//
//  ProviderController.swift
//  Ace
//
//  Owns the Demo ↔ Live switch (§5).
//
//  This is the only place in the app that knows both providers exist. Everything
//  else holds an `AIProvider` and never asks which one it is. That's what makes
//  the seam real rather than decorative — and it's why Part 3 added Live Mode
//  without touching a single screen in the study loop.
//
//  The rule that governs every branch here: **Demo Mode is the floor.** No key,
//  a bad key, no network, a dropped socket, a rate limit — all of them land in
//  the same place, which is an app that still works.
//

import Foundation
import Observation

/// What the student chose in Settings.
enum ProviderPreference: String, Codable, Sendable, CaseIterable {
    /// Always on-device, even if a key is stored.
    case alwaysDemo
    /// Use Live when a key is available; fall back silently otherwise.
    case preferLive

    var displayName: String {
        switch self {
        case .alwaysDemo: "On-device only"
        case .preferLive: "Use my key"
        }
    }

    var detail: String {
        switch self {
        case .alwaysDemo: "Free, private, works offline. Ace uses the system voice."
        case .preferLive: "Faster, more natural conversation. Falls back on its own if the connection drops."
        }
    }
}

@MainActor
@Observable
final class ProviderController {

    private static let preferenceKey = "ace.provider.preference"
    private static let modelKey = "ace.provider.model"

    /// The provider the app should use right now.
    private(set) var current: AIProvider

    /// The live provider, when one exists. Kept separately so Settings can read
    /// its latency stats and the tutor can prewarm it.
    private(set) var live: OpenAIRealtimeProvider?

    private let demo = MockAIProvider()
    private let player = RealtimeAudioPlayer()

    var preference: ProviderPreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
            Task { await refresh() }
        }
    }

    /// Which realtime model to use. Overridable because model names change
    /// faster than app releases.
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }

    /// True when a key is in the Keychain.
    private(set) var hasKey: Bool = false
    /// A masked identifier for the stored key. Never the key itself.
    private(set) var keyFingerprint: String?

    /// Result of the last self-test, shown in Settings.
    var lastTestResult: ConnectionTestResult?
    var isTesting = false

    /// Set when Live Mode gave up and handed back to Demo. Surfaced once, warmly.
    private(set) var fallbackNotice: String?

    init() {
        self.current = demo
        self.preference = UserDefaults.standard.string(forKey: Self.preferenceKey)
            .flatMap(ProviderPreference.init(rawValue:)) ?? .preferLive
        self.model = UserDefaults.standard.string(forKey: Self.modelKey) ?? RealtimeModel.default
        loadKeyState()
    }

    // MARK: - The key

    private func loadKeyState() {
        if let key = KeychainService.load() {
            hasKey = true
            keyFingerprint = APIKeyFormat.fingerprint(key)
        } else {
            hasKey = false
            keyFingerprint = nil
        }
    }

    /// Store a key. Returns nil on success, or a message explaining the problem.
    @discardableResult
    func saveKey(_ raw: String) async -> String? {
        let validation = APIKeyFormat.validate(raw)
        guard validation.isUsable else {
            return validation.message ?? "That doesn't look like a key."
        }
        guard KeychainService.store(raw) else {
            return "Couldn't save that to the Keychain."
        }
        loadKeyState()
        lastTestResult = nil
        await refresh()
        return nil
    }

    func removeKey() async {
        KeychainService.delete()
        loadKeyState()
        lastTestResult = nil
        await refresh()
    }

    // MARK: - Switching

    /// Bring `current` in line with the preference and what's actually available.
    func refresh() async {
        let shouldUseLive = preference == .preferLive && hasKey

        guard shouldUseLive else {
            if live != nil {
                await live?.disconnect()
                live = nil
            }
            current = demo
            return
        }

        guard let key = KeychainService.load() else {
            current = demo
            return
        }

        // Reuse the existing live provider unless the model changed.
        if live == nil {
            let provider = OpenAIRealtimeProvider(apiKey: key, model: model)
            provider.audioSink = player
            live = provider
        }
        current = live ?? demo
    }

    /// Open the realtime session ahead of a study session (§7's biggest win).
    ///
    /// Returns the provider the caller should actually use — which is Demo Mode
    /// if the connection didn't come up.
    @discardableResult
    func prewarmForSession(settings: StudentSettings,
                           subject: Subject?,
                           sourceText: String,
                           studentNote: String,
                           mood: MoodReading) async -> AIProvider {
        guard let live else { return demo }

        var config = RealtimeSessionConfig(
            instructions: RealtimeInstructions.build(
                persona: VoiceRoster.persona(id: settings.voicePersonaID),
                gradeLevel: settings.gradeLevel,
                subject: subject,
                sourceText: sourceText,
                studentNote: studentNote,
                studentName: settings.name,
                mood: mood
            ),
            voice: VoiceRoster.persona(id: settings.voicePersonaID).realtimeVoiceName
        )
        config.turnDetection = RealtimeInstructions.turnDetection(for: mood)

        if await live.prewarm(config: config) {
            current = live
            fallbackNotice = nil
            return live
        }

        // Couldn't connect. Say so once, kindly, and carry on.
        fallbackNotice = ConnectionQuality.offline.studentMessage
        current = demo
        return demo
    }

    /// Push a new session config mid-conversation — used when the mood read
    /// changes so delivery and turn detection follow how the student sounds.
    func adapt(to mood: MoodReading, settings: StudentSettings,
               subject: Subject?, sourceText: String, studentNote: String) async {
        guard let live, live.isReady else { return }
        var config = RealtimeSessionConfig(
            instructions: RealtimeInstructions.build(
                persona: VoiceRoster.persona(id: settings.voicePersonaID),
                gradeLevel: settings.gradeLevel, subject: subject,
                sourceText: sourceText, studentNote: studentNote,
                studentName: settings.name, mood: mood),
            voice: VoiceRoster.persona(id: settings.voicePersonaID).realtimeVoiceName
        )
        config.turnDetection = RealtimeInstructions.turnDetection(for: mood)
        await live.update(config: config)
    }

    func endSession() async {
        await live?.disconnect()
        if preference == .preferLive && hasKey {
            // Keep the provider object so the next session can prewarm quickly.
            current = live ?? demo
        }
    }

    func clearFallbackNotice() { fallbackNotice = nil }

    // MARK: - Self-test

    /// Connect, ask for one short reply, and measure it (§Part 3 checklist).
    ///
    /// Deliberately end-to-end: a test that only opens a socket would pass with
    /// a key that has no realtime access, which is the exact failure people hit.
    func runConnectionTest() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        guard let key = KeychainService.load() else {
            lastTestResult = .failed("No key saved yet.")
            return
        }

        let probe = OpenAIRealtimeProvider(apiKey: key, model: model)
        let sink = TestAudioSink()
        probe.audioSink = sink

        let started = Date()
        let config = RealtimeSessionConfig(
            instructions: "Reply with exactly: Ready.",
            voice: VoiceRoster.default.realtimeVoiceName
        )

        guard await probe.prewarm(config: config) else {
            lastTestResult = .failed(
                "Couldn't open a realtime session. Check the key is active and has Realtime access."
            )
            await probe.disconnect()
            return
        }
        let handshake = Date().timeIntervalSince(started)

        // Ask for a reply and time the first audio.
        let askedAt = Date()
        var received: TimeInterval?
        await probe.requestTestResponse()

        // Poll briefly rather than waiting on a notification — this runs once,
        // in Settings, and simplicity beats machinery here.
        for _ in 0..<120 {
            if sink.firstAudioAt != nil {
                received = sink.firstAudioAt?.timeIntervalSince(askedAt)
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let roundTrip = probe.latency.meanRoundTrip
        await probe.disconnect()

        lastTestResult = ConnectionTestResult(
            didConnect: true,
            handshake: handshake,
            timeToFirstAudio: received,
            roundTrip: roundTrip,
            failureReason: received == nil ? "Connected, but no audio came back within 6 seconds." : nil
        )
    }
}

// MARK: - Test helpers

/// Records when the first audio chunk arrived, for the self-test.
private final class TestAudioSink: RealtimeAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _firstAudioAt: Date?

    var firstAudioAt: Date? { lock.withLock { _firstAudioAt } }

    func beginPlayback() async {
        lock.withLock { if _firstAudioAt == nil { _firstAudioAt = Date() } }
    }
    func enqueue(_ pcm: Data) async {
        lock.withLock { if _firstAudioAt == nil { _firstAudioAt = Date() } }
    }
    func finishPlayback() async {}
    func stopImmediately() async {}
}

extension OpenAIRealtimeProvider {
    /// Ask the model to say one short thing. Used only by the self-test.
    func requestTestResponse() async {
        let context = TutorContext(studentMessage: "Say the single word: Ready.")
        let stream = tutorReply(context: context)
        // Kick the stream off and let it run; the sink records the timing, so
        // the content of the reply is irrelevant here.
        Task {
            do { for try await _ in stream {} } catch { }
        }
    }
}
