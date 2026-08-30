//
//  SignatureManagerView.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UIKit

/// Central manager for the saved signature kit: review, rename, delete and
/// draw reusable signatures without starting a signing session. Presented as
/// a sheet from Settings and from the signing editor's kit bar.
struct SignatureManagerView: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [SignatureProfile] = []
    @State private var previews: [UUID: UIImage] = [:]
    @State private var isLoading = true
    @State private var isDrawingNew = false
    @State private var isShowingPaywall = false
    @State private var isRenaming = false
    @State private var renameTargetId: UUID?
    @State private var draftTitle = ""
    @State private var deleteTarget: SignatureProfile?

    private var allowance: Int? {
        subscriptions.signatureProfileAllowance
    }

    private var allowanceText: String {
        guard let allowance else { return "Unlimited saved signatures · Pro" }
        return "\(profiles.count) of \(allowance) free signature slots used"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        allowanceCard
                        drawNewButton

                        if isLoading {
                            ProgressView()
                                .tint(Theme.amber)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 36)
                        } else if profiles.isEmpty {
                            VaultEmptyState(
                                title: "No signatures yet",
                                message: "Draw a signature once and reuse it on every document — initials and custom stamps too.",
                                symbol: "signature"
                            )
                        } else {
                            VStack(spacing: 10) {
                                ForEach(profiles) { profile in
                                    row(profile)
                                }
                            }
                        }

                        privacyNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Signature Kit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Close signature kit")
                }
            }
            .task { await reload() }
        }
        .sheet(isPresented: $isDrawingNew) {
            SignatureCanvasSheet { profile in
                handleNew(profile)
            }
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView()
                .environment(subscriptions)
        }
        .confirmationDialog(
            "Delete this signature?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete \(deleteTarget?.title ?? "signature")", role: .destructive) {
                confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("Documents already signed with it keep their burned-in ink — only the reusable kit entry is removed.")
        }
        .alert("Rename Signature", isPresented: $isRenaming) {
            TextField("Name", text: $draftTitle)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var allowanceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.amber)
                .frame(width: 40, height: 40)
                .background { Circle().fill(Theme.amber.opacity(0.14)) }

            VStack(alignment: .leading, spacing: 2) {
                Text(allowanceText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Stored in the encrypted app sandbox — they never leave this device.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var drawNewButton: some View {
        Button {
            Haptics.impact(.medium)
            isDrawingNew = true
        } label: {
            Label("Draw New Signature", systemImage: "pencil.tip.crop.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .leading, endPoint: .trailing)
                    )
                }
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }

    private var privacyNote: some View {
        Text("Signatures are readable only while your device is unlocked — the bitmaps are sealed whenever the phone locks.")
            .font(Theme.mono(.caption2))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }

    // MARK: - Row

    private func row(_ profile: SignatureProfile) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.paper)
                if let image = previews[profile.id] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                } else {
                    Image(systemName: profile.type.symbolName)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 96, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Text(profile.type.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background { Capsule().fill(Theme.amber.opacity(0.12)) }

                    Text(profile.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.mono(.caption2))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    startRename(profile)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Haptics.warning()
                    deleteTarget = profile
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Options for \(profile.title)")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: - Actions

    private func reload() async {
        let saved = await SignatureStorageService.shared.loadProfiles()
        profiles = saved

        var cache: [UUID: UIImage] = [:]
        for profile in saved {
            if let image = UIImage(data: profile.pngData) {
                cache[profile.id] = image
            }
        }
        previews = cache
        isLoading = false
    }

    private func handleNew(_ profile: SignatureProfile) {
        if let allowance, profiles.count >= allowance {
            Haptics.warning()
            isShowingPaywall = true
            return
        }
        Task {
            try? await SignatureStorageService.shared.save(profile)
            await reload()
            Haptics.success()
        }
    }

    private func startRename(_ profile: SignatureProfile) {
        Haptics.selection()
        renameTargetId = profile.id
        draftTitle = profile.title
        isRenaming = true
    }

    private func commitRename() {
        guard let id = renameTargetId,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }

        let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var updated = profiles[index]
        updated.title = trimmed

        Task {
            try? await SignatureStorageService.shared.save(updated)
            await reload()
        }
        Haptics.success()
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            await SignatureStorageService.shared.delete(profileId: target.id)
            await reload()
            Haptics.warning()
        }
    }
}

// MARK: - Preview

#Preview {
    SignatureManagerView()
        .environment(SubscriptionManager.previewInstance)
        .preferredColorScheme(.dark)
}
