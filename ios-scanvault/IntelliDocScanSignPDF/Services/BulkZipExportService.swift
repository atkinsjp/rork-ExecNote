//
//  BulkZipExportService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import ZIPFoundation

// MARK: - Bulk ZIP export

/// Builds a single ZIP archive from a multi-selection of scanned documents,
/// entirely on device. Entry names use each document's title (deduplicated),
/// so archives read naturally in Files, Mail and third-party unzip tools.
nonisolated enum BulkZipExportService {
    enum ZipExportError: LocalizedError {
        /// None of the selected documents had a readable PDF on this device.
        case noDocumentsOnDevice

        var errorDescription: String? {
            switch self {
            case .noDocumentsOnDevice:
                "The selected scans aren't stored on this device. Sync them from your cloud vault and try again."
            }
        }
    }

    /// Resolves each document's on-device PDF, stages the files under clean
    /// display names, and compresses them into one `.zip` in the temporary
    /// directory. Returns the archive URL ready for the share sheet.
    static func buildZip(for documents: [ScannedDocument]) async throws -> URL {
        let fileManager = FileManager.default
        var entries: [(name: String, source: URL)] = []
        var usedNames = Set<String>()

        for document in documents {
            var source = document.localURL
            if source == nil {
                source = await PDFManager.shared.existingURL(documentId: document.id)
            }
            guard let source, fileManager.fileExists(atPath: source.path) else { continue }
            entries.append((name: uniqueFileName(for: document.title, used: &usedNames), source: source))
        }

        guard !entries.isEmpty else { throw ZipExportError.noDocumentsOnDevice }

        // Stage copies under their display names so the archive contains the
        // user's titles instead of opaque UUID file names.
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("IntelliDoc-Zip-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for entry in entries {
            let destination = staging.appendingPathComponent(entry.name)
            try? fileManager.copyItem(at: entry.source, to: destination)
        }

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent(archiveFileName())
        try? fileManager.removeItem(at: archiveURL)
        try fileManager.zipItem(
            at: staging,
            to: archiveURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        return archiveURL
    }

    /// `IntelliDoc Export 2026-08-30 at 14.05.zip`
    private static func archiveFileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        return "IntelliDoc Export \(formatter.string(from: date)).zip"
    }

    /// Sanitizes a document title into a safe `.pdf` entry name, deduplicating
    /// against names already claimed: "Invoice.pdf", "Invoice (2).pdf", …
    private static func uniqueFileName(for title: String, used: inout Set<String>) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let base = cleaned.isEmpty ? "Scan" : String(cleaned.prefix(60))

        var candidate = "\(base).pdf"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) (\(counter)).pdf"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
