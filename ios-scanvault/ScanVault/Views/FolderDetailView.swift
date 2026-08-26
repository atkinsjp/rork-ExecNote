//
//  FolderDetailView.swift
//  ScanVault
//

import SwiftUI

/// Contents of a single folder. Folders marked private stay sealed until the
/// user clears a Face ID / passcode check.
struct FolderDetailView: View {
    @Environment(VaultStore.self) private var store
    @Environment(VaultLockManager.self) private var locks
    @Environment(\.dismiss) private var dismiss

    let folder: AppFolder

    @State private var isEditing = false

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
                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Folder settings")
            }
        }
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .sheet(isPresented: $isEditing) {
            FolderEditorSheet(existing: folder)
        }
        .task {
            guard locks.isLocked(folder) else { return }
            await unlock()
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

                if contents.isEmpty {
                    VaultEmptyState(
                        title: "Empty folder",
                        message: "Scans you file here will show up in this list.",
                        symbol: "tray"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(contents) { document in
                            NavigationLink(value: VaultRoute.document(document)) {
                                DocumentRow(document: document) {}
                                    .allowsHitTesting(false)
                            }
                            .buttonStyle(PressableStyle(scale: 0.98))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
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
    NavigationStack {
        FolderDetailView(folder: AppFolder.mockList[1])
    }
    .environment(VaultStore.mock())
    .preferredColorScheme(.dark)
}
