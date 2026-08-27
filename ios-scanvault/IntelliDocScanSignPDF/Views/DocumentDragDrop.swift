//
//  DocumentDragDrop.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UniformTypeIdentifiers

/// Custom process-local payload identifying an IntelliDoc document during
/// in-app drags. Exported so drop receivers can request it explicitly; the
/// PDF file itself rides along as a standard file-url representation for
/// third-party drop targets (Files, Mail, Messages…).
nonisolated extension UTType {
    static let intellidocDocument = UTType(exportedAs: "io.intellidoc.document")
}

/// Keeps an active drag session visible to SwiftUI: dims the source row and
/// lights up the folder tile currently under the finger.
@MainActor
@Observable
final class DocumentDragRelay {
    static let shared = DocumentDragRelay()

    private(set) var draggingDocumentId: String?
    private(set) var hoveredFolderId: String?

    private init() {}

    func begin(_ documentId: String) {
        draggingDocumentId = documentId
    }

    func hover(_ folderId: String?) {
        hoveredFolderId = folderId
    }

    func end() {
        draggingDocumentId = nil
        hoveredFolderId = nil
    }
}

enum DocumentDragDrop {

    /// Builds the drag payload for one document. The custom identifier drives
    /// in-app filing; `NSItemProvider(contentsOf:)` exposes the flattened PDF
    /// as a plain file that any receiving app can ingest.
    static func provider(for document: ScannedDocument) -> NSItemProvider {
        let provider: NSItemProvider
        if let url = resolvePDFURL(for: document) {
            provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } else {
            provider = NSItemProvider()
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.intellidocDocument.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(document.id.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    /// Resolves the on-disk PDF synchronously (drag callbacks are sync):
    /// prefers the persisted location, falls back to the deterministic
    /// `PDFManager` cache path (Caches/ScannedDocuments/<id>.pdf).
    private static func resolvePDFURL(for document: ScannedDocument) -> URL? {
        if let localURL = document.localURL,
           FileManager.default.fileExists(atPath: localURL.path()) {
            return localURL
        }
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "ScannedDocuments", directoryHint: .isDirectory)
            .appending(path: "\(document.id).pdf")
        return FileManager.default.fileExists(atPath: url.path()) ? url : nil
    }
}

// MARK: - Row-side modifiers

/// Attaches a long-press drag to any document row: payload carries the in-app
/// identifier plus the PDF for external drop targets, and the relay dims the
/// row for the duration of the lift.
///
/// Because SwiftUI offers no cancellation hook for an abandoned drag, the
/// lifted state self-expires shortly after `end()` was missed by cancelled
/// gestures — see the guarded delay below.
struct IntelliDocDragModifier: ViewModifier {
    let document: ScannedDocument

    @State private var relay = DocumentDragRelay.shared

    private var isLifted: Bool { relay.draggingDocumentId == document.id }

    func body(content: Content) -> some View {
        content
            .opacity(isLifted ? 0.35 : 1)
            .scaleEffect(isLifted ? 0.97 : 1)
            .animation(Theme.soft, value: isLifted)
            .onDrag {
                Haptics.impact(.light)
                relay.begin(document.id)
                scheduleAutoExpire()
                return DocumentDragDrop.provider(for: document)
            }
    }

    /// Safety net so an outward-cancelled drag can't leave a ghosted row.
    private func scheduleAutoExpire() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            if relay.draggingDocumentId == document.id {
                relay.end()
            }
        }
    }
}

extension View {
    /// Enables cross-folder + out-of-app dragging on a document row.
    func intelliDocDrag(_ document: ScannedDocument) -> some View {
        modifier(IntelliDocDragModifier(document: document))
    }

    /// Accepts dropped IntelliDoc documents and files them into `folder`.
    ///
    /// - Parameters:
    ///   - onHover: drives the folder tile highlight (true = finger over it).
    ///   - resolve: finds the document matching the payload id (nil = stale).
    ///   - onMove: performs the actual re-filing; runs on the main actor.
    func folderDropTarget(
        _ folder: AppFolder,
        relay: DocumentDragRelay = .shared,
        onHover: @escaping (Bool) -> Void,
        resolve: @escaping (String) -> ScannedDocument?,
        onMove: @escaping (ScannedDocument, AppFolder) -> Void
    ) -> some View {
        onDrop(
            of: [UTType.intellidocDocument],
            delegate: FolderDropDelegate(
                folder: folder,
                relay: relay,
                onHover: onHover,
                resolve: resolve,
                onMove: onMove
            )
        )
    }
}

// MARK: - Folder receiver

/// Handles every phase of a drop on a folder tile: enter/exit highlighting
/// and the actual filing on release. Sealed (Face ID) folders still accept
/// drops — moving a document into them reveals nothing about their contents.
struct FolderDropDelegate: DropDelegate {
    let folder: AppFolder
    let relay: DocumentDragRelay
    let onHover: (Bool) -> Void
    let resolve: (String) -> ScannedDocument?
    let onMove: (ScannedDocument, AppFolder) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.intellidocDocument])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        relay.hover(folder.id)
        onHover(true)
        Haptics.selection()
    }

    func dropExited(info: DropInfo) {
        relay.hover(nil)
        onHover(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        relay.end()
        onHover(false)

        guard let provider = info.itemProviders(for: [.intellidocDocument]).first else {
            return false
        }

        // NSString.loadObject bridges asynchronously; bounce back to the
        // main actor before touching vault state.
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in
                if let document = resolve(id) {
                    onMove(document, folder)
                }
            }
        }
        return true
    }
}
