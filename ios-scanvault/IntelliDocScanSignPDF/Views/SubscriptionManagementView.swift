//
//  SubscriptionManagementView.swift
//  IntelliDocScanSignPDF
//

import StoreKit
import SwiftUI

/// Dedicated plan-management screen reachable from Settings: shows the live
/// subscription status, lets users upgrade or switch between Annual and
/// Monthly (StoreKit swaps plans inside the same subscription group and
/// prorates automatically), hand off to Apple's subscription manager, and
/// restore purchases made on other devices.
struct SubscriptionManagementView: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlanID: String?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var restoreMessage: String?
    /// Presents Apple's system subscription-management sheet.
    @State private var showingManageSubscriptions = false

    // MARK: - Derived data

    private var sortedPlans: [PlanPresentation] {
        subscriptions.plans.isEmpty ? PlanPresentation.mockCatalog : subscriptions.plans.sorted {
            $0.cadence.sortOrder < $1.cadence.sortOrder
        }
    }

    /// Plan matching the live entitlement, when known.
    private var activePlan: PlanPresentation? {
        subscriptions.activePlanID.flatMap { id in sortedPlans.first { $0.id == id } }
    }

    /// Falls back to the best upgrade path (Annual) whenever nothing was
    /// explicitly selected, so the CTA is never ambiguous.
    private var effectivePlan: PlanPresentation {
        if let id = selectedPlanID, let match = sortedPlans.first(where: { $0.id == id }) {
            return match
        }
        return sortedPlans.first { $0.id != subscriptions.activePlanID } ?? sortedPlans[0]
    }

    private func actionLabel(for plan: PlanPresentation) -> String {
        if plan.id == subscriptions.activePlanID { return "Your Current Plan" }
        if !subscriptions.hasPro {
            if let trial = plan.trialDays, trial > 0 { return "Start \(trial)-Day Free Trial" }
            return "Upgrade to \(plan.title)"
        }
        return "Switch to \(plan.title)"
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Theme.backdrop

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    statusBar
                    plansSection
                    actionButton
                    manageSection
                    restoreSection
                    if subscriptions.isMockMode {
                        mockNotice
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
                .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
    }

    // MARK: - Status card

    private var statusBar: some View {
        HStack(spacing: 14) {
            Image(systemName: subscriptions.hasPro ? "crown.fill" : "person.crop.circle.badge.clock")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(subscriptions.hasPro ? Color(hex: "1A1206") : Theme.textSecondary)
                .frame(width: 50, height: 50)
                .background {
                    Circle().fill(subscriptions.hasPro ? Theme.amber : Theme.surfaceHigh)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(subscriptions.hasPro ? "IntelliDoc Pro Active" : "Free Plan")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Text(statusDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(subscriptions.hasPro ? Theme.amber.opacity(0.45) : Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        if let plan = activePlan {
            let cadence = plan.cadence == .annual ? "Annual" : "Monthly"
            if let date = subscriptions.currentRenewalDate {
                return "\(cadence) · renews \(date.formatted(date: .abbreviated, time: .omitted))"
            }
            return "\(cadence) plan"
        }
        if subscriptions.hasPro {
            return "Pro unlocked on this Apple ID"
        }
        return SubscriptionManager.freeTierSummary
    }

    // MARK: - Plans

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "YOUR PLANS")
            VStack(spacing: 10) {
                ForEach(sortedPlans) { plan in
                    managementTierRow(plan)
                }
            }
        }
    }

    private func managementTierRow(_ plan: PlanPresentation) -> some View {
        let isActive = plan.id == subscriptions.activePlanID
        let isSelected = effectivePlan.id == plan.id

        return Button {
            guard !isActive else { return }
            Haptics.selection()
            withAnimation(Theme.snap) { selectedPlanID = plan.id }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 2 : 1.5)
                        .frame(width: 24, height: 24)
                    if isSelected && !isActive {
                        Circle().fill(Theme.amber).frame(width: 13, height: 13)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if isActive {
                            Text("CURRENT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color(hex: "1A1206"))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background { Capsule().fill(Color(hex: "3FB0A0")) }
                        } else if let badge = plan.badge {
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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isActive ? Theme.textTertiary : Theme.textPrimary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected && !isActive ? Theme.amber.opacity(0.08) : Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected && !isActive ? Theme.amber : Theme.hairline,
                                  lineWidth: isSelected && !isActive ? 1.5 : 1)
            }
            .opacity(isActive ? 0.85 : 1)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(isActive)
        .accessibilityLabel("\(plan.title) plan, \(plan.price)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - Actions

    private var actionButton: some View {
        VStack(spacing: 10) {
            Button {
                Task { await activate(effectivePlan) }
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().tint(Theme.ink)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(actionLabel(for: effectivePlan))
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                    )
                }
                .shadow(color: Theme.amber.opacity(0.35), radius: 16, y: 7)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(isWorking || subscriptions.purchaseInFlight || effectivePlan.id == subscriptions.activePlanID)

            if let message = statusMessage ?? subscriptions.statusMessage {
                Text(message)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }

            Text("Switching applies immediately — App Store credits any unused time from your current plan.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var manageSection: some View {
        Group {
            if subscriptions.hasPro {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "BILLING")

                    Button {
                        Haptics.selection()
                        showingManageSubscriptions = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.amber)
                                .frame(width: 36, height: 36)
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Theme.amber.opacity(0.14))
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manage in App Store")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Change billing, cancel, or view invoices")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textTertiary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressableStyle(scale: 0.99))
                    .accessibilityLabel("Manage subscription in the App Store")
                }
            }
        }
    }

    private var restoreSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await restorePurchases() }
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().tint(Theme.textPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text("Restore Purchases")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background { Capsule().fill(Theme.surface) }
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(isWorking || subscriptions.purchaseInFlight)
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

    private var mockNotice: some View {
        Label(
            "Store preview mode — actions resolve instantly against demo prices until App Store products are configured.",
            systemImage: "flask.fill"
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.leading)
    }

    // MARK: - Side effects

    private func activate(_ plan: PlanPresentation) async {
        guard plan.id != subscriptions.activePlanID, !isWorking else { return }
        Haptics.impact(.medium)
        isWorking = true
        defer { isWorking = false }
        withAnimation(Theme.snap) {
            statusMessage = nil
            restoreMessage = nil
        }

        let wasPro = subscriptions.hasPro
        await subscriptions.purchase(plan)
        withAnimation(Theme.snap) { statusMessage = subscriptions.statusMessage }

        if subscriptions.hasPro && !wasPro {
            Haptics.success()
            TelemetryService.track(
                .paywallConverted,
                attributes: ["variant": RemoteConfigManager.shared.paywallVariant.rawValue]
            )
        }
    }

    private func restorePurchases() async {
        guard !isWorking else { return }
        Haptics.selection()
        isWorking = true
        defer { isWorking = false }
        withAnimation(Theme.snap) {
            statusMessage = nil
            restoreMessage = nil
        }

        await subscriptions.restore()
        withAnimation(Theme.snap) {
            restoreMessage = subscriptions.statusMessage ?? "Nothing to restore."
        }
        if subscriptions.hasPro { Haptics.success() }
    }
}

#Preview("Free tier") {
    NavigationStack {
        SubscriptionManagementView()
    }
    .environment(SubscriptionManager.previewInstance)
    .preferredColorScheme(.dark)
}
