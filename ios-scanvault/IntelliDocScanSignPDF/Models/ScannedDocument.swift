//
//  ScannedDocument.swift
//  IntelliDocScanSignPDF
//

import Foundation

/// Metadata describing a single multi-page scan stored as a PDF.
nonisolated struct ScannedDocument: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var folderId: String
    var storagePath: String
    var localURL: URL?
    var pageCount: Int
    var ocrKeywords: [String]
    var createdAt: Date
    /// True once a sanitized, image-only PDF has replaced the original scan.
    var isRedacted: Bool
    /// Number of redaction boxes burned into the flattened PDF.
    var redactionCount: Int
    /// True once signatures have been flattened into the pages.
    var isSigned: Bool
    /// Number of signature stamps burned into the document.
    var signatureCount: Int
    /// SHA-256 digest of the signed pages, recorded in the audit trail.
    var auditHash: String?
    /// Full on-device OCR text (page-separated), powering full-text search and
    /// transcription exports. Kept local-only — never synced to Firestore.
    var ocrText: String?
    /// Document type verdict from the classifier (e.g. "Receipt", "Tax Form").
    var docType: String?
    /// Smart-routing category tag (e.g. "Tax & Finance").
    var categoryTag: String?
    /// One-sentence AI summary of the document, shown as the reader header.
    var aiSummary: String?
    /// Handwriting transcription from the Notes Studio, synced via Firestore.
    var noteTranscription: String?
    /// AI-generated variations of the notes, newest first.
    var noteTransforms: [NoteTransformRecord]

    enum CodingKeys: String, CodingKey {
        case id, title, folderId, storagePath, localURL, pageCount, ocrKeywords
        case createdAt, isRedacted, redactionCount
        case isSigned, signatureCount, auditHash
        case ocrText, docType, categoryTag, aiSummary
        case noteTranscription, noteTransforms
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        folderId: String,
        storagePath: String,
        localURL: URL? = nil,
        pageCount: Int = 1,
        ocrKeywords: [String] = [],
        createdAt: Date = .now,
        isRedacted: Bool = false,
        redactionCount: Int = 0,
        isSigned: Bool = false,
        signatureCount: Int = 0,
        auditHash: String? = nil,
        ocrText: String? = nil,
        docType: String? = nil,
        categoryTag: String? = nil,
        aiSummary: String? = nil,
        noteTranscription: String? = nil,
        noteTransforms: [NoteTransformRecord] = []
    ) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.storagePath = storagePath
        self.localURL = localURL
        self.pageCount = pageCount
        self.ocrKeywords = ocrKeywords
        self.createdAt = createdAt
        self.isRedacted = isRedacted
        self.redactionCount = redactionCount
        self.isSigned = isSigned
        self.signatureCount = signatureCount
        self.auditHash = auditHash
        self.ocrText = ocrText
        self.docType = docType
        self.categoryTag = categoryTag
        self.aiSummary = aiSummary
        self.noteTranscription = noteTranscription
        self.noteTransforms = noteTransforms
    }

    /// Tolerant decoding so archives written before redaction existed keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        folderId = try container.decode(String.self, forKey: .folderId)
        storagePath = try container.decode(String.self, forKey: .storagePath)
        localURL = try container.decodeIfPresent(URL.self, forKey: .localURL)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1
        ocrKeywords = try container.decodeIfPresent([String].self, forKey: .ocrKeywords) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        isRedacted = try container.decodeIfPresent(Bool.self, forKey: .isRedacted) ?? false
        redactionCount = try container.decodeIfPresent(Int.self, forKey: .redactionCount) ?? 0
        isSigned = try container.decodeIfPresent(Bool.self, forKey: .isSigned) ?? false
        signatureCount = try container.decodeIfPresent(Int.self, forKey: .signatureCount) ?? 0
        auditHash = try container.decodeIfPresent(String.self, forKey: .auditHash)
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        docType = try container.decodeIfPresent(String.self, forKey: .docType)
        categoryTag = try container.decodeIfPresent(String.self, forKey: .categoryTag)
        aiSummary = try container.decodeIfPresent(String.self, forKey: .aiSummary)
        noteTranscription = try container.decodeIfPresent(String.self, forKey: .noteTranscription)
        noteTransforms = try container.decodeIfPresent([NoteTransformRecord].self, forKey: .noteTransforms) ?? []
    }
}

extension ScannedDocument {
    /// Canonical Firebase Storage object path for a document owned by `userId`.
    static func storagePath(userId: String, documentId: String) -> String {
        "users/\(userId)/documents/\(documentId).pdf"
    }

    /// Default title used by the "Save & File" sheet.
    static func timestampTitle(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' HH.mm"
        return "Scan \(formatter.string(from: date))"
    }

    var pageSummary: String {
        pageCount == 1 ? "1 page" : "\(pageCount) pages"
    }

    /// Case-insensitive match against the title and extracted OCR keywords.
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if title.localizedStandardContains(trimmed) { return true }
        return ocrKeywords.contains { $0.localizedStandardContains(trimmed) }
    }
}

// MARK: - Upload lifecycle

nonisolated enum SyncState: Equatable, Sendable {
    case localOnly
    case uploading(progress: Double)
    case synced
    case failed(String)

    var symbolName: String {
        switch self {
        case .localOnly: "iphone.gen3"
        case .uploading: "arrow.up.circle"
        case .synced: "checkmark.icloud.fill"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    var label: String {
        switch self {
        case .localOnly: "On device"
        case .uploading(let progress): "Uploading \(Int(progress * 100))%"
        case .synced: "Synced"
        case .failed: "Upload failed"
        }
    }
}

extension ScannedDocument {
    static let mockList: [ScannedDocument] = [
        ScannedDocument(
            id: "d-1",
            title: "Apartment Lease Agreement",
            folderId: "f-home",
            storagePath: "users/preview/documents/d-1.pdf",
            pageCount: 12,
            ocrKeywords: ["lease", "tenant", "deposit", "landlord"],
            createdAt: .now.addingTimeInterval(-3_600)
        ),
        ScannedDocument(
            id: "d-2",
            title: "Q3 Expense Receipts",
            folderId: "f-work",
            storagePath: "users/preview/documents/d-2.pdf",
            pageCount: 5,
            ocrKeywords: ["invoice", "total", "vat", "receipt"],
            createdAt: .now.addingTimeInterval(-86_400)
        ),
        ScannedDocument(
            id: "d-3",
            title: "Blood Panel Results",
            folderId: "f-health",
            storagePath: "users/preview/documents/d-3.pdf",
            pageCount: 3,
            ocrKeywords: ["hemoglobin", "cholesterol", "results"],
            createdAt: .now.addingTimeInterval(-3 * 86_400),
            isRedacted: true,
            redactionCount: 7
        ),
        ScannedDocument(
            id: "d-4",
            title: "Boarding Pass — LIS→JFK",
            folderId: "f-travel",
            storagePath: "users/preview/documents/d-4.pdf",
            pageCount: 1,
            ocrKeywords: ["boarding", "gate", "seat"],
            createdAt: .now.addingTimeInterval(-5 * 86_400)
        ),
        ScannedDocument(
            id: "d-5",
            title: "Signed NDA",
            folderId: AppFolder.inboxID,
            storagePath: "users/preview/documents/d-5.pdf",
            pageCount: 2,
            ocrKeywords: ["confidential", "agreement", "signature"],
            createdAt: .now.addingTimeInterval(-9 * 86_400),
            isSigned: true,
            signatureCount: 2
        ),
    ]
}
