//
//  CrisisSupportView.swift
//  Ace
//
//  The screen the crisis net puts up (§10).
//
//  Design rules, and they are not negotiable:
//    • It looks nothing like the rest of the app. No violet, no gradient, no
//      brand energy, no XP, no streak, no progress bar. A warm, quiet surface.
//    • No animation beyond a single soft fade. Nothing bounces here.
//    • The resources are the biggest, most obvious thing on screen.
//    • The dismiss control is deliberately understated and requires an explicit
//      tap. There is no swipe-to-dismiss, no timer, no auto-return.
//    • Nothing about studying appears until the student dismisses it.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CrisisSupportView: View {
    let response: CrisisResponse
    let onAcknowledge: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            // A warm, low-saturation ground. Deliberately not `Ink.background`.
            Ink.careBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {

                    // A small, still mark. No logo, no animation.
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Ink.careAccent)
                        .padding(.top, Space.xxl)
                        .accessibilityHidden(true)

                    Text(response.headline)
                        .aceTitle()
                        .foregroundStyle(Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(response.body)
                        .font(Typeface.reading)
                        .foregroundStyle(Ink.textPrimary.opacity(0.88))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)

                    if !response.resources.isEmpty {
                        VStack(spacing: Space.m) {
                            ForEach(response.resources) { resource in
                                SupportResourceRow(resource: resource) {
                                    open(resource)
                                }
                            }
                        }
                        .padding(.top, Space.s)
                    }

                    // The way out. Quiet, but always available — never trap
                    // someone in a screen.
                    Button {
                        onAcknowledge()
                    } label: {
                        Text(response.dismissTitle)
                            .font(Typeface.subheadline)
                            .foregroundStyle(Ink.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.l)
                            .background(Ink.careSurface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Space.l)
                    .accessibilityHint(Text("Returns to the app"))

                    Text("Ace isn't a counsellor and can't help in an emergency. The lines above are staffed by people who can.")
                        .font(Typeface.caption)
                        .foregroundStyle(Ink.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.xxl)
                }
                .aceScreenPadding()
            }
        }
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            // One slow fade. Nothing else moves on this screen.
            withAnimation(.easeOut(duration: 0.45)) { hasAppeared = true }
        }
        // No swipe-to-dismiss: leaving requires the explicit button above.
        .interactiveDismissDisabled()
    }

    private func open(_ resource: SupportResource) {
        let url: URL?
        switch resource.action {
        case .call(let number):
            url = URL(string: "tel://\(number)")
        case .text(let body, let recipient):
            // `&body=` is the cross-platform form iOS accepts for SMS prefill.
            let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
            url = URL(string: "sms:\(recipient)&body=\(encoded)")
        case .web(let address):
            url = URL(string: address)
        case .info:
            url = nil
        }
        guard let url else { return }
        openURL(url)
    }
}

/// One tappable way to reach a human.
private struct SupportResourceRow: View {
    let resource: SupportResource
    let action: () -> Void

    private var isTappable: Bool {
        if case .info = resource.action { return false }
        return true
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.l) {
                Image(systemName: symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(resource.isPrimary ? Ink.careBackground : Ink.careAccent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(resource.title)
                        .font(Typeface.bodyEmphasis)
                        .foregroundStyle(resource.isPrimary ? Ink.careBackground : Ink.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(resource.detail)
                        .font(Typeface.footnote)
                        .foregroundStyle(resource.isPrimary
                                         ? Ink.careBackground.opacity(0.75)
                                         : Ink.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(resource.isPrimary
                                         ? Ink.careBackground.opacity(0.6)
                                         : Ink.textTertiary)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(resource.isPrimary ? Ink.careAccent : Ink.careSurface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(resource.title). \(resource.detail)"))
        .accessibilityAddTraits(isTappable ? .isButton : [])
    }

    private var symbolName: String {
        switch resource.action {
        case .call: "phone.fill"
        case .text: "message.fill"
        case .web: "globe"
        case .info: "info.circle"
        }
    }
}

// MARK: - Inline concern banner

/// The lower-key response for `.concern` signals: warmth, an offer, and a way
/// back to the work — without hijacking the screen.
struct ConcernBanner: View {
    let response: CrisisResponse
    let onDismiss: () -> Void
    var onOpenResource: ((SupportResource) -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.careAccent)
                Text(response.headline)
                    .font(Typeface.bodyEmphasis)
                    .foregroundStyle(Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(response.body)
                .font(Typeface.callout)
                .foregroundStyle(Ink.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !response.resources.isEmpty {
                VStack(spacing: Space.s) {
                    ForEach(response.resources) { resource in
                        Button {
                            open(resource)
                        } label: {
                            HStack(spacing: Space.s) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(resource.title)
                                    .font(Typeface.footnote)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(Ink.careAccent)
                            .padding(.vertical, Space.m)
                            .padding(.horizontal, Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Ink.careAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(resource.title). \(resource.detail)"))
                    }
                }
            }

            Button(response.dismissTitle) {
                Feedback.tap()
                onDismiss()
            }
            .font(Typeface.footnote)
            .foregroundStyle(Ink.textTertiary)
            .padding(.top, Space.xs)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.careSurface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Ink.careAccent.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func open(_ resource: SupportResource) {
        if let onOpenResource {
            onOpenResource(resource)
            return
        }
        switch resource.action {
        case .call(let number):
            if let url = URL(string: "tel://\(number)") { openURL(url) }
        case .text(let body, let recipient):
            let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
            if let url = URL(string: "sms:\(recipient)&body=\(encoded)") { openURL(url) }
        case .web(let address):
            if let url = URL(string: address) { openURL(url) }
        case .info:
            break
        }
    }
}

// MARK: - Attaching the net to any screen

/// Presents the crisis surfaces above whatever screen it's applied to.
///
/// Every screen that accepts free text or voice attaches this once, and then
/// simply calls `appState.safety.check(text)` before acting on input.
struct SafetyNetModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    private var isPresented: Binding<Bool> {
        Binding(
            get: { appState.safety.crisisResponse != nil },
            set: { if !$0 { appState.safety.acknowledgeCrisis() } }
        )
    }

    func body(content: Content) -> some View {
        // `fullScreenCover` is iOS-only. The `#else` branch exists solely so
        // this file compiles in the command-line verification build (which
        // targets macOS) — Ace itself only ever ships the iOS path. See
        // DECISIONS.md D1.
        #if os(iOS)
        content.fullScreenCover(isPresented: isPresented) { cover }
        #else
        content.sheet(isPresented: isPresented) { cover }
        #endif
    }

    @ViewBuilder private var cover: some View {
        if let response = appState.safety.crisisResponse {
            CrisisSupportView(response: response) {
                appState.safety.acknowledgeCrisis()
            }
        }
    }
}

extension View {
    /// Attach the crisis safety net. Required on every free-text and voice
    /// surface — see §10.
    func safetyNet() -> some View {
        modifier(SafetyNetModifier())
    }
}
