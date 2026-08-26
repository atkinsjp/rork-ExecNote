//
//  PendingUploadTask.swift
//  ScanVault
//

import Foundation

/// One unit of deferred cloud work created while the device was offline.
///
/// PDF bytes are staged on disk (`sync-staging/<taskId>.pdf`) so the archive
/// survives process death; only this lightweight descriptor goes into the
/// durable queue file (`sync-queue.json`).
nonisolated struct PendingUploadTask: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Upload the staged PDF bytes, then write Firestore metadata.
        case fullDocument
        /// Metadata-only reconciliation (title/folder/redaction changes made
        /// while offline). Last-write-wins against the remote copy.
        case metadataOnly
    }

    var id: UUID
    var kind: Kind
    /// Snapshot of the document metadata to reconcile; last write wins.
    var document: ScannedDocument
    /// Staged file name inside the staging directory, or nil for metadata-only.
    var stagedFileName: String?
    var createdAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    var failureReason: String?

    init(kind: Kind, document: ScannedDocument, stagedFileName: String? = nil) {
        id = UUID()
        self.kind = kind
        self.document = document
        self.stagedFileName = stagedFileName
        createdAt = .now
        attempts = 0
    }

    /// Exponential backoff delay before the next retry, capped at two minutes.
    var retryDelay: Duration {
        let seconds = min(120, 2.0 * pow(Double(max(1, attempts)), 2))
        return .seconds(seconds)
    }
}
