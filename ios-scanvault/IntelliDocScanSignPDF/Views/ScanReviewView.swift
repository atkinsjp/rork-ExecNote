//
//  ScanReviewView.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UIKit

/// Capture review: flip through the captured pages, reorder, rotate or drop
/// them, then open the "Save & File" sheet.
struct ScanReviewView: View {
    @Environment(VaultStore.self) private var store
    @Environment(ScannerManager.self) private var scanner
    @Environment(\.dismiss) private var dismiss

    let onFiled: (FiledScan) -> Void

    /// Folder preselected in the "Save & File" sheet — used when a capture is
    /// started from inside a folder, so pages land where the user is standing.
    var presetFolderId: String? = nil

    @State private var selection: UUID?
    @State private var isFiling = false
    @State private var isSaving = false
    @State private var isAddingPages = false

    // AI smart-naming state.
    @State private var isAnalyzing = false
    @State private var classification: DocumentClassification?
    @State private var chosenName: String?
    @State private var suggestedFolderId: String?
    @State private var appliedFolderId: String?

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                topBar

                if scanner.hasPages {
                    pageCarousel
                    pageControls
                    smartSuggestionBar
                    thumbnailStrip
                    saveBar
                } else {
                    Spacer()
                    VaultEmptyState(
                        title: "No pages captured",
                        message: scanner.isDocumentCameraAvailable
                            ? "Add a page to build your PDF."
                            : "This device has no document camera. Import images from Photos instead.",
                        symbol: "doc.badge.plus"
                    )
                    Spacer()
                }
            }

            if isSaving {
                savingOverlay
            }
        }
        .fullScreenCover(isPresented: $isAddingPages) {
            DocumentCameraView(
                onFinish: { images in
                    scanner.finish(with: images, source: .camera)
                    isAddingPages = false
                },
                onCancel: { isAddingPages = false },
                onError: { error in
                    scanner.fail(error)
                    isAddingPages = false
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isFiling) {
            SaveAndFileSheet(
                pageCount: scanner.pages.count,
                initialTitle: chosenName ?? classification?.suggestedNames.first,
                initialFolderId: presetFolderId ?? appliedFolderId ?? suggestedFolderId
            ) { title, folderId in
                isFiling = false
                Task { await file(title: title, folderId: folderId) }
            }
        }
        .task(id: scanner.pageIDs) {
            await analyze()
        }
        .onAppear {
            if selection == nil { selection = scanner.pageIDs.first }
        }
        .onChange(of: scanner.pageIDs) { _, ids in
            if selection == nil || !ids.contains(selection ?? UUID()) {
                selection = ids.first
            }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                scanner.reset()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Theme.surfaceHigh) }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Discard scan")

            Spacer()

            VStack(spacing: 1) {
                Text("Review")
                    .font(Theme.display(.headline))
                    .foregroundStyle(Theme.textPrimary)
                Text(scanner.source == .camera ? "Captured with camera" : "Imported from Photos")
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            Button {
                Haptics.impact(.light)
                isAddingPages = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(scanner.isDocumentCameraAvailable ? Theme.amber : Theme.textTertiary)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Theme.surfaceHigh) }
            }
            .buttonStyle(PressableStyle())
            .disabled(!scanner.isDocumentCameraAvailable)
            .accessibilityLabel("Add more pages")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Pages

    private var pageCarousel: some View {
        TabView(selection: $selection) {
            ForEach(scanner.identifiedPages) { page in
                Image(uiImage: page.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Color.white)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .shadow(color: Theme.paper.opacity(0.14), radius: 24)
                    .shadow(color: .black.opacity(0.55), radius: 16, y: 10)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 6)
                    .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxHeight: .infinity)
        .scanSweep(active: isAnalyzing)
    }

    private var pageControls: some View {
        HStack(spacing: 10) {
            controlButton("arrow.left", label: "Move page left") {
                guard let index = selectedIndex else { return }
                withAnimation(Theme.snap) { scanner.swapPage(at: index, direction: -1) }
                Haptics.selection()
            }
            .disabled((selectedIndex ?? 0) == 0)

            controlButton("rotate.right", label: "Rotate page") {
                guard let index = selectedIndex else { return }
                scanner.rotatePage(at: index)
                Haptics.impact(.light)
            }

            Text("Page \((selectedIndex ?? 0) + 1) of \(scanner.pages.count)")
                .font(Theme.mono(.caption, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 110)
                .contentTransition(.numericText())

            controlButton("trash", label: "Delete page", tint: Color(hex: "E2664F")) {
                guard let index = selectedIndex else { return }
                withAnimation(Theme.soft) { scanner.removePage(at: index) }
                Haptics.warning()
            }

            controlButton("arrow.right", label: "Move page right") {
                guard let index = selectedIndex else { return }
                withAnimation(Theme.snap) { scanner.swapPage(at: index, direction: 1) }
                Haptics.selection()
            }
            .disabled((selectedIndex ?? 0) >= scanner.pages.count - 1)
        }
        .padding(.vertical, 14)
    }

    private func controlButton(
        _ symbol: String,
        label: String,
        tint: Color = Theme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background { Circle().fill(Theme.surfaceHigh) }
                .overlay { Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1) }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(scanner.identifiedPages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        withAnimation(Theme.snap) { selection = page.id }
                        Haptics.selection()
                    } label: {
                        ZStack(alignment: .topLeading) {
                            Color.black
                                .frame(width: 58, height: 76)
                                .overlay {
                                    Image(uiImage: page.image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .allowsHitTesting(false)
                                }
                                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            selection == page.id ? Theme.amber : Color.white.opacity(0.1),
                                            lineWidth: selection == page.id ? 2 : 1
                                        )
                                }

                            Text("\(index + 1)")
                                .font(Theme.mono(.caption2, weight: .bold))
                                .foregroundStyle(Color(hex: "1A1206"))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(Theme.amber) }
                                .padding(4)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Page \(index + 1)")
                }
            }
            .padding(.vertical, 4)
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .frame(height: 92)
    }

    private var saveBar: some View {
        Button {
            Haptics.impact()
            isFiling = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text("Save & File")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Color(hex: "1A1206"))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                Capsule().fill(
                    LinearGradient(
                        colors: [Theme.amberBright, Theme.amber],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 8)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                if let first = scanner.pages.first {
                    Image(uiImage: first)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                        .scanSweep(active: true)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Theme.amber)
                }
                Text("Building your PDF…")
                    .font(Theme.mono(.footnote, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(28)
            .cardSurface(cornerRadius: 20)
        }
        .transition(.opacity)
    }

    // MARK: - Smart suggestions

    /// One-tap naming chips + folder route from the on-device classifier.
    @ViewBuilder
    private var smartSuggestionBar: some View {
        if isAnalyzing {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                Text("Reading document on-device…")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .transition(.opacity)
        } else if let classification, !classification.suggestedNames.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                    Text(classification.reasonLine)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    confidenceBadge
                }
                .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(classification.suggestedNames, id: \.self) { name in
                            nameChip(name)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)

                Group {
                    if let folderId = suggestedFolderId,
                       let folder = store.folder(withId: folderId) {
                    Button {
                        Haptics.impact(.medium)
                        withAnimation(Theme.snap) {
                            appliedFolderId = appliedFolderId == folderId ? nil : folderId
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: folder.iconName)
                                .font(.system(size: 10, weight: .semibold))
                            Text("File to \(folder.name)")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(Int(classification.confidence * 100))% match")
                                .font(Theme.mono(.caption2))
                                .foregroundStyle(Theme.textTertiary)
                            if appliedFolderId == folderId {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(appliedFolderId == folderId ? Theme.ink : folder.tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            Capsule().fill(
                                appliedFolderId == folderId
                                    ? AnyShapeStyle(folder.tint)
                                    : AnyShapeStyle(folder.tint.opacity(0.14))
                            )
                        }
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var confidenceBadge: some View {
        let percent = Int((classification?.confidence ?? 0) * 100)
        return HStack(spacing: 4) {
            Circle()
                .fill(percent >= 70 ? Color(hex: "3FB0A0") : Theme.amber)
                .frame(width: 6, height: 6)
            Text("\(percent)% confident")
                .font(Theme.mono(.caption2, weight: .semibold))
                .foregroundStyle(percent >= 70 ? Color(hex: "3FB0A0") : Theme.amber)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background { Capsule().fill(Color.white.opacity(0.05)) }
    }

    private func nameChip(_ name: String) -> some View {
        let isSelected = chosenName == name
        return Button {
            Haptics.impact(.medium)
            withAnimation(Theme.snap) {
                chosenName = isSelected ? nil : name
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "textformat")
                    .font(.system(size: 10, weight: .semibold))
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(isSelected ? Color(hex: "1A1206") : Theme.amberBright)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.amber)
                        : AnyShapeStyle(Theme.amber.opacity(0.12))
                )
            }
            .overlay {
                Capsule().strokeBorder(isSelected ? Theme.amber : Theme.amber.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityLabel("Name suggestion: \(name)")
    }

    private func analyze() async {
        guard scanner.hasPages else {
            classification = nil
            isAnalyzing = false
            return
        }
        isAnalyzing = true
        let result = await DocumentClassifierService.shared.classify(pages: scanner.pages)
        withAnimation(Theme.snap) {
            classification = result.suggestedNames.isEmpty ? nil : result
            isAnalyzing = false
            chosenName = nil
            appliedFolderId = nil
            suggestedFolderId = resolveSuggestedFolder()
        }
    }

    /// Maps the classified category onto an existing folder by name.
    private func resolveSuggestedFolder() -> String? {
        guard let category = classification?.category else { return nil }
        if let exact = store.folders.first(where: {
            $0.name.localizedCaseInsensitiveCompare(category.rawValue) == .orderedSame
        }) {
            return exact.id
        }
        let keywords = category.rawValue.lowercased().components(separatedBy: " & ")
        if let partial = store.folders.first(where: { folder in
            keywords.contains { folder.name.lowercased().contains($0) }
        }) {
            return partial.id
        }
        return AppFolder.inboxID
    }

    // MARK: - Actions

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return scanner.index(of: selection)
    }

    private func file(title: String, folderId: String) async {
        let pages = scanner.pages
        withAnimation(Theme.snap) { isSaving = true }

        guard let document = await store.saveScan(
            pages: pages,
            title: title,
            folderId: folderId,
            classification: classification
        ) else {
            withAnimation(Theme.snap) { isSaving = false }
            return
        }

        let filed = FiledScan(
            id: document.id,
            folderId: folderId,
            thumbnail: store.thumbnail(for: document) ?? pages.first,
            pageCount: document.pageCount
        )
        withAnimation(Theme.snap) { isSaving = false }
        onFiled(filed)
    }
}

#Preview("Review") {
    let scanner = ScannerManager()
    scanner.load(
        [
            .previewPage(title: "Invoice 2291", tint: .systemBlue),
            .previewPage(title: "Terms of service", tint: .systemOrange),
            .previewPage(title: "Signature page", tint: .systemGreen),
        ],
        source: .camera
    )
    return ScanReviewView { _ in }
        .environment(VaultStore.mock())
        .environment(scanner)
        .preferredColorScheme(.dark)
}
