// swift-tools-version: 5.9
//
//  Package.swift — DEVELOPER VERIFICATION HARNESS. Not part of the shipping app.
//
//  The Ace app itself is an Xcode project (`Ace.xcodeproj`). This package exists
//  only so the pure-logic layers can be compiled and unit-tested from the
//  command line with `swift run AceVerify` — no Xcode, no simulator, no iOS SDK
//  required.
//
//  It points at the *same source files* the app compiles (see `sources:` below),
//  so there is no second copy of anything to drift out of sync.
//
//  What it can cover:  Core/ (Foundation-only) and DesignSystem/ (SwiftUI —
//                      which does build against the macOS SDK).
//  What it can't:      SwiftData models (@Model needs Xcode's macro plugin) and
//                      anything UIKit-only. Those are covered by a syntax gate
//                      instead — see `Tools/verify.sh`.
//

import PackageDescription

let package = Package(
    name: "AceVerify",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AceVerify",
            path: ".",
            exclude: [
                // Not source.
                "Ace/Assets.xcassets",
                "Ace/Resources",
                "Ace/Data",              // SwiftData @Model — see header
                // Screens bound to SwiftData (@Model needs Xcode's macro plugin).
                // Features/Safety is the exception — it touches no persistence, so it
                // is compiled below.
                "Ace/Features/Onboarding",
                "Ace/Features/Capture",
                "Ace/Features/Home",
                "Ace/Features/Study/QuizView.swift",
                "Ace/Features/Study/FlashcardView.swift",
                "Ace/Features/Study/TutorView.swift",
                "Ace/Features/Settings/SettingsView.swift",
                "Ace/Services/ShareImporter.swift",   // SwiftData-bound
                "Ace/AceApp.swift",
                // `@main` is exclusive and this target already has a main.swift.
                "AceWidget/AceWidgetBundle.swift",
                "Ace.xcodeproj",
                "Config",
                "Tools/gen",
                "Tools/verify.sh",
                "README.md",
                "DECISIONS.md",
            ],
            sources: [
                "Ace/Core",           // the logic under test
                "Ace/DesignSystem",   // type-checked against the macOS SDK
                "Ace/Services",       // Vision / AVFoundation / Speech — all macOS-available
                "Shared",             // the app<->widget contract, compiled into both targets
                "AceWidget",          // WidgetKit builds on macOS too, so the widget is checked
                "Ace/Features/Safety",// the crisis surfaces — no SwiftData, so fully checkable
                // Individual screens that touch no persistence. `sources` takes
                // file paths as well as directories, so the SwiftData-free parts
                // of a mixed folder can still be type-checked.
                "Ace/Features/Study/QuizResultsView.swift",
                "Ace/Features/Study/FlashcardResultsView.swift",
                "Ace/Features/Settings/LiveModeSettings.swift",
                "Ace/Features/Settings/PaywallView.swift",
                "Tests/Checks",       // the assertions
                "Tools/VerifyMain",   // the runner's entry point
            ]
        )
    ]
)
