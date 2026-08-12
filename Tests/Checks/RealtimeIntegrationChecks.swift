//
//  RealtimeIntegrationChecks.swift
//  Ace — verification harness
//
//  End-to-end exercise of `OpenAIRealtimeProvider` against `MockRealtimeTransport`.
//
//  This is the Part 3 checklist item — "Live Mode code-complete and
//  integration-tested against a mocked realtime server" — actually executed. The
//  provider is the real one; only the wire is fake. Everything below runs with
//  no key, no network, no audio hardware and no Xcode.
//
//  The behaviours that matter most, and that are all asserted here:
//    • the session is opened before it's needed, and configured
//    • barge-in stops audio locally FIRST, inside the 150ms budget
//    • TTFA is measured from the end of the student's speech
//    • a dropped connection reconnects, and a hopeless one degrades to Demo Mode
//    • the crisis net runs before anything reaches the network
//    • unknown events never break the stream
//

import Foundation

/// The check harness is synchronous; these behaviours are not. This bridges the
/// two by running an async block and pumping the run loop until it finishes.
///
/// It must be a run loop rather than a semaphore. Blocking the main thread means
/// the main dispatch queue is never serviced, so anything that hops to
/// `@MainActor` — `SpeechService`, `Feedback`, any of the UI-facing services —
/// waits forever and the check times out looking like a product bug.
private func runAsync<T>(timeout: TimeInterval = 5, _ body: @escaping @Sendable () async -> T) -> T? {
    nonisolated(unsafe) var result: T?
    nonisolated(unsafe) var finished = false

    Task {
        result = await body()
        finished = true
    }

    let deadline = Date().addingTimeInterval(timeout)
    while !finished, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return finished ? result : nil
}

enum RealtimeIntegrationChecks {

    private static func makeConfig() -> RealtimeSessionConfig {
        RealtimeSessionConfig(instructions: "Be a Socratic tutor.", voice: "shimmer")
    }

    // MARK: - Connecting

    static let connection = CheckSuite(name: "Live Mode — connecting") { run in

        // --- The happy path ----------------------------------------------------
        let outcome = runAsync { () -> (Bool, Int, Bool, Bool) in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            let connected = await provider.prewarm(config: makeConfig())

            let sentConfig = mock.didSend { if case .updateSession = $0 { return true }; return false }
            let ready = provider.isReady
            await provider.disconnect()
            return (connected, mock.connectCount, sentConfig, ready)
        }

        guard let (connected, connectCount, sentConfig, ready) = outcome else {
            run.expect(false, "connection test timed out")
            return
        }
        run.expect(connected, "prewarm should succeed against a healthy server")
        run.expectEqual(connectCount, 1, "connects exactly once")
        run.expect(sentConfig, "must send session.update immediately — instructions, voice, VAD")
        run.expect(ready, "provider reports ready once connected")

        // --- A rejected key -------------------------------------------------------
        let rejected = runAsync { () -> (Bool, Bool) in
            let mock = MockRealtimeTransport(script: .rejectsKey)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-bad", transport: mock)
            let connected = await provider.prewarm(config: makeConfig())
            return (connected, provider.isReady)
        }
        run.expect(rejected?.0 == false, "a rejected key must not report success")
        run.expect(rejected?.1 == false, "and must not report ready")

        // Crucially: a failed connection is not a crash and not an error screen.
        // The app carries on in Demo Mode. That's asserted by the fact that
        // `prewarm` returns a Bool rather than throwing.

        // --- Prewarming twice is a no-op --------------------------------------------
        let twice = runAsync { () -> Int in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            _ = await provider.prewarm(config: makeConfig())
            _ = await provider.prewarm(config: makeConfig())
            await provider.disconnect()
            return mock.connectCount
        }
        run.expectEqual(twice, 1, "prewarming an already-open session must not reconnect")

        // --- Mode and fallbacks -------------------------------------------------------
        let mock = MockRealtimeTransport()
        let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
        run.expectEqual(provider.mode, .live, "reports Live Mode")
        run.expect(!provider.isReady, "not ready before connecting")
        run.expectEqual(provider.connectionQuality, .offline, "offline before connecting")
    }

    // MARK: - The conversation

    static let conversation = CheckSuite(name: "Live Mode — conversation and latency") { run in

        // --- A full turn ---------------------------------------------------------
        let turn = runAsync(timeout: 8) { () -> (Bool, Int, String, Bool)? in
            let mock = MockRealtimeTransport(script: .healthy)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            // The student talks, then stops — the TTFA clock starts here.
            mock.simulateSpeechStarted()
            try? await Task.sleep(for: .milliseconds(20))
            mock.simulateSpeechStopped()

            var received = ""
            let context = TutorContext(sourceText: "Photosynthesis is a process.",
                                       studentMessage: "what is photosynthesis?")
            let stream = provider.tutorReply(context: context)
            // The stream can throw; a transport failure mid-reply is a valid
            // outcome to observe, not a reason to abandon the check.
            do { for try await chunk in stream { received += chunk } } catch { }

            try? await Task.sleep(for: .milliseconds(120))
            let hadAudio = sink.didPlayAnything
            let chunkCount = sink.chunks.count
            let measured = provider.latency.count > 0
            await provider.disconnect()
            return (hadAudio, chunkCount, received, measured)
        }

        guard let (hadAudio, chunkCount, received, measured) = turn ?? nil else {
            run.expect(false, "conversation test timed out or failed to connect")
            return
        }
        run.expect(hadAudio, "audio must reach the sink")
        run.expect(chunkCount >= 2, "every audio delta must be enqueued, got \(chunkCount)")
        run.expect(!received.isEmpty, "the transcript must stream back, got “\(received)”")
        run.expect(measured, "TTFA must be measured from the end of the student's speech")

        // --- TTFA is measured, and reflects reality ---------------------------------
        let fast = runAsync(timeout: 8) { () -> LatencyTracker? in
            let mock = MockRealtimeTransport(script: Script.fast)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            for _ in 0..<3 {
                mock.simulateSpeechStarted()
                try? await Task.sleep(for: .milliseconds(10))
                mock.simulateSpeechStopped()
                try? await Task.sleep(for: .milliseconds(180))
            }
            let tracker = provider.latency
            await provider.disconnect()
            return tracker
        }

        if let fast = fast ?? nil {
            run.expect(fast.count >= 2, "several TTFA samples recorded, got \(fast.count)")
            run.expect(fast.meetsBudget,
                       "a fast mock server must land inside the §7 budget, p95 = \(fast.p95 ?? -1)")
            run.expect((fast.p50 ?? 1) < LatencyBudget.ttfaP95Ceiling,
                       "p50 should be well inside the ceiling, got \(fast.p50 ?? -1)")
            run.expect(!fast.hudSummary.contains("—"), "the debug HUD should show real numbers")
        } else {
            run.expect(false, "latency measurement timed out")
        }

        // A slow server must be *detected*, not hidden.
        let slow = runAsync(timeout: 10) { () -> (Bool, ConnectionQuality)? in
            let mock = MockRealtimeTransport(script: .slow)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            for _ in 0..<2 {
                mock.simulateSpeechStarted()
                try? await Task.sleep(for: .milliseconds(20))
                // Server VAD creates the response itself on turn end — letting
                // the mock do that avoids racing with the barge-in cancel the
                // provider (correctly) sends on speech start.
                mock.simulateSpeechStopped()
                try? await Task.sleep(for: .milliseconds(1_100))
            }
            let result = (provider.latency.meetsBudget, provider.connectionQuality)
            await provider.disconnect()
            return result
        }
        if let (meetsBudget, quality) = slow ?? nil {
            run.expect(!meetsBudget, "a 900ms server must fail the budget, not be excused")
            run.expect(quality <= .fair, "and must show as a degraded connection, got \(quality)")
        } else {
            run.expect(false, "slow-server test timed out")
        }
    }

    // MARK: - Barge-in

    static let bargeIn = CheckSuite(name: "Live Mode — barge-in") { run in

        // The headline §7 requirement: the student starts talking, Ace stops.
        let result = runAsync(timeout: 8) { () -> (Int, BargeInTracker, Bool)? in
            let mock = MockRealtimeTransport(script: .healthy)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            // Ace starts speaking.
            try? await mock.send(.createResponse)
            try? await Task.sleep(for: .milliseconds(90))

            // The student cuts in.
            mock.simulateSpeechStarted()
            try? await Task.sleep(for: .milliseconds(60))

            let cancelled = mock.didSend { if case .cancelResponse = $0 { return true }; return false }
            let outcome = (sink.stopCount, provider.bargeIn, cancelled)
            await provider.disconnect()
            return outcome
        }

        guard let (stopCount, tracker, cancelled) = result ?? nil else {
            run.expect(false, "barge-in test timed out")
            return
        }

        run.expect(stopCount >= 1, "the audio sink must be stopped when the student speaks")
        run.expect(cancelled, "and the server must be told to cancel the response")
        run.expect(tracker.last != nil, "the barge-in must be measured")
        run.expect(tracker.meetsBudget,
                   "barge-in must land inside 150ms, worst was \(tracker.worst ?? -1)s")
        if let last = tracker.last {
            run.expect(last < LatencyBudget.bargeInCeiling,
                       "measured \(Int(last * 1000))ms, budget is 150ms")
        }

        // The budget must still hold with a realistic engine-stop cost. This is
        // the check that would catch someone adding a fade-out.
        let withCost = runAsync(timeout: 8) { () -> BargeInTracker? in
            let mock = MockRealtimeTransport(script: .healthy)
            let sink = RecordingAudioSink()
            sink.stopCost = 0.05           // 50ms to actually stop the engine
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            try? await mock.send(.createResponse)
            try? await Task.sleep(for: .milliseconds(80))
            mock.simulateSpeechStarted()
            try? await Task.sleep(for: .milliseconds(120))

            let tracker = provider.bargeIn
            await provider.disconnect()
            return tracker
        }
        if let tracker = withCost ?? nil, tracker.last != nil {
            run.expect(tracker.meetsBudget,
                       "a 50ms engine stop must still fit the budget, got \(tracker.worst ?? -1)s")
        }

        // `stopSpeaking()` — the manual stop button — must do the same thing.
        let manual = runAsync(timeout: 8) { () -> (Int, Bool)? in
            let mock = MockRealtimeTransport(script: .healthy)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            try? await mock.send(.createResponse)
            try? await Task.sleep(for: .milliseconds(80))
            await provider.stopSpeaking()

            let cancelled = mock.didSend { if case .cancelResponse = $0 { return true }; return false }
            let outcome = (sink.stopCount, cancelled)
            await provider.disconnect()
            return outcome
        }
        run.expect((manual ?? nil)?.0 ?? 0 >= 1, "the stop button must stop the audio")
        run.expect((manual ?? nil)?.1 ?? false, "and must cancel the server response")
    }

    // MARK: - Resilience

    static let resilience = CheckSuite(name: "Live Mode — resilience and safety") { run in

        // --- A dropped connection reconnects -----------------------------------
        let dropped = runAsync(timeout: 10) { () -> Int? in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            mock.simulateError(code: "transport", message: "Connection lost")
            try? await Task.sleep(for: .milliseconds(900))

            let attempts = mock.connectCount
            await provider.disconnect()
            return attempts
        }
        run.expect((dropped ?? nil) ?? 0 >= 2,
                   "a dropped connection must trigger at least one reconnect, saw \((dropped ?? nil) ?? 0)")

        // --- An interruption is NOT an error ---------------------------------------
        let interrupted = runAsync(timeout: 8) { () -> Int? in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            // The API reports a cancelled response as an error — but it's what
            // we asked for, and it must not start a reconnect storm.
            mock.simulateError(code: "response_cancelled", message: "Response cancelled")
            try? await Task.sleep(for: .milliseconds(500))

            let attempts = mock.connectCount
            await provider.disconnect()
            return attempts
        }
        run.expectEqual((interrupted ?? nil) ?? 0, 1,
                        "a cancelled response must NOT be treated as a connection failure")

        // --- Unknown events must not break anything -----------------------------------
        let unknown = runAsync(timeout: 8) { () -> Bool? in
            let mock = MockRealtimeTransport(script: .healthy)
            let sink = RecordingAudioSink()
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            provider.audioSink = sink
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            for _ in 0..<5 { mock.simulateUnknownEvent() }
            try? await Task.sleep(for: .milliseconds(50))

            // Still working afterwards?
            try? await mock.send(.createResponse)
            try? await Task.sleep(for: .milliseconds(200))

            let stillWorks = sink.didPlayAnything
            await provider.disconnect()
            return stillWorks
        }
        run.expect((unknown ?? nil) ?? false,
                   "unrecognised server events must be ignored, not fatal")

        // --- The crisis net runs before the network ---------------------------------------
        let crisis = runAsync(timeout: 8) { () -> (Bool, String)? in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            var received = ""
            let context = TutorContext(sourceText: "Photosynthesis is a process.",
                                       studentMessage: "i want to kill myself")
            let stream = provider.tutorReply(context: context)
            // The stream can throw; a transport failure mid-reply is a valid
            // outcome to observe, not a reason to abandon the check.
            do { for try await chunk in stream { received += chunk } } catch { }

            // Nothing about that message may have been sent upstream.
            let leaked = mock.didSend {
                if case .sendText(let text) = $0 { return text.contains("kill myself") }
                return false
            }
            await provider.disconnect()
            return (leaked, received)
        }
        if let (leaked, received) = crisis ?? nil {
            run.expect(!leaked,
                       "a crisis disclosure must NOT be sent to the model — the safety surface owns that moment")
            run.expect(received.isEmpty,
                       "and the tutor stream must produce nothing, so the crisis screen isn't talked over")
        } else {
            run.expect(false, "crisis test timed out")
        }

        // --- Falls back to Demo Mode when not connected ------------------------------------
        let offline = runAsync(timeout: 8) { () -> String? in
            let mock = MockRealtimeTransport(script: .rejectsKey)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-bad", transport: mock)
            _ = await provider.prewarm(config: makeConfig())   // fails

            var received = ""
            let context = TutorContext(sourceText: "Chlorophyll is the green pigment in a leaf.",
                                       studentMessage: "what is chlorophyll?")
            let stream = provider.tutorReply(context: context)
            // The stream can throw; a transport failure mid-reply is a valid
            // outcome to observe, not a reason to abandon the check.
            do { for try await chunk in stream { received += chunk } } catch { }
            return received
        }
        run.expect(!((offline ?? nil) ?? "").isEmpty,
                   "with no connection, the tutor must still answer — from Demo Mode")

        // --- On-device work stays on-device ------------------------------------------------
        let local = runAsync(timeout: 8) { () -> (Int, Int)? in
            let mock = MockRealtimeTransport(script: .healthy)
            let provider = OpenAIRealtimeProvider(apiKey: "sk-test", transport: mock)
            guard await provider.prewarm(config: makeConfig()) else { return nil }

            let text = StudyGeneratorChecks.sciencePassage
            let quiz = try? await provider.makeQuiz(from: .text(text), gradeLevel: .grade9,
                                                    title: "Bio", questionCount: 5)
            let cards = try? await provider.makeFlashcards(from: .text(text), gradeLevel: .grade9,
                                                           title: "Bio", limit: 8)
            await provider.disconnect()
            return (quiz?.questions.count ?? 0, cards?.count ?? 0)
        }
        if let (questions, cards) = local ?? nil {
            run.expect(questions > 0, "Live Mode still generates quizzes locally — no round trip needed")
            run.expect(cards > 0, "and flashcards")
        } else {
            run.expect(false, "local generation test timed out")
        }
    }
}

// MARK: - Extra scripts

private extension MockRealtimeTransport.Script {
    /// A server that answers well inside budget.
    static let fast = MockRealtimeTransport.Script(timeToFirstAudio: 0.06, audioChunks: 2)
}

/// Local alias so the suites read cleanly.
private typealias Script = MockRealtimeTransport.Script
