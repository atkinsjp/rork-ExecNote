//
//  TranscriptionReviewView.swift
//  ScanVault
//
//  Notes Studio stage one: handwritten scan on top, live editable Gemini
//  transcription below, with quick actions and the AI transform launcher.
//

import PDFKit
import SwiftUI
import UIKit

struct TranscriptionReviewView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    @State private var pages: [UIImage] = []
    @State private var currentPage = 0
    @State private var draft = ""
    @State private var storedTranscription = ""
    @State private var isLoadingPages = true
    @State private var isTranscribing = false
    @State private var errorText: String?
    @State private var isPolishing = false
    @State private var isSaving = false
    @State private var savedTick = 0

    private var live: ScannedDocument {
        store.documents.first { $0.id == document.id } ?? document
    }

    private var isDirty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != storedTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        scanPager
                            .scanSweep(active: isTranscribing)
                        transcriptionPanel
                        if let errorText {
                            errorBanner(errorText)
                        }
                        transformLauncher
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Notes Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isDirty {
                        Button("Save") { save() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .disabled(isSaving)
                    }
                }
            }
        }
        .task { await loadPages() }
        .sensoryFeedback(.success, trigger: savedTick)
        .sheet(isPresented: $isPolishing) {
            AIPolishModalView(document: live, transcript: draft)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Scan pager

    private var scanPager: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "HANDWRITTEN SCAN", trailing: pages.isEmpty ? nil : "\(pages.count) pages")
            }
            .padding(.horizontal, 4)

            Group {
                if isLoadingPages {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.surface)
                            .frame(height: 250)
                        ProgressView()
                            .tint(Theme.amber)
                        Text("Rendering pages…")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 44)
                    }
                } else if pages.isEmpty {
                    VaultEmptyState(
                        title: "Scan not on this device",
                        message: "Reconnect to download the pages, then transcription will unlock.",
                        symbol: "icloud.and.arrow.down"
                    )
                } else {
                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { index in
                            ZStack {
                                Theme.inkRaised
                                Image(uiImage: pages[index])
                                    .resizable()
                                    .scaledToFit()
                            }
                            .clipShape(.rect(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .automatic : .never))
                    .frame(height: 250)
                }
            }
        }
    }

    // MARK: - Transcription panel

    private var transcriptionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "TRANSCRIPTION")
                Spacer()

                if isTranscribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.amber)
                        Text("Gemini reading…")
                            .font(Theme.mono(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }
                } else if !storedTranscription.isEmpty {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(Theme.mono(.caption2, weight: .semibold))
                        .foregroundStyle(Color(hex: "3FB0A0"))
                }
            }
            .padding(.horizontal, 4)

            if draft.isEmpty && !isTranscribing && !pages.isEmpty {
                transcribeHero
            } else {
                quickActions
                TextEditor(text: $draft)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 190)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.surface)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .disabled(isTranscribing)
                    .opacity(isTranscribing ? 0.55 : 1)
            }
        }
    }

    private var transcribeHero: some View {
        Button {
            Haptics.impact()
            Task { await transcribe() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("Transcribe Handwriting")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Gemini 2.5 Flash reads every page, fixes spelling and keeps your lists, indents and diagram notes intact.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
        .buttonStyle(PressableStyle())
        .cardSurface(cornerRadius: 20, highlighted: true)
        .accessibilityLabel("Transcribe handwriting with Gemini")
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction("Paste", symbol: "doc.on.clipboard") {
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    draft += (draft.isEmpty ? "" : "\n") + text
                    Haptics.selection()
                }
            }
            quickAction("Insert page OCR", symbol: "text.viewfinder") {
                Task { await insertPageOCR() }
            }
            Spacer()
            if !draft.isEmpty {
                quickAction("Clear", symbol: "eraser", destructive: true) {
                    draft = ""
                    Haptics.selection()
                }
            }
        }
    }

    private func quickAction(
        _ title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(destructive ? Color(hex: "E2664F") : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { Capsule().fill(Theme.surfaceHigh) }
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Transform launcher

    @ViewBuilder
    private var transformLauncher: some View {
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Haptics.impact()
                    isPolishing = true
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Transform Notes Into…")
                            .font(.system(size: 15.5, weight: .semibold))
                        Spacer()
                        if live.noteTransforms.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("\(live.noteTransforms.count) saved")
                                .font(Theme.mono(.caption2, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .foregroundStyle(Theme.amberBright)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .buttonStyle(PressableStyle())
                .cardSurface(cornerRadius: 18, highlighted: true)
                .accessibilityLabel("Transform notes with AI")

                Text("Minutes · executive email · slide outline · LinkedIn post — streamed live, exportable as DOCX or PDF.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: "E2664F"))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { errorText = nil }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .cardSurface(cornerRadius: 14)
    }

    // MARK: - Data flow

    private func loadPages() async {
        storedTranscription = live.noteTranscription ?? ""
        draft = storedTranscription

        var url = live.localURL
        if url == nil {
            url = await PDFManager.shared.existingURL(documentId: live.id)
        }
        guard let url else {
            isLoadingPages = false
            return
        }
        pages = await PDFManager.shared.pageImages(for: url, maxWidth: 1100)
        isLoadingPages = false
    }

    private func transcribe() async {
        guard !pages.isEmpty else { return }
        isTranscribing = true
        errorText = nil

        do {
            let text = try await HandwritingTranscriptionService.shared.transcribe(pages: pages)
            draft = text
            storedTranscription = text
            await store.setTranscription(text, for: live)
            Haptics.success()
            savedTick &+= 1
        } catch {
            errorText = error.localizedDescription
            Haptics.warning()
        }
        isTranscribing = false
    }

    /// Appends on-device Vision OCR for the visible page — an offline fallback
    /// for when the cloud transcription is unavailable.
    private func insertPageOCR() async {
        guard pages.indices.contains(currentPage) else { return }
        let text = await OCRService.shared.recognizedText(in: pages[currentPage])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft += (draft.isEmpty ? "" : "\n\n") + trimmed
        Haptics.selection()
    }

    private func save() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        Task {
            await store.setTranscription(text, for: live)
            storedTranscription = text
            isSaving = false
            Haptics.success()
            savedTick &+= 1
        }
    }
}

#Preview {
    TranscriptionReviewView(document: ScannedDocument.mockList[0])
        .environment(VaultStore.mock())
        .preferredColorScheme(.dark)
}
