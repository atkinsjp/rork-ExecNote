//
//  VaultStore.swift
//  IntelliDocScanSignPDF
//

import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import WidgetKit

/// Single source of truth for folders, documents and their sync lifecycle.
///
/// Writes are local-first: a scan is rendered to PDF, persisted in the sandbox
/// and shown immediately, while the Firebase upload runs detached in the
/// background. Remote changes stream back in through `FirebaseSyncService`.
@MainActor
@Observable
final class VaultStore {
    private(set) var folders: [AppFolder] = []
    private(set) var documents: [ScannedDocument] = []
    private(set) var syncStates: [String: SyncState] = [:]
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var isBootstrapped: Bool = false

    var searchQuery: String = ""
    /// Document-type filter applied on top of the free-text query.
    var searchTypeFilter: String?
    /// Date-range filter applied on top of the free-text query.
    var searchDateFilter: SearchDateFilter = .anyTime
    /// Smart-routing category filter (e.g. "Tax & Finance") on top of the query.
    var searchCategoryFilter: String?
    /// User-assigned tag filter on top of the query (matches document tags).
    var searchTagFilter: String?
    /// Ordering applied to the filtered result set.
    var searchSort: SearchSort = .relevance
    var banner: String?

    private let sync: FirebaseSyncService
    private let archive: LocalArchive?
    private let pdf = PDFManager.shared
    private let logger = Logger(subsystem: "app.rork.scanvault", category: "vault")
    private var realtimeTask: Task<Void, Never>?
    private let userId: String

    init(
        sync: FirebaseSyncService = .shared,
        archive: LocalArchive? = .shared,
        userId: String = VaultIdentity.userId
    ) {
        self.sync = sync
        self.archive = archive
        self.userId = userId
    }

    /// In-memory store pre-filled with sample data for SwiftUI Canvas previews.
    /// Performs no disk or network access.
    static func mock(documents: [ScannedDocument] = ScannedDocument.mockList) -> VaultStore {
        let store = VaultStore(sync: .preview, archive: nil, userId: "preview")
        store.folders = AppFolder.mockList
        store.documents = documents.sorted { $0.createdAt > $1.createdAt }
        store.syncStates = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, SyncState.synced) })
        store.isBootstrapped = true
        return store
    }

    var cloudEnabled: Bool {
        if case .live = sync.backend { return true }
        return false
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true

        if let payload = await archive?.load() {
            folders = payload.folders
            documents = payload.documents.sorted { $0.createdAt > $1.createdAt }
            await rehydrateLocalURLs()
        } else {
            folders = Self.starterFolders
            await installWelcomeDocument()
            await persist()
        }

        ensureInboxExists()
        for document in documents where syncStates[document.id] == nil {
            syncStates[document.id] = cloudEnabled ? .synced : .localOnly
        }

        await refreshThumbnails()
        await updateWidgetSnapshot()
        startRealtimeSync()
    }

    private func startRealtimeSync() {
        guard cloudEnabled else { return }
        realtimeTask?.cancel()
        let stream = sync.realtimeUpdates(userId: userId)
        realtimeTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                await self.merge(snapshot)
            }
        }
    }

    /// Remote wins for records we do not know about; local files are preserved.
    private func merge(_ snapshot: RemoteSnapshot) async {
        var changed = false

        for folder in snapshot.folders where !folders.contains(where: { $0.id == folder.id }) {
            folders.append(folder)
            changed = true
        }

        for remote in snapshot.documents {
            if let index = documents.firstIndex(where: { $0.id == remote.id }) {
                var merged = remote
                merged.localURL = documents[index].localURL
                if merged != documents[index] {
                    documents[index] = merged
                    changed = true
                }
            } else {
                documents.append(remote)
                syncStates[remote.id] = .synced
                changed = true
            }
        }

        guard changed else { return }
        documents.sort { $0.createdAt > $1.createdAt }
        await persist()
    }

    private func persist() async {
        guard let archive else { return }
        await archive.save(.init(folders: folders, documents: documents))
    }

    /// Clears every in-memory trace of the vault. Called by the compliance
    /// wipe after disk + cloud data has been destroyed; also cancels realtime
    /// listeners so the backend can't resurrect rows mid-deletion.
    func resetForAccountDeletion() async {
        realtimeTask?.cancel()
        realtimeTask = nil
        folders = []
        documents.removeAll()
        syncStates.removeAll()
        thumbnails.removeAll()
        searchQuery = ""
        searchTypeFilter = nil
        searchCategoryFilter = nil
        searchTagFilter = nil
        searchDateFilter = .anyTime
        searchSort = .relevance
    }

    // MARK: - Derived data

    func documentCount(in folder: AppFolder) -> Int {
        documents.filter { $0.folderId == folder.id }.count
    }

    func documents(in folder: AppFolder) -> [ScannedDocument] {
        documents.filter { $0.folderId == folder.id }
    }

    func folder(withId id: String) -> AppFolder? {
        folders.first { $0.id == id }
    }

    var recentDocuments: [ScannedDocument] {
        Array(documents.prefix(8))
    }

    /// Full-text search across every non-locked document, ranked by the
    /// on-device search engine, filtered by type / category / date range and
    /// ordered by the selected sort option.
    var searchResults: [ScannedDocument] {
        let locks = VaultLockManager.shared
        let searchable = documents.filter { document in
            guard let folder = folder(withId: document.folderId) else { return true }
            return !locks.hidesContents(of: folder)
        }
        let results = DocumentSearchEngine.shared.search(
            query: searchQuery,
            in: searchable,
            docType: searchTypeFilter,
            tag: searchTagFilter,
            category: searchCategoryFilter,
            dateFilter: searchDateFilter
        )
        return sorted(results)
    }

    private func sorted(_ results: [ScannedDocument]) -> [ScannedDocument] {
        switch searchSort {
        case .relevance:
            results
        case .newestFirst:
            results.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            results.sorted { $0.createdAt < $1.createdAt }
        case .titleAZ:
            results.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .fileType:
            results.sorted {
                let lhs = $0.docType ?? "~unfiled"
                let rhs = $1.docType ?? "~unfiled"
                if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
                    return $0.createdAt > $1.createdAt
                }
                return lhs.caseInsensitiveCompare(rhs) == .orderedAscending
            }
        case .category:
            results.sorted {
                let lhs = $0.categoryTag ?? "~uncategorized"
                let rhs = $1.categoryTag ?? "~uncategorized"
                if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
                    return $0.createdAt > $1.createdAt
                }
                return lhs.caseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
    }

    /// Number of active search filters (type / date / category / tag), shown
    /// as a badge on the filter menu chip.
    var activeSearchFilters: Int {
        (searchTypeFilter != nil ? 1 : 0)
            + (searchDateFilter != .anyTime ? 1 : 0)
            + (searchCategoryFilter != nil ? 1 : 0)
            + (searchTagFilter != nil ? 1 : 0)
    }

    /// Distinct document types present in the vault (for the filter menu).
    var availableDocTypes: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for document in documents {
            guard let docType = document.docType, seen.insert(docType).inserted else { continue }
            result.append(docType)
        }
        return result.sorted()
    }

    /// Distinct user-assigned tags present in the vault (for the filter menu).
    var availableTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for document in documents {
            for tag in document.tags where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Distinct smart-routing categories present in the vault (for the filter menu).
    var availableCategories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for document in documents {
            guard let tag = document.categoryTag, seen.insert(tag).inserted else { continue }
            result.append(tag)
        }
        return result.sorted()
    }

    /// Search snippet for a result row, centered on the first hit.
    func searchSnippet(for document: ScannedDocument) -> String? {
        DocumentSearchEngine.shared.snippet(for: document, query: searchQuery)
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var totalPages: Int {
        documents.reduce(0) { $0 + $1.pageCount }
    }

    func syncState(for document: ScannedDocument) -> SyncState {
        syncStates[document.id] ?? .localOnly
    }

    // MARK: - Folders

    func createFolder(name: String, iconName: String, colorHex: String, locked: Bool) {
        let folder = AppFolder(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            iconName: iconName,
            colorHex: colorHex,
            isBiometricLocked: locked
        )
        folders.append(folder)
        Task {
            await persist()
            try? await sync.saveFolder(folder, userId: userId)
        }
    }

    func updateFolder(_ folder: AppFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        Task {
            await persist()
            try? await sync.saveFolder(folder, userId: userId)
        }
    }

    /// Removes a folder and re-files its documents into the Inbox.
    func deleteFolder(_ folder: AppFolder) {
        guard folder.id != AppFolder.inboxID else { return }
        folders.removeAll { $0.id == folder.id }
        for index in documents.indices where documents[index].folderId == folder.id {
            documents[index].folderId = AppFolder.inboxID
        }
        let moved = documents.filter { $0.folderId == AppFolder.inboxID }
        Task {
            await persist()
            try? await sync.deleteFolder(id: folder.id, userId: userId)
            for document in moved {
                try? await sync.saveDocumentMetadata(document, userId: userId)
            }
        }
    }

    private func ensureInboxExists() {
        guard !folders.contains(where: { $0.id == AppFolder.inboxID }) else { return }
        folders.insert(.inbox, at: 0)
    }

    // MARK: - Documents

    /// Renders `pages` into a PDF, files it, and kicks off the background upload.
    @discardableResult
    func saveScan(
        pages: [UIImage],
        title: String,
        folderId: String,
        classification: DocumentClassification? = nil
    ) async -> ScannedDocument? {
        guard !pages.isEmpty else { return nil }
        let documentId = UUID().uuidString
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? ScannedDocument.timestampTitle() : trimmed

        do {
            let result = try await pdf.makeAndSave(images: pages, documentId: documentId)
            let keywords = await OCRService.shared.keywords(from: pages)
            let pageTexts = await OCRService.shared.fullText(from: pages)

            let document = ScannedDocument(
                id: documentId,
                title: resolvedTitle,
                folderId: folderId,
                storagePath: ScannedDocument.storagePath(userId: userId, documentId: documentId),
                localURL: result.url,
                pageCount: pages.count,
                ocrKeywords: keywords,
                ocrText: pageTexts.joined(separator: "\n\u{2029}"),
                docType: classification?.docType,
                categoryTag: classification?.category?.rawValue
            )

            documents.insert(document, at: 0)
            documents.sort { $0.createdAt > $1.createdAt }
            syncStates[documentId] = cloudEnabled ? .uploading(progress: 0) : .localOnly
            thumbnails[documentId] = await pdf.thumbnail(for: result.url)
            await persist()

            // Multi-page scans surface a Live Activity in the Dynamic Island.
            if pages.count > 1 {
                LiveActivityCoordinator.shared.begin(
                    title: resolvedTitle,
                    pageCount: pages.count,
                    folderName: folderName(for: folderId)
                )
            }

            SpotlightIndexer.index(document)
            TelemetryService.track(.scanCompleted, attributes: ["pages": String(pages.count)])
            upload(document: document, data: result.data)
            await updateWidgetSnapshot()

            // Automatic one-sentence AI summary, generated once the scan is
            // filed and persisted with the document metadata.
            Task { [weak self] in
                _ = await self?.generateSummary(for: document)
            }
            return document
        } catch {
            logger.error("Saving scan failed: \(error.localizedDescription, privacy: .public)")
            banner = error.localizedDescription
            return nil
        }
    }

    // MARK: - AI summary

    /// Generates (or regenerates) the one-sentence AI summary for a document
    /// from its on-device OCR text and persists it with the metadata.
    ///
    /// - Returns: the updated document on success, nil when there is no OCR
    ///   text to summarize or the AI call failed.
    @discardableResult
    func generateSummary(for document: ScannedDocument, force: Bool = false) async -> ScannedDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return nil }
        guard force || documents[index].aiSummary == nil else { return documents[index] }

        let source = documents[index]
        guard !(source.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            logger.info("No readable text in \(source.title, privacy: .public) — skipping summary")
            return nil
        }

        do {
            let summary = try await DocumentSummaryService.summarize(
                title: source.title,
                docType: source.docType,
                ocrText: source.ocrText ?? ""
            )
            // The document may have changed while the request was in flight.
            guard documents.firstIndex(where: { $0.id == source.id }) != nil else { return nil }
            let target = documents.firstIndex(where: { $0.id == source.id })!
            documents[target].aiSummary = summary
            let updated = documents[target]

            await persist()
            try? await sync.saveDocumentMetadata(updated, userId: userId)
            SpotlightIndexer.index(updated)
            return updated
        } catch AIGatewayError.emptyResponse {
            logger.info("Nothing to summarize for \(source.title, privacy: .public)")
            return nil
        } catch {
            logger.error("AI summary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func upload(document: ScannedDocument, data: Data) {
        guard cloudEnabled else {
            Task { await LiveActivityCoordinator.shared.complete() }
            return
        }
        // Cloud sync is a Pro capability — the free tier stays on-device.
        guard SubscriptionManager.shared.hasAccess(to: .cloudSync) else {
            syncStates[document.id] = .localOnly
            Task { await LiveActivityCoordinator.shared.complete() }
            return
        }
        // Offline-first: when connectivity is down, stage into the durable
        // sync queue instead of surfacing an error. Drains automatically.
        guard OfflineSyncCoordinator.shared.isNetworkAvailable else {
            OfflineSyncCoordinator.shared.enqueue(document: document, pdfData: data)
            Task { await LiveActivityCoordinator.shared.complete() }
            return
        }
        Task { [sync, userId, weak self] in
            do {
                await LiveActivityCoordinator.shared.update(progress: 0.1, status: .uploading)
                try await sync.uploadPDF(
                    data,
                    documentId: document.id,
                    userId: userId,
                    onProgress: { progress in
                        Task { @MainActor in
                            self?.syncStates[document.id] = .uploading(progress: progress)
                            await LiveActivityCoordinator.shared.update(
                                progress: max(0.1, progress * 0.9),
                                status: .uploading
                            )
                        }
                    }
                )
                try await sync.saveDocumentMetadata(document, userId: userId)
                await MainActor.run { self?.syncStates[document.id] = .synced }
                await LiveActivityCoordinator.shared.complete()
            } catch {
                await MainActor.run {
                    self?.syncStates[document.id] = .failed(error.localizedDescription)
                }
                await LiveActivityCoordinator.shared.fail()
            }
        }
    }

    /// Retries a failed upload using the PDF already on disk.
    func retryUpload(for document: ScannedDocument) {
        guard cloudEnabled else { return }
        syncStates[document.id] = .uploading(progress: 0)
        Task { [pdf] in
            guard let url = await pdf.existingURL(documentId: document.id),
                  let data = try? Data(contentsOf: url)
            else {
                syncStates[document.id] = .failed("The local PDF is missing.")
                return
            }
            upload(document: document, data: data)
        }
    }

    func rename(_ document: ScannedDocument, to title: String) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        documents[index].title = trimmed
        let updated = documents[index]
        SpotlightIndexer.index(updated)
        Task {
            await persist()
            try? await sync.saveDocumentMetadata(updated, userId: userId)
        }
    }

    /// Replaces a document's user tags with a normalized set, persists the
    /// change, mirrors it into Firestore metadata and refreshes Spotlight.
    @discardableResult
    func setTags(_ tags: [String], for document: ScannedDocument) async -> ScannedDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return nil }

        documents[index].tags = ScannedDocument.normalizeTags(tags) ?? []
        let updated = documents[index]

        await persist()
        try? await sync.saveDocumentMetadata(updated, userId: userId)
        SpotlightIndexer.index(updated)
        return updated
    }

    func move(_ document: ScannedDocument, to folderId: String) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents[index].folderId = folderId
        let updated = documents[index]
        Task {
            await persist()
            try? await sync.saveDocumentMetadata(updated, userId: userId)
        }
    }

    func delete(_ document: ScannedDocument) {
        documents.removeAll { $0.id == document.id }
        syncStates[document.id] = nil
        thumbnails[document.id] = nil
        SpotlightIndexer.remove(documentId: document.id)
        Task { await updateWidgetSnapshot() }
        Task { [pdf, sync, userId] in
            await pdf.delete(documentId: document.id)
            await persist()
            try? await sync.deleteDocumentMetadata(id: document.id, userId: userId)
            try? await sync.deletePDF(documentId: document.id, userId: userId)
        }
    }

    /// Bulk delete from multi-select: removes every listed document at once,
    /// clears their sync/thumbnail state, then destroys local PDFs and cloud
    /// copies in the background before persisting the slimmed archive.
    func deleteDocuments(_ targets: [ScannedDocument]) {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty else { return }

        documents.removeAll { ids.contains($0.id) }
        for id in ids {
            syncStates[id] = nil
            thumbnails[id] = nil
            SpotlightIndexer.remove(documentId: id)
        }

        Task { await updateWidgetSnapshot() }
        Task { [pdf, sync, userId] in
            for id in ids {
                await pdf.delete(documentId: id)
                try? await sync.deleteDocumentMetadata(id: id, userId: userId)
                try? await sync.deletePDF(documentId: id, userId: userId)
            }
            await persist()
        }
    }

    // MARK: - Notes Studio

    /// Persists the (possibly hand-edited) handwriting transcription with the
    /// document and mirrors it into the Firestore metadata.
    @discardableResult
    func setTranscription(_ text: String, for document: ScannedDocument) async -> ScannedDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        documents[index].noteTranscription = trimmed
        let updated = documents[index]
        SpotlightIndexer.index(updated)
        await persist()
        try? await sync.saveDocumentMetadata(updated, userId: userId)
        return updated
    }

    /// Stores a finished AI variation with the document metadata (newest
    /// first) and syncs it to Firestore.
    @discardableResult
    func addTransform(_ record: NoteTransformRecord, for document: ScannedDocument) async -> ScannedDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return nil }

        documents[index].noteTransforms.removeAll { $0.id == record.id }
        documents[index].noteTransforms.insert(record, at: 0)
        // Keep the embedded metadata lean — Firestore documents cap at 1 MB.
        if documents[index].noteTransforms.count > 10 {
            documents[index].noteTransforms = Array(documents[index].noteTransforms.prefix(10))
        }
        let updated = documents[index]

        await persist()
        try? await sync.saveDocumentMetadata(updated, userId: userId)
        return updated
    }

    // MARK: - Redaction

    /// Replaces the document's PDF with a flattened, sanitized copy (opaque
    /// masks burned in, no text layer) and re-uploads it in the background.
    @discardableResult
    func applyRedactions(
        to document: ScannedDocument,
        pages: [UIImage],
        regions: [RedactionBox]
    ) async -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return false }
        let applied = regions.filter(\.isSelected)
        guard !applied.isEmpty else { return false }

        // Batch redactions surface a Live Activity in the Dynamic Island.
        LiveActivityCoordinator.shared.begin(
            title: document.title,
            pageCount: document.pageCount,
            folderName: folderName(for: document.folderId),
            status: .redacting
        )

        do {
            let result = try await OCRRedactionService.shared.renderRedactedPDF(
                pages: pages,
                regions: applied,
                documentId: document.id
            )

            documents[index].localURL = result.url
            documents[index].isRedacted = true
            documents[index].redactionCount = applied.count
            let updated = documents[index]
            TelemetryService.track(.redactionApplied)

            thumbnails[document.id] = await pdf.thumbnail(for: result.url)
            await persist()

            SpotlightIndexer.index(updated)
            // The sanitized PDF replaces the cloud copy too.
            upload(document: updated, data: result.data)
            await updateWidgetSnapshot()
            return true
        } catch {
            logger.error("Redaction failed: \(error.localizedDescription, privacy: .public)")
            banner = error.localizedDescription
            await LiveActivityCoordinator.shared.fail()
            return false
        }
    }

    // MARK: - Signing

    /// Flattens signature stamps into the document's PDF, seals a SHA-256
    /// audit trail, and re-uploads the cryptographically stamped file.
    @discardableResult
    func finalizeSignature(
        for document: ScannedDocument,
        placements: [PlacementData],
        profiles: [SignatureProfile],
        signerName: String,
        signerEmail: String,
        includeAuditPage: Bool
    ) async -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return false }
        guard !placements.isEmpty else { return false }

        // Signing surfaces a Live Activity while stamps + audit trail render.
        LiveActivityCoordinator.shared.begin(
            title: document.title,
            pageCount: document.pageCount,
            folderName: folderName(for: document.folderId),
            status: .redacting
        )

        var sourceURL: URL? = document.localURL
        if sourceURL == nil {
            sourceURL = await pdf.existingURL(documentId: document.id)
        }
        guard let sourceURL else {
            banner = "The PDF is not on this device."
            return false
        }

        do {
            let result = try await PDFSignerService.shared.finalize(
                documentId: document.id,
                sourceURL: sourceURL,
                placements: placements,
                profiles: profiles,
                signerName: signerName,
                signerEmail: signerEmail,
                includeAuditPage: includeAuditPage
            )

            documents[index].localURL = result.url
            documents[index].isSigned = true
            documents[index].signatureCount = placements.count
            documents[index].auditHash = result.audit.documentSHA256
            if includeAuditPage {
                documents[index].pageCount += 1
            }
            let updated = documents[index]
            TelemetryService.track(.signatureStamped)

            thumbnails[document.id] = await pdf.thumbnail(for: result.url)
            await persist()

            SpotlightIndexer.index(updated)
            // The stamped PDF replaces the cloud copy too.
            upload(document: updated, data: result.data)
            await updateWidgetSnapshot()
            return true
        } catch {
            logger.error("Signing failed: \(error.localizedDescription, privacy: .public)")
            banner = error.localizedDescription
            await LiveActivityCoordinator.shared.fail()
            return false
        }
    }

    // MARK: - OS integration

    /// Folder display name for Live Activity badges.
    private func folderName(for folderId: String) -> String {
        folder(withId: folderId)?.name ?? "Inbox"
    }

    /// Publishes the latest vault snapshot to the widget suite through the
    /// App Group container, then reloads every widget timeline.
    private func updateWidgetSnapshot() async {
        let recent = documents
            .prefix(2)
            .map { document in
                WidgetDocumentSnapshot(
                    id: document.id,
                    title: document.title,
                    createdAt: document.createdAt,
                    pageCount: document.pageCount,
                    thumbnailData: thumbnails[document.id]?.jpegData(compressionQuality: 0.6)
                )
            }
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        let stats = VaultWidgetStats(
            monthScans: documents.filter { $0.createdAt >= monthStart }.count,
            totalDocuments: documents.count
        )
        VaultWidgetStore.save(recent: Array(recent), stats: stats)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Thumbnails

    func thumbnail(for document: ScannedDocument) -> UIImage? {
        thumbnails[document.id]
    }

    private func refreshThumbnails() async {
        for document in documents.prefix(24) where thumbnails[document.id] == nil {
            let cached = await pdf.existingURL(documentId: document.id)
            guard let url = document.localURL ?? cached else { continue }
            if let image = await pdf.thumbnail(for: url) {
                thumbnails[document.id] = image
            }
        }
    }

    private func rehydrateLocalURLs() async {
        for index in documents.indices {
            documents[index].localURL = await pdf.existingURL(documentId: documents[index].id)
        }
    }

    /// Replaces the untouched starter folders with the persona's filing set.
    /// No-ops once the user has customized their folder structure.
    func applyPersona(_ persona: OnboardingPersona) async {
        let starterNames = Set(Self.starterFolders.map(\.name))
        let isUntouched = Set(folders.map(\.name)) == starterNames
        guard isUntouched || folders.allSatisfy({ $0.id == AppFolder.inboxID }) else { return }

        let seeded = persona.folderTemplates
        folders = [AppFolder.inbox] + seeded
        await persist()

        for folder in seeded {
            try? await sync.saveFolder(folder, userId: userId)
        }
    }

    // MARK: - First launch

    private static let starterFolders: [AppFolder] = [
        .inbox,
        AppFolder(name: "Work", iconName: "briefcase.fill", colorHex: "4A90D9"),
        AppFolder(name: "Home", iconName: "house.fill", colorHex: "E2664F"),
        AppFolder(name: "Health", iconName: "stethoscope", colorHex: "3FB0A0", isBiometricLocked: true),
        AppFolder(name: "Receipts", iconName: "creditcard.fill", colorHex: "B4C74A"),
    ]

    /// Generates a real one-page PDF explaining the app, so the vault is never
    /// empty on first launch and PDFKit has something genuine to render.
    private func installWelcomeDocument() async {
        let page = WelcomePage.render()
        let documentId = "welcome-\(UUID().uuidString.prefix(8))"
        guard let result = try? await pdf.makeAndSave(images: [page], documentId: documentId) else { return }

        let document = ScannedDocument(
            id: documentId,
            title: "Welcome to IntelliDocScanSignPDF",
            folderId: AppFolder.inboxID,
            storagePath: ScannedDocument.storagePath(userId: userId, documentId: documentId),
            localURL: result.url,
            pageCount: 1,
            ocrKeywords: ["welcome", "scan", "folder", "vault", "guide"]
        )
        documents.append(document)
        syncStates[documentId] = .localOnly
        thumbnails[documentId] = await pdf.thumbnail(for: result.url)
    }
}
