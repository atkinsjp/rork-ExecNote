//
//  ICloudSyncService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import Observation
import OSLog

// MARK: - Availability

/// Runtime state of the user's iCloud Drive container.
nonisolated enum ICloudAvailability: Equatable, Sendable {
    case checking
    case unavailable
    case available
}

// MARK: - Manifest

/// Device-generated vault mirror written into the app's private iCloud Drive
/// container. Apple's file provider ships it (and the PDFs next to it) to
/// every signed-in device, where `VaultStore` merges it pull-side.
nonisolated struct ICloudManifest: Codable, Sendable, Equatable {
    struct CloudDocumentRecord: Codable, Sendable, Equatable {
        var document: ScannedDocument
        var mirroredAt: Date
    }

    var version: Int
    var updatedAt: Date
    var folders: [AppFolder]
    var documents: [CloudDocumentRecord]
    /// Documents deleted on any device (id → deletion time). Tombstones keep
    /// stale manifests on other devices from resurrecting removed scans.
    var tombstones: [String: Date]

    init(folders: [AppFolder], documents: [CloudDocumentRecord], tombstones: [String: Date]) {
        version = 1
        updatedAt = .now
        self.folders = folders
        self.documents = documents
        self.tombstones = tombstones
    }
}

// MARK: - Service

/// Automatic iCloud Drive sync for the document vault. All transport is
/// Apple's file provider — no server code involved.
///
/// - **Push** — `VaultStore.persist()` hands every vault mutation to
///   `syncVault(folders:documents:)`; the service reconciles changed PDFs
///   into `<container>/Documents/vault/files/` and rewrites `manifest.json`
///   under file coordination, debounced so bursts of edits coalesce.
/// - **Pull** — an `NSMetadataQuery` watches the container; whenever a newer
///   manifest arrives from another device it is decoded and streamed to
///   `VaultStore`, which imports unknown documents and honors tombstones.
/// - **Privacy** — mirrors the Firestore policy: full OCR text is stripped
///   before anything leaves the device and the container is app-private.
///
/// Everything degrades gracefully: without an iCloud account the service
/// reports `.unavailable`, the toggle disables and scanning stays local-only.
@MainActor
@Observable
final class ICloudSyncService {
    static let shared = ICloudSyncService()

    // MARK: Observable state

    private(set) var availability: ICloudAvailability = .checking
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    /// Ids whose current PDF is mirrored in the container.
    private(set) var mirroredIds: Set<String> = []
    private(set) var tombstones: [String: Date] = [:]

    /// User switch (Settings → iCloud Sync). On by default; syncing only
    /// actually runs when the account also resolves to a container.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    var isActive: Bool { isEnabled && availability == .available }

    // MARK: Plumbing

    private nonisolated static let logger = Logger(subsystem: "app.rork.scanvault", category: "icloud")
    private nonisolated static let enabledKey = "scanvault.icloud.enabled"
    private nonisolated static let filePrefix = "welcome-"

    private var containerRoot: URL?
    private var hasStarted = false
    private var pushTask: Task<Void, Never>?
    private var pendingPush: VaultPush?
    private var metadataQuery: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var lastRemotePullAt: Date?

    private let snapshotStream: AsyncStream<ICloudManifest>
    private let snapshotContinuation: AsyncStream<ICloudManifest>.Continuation

    /// Immutable vault snapshot staged for the next push.
    private nonisolated struct VaultPush: Sendable {
        var folders: [AppFolder]
        var documents: [ScannedDocument]
    }

    private init() {
        let (stream, continuation) = AsyncStream.makeStream(of: ICloudManifest.self)
        snapshotStream = stream
        snapshotContinuation = continuation
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    /// Resolves the iCloud container (can block on account lookup, so it runs
    /// detached) and begins watching for remote changes. Idempotent.
    func start() {
        loadTombstones()
        guard !hasStarted else { return }
        hasStarted = true
        resolveContainer()
    }

    /// Re-resolves the container after the user signs into iCloud while the
    /// app is running. Safe to call repeatedly.
    func refreshAvailability() async {
        guard containerRoot == nil else { return }
        resolveContainer()
    }

    private func resolveContainer() {
        Task.detached(priority: .utility) { [weak self] in
            let root = Self.resolveContainerRoot()
            await self?.handleContainer(root)
        }
    }

    private func handleContainer(_ root: URL?) {
        guard containerRoot == nil else { return }
        availability = root == nil ? .unavailable : .available
        guard let root else {
            Self.logger.info("iCloud container unavailable — sync stays local-only.")
            return
        }
        containerRoot = root
        let filesDirectory = root.appending(path: "files", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        startMetadataQuery()
        Task { await pullRemoteManifest() }
    }

    private nonisolated static func resolveContainerRoot() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        return container.appending(path: "Documents/vault", directoryHint: .isDirectory)
    }

    // MARK: Push (local → remote)

    /// Coalesces a vault mutation into the next background push. Called from
    /// `VaultStore.persist()` after every local change.
    func syncVault(folders: [AppFolder], documents: [ScannedDocument]) {
        guard isActive, hasStarted else { return }
        let syncable = documents.filter { !$0.id.hasPrefix(Self.filePrefix) }
        pendingPush = VaultPush(folders: folders, documents: syncable)
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.performPush()
        }
    }

    private func performPush() async {
        defer { pushTask = nil }
        isSyncing = true
        defer { isSyncing = false }

        while let push = pendingPush {
            pendingPush = nil
            guard let root = containerRoot else { return }
            do {
                let mirrored = try await Task.detached(priority: .utility) { [tombstones = tombstones] in
                    try Self.push(push, tombstones: tombstones, to: root)
                }.value
                mirroredIds = mirrored
                lastSyncAt = .now
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                Self.logger.error("iCloud push failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// Reconciles the container with `push`: copies new/changed PDFs under
    /// file coordination, drops files for tombstoned documents and rewrites
    /// the manifest. Runs entirely off the main actor.
    private nonisolated static func push(
        _ push: VaultPush,
        tombstones: [String: Date],
        to root: URL
    ) throws -> Set<String> {
        let fileManager = FileManager.default
        let filesDirectory = root.appending(path: "files", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        var mirrored: Set<String> = []

        for document in push.documents {
            guard let source = document.localURL,
                  fileManager.fileExists(atPath: source.path)
            else { continue }

            let destination = filesDirectory.appending(path: "\(document.id).pdf")
            let remoteSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let localSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if remoteSize >= 0, remoteSize == localSize {
                mirrored.insert(document.id)
                continue
            }

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            coordinator.coordinate(
                readingItemAt: source, options: .withoutChanges,
                writingItemAt: destination, options: .forReplacing, error: nil
            ) { readURL, writeURL in
                try? fileManager.removeItem(at: writeURL)
                do {
                    try fileManager.copyItem(at: readURL, to: writeURL)
                } catch {
                    coordinationError = error as NSError
                }
            }
            if let coordinationError { throw coordinationError }
            mirrored.insert(document.id)
        }

        for deletedId in tombstones.keys {
            let stale = filesDirectory.appending(path: "\(deletedId).pdf")
            if fileManager.fileExists(atPath: stale.path) {
                try? fileManager.removeItem(at: stale)
            }
        }

        let records = push.documents.map { document -> ICloudManifest.CloudDocumentRecord in
            var sanitized = document
            // Full OCR text never leaves the device (same policy as Firestore).
            sanitized.ocrText = nil
            return ICloudManifest.CloudDocumentRecord(document: sanitized, mirroredAt: .now)
        }
        let manifest = ICloudManifest(folders: push.folders, documents: records, tombstones: tombstones)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try writeCoordinated(encoder.encode(manifest), to: root.appending(path: "manifest.json"))
        return mirrored
    }

    // MARK: Pull (remote → local)

    /// Stream of manifests written by the user's other devices.
    var incomingManifests: AsyncStream<ICloudManifest> { snapshotStream }

    /// Reads the remote manifest (downloading it first when needed) and emits
    /// it for local import. No-op when the file is absent or unchanged.
    func pullRemoteManifest() async {
        guard let manifest = await readManifest() else { return }
        lastRemotePullAt = manifest.updatedAt
        snapshotContinuation.yield(manifest)
    }

    /// Reads the remote manifest without touching pull bookkeeping; used by
    /// the one-shot import retry in `VaultStore`.
    func currentManifest() async -> ICloudManifest? {
        await readManifest()
    }

    private func readManifest() async -> ICloudManifest? {
        guard let root = containerRoot else { return nil }
        let url = root.appending(path: "manifest.json")
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            Self.downloadIfNeeded(url)
            guard let data = Self.readCoordinated(url), !data.isEmpty else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ICloudManifest.self, from: data)
        }.value
    }

    private func startMetadataQuery() {
        guard metadataQuery == nil, let root = containerRoot else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [root.path]
        query.predicate = NSPredicate(format: "%K == 'manifest.json'", NSMetadataItemFSNameKey)
        metadataQuery = query
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleRemoteManifestHint() }
        }
        query.start()
        query.enableUpdates()
    }

    private func handleRemoteManifestHint() {
        guard let root = containerRoot else { return }
        let url = root.appending(path: "manifest.json")
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let modified, modified > (lastRemotePullAt ?? .distantPast) else { return }
        Task { await pullRemoteManifest() }
    }

    // MARK: Document access for imports

    /// Fetches a mirrored PDF by id, downloading it from iCloud first when
    /// needed. Returns nil when the copy is missing or not yet available.
    func pdfData(documentId: String) async -> Data? {
        guard let root = containerRoot else { return nil }
        let url = root.appending(path: "files/\(documentId).pdf")
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            Self.downloadIfNeeded(url)
            return Self.readCoordinated(url)
        }.value
    }

    // MARK: Deletions

    /// Records a document removal so other devices (and this one, via stale
    /// manifests) honor it. The next push writes the tombstone and drops the
    /// cloud PDF.
    func recordDeletion(documentId: String) {
        tombstones[documentId] = .now
        mirroredIds.remove(documentId)
        persistTombstones()
    }

    func isTombstoned(documentId: String) -> Bool {
        tombstones[documentId] != nil
    }

    /// True when the document's current PDF is mirrored in iCloud Drive.
    func isMirrored(documentId: String) -> Bool {
        mirroredIds.contains(documentId)
    }

    // MARK: Compliance

    /// Destroys the entire iCloud mirror (account deletion flow). Best-effort,
    /// matching the Firestore wipe: other devices honor their own local state.
    func wipeContainer() async {
        guard let root = containerRoot else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
        }.value
        mirroredIds.removeAll()
        tombstones.removeAll()
        persistTombstones()
        lastSyncAt = nil
    }

    // MARK: Tombstone persistence

    private var tombstonesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "icloud-tombstones.json")
    }

    private func loadTombstones() {
        guard let data = try? Data(contentsOf: tombstonesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tombstones = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func persistTombstones() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(tombstones) {
            try? data.write(to: tombstonesURL, options: .atomic)
        }
    }

    // MARK: File coordination helpers

    private nonisolated static func readCoordinated(_ url: URL) -> Data? {
        var data: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: nil) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data
    }

    private nonisolated static func writeCoordinated(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: nil) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                coordinationError = error as NSError
            }
        }
        if let coordinationError { throw coordinationError }
    }

    /// Blocks (off-main) until iCloud finishes downloading the item, or the
    /// 30 s timeout elapses. No-op for already-downloaded files.
    private nonisolated static func downloadIfNeeded(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status == .current {
            return
        }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
               status == .current {
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
}
