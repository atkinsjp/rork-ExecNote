//
//  ScanVaultIntents.swift
//  ScanVault
//
//  Deep-link routing + lightweight "open the app" intents used by the widget
//  buttons. Compiled into both the main app and the widget extension.
//

import AppIntents
import Foundation
import Observation

// MARK: - Deep link routing

/// Destinations reachable from widgets, Siri and Home Screen quick actions.
nonisolated enum DeepLink: String, Sendable, Equatable {
    /// Open the VisionKit document camera directly.
    case scan
    /// Scan, then present the redaction studio on the captured document.
    case redact
    /// Open the vault dashboard.
    case vault
}

/// Routes deep links raised by widgets, quick actions and App Intents into
/// the running SwiftUI hierarchy.
@MainActor
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    /// Link awaiting consumption by the UI layer.
    var pendingLink: DeepLink?

    private init() {}

    func open(_ link: DeepLink) {
        pendingLink = link
    }

    /// Called by the view that handled the link.
    func consume() -> DeepLink? {
        defer { pendingLink = nil }
        return pendingLink
    }
}

// MARK: - Widget button intents

/// One-tap "Scan Document": opens the app straight into the camera flow.
nonisolated struct OpenScannerIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Document"
    static var description = IntentDescription("Opens ScanVault's document camera.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.open(.scan)
        return .result()
    }
}

/// "Redact PII": scans first, then opens the redaction studio.
nonisolated struct OpenRedactIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan & Redact PII"
    static var description = IntentDescription("Scans a document, then opens the on-device PII redaction studio.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.open(.redact)
        return .result()
    }
}

/// "Open Vault": jumps to the dashboard.
nonisolated struct OpenVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Vault"
    static var description = IntentDescription("Opens the ScanVault dashboard.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.open(.vault)
        return .result()
    }
}
