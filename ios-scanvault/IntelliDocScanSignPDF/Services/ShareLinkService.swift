//
//  ShareLinkService.swift
//  IntelliDocScanSignPDF
//
//  Secure expiring share links: asks the deployed `generateSecureShareLink`
//  Cloud Function to mint a capability-token URL over the already-synced PDF
//  in Firebase Storage. The backend enforces expiry, hashes the 256-bit key,
//  and optionally verifies a scrypt-hashed password before streaming bytes.
//

import Foundation
import OSLog

/// Result of a successful share-link creation.
nonisolated struct ShareLinkResult: Sendable, Equatable {
    /// Full download URL including its embedded capability token.
    let url: URL
    /// When recipients lose access.
    let expiresAt: Date
    /// Whether the link requires the sender's password to open.
    let requiresPassword: Bool
}

nonisolated enum ShareLinkError: LocalizedError {
    case notConfigured
    case notSynced
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud sharing isn't available on this install. Check your connection and try again."
        case .notSynced:
            "This scan hasn't reached your cloud vault yet. Reconnect and upload it before sharing a link."
        case .server(let detail):
            detail.isEmpty
                ? "The share service couldn't create the link. Please try again."
                : detail
        case .transport(let reason):
            "Network problem: \(reason)"
        }
    }
}

/// Thin client for the share-link callable (Firebase Functions v2 wire
/// protocol: POST `{ "data": … }`, response `{ "result": … }`).
nonisolated enum ShareLinkService {

    private static let logger = Logger(subsystem: "app.rork.scanvault", category: "share-link")

    /// Function region pinned in the backend's `setGlobalOptions`.
    private static let region = "us-central1"
    private static let functionName = "generateSecureShareLink"

    /// Creates an expiring link for an uploaded document.
    ///
    /// - Parameters:
    ///   - documentId: Firestore/storage id of the document (no extension).
    ///   - userId: vault-owner scope whose Storage prefix holds the PDF.
    ///   - storagePath: full object path, e.g. `users/<uid>/documents/<id>.pdf`.
    ///   - expiryHours: 24 or 168 (7 days); the backend clamps anything else.
    ///   - password: optional shared secret checked at download time.
    static func create(
        documentId: String,
        userId: String,
        storagePath: String,
        expiryHours: Int,
        password: String?
    ) async throws -> ShareLinkResult {
        guard let config = FirebaseConfiguration.fromEnvironment() else {
            throw ShareLinkError.notConfigured
        }

        guard let url = URL(string: "https://\(region)-\(config.projectId).cloudfunctions.net/\(functionName)") else {
            throw ShareLinkError.notConfigured
        }

        var payload: [String: Any] = [
            "documentId": documentId,
            "userId": userId,
            "expiryHours": expiryHours,
        ]
        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPassword.isEmpty {
            payload["password"] = trimmedPassword
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["data": payload])

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response: response, body: body)

            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard let result = json?["result"] as? [String: Any],
                  let urlString = result["shareUrl"] as? String,
                  let shareURL = URL(string: urlString),
                  let expiresISO = result["expiresAtISO"] as? String,
                  let expiresAt = ISO8601DateFormatter().date(from: expiresISO)
            else {
                throw ShareLinkError.server("")
            }

            let requiresPassword = (result["requiresPassword"] as? Bool) ?? false
            logger.info("Share link minted (expiry \(expiresISO, privacy: .public))")
            return ShareLinkResult(url: shareURL, expiresAt: expiresAt, requiresPassword: requiresPassword)
        } catch let error as ShareLinkError {
            throw error
        } catch {
            throw ShareLinkError.transport(error.localizedDescription)
        }
    }

    /// Maps HTTP + Functions-v2 error envelopes onto friendly messages.
    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail =
            (json?["error"] as? String)
            ?? ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: body.prefix(300), encoding: .utf8)
            ?? ""

        logger.error("Share link rejected (\(http.statusCode, privacy: .public)): \(detail.prefix(200), privacy: .public)")

        if detail.contains("has not been synced") || detail.contains("not-found") {
            throw ShareLinkError.notSynced
        }
        // Functions wrap HttpsError messages as JSON strings; peel the last
        // segment so users see "That document has not been synced yet." style text.
        let cleaned = detail
            .replacingOccurrences(of: "\\n|\\t", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"{}"))

        throw ShareLinkError.server(cleaned.isEmpty ? "" : cleaned)
    }

    // MARK: - Suggested passwords

    private static let words = [
        "atlas", "ember", "quartz", "harbor", "lumen", "pilot",
        "cinder", "marble", "vector", "juniper", "cobalt", "saffron",
    ]

    /// Memorable fallback password when the user wants protection without
    /// inventing one themselves (e.g. "ember-482-quartz").
    static func generateSuggestedPassword() -> String {
        let unique = Array(words.shuffled().prefix(2))
        let digits = String(format: "%03d", Int.random(in: 100...999))
        return "\(unique[0])-\(digits)-\(unique[1])"
    }
}
