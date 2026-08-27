//
//  OnboardingFlowView.swift
//  IntelliDocScanSignPDF
//

import AuthenticationServices
import SwiftUI

/// Full-screen 5-step flow:
/// hook → interactive redaction demo → persona selector → account → paywall.
struct OnboardingFlowView: View {
    @Environment(SubscriptionManager.self) private var subscriptions

    @State private var coordinator = OnboardingPaywallCoordinator()

    /// Called with the chosen persona when the flow finishes.
    let onFinish: (OnboardingPersona?) -> Void

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                stepIndicator
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ZStack {
                    switch coordinator.step {
                    case .hook: HookStep(onContinue: coordinator.advance)
                    case .demo: DemoStep(onContinue: coordinator.advance)
                    case .persona:
                        PersonaStep(
                            persona: coordinator.persona,
                            onSelect: coordinator.select,
                            onContinue: coordinator.advance
                        )
                    case .account:
                        AccountStep(onContinue: coordinator.advance)
                    case .paywall:
                        PaywallStep(
                            onPurchase: {
                                coordinator.completeWithPurchase()
                            },
                            onSkip: {
                                coordinator.skip()
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .environment(subscriptions)
        .animation(Theme.flight, value: coordinator.step)
        .onChange(of: coordinator.isFinished) { _, finished in
            guard finished else { return }
            onFinish(coordinator.persona)
        }
    }

    // MARK: - Progress

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPaywallCoordinator.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(
                        step.rawValue <= coordinator.step.rawValue
                            ? Theme.amber
                            : Theme.hairline
                    )
                    .frame(height: 3)
                    .frame(maxWidth: step.rawValue == coordinator.step.rawValue ? 34 : 16)
            }
        }
        .padding(.horizontal, 24)
        .animation(Theme.snap, value: coordinator.step)
    }
}

// MARK: - Step 1: Hook

/// Animated feature showcase: "Scan. Redact. Sign. File in seconds."
private struct HookStep: View {
    let onContinue: () -> Void

    @State private var revealedFeatures: Set<Int> = []

    private let features: [(symbol: String, title: String, subtitle: String)] = [
        ("doc.viewfinder", "Scan", "Edge-detected, multi-page PDFs in one pass"),
        ("eye.slash.fill", "Redact", "SSNs, cards and phones found & burned out on-device"),
        ("signature", "Sign", "PencilKit stamps with a SHA-256 audit trail"),
        ("archivebox.fill", "File", "Smart folders that route themselves"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 10) {
                Text("Scan. Redact. Sign.\nFile in seconds.")
                    .font(Theme.display(.largeTitle))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text("The document vault that never reads your documents.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.amber.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: feature.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.amber)
                                .symbolEffect(.bounce, value: revealedFeatures.contains(index))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(feature.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
                    .opacity(revealedFeatures.contains(index) ? 1 : 0)
                    .offset(y: revealedFeatures.contains(index) ? 0 : 18)
                }
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 26)

            Button {
                Haptics.impact(.medium)
                onContinue()
            } label: {
                Text("See it in action")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1206"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        Capsule().fill(LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom))
                    }
                    .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .task {
            for index in features.indices {
                try? await Task.sleep(for: .milliseconds(240))
                withAnimation(Theme.flight) {
                    _ = revealedFeatures.insert(index)
                }
                Haptics.selection()
            }
        }
    }
}

// MARK: - Step 2: Interactive demo

/// One tap: the sample document's SSN auto-blackouts, then the page slides
/// into its folder — the core magic in miniature.
private struct DemoStep: View {
    let onContinue: () -> Void

    @State private var phase: DemoPhase = .idle

    private enum DemoPhase {
        case idle, redacting, filed
    }

    private struct DemoLine: Identifiable {
        let id: Int
        let text: String
        let isPII: Bool
    }

    private let lines: [DemoLine] = [
        DemoLine(id: 0, text: "INTAKE FORM — REGIONAL CLINIC", isPII: false),
        DemoLine(id: 1, text: "Patient: Alex Morgan", isPII: false),
        DemoLine(id: 2, text: "SSN: 078-05-1120", isPII: true),
        DemoLine(id: 3, text: "Card ending: 4111 1111 1111 1111", isPII: true),
        DemoLine(id: 4, text: "Phone: (415) 555-0132", isPII: true),
        DemoLine(id: 5, text: "Reviewed by intake staff", isPII: false),
    ]

    private var isFiled: Bool { phase == .filed }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Text("Tap once. Watch the magic.")
                    .font(Theme.display(.title2))
                    .foregroundStyle(Theme.textPrimary)
                Text("Real PII detection runs entirely on this device —")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("no server ever sees the page.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 22)

            ZStack {
                // Destination folder the page flies into.
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: "3FB0A0").opacity(0.14))
                            .frame(width: 86, height: 86)
                        Image(systemName: isFiled ? "folder.fill.badge.checkmark" : "folder.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(Color(hex: "3FB0A0"))
                            .symbolEffect(.bounce, value: isFiled)
                    }
                    Text("Medical & Health")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "3FB0A0"))
                }
                .opacity(phase == .idle ? 0.25 : 1)

                // The demo document.
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(lines) { line in
                        ZStack(alignment: .leading) {
                            Text(line.text)
                                .font(line.id == 0 ? Theme.mono(.caption, weight: .bold) : Theme.mono(.footnote))
                                .foregroundStyle(line.id == 0 ? Color(hex: "3A3B40") : Color(hex: "26272C"))

                            if line.isPII && phase != .idle {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color(hex: "15161A"))
                                    .overlay {
                                        HStack(spacing: 4) {
                                            Image(systemName: "eye.slash.fill")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(Color(hex: "E2664F"))
                                            Text("REDACTED")
                                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                .foregroundStyle(Color(hex: "E2664F"))
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 320, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.paper)
                }
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                .scaleEffect(isFiled ? 0.22 : 1)
                .offset(
                    x: isFiled ? 0 : 0,
                    y: isFiled ? -30 : 0
                )
                .opacity(isFiled ? 0 : 1)
                .rotationEffect(.degrees(isFiled ? 14 : 0))
            }
            .frame(maxHeight: 340)
            .animation(Theme.flight, value: phase)

            Spacer(minLength: 20)

            Button {
                Haptics.impact(.medium)
                switch phase {
                case .idle:
                    withAnimation(Theme.snap) { phase = .redacting }
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        withAnimation(Theme.flight) { phase = .filed }
                        Haptics.success()
                    }
                case .redacting:
                    break
                case .filed:
                    onContinue()
                }
            } label: {
                Label(
                    phase == .idle ? "Redact & File it" : phase == .redacting ? "Redacting…" : "Continue",
                    systemImage: phase == .idle ? "wand.and.stars" : phase == .filed ? "arrow.right" : "hourglass"
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(phase == .redacting)
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Step 3: Persona

/// Goal selector that customizes the default folder set.
private struct PersonaStep: View {
    let persona: OnboardingPersona?
    let onSelect: (OnboardingPersona) -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 14)

            VStack(spacing: 8) {
                Text("What's your paperwork about?")
                    .font(Theme.display(.title2))
                    .foregroundStyle(Theme.textPrimary)
                Text("We'll build your folders around it. Change anything later.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 22)

            VStack(spacing: 12) {
                ForEach(OnboardingPersona.allCases) { option in
                    PersonaRow(
                        persona: option,
                        isSelected: persona == option
                    ) {
                        Haptics.selection()
                        onSelect(option)
                    }
                }
            }
            .padding(.horizontal, 26)

            Spacer(minLength: 22)

            Button {
                Haptics.impact(.medium)
                onContinue()
            } label: {
                Text(persona == nil ? "Skip personalization" : "Continue")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1206"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        Capsule().fill(
                            LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                        )
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
    }
}

private struct PersonaRow: View {
    let persona: OnboardingPersona
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Theme.amber.opacity(0.16) : Color.white.opacity(0.05))
                        .frame(width: 46, height: 46)
                    Image(systemName: persona.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(persona.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Theme.amber.opacity(0.06) : Color.white.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Theme.amber.opacity(0.7) : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Step 4: Account

/// One-tap Sign in with Apple — anchors the user's identity before the
/// purchase decision, with a friction-free skip for privacy-first users.
private struct AccountStep: View {
    let onContinue: () -> Void

    @Environment(AccountService.self) private var account

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 14)

            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.amber.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: account.isSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.shield.checkmark")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .symbolEffect(.bounce, value: account.isSignedIn)
                }

                Text(account.isSignedIn ? "You're in." : "Claim your vault.")
                    .font(Theme.display(.title2))
                    .foregroundStyle(Theme.textPrimary)

                if account.isSignedIn {
                    Text("Signed in as \(account.displayName). Your Apple ID never sees your documents.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Sign in with Apple to anchor your purchase across reinstalls. Everything else stays on this device.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 30)

            Spacer(minLength: 24)

            if account.isSignedIn {
                Button {
                    Haptics.impact(.medium)
                    onContinue()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            Capsule().fill(
                                LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                            )
                        }
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .padding(.horizontal, 26)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    account.handle(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(Capsule())
                .background {
                    // White mount so the standard black button reads on the
                    // graphite backdrop, matching the Settings styling.
                    Capsule().fill(Color.white).padding(-5)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .padding(.horizontal, 26)
                .transition(.opacity)

                Button {
                    Haptics.selection()
                    onContinue()
                } label: {
                    Text("Skip for now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Skip sign in for now")
            }

            Text("Scans never touch the cloud without your say-so.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
                .padding(.bottom, 30)
        }
        .animation(Theme.flight, value: account.isSignedIn)
        .onChange(of: account.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                Haptics.success()
            }
        }
    }
}

// MARK: - Step 5: Paywall wrapper

private struct PaywallStep: View {
    let onPurchase: () -> Void
    let onSkip: () -> Void

    @Environment(SubscriptionManager.self) private var subscriptions
    @State private var hasObservedPurchase = false

    var body: some View {
        VStack(spacing: 0) {
            PaywallView(showsCloseButton: false)
                .frame(maxHeight: .infinity)

            Button {
                Haptics.selection()
                onSkip()
            } label: {
                Text("Continue with free tier — 5 redactions, 1 signature")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 12)
            }
        }
        .onChange(of: subscriptions.hasPro) { _, isPro in
            if isPro && !hasObservedPurchase {
                hasObservedPurchase = true
                Haptics.success()
                onPurchase()
            }
        }
    }
}

#Preview {
    OnboardingFlowView { _ in }
        .environment(SubscriptionManager.previewInstance)
        .preferredColorScheme(.dark)
}
