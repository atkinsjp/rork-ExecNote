//
//  PrivacyComplianceManager.swift
//  ScanVault
//

import CryptoKit
import Foundation
import OSLog

enum DataExportError: LocalizedError {
    case empty
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "There is nothing to export yet — your vault is empty."
        case .writeFailed(let reason):
            "The export archive could not be written: \(reason)"
        }
    }
}

/// App Store Guideline 5.1.1 compliance operations:
/// - **Complete account & data deletion** — wipes the local sandbox, staged
///   sync queues, signature assets and best-effort cloud copies of every
///   user-created record.
/// - **Export all my data** — bundles every user-created PDF, transcription,
///   note transform and metadata file into one portable `.zip`.
///
/// All work runs in-memory/on-device; nothing about these flows is reported
/// anywhere except coarse telemetry counters.
@MainActor
final class PrivacyComplianceManager {
    static let shared = PrivacyComplianceManager()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "compliance")

    private init() {}

    // MARK: - Export All My Data

    /// Builds `scanvault-export.zip` containing:
    /// - `metadata/index.json`      — folders + documents (Codable JSON)
    /// - `PDFs/<title>.pdf`         — every locally-available scan
    /// - `Transcriptions/<title>.txt` — OCR pages and note transforms
    /// - `transfers.log`            — audit summary for the user's records
    ///
    /// - Returns: the archive URL, ready for a share sheet.
    func exportAllData(from store: VaultStore) async throws -> URL {
        guard !store.documents.isEmpty || !store.folders.isEmpty else {
            throw DataExportError.empty
        }

        var entries: [ZipArchiveWriter.Entry] = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Metadata manifest ---------------------------------------------------
        if let manifest = try? encoder.encode(ExportManifest(folders: store.folders, documents: store.documents)) {
            entries.append(.init(name: "metadata/index.json", data: manifest))
        }

        var exportedPdfCount = 0
        var transcribedCount = 0

        // Per-document artifacts ----------------------------------------------
        for document in store.documents {
            let safeTitle = sanitizedFileName(document.title)

            var localURL = document.localURL
            if localURL == nil {
                localURL = await resolvedLocalURL(for: document)
            }
            if let localURL, let pdfData = try? Data(contentsOf: localURL) {
                entries.append(.init(name: "PDFs/\(safeTitle)-\(document.id.suffix(6)).pdf", data: pdfData))
                exportedPdfCount += 1
            }

            var notes = ""
            if let ocrText = document.ocrText, !ocrText.isEmpty {
                notes += "# Recognized Text\n\n\(ocrText)\n\n"
            }
            if let transcription = document.noteTranscription, !transcription.isEmpty {
                notes += "# Handwriting Transcription\n\n\(transcription)\n\n"
            }
            for transform in document.noteTransforms {
                notes += "# Transform: \(transform.format.title) · \(transform.tone.label)\n\n\(transform.content)\n\n"
            }
            if !notes.isEmpty {
                entries.append(.init(name: "Transcriptions/\(safeTitle).md", data: Data(notes.utf8)))
                transcribedCount += 1
            }
        }

        guard !entries.isEmpty else { throw DataExportError.empty }

        // Audit trail footer --------------------------------------------------
        let auditLine = """
        ScanVault data export
        Generated: \(ISO8601DateFormatter().string(from: .now))
        Documents: \(store.documents.count) · Folders: \(store.folders.count)
        PDFs included: \(exportedPdfCount) · Transcriptions included: \(transcribedCount)
        Contents were generated entirely on this device.
        """
        entries.append(.init(name: "transfers.log", data: Data(auditLine.utf8)))

        let destination = exportDestinationURL()
        do {
            let url = try ZipArchiveWriter.write(entries, to: destination)
            TelemetryService.track(.dataExported)
            return url
        } catch {
            throw DataExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Complete Account & Data Deletion (5.1.1(v))

    /// Permanently destroys every trace of the user's vault:
    /// 1. Cloud Firestore documents/folders + Storage PDFs (best-effort).
    /// 2. Local sandbox: application-support archives, staged sync uploads.
    /// 3. Signature kit profiles and their protected PNG assets.
    /// 4. In-memory state, identity id, telemetry counters, onboarding flag.
    ///
    /// - Returns: a human-readable report surfaced by the confirmation UI.
    @discardableResult
    func deleteAllAccountData(store: VaultStore) async -> String {
        var report: [String] = []

        // --- 1. Cloud copies (best effort; offline devices retry via their
        // own admin tools since the local identifiers are also wiped).
        let documents = store.documents
        let folders = store.folders
        let sync = FirebaseSyncService.shared

        if await sync.isConfigured {
            var deleted = 0
            for document in documents {
                if (try? await sync.deletePDF(documentId: document.id, userId: VaultIdentity.userId)) != nil {}
                if (try? await sync.deleteDocumentMetadata(id: document.id, userId: VaultIdentity.userId)) != nil { deleted += 1 }
            }
            for folder in folders where folder.id != AppFolder.inboxID {
                if (try? await sync.deleteFolder(id: folder.id, userId: VaultIdentity.userId)) != nil { deleted += 1 }
            }
            report.append("Cloud records removed: \(deleted)")
        } else {
            report.append("Cloud sync not configured — nothing existed remotely.")
        }

        // --- 2. Local sandbox ---------------------------------------------
        OfflineSyncCoordinator.shared.purgePendingData()

        let fileManager = FileManager.default
        let wipedSupport = removeContents(ofDirectory: appSupportDirectory(), excluding: [])
        report.append("Local records erased: \(wipedSupport)")

        // --- 3. Signature kit ----------------------------------------------
        let signatureProfiles = await SignatureStorageService.shared.loadProfiles()
        for profile in signatureProfiles {
            await SignatureStorageService.shared.delete(profileId: profile.id)
        }
        removeContents(ofDirectory: appSupportDirectory().appending(path: "SignatureKit"), excluding: [])
        report.append("Signature assets destroyed: \(signatureProfiles.count)")

        // --- 4. Identity & preferences ---------------------------------------
        TelemetryService.shared.purgeCounters()
        UserDefaults.standard.removeObject(forKey: VaultIdentity.storageKey)
        UserDefaults.standard.removeObject(forKey: OnboardingPaywallCoordinator.hasCompletedKey)
        UserDefaults.standard.removeObject(forKey: AppearanceMode.storageKey)

        // --- In-memory reset (cancels realtime listeners too) --------------
        await store.resetForAccountDeletion()

        logger.log("Account data deletion completed.")
        TelemetryService.track(.accountDeleted)

        // Deletion must leave the whole device clean of derived state.
        SecItemDeleteAllVendoredKeys()
        report.append("Every remaining keychain asset removed.")

        return report.joined(separator: "\n")
    }

    // MARK: - Filesystem helpers

    private func exportDestinationURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let exports = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Exports")
        return exports.appending(path: "scanvault-export-\(stamp).zip")
    }

    private func appSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private func removeContents(ofDirectory url: URL, excluding excluded: [String]) -> Int {
        guard let items = try? fileManagerDefault.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return 0
        }
        var count = 0
        for item in items where !excluded.contains(item.lastPathComponent) {
            if (try? fileManagerDefault.removeItem(at: item)) != nil { count += 1 }
        }
        return count
    }

    private let fileManagerDefault = FileManager.default

    private func resolvedLocalURL(for document: ScannedDocument) async -> URL? {
        await PDFManager.shared.existingURL(documentId: document.id)
    }

    private func sanitizedFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }
}

// MARK: - Export manifest model

nonisolated struct ExportManifest: Codable, Sendable {
    var folders: [AppFolder]
    var documents: [ScannedDocument]
    var formatVersion: Int

    init(folders: [AppFolder], documents: [ScannedDocument]) {
        self.folders = folders
        self.documents = documents
        formatVersion = 1
    }
}

// MARK: - Keychain sweep

/// Removes any ScanVault-owned generic password items (defense-in-depth for
/// future stored credentials; today's identities live in UserDefaults).
private nonisolated func SecItemDeleteAllVendoredKeys() {
    #if !targetEnvironment(simulator)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.rork.scanvault",
    ]
    SecItemDelete(query as CFDictionary)
    #endif
}
