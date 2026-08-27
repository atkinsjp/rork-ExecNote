//
//  DocumentClassification.swift
//  IntelliDocScanSignPDF
//

import Foundation

// MARK: - Categories

/// Canonical filing categories the router understands.
nonisolated enum DocumentCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case taxFinance = "Tax & Finance"
    case medicalHealth = "Medical & Health"
    case legalContracts = "Legal & Contracts"
    case receiptsExpenses = "Receipts & Expenses"
    case personalIDs = "Personal IDs"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .taxFinance: "banknote.fill"
        case .medicalHealth: "cross.case.fill"
        case .legalContracts: "scale.3d"
        case .receiptsExpenses: "receipt.fill"
        case .personalIDs: "person.text.rectangle.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .taxFinance: "4A90D9"
        case .medicalHealth: "3FB0A0"
        case .legalContracts: "8A7CE0"
        case .receiptsExpenses: "B4C74A"
        case .personalIDs: "E2664F"
        }
    }
}

// MARK: - Classification result

/// Everything the on-device analyzer learned about one scanned document.
nonisolated struct DocumentClassification: Sendable, Equatable {
    /// Vendor / entity anchor, e.g. "Home Depot", "IRS", "Dr. Smith".
    var entity: String?
    /// Document type label, e.g. "Receipt", "Tax Form", "Prescription".
    var docType: String?
    /// Most salient date found in the text, if any.
    var date: Date?
    /// Largest / labelled money amount, if any.
    var total: Double?
    /// Smart-routing destination.
    var category: DocumentCategory?
    /// 0–1 confidence in the category + type verdict.
    var confidence: Double
    /// Three one-tap name suggestions for the review screen.
    var suggestedNames: [String]
    /// Keywords that drove the verdict (debug + UI chips).
    var matchedKeywords: [String]

    /// Canonical machine-friendly name: `YYYY-MM-DD_[Entity]_[DocType].pdf`.
    var canonicalFileName: String? {
        guard let docType else { return nil }
        let day = (date ?? .now).formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let entityPart = entity.map { sanitize($0) } ?? "Document"
        return "\(day)_\(entityPart)_\(sanitize(docType)).pdf"
    }

    /// Short "why" line for the suggestion bar.
    var reasonLine: String {
        var parts: [String] = []
        if let docType { parts.append(docType) }
        if let entity { parts.append(entity) }
        if parts.isEmpty { return "Text read on-device" }
        return parts.joined(separator: " · ")
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .filter { !$0.isWhitespace }
    }
}
