//
//  FirebaseSyncService.swift
//  ScanVault
//

import Foundation
import OSLog

// MARK: - Configuration

/// Credentials required to talk to Cloud Firestore and Firebase Storage.
///
/// Values are injected as public environment variables at build time so no
/// secrets live in source control:
/// `EXPO_PUBLIC_FIREBASE_PROJECT_ID`, `EXPO_PUBLIC_FIREBASE_API_KEY`,
/// `EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET`.
nonisolated struct FirebaseConfiguration: Sendable, Equatable {
    let projectId: String
    let apiKey: String
    let storageBucket: String

    static func fromEnvironment() -> FirebaseConfiguration? {
        let values = Config.allValues
        let projectId = values["EXPO_PUBLIC_FIREBASE_PROJECT_ID"] ?? ""
        let apiKey = values["EXPO_PUBLIC_FIREBASE_API_KEY"] ?? ""
        let bucket = values["EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET"] ?? "\(projectId).appspot.com"

        guard !projectId.isEmpty, !apiKey.isEmpty else { return nil }
        return FirebaseConfiguration(projectId: projectId, apiKey: apiKey, storageBucket: bucket)
    }
}

nonisolated enum FirebaseSyncError: LocalizedError {
    case notConfigured
    case badResponse(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud sync is not configured yet. Your scans are saved on this device."
        case .badResponse(let code, let message):
            "The server rejected the request (\(code)). \(message)"
        case .transport(let reason):
            "Network problem: \(reason)"
        }
    }
}

/// A point-in-time view of the remote collections.
nonisolated struct RemoteSnapshot: Sendable, Equatable {
    var folders: [AppFolder]
    var documents: [ScannedDocument]

    static let empty = RemoteSnapshot(folders: [], documents: [])
}

// MARK: - Service

/// Uploads scanned PDFs to Firebase Storage, mirrors their metadata into Cloud
/// Firestore, and streams realtime updates back to the app.
///
/// Two backends are supported:
/// - `.live` — real Firestore + Storage REST endpoints.
/// - `.offline` — a no-network stub used by SwiftUI previews and by devices
///   where no Firebase credentials have been provided. Everything still works
///   locally; nothing leaves the device.
actor FirebaseSyncService {
    enum Backend: Sendable, Equatable {
        case live(FirebaseConfiguration)
        case offline
    }

    static let shared = FirebaseSyncService(
        backend: FirebaseConfiguration.fromEnvironment().map(Backend.live) ?? .offline
    )

    /// Offline instance for SwiftUI Canvas previews and unit tests.
    static let preview = FirebaseSyncService(backend: .offline)

    let backend: Backend
    private let session: URLSession
    private let logger = Logger(subsystem: "app.rork.scanvault", category: "sync")

    init(backend: Backend, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    var isConfigured: Bool {
        if case .live = backend { return true }
        return false
    }

    // MARK: Storage

    /// Uploads PDF bytes to `users/{userId}/documents/{documentId}.pdf`.
    /// - Returns: the storage object path that was written.
    @discardableResult
    func uploadPDF(
        _ data: Data,
        documentId: String,
        userId: String,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> String {
        let path = ScannedDocument.storagePath(userId: userId, documentId: documentId)

        guard case .live(let config) = backend else {
            // Offline backend: simulate a short deterministic ramp so the UI
            // still shows meaningful progress, then resolve.
            for step in 1...4 {
                try? await Task.sleep(for: .milliseconds(120))
                onProgress(Double(step) / 4.0)
            }
            return path
        }

        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .firebasePathAllowed),
              let url = URL(string: "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o?uploadType=media&name=\(encoded)")
        else { throw FirebaseSyncError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        do {
            let (body, response) = try await session.upload(for: request, from: data, delegate: delegate)
            try Self.validate(response: response, body: body)
            onProgress(1)
            return path
        } catch let error as FirebaseSyncError {
            throw error
        } catch {
            throw FirebaseSyncError.transport(error.localizedDescription)
        }
    }

    /// Public read URL for an uploaded object, when the bucket allows it.
    nonisolated func downloadURL(for storagePath: String) -> URL? {
        guard case .live(let config) = backend,
              let encoded = storagePath.addingPercentEncoding(withAllowedCharacters: .firebasePathAllowed)
        else { return nil }
        return URL(string: "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o/\(encoded)?alt=media")
    }

    func deletePDF(documentId: String, userId: String) async throws {
        guard case .live(let config) = backend else { return }
        let path = ScannedDocument.storagePath(userId: userId, documentId: documentId)
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .firebasePathAllowed),
              let url = URL(string: "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o/\(encoded)")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }

    // MARK: Firestore

    /// Writes document metadata to `users/{userId}/documents/{documentId}`.
    func saveDocumentMetadata(_ document: ScannedDocument, userId: String) async throws {
        try await patch(
            path: "users/\(userId)/documents/\(document.id)",
            fields: document.firestoreFields
        )
    }

    /// Writes folder metadata to `users/{userId}/folders/{folderId}`.
    func saveFolder(_ folder: AppFolder, userId: String) async throws {
        try await patch(
            path: "users/\(userId)/folders/\(folder.id)",
            fields: folder.firestoreFields
        )
    }

    func deleteDocumentMetadata(id: String, userId: String) async throws {
        try await delete(path: "users/\(userId)/documents/\(id)")
    }

    func deleteFolder(id: String, userId: String) async throws {
        try await delete(path: "users/\(userId)/folders/\(id)")
    }

    func fetchDocuments(userId: String) async throws -> [ScannedDocument] {
        try await list(path: "users/\(userId)/documents").compactMap(ScannedDocument.init(firestore:))
    }

    func fetchFolders(userId: String) async throws -> [AppFolder] {
        try await list(path: "users/\(userId)/folders").compactMap(AppFolder.init(firestore:))
    }

    func snapshot(userId: String) async throws -> RemoteSnapshot {
        guard isConfigured else { return .empty }
        async let folders = fetchFolders(userId: userId)
        async let documents = fetchDocuments(userId: userId)
        return try await RemoteSnapshot(folders: folders, documents: documents)
    }

    /// Emits a fresh snapshot of the folder + document collections whenever the
    /// remote data changes. Backed by a lightweight poll so it works without a
    /// persistent gRPC listen channel; the stream ends when the task is cancelled.
    nonisolated func realtimeUpdates(
        userId: String,
        every interval: Duration = .seconds(12)
    ) -> AsyncStream<RemoteSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                var previous: RemoteSnapshot?
                while !Task.isCancelled {
                    if let snapshot = try? await self.snapshot(userId: userId), snapshot != previous {
                        previous = snapshot
                        continuation.yield(snapshot)
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: REST plumbing

    private func documentsBaseURL(_ config: FirebaseConfiguration) -> String {
        "https://firestore.googleapis.com/v1/projects/\(config.projectId)/databases/(default)/documents"
    }

    private func patch(path: String, fields: [String: Any]) async throws {
        guard case .live(let config) = backend else { return }
        guard let url = URL(string: "\(documentsBaseURL(config))/\(path)?key=\(config.apiKey)") else {
            throw FirebaseSyncError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fields": fields])

        do {
            let (body, response) = try await session.data(for: request)
            try Self.validate(response: response, body: body)
        } catch let error as FirebaseSyncError {
            logger.error("Firestore write failed for \(path, privacy: .public)")
            throw error
        } catch {
            throw FirebaseSyncError.transport(error.localizedDescription)
        }
    }

    private func delete(path: String) async throws {
        guard case .live(let config) = backend else { return }
        guard let url = URL(string: "\(documentsBaseURL(config))/\(path)?key=\(config.apiKey)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }

    private func list(path: String) async throws -> [[String: Any]] {
        guard case .live(let config) = backend else { return [] }
        guard let url = URL(string: "\(documentsBaseURL(config))/\(path)?key=\(config.apiKey)&pageSize=300") else {
            return []
        }
        do {
            let (body, response) = try await session.data(from: url)
            try Self.validate(response: response, body: body)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let documents = json?["documents"] as? [[String: Any]] ?? []
            return documents.compactMap { $0["fields"] as? [String: Any] }
        } catch let error as FirebaseSyncError {
            throw error
        } catch {
            throw FirebaseSyncError.transport(error.localizedDescription)
        }
    }

    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: body.prefix(300), encoding: .utf8) ?? ""
            throw FirebaseSyncError.badResponse(http.statusCode, message)
        }
    }
}

// MARK: - Upload progress

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @Sendable @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

private extension CharacterSet {
    static let firebasePathAllowed: CharacterSet = .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
}

// MARK: - Firestore value mapping

nonisolated extension ScannedDocument {
    var firestoreFields: [String: Any] {
        [
            "id": ["stringValue": id],
            "title": ["stringValue": title],
            "folderId": ["stringValue": folderId],
            "storagePath": ["stringValue": storagePath],
            "pageCount": ["integerValue": String(pageCount)],
            "ocrKeywords": ["arrayValue": ["values": ocrKeywords.map { ["stringValue": $0] }]],
            "isRedacted": ["booleanValue": isRedacted],
            "redactionCount": ["integerValue": String(redactionCount)],
            "isSigned": ["booleanValue": isSigned],
            "signatureCount": ["integerValue": String(signatureCount)],
            "auditHash": ["stringValue": auditHash ?? ""],
            "docType": ["stringValue": docType ?? ""],
            "categoryTag": ["stringValue": categoryTag ?? ""],
            "noteTranscription": ["stringValue": noteTranscription ?? ""],
            "noteTransforms": ["arrayValue": ["values": noteTransforms.map { ["mapValue": ["fields": $0.firestoreFields]] }]],
            "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: createdAt)],
        ]
    }

    init?(firestore fields: [String: Any]) {
        guard let id = fields.firestoreString("id"),
              let title = fields.firestoreString("title")
        else { return nil }

        self.init(
            id: id,
            title: title,
            folderId: fields.firestoreString("folderId") ?? AppFolder.inboxID,
            storagePath: fields.firestoreString("storagePath") ?? "",
            localURL: nil,
            pageCount: fields.firestoreInt("pageCount") ?? 1,
            ocrKeywords: fields.firestoreStringArray("ocrKeywords"),
            createdAt: fields.firestoreDate("createdAt") ?? .now,
            isRedacted: fields.firestoreBool("isRedacted") ?? false,
            redactionCount: fields.firestoreInt("redactionCount") ?? 0,
            isSigned: fields.firestoreBool("isSigned") ?? false,
            signatureCount: fields.firestoreInt("signatureCount") ?? 0,
            auditHash: fields.firestoreString("auditHash"),
            docType: fields.firestoreString("docType"),
            categoryTag: fields.firestoreString("categoryTag"),
            noteTranscription: fields.firestoreNonEmptyString("noteTranscription"),
            noteTransforms: fields.firestoreMapArray("noteTransforms").compactMap(NoteTransformRecord.init(firestore:))
        )
    }
}

nonisolated extension AppFolder {
    var firestoreFields: [String: Any] {
        [
            "id": ["stringValue": id],
            "name": ["stringValue": name],
            "iconName": ["stringValue": iconName],
            "colorHex": ["stringValue": colorHex],
            "isBiometricLocked": ["booleanValue": isBiometricLocked],
            "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: createdAt)],
        ]
    }

    init?(firestore fields: [String: Any]) {
        guard let id = fields.firestoreString("id"),
              let name = fields.firestoreString("name")
        else { return nil }

        self.init(
            id: id,
            name: name,
            iconName: fields.firestoreString("iconName") ?? "folder.fill",
            colorHex: fields.firestoreString("colorHex") ?? "E8A33D",
            isBiometricLocked: fields.firestoreBool("isBiometricLocked") ?? false,
            createdAt: fields.firestoreDate("createdAt") ?? .now
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func firestoreString(_ key: String) -> String? {
        (self[key] as? [String: Any])?["stringValue"] as? String
    }

    /// String field where the empty string is treated as absent.
    func firestoreNonEmptyString(_ key: String) -> String? {
        guard let value = firestoreString(key), !value.isEmpty else { return nil }
        return value
    }

    /// Array of embedded Firestore maps (e.g. AI note variations).
    func firestoreMapArray(_ key: String) -> [[String: Any]] {
        guard let wrapper = (self[key] as? [String: Any])?["arrayValue"] as? [String: Any],
              let values = wrapper["values"] as? [[String: Any]]
        else { return [] }
        return values.compactMap { $0["mapValue"] as? [String: Any] }
            .compactMap { $0["fields"] as? [String: Any] }
    }

    func firestoreInt(_ key: String) -> Int? {
        guard let raw = (self[key] as? [String: Any])?["integerValue"] else { return nil }
        if let text = raw as? String { return Int(text) }
        return raw as? Int
    }

    func firestoreBool(_ key: String) -> Bool? {
        (self[key] as? [String: Any])?["booleanValue"] as? Bool
    }

    func firestoreStringArray(_ key: String) -> [String] {
        guard let wrapper = (self[key] as? [String: Any])?["arrayValue"] as? [String: Any],
              let values = wrapper["values"] as? [[String: Any]]
        else { return [] }
        return values.compactMap { $0["stringValue"] as? String }
    }

    func firestoreDate(_ key: String) -> Date? {
        guard let text = (self[key] as? [String: Any])?["timestampValue"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
