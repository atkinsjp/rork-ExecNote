//
//  SpotlightIndexer.swift
//  IntelliDocScanSignPDF
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Mirrors scanned documents into iOS Spotlight so they surface directly from
/// the Home Screen search bar. Titles, keywords and OCR text are indexed —
/// all on-device.
nonisolated enum SpotlightIndexer {
    private static let domain = "app.rork.scanvault.documents"

    /// Indexes (or re-indexes) one document. Safe to call repeatedly.
    static func index(_ document: ScannedDocument) {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.pdf)
        attributes.title = document.title
        attributes.contentDescription = snippet(for: document)
        attributes.keywords = Array(document.ocrKeywords.prefix(12))
        attributes.contentCreationDate = document.createdAt
        attributes.addedDate = document.createdAt
        attributes.identifier = document.id

        if let url = document.localURL {
            attributes.contentURL = url
            attributes.relatedUniqueIdentifier = document.id
        }

        let item = CSSearchableItem(
            uniqueIdentifier: document.id,
            domainIdentifier: domain,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture

        // CoreSpotlight disk writes stay off the caller's thread.
        Task.detached(priority: .utility) {
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    static func remove(documentId: String) {
        Task.detached(priority: .utility) {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [documentId]) { _ in }
        }
    }

    static func removeAll() {
        Task.detached(priority: .utility) {
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
        }
    }

    /// Compact description shown under the title in Spotlight results.
    private static func snippet(for document: ScannedDocument) -> String {
        var parts: [String] = []
        if let docType = document.docType {
            parts.append(docType)
        }
        parts.append(document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages")
        if document.isRedacted { parts.append("redacted") }
        if document.isSigned { parts.append("signed") }
        var line = parts.joined(separator: " · ")

        if let text = document.ocrText, !text.isEmpty {
            let words = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .prefix(14)
                .joined(separator: " ")
            line += " — \(words)"
        }
        return String(line.prefix(160))
    }
}
