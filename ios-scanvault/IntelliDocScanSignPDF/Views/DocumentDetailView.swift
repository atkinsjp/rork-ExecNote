//
//  DocumentDetailView.swift
//  IntelliDocScanSignPDF
//

import PDFKit
import SwiftUI
import UIKit

/// Full-page PDFKit reader with sync status, keywords and filing controls.
struct DocumentDetailView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isConfirmingDelete = false
    @State private var isRedacting = false
    @State private var isSigning = false
    @State private var isExporting = false
    @State private var isSearching = false
    @State private var isNotesStudio = false

    /// Drives PDFSelection highlighting + match navigation inside the reader.
    @State private var searchController = PDFSearchController()

    /// AI summary header lifecycle (done state lives on `live.aiSummary`).
    @State private var summaryPhase: SummaryPhase = .idle

    private var live: ScannedDocument {
        store.documents.first { $0.id == document.id } ?? document
    }

    private var fileURL: URL? {
        live.localURL
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                metaBar

                if showsSummaryHeader {
                    summaryHeader
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                if isSearching {
                    documentSearchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let fileURL {
                    PDFReader(url: fileURL, searchController: searchController)
                        .clipShape(.rect(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else {
                    VaultEmptyState(
                        title: "PDF not on this device",
                        message: "This scan lives in your cloud vault. Reconnect to download the pages again.",
                        symbol: "icloud.and.arrow.down"
                    )
                    Spacer()
                }

                if !live.ocrKeywords.isEmpty {
                    keywordStrip
                }
            }
        }
        .navigationTitle(live.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ink, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if fileURL != nil {
                    Button {
                        Haptics.selection()
                        withAnimation(Theme.snap) { isSearching.toggle() }
                        if !isSearching { searchController.clear() }
                    } label: {
                        Image(systemName: "text.magnifyingglass")
                    }
                    .accessibilityLabel("Search in document")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftTitle = live.title
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    if live.aiSummary != nil || liveHasOCR {
                        Button {
                            Task { await loadSummary(force: true) }
                        } label: {
                            Label("Regenerate Summary", systemImage: "sparkles")
                        }
                    }

                    if fileURL != nil {
                        Button {
                            isNotesStudio = true
                        } label: {
                            Label("Notes Studio", systemImage: "wand.and.stars")
                        }

                        Button {
                            isSigning = true
                        } label: {
                            Label("Sign & Finalize", systemImage: "signature")
                        }

                        Button {
                            isRedacting = true
                        } label: {
                            Label("Redact & Sanitize", systemImage: "eye.slash")
                        }
                    }

                    if fileURL != nil {
                        Button {
                            isExporting = true
                        } label: {
                            Label("Export & Share", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Quick Share (original)", systemImage: "arrowshape.turn.up.right")
                        }
                    }

                    Menu("Move to") {
                        ForEach(store.folders.filter { $0.id != live.folderId }) { folder in
                            Button {
                                store.move(live, to: folder.id)
                                Haptics.selection()
                            } label: {
                                Label(folder.name, systemImage: folder.iconName)
                            }
                        }
                    }

                    if case .failed = store.syncState(for: live) {
                        Button {
                            store.retryUpload(for: live)
                        } label: {
                            Label("Retry Upload", systemImage: "arrow.clockwise.icloud")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Document actions")
            }
        }
        .alert("Rename document", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
            Button("Save") { store.rename(live, to: draftTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(live)
                Haptics.warning()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isRedacting) {
            DocumentRedactionView(document: live)
        }
        .sheet(isPresented: $isSigning) {
            PDFSigningEditorView(document: live)
        }
        .sheet(isPresented: $isExporting) {
            DocumentExportSheet(document: live)
        }
        .sheet(isPresented: $isNotesStudio) {
            TranscriptionReviewView(document: live)
        }
        // Auto-summarize once per document visit when no sentence exists yet.
        .task(id: live.id) {
            guard live.aiSummary == nil, summaryPhase == .idle, liveHasOCR else { return }
            await loadSummary(force: false)
        }
    }

    // MARK: - AI summary header

    private enum SummaryPhase: Equatable {
        case idle
        case generating
        case failed
    }

    private var metaBar: some View {
        HStack(spacing: 10) {
            if let folder = store.folder(withId: live.folderId) {
                HStack(spacing: 5) {
                    Image(systemName: folder.iconName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(folder.tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background { Capsule().fill(folder.tint.opacity(0.14)) }
            }

            Text(live.pageSummary)
                .font(Theme.mono(.caption2))
                .foregroundStyle(Theme.textTertiary)

            if live.isRedacted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Redacted · \(live.redactionCount)")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "3FB0A0"))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background { Capsule().fill(Color(hex: "3FB0A0").opacity(0.14)) }
            }

            if live.isSigned {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Signed · \(live.signatureCount)")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background { Capsule().fill(Theme.amber.opacity(0.14)) }
            }

            if live.noteTranscription != nil {
                HStack(spacing: 5) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Notes")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "8A7CE0"))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background { Capsule().fill(Color(hex: "8A7CE0").opacity(0.14)) }
            }

            Spacer(minLength: 0)

            SyncChip(state: store.syncState(for: live))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Whether the AI summary card should render at all.
    private var showsSummaryHeader: Bool {
        live.aiSummary != nil || summaryPhase == .generating
            || (summaryPhase == .failed && liveHasOCR)
    }

    private var liveHasOCR: Bool {
        !(live.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Runs generation through the store and settles the local phase. The
    /// store deduplicates against already-stored summaries unless forced.
    private func loadSummary(force: Bool) async {
        summaryPhase = .generating
        let updated = await store.generateSummary(for: live, force: force)
        withAnimation(Theme.soft) {
            summaryPhase = updated?.aiSummary != nil ? .idle : .failed
        }
        Haptics.selection()
    }

    /// Amber sparkle card pinned above the reader: finished sentence,
    /// scanning-beam while generating, retry pill when the call failed.
    @ViewBuilder
    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.amberBright)

                Text("AI SUMMARY")
                    .font(Theme.mono(.caption2, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textTertiary)

                Spacer(minLength: 0)

                if summaryPhase == .generating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.amber)
                } else if summaryPhase == .failed {
                    Button {
                        Haptics.selection()
                        Task { await loadSummary(force: true) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.amberBright)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background { Capsule().fill(Theme.amber.opacity(0.14)) }
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            switch summaryPhase {
            case .generating:
                Text("Reading your scan…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            case .failed:
                Text("Couldn’t generate a summary for this scan.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            case .idle:
                Text(live.aiSummary ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        // Scanner light sweeps the card while the sentence is being written.
        .scanSweep(active: summaryPhase == .generating)
        .accessibilityElement(children: .combine)
    }

    // MARK: - In-document search

    /// Search field with "Match 2 of 7" counter and prev/next navigation.
    private var documentSearchBar: some View {
        @Bindable var search = searchController
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchController.matchCount > 0 ? Theme.amber : Theme.textTertiary)

            TextField("Find in document", text: $search.query)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.amber)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onChange(of: searchController.query) { _, _ in
                    searchController.scheduleSearch()
                }

            if searchController.matchCount > 0 {
                Text("Match \(searchController.currentMatch + 1) of \(searchController.matchCount)")
                    .font(Theme.mono(.caption2, weight: .semibold))
                    .foregroundStyle(Theme.amberBright)
                    .fixedSize()

                Button {
                    Haptics.selection()
                    searchController.goToPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Theme.surfaceHigh) }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Previous match")

                Button {
                    Haptics.selection()
                    searchController.goToNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Theme.surfaceHigh) }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Next match")
            }

            Button {
                searchController.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var keywordStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("READ ON DEVICE")
                .font(Theme.mono(.caption2, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(live.ocrKeywords.prefix(16), id: \.self) { keyword in
                        Text(keyword)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background { Capsule().fill(Color.white.opacity(0.05)) }
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
                    }
                }
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
        .padding(.bottom, 16)
    }
}

// MARK: - In-document search controller

/// Finds `PDFSelection` matches, highlights them on the PDF canvas and walks
/// the user through them with prev/next navigation.
@MainActor
@Observable
final class PDFSearchController {
    var query = ""
    private(set) var matchCount = 0
    private(set) var currentMatch = 0

    weak var pdfView: PDFView?
    private var selections: [PDFSelection] = []
    private var searchTask: Task<Void, Never>?

    /// Debounced search so typing stays instant.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.performSearch()
        }
    }

    func performSearch() {
        guard let pdfView, let document = pdfView.document else { return }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)

        guard trimmed.count >= 2 else {
            selections = []
            matchCount = 0
            currentMatch = 0
            return
        }

        selections = document.findString(trimmed, withOptions: [.caseInsensitive])
        matchCount = selections.count
        currentMatch = 0

        // Highlight every hit on the canvas, then scroll to the first.
        pdfView.highlightedSelections = selections
        if !selections.isEmpty {
            goToMatch(0)
        }
    }

    func goToNext() {
        guard !selections.isEmpty else { return }
        goToMatch(currentMatch + 1)
    }

    func goToPrevious() {
        guard !selections.isEmpty else { return }
        goToMatch(currentMatch - 1)
    }

    func goToMatch(_ index: Int) {
        guard !selections.isEmpty, let pdfView else { return }
        let clamped = ((index % selections.count) + selections.count) % selections.count
        currentMatch = clamped
        let selection = selections[clamped]
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: true)
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        selections = []
        matchCount = 0
        currentMatch = 0
        pdfView?.highlightedSelections = nil
        pdfView?.setCurrentSelection(nil, animate: false)
    }
}

// MARK: - PDFKit bridge

/// Renders a PDF from disk with continuous vertical scrolling, optionally
/// bound to a search controller for in-document find + highlight.
struct PDFReader: UIViewRepresentable {
    let url: URL
    var searchController: PDFSearchController?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = UIColor(Theme.inkRaised)
        view.document = PDFDocument(url: url)
        searchController?.pdfView = view
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
        if searchController?.pdfView !== uiView {
            searchController?.pdfView = uiView
        }
    }
}

#Preview {
    NavigationStack {
        DocumentDetailView(document: ScannedDocument.mockList[0])
    }
    .environment(VaultStore.mock())
    .preferredColorScheme(.dark)
}
