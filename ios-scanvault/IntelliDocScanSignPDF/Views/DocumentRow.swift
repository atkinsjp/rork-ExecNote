//
//  DocumentRow.swift
//  IntelliDocScanSignPDF
//

import SwiftUI

/// A single scan in a list: paper thumbnail, title, metadata and sync status.
struct DocumentRow: View {
    @Environment(VaultStore.self) private var store

    let document: ScannedDocument
    var showsFolder: Bool = false
    /// Full-text match snippet shown under the metadata row (search results).
    var snippet: String?
    /// When true the row shows a leading check indicator and taps toggle
    /// selection instead of navigating (multi-select mode).
    var isSelectionMode: Bool = false
    /// Check state while `isSelectionMode` is active.
    var isSelected: Bool = false
    let action: () -> Void

    @State private var isConfirmingDelete = false

    /// Compact `#tag` badges — first two plus an overflow count — so tagged
    /// scans are recognizable at a glance in lists.
    @ViewBuilder
    private var tagBadges: some View {
        if !document.tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(document.tags.prefix(2), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .lineLimit(1)
                }
                if document.tags.count > 2 {
                    Text("+\(document.tags.count - 2)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags: " + document.tags.joined(separator: ", "))
        }
    }

    var body: some View {
        Group {
            if isSelectionMode {
                card
            } else {
                card
                    .intelliDocDrag(document)
                    .contextMenu { menuContent }
            }
        }
        .confirmationDialog(
            "Delete “\(document.title)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Document", role: .destructive) {
                withAnimation(Theme.soft) { store.delete(document) }
                Haptics.warning()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The PDF is removed from this device and from your cloud vault.")
        }
    }

    private var card: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if isSelectionMode {
                    selectionIndicator
                }
                PageThumbnail(
                    image: store.thumbnail(for: document),
                    pageCount: document.pageCount,
                    width: 46
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if showsFolder, let folder = store.folder(withId: document.folderId) {
                            HStack(spacing: 4) {
                                Image(systemName: folder.iconName)
                                    .font(.system(size: 9, weight: .semibold))
                                Text(folder.name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(folder.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background { Capsule().fill(folder.tint.opacity(0.14)) }
                        }

                        tagBadges

                        Text(document.pageSummary)
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textTertiary)

                        Text("·")
                            .foregroundStyle(Theme.textTertiary)

                        Text(document.createdAt, format: .relative(presentation: .named))
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }

                    if let snippet {
                        Text(snippet)
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 4)

                SyncChip(state: store.syncState(for: document), compact: true)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface.opacity(0.85))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelectionMode && isSelected
                            ? Theme.amber.opacity(0.55)
                            : Color.white.opacity(0.05),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var menuContent: some View {
        Group {
            ForEach(store.folders.filter { $0.id != document.folderId }) { folder in
                Button {
                    store.move(document, to: folder.id)
                    Haptics.selection()
                } label: {
                    Label("Move to \(folder.name)", systemImage: folder.iconName)
                }
            }
            Divider()
            if case .failed = store.syncState(for: document) {
                Button {
                    store.retryUpload(for: document)
                } label: {
                    Label("Retry Upload", systemImage: "arrow.clockwise.icloud")
                }
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Leading check indicator shown while multi-select is active.
    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? Theme.amber : Color.white.opacity(0.28),
                    lineWidth: 1.5
                )
            if isSelected {
                Circle().fill(Theme.amber)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1206"))
            }
        }
        .frame(width: 26, height: 26)
        .animation(Theme.snap, value: isSelected)
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Theme.backdrop
        VStack(spacing: 10) {
            ForEach(ScannedDocument.mockList) { document in
                DocumentRow(document: document, showsFolder: true) {}
            }
        }
        .padding(20)
    }
    .environment(VaultStore.mock())
    .preferredColorScheme(.dark)
}
