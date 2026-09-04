//
//  FolderDetailView.swift
//  IntelliDocScanSignPDF
//

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Contents of a single folder. Folders marked private stay sealed until the
/// user clears a Face ID / passcode check.
struct FolderDetailView: View {
    @Environment(VaultStore.self) private var store
    @Environment(VaultLockManager.self) private var locks
    @Environment(ScannerManager.self) private var scanner
    @Environment(\.dismiss) private var dismiss

    let folder: AppFolder

    /// Shared navigation path from the dashboard stack — document taps push
    /// `.document` routes exactly like the dashboard rows do.
    @Binding var path: [VaultRoute]

    /// Zoom transition namespace owned by the dashboard's navigation stack —
    /// registered on each row so tapping a document morphs it into the detail
    /// view instead of using the default push.
    let sourceNamespace: Namespace.ID

    @State private var isEditing = false

    // Multi-select mode for bulk document actions.
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var isConfirmingSelectionDelete = false

    // Bulk ZIP export of the current selection.
    @State private var isExportingZip = false
    @State private var sharedZipURL: URL?
    @State private var isShowingZipError = false
    @State private var zipExportErrorMessage = ""

    // Upload flow — camera capture and photo import preset to this folder.
    @State private var isUploading = false
    @State private var isShowingCamera = false
    @State private var isImportingPhotos = false
    @State private var isImportingFiles = false
    @State private var isShowingReview = false
    @State private var photoSelection: [PhotosPickerItem] = []

    private var isUnlocked: Bool {
        !locks.isLocked(folder)
    }

    private var contents: [ScannedDocument] {
        store.documents(in: folder).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            if !isUnlocked {
                lockedGate
            } else {
                contentList
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        Haptics.selection()
                        if isSelecting {
                            exitSelection()
                        } else {
                            withAnimation(Theme.soft) { isSelecting = true }
                        }
                    } label: {
                        Image(systemName: isSelecting ? "checkmark.circle.fill" : "checklist")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSelecting ? Theme.amber : Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(isSelecting ? "Exit selection mode" : "Select documents")

                    Button {
                        Haptics.selection()
                        isUploading = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "1A1206"))
                            .frame(width: 32, height: 32)
                            .background { Circle().fill(Theme.amber) }
                            .shadow(color: Theme.amber.opacity(0.35), radius: 8, y: 3)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Add scan to \(folder.name)")

                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Folder settings")
                }
            }
        }
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .sheet(isPresented: $isEditing) {
            FolderEditorSheet(existing: folder)
        }
        .confirmationDialog(
            "Add to “\(folder.name)”",
            isPresented: $isUploading,
            titleVisibility: .visible
        ) {
            Button {
                startCameraCapture()
            } label: {
                Label("Scan with Camera", systemImage: "doc.viewfinder")
            }
            Button {
                isImportingPhotos = true
            } label: {
                Label("Import from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                isImportingFiles = true
            } label: {
                Label("Choose from Files", systemImage: "folder")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New pages are filed straight into this folder.")
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCaptureView(
                onFinish: { images in
                    scanner.finish(with: images, source: .camera)
                    // Wait for the camera cover to finish dismissing before
                    // presenting review, or the review cover can't dismiss.
                    isShowingCamera = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.5))
                        isShowingReview = true
                    }
                },
                onCancel: {
                    scanner.cancel()
                    isShowingCamera = false
                },
                onError: { error in
                    scanner.fail(error)
                    isShowingCamera = false
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingReview) {
            ScanReviewView(presetFolderId: folder.id) { _ in
                isShowingReview = false
                Haptics.success()
            }
        }
        .photosPicker(
            isPresented: $isImportingPhotos,
            selection: $photoSelection,
            maxSelectionCount: 12,
            matching: .images
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.image, .pdf, DocxImportService.docxType],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await importFiles(urls) }
            }
        }
        .task {
            guard locks.isLocked(folder) else { return }
            await unlock()
        }
    }

    // MARK: - Upload

    /// Prominent upload entry shown above the document list.
    private var uploadRow: some View {
        Button {
            Haptics.selection()
            isUploading = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.amber.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload to this folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Scan or import straight into \(folder.name)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.amber)
            }
            .padding(14)
            .cardSurface(cornerRadius: 20)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityLabel("Upload documents into \(folder.name)")
    }

    private func startCameraCapture() {
        Haptics.impact(.light)
        scanner.reset()
        if scanner.isDocumentCameraAvailable {
            scanner.beginCapture()
            isShowingCamera = true
        } else {
            isImportingPhotos = true
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        photoSelection = []
        guard !images.isEmpty else { return }
        scanner.load(images, source: .photoImport)
        presentReviewAfterImportDismissal()
    }

    /// Turns Files-picked PDFs and images into session pages, then routes them
    /// through the standard review flow.
    private func importFiles(_ urls: [URL]) async {
        var images: [UIImage] = []
        for url in urls {
            guard !url.hasDirectoryPath else { continue }
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            if url.pathExtension.lowercased() == "pdf" {
                // PDFManager is an actor, so rasterization runs off-main.
                let pages = (try? await PDFManager.shared.pageImages(for: url)) ?? []
                images.append(contentsOf: pages)
            } else if url.pathExtension.lowercased() == "docx" {
                // Word text is laid out into pages off-main by DocxImportService.
                let pages = (try? await DocxImportService.pages(for: url)) ?? []
                images.append(contentsOf: pages)
            } else if let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) {
                images.append(image)
            }
        }
        guard !images.isEmpty else {
            Haptics.warning()
            return
        }
        Haptics.success()
        scanner.load(images, source: .fileImport)
        presentReviewAfterImportDismissal()
    }

    /// Pickers are sheets — presenting the review cover while the picker is
    /// still dismissing leaves the review's close button unable to dismiss.
    /// Close the pickers, wait out the dismissal, then present review.
    private func presentReviewAfterImportDismissal() {
        isImportingPhotos = false
        isImportingFiles = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            isShowingReview = true
        }
    }

    // MARK: - Locked state

    private var lockedGate: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(folder.tint.opacity(0.12))
                    .frame(width: 108, height: 108)
                Image(systemName: BiometricAuthService.symbolName)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(folder.tint)
                    .symbolEffect(.pulse, isActive: locks.isAuthenticating)
            }

            VStack(spacing: 6) {
                Text("\(folder.name) is locked")
                    .font(Theme.display(.title2))
                    .foregroundStyle(Theme.textPrimary)
                Text(lockError ?? "Unlock with \(BiometricAuthService.biometryLabel) to view \(contents.count) filed \(contents.count == 1 ? "document" : "documents").")
                    .font(.subheadline)
                    .foregroundStyle(lockError == nil ? Theme.textSecondary : Color(hex: "E2664F"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button {
                Task { await unlock() }
            } label: {
                Text("Unlock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1206"))
                    .frame(width: 180, height: 50)
                    .background { Capsule().fill(Theme.amber) }
            }
            .buttonStyle(PressableStyle())
            .disabled(locks.isAuthenticating)
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var lockError: String? {
        locks.lastError
    }

    private func unlock() async {
        guard await locks.unlock(folder) else {
            Haptics.warning()
            return
        }
        // Success haptic + spring reveal of the vault contents.
        Haptics.success()
    }

    // MARK: - Contents

    private var contentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                uploadRow

                if contents.isEmpty {
                    VaultEmptyState(
                        title: "Empty folder",
                        message: "Scans you file here will show up in this list.",
                        symbol: "tray"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(contents) { document in
                            if isSelecting {
                                DocumentRow(
                                    document: document,
                                    isSelectionMode: true,
                                    isSelected: selectedIds.contains(document.id)
                                ) {
                                    toggleSelection(document.id)
                                }
                            } else {
                                DocumentRow(document: document) {
                                    path.append(.document(document))
                                }
                                .matchedTransitionSource(id: document.id, in: sourceNamespace)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                DocumentSelectionBar(
                    count: selectedIds.count,
                    isAllSelected: !contents.isEmpty && selectedIds.count == contents.count,
                    isExporting: isExportingZip,
                    onToggleAll: toggleSelectAll,
                    onExport: exportSelected,
                    onDelete: { isConfirmingSelectionDelete = true },
                    onCancel: exitSelection
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "Delete \(selectedIds.count) \(selectedIds.count == 1 ? "document" : "documents")?",
            isPresented: $isConfirmingSelectionDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedIds.count) \(selectedIds.count == 1 ? "Document" : "Documents")", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from this device and from your cloud vault.")
        }
        .onChange(of: isUnlocked) { _, unlocked in
            // A re-sealed folder hides its list — drop the selection with it.
            guard !unlocked else { return }
            isSelecting = false
            selectedIds.removeAll()
        }
        .sheet(item: $sharedZipURL) { url in
            ShareSheet(items: [url])
                .ignoresSafeArea()
        }
        .alert("Couldn't create archive", isPresented: $isShowingZipError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(zipExportErrorMessage)
        }
    }

    // MARK: - Multi-select

    private func toggleSelection(_ id: String) {
        Haptics.selection()
        withAnimation(Theme.snap) {
            if selectedIds.contains(id) {
                selectedIds.remove(id)
            } else {
                selectedIds.insert(id)
            }
        }
    }

    private func toggleSelectAll() {
        Haptics.selection()
        withAnimation(Theme.snap) {
            if selectedIds.count == contents.count {
                selectedIds.removeAll()
            } else {
                selectedIds = Set(contents.map(\.id))
            }
        }
    }

    private func deleteSelected() {
        let targets = store.documents.filter { selectedIds.contains($0.id) }
        guard !targets.isEmpty else { return }
        withAnimation(Theme.soft) { store.deleteDocuments(targets) }
        Haptics.warning()
        exitSelection()
    }

    private func exitSelection() {
        withAnimation(Theme.soft) { isSelecting = false }
        selectedIds.removeAll()
    }

    private func exportSelected() {
        guard !isExportingZip else { return }
        let targets = store.documents.filter { selectedIds.contains($0.id) }
        guard !targets.isEmpty else { return }
        Haptics.impact(.medium)
        isExportingZip = true
        Task {
            do {
                let archive = try await BulkZipExportService.buildZip(for: targets)
                isExportingZip = false
                Haptics.success()
                sharedZipURL = archive
            } catch {
                isExportingZip = false
                Haptics.warning()
                zipExportErrorMessage = error.localizedDescription
                isShowingZipError = true
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(folder.tint.opacity(0.16))
                    .frame(width: 52, height: 52)
                Image(systemName: folder.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(folder.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(Theme.display(.title3))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(contents.count) documents · \(contents.reduce(0) { $0 + $1.pageCount }) pages")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .cardSurface(cornerRadius: 20)
        .padding(.top, 6)
    }
}

#Preview {
    FolderDetailPreview()
}

private struct FolderDetailPreview: View {
    @Namespace private var zoomNamespace

    var body: some View {
        NavigationStack {
            FolderDetailView(
                folder: AppFolder.mockList[1],
                path: .constant([]),
                sourceNamespace: zoomNamespace
            )
        }
        .environment(VaultStore.mock())
        .preferredColorScheme(.dark)
    }
}
