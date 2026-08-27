//
//  TelemetryService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import OSLog

/// Product analytics events — deliberately coarse-grained and free of any
/// document content or personal identifiers.
nonisolated enum TelemetryEvent: String, CaseIterable, Sendable {
    case scanCompleted = "scan_completed"
    case redactionApplied = "redaction_applied"
    case signatureStamped = "signature_stamped"
    case legalPolicyViewed = "legal_policy_viewed"
    case paywallConverted = "paywall_converted"
    case syncQueuedOffline = "sync_queued_offline"
    case dataExported = "data_exported"
    case accountDeleted = "account_deleted"
}

/// Non-PII product telemetry.
///
/// Hard privacy guardrails baked into this sink:
/// - Event names and counters only. Callers pass whitelisted string attributes
///   (e.g. A/B variant names, UI ids) — never OCR text, titles, paths,
///   transcript content or user identifiers.
/// - Counters live solely in UserDefaults (declared reason: app functionality),
///   aggregated with no per-session correlation beyond monotonic counts.
/// - Nothing here ever serializes a `ScannedDocument`.
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "telemetry")
    private let countersKey = "scanvault.telemetry.counters"

    private init() {}

    /// Records `event` from anywhere in the app (hops to the main actor).
    nonisolated static func track(
        _ event: TelemetryEvent,
        attributes: [String: String] = [:]
    ) {
        Task { @MainActor in
            TelemetryService.shared.record(event, attributes: attributes)
        }
    }

    private func record(_ event: TelemetryEvent, attributes: [String: String]) {
        logger.log("\(event.rawValue, privacy: .public)")

        var counters = Self.loadCounters(key: countersKey)
        counters[event.rawValue, default: 0] += 1
        UserDefaults.standard.set(counters, forKey: countersKey)

        // Attribute values are developer-controlled constants (variant names,
        // surface ids). Reject anything oversized as a defense against misuse.
        for (key, value) in attributes.prefix(3) {
            logger.log("  ↳ \(key, privacy: .public)=\(String(value.prefix(24)), privacy: .public)")
        }
    }

    /// Current lifetime counts, exposed for a future debug screen.
    func counts() -> [String: Int] {
        Self.loadCounters(key: countersKey)
    }

    private nonisolated static func loadCounters(key: String) -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// Clears counters — part of the account-deletion sweep.
    func purgeCounters() {
        UserDefaults.standard.removeObject(forKey: countersKey)
    }
}
