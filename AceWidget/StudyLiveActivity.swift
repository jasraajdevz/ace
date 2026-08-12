//
//  StudyLiveActivity.swift
//  AceWidget
//
//  The session on the lock screen and in the Dynamic Island (§Part 5).
//
//  Same restraint as the home-screen widget: a ring, a number, and one line. A
//  Live Activity that animates or shouts is a Live Activity that gets dismissed,
//  and the point of this one is to sit there quietly while somebody works.
//

import SwiftUI
import WidgetKit

#if os(iOS)
import ActivityKit

struct StudyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            // The lock-screen / banner presentation.
            LockScreenView(context: context)
                .activityBackgroundTint(WidgetInk.background)
                .activitySystemActionForegroundColor(WidgetInk.accent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProgressRing(progress: context.state.progress,
                                 isMeasurable: context.attributes.isMeasurable)
                        .frame(width: 42, height: 42)
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.streakDays > 0 {
                        Label {
                            Text("\(context.state.streakDays)")
                                .font(.system(size: 15, design: .rounded).weight(.heavy))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "flame.fill")
                        }
                        .foregroundStyle(WidgetInk.flame)
                        .padding(.trailing, 4)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.goalText)
                            .font(.system(size: 13, design: .rounded).weight(.semibold))
                            .foregroundStyle(WidgetInk.textPrimary)
                            .lineLimit(1)
                        Text(context.state.status)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(WidgetInk.textSecondary)
                            .lineLimit(1)
                    }
                }

            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "book.fill")
                    .foregroundStyle(WidgetInk.accent)
            } compactTrailing: {
                Text("\(context.state.minutes)m")
                    .font(.system(size: 13, design: .rounded).weight(.semibold))
                    .foregroundStyle(WidgetInk.textSecondary)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "book.fill")
                    .foregroundStyle(WidgetInk.accent)
            }
            .widgetURL(URL(string: "ace://session"))
        }
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let context: ActivityViewContext<StudyActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(progress: context.state.progress,
                         isMeasurable: context.attributes.isMeasurable)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.goalText)
                    .font(.system(size: 15, design: .rounded).weight(.semibold))
                    .foregroundStyle(WidgetInk.textPrimary)
                    .lineLimit(1)

                Text(context.state.status)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(WidgetInk.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(context.state.minutes)")
                    .font(.system(size: 24, design: .rounded).weight(.heavy))
                    .foregroundStyle(WidgetInk.textPrimary)
                    .monospacedDigit()
                Text("min")
                    .font(.system(size: 10, design: .rounded).weight(.semibold))
                    .foregroundStyle(WidgetInk.textTertiary)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(context.attributes.goalText). \(context.state.minutes) minutes. \(context.state.status)"))
    }
}

/// Shared ring. For a landmark goal there's nothing to measure, so it shows a
/// steady arc rather than a progress bar that would never move.
private struct ProgressRing: View {
    let progress: Double
    let isMeasurable: Bool

    var body: some View {
        ZStack {
            Circle().stroke(WidgetInk.surfaceRaised, lineWidth: 5)
            Circle()
                .trim(from: 0, to: isMeasurable ? max(0.02, min(progress, 1)) : 0.12)
                .stroke(WidgetInk.brandGradient,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "book.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WidgetInk.accent)
        }
    }
}

#endif
