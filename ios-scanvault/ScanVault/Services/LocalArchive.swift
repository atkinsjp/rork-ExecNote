//
//  LocalArchive.swift
//  ScanVault
//

import Foundation
import OSLog

/// Offline-first mirror of the vault. Everything the user scans is written here
/// first so the app is fully usable without a network connection; Firebase sync
/// runs afterwards in the background.
actor LocalArchive {
    static let shared = LocalArchive()

    nonisolated struct Payload: Codable, Sendable {
        var folders: [AppFolder]
        var documents: [ScannedDocument]
    }

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "archive")
    private let fileName = "vault-index.json"

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: fileName)
    }

    func load() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Payload.self, from: data)
        } catch {
            logger.error("Vault index could not be decoded; starting fresh.")
            return nil
        }
    }

    func save(_ payload: Payload) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Vault index could not be written.")
        }
    }
}

/// Stable anonymous identifier used as `{userId}` in Firebase paths until real
/// account sign-in is added.
nonisolated enum VaultIdentity {
    /// Storage key published so the compliance wipe can erase the identity.
    static let storageKey = "scanvault.userId"

    static var userId: String {
        if let existing = UserDefaults.standard.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: storageKey)
        return generated
    }
}
