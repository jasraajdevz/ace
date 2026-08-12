//
//  QuickCaptureIntent.swift
//  AceWidget
//
//  Quick capture from the widget (§Part 5).
//
//  iOS 17 widgets can run an `AppIntent` on tap without launching the app. This
//  one records the request in the App Group and opens Ace straight into capture,
//  so "photograph this worksheet" is one tap from the home screen rather than
//  four.
//
//  `openAppWhenRun` is true because the whole point is to get to the camera. An
//  intent that silently succeeded and left the student on the home screen would
//  be worse than no button.
//

import AppIntents
import WidgetKit
import SwiftUI

struct QuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Add study material"
    static var description = IntentDescription(
        "Opens Ace ready to photograph, scan or paste something."
    )

    /// We need the app: this ends at the camera.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Written to the shared container rather than passed through the URL, so
        // the request survives a cold launch.
        QuickCaptureRequest.request()
        return .result()
    }
}

// MARK: - The button

/// The capture button shown on the medium widget.
///
/// Kept visually quiet — the widget's job is still the streak and the nudge;
/// this is a shortcut, not the headline.
struct QuickCaptureButton: View {
    var body: some View {
        Button(intent: QuickCaptureIntent()) {
            HStack(spacing: 5) {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 11, weight: .bold))
                Text("Add")
                    .font(.system(size: 12, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(WidgetInk.accent)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(WidgetInk.accent.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add study material"))
    }
}
