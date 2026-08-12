//
//  UsageMeter.swift
//  Ace
//
//  What a student actually costs (§Part 5).
//
//  Live Mode bills by the token and by the minute of audio, and voice is the
//  expensive part by a wide margin. If you ship a flat-rate subscription without
//  knowing what your heaviest user consumes, the heaviest user decides your
//  margin for you.
//
//  So everything is metered locally, per session, from the moment Live Mode is
//  switched on. Nothing leaves the device — `UsageLedger` is a value type with a
//  `Codable` snapshot, which is also the seam a future server would sync
//  through.
//
//  Demo Mode is metered too, at zero, so the comparison is visible: a student
//  can see exactly what their key is being spent on and what it would have cost
//  to stay on-device.
//

import Foundation

// MARK: - What gets used

/// One billable event.
struct UsageEvent: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable {
        /// Text sent to the model.
        case inputTokens
        /// Text produced by the model.
        case outputTokens
        /// Audio sent up, in seconds.
        case inputAudio
        /// Audio produced, in seconds.
        case outputAudio
        /// Cached input tokens, billed at a lower rate.
        case cachedInputTokens
    }

    var kind: Kind
    /// Tokens, or seconds for audio.
    var amount: Double
    var at: Date

    init(kind: Kind, amount: Double, at: Date = Date()) {
        self.kind = kind
        self.amount = max(0, amount)
        self.at = at
    }
}

/// Everything used in one study session.
struct SessionUsage: Sendable, Equatable, Codable, Identifiable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
    /// Whether this session ran on the network at all.
    var wasLive: Bool

    var inputTokens: Double = 0
    var cachedInputTokens: Double = 0
    var outputTokens: Double = 0
    var inputAudioSeconds: Double = 0
    var outputAudioSeconds: Double = 0

    init(startedAt: Date = Date(), wasLive: Bool = false) {
        self.startedAt = startedAt
        self.wasLive = wasLive
    }

    mutating func record(_ event: UsageEvent) {
        switch event.kind {
        case .inputTokens: inputTokens += event.amount
        case .cachedInputTokens: cachedInputTokens += event.amount
        case .outputTokens: outputTokens += event.amount
        case .inputAudio: inputAudioSeconds += event.amount
        case .outputAudio: outputAudioSeconds += event.amount
        }
    }

    var voiceMinutes: Double {
        (inputAudioSeconds + outputAudioSeconds) / 60
    }

    var totalTokens: Double {
        inputTokens + cachedInputTokens + outputTokens
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isEmpty: Bool { totalTokens == 0 && voiceMinutes == 0 }
}

// MARK: - Prices

/// What the provider charges.
///
/// **These are defaults, not gospel.** Model prices move, and a hard-coded
/// number that silently goes stale produces a pricing worksheet that is
/// confidently wrong — which is worse than no worksheet. So they're overridable,
/// they carry the date they were last checked, and the worksheet says so.
struct RateCard: Sendable, Equatable, Codable {

    /// US dollars per million tokens.
    var inputPerMillion: Double
    var cachedInputPerMillion: Double
    var outputPerMillion: Double
    /// US dollars per minute of audio.
    var audioInputPerMinute: Double
    var audioOutputPerMinute: Double
    /// When these numbers were last checked, so a stale card is obvious.
    var checkedOn: String
    var label: String

    /// Realtime voice — the expensive path.
    static let realtimeVoice = RateCard(
        inputPerMillion: 4.00,
        cachedInputPerMillion: 0.40,
        outputPerMillion: 16.00,
        audioInputPerMinute: 0.06,
        audioOutputPerMinute: 0.24,
        checkedOn: "2026-08",
        label: "Realtime (voice)"
    )

    /// A cheaper realtime tier, for the metering comparison.
    static let realtimeMini = RateCard(
        inputPerMillion: 0.60,
        cachedInputPerMillion: 0.06,
        outputPerMillion: 2.40,
        audioInputPerMinute: 0.01,
        audioOutputPerMinute: 0.04,
        checkedOn: "2026-08",
        label: "Realtime mini (voice)"
    )

    /// Demo Mode. Everything is on-device, so everything is free — and having a
    /// zero card means the comparison needs no special-casing.
    static let onDevice = RateCard(
        inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0,
        audioInputPerMinute: 0, audioOutputPerMinute: 0,
        checkedOn: "n/a", label: "On-device"
    )

    /// Cost in dollars for a session.
    func cost(of usage: SessionUsage) -> Double {
        usage.inputTokens / 1_000_000 * inputPerMillion
            + usage.cachedInputTokens / 1_000_000 * cachedInputPerMillion
            + usage.outputTokens / 1_000_000 * outputPerMillion
            + usage.inputAudioSeconds / 60 * audioInputPerMinute
            + usage.outputAudioSeconds / 60 * audioOutputPerMinute
    }
}

// MARK: - The ledger

/// Every session's usage, plus the arithmetic over it.
///
/// Bounded: the ledger keeps the most recent sessions and a running lifetime
/// total, so it can't grow without limit on a device that studies daily for
/// three years.
struct UsageLedger: Sendable, Equatable, Codable {

    static let maxRetainedSessions = 120

    private(set) var sessions: [SessionUsage] = []
    /// Sessions dropped from the window still count toward the lifetime totals.
    private(set) var retiredCost: Double = 0
    private(set) var retiredVoiceMinutes: Double = 0
    private(set) var retiredSessionCount: Int = 0

    init() {}

    // MARK: Recording

    mutating func begin(wasLive: Bool, now: Date = Date()) -> UUID {
        let session = SessionUsage(startedAt: now, wasLive: wasLive)
        sessions.append(session)
        trim()
        return session.id
    }

    mutating func record(_ event: UsageEvent, in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].record(event)
    }

    mutating func end(_ sessionID: UUID, now: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].endedAt = now
    }

    /// Drop the oldest sessions, folding their cost into the lifetime totals.
    private mutating func trim(rate: RateCard = .realtimeVoice) {
        guard sessions.count > Self.maxRetainedSessions else { return }
        let overflow = sessions.count - Self.maxRetainedSessions
        for session in sessions.prefix(overflow) {
            retiredCost += rate.cost(of: session)
            retiredVoiceMinutes += session.voiceMinutes
            retiredSessionCount += 1
        }
        sessions.removeFirst(overflow)
    }

    // MARK: Reading

    var liveSessions: [SessionUsage] { sessions.filter(\.wasLive) }

    func cost(rate: RateCard = .realtimeVoice) -> Double {
        retiredCost + sessions.reduce(0) { $0 + rate.cost(of: $1) }
    }

    var voiceMinutes: Double {
        retiredVoiceMinutes + sessions.reduce(0) { $0 + $1.voiceMinutes }
    }

    var totalTokens: Double {
        sessions.reduce(0) { $0 + $1.totalTokens }
    }

    var sessionCount: Int { retiredSessionCount + sessions.count }

    /// Usage inside a rolling window — what a monthly cap is measured against.
    func usage(since: Date) -> (voiceMinutes: Double, tokens: Double, cost: Double) {
        let recent = sessions.filter { $0.startedAt >= since }
        return (
            recent.reduce(0) { $0 + $1.voiceMinutes },
            recent.reduce(0) { $0 + $1.totalTokens },
            recent.reduce(0) { $0 + RateCard.realtimeVoice.cost(of: $1) }
        )
    }

    /// The start of the current calendar month, for cap enforcement.
    static func monthStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    /// Average cost per session, over live sessions only — averaging in free
    /// on-device sessions would flatter the number into meaninglessness.
    func averageLiveSessionCost(rate: RateCard = .realtimeVoice) -> Double {
        let live = liveSessions
        guard !live.isEmpty else { return 0 }
        return live.reduce(0) { $0 + rate.cost(of: $1) } / Double(live.count)
    }

    func averageLiveSessionMinutes() -> Double {
        let live = liveSessions
        guard !live.isEmpty else { return 0 }
        return live.reduce(0) { $0 + $1.voiceMinutes } / Double(live.count)
    }
}

// MARK: - Estimating tokens

/// Token counting without a tokeniser.
///
/// A real BPE tokeniser is a megabyte of vocabulary for a number that only needs
/// to be roughly right — this meters spend for the student's own information and
/// for cap enforcement, not for billing. Four characters per token is the
/// standard rule of thumb for English and lands within about 10%.
///
/// It errs *high* on purpose: a cap that trips slightly early is a mild
/// annoyance; one that trips late is a surprise bill.
enum TokenEstimator {
    static let charactersPerToken: Double = 3.7

    static func tokens(in text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        return (Double(text.count) / charactersPerToken).rounded(.up)
    }

    /// Audio tokens are billed separately from text, but the realtime API also
    /// charges text tokens for the transcript. This is the transcript estimate.
    static func transcriptTokens(seconds: Double) -> Double {
        // ~150 words a minute, ~1.3 tokens a word.
        (seconds / 60 * 150 * 1.3).rounded(.up)
    }
}
