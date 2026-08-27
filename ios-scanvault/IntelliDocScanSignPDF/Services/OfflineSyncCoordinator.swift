//
//  OfflineSyncCoordinator.swift
//  IntelliDocScanSignPDF
//

import Foundation
import Network
import OSLog

/// Resilience engine for cloud sync.
///
/// - Watches connectivity in real time via `NWPathMonitor`.
/// - When a write cannot reach Firebase (offline or transport failure), the
///   PDF bytes are staged to disk and a lightweight descriptor joins a
///   durable queue (`sync-queue.json`) that survives process death.
/// - On reconnect, queued work drains sequentially over a **background
///   URLSession** upload with per-task exponential backoff.
/// - Conflict resolution is deliberately **last-write-wins**: whatever the
///   device writes most recently patches over the Firestore copy; remote
///   records unknown locally are merged by `VaultStore`.
///
/// The coordinator never touches document content beyond moving already-OCR'd
/// files into place — it is transport plumbing only.
@MainActor
@Observable
final class OfflineSyncCoordinator {
    static let shared = OfflineSyncCoordinator()

    // MARK: - Observable state

    private(set) var isNetworkAvailable: Bool = true
    private(set) var isConnectionExpensive: Bool = false
    private(set) var pendingTasks: [PendingUploadTask] = []
    private(set) var isDraining: Bool = false
    private(set) var lastSyncError: String?

    // MARK: - Plumbing

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "offline-sync")
    private var monitor: NWPathMonitor?
    private var drainTask: Task<Void, Never>?

    private let baseDirectory: URL
    private let queueURL: URL
    private let stagingDirectory: URL

    /// Background session so long PDF uploads survive screen lock, following
    /// Apple's background-transfer guidance for media-scale payloads.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "app.rork.scanvault.sync"
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration)
    }()

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDirectory = base
        queueURL = base.appending(path: "sync-queue.json")
        stagingDirectory = base.appending(path: "sync-staging", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        loadQueue()
    }

    // MARK: - Lifecycle

    /// Starts `NWPathMonitor`. Called once from the root view at launch.
    func startMonitoring() {
        guard monitor == nil else { return }
        loadQueue()

        let networkMonitor = NWPathMonitor()
        networkMonitor.pathUpdateHandler = { path in
            // Extract plain values here — NWPath isn't Sendable across actors.
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            Task {
                await OfflineSyncCoordinator.shared.handleNetworkChange(
                    satisfied: satisfied, expensive: expensive
                )
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "app.rork.scanvault.netmon"))
        monitor = networkMonitor
    }

    private func handleNetworkChange(satisfied: Bool, expensive: Bool) {
        isConnectionExpensive = expensive
        let wasOffline = !isNetworkAvailable
        isNetworkAvailable = satisfied
        if wasOffline && satisfied && !pendingTasks.isEmpty {
            scheduleDrain()
        }
    }

    // MARK: - Enqueueing

    /// Stages a scanned PDF + metadata for later upload while offline.
    func enqueue(document: ScannedDocument, pdfData: Data?) {
        var task = PendingUploadTask(kind: .fullDocument, document: document)
        if let pdfData, !pdfData.isEmpty {
            let fileName = "\(task.id.uuidString).pdf"
            do {
                try pdfData.write(to: stagedURL(fileName), options: [.atomic, .completeFileProtection])
                task.stagedFileName = fileName
            } catch {
                logger.error("Staging failed; will re-capture bytes at drain time.")
            }
        }
        append(task: task)
        TelemetryService.track(.syncQueuedOffline)
    }

    /// Queues metadata-only changes made while offline (LWW reconciliation).
    func enqueueMetadata(_ document: ScannedDocument) {
        append(task: PendingUploadTask(kind: .metadataOnly, document: document))
    }

    private func append(task: PendingUploadTask) {
        pendingTasks.append(task)
        persistQueue()
        if isNetworkAvailable {
            scheduleDrain()
        }
    }

    // MARK: - Drain loop

    private func scheduleDrain() {
        guard !isDraining, isNetworkAvailable, !pendingTasks.isEmpty else { return }
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        isDraining = true
        defer { isDraining = false }

        while isNetworkAvailable, let next = pendingTasks.first {
            guard !Task.isCancelled else { return }
            do {
                try await perform(next)
                complete(next.id)
                lastSyncError = nil
            } catch {
                failures += 1
                updateFailure(for: next.id, reason: error.localizedDescription)
                logger.error("Sync attempt failed (\(next.attempts + 1)): \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: min(next.retryDelay, .seconds(120)))
            }
        }
    }

    private var failures = 0

    private func perform(_ task: PendingUploadTask) async throws {
        let userId = VaultIdentity.userId
        let service = FirebaseSyncService.shared

        // 1. Bytes first (Storage), then metadata (Firestore), matching the
        //    online flow so thumbnails can resolve immediately server-side.
        if let fileName = task.stagedFileName {
            let fileURL = stagedURL(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let request = Self.storageUploadRequest(
                    bucket: FirebaseConfiguration.fromEnvironment()?.storageBucket ?? "",
                    storagePath: task.document.storagePath
                )
                _ = try await session.upload(for: request, fromFile: fileURL)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        try await service.saveDocumentMetadata(task.document, userId: userId)
    }

    /// Replicates the Storage multipart-less media POST endpoint used by
    /// `FirebaseSyncService.uploadPDF`, but over the background session.
    private nonisolated static func storageUploadRequest(bucket: String, storagePath: String) -> URLRequest {
        let allowed: CharacterSet = .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let encoded = storagePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? storagePath
        var request = URLRequest(url: URL(string: "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o?uploadType=media&name=\(encoded)")!)
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Queue bookkeeping

    private func complete(_ taskId: UUID) {
        if let index = pendingTasks.firstIndex(where: { $0.id == taskId }) {
            pendingTasks.remove(at: index)
        }
        persistQueue()
    }

    private func updateFailure(for taskId: UUID, reason: String) {
        guard let index = pendingTasks.firstIndex(where: { $0.id == taskId }) else { return }
        pendingTasks[index].attempts += 1
        pendingTasks[index].lastAttemptAt = .now
        pendingTasks[index].failureReason = String(reason.prefix(140))
        lastSyncError = pendingTasks[index].failureReason
        persistQueue()
    }

    private func stagedURL(_ fileName: String) -> URL {
        stagingDirectory.appending(path: fileName)
    }

    // MARK: - Persistence

    private func persistQueue() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(pendingTasks) {
            try? data.write(to: queueURL, options: .atomic)
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pendingTasks = (try? decoder.decode([PendingUploadTask].self, from: data)) ?? []
    }

    // MARK: - Account deletion support

    /// Wipes staged uploads and the durable queue (`PrivacyComplianceManager`).
    func purgePendingData() {
        drainTask?.cancel()
        drainTask = nil
        pendingTasks.removeAll()
        persistQueue()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }
}

private extension Duration {
    static func min(_ lhs: Duration, rhs: Duration) -> Duration {
        lhs < rhs ? lhs : rhs
    }
}
