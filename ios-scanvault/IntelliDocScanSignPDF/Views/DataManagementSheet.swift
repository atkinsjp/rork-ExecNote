//
//  DataManagementSheet.swift
//  IntelliDocScanSignPDF
//

import SwiftUI

/// Guideline 5.1.1(v) user-controls screen: one-tap portable export and the
/// irreversible full account/data wipe.
struct DataManagementSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deletionReport: [String] = []

    var body: some View {
        ZStack {
            Theme.backdrop

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    exportSection
                    deletionSection

                    if !deletionReport.isEmpty {
                        reportCard(deletionReport)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Manage Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .confirmationDialog(
            "Delete everything?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Permanently Delete Everything", role: .destructive) {
                Haptics.warning()
                Task { await performDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all \(store.documents.count) documents, folders, transcriptions and signature assets — locally and in the cloud. This cannot be undone.")
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "EXPORT ALL MY DATA")

            VStack(spacing: 12) {
                Text("Generate a portable ZIP containing every scan PDF, transcription, AI note transform and metadata record created on this device. Nothing is uploaded during export.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label("Share Export Archive", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(hex: "1A1206"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background { Capsule().fill(Theme.amberBright) }
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))

                    Text("Saved as \((exportedURL.lastPathComponent as NSString).abbreviatingWithTildeInPath)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Button {
                        Haptics.impact(.light)
                        Task { await runExport() }
                    } label: {
                        HStack(spacing: 8) {
                            if isExporting {
                                ProgressView().tint(Theme.ink)
                            } else {
                                Image(systemName: "externaldrive.badge.timemachine")
                            }
                            Text(isExporting ? "Building archive…" : "Build Export Archive (.zip)")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background { Capsule().fill(Theme.amber) }
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .disabled(isExporting || store.documents.isEmpty)
                }

                if let exportError {
                    Text(exportError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "E2664F"))
                }
            }
            .padding(14)
            .cardSurface(cornerRadius: 16)
        }
    }

    // MARK: - Deletion

    private var deletionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "DANGER ZONE")

            VStack(spacing: 12) {
                Text("Permanently deletes every cloud record, local file, staged sync upload, signature asset, anonymous vault identifier and telemetry counter tied to this device's IntelliDocScanSignPDF install.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(role: .destructive) {
                    Haptics.warning()
                    showDeleteConfirmation = true
                } label: {
                    HStack(spacing: 8) {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Image(systemName: "trash.slash.fill")
                        }
                        Text(isDeleting ? "Erasing…" : "Delete Account & All Data")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background { Capsule().fill(Color(hex: "C0453B")) }
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .disabled(isDeleting)

                Text("You'll start completely fresh next launch — the welcome tour plays again because nothing remains to restore.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "C0453B").opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(hex: "C0453B").opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func reportCard(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Deletion complete", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(hex: "3FB0A0"))
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .tint(Theme.amber)
        }
        .padding(14)
        .cardSurface(cornerRadius: 16)
    }

    // MARK: - Actions

    private func runExport() async {
        defer { isExporting = false }
        isExporting = true
        exportError = nil
        do {
            exportedURL = try await PrivacyComplianceManager.shared.exportAllData(from: store)
            Haptics.success()
        } catch {
            exportError = error.localizedDescription
            Haptics.warning()
        }
    }

    private func performDeletion() async {
        isDeleting = true
        deletionReport = []
        let report = await PrivacyComplianceManager.shared.deleteAllAccountData(store: store)
        deletionReport = report.components(separatedBy: "\n")
        isDeleting = false
        Haptics.success()
    }
}

#Preview {
    NavigationStack {
        DataManagementSheet()
            .environment(VaultStore.mock())
    }
}
