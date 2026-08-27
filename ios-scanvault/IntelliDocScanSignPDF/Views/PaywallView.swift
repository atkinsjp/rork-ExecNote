//
//  PaywallView.swift
//  IntelliDocScanSignPDF
//

import StoreKit
import SwiftUI

/// Conversion paywall: privacy-first value prop, three pricing tiers, social
/// proof, security badges and legal / restore links.
///
/// Renders entirely from `PlanPresentation` metadata, so previews and the mock
/// storefront work with zero network or App Store Connect dependencies.
struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscriptions

    var compact = false

    @State private var selectedPlanID: String = PlanPresentation.mockCatalog[0].id
    @State private var presentingLegalKind: LegalDocumentKind?
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    private var selectedPlan: PlanPresentation {
        subscriptions.plans.first { $0.id == selectedPlanID }
            ?? PlanPresentation.mockCatalog[0]
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    hero
                    featureList
                    if RemoteConfigManager.shared.annualDiscountPercentage > 0 {
                        annualDiscountBadge
                    }
                    planTiers
                    callToAction
                    restoreRow
                    proofRow
                    legalRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 26)
            }
        }
        // Mandated legal surfaces open in-app (5.1.1).
        .sheet(item: $presentingLegalKind) { kind in
            LegalDocumentView(kind: kind)
        }
        .onAppear {
            if !subscriptions.plans.contains(where: { $0.id == selectedPlanID }) {
                selectedPlanID = subscriptions.plans.first?.id ?? PlanPresentation.mockCatalog[0].id
            }
        }
        .animation(Theme.snap, value: subscriptions.plans.count)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Theme.amber)
                .symbolEffect(.pulse, options: .nonRepeating)

            Text("IntelliDoc Pro")
                .font(Theme.display(.largeTitle))
                .foregroundStyle(Theme.textPrimary)

            Text(heroCopy)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(.top, 6)
    }

    private var featureList: some View {
        VStack(spacing: 10) {
            ForEach(ProFeature.allCases) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .frame(width: 34, height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.12))
                        }
                    Text(feature.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "3FB0A0"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
            }
        }
    }

    private var planTiers: some View {
        VStack(spacing: 12) {
            if subscriptions.isLoadingProducts && subscriptions.plans.isEmpty {
                ProgressView()
                    .tint(Theme.amber)
                    .frame(height: 180)
            } else {
                ForEach(subscriptions.plans) { plan in
                    PlanTierRow(
                        plan: plan,
                        isSelected: selectedPlanID == plan.id
                    ) {
                        Haptics.impact(.medium)
                        withAnimation(Theme.snap) { selectedPlanID = plan.id }
                    }
                }
            }
        }
    }

    private var callToAction: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.impact(.medium)
                Task { await purchase() }
            } label: {
                HStack(spacing: 8) {
                    if subscriptions.purchaseInFlight {
                        ProgressView()
                            .tint(Theme.ink)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(ctaLabel)
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                    )
                }
                .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(subscriptions.purchaseInFlight)

            if let message = subscriptions.statusMessage {
                Text(message)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Remote Config A/B headline copy (`paywall_variant`).
    private var heroCopy: String {
        switch RemoteConfigManager.shared.paywallVariant {
        case .trialFocused:
            "Start your free trial and try everything on this device — unlimited redaction, the multi-profile signature kit, and zero-knowledge cloud sync. Cancel anytime."
        case .lifetimeHighlight:
            "Best value on paperwork. Unlimited redaction, signature kits with cryptographic audit trails, and zero-knowledge cloud sync — start free and cancel anytime."
        case .featureComparison:
            "Your paperwork never leaves this device. Pro unlocks unlimited redaction, e-signatures with SHA-256 audit trail, encrypted cross-device backup, and premium OCR quality."
        }
    }

    private var annualDiscountBadge: some View {
        Label(
            "Save \(RemoteConfigManager.shared.annualDiscountPercentage)% on annual",
            systemImage: "tag.fill"
        )
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color(hex: "1A1206"))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background { Capsule().fill(Theme.amberBright) }
        .shadow(color: Theme.amber.opacity(0.3), radius: 8, y: 3)
    }

    private var ctaLabel: String {
        if subscriptions.hasPro { return "Pro Active — Enjoy" }
        if let trial = selectedPlan.trialDays, trial > 0 {
            return "Start \(trial)-Day Free Trial"
        }
        return "Unlock \(selectedPlan.title)"
    }

    private var proofRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.amber)
                }
                Text("4.9 · 12,400+ ratings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                securityBadge("100% On-Device OCR & Flattening", symbol: "iphone.and.arrow.forward")
                securityBadge("SHA-256 Audit Trail", symbol: "number.square")
            }
        }
    }

    private func securityBadge(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color(hex: "3FB0A0"))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background { Capsule().fill(Color(hex: "3FB0A0").opacity(0.1)) }
        .overlay { Capsule().strokeBorder(Color(hex: "3FB0A0").opacity(0.35), lineWidth: 1) }
    }

    /// Prominent restore affordance — critical on new devices where the App
    /// Store doesn't auto-surfaces previous subscriptions.
    private var restoreRow: some View {
        VStack(spacing: 8) {
            Button {
                Task { await restorePurchases() }
            } label: {
                HStack(spacing: 8) {
                    if isRestoring {
                        ProgressView()
                            .tint(Theme.textPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(isRestoring ? "Restoring…" : "Restore Purchases")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background { Capsule().fill(Theme.surface) }
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(isRestoring || subscriptions.purchaseInFlight)
            .accessibilityLabel("Restore purchases from your Apple ID")

            if let message = restoreMessage {
                Text(message)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(subscriptions.hasPro ? Color(hex: "3FB0A0") : Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    /// High-contrast mandated legal links — taps open the in-app legal reader
    /// rather than cold-jumping out of the funnel.
    private var legalRow: some View {
        HStack(spacing: 18) {
            Button("Terms of Use (EULA)") {
                Haptics.selection()
                presentingLegalKind = .termsOfService
            }
            Button("Privacy Policy") {
                Haptics.selection()
                presentingLegalKind = .privacyPolicy
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .tint(Theme.textPrimary)
    }

    // MARK: - Actions

    private func restorePurchases() async {
        guard !isRestoring else { return }
        Haptics.selection()
        withAnimation(Theme.snap) { restoreMessage = nil }
        isRestoring = true
        defer { isRestoring = false }

        await subscriptions.restore()

        let message = subscriptions.statusMessage ?? "Nothing to restore."
        withAnimation(Theme.snap) { restoreMessage = message }
        if subscriptions.hasPro {
            Haptics.success()
        }
    }

    private func purchase() async {
        let wasPro = subscriptions.hasPro
        await subscriptions.purchase(selectedPlan)
        if !wasPro && subscriptions.hasPro {
            TelemetryService.track(
                .paywallConverted,
                attributes: ["variant": RemoteConfigManager.shared.paywallVariant.rawValue]
            )
        }
    }
}

// MARK: - Tier row

private struct PlanTierRow: View {
    let plan: PlanPresentation
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 2 : 1.5)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle().fill(Theme.amber).frame(width: 13, height: 13)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let badge = plan.badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(hex: "1A1206"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background { Capsule().fill(Theme.amber) }
                        }
                    }
                    Text(plan.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Text(plan.price)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Theme.amber.opacity(0.08) : Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    PaywallView()
        .environment(SubscriptionManager.previewInstance)
        .preferredColorScheme(.dark)
}
