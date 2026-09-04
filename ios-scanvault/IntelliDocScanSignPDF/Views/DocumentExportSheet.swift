//
//  DocumentExportSheet.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UIKit

// MARK: - Activity view bridge

/// Native `UIActivityViewController` wrapper (AirDrop, Files, Mail, WhatsApp…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Export sheet

/// Export preview: format picker, compression presets with before/after size
/// estimates, a live progress ring during optimization, then the native share
/// sheet.
struct DocumentExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    @State private var format: ExportFormat = .pdf
    @State private var preset: CompressionPreset = .email
    @State private var pageOrder: [Int]?
    @State private var originalSize: Int64 = 0
    @State private var estimatedSize: Int64?
    @State private var isEstimating = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var sharedURL: URL?
    @State private var errorMessage: String?

    private let coordinator = DocumentExportCoordinator.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        pagesSection
                        formatSection
                        if format == .pdf {
                            presetSection
                            sizeEstimate
                        }
                        exportButton
                        footnote
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Export & Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .overlay {
                if isExporting {
                    progressOverlay
                }
            }
            .sheet(item: $sharedURL) { url in
                ShareSheet(items: [url])
                    .ignoresSafeArea()
            }
            .task { await loadSizes() }
            .onChange(of: preset) { _, _ in
                Task { await estimate() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(document.title, systemImage: "square.and.arrow.up.fill")
                .font(Theme.display(.headline))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text(headerMeta)
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var headerMeta: String {
        var meta = "\(document.pageCount) pages · flattened export — redactions & signatures burned in"
        if pageOrder != nil { meta += " · custom order" }
        return meta
    }

    /// Draggable page thumbnails; the chosen arrangement flows into the export.
    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Pages")
            PageReorderGrid(document: document) { order in
                pageOrder = order
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Format")

            VStack(spacing: 10) {
                ForEach(ExportFormat.allCases) { option in
                    formatRow(option)
                }
            }
        }
    }

    private func formatRow(_ option: ExportFormat) -> some View {
        let isSelected = format == option
        return Button {
            Haptics.selection()
            withAnimation(Theme.snap) { format = option }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Theme.amber.opacity(0.14) : Color.white.opacity(0.04))
                        .frame(width: 40, height: 40)
                    Image(systemName: option.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(option.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? Theme.amber.opacity(0.06) : Color.white.opacity(0.02))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(isSelected ? Theme.amber.opacity(0.7) : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Compression", trailing: preset.targetLabel)

            VStack(spacing: 10) {
                ForEach(CompressionPreset.allCases) { option in
                    presetRow(option)
                }
            }
        }
    }

    private func presetRow(_ option: CompressionPreset) -> some View {
        let isSelected = preset == option
        return Button {
            Haptics.impact(.medium)
            withAnimation(Theme.snap) { preset = option }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Theme.amber.opacity(0.14) : Color.white.opacity(0.04))
                        .frame(width: 40, height: 40)
                    Image(systemName: option.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(option.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? Theme.amber.opacity(0.06) : Color.white.opacity(0.02))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(isSelected ? Theme.amber.opacity(0.7) : Theme.hairline, lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var sizeEstimate: some View {
        HStack(spacing: 12) {
            sizeBlock(
                label: "CURRENT",
                value: ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file)
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textTertiary)

            sizeBlock(
                label: "ESTIMATED",
                value: isEstimating
                    ? "…"
                    : (estimatedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            )
            Spacer()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 15).fill(Theme.surface)
        }
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Theme.hairline, lineWidth: 1) }
    }

    private func sizeBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.mono(.caption2, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var exportButton: some View {
        Button {
            Task { await export() }
        } label: {
            Label("Prepare & Share", systemImage: "square.and.arrow.up.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                    )
                }
        }
        .buttonStyle(PressableStyle(scale: 0.97))
    }

    private var footnote: some View {
        Text("The exported PDF is a fresh, flattened copy — your original stays untouched in the vault.")
            .font(Theme.mono(.caption2))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 8)
    }

    // MARK: - Progress ring

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressRingView(progress: exportProgress)
                    .frame(width: 88, height: 88)
                Text(exportProgressLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(30)
            .cardSurface(cornerRadius: 24)
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private var exportProgressLabel: String {
        switch format {
        case .pdf: "Optimizing PDF…"
        case .imagePack: "Zipping high-res pages…"
        case .text: "Transcribing pages…"
        }
    }

    // MARK: - Data

    private func loadSizes() async {
        var url: URL? = document.localURL
        if url == nil {
            url = await PDFManager.shared.existingURL(documentId: document.id)
        }
        if let url {
            originalSize = await PDFCompressionService.shared.originalSize(url: url)
            await estimate()
        } else if format == .pdf {
            errorMessage = ExportError.noSource.localizedDescription
        }
    }

    private func estimate() async {
        guard format == .pdf else {
            estimatedSize = nil
            return
        }
        var url: URL? = document.localURL
        if url == nil {
            url = await PDFManager.shared.existingURL(documentId: document.id)
        }
        guard let url else {
            estimatedSize = nil
            return
        }
        isEstimating = true
        let estimate = await PDFCompressionService.shared.estimateCompressedSize(url: url, preset: preset)
        withAnimation(Theme.snap) {
            estimatedSize = estimate
            isEstimating = false
        }
    }

    private func export() async {
        guard !isExporting else { return }
        Haptics.impact(.medium)
        isExporting = true
        exportProgress = 0.05

        // Animate the ring while the work runs.
        let ticker = Task {
            while !Task.isCancelled && exportProgress < 0.92 {
                try? await Task.sleep(for: .milliseconds(90))
                exportProgress = min(0.92, exportProgress + 0.03)
            }
        }

        do {
            let url = try await coordinator.buildExport(
                document: document,
                format: format,
                preset: preset,
                pageOrder: pageOrder
            )
            ticker.cancel()
            exportProgress = 1
            Haptics.success()
            try? await Task.sleep(for: .milliseconds(280))
            isExporting = false
            sharedURL = url
        } catch {
            ticker.cancel()
            isExporting = false
            Haptics.warning()
            errorMessage = error.localizedDescription
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Progress ring

/// Circular progress ring used while optimizing an export.
struct ProgressRingView: View {
    var progress: Double
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.amber.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(
                    Theme.amber,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(Theme.snap, value: progress)

            Image(systemName: "doc.zipper")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.amber)
        }
    }
}

#Preview {
    DocumentExportSheet(document: ScannedDocument.mockList[0])
        .preferredColorScheme(.dark)
}
