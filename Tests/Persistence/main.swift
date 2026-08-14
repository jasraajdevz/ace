//
//  main.swift
//  Ace — headless persistence harness entry point
//
//  Assembled and run by `Tools/gen/harness_data.py`. Not part of the app, and
//  not part of the SPM verification target — it needs the macro-stripped copies
//  of the SwiftData files, which only that script produces.
//

import Foundation

let boldGreen = "\u{001B}[1;32m"
let boldRed = "\u{001B}[1;31m"
let dim = "\u{001B}[2m"
let reset = "\u{001B}[0m"

// The suites touch `@MainActor` types (SessionRecorder, CelebrationCenter,
// SafetyCoordinator), so the whole run happens on the main actor. `MainActor
// .assumeIsolated` is valid here because this IS the main thread — top-level
// code in a `main.swift` runs on it.
let suites: [CheckSuite] = MainActor.assumeIsolated {
    [
        PersistenceChecks.stores,
        PersistenceChecks.models,
        PersistenceChecks.recorder,
        PersistenceChecks.demoContent,
        PersistenceChecks.shareImport,
    ]
}

var totalPassed = 0
var totalFailed = 0

for suite in suites {
    let run = suite.run()
    totalPassed += run.passed
    totalFailed += run.failures.count

    if run.isPassing {
        print("  \(boldGreen)✓\(reset) \(suite.name) \(dim)(\(run.passed) checks)\(reset)")
    } else {
        print("  \(boldRed)✗\(reset) \(suite.name) "
              + "\(dim)(\(run.passed) passed, \(run.failures.count) failed)\(reset)")
        for failure in run.failures {
            print("      \(boldRed)•\(reset) \(failure)")
        }
    }
}

print("")
if totalFailed == 0 {
    print("  \(dim)\(totalPassed) persistence checks passed against the in-memory store\(reset)")
    exit(0)
} else {
    print("  \(boldRed)\(totalFailed) failed\(reset), \(totalPassed) passed")
    exit(1)
}
