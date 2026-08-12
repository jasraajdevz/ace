//
//  RealtimeProtocol.swift
//  Ace
//
//  The OpenAI Realtime API wire format, as plain Swift values.
//
//  Kept in `Core/` — with no networking in it — for one reason: it means the
//  entire event-handling behaviour (what Ace does when speech starts, when the
//  first audio chunk lands, when the model is interrupted, when the socket dies
//  mid-response) can be driven from a mock server and tested exhaustively
//  without a key, a network, or Xcode.
//
//  A note on naming: the Realtime API renamed several events between the
//  preview and GA releases (`response.audio.delta` → `response.output_audio.delta`,
//  and similarly for transcripts). Both spellings are decoded here. Accepting an
//  alias costs one line; failing to recognise the audio event costs the entire
//  feature, silently, on whichever API version we didn't expect.
//

import Foundation

// MARK: - Model

/// Which realtime model to use.
///
/// Configurable rather than hard-coded because realtime model names move faster
/// than app releases, and a stale identifier is a total outage for Live Mode.
/// Settings exposes an override.
enum RealtimeModel {
    static let `default` = "gpt-realtime"

    /// Models known to work with this client, offered in Settings.
    static let known = [
        "gpt-realtime",
        "gpt-realtime-mini",
        "gpt-4o-realtime-preview"
    ]
}

/// Audio wire format. 24kHz mono PCM16 is what the Realtime API speaks.
enum RealtimeAudio {
    static let sampleRate: Double = 24_000
    static let channels: Int = 1
    static let formatName = "pcm16"
    /// Bytes per sample.
    static let bytesPerFrame = 2

    /// How many frames are in a chunk of the given duration.
    static func frames(forSeconds seconds: Double) -> Int {
        Int(seconds * sampleRate)
    }

    /// Duration of a PCM16 buffer of `byteCount` bytes.
    static func duration(ofBytes byteCount: Int) -> TimeInterval {
        Double(byteCount) / (sampleRate * Double(bytesPerFrame))
    }
}

// MARK: - Session configuration

/// Turn detection. Server-side VAD is what makes conversation feel natural —
/// the student just talks, and the model decides when they've finished.
struct TurnDetection: Codable, Sendable, Equatable {
    var type: String = "server_vad"
    /// 0...1. Higher = less sensitive. Too low and a cough starts a turn.
    var threshold: Double = 0.5
    /// Milliseconds of audio kept from *before* speech was detected, so the
    /// first word isn't clipped.
    var prefixPaddingMs: Int = 300
    /// How long a pause ends the turn. 500ms is the sweet spot for a tutor: long
    /// enough to think mid-sentence, short enough that answering feels instant.
    var silenceDurationMs: Int = 500
    /// Whether the model replies automatically when the turn ends.
    var createResponse: Bool = true
    /// Whether the model's own speech is cut when the student starts talking.
    /// This is the barge-in switch (§7).
    var interruptResponse: Bool = true

    enum CodingKeys: String, CodingKey {
        case type, threshold
        case prefixPaddingMs = "prefix_padding_ms"
        case silenceDurationMs = "silence_duration_ms"
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
    }

    /// Slightly more patient — used when the student is confused or low, where
    /// being cut off mid-thought is the last thing they need (§9).
    static var patient: TurnDetection {
        var detection = TurnDetection()
        detection.silenceDurationMs = 900
        detection.prefixPaddingMs = 400
        return detection
    }

    static let responsive = TurnDetection()
}

/// The `session.update` payload.
struct RealtimeSessionConfig: Codable, Sendable, Equatable {
    var instructions: String
    var voice: String
    var modalities: [String] = ["audio", "text"]
    var inputAudioFormat: String = RealtimeAudio.formatName
    var outputAudioFormat: String = RealtimeAudio.formatName
    var turnDetection: TurnDetection = .responsive
    /// Lower = more focused. A tutor that free-associates is a tutor that
    /// invents facts, so this sits well below the default.
    var temperature: Double = 0.7
    var maxOutputTokens: Int = 1_200
    /// Transcribe the student's own audio so the transcript, the safety net and
    /// the mood heuristics all see what they said.
    var inputAudioTranscriptionModel: String? = "whisper-1"

    enum CodingKeys: String, CodingKey {
        case instructions, voice, modalities, temperature
        case inputAudioFormat = "input_audio_format"
        case outputAudioFormat = "output_audio_format"
        case turnDetection = "turn_detection"
        case maxOutputTokens = "max_response_output_tokens"
        case inputAudioTranscription = "input_audio_transcription"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(voice, forKey: .voice)
        try container.encode(modalities, forKey: .modalities)
        try container.encode(inputAudioFormat, forKey: .inputAudioFormat)
        try container.encode(outputAudioFormat, forKey: .outputAudioFormat)
        try container.encode(turnDetection, forKey: .turnDetection)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxOutputTokens, forKey: .maxOutputTokens)
        if let model = inputAudioTranscriptionModel {
            try container.encode(["model": model], forKey: .inputAudioTranscription)
        }
    }

    init(instructions: String, voice: String) {
        self.instructions = instructions
        self.voice = voice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? "alloy"
        modalities = try container.decodeIfPresent([String].self, forKey: .modalities) ?? ["audio", "text"]
        turnDetection = try container.decodeIfPresent(TurnDetection.self, forKey: .turnDetection) ?? .responsive
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 1_200
    }
}

// MARK: - Client events

/// Something Ace sends to the server.
enum RealtimeClientEvent: Sendable {
    case updateSession(RealtimeSessionConfig)
    /// Base64 PCM16 audio from the microphone.
    case appendAudio(String)
    case commitAudio
    case clearAudio
    /// Ask for a reply now (used when server VAD is off, and for the opening line).
    case createResponse
    /// Stop the model mid-sentence. This is the barge-in path (§7).
    case cancelResponse
    /// Inject a text message as if the student typed it.
    case sendText(String)

    var jsonObject: [String: Any] {
        switch self {
        case .updateSession(let config):
            let data = (try? JSONEncoder().encode(config)) ?? Data()
            let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ["type": "session.update", "session": session]

        case .appendAudio(let base64):
            return ["type": "input_audio_buffer.append", "audio": base64]

        case .commitAudio:
            return ["type": "input_audio_buffer.commit"]

        case .clearAudio:
            return ["type": "input_audio_buffer.clear"]

        case .createResponse:
            return ["type": "response.create"]

        case .cancelResponse:
            return ["type": "response.cancel"]

        case .sendText(let text):
            return [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]]
                ]
            ]
        }
    }

    func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    }
}

// MARK: - Server events

/// Something the server sends back.
///
/// Only the events Ace actually acts on are modelled; everything else decodes to
/// `.other` rather than throwing. An unknown event must never break the stream —
/// the API adds events over time and none of them are our business.
enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated(id: String)
    case sessionUpdated
    /// Server VAD heard the student start talking. This is the barge-in trigger.
    case speechStarted
    case speechStopped
    /// The student's own words, transcribed.
    case inputTranscript(String)
    case responseCreated(id: String)
    /// A chunk of Ace's voice, base64 PCM16. The first one stops the TTFA clock.
    case audioDelta(base64: String)
    case audioDone
    /// A chunk of Ace's words.
    case textDelta(String)
    case responseDone
    case rateLimited(resetSeconds: Double?)
    case error(code: String?, message: String)
    case other(type: String)

    var typeName: String {
        switch self {
        case .sessionCreated: "session.created"
        case .sessionUpdated: "session.updated"
        case .speechStarted: "input_audio_buffer.speech_started"
        case .speechStopped: "input_audio_buffer.speech_stopped"
        case .inputTranscript: "conversation.item.input_audio_transcription.completed"
        case .responseCreated: "response.created"
        case .audioDelta: "response.output_audio.delta"
        case .audioDone: "response.output_audio.done"
        case .textDelta: "response.output_text.delta"
        case .responseDone: "response.done"
        case .rateLimited: "rate_limits.updated"
        case .error: "error"
        case .other(let type): type
        }
    }

    /// Parse a server frame. Never throws: a frame we can't understand becomes
    /// `.other`, because dropping the connection over an unrecognised event
    /// would be a self-inflicted outage.
    static func decode(_ data: Data) -> RealtimeServerEvent {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            return .other(type: "malformed")
        }
        return decode(type: type, object: object)
    }

    static func decode(type: String, object: [String: Any]) -> RealtimeServerEvent {
        switch type {
        case "session.created":
            let session = object["session"] as? [String: Any]
            return .sessionCreated(id: session?["id"] as? String ?? "")

        case "session.updated":
            return .sessionUpdated

        case "input_audio_buffer.speech_started":
            return .speechStarted

        case "input_audio_buffer.speech_stopped":
            return .speechStopped

        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscript(object["transcript"] as? String ?? "")

        case "response.created":
            let response = object["response"] as? [String: Any]
            return .responseCreated(id: response?["id"] as? String ?? "")

        // Both spellings — see the file header.
        case "response.output_audio.delta", "response.audio.delta":
            return .audioDelta(base64: object["delta"] as? String ?? "")

        case "response.output_audio.done", "response.audio.done":
            return .audioDone

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta",
             "response.output_text.delta", "response.text.delta":
            return .textDelta(object["delta"] as? String ?? "")

        case "response.done":
            // A response can finish because the *student* interrupted it. That's
            // a normal, healthy outcome, not a failure.
            return .responseDone

        case "rate_limits.updated":
            let limits = object["rate_limits"] as? [[String: Any]]
            let soonest = limits?.compactMap { $0["reset_seconds"] as? Double }.min()
            return .rateLimited(resetSeconds: soonest)

        case "error":
            let error = object["error"] as? [String: Any]
            return .error(
                code: error?["code"] as? String,
                message: error?["message"] as? String ?? "Unknown realtime error"
            )

        default:
            return .other(type: type)
        }
    }

    /// True for events that mean audio is flowing — used to stop the TTFA clock.
    var isFirstAudio: Bool {
        if case .audioDelta(let base64) = self { return !base64.isEmpty }
        return false
    }
}

// MARK: - Instructions

/// Builds the system prompt for a Live session.
///
/// This is where Ace's personality and its teaching rules become instructions
/// rather than Swift code. Everything here mirrors what `SocraticEngine` and
/// `SourceTutor` do in Demo Mode — deliberately, so switching providers changes
/// the latency and the naturalness, never the pedagogy or the safety behaviour.
enum RealtimeInstructions {

    static func build(persona: VoicePersona,
                      gradeLevel: GradeLevel,
                      subject: Subject?,
                      sourceText: String,
                      studentNote: String,
                      studentName: String,
                      mood: MoodReading) -> String {

        let name = studentName.trimmed.isEmpty ? "the student" : studentName.trimmed
        let subjectLine = subject.map { "They're working on \($0.displayName). " } ?? ""
        let noteLine = studentNote.trimmed.isEmpty
            ? ""
            : "In their own words, what they're doing right now: “\(studentNote.trimmed)”. "

        // The source is truncated because a whole chapter would crowd out the
        // instructions themselves in the context window.
        let material = String(sourceText.prefix(6_000))

        return """
        You are Ace, a study tutor talking out loud with \(name), who is at \
        \(gradeLevel.displayName) level. \(subjectLine)\(noteLine)

        # How you teach — this is the whole point of you
        Never lead with the answer. Ask first. When \(name) is stuck, give ONE hint, \
        then wait. Climb this ladder one rung per turn:
        1. Ask them what the question is actually asking.
        2. Point at the part of their material that matters, without naming the answer.
        3. Give the shape of the answer — how many words, what kind of thing it is.
        4. Give the definition without the label.
        5. Only now, give the answer, with the reasoning.
        If they say "just tell me", "I give up" or anything like it, jump straight to \
        step 5. Refusing a direct request is stonewalling, not teaching.
        When they get something right, ask them WHY — getting it right by elimination \
        and by understanding look identical from the outside.

        # Stay on their page
        Everything you say must come from the material below. If they ask about \
        something that isn't in it, say so plainly and ask them to point you at the \
        right bit. Never invent a fact, a date, a formula or a quotation. Being \
        wrong confidently is worse than being unhelpful.

        # How you sound
        \(personaDirection(persona)).
        \(registerDirection(gradeLevel))
        \(moodDirection(mood))
        Keep replies short — two or three sentences, then stop and let them talk. \
        You are having a conversation, not delivering a lecture. Never read long \
        passages aloud. Never use bullet points or markdown; this is speech.

        # Safety — overrides everything above
        If \(name) says anything suggesting self-harm, suicide, or that they don't \
        want to be alive: stop tutoring immediately. Do not quiz, do not mention \
        points or streaks, do not try to cheer them up or minimise it. Respond with \
        warmth and no judgement, tell them you're glad they said it, and encourage \
        them to talk to someone they trust or a crisis line right now. Do not \
        role-play as a therapist and do not promise confidentiality. Stay with them; \
        do not steer back to studying.

        # Their material
        \(material)
        """
    }

    private static func personaDirection(_ persona: VoicePersona) -> String {
        "Your character: \(persona.blurb) Speak like that consistently"
    }

    private static func registerDirection(_ gradeLevel: GradeLevel) -> String {
        switch gradeLevel.band {
        case .elementary:
            return "Use short, everyday words. Sentences of about ten words. No jargon unless the page uses it, and then explain it once."
        case .middle:
            return "Plain language, short sentences. Introduce proper terms but always tie them to something concrete."
        case .high:
            return "Use the subject's real vocabulary. Assume they can follow a two-step argument."
        case .college:
            return "Talk to them as a peer. Use precise terminology, and push on the parts of their reasoning that are hand-waved."
        }
    }

    /// The voice-matching half of §9, expressed as instructions.
    private static func moodDirection(_ mood: MoodReading) -> String {
        guard mood.isActionable else {
            return "Match their energy and pace as you hear it — mirror how they sound, never imitate their voice."
        }
        switch mood.mood {
        case .energized:
            return "They sound like they're rolling. Match it — quicker, brighter, keep the momentum."
        case .focused:
            return "They're in the zone. Stay out of the way: shorter replies, less chat."
        case .confused:
            return "They sound lost. Slow right down. Smaller steps, more pauses, one idea per turn."
        case .frustrated:
            return "They sound frustrated. Slow down and soften. Do not sound cheerful at them — it reads as mocking. Acknowledge the question is genuinely hard."
        case .low:
            return "They sound low. Be gentle and unhurried. Warmth first, work second. No hype, no pressure, no mention of streaks."
        case .distracted:
            return "They've drifted. Re-engage with something short and concrete — a direct question, not a recap."
        case .neutral:
            return "Match their energy and pace as you hear it."
        }
    }

    /// Turn detection tuned to mood: a confused or low student gets longer to
    /// think before Ace assumes they've finished.
    static func turnDetection(for mood: MoodReading) -> TurnDetection {
        guard mood.isActionable else { return .responsive }
        return mood.mood.wantsGentleness ? .patient : .responsive
    }
}
