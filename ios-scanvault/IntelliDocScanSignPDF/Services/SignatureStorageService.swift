//
//  SignatureStorageService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import OSLog

nonisolated enum SignatureStorageError: LocalizedError {
    case loadFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed: "Your saved signatures could not be read from this device."
        case .saveFailed(let reason): "The signature could not be saved: \(reason)"
        }
    }
}

/// Persists the user's signature kit inside the encrypted app sandbox so it
/// survives across sessions and never leaves the device.
///
/// Each profile's PNG is written with complete file protection, meaning the
/// bitmap is unreadable while the device is locked. A single index manifest
/// keeps load/save operations to one atomic read.
actor SignatureStorageService {
    static let shared = SignatureStorageService()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "signatures")
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "SignatureKit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        indexURL = directory.appending(path: "profiles.json")
    }

    // MARK: - CRUD

    /// Loads every saved profile, newest first.
    func loadProfiles() -> [SignatureProfile] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            let profiles = try JSONDecoder().decode([SignatureProfile].self, from: data)
            return profiles.sorted { $0.createdAt > $1.createdAt }
        } catch {
            logger.error("Signature manifest decode failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Appends (or replaces) `profile` and rewrites the manifest atomically.
    func save(_ profile: SignatureProfile) throws {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(profiles).write(to: indexURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw SignatureStorageError.saveFailed(error.localizedDescription)
        }
    }

    func delete(profileId: UUID) {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == profileId }
        try? JSONEncoder().encode(profiles).write(to: indexURL, options: [.atomic, .completeFileProtection])
    }
}
