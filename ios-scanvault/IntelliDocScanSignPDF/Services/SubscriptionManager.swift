//
//  SubscriptionManager.swift
//  IntelliDocScanSignPDF
//

import Foundation
import Observation
import StoreKit

// MARK: - Feature gates

/// Capabilities unlocked by IntelliDoc Pro.
nonisolated enum ProFeature: String, CaseIterable, Sendable, Identifiable {
    case unlimitedRedactions
    case signatureKitAndAudit
    case cloudSync

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unlimitedRedactions: "Unlimited PII Auto-Redactions"
        case .signatureKitAndAudit: "Multi-Profile Signature Kit & Audit Trail"
        case .cloudSync: "Cloud Sync to Firebase"
        }
    }

    var symbolName: String {
        switch self {
        case .unlimitedRedactions: "eye.slash.fill"
        case .signatureKitAndAudit: "signature"
        case .cloudSync: "icloud.fill"
        }
    }
}

// MARK: - Plan presentation

/// Display metadata for a pricing tier. Fully populated in mock mode so
/// SwiftUI previews render without network or App Store Connect.
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

/// StoreKit 2 storefront: loads products, runs purchases and restore, keeps a
/// live `Transaction.updates` listener, and exposes Pro feature gating.
///
/// When StoreKit returns no products (fresh simulator, previews, no App Store
/// Connect config), the manager degrades to the mock catalog so the whole flow
/// remains explorable without network dependencies.
@MainActor
@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    static let productIDs = [
        "app.rork.scanvault.pro.annual",
        "app.rork.scanvault.pro.monthly",
    ]

    /// True when no real StoreKit products are available; purchases resolve
    /// instantly against the mock catalog.
    private(set) var isMockMode = false

    private(set) var plans: [PlanPresentation] = []
    private(set) var storeProducts: [String: Product] = [:]
    private(set) var hasPro = false
    /// Product ID of the active entitlement among known product IDs, if any.
    private(set) var activePlanID: String?
    /// Renewal/expiration date reported by StoreKit for the active plan.
    private(set) var currentRenewalDate: Date?
    private(set) var isLoadingProducts = true
    private(set) var purchaseInFlight = false
    var statusMessage: String?

    /// Free-tier limits enforced by the feature gates.
    nonisolated static let freeRedactionLimit = 5
    nonisolated static let freeSignatureProfileLimit = 1

    // `nonisolated(unsafe)` so `deinit` (always nonisolated) can cancel it.
    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    init(previewOnly: Bool = false) {
        if previewOnly {
            // Previews: mock catalog, no StoreKit, no network, instant state.
            isMockMode = true
            plans = PlanPresentation.mockCatalog
            isLoadingProducts = false
        } else {
            updatesTask = Task { [weak self] in
                await self?.listenForTransactions()
            }
            Task { [weak self] in
                await self?.refreshEntitlements()
                await self?.loadProducts()
            }
        }
    }

    /// Offline instance for SwiftUI previews — mock catalog, no StoreKit calls.
    static let previewInstance = SubscriptionManager(previewOnly: true)

    deinit {
        updatesTask?.cancel()
    }

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

    // MARK: - Storefront

    func loadProducts() async {
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: Self.productIDs)
            guard !products.isEmpty else {
                enterMockMode()
                return
            }

            storeProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            plans = products
                .compactMap { product in
                    let presentation = PlanPresentation.mockCatalog.first { $0.id == product.id }
                    return PlanPresentation(
                        id: product.id,
                        cadence: presentation?.cadence ?? .monthly,
                        title: product.displayName,
                        price: product.displayPrice,
                        subtitle: presentation?.subtitle ?? "",
                        badge: presentation?.badge,
                        trialDays: presentation?.trialDays
                    )
                }
                .sorted { $0.cadence.sortOrder < $1.cadence.sortOrder }
            isMockMode = false
        } catch {
            enterMockMode()
        }
    }

    private func enterMockMode() {
        isMockMode = true
        plans = PlanPresentation.mockCatalog
        storeProducts = [:]
    }

    // MARK: - Purchasing

    func purchase(_ plan: PlanPresentation) async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        statusMessage = nil
        defer { purchaseInFlight = false }

        // Mock path: instant unlock, no network.
        guard let product = storeProducts[plan.id] else {
            try? await Task.sleep(for: .milliseconds(450))
            await refreshEntitlements(mockUnlock: true)
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
            case .userCancelled:
                statusMessage = "Purchase cancelled."
            case .pending:
                statusMessage = "Purchase pending approval."
            @unknown default:
                statusMessage = "Unknown purchase result."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = hasPro ? "Purchases restored." : "No previous purchases found."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Entitlements

    /// Walks the StoreKit 2 current-entitlements stream, unlocks Pro if any
    /// active, unrevoked subscription or non-consumable is found, and records
    /// which known plan is live plus its renewal date for the management UI.
    func refreshEntitlements(mockUnlock: Bool = false) async {
        if mockUnlock {
            hasPro = true
            activePlanID = nil
            currentRenewalDate = nil
            return
        }

        var unlocked = false
        var activeID: String?
        var renewal: Date?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }
            // No expiration (non-consumables) counts as active; expiring
            // entitlements are active only until their renewal date.
            let expiration = transaction.expirationDate
            let isActive = expiration.map { $0 > Date.now } ?? true
            guard isActive else { continue }
            unlocked = true
            if Self.productIDs.contains(transaction.productID) {
                activeID = transaction.productID
                renewal = expiration
            }
        }
        hasPro = unlocked
        activePlanID = activeID
        currentRenewalDate = renewal
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard let transaction = try? checkVerified(result) else { continue }
            await transaction.finish()
            await refreshEntitlements()
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreKitError.notEntitled
        case .verified(let safe):
            return safe
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
