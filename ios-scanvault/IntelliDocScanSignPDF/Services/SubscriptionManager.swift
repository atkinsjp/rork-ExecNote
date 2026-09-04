//
//  SubscriptionManager.swift
//  IntelliDocScanSignPDF
//

import Foundation
import Observation
import RevenueCat

// MARK: - Feature gates

/// Capabilities unlocked by IntelliDoc Pro.
nonisolated enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case unlimitedScans
    case unlimitedRedactions
    case signatureKitAndAudit
    case unlimitedRewrites
    case cloudSync

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unlimitedScans: "Unlimited Scans & Imports"
        case .unlimitedRedactions: "Unlimited PII Auto-Redactions"
        case .signatureKitAndAudit: "Multi-Profile Signature Kit & Audit Trail"
        case .unlimitedRewrites: "Unlimited AI Rewrites & Polish"
        case .cloudSync: "Cloud Sync to Firebase"
        }
    }

    var symbolName: String {
        switch self {
        case .unlimitedScans: "doc.viewfinder.fill"
        case .unlimitedRedactions: "eye.slash.fill"
        case .signatureKitAndAudit: "signature"
        case .unlimitedRewrites: "wand.and.stars"
        case .cloudSync: "icloud.fill"
        }
    }
}

// MARK: - Free usage ledger

/// Cumulative free-tier usage counters, persisted in UserDefaults (declared
/// reason: app functionality). Counting is lifetime-per-device by design so
/// the free quota can't be refreshed by relaunching.
nonisolated enum FreeUsageLedger {
    static let scansUsedKey = "freeUsage.scansUsed"
    static let rewritesUsedKey = "freeUsage.rewritesUsed"

    static var scansUsed: Int {
        UserDefaults.standard.integer(forKey: scansUsedKey)
    }

    static var rewritesUsed: Int {
        UserDefaults.standard.integer(forKey: rewritesUsedKey)
    }

    static func recordScan() {
        UserDefaults.standard.set(scansUsed + 1, forKey: scansUsedKey)
    }

    static func recordRewrite() {
        UserDefaults.standard.set(rewritesUsed + 1, forKey: rewritesUsedKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: scansUsedKey)
        UserDefaults.standard.removeObject(forKey: rewritesUsedKey)
    }
}

// MARK: - Plan presentation

/// Display metadata for a pricing tier. Fully populated in mock mode so
/// SwiftUI previews render without network or RevenueCat dependencies.
nonisolated struct PlanPresentation: Identifiable, Hashable, Sendable {
    enum Cadence: String, Sendable { case annual, monthly }

    let id: String
    let cadence: Cadence
    let title: String
    let price: String
    let subtitle: String
    var badge: String?
    var trialDays: Int?

    static let mockCatalog: [PlanPresentation] = [
        PlanPresentation(
            id: "app.rork.scanvault.pro.annual",
            cadence: .annual,
            title: "Annual",
            price: "$49.99",
            subtitle: "$4.17 / month",
            badge: "Best Value · Save 58%",
            trialDays: 3
        ),
        PlanPresentation(
            id: "app.rork.scanvault.pro.monthly",
            cadence: .monthly,
            title: "Monthly",
            price: "$9.99",
            subtitle: "billed monthly",
            badge: nil,
            trialDays: nil
        ),
    ]
}

// MARK: - Manager

/// RevenueCat-backed storefront: loads the current offering, runs purchases
/// and restore, keeps a live `customerInfoStream` listener, and exposes Pro
/// feature gating.
///
/// When RevenueCat is unavailable (fresh simulator, previews, no configured
/// offering), the manager degrades to the mock catalog so the whole flow
/// remains explorable without network dependencies.
@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    /// RevenueCat entitlement unlocked by both IntelliDoc plans.
    static let entitlementID = "intellidoc_pro"

    /// True when no real offering is available; purchases resolve
    /// instantly against the mock catalog.
    private(set) var isMockMode = false

    private(set) var plans: [PlanPresentation] = []
    /// Live RevenueCat packages keyed by their App Store product identifier.
    private var packagesByProductID: [String: Package] = [:]
    private(set) var hasPro = false
    /// Product identifier of the active entitlement, if any.
    private(set) var activePlanID: String?
    /// Renewal/expiration date reported by RevenueCat for the active plan.
    private(set) var currentRenewalDate: Date?
    private(set) var isLoadingProducts = true
    private(set) var purchaseInFlight = false
    var statusMessage: String?

    /// Free-tier limits enforced by the feature gates.
    nonisolated static let freeScanLimit = 5
    nonisolated static let freeRedactionLimit = 5
    nonisolated static let freeSignatureProfileLimit = 5
    nonisolated static let freeRewriteLimit = 5

    /// Canonical one-line free-tier description. Counters are lifetime totals
    /// per device — never monthly — so the copy pins that explicitly.
    nonisolated static let freeTierSummary = "\(freeScanLimit) scans · \(freeRedactionLimit) redactions · \(freeSignatureProfileLimit) signatures · \(freeRewriteLimit) rewrites — total, not monthly"

    init(previewOnly: Bool = false) {
        if previewOnly {
            // Previews: mock catalog, no RevenueCat, no network, instant state.
            isMockMode = true
            plans = PlanPresentation.mockCatalog
            isLoadingProducts = false
        } else {
            Task { [weak self] in
                await self?.listenForCustomerInfo()
            }
            Task { [weak self] in
                await self?.refreshEntitlements()
                await self?.loadProducts()
            }
        }
    }

    /// Offline instance for SwiftUI previews — mock catalog, no SDK calls.
    static let previewInstance = SubscriptionManager(previewOnly: true)

    // MARK: - ProAccessManager

    func hasAccess(to feature: ProFeature) -> Bool {
        hasPro
    }

    /// Free-tier redaction allowance remaining before the paywall is required.
    var redactionAllowance: Int? {
        hasPro ? nil : Self.freeRedactionLimit
    }

    /// Free-tier signature kit size before the paywall is required.
    var signatureProfileAllowance: Int? {
        hasPro ? nil : Self.freeSignatureProfileLimit
    }

    /// Free scans remaining (`nil` = unlimited under Pro). Cumulative count of
    /// documents filed through the scan flow.
    var scanAllowance: Int? {
        hasPro ? nil : max(0, Self.freeScanLimit - FreeUsageLedger.scansUsed)
    }

    /// Free AI rewrites remaining (`nil` = unlimited under Pro).
    var rewriteAllowance: Int? {
        hasPro ? nil : max(0, Self.freeRewriteLimit - FreeUsageLedger.rewritesUsed)
    }

    /// Records one filed scan against the free quota.
    func recordScanUsed() {
        FreeUsageLedger.recordScan()
    }

    /// Records one successful AI rewrite against the free quota.
    func recordRewriteUsed() {
        FreeUsageLedger.recordRewrite()
    }

    // MARK: - Storefront

    /// Loads the current RevenueCat offering and maps its packages into
    /// plan presentations. Falls back to the mock catalog when the offering
    /// is missing (no products configured, offline, or unconfigured SDK).
    func loadProducts() async {
        defer { isLoadingProducts = false }

        do {
            let offerings = try await Purchases.shared.offerings()
            guard let current = offerings.current, !current.availablePackages.isEmpty else {
                enterMockMode()
                return
            }

            var newPlans: [PlanPresentation] = []
            var packages: [String: Package] = [:]

            for package in current.availablePackages {
                let product = package.storeProduct
                let cadence: PlanPresentation.Cadence = package.packageType == .annual ? .annual : .monthly
                let presentation = PlanPresentation.mockCatalog.first { $0.cadence == cadence }

                var plan = PlanPresentation(
                    id: product.productIdentifier,
                    cadence: cadence,
                    title: presentation?.title ?? product.localizedTitle,
                    price: product.localizedPriceString,
                    subtitle: presentation?.subtitle ?? "",
                    badge: presentation?.badge,
                    trialDays: nil
                )

                // Surface the 3-day free trial configured in App Store Connect.
                if let intro = product.introductoryDiscount, intro.price == 0 {
                    plan.trialDays = 3
                    plan.badge = presentation?.badge
                } else if cadence == .annual {
                    plan.trialDays = nil
                }

                packages[product.productIdentifier] = package
                newPlans.append(plan)
            }

            guard !newPlans.isEmpty else {
                enterMockMode()
                return
            }

            plans = newPlans.sorted { $0.cadence.sortOrder < $1.cadence.sortOrder }
            packagesByProductID = packages
            isMockMode = false

            // Re-map the active plan against the now-known catalog.
            if let entitlement = try? await Purchases.shared.customerInfo(),
               let active = entitlement.entitlements[Self.entitlementID], active.isActive {
                activePlanID = active.productIdentifier
                currentRenewalDate = active.expirationDate
            }
        } catch {
            enterMockMode()
        }
    }

    private func enterMockMode() {
        isMockMode = true
        plans = PlanPresentation.mockCatalog
        packagesByProductID = [:]
    }

    // MARK: - Purchasing

    /// Purchases the package behind the given plan. When running in mock
    /// mode (no live offering), the unlock resolves instantly.
    func purchase(_ plan: PlanPresentation) async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        statusMessage = nil
        defer { purchaseInFlight = false }

        // Mock path: instant unlock, no network.
        guard let package = packagesByProductID[plan.id] else {
            try? await Task.sleep(for: .milliseconds(450))
            hasPro = true
            activePlanID = nil
            currentRenewalDate = nil
            return
        }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                statusMessage = "Purchase cancelled."
            } else {
                applyCustomerInfo(result.customerInfo)
                if hasPro {
                    statusMessage = nil
                } else {
                    statusMessage = "Purchase completed but not yet active — try restoring."
                }
            }
        } catch ErrorCode.purchaseCancelledError {
            // StoreKit cancellation — not an error.
            statusMessage = "Purchase cancelled."
        } catch ErrorCode.paymentPendingError {
            // Awaiting parental approval or extra auth — not a failure.
            statusMessage = "Purchase pending approval."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Restores prior purchases onto this device via RevenueCat's
    /// server-side receipt validation.
    func restore() async {
        do {
            let info = try await Purchases.shared.restorePurchases()
            applyCustomerInfo(info)
            statusMessage = hasPro ? "Purchases restored." : "No previous purchases found."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlements

    /// Pulls the latest customer info from RevenueCat and updates Pro state.
    func refreshEntitlements() async {
        do {
            applyCustomerInfo(try await Purchases.shared.customerInfo())
        } catch {
            // Keep the last-known state; the live stream will recover.
        }
    }

    /// Maps a `CustomerInfo` snapshot onto the observable Pro state.
    private func applyCustomerInfo(_ info: CustomerInfo) {
        if let entitlement = info.entitlements[Self.entitlementID], entitlement.isActive {
            hasPro = true
            activePlanID = entitlement.productIdentifier
            currentRenewalDate = entitlement.expirationDate
        } else {
            hasPro = false
            activePlanID = nil
            currentRenewalDate = nil
        }
    }

    /// Real-time entitlement updates (renewals, refunds, family sharing).
    private func listenForCustomerInfo() async {
        for await info in Purchases.shared.customerInfoStream {
            applyCustomerInfo(info)
        }
    }
}

nonisolated extension PlanPresentation.Cadence {
    var sortOrder: Int {
        switch self {
        case .annual: 0
        case .monthly: 1
        }
    }
}
