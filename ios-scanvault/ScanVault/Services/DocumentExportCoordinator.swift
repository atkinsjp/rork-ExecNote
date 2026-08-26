//
//  DocumentExportCoordinator.swift
//  ScanVault
//

import Foundation
import UIKit

nonisolated enum ExportError: LocalizedError {
    case noSource
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSource: "The PDF for this document is not on this device."
        case .buildFailed(let reason): "The export could not be prepared: \(reason)"
        }
    }
}

/// Formats available from the export sheet.
nonisolated enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// Flattened PDF (redactions & signatures permanently burned in),
    /// optionally optimized under a compression preset.
    case pdf
    /// ZIP of high-resolution JPEGs, one per page.
    case imagePack
    /// Plain-text / Markdown OCR transcription.
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "Flattened PDF"
        case .imagePack: "Image Pack"
        case .text: "Text / Markdown"
        }
    }

    var subtitle: String {
        switch self {
        case .pdf: "Sanitized & signed — nothing recoverable"
        case .imagePack: "ZIP of high-res JPEG pages"
        case .text: "Raw OCR transcription"
        }
    }

    var symbolName: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .imagePack: "photo.stack.fill"
        case .text: "text.quote"
        }
    }
}

/// Prepares shareable artifacts for a scanned document: compressed PDFs,
/// JPEG image packs (zipped) and OCR transcriptions.
@MainActor
final class DocumentExportCoordinator {
    static let shared = DocumentExportCoordinator()

    private let compression = PDFCompressionService.shared

    /// Resolves the document's on-disk PDF, preferring the local URL.
    private func sourceURL(for document: ScannedDocument) async -> URL? {
        if let local = document.localURL { return local }
        return await PDFManager.shared.existingURL(documentId: document.id)
    }

    /// Builds the export file for `document` and returns its temporary URL.
    @discardableResult
    func buildExport(
        document: ScannedDocument,
        format: ExportFormat,
        preset: CompressionPreset = .email
    ) async throws -> URL {
        let safeName = sanitizedFileName(document.title)

        switch format {
        case .pdf:
            guard let sourceURL = await sourceURL(for: document) else {
                throw ExportError.noSource
            }

            let result = try await compression.compress(
                url: sourceURL,
                preset: preset,
                documentId: document.id
            )
            // Rename to the friendly title once compression finished.
            let namedURL = FileManager.default.temporaryDirectory
                .appending(path: "\(safeName).pdf")
            try? FileManager.default.removeItem(at: namedURL)
            try? FileManager.default.copyItem(at: result.url, to: namedURL)
            return namedURL

        case .imagePack:
            guard let sourceURL = await sourceURL(for: document) else {
                throw ExportError.noSource
            }

            let pages = await PDFManager.shared.pageImages(for: sourceURL, maxWidth: 1700)
            guard !pages.isEmpty else { throw ExportError.noSource }

            var entries: [(name: String, data: Data)] = []
            for (index, page) in pages.enumerated() {
                let jpeg = page.jpegData(compressionQuality: 0.85) ?? Data()
                entries.append((name: "\(safeName)-p\(index + 1).jpg", data: jpeg))
            }

            let zipURL = FileManager.default.temporaryDirectory
                .appending(path: "\(safeName)-pages.zip")
            try ZipArchive.write(entries: entries, to: zipURL)
            return zipURL

        case .text:
            let text = try await transcription(for: document, title: document.title)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "\(safeName).md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// Markdown transcription; falls back to on-device OCR when a legacy
    /// document has no stored text.
    func transcription(for document: ScannedDocument, title: String) async throws -> String {
        var pageTexts: [String] = []

        if let stored = document.ocrText, !stored.isEmpty {
            pageTexts = stored.components(separatedBy: "\n\u{2029}")
        } else if let url = await sourceURL(for: document) {
            let pages = await PDFManager.shared.pageImages(for: url, maxWidth: 1240)
            for page in pages {
                pageTexts.append(await OCRService.shared.recognizedText(in: page))
            }
        }

        guard !pageTexts.isEmpty else { throw ExportError.noSource }

        var markdown = "# \(title)\n\n"
        markdown += "- **Exported:** \(Date.now.formatted(date: .long, time: .shortened))\n"
        markdown += "- **Pages:** \(pageTexts.count)\n"
        if document.isRedacted { markdown += "- **Redacted:** yes (\(document.redactionCount) regions)\n" }
        if document.isSigned { markdown += "- **Signed:** yes (\(document.signatureCount) stamps)\n" }
        if let docType = document.docType { markdown += "- **Type:** \(docType)\n" }
        markdown += "\n---\n\n"

        for (index, text) in pageTexts.enumerated() {
            markdown += "## Page \(index + 1)\n\n"
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            markdown += trimmed.isEmpty ? "_(no text detected)_" : trimmed
            markdown += "\n\n"
        }
        return markdown
    }

    private func sanitizedFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "IntelliDoc-Export" : cleaned
    }
}

// MARK: - Minimal ZIP writer

/// Stored-entry (uncompressed) ZIP writer. JPEG payloads are already
/// compressed, so stored entries cost nothing and avoid any deflate
/// dependencies.
nonisolated enum ZipArchive {
    /// CRC-32 (IEEE 802.3) lookup table, built once.
    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func write(entries: [(name: String, data: Data)], to url: URL) throws {
        var body = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(of: entry.data)
            let offset = UInt32(body.count)

            // Local file header.
            body.appendLE(UInt32(0x04034b50))
            body.appendLE(UInt16(20))            // version needed
            body.appendLE(UInt16(0))             // flags
            body.appendLE(UInt16(0))             // stored
            body.appendLE(UInt16(0))             // time
            body.appendLE(UInt16(0x4B21))        // date (Jan 1 2026-ish)
            body.appendLE(crc)
            body.appendLE(UInt32(entry.data.count))
            body.appendLE(UInt32(entry.data.count))
            body.appendLE(UInt16(nameBytes.count))
            body.appendLE(UInt16(0))             // extra length
            body.append(contentsOf: nameBytes)
            body.append(entry.data)

            // Central directory record.
            centralDirectory.appendLE(UInt32(0x02014b50))
            centralDirectory.appendLE(UInt16(20))       // version made by
            centralDirectory.appendLE(UInt16(20))       // version needed
            centralDirectory.appendLE(UInt16(0))        // flags
            centralDirectory.appendLE(UInt16(0))        // stored
            centralDirectory.appendLE(UInt16(0))        // time
            centralDirectory.appendLE(UInt16(0x4B21))   // date
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt32(entry.data.count))
            centralDirectory.appendLE(UInt16(nameBytes.count))
            centralDirectory.appendLE(UInt16(0))        // extra
            centralDirectory.appendLE(UInt16(0))        // comment
            centralDirectory.appendLE(UInt16(0))        // disk
            centralDirectory.appendLE(UInt16(0))        // internal attrs
            centralDirectory.appendLE(UInt32(0))        // external attrs
            centralDirectory.appendLE(offset)
            centralDirectory.append(contentsOf: nameBytes)

            entryCount &+= 1
        }

        let centralStart = UInt32(body.count)
        var archive = body
        archive.append(centralDirectory)

        // End of central directory.
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))                 // disk
        archive.appendLE(UInt16(0))                 // start disk
        archive.appendLE(entryCount)
        archive.appendLE(entryCount)
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(centralStart)
        archive.appendLE(UInt16(0))                 // comment length

        try archive.write(to: url, options: .atomic)
    }

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

nonisolated extension Data {
    /// Appends a little-endian integer to the archive stream.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { bytes in
            append(contentsOf: bytes)
        }
    }
}
