//
//  AIPolishModalView.swift
//  ScanVault
//
//  "Transform Notes Into…" bottom sheet: format action cards, tone selector,
//  live-streaming AI preview with haptic pulses, and one-tap copy / DOCX / PDF.
//

import SwiftUI
import UIKit

struct AIPolishModalView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument
    let transcript: String

    /// Generation lifecycle.
    private enum Phase: Equatable {
        case idle
        case streaming
        case done(String)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var selectedFormat: NoteTransformFormat?
    @State private var tone: WritingTone = .professional
    @State private var streamingText = ""
    /// Completed variation shown in the preview (already persisted).
    @State private var previewRecord: NoteTransformRecord?
    @State private var shareItem: ShareItem?
    @State private var deviceExportItem: ShareItem?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var copiedTick = 0
    @State private var filedNotice: String?
    /// Bumped every few streamed tokens to fire haptic pulses.
    @State private var pulseTick = 0

    private var live: ScannedDocument {
        store.documents.first { $0.id == document.id } ?? document
    }

    private var previewText: String {
        if case .streaming = phase { return streamingText }
        if case .done(let text) = phase { return text }
        return previewRecord?.content ?? ""
    }

    private var isBusy: Bool {
        if case .streaming = phase { return true }
        return isExporting
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        formatGrid
                        toneSelector
                        if let exportError {
                            errorBanner(exportError)
                        }
                        previewCard(proxy: proxy)
                        if !live.noteTransforms.isEmpty {
                            savedVariations
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(item: $deviceExportItem) { item in
            DeviceFileExporter(url: item.url)
                .presentationDetents([.large])
                .ignoresSafeArea()
        }
        .onChange(of: filedNotice) { _, newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 0.3)) { filedNotice = nil }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pulseTick)
        .sensoryFeedback(.success, trigger: copiedTick)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("Transform Notes Into…")
                    .font(Theme.display(.headline))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text("Gemini 2.5 Flash rewrites your transcription into a finished document, streamed live below.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Format cards

    private var formatGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(NoteTransformFormat.allCases) { format in
                formatCard(format)
            }
        }
    }

    private func formatCard(_ format: NoteTransformFormat) -> some View {
        let isSelected = selectedFormat == format
        return Button {
            guard !isBusy else { return }
            Haptics.impact()
            selectedFormat = format
            previewRecord = nil
            generate(format)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: format.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.amberBright : Theme.amber)
                    .frame(width: 40, height: 40)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? Theme.amber.opacity(0.18) : Theme.amber.opacity(0.08))
                    }

                Text(format.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(format.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(PressableStyle())
        .cardSurface(cornerRadius: 18, highlighted: isSelected)
        .accessibilityLabel("\(format.title): \(format.subtitle)")
    }

    // MARK: - Tone selector

    private var toneSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "TONE")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WritingTone.allCases) { candidate in
                        let isSelected = tone == candidate
                        Button {
                            guard !isBusy else { return }
                            Haptics.selection()
                            tone = candidate
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: candidate.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(candidate.label)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(isSelected ? Theme.ink : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                Capsule().fill(isSelected ? Theme.amber : Theme.surfaceHigh)
                            }
                            .overlay {
                                Capsule().strokeBorder(
                                    isSelected ? Theme.amberBright : Theme.hairline,
                                    lineWidth: 1
                                )
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("\(candidate.label) tone")
                    }
                }
                .padding(.horizontal, 16)
            }
            .contentMargins(.horizontal, -16, for: .scrollContent)
        }
    }

    // MARK: - Live preview

    private func previewCard(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if case .streaming = phase {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.amber)
                    Text("WRITING")
                        .font(Theme.mono(.caption2, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.amber)
                } else if previewText.isEmpty {
                    Text("PREVIEW")
                        .font(Theme.mono(.caption2, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "3FB0A0"))
                    Text(previewRecord.map { "\($0.format.title) · \($0.tone.label)" } ?? "\(selectedFormat?.title ?? "") · \(tone.label)")
                        .font(Theme.mono(.caption2, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if !previewText.isEmpty {
                    Text("\(previewText.split(whereSeparator: \.isWhitespace).count) words")
                        .font(Theme.mono(.caption2))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if previewText.isEmpty {
                emptyPreview
            } else {
                ScrollView {
                    Text(previewText)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .id("stream-end")
                }
                .frame(maxHeight: 360)
                .overlay(alignment: .bottom) {
                    if case .streaming = phase {
                        LinearGradient(
                            colors: [.clear, Theme.surface],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 34)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isBusy ? Theme.amber.opacity(0.45) : Theme.hairline,
                    lineWidth: 1
                )
        }
        .onChange(of: streamingText) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("stream-end", anchor: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !previewText.isEmpty {
                VStack(spacing: 8) {
                    actionButtons
                    filingRow
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text("Pick a format above — your finished document streams in here in real time.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26)
        }
        .padding(.vertical, 34)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            actionButton("Copy", symbol: "doc.on.doc.fill", prominent: false) {
                UIPasteboard.general.string = previewText
                copiedTick &+= 1
                Haptics.success()
            }
            if activeFormat == .slideDeck {
                actionButton("PPTX", symbol: "rectangle.stack.fill", prominent: false, disabled: isExporting) {
                    export(.pptx)
                }
            } else {
                actionButton("DOCX", symbol: "doc.richtext.fill", prominent: false, disabled: isExporting) {
                    export(.docx)
                }
            }
            actionButton("PDF", symbol: "doc.badge.arrow.up.fill", prominent: true, disabled: isExporting) {
                export(.pdf)
            }
        }
    }

    /// The format currently on screen (a saved record wins over the selection).
    private var activeFormat: NoteTransformFormat? {
        previewRecord?.format ?? selectedFormat
    }

    /// Filing row: keep the output inside ScanVault, or export it to a
    /// user-chosen location on the device.
    private var filingRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    fileInApp()
                } label: {
                    Label("File in App (PDF)", systemImage: "tray.and.arrow.down")
                }
                Button {
                    fileToDevice()
                } label: {
                    Label(activeFormat == .slideDeck ? "Save to Device (PPTX)…" : "Save to Device (PDF)…",
                          systemImage: "iphone.and.arrow.forward")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("File Output")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(Theme.textPrimary)
                .background { Capsule().fill(Theme.surfaceHigh) }
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
            }
            .buttonStyle(PressableStyle())
            .disabled(isBusy)

            if let filedNotice {
                Text(filedNotice)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        prominent: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 6) {
                if disabled {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(prominent ? Theme.ink : Theme.textSecondary)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(prominent ? Theme.ink : Theme.textPrimary)
            .background {
                Capsule().fill(prominent ? Theme.amber : Theme.surfaceHigh)
            }
            .overlay {
                Capsule().strokeBorder(
                    prominent ? Theme.amberBright : Theme.hairline,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled || isBusy)
        .accessibilityLabel(title)
    }

    // MARK: - Saved variations

    private var savedVariations: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "SAVED VARIATIONS", trailing: "\(live.noteTransforms.count)")
            VStack(spacing: 8) {
                ForEach(live.noteTransforms.prefix(6)) { record in
                    Button {
                        guard !isBusy else { return }
                        Haptics.selection()
                        previewRecord = record
                        phase = .done(record.content)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: record.format.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.amber)
                                .frame(width: 34, height: 34)
                                .background {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Theme.amber.opacity(0.1))
                                }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.format.title)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(record.tone.label) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(Theme.mono(.caption2))
                                    .foregroundStyle(Theme.textTertiary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(PressableStyle())
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "E2664F"))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let selectedFormat, case .failed = phase {
                Button("Retry") {
                    generate(selectedFormat)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.amber)
            } else {
                Button("Dismiss") { exportError = nil }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 14)
    }

    // MARK: - Generation

    private func generate(_ format: NoteTransformFormat) {
        phase = .streaming
        streamingText = ""
        exportError = nil

        Task {
            do {
                let text = try await SmartTransformEngine.shared.transform(
                    text: transcript,
                    format: format,
                    tone: tone,
                    context: live.title
                ) { delta in
                    Task { @MainActor in
                        streamingText += delta
                        // Pulse roughly every 80 characters streamed.
                        if streamingText.count % 80 < delta.count {
                            pulseTick &+= 1
                        }
                    }
                }

                let record = NoteTransformRecord(
                    format: format,
                    tone: tone,
                    content: text
                )
                previewRecord = record
                phase = .done(text)
                await store.addTransform(record, for: live)
                Haptics.success()
            } catch {
                phase = .failed(error.localizedDescription)
                exportError = error.localizedDescription
                Haptics.warning()
            }
        }
    }

    /// Builds the on-disk artifact for a kind, shared by share/export/filing.
    private func makeFile(_ kind: DocumentExportEngine.Format) throws -> URL {
        guard let record = previewRecord else {
            throw DocumentExportEngine.ExportError.emptyContent
        }
        switch kind {
        case .docx:
            return try DocumentExportEngine.shared.exportDOCX(record: record, title: live.title)
        case .pdf:
            return try DocumentExportEngine.shared.exportPDF(record: record, title: live.title)
        case .pptx:
            return try DocumentExportEngine.shared.exportPPTX(record: record, title: live.title)
        }
    }

    private func export(_ kind: DocumentExportEngine.Format) {
        guard previewRecord != nil else { return }
        isExporting = true
        exportError = nil

        Task {
            do {
                shareItem = ShareItem(url: try makeFile(kind))
            } catch {
                exportError = error.localizedDescription
                Haptics.warning()
            }
            isExporting = false
        }
    }

    /// Files a PDF copy inside the app container (`Documents/Exports/`).
    private func fileInApp() {
        guard previewRecord != nil else { return }
        isExporting = true
        exportError = nil

        Task {
            do {
                let url = try makeFile(.pdf)
                let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appending(path: "Exports", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
                let destination = exports.appending(path: url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
                withAnimation { filedNotice = "Filed · Exports/\(destination.lastPathComponent)" }
                Haptics.success()
            } catch {
                exportError = error.localizedDescription
                Haptics.warning()
            }
            isExporting = false
        }
    }

    /// Hands the artifact to the system Files picker so the user can file it
    /// anywhere on the device or in iCloud Drive.
    private func fileToDevice() {
        guard previewRecord != nil else { return }
        isExporting = true
        exportError = nil

        Task {
            do {
                let kind: DocumentExportEngine.Format = activeFormat == .slideDeck ? .pptx : .pdf
                deviceExportItem = ShareItem(url: try makeFile(kind))
            } catch {
                exportError = error.localizedDescription
                Haptics.warning()
            }
            isExporting = false
        }
    }
}

// MARK: - Share wrapper

/// Identifiable URL wrapper so `.sheet(item:)` can present the share sheet.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// System Files picker in export mode: the user chooses where on the device
/// (or iCloud Drive) the generated file is filed.
private struct DeviceFileExporter: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: { dismiss() })
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Haptics.success()
            onDone()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDone()
        }
    }
}

#Preview {
    AIPolishModalView(
        document: ScannedDocument.mockList[0],
        transcript: "Kickoff — Sarah wants launch Oct 14. Budget approved 40k. Dev: API by Sept 2 (Marcus). Design mocks Friday (Lena)."
    )
    .environment(VaultStore.mock())
    .preferredColorScheme(.dark)
}
