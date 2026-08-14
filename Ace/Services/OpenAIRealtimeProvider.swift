//
//  OpenAIRealtimeProvider.swift
//  Ace
//
//  Live Mode: the same `AIProvider` interface, backed by the OpenAI Realtime API.
//
//  Everything in here exists to hit the §7 budget — under 400ms from the student
//  finishing a sentence to Ace's first audible syllable. The techniques, in the
//  order they matter:
//
//    1. **The session is opened before it's needed.** `prewarm()` runs when a
//       study session starts, not when the student first speaks, so the TCP
//       handshake, the TLS handshake and the `session.update` round trip are all
//       already paid for. This alone is worth several hundred milliseconds.
//    2. **Server-side VAD.** The model decides when the student stopped talking,
//       so there's no client-side silence timer adding delay on top.
//    3. **Speak on the first chunk.** Audio is played the instant the first
//       delta arrives, not when the response completes.
//    4. **Barge-in is local first.** When speech is detected we stop playback
//       immediately and send the cancel afterwards — waiting for a server
//       round-trip would blow the 150ms budget on its own.
//    5. **Fall back, never fail.** Any unrecoverable problem degrades to Demo
//       Mode with one warm sentence. Live Mode being down never blocks studying.
//

import Foundation

/// The realtime provider. Talks to a `RealtimeTransport`, which in tests is a
/// mock and in production is a WebSocket.
final class OpenAIRealtimeProvider: AIProvider, @unchecked Sendable {

    let mode: AIProviderMode = .live

    // MARK: Configuration

    private let apiKey: String
    private let model: String
    private let transport: RealtimeTransport
    /// Everything Live Mode doesn't do itself (OCR, quiz generation) is handed
    /// to the on-device provider. There is no reason to pay a network round trip
    /// to read a page Vision can read locally, and it keeps Live Mode's failure
    /// surface small.
    private let fallback: MockAIProvider

    // MARK: State

    private let state = RealtimeState()

    init(apiKey: String,
         model: String = RealtimeModel.default,
         transport: RealtimeTransport? = nil,
         fallback: MockAIProvider = MockAIProvider()) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport ?? WebSocketRealtimeTransport()
        self.fallback = fallback
    }

    var isReady: Bool { state.isConnected }

    /// Where the socket is. Distinct from `isReady`, which collapses every
    /// not-connected state into one — this keeps "handshaking" apart from
    /// "never started" and from "failed".
    var transportState: TransportState { state.current }

    // MARK: - Connection lifecycle

    /// Open the session ahead of time. Called when a study session begins.
    ///
    /// Failure here is not an error the student sees: they simply stay in Demo
    /// Mode, which works.
    @discardableResult
    func prewarm(config: RealtimeSessionConfig) async -> Bool {
        guard !state.isConnected else { return true }
        do {
            let start = Date()
            state.markConnecting()
            let sessionID = try await transport.connect(apiKey: apiKey, model: model)
            state.markConnected(sessionID: sessionID)
            state.recordHandshake(Date().timeIntervalSince(start))

            // Remembered so a reconnect can restore the same session — without
            // this, reconnection has nothing to re-send and silently gives up.
            state.lastConfig = config
            try await transport.send(.updateSession(config))
            startEventLoop()
            return true
        } catch {
            state.markFailed(error.localizedDescription)
            return false
        }
    }

    /// Update the live session — used when the mood read changes, so turn
    /// detection and delivery track how the student sounds (§9).
    func update(config: RealtimeSessionConfig) async {
        guard state.isConnected else { return }
        try? await transport.send(.updateSession(config))
    }

    func disconnect() async {
        state.eventLoop?.cancel()
        state.eventLoop = nil
        await transport.disconnect()
        state.markClosed()
    }

    // MARK: - The event loop

    /// Consumes server events and turns them into the app's world: audio to
    /// play, text to show, latency to record, barge-ins to honour.
    private func startEventLoop() {
        state.eventLoop?.cancel()
        state.eventLoop = Task { [transport, state, weak self] in
            for await event in transport.events {
                guard !Task.isCancelled else { return }

                switch event {
                case .speechStarted:
                    // BARGE-IN. Stop Ace's audio locally, right now, before
                    // telling the server anything — the round trip alone would
                    // exceed the 150ms budget.
                    state.beginBargeIn()
                    await self?.audioSink?.stopImmediately()
                    state.completeBargeIn()
                    try? await transport.send(.cancelResponse)
                    state.markStudentSpeaking(true)

                case .speechStopped:
                    state.markStudentSpeaking(false)
                    // The TTFA clock starts the instant they stop talking —
                    // that's what the student actually experiences as "waiting".
                    state.startTTFAClock()

                case .audioDelta(let base64):
                    if state.stopTTFAClock() {
                        // First chunk of this response: start playing at once.
                        await self?.audioSink?.beginPlayback()
                    }
                    if let data = Data(base64Encoded: base64) {
                        state.countOutputAudio(bytes: data.count)
                        await self?.audioSink?.enqueue(data)
                    }

                case .audioDone:
                    await self?.audioSink?.finishPlayback()

                case .textDelta(let text):
                    state.appendTranscript(text)

                case .inputTranscript(let text):
                    state.setStudentTranscript(text)

                case .responseDone:
                    state.completeResponse()

                case .rateLimited(let reset):
                    state.noteRateLimit(resetSeconds: reset)

                case .error(let code, let message):
                    state.recordError()
                    // An interruption is reported as an error by the API but is
                    // exactly what we asked for; it must not trigger a reconnect.
                    if code != "response_cancelled" {
                        self?.scheduleReconnect(reason: message)
                    }

                case .sessionCreated, .sessionUpdated, .responseCreated, .other:
                    break
                }
            }
            // The stream ended — the socket is gone.
            self?.scheduleReconnect(reason: "Connection closed")
        }
    }

    /// Start reconnecting, at most one attempt-chain at a time.
    ///
    /// Runs in its own task rather than inline in the event loop: reconnecting
    /// replaces the event loop, and a task cannot cleanly cancel itself
    /// mid-iteration. The `isReconnecting` guard is what stops a socket that
    /// reports both an error *and* a stream end from starting two chains.
    private func scheduleReconnect(reason: String) {
        guard !state.isReconnecting else { return }
        state.isReconnecting = true
        state.markDisconnected()

        Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        defer { state.isReconnecting = false }

        guard let config = state.lastConfig else {
            state.markFailed(ReconnectPolicy.exhaustedMessage)
            return
        }

        let policy = ReconnectPolicy()
        var attempt = 1

        while policy.shouldRetry(afterAttempt: attempt - 1) {
            let delay = policy.delay(forAttempt: attempt,
                                     jitterFraction: Double.random(in: 0.3...1.0))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            state.recordReconnect()
            if await prewarm(config: config) { return }
            attempt += 1
        }

        // Out of attempts. Not an error screen — Demo Mode is right there (§10).
        state.markFailed(ReconnectPolicy.exhaustedMessage)
    }

    // MARK: - Audio plumbing

    /// Where decoded audio goes. Injected so the provider can be exercised with
    /// no audio hardware at all.
    var audioSink: RealtimeAudioSink?

    /// Feed a chunk of microphone audio upstream.
    func sendMicrophoneAudio(_ pcm: Data) async {
        guard state.isConnected else { return }
        state.countInputAudio(bytes: pcm.count)
        try? await transport.send(.appendAudio(pcm.base64EncodedString()))
    }

    /// Audio moved this session, for metering. Reading it clears the tally so a
    /// second read can't bill the same seconds twice.
    func drainAudioUsage() -> (input: Double, output: Double) {
        let seconds = state.audioSeconds
        state.resetAudioCounts()
        return seconds
    }

    // MARK: - AIProvider

    func speak(_ text: String, persona: VoicePersona, prosody: Prosody) async throws {
        // In Live Mode, Ace's voice arrives as audio from the model. This path
        // is for the app's own lines — a session summary, a nudge — which are
        // spoken locally rather than paying a round trip for a fixed string.
        try await fallback.speak(text, persona: persona, prosody: prosody)
    }

    func stopSpeaking() async {
        state.beginBargeIn()
        await audioSink?.stopImmediately()
        state.completeBargeIn()
        await fallback.stopSpeaking()
        if state.isConnected {
            try? await transport.send(.cancelResponse)
        }
    }

    func transcribe(audio: Data) async throws -> String {
        // The realtime session transcribes the student's own audio as it goes,
        // so a separate call is only needed when Live Mode isn't up.
        if let latest = state.takeStudentTranscript() { return latest }
        return try await fallback.transcribe(audio: audio)
    }

    func tutorReply(context: TutorContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // The safety net runs before anything reaches the network, in
                // every mode (§10).
                let signal = CrisisSafetyService().evaluate(context.studentMessage)
                guard signal.severity != .crisis else {
                    continuation.finish()
                    return
                }

                guard state.isConnected else {
                    // Not up — hand straight to Demo Mode rather than stalling.
                    for try await chunk in fallback.tutorReply(context: context) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    return
                }

                state.beginResponse()
                do {
                    try await transport.send(.sendText(context.studentMessage))
                    try await transport.send(.createResponse)
                } catch {
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                    return
                }

                // Drain the transcript as the model produces it.
                while !Task.isCancelled {
                    if let chunk = state.takeTranscriptChunk() {
                        continuation.yield(chunk)
                        continue
                    }
                    if state.isResponseComplete { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Vision and study-material generation stay on-device: Apple's OCR is free,
    // instant and private, and the local generator is deterministic.
    func readText(from imageData: Data) async throws -> RecognizedText {
        try await fallback.readText(from: imageData)
    }

    func makeQuiz(from source: StudyMaterialSource, gradeLevel: GradeLevel,
                  title: String, questionCount: Int) async throws -> Quiz {
        try await fallback.makeQuiz(from: source, gradeLevel: gradeLevel,
                                    title: title, questionCount: questionCount)
    }

    func makeFlashcards(from source: StudyMaterialSource, gradeLevel: GradeLevel,
                        title: String, limit: Int) async throws -> [Flashcard] {
        try await fallback.makeFlashcards(from: source, gradeLevel: gradeLevel,
                                          title: title, limit: limit)
    }

    func readEmotion(audio: Data?, text: String?, signals: BehaviourSignals) async -> MoodReading {
        // Behaviour from the shared heuristics, sound from the live analyser,
        // fused with a bias toward the gentler read.
        let behaviour = await fallback.readEmotion(audio: audio, text: text, signals: signals)
        let voice = state.voiceReading.inferredMood
        return MoodFusion.combine(voice: voice, behaviour: behaviour)
    }

    // MARK: - Diagnostics

    var latency: LatencyTracker { state.latency }
    var bargeIn: BargeInTracker { state.bargeIn }
    var connectionQuality: ConnectionQuality {
        ConnectionQuality.assess(tracker: state.latency, isConnected: state.isConnected)
    }

    /// Feed an analysed microphone frame in for voice matching (§9).
    func ingestVoiceFrame(_ frame: VoiceFrame) {
        state.ingestVoiceFrame(frame)
    }

    var voiceReading: VoiceReading { state.voiceReading }
}

// MARK: - Where audio goes

/// Plays the audio Ace sends back.
///
/// A protocol rather than a concrete engine so the provider's timing behaviour —
/// including the barge-in budget — can be tested with a recording sink and no
/// speakers involved.
protocol RealtimeAudioSink: AnyObject, Sendable {
    /// Called on the first chunk of a response.
    func beginPlayback() async
    /// Queue decoded PCM16 for playback.
    func enqueue(_ pcm: Data) async
    /// The model finished speaking.
    func finishPlayback() async
    /// Stop NOW. This is the barge-in path — it must not wait for anything.
    func stopImmediately() async
}

// MARK: - Provider state

/// Mutable state, behind a lock.
///
/// Split out of the provider so the provider itself reads as a sequence of
/// behaviours rather than a pile of `lock.lock()`.
final class RealtimeState: @unchecked Sendable {

    private let lock = NSLock()

    private var _state: TransportState = .idle
    private var _latency = LatencyTracker()
    private var _bargeIn = BargeInTracker()
    private var _analyzer = VoiceEnergyAnalyzer()
    private var _transcriptBuffer: [String] = []
    private var _studentTranscript: String?
    private var _responseComplete = true
    private var _ttfaStart: Date?
    private var _ttfaRunning = false
    private var _rateLimitResetSeconds: Double?
    private var _inputAudioBytes = 0
    private var _outputAudioBytes = 0

    var eventLoop: Task<Void, Never>?
    var lastConfig: RealtimeSessionConfig?
    var isReconnecting = false
    private(set) var isStudentSpeaking = false

    // MARK: Connection

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _state.isConnected
    }

    var current: TransportState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Entering the handshake.
    ///
    /// `TransportState.connecting` existed and was never assigned, so the state
    /// machine jumped straight from idle to connected and nothing could tell
    /// "not started" apart from "waiting on the socket" — which is the window
    /// the student actually spends time in.
    func markConnecting() {
        lock.lock(); defer { lock.unlock() }
        _state = .connecting
    }

    func markConnected(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        _state = .connected(sessionID: sessionID)
    }

    func markDisconnected() {
        lock.lock(); defer { lock.unlock() }
        _state = .closed
    }

    func markClosed() {
        lock.lock(); defer { lock.unlock() }
        _state = .closed
        _latency.reset()
    }

    func markFailed(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        _state = .failed(reason)
    }

    var failureReason: String? {
        lock.lock(); defer { lock.unlock() }
        if case .failed(let reason) = _state { return reason }
        return nil
    }

    // MARK: Latency

    var latency: LatencyTracker {
        lock.lock(); defer { lock.unlock() }
        return _latency
    }

    var bargeIn: BargeInTracker {
        lock.lock(); defer { lock.unlock() }
        return _bargeIn
    }

    // MARK: Metering

    /// Bytes of PCM16 moved each way this session.
    ///
    /// The provider counts them because it is the only thing in the app that
    /// costs money, so it is the only honest place to measure. Estimating from
    /// the text instead would drift the moment a response was interrupted —
    /// and barge-in makes that the common case, not the rare one.
    func countInputAudio(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        _inputAudioBytes += bytes
    }

    func countOutputAudio(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        _outputAudioBytes += bytes
    }

    /// Seconds of audio each way, from the byte counts.
    var audioSeconds: (input: Double, output: Double) {
        lock.lock(); defer { lock.unlock() }
        let perSecond = RealtimeAudio.sampleRate * 2   // PCM16 mono
        return (Double(_inputAudioBytes) / perSecond,
                Double(_outputAudioBytes) / perSecond)
    }

    func resetAudioCounts() {
        lock.lock(); defer { lock.unlock() }
        _inputAudioBytes = 0
        _outputAudioBytes = 0
    }

    func recordHandshake(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _latency.recordRoundTrip(seconds)
    }

    func recordReconnect() {
        lock.lock(); defer { lock.unlock() }
        _latency.recordReconnect()
    }

    func recordError() {
        lock.lock(); defer { lock.unlock() }
        _latency.recordError()
    }

    /// Start counting from the moment the student stopped talking.
    func startTTFAClock() {
        lock.lock(); defer { lock.unlock() }
        _ttfaStart = Date()
        _ttfaRunning = true
    }

    /// Stop the clock. Returns true if this was the first audio of the response,
    /// which is the caller's cue to start playback.
    @discardableResult
    func stopTTFAClock() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _ttfaRunning, let start = _ttfaStart else { return false }
        _latency.recordTTFA(Date().timeIntervalSince(start))
        _ttfaRunning = false
        _ttfaStart = nil
        return true
    }

    // MARK: Barge-in

    func beginBargeIn() {
        lock.lock(); defer { lock.unlock() }
        _bargeIn.speechDetected()
    }

    func completeBargeIn() {
        lock.lock(); defer { lock.unlock() }
        _bargeIn.audioStopped()
    }

    func markStudentSpeaking(_ speaking: Bool) {
        lock.lock(); defer { lock.unlock() }
        isStudentSpeaking = speaking
        if !speaking { _analyzer.completeTurn() }
    }

    // MARK: Transcript

    func appendTranscript(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        _transcriptBuffer.append(chunk)
    }

    func takeTranscriptChunk() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !_transcriptBuffer.isEmpty else { return nil }
        return _transcriptBuffer.removeFirst()
    }

    func setStudentTranscript(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _studentTranscript = text
    }

    func takeStudentTranscript() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { _studentTranscript = nil }
        return _studentTranscript
    }

    // MARK: Response lifecycle

    func beginResponse() {
        lock.lock(); defer { lock.unlock() }
        _responseComplete = false
        _transcriptBuffer.removeAll()
    }

    func completeResponse() {
        lock.lock(); defer { lock.unlock() }
        _responseComplete = true
    }

    var isResponseComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _responseComplete
    }

    func noteRateLimit(resetSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        _rateLimitResetSeconds = resetSeconds
    }

    // MARK: Voice

    func ingestVoiceFrame(_ frame: VoiceFrame) {
        lock.lock(); defer { lock.unlock() }
        _analyzer.ingest(frame)
    }

    var voiceReading: VoiceReading {
        lock.lock(); defer { lock.unlock() }
        return _analyzer.read()
    }
}
