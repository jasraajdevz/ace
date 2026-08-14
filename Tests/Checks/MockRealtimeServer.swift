//
//  MockRealtimeServer.swift
//  Ace — verification harness
//
//  A scriptable stand-in for the OpenAI Realtime server.
//
//  This is what makes the Part 3 checklist item — "Live Mode integration-tested
//  against a mocked realtime server" — something that actually happens rather
//  than something asserted. It implements `RealtimeTransport`, so
//  `OpenAIRealtimeProvider` cannot tell it from the real thing, and it can be
//  told to do the things a real server does at the worst possible moment:
//  hang up mid-response, rate-limit, take 900ms to answer, reject the key.
//
//  Timing is real (via `Task.sleep`) but scaled down, so latency assertions
//  measure the code path rather than a simulated delay.
//

import Foundation

/// A programmable realtime server.
final class MockRealtimeTransport: RealtimeTransport, @unchecked Sendable {

    // MARK: Scripting

    /// How the mock should behave.
    struct Script: Sendable {
        /// Fail the handshake with this message.
        var connectFailure: String?
        /// Delay before `session.created`.
        var handshakeDelay: TimeInterval = 0.002
        /// Delay between asking for a response and the first audio chunk. This
        /// is what the TTFA assertions measure.
        var timeToFirstAudio: TimeInterval = 0.05
        /// How many audio chunks a response produces.
        var audioChunks: Int = 3
        /// Text the model "says".
        var transcript: [String] = ["Okay. ", "What do you think ", "it's telling you?"]
        /// Close the connection partway through a response.
        var dropDuringResponse = false
        /// Emit a rate-limit event on connect.
        var rateLimited = false
        /// Mirror `turn_detection.create_response`: the server starts a reply on
        /// its own when it decides the student's turn has ended.
        var autoRespondOnTurnEnd = true

        static let healthy = Script()
        static let slow = Script(timeToFirstAudio: 0.9)
        static let rejectsKey = Script(connectFailure: "That key was rejected.")
        static let dropsOut = Script(dropDuringResponse: true)
    }

    var script: Script

    // MARK: Recording — what the client sent

    private let lock = NSLock()
    private var _sent: [RealtimeClientEvent] = []
    private var _connectCount = 0
    private var continuation: AsyncStream<RealtimeServerEvent>.Continuation?
    private var pending: Task<Void, Never>?

    let events: AsyncStream<RealtimeServerEvent>

    init(script: Script = .healthy) {
        self.script = script
        var captured: AsyncStream<RealtimeServerEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    /// Everything the client sent, in order.
    var sent: [RealtimeClientEvent] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var connectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _connectCount
    }

    /// Did the client send this kind of event?
    func didSend(_ predicate: (RealtimeClientEvent) -> Bool) -> Bool {
        sent.contains(where: predicate)
    }

    var lastRoundTrip: TimeInterval? { 0.03 }

    // MARK: Transport

    func connect(apiKey: String, model: String) async throws -> String {
        lock.lock(); _connectCount += 1; lock.unlock()

        if let failure = script.connectFailure {
            throw AIProviderError.transport(failure)
        }
        try? await Task.sleep(for: .seconds(script.handshakeDelay))

        let id = "sess_mock_\(connectCount)"
        continuation?.yield(.sessionCreated(id: id))
        if script.rateLimited {
            continuation?.yield(.rateLimited(resetSeconds: 30))
        }
        return id
    }

    func send(_ event: RealtimeClientEvent) async throws {
        lock.lock(); _sent.append(event); lock.unlock()

        switch event {
        case .updateSession:
            continuation?.yield(.sessionUpdated)
        case .createResponse, .sendText:
            // `sendText` alone doesn't produce a response; only `createResponse`
            // does — matching the real API.
            if case .createResponse = event { beginResponse() }
        case .cancelResponse:
            pending?.cancel()
            continuation?.yield(.responseDone)
        case .appendAudio, .commitAudio, .clearAudio:
            break
        }
    }

    func disconnect() async {
        pending?.cancel()
        continuation?.finish()
        continuation = nil
    }

    // MARK: Simulating a response

    private func beginResponse() {
        pending?.cancel()
        pending = Task { [continuation, script] in
            continuation?.yield(.responseCreated(id: "resp_mock"))

            try? await Task.sleep(for: .seconds(script.timeToFirstAudio))
            guard !Task.isCancelled else { return }

            for index in 0..<script.audioChunks {
                guard !Task.isCancelled else { return }

                if script.dropDuringResponse && index == 1 {
                    continuation?.yield(.error(code: "transport", message: "Connection lost"))
                    continuation?.finish()
                    return
                }

                // 20ms of silence, base64'd — shape matters, contents don't.
                let pcm = Data(repeating: 0, count: 960)
                continuation?.yield(.audioDelta(base64: pcm.base64EncodedString()))

                if index < script.transcript.count {
                    continuation?.yield(.textDelta(script.transcript[index]))
                }
                try? await Task.sleep(for: .milliseconds(5))
            }

            continuation?.yield(.audioDone)
            continuation?.yield(.responseDone)
        }
    }

    // MARK: Driving the server side directly

    /// Pretend the student started talking (server VAD).
    func simulateSpeechStarted() {
        continuation?.yield(.speechStarted)
    }

    func simulateSpeechStopped() {
        continuation?.yield(.speechStopped)
        if script.autoRespondOnTurnEnd { beginResponse() }
    }

    func simulateStudentTranscript(_ text: String) {
        continuation?.yield(.inputTranscript(text))
    }

    func simulateError(code: String?, message: String) {
        continuation?.yield(.error(code: code, message: message))
    }

    /// An event type this client has never heard of — must not break the stream.
    func simulateUnknownEvent() {
        continuation?.yield(.other(type: "some.future.event"))
    }
}

// MARK: - Recording audio sink

/// Stands in for the speakers. Records what it was asked to do and, crucially,
/// *when* — which is how the barge-in budget is measured without any audio
/// hardware.
final class RecordingAudioSink: RealtimeAudioSink, @unchecked Sendable {

    private let lock = NSLock()
    private var _chunks: [Data] = []
    private var _isPlaying = false
    private var _beganAt: Date?
    private var _stoppedAt: Date?
    private var _stopCount = 0
    private var _finishCount = 0
    private var _beginCount = 0
    private var _droppedCount = 0

    /// Simulated cost of actually stopping the audio engine. Set this to prove
    /// the budget still holds with a realistic engine underneath.
    var stopCost: TimeInterval = 0

    init() {}

    func beginPlayback() async {
        lock.lock(); defer { lock.unlock() }
        _isPlaying = true
        _beginCount += 1
        if _beganAt == nil { _beganAt = Date() }
    }

    /// Drops audio that arrives while not playing — exactly as
    /// `RealtimeAudioPlayer` does.
    ///
    /// This used to append unconditionally, which made the mock more forgiving
    /// than the thing it stands in for. A sink that accepts what the real one
    /// discards hides the bug where playback never starts, and that is precisely
    /// the bug it was standing in for.
    func enqueue(_ pcm: Data) async {
        lock.lock(); defer { lock.unlock() }
        guard _isPlaying else {
            _droppedCount += 1
            return
        }
        _chunks.append(pcm)
    }

    func finishPlayback() async {
        lock.lock(); defer { lock.unlock() }
        _isPlaying = false
        _finishCount += 1
    }

    func stopImmediately() async {
        if stopCost > 0 {
            try? await Task.sleep(for: .seconds(stopCost))
        }
        lock.lock(); defer { lock.unlock() }
        _isPlaying = false
        _stoppedAt = Date()
        _stopCount += 1
    }

    // MARK: Inspection

    var chunks: [Data] { lock.lock(); defer { lock.unlock() }; return _chunks }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return _isPlaying }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    var finishCount: Int { lock.lock(); defer { lock.unlock() }; return _finishCount }
    var didPlayAnything: Bool { !chunks.isEmpty }
    var beganAt: Date? { lock.lock(); defer { lock.unlock() }; return _beganAt }
    var chunkCount: Int { chunks.count }
    var beginCount: Int { lock.lock(); defer { lock.unlock() }; return _beginCount }
    /// Audio the player would have thrown away.
    var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return _droppedCount }
}
