//
//  DocumentRedactionView.swift
//  ScanVault
//

import SwiftUI
import UIKit

/// On-device redaction studio: page-by-page viewer with detected PII
/// highlights, tap-to-toggle regions, a manual draw-a-box tool, category
/// quick actions, and a before/after confirmation before the sanitized PDF
/// permanently replaces the original.
struct DocumentRedactionView: View {
    @Environment(VaultStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    /// Pages supplied directly instead of rasterized from disk (previews).
    var preloadedPages: [UIImage] = []

    enum Mode: String, CaseIterable, Identifiable, Hashable {
        case inspect
        case brush

        var id: String { rawValue }
        var symbolName: String { self == .inspect ? "text.viewfinder" : "plus.viewfinder" }
        var label: String { self == .inspect ? "Inspect" : "Draw box" }
    }

    struct Comparison: Identifiable {
        let id = UUID()
        let before: UIImage
        let after: UIImage
        let count: Int
    }

    @State private var pages: [UIImage] = []
    @State private var boxes: [RedactionBox] = []
    @State private var mode: Mode = .inspect
    @State private var pageIndex: Int = 0
    @State private var customQuery: String = ""
    @State private var notice: String?
    @State private var isLoading: Bool = true
    @State private var isAnalyzing: Bool = false
    @State private var analyzeProgress: Double = 0
    @State private var isRendering: Bool = false
    @State private var comparison: Comparison?
    @State private var isShowingPaywall = false

    private let service = OCRRedactionService.shared

    /// Free-tier cap; `nil` when Pro unlocks unlimited redactions.
    private var redactionAllowance: Int? {
        subscriptions.redactionAllowance
    }

    private var liveDocument: ScannedDocument {
        store.documents.first { $0.id == document.id } ?? document
    }

    private var pageBoxes: [RedactionBox] {
        boxes.filter { $0.pageIndex == pageIndex }
    }

    private var selectedCount: Int {
        boxes.filter(\.isSelected).count
    }

    private var currentPage: UIImage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    private var quickKinds: [RedactionKind] {
        [.ssn, .creditCard, .email, .phone]
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop
                content
            }
            .overlay { renderingOverlay }
            .navigationTitle("Redact & Sanitize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if liveDocument.isRedacted {
                        Label("\(liveDocument.redactionCount) redacted", systemImage: "checkmark.shield.fill")
                            .font(Theme.mono(.caption2, weight: .semibold))
                            .foregroundStyle(Color(hex: "3FB0A0"))
                    }
                }
            }
            .sheet(item: $comparison) { comparison in
                RedactionCompareSheet(comparison: comparison) {
                    apply()
                }
            }
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView()
                    .environment(subscriptions)
            }
            .task { await loadIfNeeded() }
            .interactiveDismissDisabled(isRendering)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(Theme.amber)
                    .controlSize(.large)
                Text("Opening pages…")
                    .font(Theme.mono(.caption, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pages.isEmpty {
            VaultEmptyState(
                title: "Nothing to redact",
                message: "The pages for this scan aren't stored on this device.",
                symbol: "doc.text.magnifyingglass"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                statsBar
                pageArea
                toolRow
                chipsRow
                scrubber
                applyButton
            }
        }
    }

    // MARK: - Status bar

    private var statsBar: some View {
        HStack(spacing: 8) {
            if isAnalyzing {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse)
                    .foregroundStyle(Theme.amber)
                Text("Reading pages… \(Int(analyzeProgress * 100))%")
                    .font(Theme.mono(.caption, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            } else {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedCount > 0 ? Theme.amber : Theme.textTertiary)
                Text("\(boxes.count) found · \(selectedCount) selected")
                    .font(Theme.mono(.caption, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 8)

            if let notice {
                Text(notice)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .animation(Theme.snap, value: isAnalyzing)
    }

    // MARK: - Page viewer

    /// In brush mode the paged viewer is swapped for a static canvas so the
    /// drag gesture never fights TabView's swipe.
    @ViewBuilder
    private var pageArea: some View {
        Group {
            if mode == .brush, let currentPage {
                PageCanvas(
                    image: currentPage,
                    boxes: pageBoxes,
                    isBrushActive: true,
                    onToggle: { toggleBox($0) },
                    onDraw: { addManualBox($0) }
                )
                .padding(.horizontal, 20)
            } else {
                TabView(selection: $pageIndex) {
                    ForEach(pages.indices, id: \.self) { index in
                        PageCanvas(
                            image: pages[index],
                            boxes: boxes.filter { $0.pageIndex == index },
                            isBrushActive: false,
                            onToggle: { toggleBox($0) },
                            onDraw: { _ in }
                        )
                        .padding(.horizontal, 20)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .overlay(alignment: .bottom) {
            Text("PAGE \(pageIndex + 1) OF \(pages.count)")
                .font(Theme.mono(.caption2, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background { Capsule().fill(Color.black.opacity(0.55)) }
                .padding(.bottom, 4)
                .animation(Theme.snap, value: pageIndex)
        }
    }

    // MARK: - Tools & search

    private var toolRow: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 118)
            .accessibilityLabel("Tool")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)

                TextField("Find & redact any word", text: $customQuery)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.amber)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(runCustomSearch)

                if !customQuery.isEmpty {
                    Button {
                        customQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Quick actions

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickKinds, id: \.self) { kind in
                    quickChip(kind)
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .padding(.vertical, 6)
    }

    private func quickChip(_ kind: RedactionKind) -> some View {
        let sameKind = boxes.filter { $0.kind == kind }
        let total = sameKind.count
        let allSelected = total > 0 && sameKind.allSatisfy(\.isSelected)
        let color = Color(hex: kind.colorHex)

        return Button {
            toggleCategory(kind)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(kind.label)s · \(total)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(total == 0 ? Theme.textTertiary : color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(allSelected ? color.opacity(0.18) : Color.white.opacity(0.04))
            }
            .overlay {
                Capsule().strokeBorder(
                    allSelected ? color.opacity(0.7) : Theme.hairline,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .disabled(total == 0)
        .animation(Theme.snap, value: allSelected)
    }

    // MARK: - Page scrubber

    private var scrubber: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    scrubberItem(index)
                }
            }
            .padding(.vertical, 4)
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .frame(height: 78)
    }

    private func scrubberItem(_ index: Int) -> some View {
        let isCurrent = index == pageIndex
        let marks = boxes.filter { $0.pageIndex == index && $0.isSelected }.count

        return Button {
            withAnimation(Theme.snap) { pageIndex = index }
            Haptics.selection()
        } label: {
            VStack(spacing: 3) {
                Color.black
                    .frame(width: 40, height: 52)
                    .overlay {
                        Image(uiImage: pages[index])
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                isCurrent ? Theme.amber : Color.white.opacity(0.12),
                                lineWidth: isCurrent ? 1.5 : 0.5
                            )
                    }

                Text(marks > 0 ? "P\(index + 1) · \(marks)" : "P\(index + 1)")
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(isCurrent ? Theme.amber : Theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1), \(marks) redactions")
    }

    // MARK: - Apply

    private var applyButton: some View {
        Button {
            prepareComparison()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(
                    selectedCount == 0
                        ? "Select redactions to apply"
                        : "Apply \(selectedCount) Redaction\(selectedCount == 1 ? "" : "s")"
                )
                .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(selectedCount == 0 ? Theme.textTertiary : Color(hex: "1A1206"))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                Capsule().fill(
                    selectedCount == 0
                        ? AnyShapeStyle(Color.white.opacity(0.06))
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [Theme.amberBright, Theme.amber],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
            }
            .shadow(
                color: selectedCount == 0 ? .clear : Theme.amber.opacity(0.3),
                radius: 14,
                y: 6
            )
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(selectedCount == 0)
        .animation(Theme.snap, value: selectedCount)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var renderingOverlay: some View {
        Group {
            if isRendering {
                ZStack {
                    Color.black.opacity(0.72).ignoresSafeArea()

                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(Theme.amber)
                            .controlSize(.large)
                        Text("FLATTENING PAGES")
                            .font(Theme.mono(.caption, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Rebuilding an image-only PDF — no text layer survives.")
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(26)
                    .cardSurface(cornerRadius: 20)
                    .padding(40)
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.snap, value: isRendering)
    }

    // MARK: - Actions

    private func loadIfNeeded() async {
        guard pages.isEmpty else { return }

        if !preloadedPages.isEmpty {
            pages = preloadedPages
            isLoading = false
            await analyze()
            return
        }

        let cached = await PDFManager.shared.existingURL(documentId: document.id)
        var loaded: [UIImage] = []
        if let source = document.localURL ?? cached {
            loaded = await PDFManager.shared.pageImages(for: source)
        }
        pages = loaded
        isLoading = false

        if !loaded.isEmpty {
            await analyze()
        }
    }

    private func analyze() async {
        isAnalyzing = true
        analyzeProgress = 0

        for (index, page) in pages.enumerated() {
            let found = await service.analyzePage(page, pageIndex: index)
            withAnimation(Theme.snap) { boxes += found }
            analyzeProgress = Double(index + 1) / Double(pages.count)
        }

        isAnalyzing = false
        notice = boxes.isEmpty ? "No PII detected" : nil
    }

    private func runCustomSearch() {
        let term = customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, !pages.isEmpty else { return }

        isAnalyzing = true
        boxes.removeAll { $0.kind == .custom }
        let existingRects = Set(boxes.map(\.rect))

        Task {
            var found: [RedactionBox] = []
            for (index, page) in pages.enumerated() {
                found += await service.analyzePage(page, pageIndex: index, customTerm: term)
                    .filter { $0.kind == .custom && !existingRects.contains($0.rect) }
            }

            withAnimation(Theme.snap) { boxes += found }
            isAnalyzing = false
            notice = found.isEmpty
                ? "No matches for “\(term)”"
                : "\(found.count) \(found.count == 1 ? "match" : "matches") marked"
            Haptics.selection()
        }
    }

    private func toggleBox(_ id: UUID) {
        guard mode == .inspect, let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Theme.snap) { boxes[index].isSelected.toggle() }
        Haptics.selection()
    }

    private func addManualBox(_ rect: CGRect) {
        withAnimation(Theme.snap) {
            boxes.append(
                RedactionBox(
                    pageIndex: pageIndex,
                    rect: rect,
                    kind: .manual,
                    isManual: true,
                    isSelected: true
                )
            )
        }
        Haptics.impact()
    }

    private func toggleCategory(_ kind: RedactionKind) {
        let indices = boxes.indices.filter { boxes[$0].kind == kind }
        guard !indices.isEmpty else { return }
        let allSelected = indices.allSatisfy { boxes[$0].isSelected }

        withAnimation(Theme.snap) {
            for index in indices {
                boxes[index].isSelected = !allSelected
            }
        }
        Haptics.selection()
    }

    private func prepareComparison() {
        guard let currentPage, selectedCount > 0 else { return }
        isRendering = true

        Task {
            let after = await service.renderPreviewImage(page: currentPage, regions: pageBoxes)
            isRendering = false

            if let after {
                comparison = Comparison(before: currentPage, after: after, count: selectedCount)
            } else {
                notice = "Preview could not be rendered."
            }
        }
    }

    private func apply() {
        guard selectedCount > 0 else { return }
        if let allowance = redactionAllowance, selectedCount > allowance {
            Haptics.warning()
            isShowingPaywall = true
            return
        }
        isRendering = true

        Task {
            let ok = await store.applyRedactions(to: liveDocument, pages: pages, regions: boxes)
            isRendering = false
            comparison = nil

            if ok {
                Haptics.success()
                dismiss()
            }
        }
    }
}

// MARK: - Page canvas

/// A single page with interactive redaction highlights and, in brush mode, a
/// drag-to-draw region tool.
private struct PageCanvas: View {
    let image: UIImage
    let boxes: [RedactionBox]
    let isBrushActive: Bool
    let onToggle: (UUID) -> Void
    let onDraw: (CGRect) -> Void

    @State private var dragRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fitRect(for: image.size, in: geo.size)

            Group {
                if isBrushActive {
                    canvas(fit: fit)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(fit: fit))
                } else {
                    canvas(fit: fit)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private func canvas(fit: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.02))

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: fit.width, height: fit.height)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

            ForEach(boxes) { box in
                boxView(box, fit: fit)
            }

            if let dragRect {
                let frame = rect(in: fit, from: dragRect) ?? .zero
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.amber.opacity(0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.amber, lineWidth: 1.5)
                    }
                    .frame(width: max(frame.width, 8), height: max(frame.height, 8))
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    private func dragGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragRect = Self.normalizedRect(
                    from: value.startLocation,
                    to: value.location,
                    fit: fit
                )
            }
            .onEnded { _ in
                defer { dragRect = nil }
                guard let rect = dragRect, rect.width > 0.012, rect.height > 0.008 else { return }
                onDraw(rect)
            }
    }

    @ViewBuilder
    private func boxView(_ box: RedactionBox, fit: CGRect) -> some View {
        let frame = rect(in: fit, from: box.rect) ?? .zero
        let color = Color(hex: box.kind.colorHex)

        Button {
            if !isBrushActive { onToggle(box.id) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(box.isSelected ? color.opacity(0.3) : Color.white.opacity(0.04))

                if box.isSelected {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(color, lineWidth: 1.5)
                } else {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(0.35),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                }

                if box.isSelected, frame.width > 56 {
                    Text(box.kind.shortLabel)
                        .font(Theme.mono(.caption2, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background { Capsule().fill(Color.black.opacity(0.6)) }
                        .padding(2)
                }
            }
            .frame(width: max(frame.width, 12), height: max(frame.height, 12))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -9))
        .position(x: frame.midX, y: frame.midY)
        .animation(Theme.snap, value: box.isSelected)
        .accessibilityLabel(
            "\(box.kind.label) \(box.isSelected ? "selected" : "dismissed") on page \(box.pageIndex + 1)"
        )
    }

    // MARK: Geometry mapping

    private func rect(in fit: CGRect, from normalized: CGRect) -> CGRect? {
        guard fit.width > 0, fit.height > 0 else { return nil }
        return CGRect(
            x: fit.minX + normalized.minX * fit.width,
            y: fit.minY + normalized.minY * fit.height,
            width: normalized.width * fit.width,
            height: normalized.height * fit.height
        )
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint, fit: CGRect) -> CGRect {
        let a = normalized(start, fit: fit)
        let b = normalized(end, fit: fit)
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private static func normalized(_ point: CGPoint, fit: CGRect) -> CGPoint {
        guard fit.width > 0, fit.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - fit.minX) / fit.width, 0), 1),
            y: min(max((point.y - fit.minY) / fit.height, 0), 1)
        )
    }

    private static func fitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0
        else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Before / after confirmation

private struct RedactionCompareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let comparison: DocumentRedactionView.Comparison
    let onApply: () -> Void

    var body: some View {
        ZStack {
            Theme.inkRaised.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Before & After")
                            .font(Theme.display(.title3))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(comparison.count) redaction\(comparison.count == 1 ? "" : "s") will be burned into every page")
                            .font(Theme.mono(.caption2))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 8)

                    pane("BEFORE", comparison.before, tinted: false)
                    pane("AFTER — FLATTENED", comparison.after, tinted: true)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(hex: "3FB0A0"))
                        Text("The sanitized PDF is image-only — redacted text can't be copied, searched or recovered from the file.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: "3FB0A0").opacity(0.08))
                    }

                    Button {
                        dismiss()
                        onApply()
                    } label: {
                        Label("Apply \(comparison.count) Redactions", systemImage: "eye.slash.fill")
                            .font(.system(size: 17, weight: .semibold))
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
                            .shadow(color: Theme.amber.opacity(0.3), radius: 14, y: 6)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))

                    Button("Keep editing") { dismiss() }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.inkRaised)
        .presentationContentInteraction(.scrolls)
    }

    private func pane(_ label: String, _ image: UIImage, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.mono(.caption2, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Theme.textTertiary)
            Color.black
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                }
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            tinted ? Color(hex: "3FB0A0").opacity(0.6) : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
        }
    }
}

// MARK: - Preview fixtures

#Preview {
    DocumentRedactionView(
        document: ScannedDocument.mockList[2],
        preloadedPages: RedactionPreviewFixtures.pages
    )
    .environment(VaultStore.mock())
}

private enum RedactionPreviewFixtures {
    static var pages: [UIImage] {
        [
            render(lines: [
                "PATIENT INTAKE FORM",
                "Name: Dana R. Whitfield",
                "SSN: 078-05-1120",
                "Email: dana.whitfield@example.com",
                "Phone: (415) 555-0132",
                "",
                "Card on file: 4111 1111 1111 1111",
                "Expires 09/2028",
            ]),
            render(lines: [
                "INSURANCE SUMMARY",
                "Policy 884-22-9011",
                "Contact: billing@acme-health.example.org",
                "Fax +1 202 555 0177",
                "Total billed: $1,284.50",
            ]),
        ]
    }

    private static func render(lines: [String]) -> UIImage {
        let size = CGSize(width: 612, height: 792)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 26
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 21, weight: .regular),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
            (lines.joined(separator: "\n") as NSString).draw(
                in: CGRect(x: 54, y: 90, width: 504, height: 640),
                withAttributes: attributes
            )
        }
    }
}
