//
//  RemoteConfigManager.swift
//  ScanVault
//

import Foundation
import OSLog

/// Fetches and caches remote dynamic configuration so the paywall, legal
/// links and AI prompts iterate without binary re-submission.
///
/// Transport is the same REST-based Firestore used by `FirebaseSyncService`
/// (no SDK needed): configuration lives in a single document
/// `config/appConfig` and is read with one GET. Values are persisted to disk
/// so the last known-good variant survives cold starts without network.
///
/// Supported keys (Firestore types in parentheses):
/// - `paywall_variant`              — string: "trial_focused" | "lifetime_highlight" | "feature_comparison"
/// - `annual_discount_percentage`   — integer, e.g. 60
/// - `free_tier_scan_limit`         — integer, e.g. 5
/// - `privacy_policy_url`, `terms_url` — string URLs
/// - `gemini_system_prompt_version` — integer
@MainActor
@Observable
final class RemoteConfigManager {
    static let shared = RemoteConfigManager()

    // MARK: - Public config values

    nonisolated enum PaywallVariant: String, CaseIterable, Sendable {
        case trialFocused = "trial_focused"
        case lifetimeHighlight = "lifetime_highlight"
        case featureComparison = "feature_comparison"

        var label: String { rawValue }
    }

    private(set) var paywallVariant: PaywallVariant = .trialFocused
    private(set) var annualDiscountPercentage: Int = 60
    private(set) var freeTierScanLimit: Int = 5
    private(set) var geminiSystemPromptVersion: Int = 1
    /// Non-nil only when Remote Config supplied an override; falls through to
    /// bundled legal URLs otherwise.
    private(set) var privacyPolicyURL: URL?
    private(set) var termsOfServiceURL: URL?
    private(set) var lastFetchedAt: Date?
    private(set) var isRefreshing = false

    // MARK: - Plumbing

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "remote-config")
    private let cacheURL: URL

    nonisolated struct CachedConfig: Codable, Sendable {
        var paywallVariant: String?
        var annualDiscountPercentage: Int?
        var freeTierScanLimit: Int?
        var geminiSystemPromptVersion: Int?
        var privacyPolicyURL: String?
        var termsOfServiceURL: String?
        var fetchedAt: Date
    }

    init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheURL = base.appending(path: "remote-config.json")
        loadCached()
    }

    // MARK: - Refresh

    /// Fetches `config/appConfig` once. Silent no-op on failure — callers keep
    /// whatever they had before.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let config = FirebaseConfiguration.fromEnvironment() else {
            logger.log("Firebase not configured; keeping cached/defaults.")
            return
        }

        let urlString = "https://firestore.googleapis.com/v1/projects/\(config.projectId)/databases/(default)/documents/config/appConfig?key=\(config.apiKey)"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FirebaseSyncError.badResponse(http.statusCode, "")
            }
            guard let fields = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["fields"] as? [String: Any] else {
                return
            }
            apply(fields: fields)
        } catch {
            logger.error("Remote Config fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(fields: [String: Any]) {
        paywallVariant = PaywallVariant(
            rawValue: Self.string(fields["paywall_variant"]) ?? ""
        ) ?? paywallVariant
        annualDiscountPercentage = Self.integer(Self.integerField(fields["annual_discount_percentage"]), fallback: annualDiscountPercentage)
        freeTierScanLimit = Self.integer(Self.integerField(fields["free_tier_scan_limit"]), fallback: freeTierScanLimit)
        geminiSystemPromptVersion = Self.integer(Self.integerField(fields["gemini_system_prompt_version"]), fallback: geminiSystemPromptVersion)

        if let raw = Self.string(fields["privacy_policy_url"]), let url = URL(string: raw) {
            privacyPolicyURL = url
        }
        if let raw = Self.string(fields["terms_url"]), let url = URL(string: raw) {
            termsOfServiceURL = url
        }
        lastFetchedAt = .now

        persistCache()
    }

    // MARK: - Cache

    private func loadCached() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedConfig.self, from: data)
        else { return }

        if let raw = cached.paywallVariant, let variant = PaywallVariant(rawValue: raw) {
            paywallVariant = variant
        }
        if let value = cached.annualDiscountPercentage { annualDiscountPercentage = value }
        if let value = cached.freeTierScanLimit { freeTierScanLimit = value }
        if let value = cached.geminiSystemPromptVersion { geminiSystemPromptVersion = value }
        if let raw = cached.privacyPolicyURL { privacyPolicyURL = URL(string: raw) }
        if let raw = cached.termsOfServiceURL { termsOfServiceURL = URL(string: raw) }
        lastFetchedAt = cached.fetchedAt
    }

    private func persistCache() {
        let snapshot = CachedConfig(
            paywallVariant: paywallVariant.rawValue,
            annualDiscountPercentage: annualDiscountPercentage,
            freeTierScanLimit: freeTierScanLimit,
            geminiSystemPromptVersion: geminiSystemPromptVersion,
            privacyPolicyURL: privacyPolicyURL?.absoluteString,
            termsOfServiceURL: termsOfServiceURL?.absoluteString,
            fetchedAt: lastFetchedAt ?? .now
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: - Firestore field helpers (local to this manager's parser)

    private static func string(_ field: Any?) -> String? {
        (field as? [String: Any])?["stringValue"] as? String
    }

    private static func integerField(_ field: Any?) -> Int? {
        guard let wrapper = field as? [String: Any], let raw = wrapper["integerValue"] else { return nil }
        if let text = raw as? String { return Int(text) }
        return raw as? Int
    }

    private static func integer(_ newValue: Int?, fallback current: Int) -> Int {
        guard let newValue else { return current }
        return max(0, min(100, newValue))
    }
}
