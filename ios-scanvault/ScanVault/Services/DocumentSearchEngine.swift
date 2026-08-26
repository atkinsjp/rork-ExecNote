//
//  DocumentSearchEngine.swift
//  ScanVault
//

import Foundation

/// One scored search hit over the vault's full-text index.
nonisolated struct SearchHit: Identifiable, Equatable {
    let documentId: String
    let score: Int
    let snippet: String

    var id: String { documentId }
}

/// Date-range buckets offered by the dashboard filter.
nonisolated enum SearchDateFilter: String, CaseIterable, Identifiable, Sendable {
    case anyTime
    case last7
    case last30
    case thisYear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anyTime: "Any time"
        case .last7: "Last 7 days"
        case .last30: "Last 30 days"
        case .thisYear: "This year"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .anyTime: nil
        case .last7: 7 * 86_400
        case .last30: 30 * 86_400
        case .thisYear: nil
        }
    }

    func contains(_ date: Date, now: Date = .now) -> Bool {
        switch self {
        case .anyTime: return true
        case .last7, .last30:
            guard let interval else { return true }
            return date >= now.addingTimeInterval(-interval)
        case .thisYear:
            return Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        }
    }
}

/// Result ordering options for the dashboard search filter menu.
nonisolated enum SearchSort: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case newestFirst
    case oldestFirst
    case titleAZ
    case fileType
    case category

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Most relevant"
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .titleAZ: "Title A–Z"
        case .fileType: "File type"
        case .category: "Category"
        }
    }
}

/// In-memory full-text index over every document's OCR text.
///
/// Documents are tokenized once and cached; subsequent searches score hits by
/// term frequency across title, keywords and page text, with snippets drawn
/// around the first match. Locked folders are excluded by the caller.
@MainActor
final class DocumentSearchEngine {
    static let shared = DocumentSearchEngine()

    private struct IndexedDocument {
        let document: ScannedDocument
        /// Token -> occurrence count over all indexed fields.
        let tokenCounts: [String: Int]
        let loweredText: String
    }

    private var indexed: [String: IndexedDocument] = [:]
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "your", "you",
        "are", "was", "will", "have", "has", "not", "all", "any", "but",
    ]

    // MARK: - Indexing

    /// Re-indexes any document that is new or changed; cheap no-op otherwise.
    func ensureIndexed(_ documents: [ScannedDocument]) {
        var seen = Set<String>()
        for document in documents {
            seen.insert(document.id)
            if indexed[document.id]?.document == document { continue }
            indexed[document.id] = Self.buildEntry(for: document)
        }
        // Drop deleted documents from the index.
        for staleId in indexed.keys where !seen.contains(staleId) {
            indexed.removeValue(forKey: staleId)
        }
    }

    private static func buildEntry(for document: ScannedDocument) -> IndexedDocument {
        let text = [
            document.title,
            document.ocrText ?? "",
            document.ocrKeywords.joined(separator: " "),
            document.noteTranscription ?? "",
            document.noteTransforms.map(\.content).joined(separator: "\n"),
        ]
        .joined(separator: " \n ")
        let lowered = text.lowercased()

        var counts: [String: Int] = [:]
        for token in lowered.components(separatedBy: CharacterSet.alphanumerics.inverted) where !token.isEmpty {
            counts[token, default: 0] += 1
        }
        return IndexedDocument(document: document, tokenCounts: counts, loweredText: lowered)
    }

    // MARK: - Search

    /// Filters documents by free-text query, optional document type, tag,
    /// category and date range, ranked by relevance.
    func search(
        query: String,
        in documents: [ScannedDocument],
        docType: String? = nil,
        tag: String? = nil,
        category: String? = nil,
        dateFilter: SearchDateFilter = .anyTime
    ) -> [ScannedDocument] {
        ensureIndexed(documents)

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !Self.stopWords.contains($0) }

        return documents
            .filter { document in
                if let docType, document.docType?.localizedCaseInsensitiveCompare(docType) != .orderedSame {
                    return false
                }
                if let category, document.categoryTag?.localizedCaseInsensitiveCompare(category) != .orderedSame {
                    return false
                }
                if let tag, !document.ocrKeywords.contains(where: { $0.localizedCaseInsensitiveContains(tag) }) {
                    return false
                }
                guard dateFilter.contains(document.createdAt) else { return false }
                guard !tokens.isEmpty else { return true }

                guard let entry = indexed[document.id] else { return false }
                return tokens.allSatisfy { entry.loweredText.contains($0) }
            }
            .sorted { lhs, rhs in
                let lhsScore = score(of: lhs, tokens: tokens)
                let rhsScore = score(of: rhs, tokens: tokens)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func score(of document: ScannedDocument, tokens: [String]) -> Int {
        guard !tokens.isEmpty, let entry = indexed[document.id] else { return 0 }
        var total = 0
        for token in tokens {
            total += entry.tokenCounts[token] ?? 0
            if document.title.lowercased().contains(token) { total += 8 }
            if document.ocrKeywords.contains(where: { $0.lowercased().contains(token) }) { total += 4 }
        }
        return total
    }

    /// Short text snippet centered on the first query hit, for result rows.
    func snippet(for document: ScannedDocument, query: String) -> String? {
        let text = document.ocrText ?? document.noteTranscription
            ?? document.ocrKeywords.joined(separator: ", ")
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        guard let range = lowered.range(of: trimmed) ?? lowered.range(of: String(trimmed.prefix(12))) else {
            return String(text.prefix(90))
        }
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + text[start..<end] + suffix
    }
}
