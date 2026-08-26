//
//  SaveAndFileSheet.swift
//  ScanVault
//

import SwiftUI

/// Bottom sheet that names the scan and chooses the folder it flies into.
struct SaveAndFileSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let pageCount: Int
    var initialTitle: String? = nil
    var initialFolderId: String? = nil
    let onCommit: (String, String) -> Void

    @State private var title: String
    @State private var folderId: String
    @FocusState private var isNameFocused: Bool

    init(
        pageCount: Int,
        initialTitle: String? = nil,
        initialFolderId: String? = nil,
        onCommit: @escaping (String, String) -> Void
    ) {
        self.pageCount = pageCount
        self.initialTitle = initialTitle
        self.initialFolderId = initialFolderId
        self.onCommit = onCommit
        _title = State(initialValue: initialTitle ?? ScannedDocument.timestampTitle())
        _folderId = State(initialValue: initialFolderId ?? AppFolder.inboxID)
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var targetFolder: AppFolder? {
        store.folder(withId: folderId)
    }

    var body: some View {
        ZStack {
            Theme.inkRaised.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Save & File")
                            .font(Theme.display(.title2))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(pageCount) \(pageCount == 1 ? "page" : "pages") ready to become a PDF")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.textTertiary)
                        if initialTitle != nil {
                            Label("Smart name applied — edit freely", systemImage: "sparkles")
                                .font(Theme.mono(.caption2))
                                .foregroundStyle(Theme.amber)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background { Circle().fill(Theme.surfaceHigh) }
                            .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 1) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Close without saving")
                }
                .padding(.top, 6)

                nameField

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "File into")

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.folders) { folder in
                                folderChip(folder)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 220)
                    .scrollBounceBehavior(.basedOnSize)
                }

                Spacer(minLength: 0)

                commitButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.inkRaised)
        .presentationContentInteraction(.scrolls)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Document name")

            HStack(spacing: 10) {
                Image(systemName: "textformat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isNameFocused ? Theme.amber : Theme.textTertiary)

                TextField("Document name", text: $title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.amber)
                    .focused($isNameFocused)
                    .submitLabel(.done)

                if !title.isEmpty {
                    Button {
                        title = ""
                        isNameFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear name")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isNameFocused ? Theme.amber.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 1)
            }
            .animation(Theme.snap, value: isNameFocused)
        }
    }

    private func folderChip(_ folder: AppFolder) -> some View {
        let isSelected = folder.id == folderId
        return Button {
            withAnimation(Theme.snap) { folderId = folder.id }
            Haptics.selection()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(folder.tint.opacity(isSelected ? 0.26 : 0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: folder.iconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(folder.tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(store.documentCount(in: folder))")
                        .font(Theme.mono(.caption2))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 0)

                if folder.isBiometricLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? folder.tint.opacity(0.10) : Color.white.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? folder.tint.opacity(0.8) : Color.white.opacity(0.06),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var commitButton: some View {
        Button {
            Haptics.impact()
            onCommit(title, folderId)
            dismiss()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: targetFolder?.iconName ?? "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("File to \(targetFolder?.name ?? "Inbox")")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(hex: "1A1206"))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.amberBright, Theme.amber],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .shadow(color: Theme.amber.opacity(0.32), radius: 16, y: 7)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .contentTransition(.opacity)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SaveAndFileSheet(pageCount: 3) { _, _ in }
                .environment(VaultStore.mock())
        }
        .preferredColorScheme(.dark)
}
