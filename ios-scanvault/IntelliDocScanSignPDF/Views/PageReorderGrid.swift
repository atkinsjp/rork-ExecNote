//
//  PageReorderGrid.swift
//  IntelliDocScanSignPDF
//
//  Draggable page-thumbnail grid for the export sheet. Touch-and-hold a page
//  to lift it, then drag to reorder. Reports the resulting page order (original
//  indices in display order) so exports honor the user's arrangement while the
//  vault copy stays untouched.
//

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PageReorderGrid: View {
    let document: ScannedDocument
    /// Receives the current page order — original page indices in display
    /// order. `nil` means the original order is restored.
    let onOrderChange: ([Int]?) -> Void

    struct PageThumb: Identifiable, Equatable {
        let id: Int
        let image: UIImage

        static func == (lhs: PageThumb, rhs: PageThumb) -> Bool { lhs.id == rhs.id }
    }

    @State private var pages: [PageThumb] = []
    @State private var isLoading = true
    @State private var isUnavailable = false
    @State private var dragging: PageThumb?

    private let thumbnailHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                loadingPlaceholder
            } else if isUnavailable {
                unavailableNote
            } else {
                grid
                footerRow
            }
        }
        .task { await loadThumbnails() }
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
            spacing: 10
        ) {
            ForEach(pages) { thumb in
                cell(thumb)
                    .onDrag {
                        Haptics.selection()
                        dragging = thumb
                        return NSItemProvider(object: "\(thumb.id)" as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: PageDropDelegate(
                            pages: $pages,
                            dragging: $dragging,
                            target: thumb,
                            onOrderChange: onOrderChange
                        )
                    )
            }
        }
    }

    private func cell(_ thumb: PageThumb) -> some View {
        let isDragging = dragging?.id == thumb.id

        return VStack(spacing: 0) {
            Color.clear
                .frame(height: thumbnailHeight)
                .overlay {
                    Image(uiImage: thumb.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("P\(thumb.id + 1)")
                        .font(Theme.mono(.caption2, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background { Capsule().fill(Theme.ink.opacity(0.75)) }
                        .padding(5)
                }
        }
        .frame(maxWidth: .infinity)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface) }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDragging ? Theme.amber : Theme.hairline, lineWidth: isDragging ? 2 : 1)
        }
        .clipShape(.rect(cornerRadius: 12))
        .scaleEffect(isDragging ? 1.05 : 1)
        .shadow(color: isDragging ? Theme.amber.opacity(0.35) : .clear, radius: 10, y: 4)
        .animation(Theme.snap, value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(thumb.id + 1) of \(pages.count)")
        .accessibilityHint("Rearrange the page order for export")
        .accessibilityAction(named: Text("Move Earlier")) { move(thumb, delta: -1) }
        .accessibilityAction(named: Text("Move Later")) { move(thumb, delta: 1) }
    }

    // MARK: - States

    private var loadingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Theme.amber)
            Text("Loading page previews…")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background { RoundedRectangle(cornerRadius: 14).fill(Theme.surface) }
    }

    private var unavailableNote: some View {
        Label("Page previews aren't available on this device — the export still uses the original order.", systemImage: "info.circle")
            .font(Theme.mono(.caption))
            .foregroundStyle(Theme.textTertiary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 14).fill(Theme.surface) }
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(isReordered ? "Custom order — the export follows this arrangement." : "Touch, hold and drag a page to rearrange it.")
                .font(Theme.mono(.caption2))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 8)

            if isReordered {
                Button("Reset") {
                    Haptics.selection()
                    withAnimation(Theme.snap) { pages.sort { $0.id < $1.id } }
                    onOrderChange(nil)
                }
                .font(.system(size: 12, weight: .semibold))
                .tint(Theme.amber)
                .buttonStyle(PressableStyle(scale: 0.95))
            }
        }
    }

    private var isReordered: Bool {
        pages.map(\.id) != Array(0..<pages.count)
    }

    // MARK: - Data

    private func loadThumbnails() async {
        defer { isLoading = false }

        var url: URL? = document.localURL
        if url == nil {
            url = await PDFManager.shared.existingURL(documentId: document.id)
        }
        guard let url else {
            isUnavailable = true
            return
        }

        // Rasterize off-main: PDFKit thumbnail rendering is thread-safe, and
        // CGImage is Sendable so the hop back to the actor is clean.
        struct Payload {
            let id: Int
            let cgImage: CGImage
        }

        let payload: [Payload] = await Task.detached(priority: .userInitiated) { () -> [Payload] in
            guard let pdf = PDFDocument(url: url) else { return [] }
            let size = CGSize(width: 240, height: 320)
            var result: [Payload] = []
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index),
                      let image = page.thumbnail(of: size, for: .mediaBox).cgImage else { continue }
                result.append(Payload(id: index, cgImage: image))
            }
            return result
        }.value

        if payload.isEmpty {
            isUnavailable = true
        } else {
            pages = payload.map { PageThumb(id: $0.id, image: UIImage(cgImage: $0.cgImage)) }
        }
    }

    // MARK: - Accessibility moves

    private func move(_ thumb: PageThumb, delta: Int) {
        guard let from = pages.firstIndex(where: { $0.id == thumb.id }) else { return }
        let to = from + delta
        guard pages.indices.contains(to) else { return }
        withAnimation(Theme.snap) {
            pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        Haptics.selection()
        onOrderChange(currentOrder)
    }

    private var currentOrder: [Int]? {
        let order = pages.map(\.id)
        return order == Array(0..<order.count) ? nil : order
    }
}

// MARK: - Drop delegate

/// Live-reorders thumbnails as a dragged page passes over each cell, then
/// reports the final arrangement on drop.
private struct PageDropDelegate: DropDelegate {
    @Binding var pages: [PageReorderGrid.PageThumb]
    @Binding var dragging: PageReorderGrid.PageThumb?
    let target: PageReorderGrid.PageThumb
    let onOrderChange: ([Int]?) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging,
              dragging.id != target.id,
              let from = pages.firstIndex(where: { $0.id == dragging.id }),
              let to = pages.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(Theme.snap) {
            pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        Haptics.selection()
        onOrderChange(finalOrder)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func performDrop(info: DropInfo) -> Bool {
        onOrderChange(finalOrder)
        Haptics.impact(.light)
        dragging = nil
        return true
    }

    private var finalOrder: [Int]? {
        let order = pages.map(\.id)
        return order == Array(0..<order.count) ? nil : order
    }
}

#Preview {
    PageReorderGrid(document: ScannedDocument.mockList[0]) { _ in }
        .padding()
        .preferredColorScheme(.dark)
}
