//
//  VoiceChecks3.swift
//  Ace — verification harness
//
//  Part 3: the realtime protocol, the latency budget, barge-in, voice matching,
//  key handling, and a full integration pass against the mock server.
//

import Foundation

// MARK: - Wire format

enum RealtimeProtocolChecks {
    static let all = CheckSuite(name: "Realtime protocol") { run in

        // --- Client events encode to the right shape ---------------------------
        let config = RealtimeSessionConfig(instructions: "Be a tutor.", voice: "shimmer")
        let updateJSON = RealtimeClientEvent.updateSession(config).jsonObject
        run.expectEqual(updateJSON["type"] as? String, "session.update", "session.update type")
        guard let session = updateJSON["session"] as? [String: Any] else {
            run.expect(false, "session.update carries no session object")
            return
        }
        run.expectEqual(session["voice"] as? String, "shimmer", "voice is sent")
        run.expectEqual(session["instructions"] as? String, "Be a tutor.", "instructions are sent")
        run.expectEqual(session["input_audio_format"] as? String, "pcm16", "input format")
        run.expectEqual(session["output_audio_format"] as? String, "pcm16", "output format")
        run.expect(session["turn_detection"] != nil, "turn detection is configured")
        run.expect(session["input_audio_transcription"] != nil,
                   "the student's own audio must be transcribed — the safety net reads it")

        // Turn detection must ask the server to handle interruption, or barge-in
        // is left entirely to the client.
        if let detection = session["turn_detection"] as? [String: Any] {
            run.expectEqual(detection["type"] as? String, "server_vad", "server VAD")
            run.expectEqual(detection["interrupt_response"] as? Bool, true,
                            "the server must cut the model when the student speaks")
            run.expectEqual(detection["create_response"] as? Bool, true, "auto-reply on turn end")
        }

        run.expectEqual(RealtimeClientEvent.commitAudio.jsonObject["type"] as? String,
                        "input_audio_buffer.commit", "commit")
        run.expectEqual(RealtimeClientEvent.cancelResponse.jsonObject["type"] as? String,
                        "response.cancel", "cancel")
        run.expectEqual(RealtimeClientEvent.appendAudio("AAAA").jsonObject["audio"] as? String,
                        "AAAA", "audio payload")

        let textEvent = RealtimeClientEvent.sendText("what is glucose?").jsonObject
        run.expectEqual(textEvent["type"] as? String, "conversation.item.create", "text item")

        // Everything must survive JSON serialisation.
        for event: RealtimeClientEvent in [.updateSession(config), .appendAudio("AA"),
                                           .commitAudio, .clearAudio, .createResponse,
                                           .cancelResponse, .sendText("hi")] {
            run.expect((try? event.encoded()) != nil, "\(event.jsonObject["type"] ?? "?") must encode")
        }

        // --- Server events decode --------------------------------------------------
        func decode(_ json: String) -> RealtimeServerEvent {
            RealtimeServerEvent.decode(Data(json.utf8))
        }

        run.expectEqual(decode(#"{"type":"session.created","session":{"id":"s1"}}"#),
                        .sessionCreated(id: "s1"), "session.created")
        run.expectEqual(decode(#"{"type":"input_audio_buffer.speech_started"}"#),
                        .speechStarted, "speech started")
        run.expectEqual(decode(#"{"type":"input_audio_buffer.speech_stopped"}"#),
                        .speechStopped, "speech stopped")
        run.expectEqual(decode(#"{"type":"response.done"}"#), .responseDone, "response done")

        // BOTH audio event spellings must work — the API renamed these between
        // preview and GA, and missing the new one is a silent total failure.
        run.expectEqual(decode(#"{"type":"response.output_audio.delta","delta":"QUJD"}"#),
                        .audioDelta(base64: "QUJD"), "GA audio delta name")
        run.expectEqual(decode(#"{"type":"response.audio.delta","delta":"QUJD"}"#),
                        .audioDelta(base64: "QUJD"), "preview audio delta name")
        run.expectEqual(decode(#"{"type":"response.output_audio_transcript.delta","delta":"hi"}"#),
                        .textDelta("hi"), "GA transcript name")
        run.expectEqual(decode(#"{"type":"response.audio_transcript.delta","delta":"hi"}"#),
                        .textDelta("hi"), "preview transcript name")

        run.expectEqual(decode(#"{"type":"error","error":{"code":"bad","message":"nope"}}"#),
                        .error(code: "bad", message: "nope"), "error")
        run.expectEqual(decode(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#),
                        .inputTranscript("hello"), "student transcript")

        // Unknown and malformed input must degrade, never throw.
        if case .other = decode(#"{"type":"some.future.event"}"#) {
            run.expect(true, "unknown event")
        } else {
            run.expect(false, "an unknown event must decode to .other, not break the stream")
        }
        if case .other = decode("not json at all") {
            run.expect(true, "malformed frame")
        } else {
            run.expect(false, "malformed input must not crash the decoder")
        }
        if case .other = decode(#"{"no_type":true}"#) {
            run.expect(true, "typeless frame")
        } else {
            run.expect(false, "a frame with no type must decode to .other")
        }

        run.expect(RealtimeServerEvent.audioDelta(base64: "QQ==").isFirstAudio,
                   "a non-empty audio delta counts as first audio")
        run.expect(!RealtimeServerEvent.audioDelta(base64: "").isFirstAudio,
                   "an empty delta does not count")
        run.expect(!RealtimeServerEvent.responseDone.isFirstAudio, "response.done is not audio")

        // --- Audio maths ------------------------------------------------------------
        run.expectEqual(RealtimeAudio.frames(forSeconds: 1), 24_000, "24kHz")
        run.expectEqual(RealtimeAudio.duration(ofBytes: 48_000), 1.0, "1 second of PCM16")

        // --- Turn detection tuning ------------------------------------------------------
        run.expect(TurnDetection.patient.silenceDurationMs > TurnDetection.responsive.silenceDurationMs,
                   "a struggling student must get longer to think before Ace jumps in")
        for mood: Mood in [.confused, .frustrated, .low] {
            let detection = RealtimeInstructions.turnDetection(
                for: MoodReading(mood: mood, confidence: 0.8))
            run.expectEqual(detection.silenceDurationMs, TurnDetection.patient.silenceDurationMs,
                            "\(mood) should get the patient turn detector")
        }
        run.expectEqual(
            RealtimeInstructions.turnDetection(for: MoodReading(mood: .energized, confidence: 0.8)).silenceDurationMs,
            TurnDetection.responsive.silenceDurationMs,
            "an energised student gets the responsive detector")
        run.expectEqual(
            RealtimeInstructions.turnDetection(for: .unknown).silenceDurationMs,
            TurnDetection.responsive.silenceDurationMs,
            "no reading means the default detector")
    }
}

// MARK: - Instructions

enum RealtimeInstructionChecks {
    static let all = CheckSuite(name: "Live Mode instructions") { run in
        let source = "Photosynthesis is the process plants use to make food. "
            + "Chlorophyll is the green pigment that captures light."

        let instructions = RealtimeInstructions.build(
            persona: VoiceRoster.default,
            gradeLevel: .grade9,
            subject: .science,
            sourceText: source,
            studentNote: "test Friday",
            studentName: "Sam",
            mood: MoodReading(mood: .frustrated, confidence: 0.8)
        )
        let lower = instructions.lowercased()

        // The pedagogy must survive the switch from Demo to Live. These are the
        // same rules SocraticEngine enforces in code.
        run.expect(lower.contains("never lead with the answer"), "Socratic rule is stated")
        run.expect(lower.contains("just tell me"), "the explicit-request escape hatch is stated")
        run.expect(lower.contains("ask them why") || lower.contains("ask them WHY".lowercased()),
                   "must probe reasoning on correct answers")
        run.expect(lower.contains("never invent"), "grounding rule is stated")
        run.expect(instructions.contains(source), "the student's material is included")
        run.expect(instructions.contains("Sam"), "the student's name is used")
        run.expect(instructions.contains("test Friday"), "the student's own note is used")
        run.expect(lower.contains("science"), "the subject is mentioned")

        // Safety must be present and must override.
        run.expect(lower.contains("self-harm") || lower.contains("suicide"),
                   "the crisis instruction must be present")
        run.expect(lower.contains("overrides everything"), "safety must be marked as overriding")
        run.expect(lower.contains("do not role-play as a therapist"), "no therapist role-play")
        run.expect(lower.contains("do not promise confidentiality"), "no confidentiality promises")
        run.expect(lower.contains("streak"), "must explicitly forbid mentioning streaks in a crisis")

        // Mood shapes delivery.
        run.expect(lower.contains("frustrated"), "the mood read reaches the model")
        run.expect(lower.contains("mocking"),
                   "must warn against sounding cheerful at a frustrated student")

        // Speech, not prose.
        run.expect(lower.contains("markdown") || lower.contains("bullet"),
                   "must forbid markdown — this is spoken")
        run.expect(lower.contains("short"), "must ask for short replies")

        // Register changes with grade level.
        let young = RealtimeInstructions.build(
            persona: VoiceRoster.default, gradeLevel: .grade5, subject: nil,
            sourceText: source, studentNote: "", studentName: "", mood: .unknown)
        let college = RealtimeInstructions.build(
            persona: VoiceRoster.default, gradeLevel: .college, subject: nil,
            sourceText: source, studentNote: "", studentName: "", mood: .unknown)
        run.expect(young != college, "a 5th grader and an undergraduate get different instructions")
        run.expect(young.lowercased().contains("everyday words"), "elementary register")
        run.expect(college.lowercased().contains("peer"), "college register")

        // No name supplied must not produce a dangling greeting.
        run.expect(!young.contains("  "), "missing name must not leave a double space")
        run.expect(young.contains("the student"), "falls back to “the student”")

        // Every mood must produce distinct, non-empty delivery direction.
        var directions = Set<String>()
        for mood in Mood.allCases {
            let text = RealtimeInstructions.build(
                persona: VoiceRoster.default, gradeLevel: .grade9, subject: nil,
                sourceText: source, studentNote: "", studentName: "",
                mood: MoodReading(mood: mood, confidence: 0.9))
            run.expect(!text.isEmpty, "\(mood) produced no instructions")
            directions.insert(text)
        }
        run.expect(directions.count >= 5,
                   "moods should produce meaningfully different direction, got \(directions.count) variants")

        // A very long source must be truncated so it can't crowd out the rules.
        let huge = String(repeating: "word ", count: 20_000)
        let bounded = RealtimeInstructions.build(
            persona: VoiceRoster.default, gradeLevel: .grade9, subject: nil,
            sourceText: huge, studentNote: "", studentName: "", mood: .unknown)
        run.expect(bounded.count < 12_000, "a huge source must be truncated, got \(bounded.count)")
        run.expect(bounded.lowercased().contains("never lead with the answer"),
                   "truncation must never drop the teaching rules")
    }
}

// MARK: - Latency

enum LatencyChecks {
    static let all = CheckSuite(name: "Latency, barge-in and reconnection") { run in

        // --- Tracker ----------------------------------------------------------
        var tracker = LatencyTracker()
        run.expect(tracker.p50 == nil, "no samples means no percentile")
        run.expect(tracker.meetsBudget, "no data should not read as a failure")
        run.expectEqual(tracker.hudSummary, "TTFA —", "empty HUD line")

        for sample in [0.20, 0.25, 0.30, 0.35, 0.40] { tracker.recordTTFA(sample) }
        run.expectEqual(tracker.count, 5, "five samples")
        run.expectEqual(tracker.last, 0.40, "last sample")
        run.expectEqual(tracker.p50, 0.30, "p50 of 5 sorted samples")
        run.expectEqual(tracker.percentile(1.0), 0.40, "p100 is the max")
        run.expectEqual(tracker.percentile(0), 0.20, "p0 is the min")
        run.expect(tracker.meetsBudget, "0.4s p95 is inside the 0.7s ceiling")
        run.expectEqual(tracker.verdict, .good, "300ms p50 is good")

        // Junk must be ignored, not averaged in.
        var guarded = LatencyTracker()
        guarded.recordTTFA(-1)
        guarded.recordTTFA(999)
        run.expectEqual(guarded.count, 0, "impossible samples are dropped")

        // The window is bounded, so a bad patch can't be hidden by ancient data.
        var windowed = LatencyTracker()
        for index in 0..<200 { windowed.recordTTFA(Double(index) / 1000) }
        run.expectEqual(windowed.count, LatencyTracker.windowSize, "window is capped")

        // A slow connection must fail the budget.
        var slow = LatencyTracker()
        for _ in 0..<10 { slow.recordTTFA(1.2) }
        run.expect(!slow.meetsBudget, "1.2s TTFA must fail the budget")
        run.expectEqual(slow.verdict, .poor, "1.2s is poor")

        // Budget verdicts sit at the documented boundaries.
        run.expectEqual(LatencyBudget.verdict(forTTFA: 0.2), .good, "200ms is good")
        run.expectEqual(LatencyBudget.verdict(forTTFA: 0.5), .acceptable, "500ms is acceptable")
        run.expectEqual(LatencyBudget.verdict(forTTFA: 0.9), .poor, "900ms is poor")
        run.expectEqual(LatencyBudget.ttfaTarget, 0.400, "the §7 target is 400ms")
        run.expectEqual(LatencyBudget.ttfaP95Ceiling, 0.700, "the §7 p95 ceiling is 700ms")
        run.expectEqual(LatencyBudget.bargeInCeiling, 0.150, "the §7 barge-in ceiling is 150ms")

        // Jitter.
        var jittery = LatencyTracker()
        for sample in [0.1, 0.5, 0.1, 0.5] { jittery.recordRoundTrip(sample) }
        run.expect((jittery.jitter ?? 0) > 0.1, "alternating RTT should show jitter")
        var steady = LatencyTracker()
        for _ in 0..<4 { steady.recordRoundTrip(0.2) }
        run.expectEqual(steady.jitter, 0, "a steady connection has no jitter")

        // --- Connection quality --------------------------------------------------
        run.expectEqual(ConnectionQuality.assess(tracker: LatencyTracker(), isConnected: false),
                        .offline, "not connected is offline")
        run.expectEqual(ConnectionQuality.assess(tracker: tracker, isConnected: true),
                        .good, "fast samples read as good")
        run.expectEqual(ConnectionQuality.assess(tracker: slow, isConnected: true),
                        .poor, "slow samples read as poor")

        var flapping = LatencyTracker()
        for sample in [0.1, 0.1, 0.1] { flapping.recordTTFA(sample) }
        for _ in 0..<3 { flapping.recordReconnect() }
        run.expectEqual(ConnectionQuality.assess(tracker: flapping, isConnected: true), .poor,
                        "repeated reconnects outrank fast timings")

        run.expect(ConnectionQuality.good > ConnectionQuality.poor, "quality is ordered")
        for quality in ConnectionQuality.allCases {
            run.expect(!quality.displayName.isEmpty, "\(quality) needs a label")
            run.expect(!quality.symbolName.isEmpty, "\(quality) needs an icon")
        }
        run.expect(ConnectionQuality.good.studentMessage == nil,
                   "a good connection must not announce itself")
        run.expect(ConnectionQuality.offline.studentMessage != nil, "offline must be explained")
        run.expect(ConnectionQuality.offline.studentMessage?.lowercased().contains("keep going") == true,
                   "the offline message must reassure, not alarm: it falls back to Demo Mode")

        // --- Barge-in ---------------------------------------------------------------
        var barge = BargeInTracker()
        run.expect(!barge.isMeasuring, "not measuring initially")
        run.expect(barge.meetsBudget, "no samples passes trivially")
        run.expect(barge.audioStopped() == nil, "stopping without a start is a no-op")

        let start = Date()
        barge.speechDetected(at: start)
        run.expect(barge.isMeasuring, "measuring after speech is detected")
        let elapsed = barge.audioStopped(at: start.addingTimeInterval(0.08))
        run.expectClose(elapsed, 0.08, "measured 80ms")
        run.expect(barge.meetsBudget, "80ms is inside the 150ms budget")
        run.expect(!barge.isMeasuring, "measurement completed")

        barge.speechDetected(at: start)
        _ = barge.audioStopped(at: start.addingTimeInterval(0.30))
        run.expect(!barge.meetsBudget,
                   "300ms must fail — the worst case is what the student notices")
        run.expectClose(barge.worst, 0.30, "worst is tracked")

        var cancelled = BargeInTracker()
        cancelled.speechDetected()
        cancelled.cancel()
        run.expect(!cancelled.isMeasuring, "cancel clears the pending measurement")
        run.expect(cancelled.audioStopped() == nil, "a cancelled measurement records nothing")

        // --- Reconnect policy ------------------------------------------------------------
        let policy = ReconnectPolicy()
        run.expectEqual(policy.delay(forAttempt: 0), 0, "attempt 0 is immediate")

        var previous: TimeInterval = 0
        for attempt in 1...5 {
            let delay = policy.delay(forAttempt: attempt, jitterFraction: 1.0)
            run.expect(delay >= previous, "backoff must not shrink at attempt \(attempt)")
            run.expect(delay <= policy.maxDelay, "backoff is capped, got \(delay)")
            previous = delay
        }
        run.expectEqual(policy.delay(forAttempt: 30, jitterFraction: 1.0), policy.maxDelay,
                        "backoff saturates at the cap")

        // Jitter must actually spread retries out.
        let noJitter = policy.delay(forAttempt: 4, jitterFraction: 0)
        let fullJitter = policy.delay(forAttempt: 4, jitterFraction: 1)
        run.expectEqual(noJitter, 0, "zero jitter means retry now")
        run.expect(fullJitter > 0, "full jitter means the whole backoff")

        run.expect(policy.shouldRetry(afterAttempt: 1), "retries early")
        run.expect(!policy.shouldRetry(afterAttempt: policy.maxAttempts), "gives up eventually")
        run.expect(ReconnectPolicy.exhaustedMessage.lowercased().contains("still works"),
                   "giving up must reassure the student that Demo Mode works")

        // --- Self-test result copy -----------------------------------------------------------
        let passed = ConnectionTestResult(didConnect: true, handshake: 0.12,
                                          timeToFirstAudio: 0.28, roundTrip: 0.04)
        run.expect(passed.passed, "a complete result passes")
        run.expect(passed.headline.contains("fast"), "a 280ms result should read as fast")
        run.expect(passed.detail.contains("280ms"), "the detail must quote real numbers")

        let slowResult = ConnectionTestResult(didConnect: true, handshake: 0.4,
                                              timeToFirstAudio: 1.4, roundTrip: 0.5)
        run.expect(slowResult.passed, "slow is still a pass — it connected")
        run.expect(slowResult.headline.lowercased().contains("slow"), "but says it's slow")
        run.expect(slowResult.detail.lowercased().contains("network"),
                   "and blames the network rather than the key")

        let failed = ConnectionTestResult.failed("That key was rejected.")
        run.expect(!failed.passed, "a failure does not pass")
        run.expectEqual(failed.detail, "That key was rejected.", "the reason is surfaced verbatim")
        run.expect(failed.headline.lowercased().contains("couldn't connect"), "failure headline")

        let noAudio = ConnectionTestResult(didConnect: true, handshake: 0.1,
                                           timeToFirstAudio: nil, roundTrip: nil)
        run.expect(!noAudio.passed, "connecting without audio is not a pass")
        run.expect(noAudio.headline.lowercased().contains("no audio"), "and says why")
    }
}

// MARK: - Voice matching

enum VoiceMatchingChecks {
    static let all = CheckSuite(name: "Voice matching") { run in

        func frame(level: Double, speech: Bool = true, brightness: Double = 0.3) -> VoiceFrame {
            VoiceFrame(level: level, brightness: brightness, duration: 0.02, isSpeech: speech)
        }

        // --- Not enough data means no opinion -----------------------------------
        var analyzer = VoiceEnergyAnalyzer()
        run.expect(!analyzer.read().isReliable, "no audio means no reading")
        run.expect(!analyzer.read().inferredMood.isActionable,
                   "an unreliable reading must never be acted on")

        analyzer.ingest(frame(level: 0.3))
        run.expect(!analyzer.read().isReliable, "one frame is not enough")

        // --- Baseline is per-student ---------------------------------------------
        var quiet = VoiceEnergyAnalyzer()
        for _ in 0..<120 { quiet.ingest(frame(level: 0.08)) }
        run.expect(quiet.baselineLevel > 0, "baseline learns from speech")
        let quietReading = quiet.read()
        run.expect(quietReading.isReliable, "120 frames is 2.4s of speech")
        run.expect(abs(quietReading.relativeEnergy - 1.0) < 0.35,
                   "a consistently quiet student is at their OWN normal, got \(quietReading.relativeEnergy)")

        var loud = VoiceEnergyAnalyzer()
        for _ in 0..<120 { loud.ingest(frame(level: 0.75)) }
        run.expect(abs(loud.read().relativeEnergy - 1.0) < 0.35,
                   "a consistently loud student is also at their own normal")

        // --- Change from baseline is what matters -----------------------------------
        var rising = VoiceEnergyAnalyzer()
        for _ in 0..<200 { rising.ingest(frame(level: 0.2)) }   // settle the baseline
        rising.completeTurn()
        for _ in 0..<100 { rising.ingest(frame(level: 0.55)) }  // now much louder
        run.expect(rising.read().relativeEnergy > 1.3,
                   "a sudden jump in loudness should register, got \(rising.read().relativeEnergy)")

        // --- Hesitation --------------------------------------------------------------
        var hesitant = VoiceEnergyAnalyzer()
        for index in 0..<200 {
            // Speak, pause, speak, pause…
            hesitant.ingest(frame(level: 0.3, speech: (index / 10) % 2 == 0))
        }
        run.expect(hesitant.read().hesitation > 0.3,
                   "alternating speech and silence is hesitation, got \(hesitant.read().hesitation)")

        var fluent = VoiceEnergyAnalyzer()
        for _ in 0..<200 { fluent.ingest(frame(level: 0.3)) }
        run.expectEqual(fluent.read().hesitation, 0, "continuous speech has no interior silence")

        // --- Readings map to moods conservatively ---------------------------------------
        let flat = VoiceReading(relativeEnergy: 0.55, relativePace: 0.7,
                                hesitation: 0.1, variability: 0.2, speechSeconds: 3)
        run.expectEqual(flat.inferredMood.mood, .low, "quiet, slow and flat reads as low")

        let stuck = VoiceReading(relativeEnergy: 1.0, relativePace: 1.0,
                                 hesitation: 0.6, variability: 0.3, speechSeconds: 3)
        run.expectEqual(stuck.inferredMood.mood, .confused, "lots of pausing reads as confused")

        let rolling = VoiceReading(relativeEnergy: 1.4, relativePace: 1.3,
                                   hesitation: 0.05, variability: 0.3, speechSeconds: 3)
        run.expectEqual(rolling.inferredMood.mood, .energized, "loud and fast reads as energised")

        let spiky = VoiceReading(relativeEnergy: 1.5, relativePace: 1.0,
                                 hesitation: 0.1, variability: 0.7, speechSeconds: 3)
        run.expectEqual(spiky.inferredMood.mood, .frustrated, "loud and uneven reads as frustrated")

        // Audio-only confidence must stay below what behaviour can claim — it's
        // a weaker signal and must not override hard evidence.
        for reading in [flat, stuck, rolling, spiky] {
            run.expect(reading.inferredMood.confidence <= 0.65,
                       "audio confidence must stay modest, got \(reading.inferredMood.confidence)")
            run.expect(!reading.inferredMood.rationale.isEmpty, "every reading needs a rationale")
        }
        let brief = VoiceReading(relativeEnergy: 2, relativePace: 2,
                                 hesitation: 0, variability: 0, speechSeconds: 0.4)
        run.expectEqual(brief.inferredMood.confidence, 0,
                        "half a second of speech must produce zero confidence")

        // --- Mirroring, not copying --------------------------------------------------------
        let base = Prosody(rate: 0.5, pitch: 1.0, volume: 1.0)

        let fastStudent = VoiceReading(relativeEnergy: 1.0, relativePace: 2.0,
                                       hesitation: 0, variability: 0.2, speechSeconds: 4)
        let matchedFast = fastStudent.matchedProsody(base: base)
        run.expect(matchedFast.rate > base.rate, "Ace speeds up for a fast student")
        run.expect(matchedFast.rate < base.rate + 0.11,
                   "but only partway — fully matching an agitated student helps nobody")

        let slowStudent = VoiceReading(relativeEnergy: 0.8, relativePace: 0.5,
                                       hesitation: 0.5, variability: 0.2, speechSeconds: 4)
        let matchedSlow = slowStudent.matchedProsody(base: base)
        run.expect(matchedSlow.rate < base.rate, "Ace slows down for a slow student")
        run.expect(matchedSlow.preDelay > base.preDelay,
                   "someone hesitating gets more room to think, not less")

        run.expectEqual(VoiceReading.none.matchedProsody(base: base), base,
                        "an unreliable reading changes nothing")

        // Whatever the input, delivery stays in the safe range.
        for energy in [0.25, 1.0, 3.0] {
            for pace in [0.25, 1.0, 3.0] {
                let extreme = VoiceReading(relativeEnergy: energy, relativePace: pace,
                                           hesitation: 1, variability: 1, speechSeconds: 5)
                let matched = extreme.matchedProsody(base: base)
                run.expectEqual(matched, matched.clamped,
                                "matching must never leave the safe prosody range (\(energy), \(pace))")
            }
        }

        // --- Fusing the two signals -------------------------------------------------------------
        let voiceLow = MoodReading(mood: .low, confidence: 0.6, rationale: "quiet")
        let behaviourEnergised = MoodReading(mood: .energized, confidence: 0.6, rationale: "streak")
        let mixed = MoodFusion.combine(voice: voiceLow, behaviour: behaviourEnergised)
        run.expectEqual(mixed.mood, .low,
                        "when signals disagree, err toward the gentler read")

        let agreeing = MoodFusion.combine(
            voice: MoodReading(mood: .confused, confidence: 0.5, rationale: "pauses"),
            behaviour: MoodReading(mood: .confused, confidence: 0.6, rationale: "2 wrong"))
        run.expectEqual(agreeing.mood, .confused, "agreement keeps the mood")
        run.expect(agreeing.confidence > 0.6, "agreement raises confidence")
        run.expect(agreeing.confidence <= 0.95, "confidence is capped below certainty")

        let onlyBehaviour = MoodFusion.combine(
            voice: MoodReading(mood: .energized, confidence: 0.1, rationale: "weak"),
            behaviour: MoodReading(mood: .frustrated, confidence: 0.8, rationale: "3 wrong"))
        run.expectEqual(onlyBehaviour.mood, .frustrated,
                        "a weak voice read must not override hard behavioural evidence")

        let neither = MoodFusion.combine(voice: .unknown, behaviour: .unknown)
        run.expect(!neither.isActionable, "two non-signals stay a non-signal")
    }
}

// MARK: - Key handling

enum KeyChecks {
    static let all = CheckSuite(name: "API key handling") { run in

        run.expectEqual(APIKeyFormat.validate(""), .empty, "empty")
        run.expectEqual(APIKeyFormat.validate("   "), .empty, "whitespace")
        run.expect(APIKeyFormat.validate("sk-abcdefghijklmnopqrstuvwxyz").isUsable, "a plain key")
        run.expect(APIKeyFormat.validate("sk-proj-abcdefghijklmnopqrstuvwxyz").isUsable,
                   "a project key")
        run.expect(APIKeyFormat.validate("sk-svcacct-abcdefghijklmnopqrstuv").isUsable,
                   "a service-account key")
        run.expect(APIKeyFormat.validate("  sk-abcdefghijklmnopqrstuvwxyz  ").isUsable,
                   "surrounding whitespace is trimmed, not rejected")

        // Real paste mistakes, each with a specific message.
        for (input, hint) in [
            ("https://platform.openai.com/keys", "url"),
            ("Bearer sk-abcdefghijklmnopqrst", "bearer"),
            ("sk-abc def", "spaces"),
            ("sk-short", "cut off"),
            ("abcdefghijklmnopqrstuvwxyz", "sk-")
        ] {
            let result = APIKeyFormat.validate(input)
            run.expect(!result.isUsable, "“\(input)” must be rejected")
            run.expect(result.message != nil, "“\(input)” must explain why")
            if let message = result.message {
                run.expect(message.lowercased().contains(hint),
                           "the message for “\(input)” should mention \(hint): got “\(message)”")
            }
        }

        // The fingerprint identifies without exposing.
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz123456a91f"
        let fingerprint = APIKeyFormat.fingerprint(key)
        run.expect(fingerprint.hasSuffix("a91f"), "shows the last four")
        run.expect(fingerprint.hasPrefix("sk-proj-"), "shows the key family")
        run.expect(!fingerprint.contains("abcdefghijklmnop"),
                   "MUST NOT expose the body of the key: “\(fingerprint)”")
        run.expect(fingerprint.count < 20, "fingerprint stays short")
        run.expectEqual(APIKeyFormat.fingerprint("sk-x"), "sk-…", "a too-short key degrades safely")
        run.expectEqual(APIKeyFormat.fingerprint(""), "sk-…", "empty degrades safely")
    }
}
