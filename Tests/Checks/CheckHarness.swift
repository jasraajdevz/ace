//
//  CheckHarness.swift
//  Ace — developer verification harness
//
//  A ~60-line stand-in for XCTest.
//
//  Why not XCTest or Swift Testing? Both ship inside Xcode, and this project is
//  being built on a machine that only has the Swift command-line toolchain. A
//  test suite you can't run is worth nothing, so the assertions live here in
//  plain Swift and run with `swift run AceVerify`.
//
//  Once Xcode is installed these same `CheckSuite` values can be called from a
//  real XCTest/Swift Testing target without changing a line — see README.
//

import Foundation

/// Records pass/fail for one suite.
final class CheckRun {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    let suiteName: String

    init(suiteName: String) { self.suiteName = suiteName }

    /// Assert a condition.
    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            let fileName = URL(fileURLWithPath: String(describing: file)).lastPathComponent
            failures.append("\(message())  [\(fileName):\(line)]")
        }
    }

    /// Assert two measurements are equal within a tolerance.
    ///
    /// Timings derived from `Date` arithmetic are `Double`s that carry rounding
    /// error, so exact equality on them tests floating-point representation
    /// rather than behaviour.
    func expectClose(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #file, line: UInt = #line) {
        let label = message().isEmpty ? "" : "\(message()): "
        guard let actual else {
            expect(false, "\(label)expected ≈\(expected), got nil", file: file, line: line)
            return
        }
        expect(abs(actual - expected) <= tolerance,
               "\(label)expected ≈\(expected) (±\(tolerance)), got \(actual)",
               file: file, line: line)
    }

    /// Assert equality, printing both sides on failure.
    func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                   _ message: @autoclosure () -> String = "",
                                   file: StaticString = #file, line: UInt = #line) {
        let label = message().isEmpty ? "" : "\(message()): "
        expect(actual == expected,
               "\(label)expected \(expected), got \(actual)",
               file: file, line: line)
    }

    var isPassing: Bool { failures.isEmpty }
}

/// A named group of assertions.
struct CheckSuite {
    let name: String
    let body: (CheckRun) -> Void

    func run() -> CheckRun {
        let run = CheckRun(suiteName: name)
        body(run)
        return run
    }
}

/// Run an async body from a synchronous check and hand back its result.
///
/// Pumps the run loop rather than blocking on a semaphore. A semaphore would
/// park the main thread, and anything that hops to `@MainActor` inside `body`
/// would then wait forever on a thread that is itself waiting — the harness
/// would deadlock rather than fail, which is the worst way for a test to break.
///
/// Returns nil if `body` didn't finish inside `timeout`.
func runAsync<T>(timeout: TimeInterval = 5, _ body: @escaping @Sendable () async -> T) -> T? {
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

/// Everything the verifier executes. Add new suites here.
enum AllChecks {
    static var suites: [CheckSuite] {
        [
            CrisisSafetyChecks.detection,
            CrisisSafetyChecks.falsePositives,
            CrisisSafetyChecks.responses,
            CrisisSafetyChecks.regions,
            TextCleanerChecks.all,
            StudyGeneratorChecks.all,
            ProgressionChecks.all,
            VoiceChecks.all,
            TutorChecks.socratic,
            TutorChecks.mood,
            QuizRunnerChecks.all,
            FlashcardRunnerChecks.all,
            SourceTutorChecks.all,
            RealtimeProtocolChecks.all,
            RealtimeInstructionChecks.all,
            LatencyChecks.all,
            VoiceMatchingChecks.all,
            KeyChecks.all,
            RealtimeIntegrationChecks.connection,
            RealtimeIntegrationChecks.states,
            RealtimeIntegrationChecks.unpromptedSpeech,
            RealtimeIntegrationChecks.conversation,
            RealtimeIntegrationChecks.bargeIn,
            RealtimeIntegrationChecks.resilience,
            GoalChecks.all,
            BodyDoubleChecks.all,
            GuardianChecks.all,
            ComfortChecks.all,
            FocusModeChecks.all,
            IdleChecks.all,
            SpeakingDrillChecks.all,
            VoiceSafetyChecks.all,
            UsageMeterChecks.all,
            TierChecks.all,
            PricingChecks.all,
            PaywallFlagChecks.all,
            ShareInboxChecks.all,
            DemoDeckChecks.all,
            DesignSystemChecks.all,
            ContrastChecks.all,
            WidgetAgingChecks.all,
            ShareConcurrencyChecks.all,
            MutePreferenceChecks.all,
            CaptureFlowChecks.all,
            ServiceChecks.comfortMute,
            ServiceChecks.providerSwitching,
            ServiceChecks.moodEasing,
            ServiceChecks.metering,
            ServiceChecks.suppressionLifts,
            ServiceChecks.countableGoals,
        ]
    }
}
