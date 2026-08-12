//
//  Latency.swift
//  Ace
//
//  Measuring and surviving the network (§7).
//
//  The budget Ace is built to:
//
//    • TTFA (end of the student's speech → Ace's first audible audio):
//      under 400ms on a good network, p95 ≤ 700ms.
//    • Barge-in (student starts talking → Ace's audio stops): under 150ms.
//    • Demo Mode voice: under 150ms perceived.
//
//  All of it is pure arithmetic over timestamps, which is why it lives in
//  `Core/` and is tested rather than eyeballed. The debug HUD in Settings reads
//  straight off `LatencyTracker`.
//

import Foundation

// MARK: - Budgets

enum LatencyBudget {
    /// Target time-to-first-audio on a good connection.
    static let ttfaTarget: TimeInterval = 0.400
    /// The p95 ceiling. Above this, the connection indicator goes amber.
    static let ttfaP95Ceiling: TimeInterval = 0.700
    /// Barge-in must be faster than this or it stops feeling like an interruption
    /// and starts feeling like a bug.
    static let bargeInCeiling: TimeInterval = 0.150
    /// Demo Mode's perceived start-of-speech.
    static let demoModeCeiling: TimeInterval = 0.150

    static func verdict(forTTFA seconds: TimeInterval) -> LatencyVerdict {
        switch seconds {
        case ..<ttfaTarget: .good
        case ttfaTarget..<ttfaP95Ceiling: .acceptable
        default: .poor
        }
    }
}

enum LatencyVerdict: String, Sendable, Equatable {
    case good, acceptable, poor

    var displayName: String {
        switch self {
        case .good: "Instant"
        case .acceptable: "Fine"
        case .poor: "Laggy"
        }
    }
}

// MARK: - Tracker

/// Rolling latency statistics.
///
/// Keeps a bounded window rather than a lifetime average: what matters is
/// whether the connection is good *now*, and a lifetime mean would hide a
/// network that just fell over.
struct LatencyTracker: Sendable, Equatable {

    /// How many samples the percentiles are computed over.
    static let windowSize = 40

    private(set) var samples: [TimeInterval] = []
    /// Round-trip times from the connection self-test / keepalives.
    private(set) var roundTrips: [TimeInterval] = []
    private(set) var reconnectCount = 0
    private(set) var errorCount = 0

    init() {}

    // MARK: Recording

    mutating func recordTTFA(_ seconds: TimeInterval) {
        // A negative or absurd sample means a clock problem, not a fast network.
        guard seconds >= 0, seconds < 30 else { return }
        samples.append(seconds)
        if samples.count > Self.windowSize { samples.removeFirst(samples.count - Self.windowSize) }
    }

    mutating func recordRoundTrip(_ seconds: TimeInterval) {
        guard seconds >= 0, seconds < 30 else { return }
        roundTrips.append(seconds)
        if roundTrips.count > Self.windowSize {
            roundTrips.removeFirst(roundTrips.count - Self.windowSize)
        }
    }

    mutating func recordReconnect() { reconnectCount += 1 }
    mutating func recordError() { errorCount += 1 }

    mutating func reset() {
        samples.removeAll()
        roundTrips.removeAll()
        reconnectCount = 0
        errorCount = 0
    }

    // MARK: Statistics

    var last: TimeInterval? { samples.last }
    var count: Int { samples.count }

    var p50: TimeInterval? { percentile(0.50) }
    var p95: TimeInterval? { percentile(0.95) }

    var mean: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var meanRoundTrip: TimeInterval? {
        guard !roundTrips.isEmpty else { return nil }
        return roundTrips.reduce(0, +) / Double(roundTrips.count)
    }

    /// Jitter — the mean absolute deviation of round-trip times. High jitter is
    /// what makes audio choppy even when the average looks fine.
    var jitter: TimeInterval? {
        guard roundTrips.count >= 2, let mean = meanRoundTrip else { return nil }
        let deviation = roundTrips.map { abs($0 - mean) }.reduce(0, +)
        return deviation / Double(roundTrips.count)
    }

    /// Nearest-rank percentile. With a 40-sample window this is exact enough,
    /// and it can't produce a value that was never measured — which an
    /// interpolating percentile can, and which is confusing in a debug HUD.
    func percentile(_ fraction: Double) -> TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = min(max(fraction, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    /// Whether we're inside the §7 budget.
    var meetsBudget: Bool {
        guard let p95 else { return true }   // no data yet — assume the best
        return p95 <= LatencyBudget.ttfaP95Ceiling
    }

    var verdict: LatencyVerdict {
        guard let p50 else { return .good }
        return LatencyBudget.verdict(forTTFA: p50)
    }

    /// One line for the debug HUD.
    var hudSummary: String {
        guard !samples.isEmpty else { return "TTFA —" }
        func ms(_ value: TimeInterval?) -> String {
            value.map { "\(Int(($0 * 1000).rounded()))" } ?? "—"
        }
        return "TTFA \(ms(last))ms · p50 \(ms(p50)) · p95 \(ms(p95)) · n=\(samples.count)"
    }
}

// MARK: - Connection quality

/// What the connection indicator shows.
enum ConnectionQuality: Int, Sendable, Comparable, CaseIterable {
    case offline = 0
    case poor = 1
    case fair = 2
    case good = 3

    static func < (lhs: ConnectionQuality, rhs: ConnectionQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .offline: "Offline"
        case .poor: "Weak connection"
        case .fair: "Okay connection"
        case .good: "Good connection"
        }
    }

    /// What Ace tells the student. Only the bad cases say anything — a good
    /// connection needs no announcement.
    var studentMessage: String? {
        switch self {
        case .offline: "I've dropped offline. Switching to on-device mode so we can keep going."
        case .poor: "Connection's rough — I might lag a bit."
        case .fair, .good: nil
        }
    }

    var symbolName: String {
        switch self {
        case .offline: "wifi.slash"
        case .poor: "wifi.exclamationmark"
        case .fair: "wifi"
        case .good: "wifi"
        }
    }

    /// Derive quality from what we've measured.
    static func assess(tracker: LatencyTracker, isConnected: Bool) -> ConnectionQuality {
        guard isConnected else { return .offline }

        // Repeated reconnects are a stronger signal than any single timing.
        if tracker.reconnectCount >= 3 { return .poor }

        guard let p95 = tracker.p95 else {
            // No TTFA samples yet — fall back to round-trip time.
            guard let rtt = tracker.meanRoundTrip else { return .good }
            return rtt < 0.15 ? .good : (rtt < 0.4 ? .fair : .poor)
        }

        if p95 <= LatencyBudget.ttfaTarget { return .good }
        if p95 <= LatencyBudget.ttfaP95Ceiling { return .fair }
        return .poor
    }
}

// MARK: - Reconnection

/// Exponential backoff with jitter.
///
/// The jitter matters more than it looks: without it, every client that dropped
/// during the same outage retries in lockstep and hammers the service the moment
/// it comes back.
struct ReconnectPolicy: Sendable {

    let initialDelay: TimeInterval
    let maxDelay: TimeInterval
    let multiplier: Double
    /// Give up after this many attempts and fall back to Demo Mode.
    let maxAttempts: Int

    init(initialDelay: TimeInterval = 0.4,
         maxDelay: TimeInterval = 12,
         multiplier: Double = 1.8,
         maxAttempts: Int = 6) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.maxAttempts = maxAttempts
    }

    /// Delay before attempt number `attempt` (1-based).
    ///
    /// `jitterFraction` is passed in rather than generated so the whole policy
    /// stays a pure function and can be tested exactly.
    func delay(forAttempt attempt: Int, jitterFraction: Double = 0.5) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let exponential = initialDelay * pow(multiplier, Double(attempt - 1))
        let capped = min(exponential, maxDelay)
        // Full jitter: uniformly random in [0, capped].
        return capped * min(max(jitterFraction, 0), 1)
    }

    func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt < maxAttempts
    }

    /// What to do when we've run out of attempts. Never an error screen — Demo
    /// Mode is right there and it works (§10: graceful offline behaviour).
    static let exhaustedMessage =
        "I can't reach the fast voice right now, so I've switched to on-device mode. "
        + "Everything still works — I'll sound a little different."
}

// MARK: - Barge-in

/// Tracks how quickly Ace shuts up when the student starts talking (§7).
///
/// Separated from the audio engine so the *timing contract* can be tested
/// without any audio at all: `speechDetected` starts the clock, `audioStopped`
/// stops it, and the elapsed time must land under 150ms.
struct BargeInTracker: Sendable, Equatable {

    private(set) var samples: [TimeInterval] = []
    private var detectedAt: Date?

    init() {}

    /// The student started speaking.
    mutating func speechDetected(at time: Date = Date()) {
        detectedAt = time
    }

    /// Ace's audio actually stopped. Returns how long it took, or nil if no
    /// barge-in was in flight.
    @discardableResult
    mutating func audioStopped(at time: Date = Date()) -> TimeInterval? {
        guard let start = detectedAt else { return nil }
        detectedAt = nil
        let elapsed = time.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < 5 else { return nil }
        samples.append(elapsed)
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
        return elapsed
    }

    /// Cancel a pending measurement — the student stopped talking before Ace
    /// had anything to interrupt.
    mutating func cancel() { detectedAt = nil }

    var isMeasuring: Bool { detectedAt != nil }
    var last: TimeInterval? { samples.last }

    var worst: TimeInterval? { samples.max() }

    var mean: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// Every measured barge-in must be inside budget — the worst case is what
    /// the student notices, not the average.
    var meetsBudget: Bool {
        guard let worst else { return true }
        return worst <= LatencyBudget.bargeInCeiling
    }

    var hudSummary: String {
        guard let last, let worst else { return "Barge-in —" }
        return "Barge-in \(Int((last * 1000).rounded()))ms · worst \(Int((worst * 1000).rounded()))ms"
    }
}

// MARK: - Self-test

/// The result of the Settings "test connection" button.
struct ConnectionTestResult: Sendable, Equatable {
    var didConnect: Bool
    /// Time to open the session and receive `session.created`.
    var handshake: TimeInterval?
    /// Time from asking for a reply to the first audio chunk.
    var timeToFirstAudio: TimeInterval?
    var roundTrip: TimeInterval?
    var failureReason: String?

    var passed: Bool {
        didConnect && timeToFirstAudio != nil && failureReason == nil
    }

    /// Headline shown in Settings.
    var headline: String {
        guard didConnect else { return "Couldn't connect" }
        guard let ttfa = timeToFirstAudio else { return "Connected, but no audio came back" }
        switch LatencyBudget.verdict(forTTFA: ttfa) {
        case .good: return "Connected — fast"
        case .acceptable: return "Connected"
        case .poor: return "Connected, but slow"
        }
    }

    /// The detail line. Concrete numbers, because "it works" is not diagnosable.
    var detail: String {
        if let failureReason { return failureReason }
        func ms(_ value: TimeInterval?) -> String {
            value.map { "\(Int(($0 * 1000).rounded()))ms" } ?? "—"
        }
        var parts: [String] = []
        if handshake != nil { parts.append("handshake \(ms(handshake))") }
        if timeToFirstAudio != nil { parts.append("first audio \(ms(timeToFirstAudio))") }
        if roundTrip != nil { parts.append("round trip \(ms(roundTrip))") }
        guard !parts.isEmpty else { return "No measurements." }

        var line = parts.joined(separator: " · ")
        if let ttfa = timeToFirstAudio, ttfa > LatencyBudget.ttfaP95Ceiling {
            line += "\nThat's above the target of \(Int(LatencyBudget.ttfaTarget * 1000))ms — usually the network, not the key."
        }
        return line
    }

    static func failed(_ reason: String) -> ConnectionTestResult {
        ConnectionTestResult(didConnect: false, failureReason: reason)
    }
}
