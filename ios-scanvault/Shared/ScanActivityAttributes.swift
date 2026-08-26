//
//  ScanActivityAttributes.swift
//  ScanVault
//
//  Shared between the main app (starts/updates the activity) and the widget
//  extension (renders the Dynamic Island + Lock Screen presentations).
//

import ActivityKit
import Foundation

/// Pipeline stages surfaced on the Live Activity.
nonisolated enum UploadStatus: String, Codable, Sendable, Hashable {
    case scanning
    case redacting
    case uploading
    case completed
    case failed

    var label: String {
        switch self {
        case .scanning: "Scanning"
        case .redacting: "Redacting"
        case .uploading: "Uploading"
        case .completed: "Filed"
        case .failed: "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .scanning: "doc.viewfinder"
        case .redacting: "eye.slash"
        case .uploading: "arrow.up.icloud"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// Live Activity attributes for a document moving through the
/// scan → redact/sign → upload pipeline.
nonisolated struct ScanActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// 0.0 – 1.0 pipeline progress.
        var uploadProgress: Double
        var status: UploadStatus
    }

    /// Title of the document being processed.
    var documentTitle: String
    var pageCount: Int
    /// Destination folder shown on the expanded banner, e.g. "Tax & Finance".
    var folderName: String
}
