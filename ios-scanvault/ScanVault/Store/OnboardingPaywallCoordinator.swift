//
//  OnboardingPaywallCoordinator.swift
//  ScanVault
//

import Foundation
import Observation
import SwiftUI

// MARK: - Persona

/// The user's stated goal; drives their default folder set.
nonisolated enum OnboardingPersona: String, CaseIterable, Codable, Sendable, Identifiable {
    case personalTax
    case smallBusiness
    case fieldWork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalTax: "Personal & Tax"
        case .smallBusiness: "Small Business / Freelance"
        case .fieldWork: "Field Work / Real Estate"
        }
    }

    var subtitle: String {
        switch self {
        case .personalTax: "W-2s, medical records, IDs and receipts in one vault."
        case .smallBusiness: "Invoices, contracts and expense receipts, ready for tax season."
        case .fieldWork: "Permits, lease docs and site receipts filed from the truck."
        }
    }

    var symbolName: String {
        switch self {
        case .personalTax: "house.fill"
        case .smallBusiness: "briefcase.fill"
        case .fieldWork: "wrench.and.screwdriver.fill"
        }
    }

    /// Starter folders seeded for this persona (Inbox is always added).
    var folderTemplates: [AppFolder] {
        switch self {
        case .personalTax:
            return [
                AppFolder(name: "Tax & Finance", iconName: "banknote.fill", colorHex: "4A90D9"),
                AppFolder(name: "Medical & Health", iconName: "stethoscope", colorHex: "3FB0A0", isBiometricLocked: true),
                AppFolder(name: "Receipts & Expenses", iconName: "receipt.fill", colorHex: "B4C74A"),
                AppFolder(name: "Personal IDs", iconName: "person.text.rectangle.fill", colorHex: "E2664F"),
            ]
        case .smallBusiness:
            return [
                AppFolder(name: "Legal & Contracts", iconName: "scale.3d", colorHex: "8A7CE0"),
                AppFolder(name: "Receipts & Expenses", iconName: "receipt.fill", colorHex: "B4C74A"),
                AppFolder(name: "Tax & Finance", iconName: "banknote.fill", colorHex: "4A90D9"),
                AppFolder(name: "Clients & Invoices", iconName: "paperplane.fill", colorHex: "D9598A"),
            ]
        case .fieldWork:
            return [
                AppFolder(name: "Legal & Contracts", iconName: "scale.3d", colorHex: "8A7CE0"),
                AppFolder(name: "Receipts & Expenses", iconName: "receipt.fill", colorHex: "B4C74A"),
                AppFolder(name: "Properties & Sites", iconName: "building.2.fill", colorHex: "4A90D9"),
                AppFolder(name: "Personal IDs", iconName: "person.text.rectangle.fill", colorHex: "E2664F"),
            ]
        }
    }
}

// MARK: - Coordinator

/// Drives the 4-step hook → demo → persona → paywall conversion flow.
@MainActor
@Observable
final class OnboardingPaywallCoordinator {
    enum Step: Int, CaseIterable {
        case hook
        case demo
        case persona
        case paywall
    }

    private(set) var step: Step = .hook
    private(set) var persona: OnboardingPersona?
    private(set) var isPurchasing = false

    /// Set once the flow completes (purchased or skipped).
    var isFinished = false

    static let hasCompletedKey = "hasCompletedOnboarding"

    static var hasCompletedBefore: Bool {
        UserDefaults.standard.bool(forKey: hasCompletedKey)
    }

    func advance() {
        withAnimation(Theme.flight) {
            if let next = Step(rawValue: step.rawValue + 1) {
                step = next
            }
        }
    }

    func select(_ persona: OnboardingPersona) {
        self.persona = persona
    }

    /// Finishes with a purchase (Pro unlocked).
    func completeWithPurchase() {
        markComplete()
    }

    /// Finishes without purchasing — access stays on the free tier.
    func skip() {
        markComplete()
    }

    private func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedKey)
        withAnimation(Theme.flight) { isFinished = true }
    }
}
