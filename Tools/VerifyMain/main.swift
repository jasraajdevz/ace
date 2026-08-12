//
//  main.swift
//  AceVerify — developer verification harness entry point
//
//  Run with:  swift run AceVerify
//
//  Exits non-zero if anything fails, so it works as a pre-commit gate.
//

import Foundation

let boldGreen = "\u{001B}[1;32m"
let boldRed = "\u{001B}[1;31m"
let dim = "\u{001B}[2m"
let reset = "\u{001B}[0m"

// Developer tooling modes, before the check run.
if CommandLine.arguments.contains("--make-demo-decks") {
    print("\n\(dim)Generating bundled demo decks…\(reset)\n")
    let ok = DemoDeckBuilder.writeAll(to: "Ace/Resources/DemoDecks")
    print("")
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--dump-demo-decks") {
    DemoDeckBuilder.dump()
    exit(0)
}

print("\n\(dim)Ace — core verification\(reset)\n")

var totalPassed = 0
var totalFailed = 0
var failingSuites: [String] = []

for suite in AllChecks.suites {
    let run = suite.run()
    totalPassed += run.passed
    totalFailed += run.failures.count

    if run.isPassing {
        print("  \(boldGreen)✓\(reset) \(suite.name) \(dim)(\(run.passed) checks)\(reset)")
    } else {
        failingSuites.append(suite.name)
        print("  \(boldRed)✗\(reset) \(suite.name) \(dim)(\(run.passed) passed, \(run.failures.count) failed)\(reset)")
        for failure in run.failures {
            print("      \(boldRed)•\(reset) \(failure)")
        }
    }
}

print("")
if totalFailed == 0 {
    print("\(boldGreen)All \(totalPassed) checks passed.\(reset)\n")
    exit(0)
} else {
    print("\(boldRed)\(totalFailed) failed\(reset), \(totalPassed) passed — \(failingSuites.joined(separator: ", "))\n")
    exit(1)
}
