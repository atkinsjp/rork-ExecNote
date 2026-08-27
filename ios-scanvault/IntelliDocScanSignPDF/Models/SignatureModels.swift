//
//  SignatureModels.swift
//  IntelliDocScanSignPDF
//

import CoreGraphics
import Foundation

// MARK: - Profile

/// The kind of stamp a saved signature profile represents.
nonisolated enum SignatureType: String, Codable, Sendable, CaseIterable {
    case signature
    case initials
    case dateStamp
    case customText

    var label: String {
        switch self {
        case .signature: "Signature"
        case .initials: "Initials"
        case .dateStamp: "Date Stamp"
        case .customText: "Custom Text"
        }
    }

    var symbolName: String {
        switch self {
        case .signature: "signature"
        case .initials: "textformat.abc"
        case .dateStamp: "calendar"
        case .customText: "character.cursor.ibeam"
        }
    }
}

/// A reusable ink signature, initial or stamp drawn by the user.
///
/// The bitmap is stored at high resolution with a transparent background so it
/// composites cleanly over any page.
nonisolated struct SignatureProfile: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var title: String
    var type: SignatureType
    var pngData: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        type: SignatureType,
        pngData: Data,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.pngData = pngData
        self.createdAt = createdAt
    }
}

// MARK: - Placement

/// A single signature stamp positioned on a page.
///
/// `rect` is normalized (0–1) in **top-left** page space — the same convention
/// the on-screen overlay uses — so it survives zoom, pan and page rotations.
nonisolated struct PlacementData: Codable, Sendable, Hashable {
    var pageIndex: Int
    var rect: CGRect
    var rotationDegrees: Double
    var profileId: UUID
    var profileTitle: String

    init(
        pageIndex: Int,
        rect: CGRect,
        rotationDegrees: Double = 0,
        profileId: UUID,
        profileTitle: String
    ) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.rotationDegrees = rotationDegrees
        self.profileId = profileId
        self.profileTitle = profileTitle
    }
}

nonisolated extension CGRect {
    static let fullPage = CGRect(x: 0, y: 0, width: 1, height: 1)
}

// MARK: - Audit record

/// Cryptographic audit trail captured when a document is signed.
nonisolated struct SignatureAuditRecord: Codable, Sendable {
    var documentId: String
    var signerName: String
    var signerEmail: String
    var timestamp: Date
    var deviceModel: String
    var documentSHA256: String
    var signaturePlacements: [PlacementData]

    init(
        documentId: String,
        signerName: String,
        signerEmail: String,
        timestamp: Date = .now,
        deviceModel: String,
        documentSHA256: String,
        signaturePlacements: [PlacementData]
    ) {
        self.documentId = documentId
        self.signerName = signerName
        self.signerEmail = signerEmail
        self.timestamp = timestamp
        self.deviceModel = deviceModel
        self.documentSHA256 = documentSHA256
        self.signaturePlacements = signaturePlacements
    }
}
