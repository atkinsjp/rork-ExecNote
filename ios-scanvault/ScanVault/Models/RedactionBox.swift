//
//  RedactionBox.swift
//  ScanVault
//

import Foundation
import CoreGraphics

/// The class of sensitive content a redaction box covers.
nonisolated enum RedactionKind: String, Codable, CaseIterable, Sendable {
    case ssn
    case creditCard
    case email
    case phone
    case custom
    case manual

    var label: String {
        switch self {
        case .ssn: "SSN"
        case .creditCard: "Card"
        case .email: "Email"
        case .phone: "Phone"
        case .custom: "Match"
        case .manual: "Box"
        }
    }

    /// Compact tag rendered inside a highlight on the canvas.
    var shortLabel: String {
        switch self {
        case .ssn: "SSN"
        case .creditCard: "CARD"
        case .email: "EMAIL"
        case .phone: "PHONE"
        case .custom: "MATCH"
        case .manual: "BOX"
        }
    }

    var symbolName: String {
        switch self {
        case .ssn: "person.text.rectangle"
        case .creditCard: "creditcard"
        case .email: "envelope"
        case .phone: "phone"
        case .custom: "text.magnifyingglass"
        case .manual: "square.and.pencil"
        }
    }

    var colorHex: String {
        switch self {
        case .ssn: "E2664F"
        case .creditCard: "E8A33D"
        case .email: "3FB0A0"
        case .phone: "4A90D9"
        case .custom: "8A7CE0"
        case .manual: "F1F0ED"
        }
    }
}

/// One redaction region on one page.
///
/// `rect` is normalized (0–1) with a top-left origin relative to the page
/// image, so it maps cleanly onto UIKit views, Canvas overlays and the PDF
/// page box alike.
nonisolated struct RedactionBox: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let pageIndex: Int
    var rect: CGRect
    let kind: RedactionKind
    var matchedText: String?
    var isManual: Bool
    var isSelected: Bool

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        rect: CGRect,
        kind: RedactionKind,
        matchedText: String? = nil,
        isManual: Bool = false,
        isSelected: Bool = true
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.kind = kind
        self.matchedText = matchedText
        self.isManual = isManual
        self.isSelected = isSelected
    }
}
