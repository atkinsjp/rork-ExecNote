//
//  VaultComponents.swift
//  IntelliDocScanSignPDF
//

import SwiftUI
import UIKit

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Theme.mono(.caption, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.textTertiary)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(.caption, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Search

struct VaultSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.amber : Theme.textTertiary)

            TextField("Search titles and page text", text: $text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.amber)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? Theme.amber.opacity(0.5) : Color.white.opacity(0.07), lineWidth: 1)
        }
        .animation(Theme.snap, value: isFocused)
        .animation(Theme.snap, value: text.isEmpty)
    }
}

// MARK: - Sync chip

struct SyncChip: View {
    let state: SyncState
    var compact: Bool = false

    private var tint: Color {
        switch state {
        case .localOnly: Theme.textTertiary
        case .uploading: Theme.amber
        case .synced: Color(hex: "3FB0A0")
        case .failed: Color(hex: "E2664F")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbolName)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .symbolEffect(.pulse, isActive: isUploading)
            if !compact {
                Text(state.label)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous).fill(tint.opacity(0.12))
        }
        .accessibilityLabel(state.label)
    }

    private var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }
}

// MARK: - Page thumbnail

/// Paper-white page preview with a stacked-sheets effect for multi-page scans.
struct PageThumbnail: View {
    let image: UIImage?
    var pageCount: Int = 1
    var width: CGFloat = 54
    var cornerRadius: CGFloat = 7

    private var height: CGFloat { width * 1.32 }

    var body: some View {
        ZStack {
            if pageCount > 2 {
                sheet(offset: 5, opacity: 0.16)
            }
            if pageCount > 1 {
                sheet(offset: 2.5, opacity: 0.3)
            }

            Group {
                if let image {
                    Color.black
                        .frame(width: width, height: height)
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                } else {
                    LinearGradient(
                        colors: [Theme.paper, Color(hex: "D9D5CB")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: width * 0.075) {
                            ForEach(0..<5, id: \.self) { index in
                                Capsule()
                                    .fill(Color.black.opacity(0.12))
                                    .frame(width: width * (index == 0 ? 0.5 : 0.62), height: width * 0.045)
                            }
                        }
                        .padding(width * 0.16)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: Theme.paper.opacity(0.18), radius: 10)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        }
        .frame(width: width + 6, height: height + 6)
        .accessibilityHidden(true)
    }

    private func sheet(offset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.paper.opacity(opacity))
            .frame(width: width, height: height)
            .offset(x: offset, y: -offset)
    }
}

// MARK: - Folder anchors (used by the file-to-folder flight animation)

struct FolderAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Pressable button style

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.snap, value: configuration.isPressed)
    }
}

// MARK: - Empty state

struct VaultEmptyState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.amber.opacity(0.1))
                    .frame(width: 82, height: 82)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.amber)
            }
            Text(title)
                .font(Theme.display(.title3))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

// MARK: - Multi-select action bar

/// Bottom action bar pinned over the safe area while multi-select is active:
/// exit, selected count with a select-all toggle, a bulk ZIP export button,
/// and a destructive bulk delete pill. Visually mirrors the capture bar's
/// fading ink gradient.
struct DocumentSelectionBar: View {
    let count: Int
    let isAllSelected: Bool
    /// True while the ZIP archive is being built — swaps the export icon for a
    /// progress spinner and blocks further taps.
    var isExporting = false
    let onToggleAll: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Theme.surfaceHigh) }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Exit selection mode")

            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) selected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())

                Button(action: onToggleAll) {
                    Text(isAllSelected ? "Deselect all" : "Select all")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.amberBright)
                }
                .buttonStyle(.plain)
                .disabled(count == 0 && !isAllSelected)
                .accessibilityLabel(isAllSelected ? "Deselect all documents" : "Select all documents")
            }

            Spacer(minLength: 8)

            Button(action: onExport) {
                Group {
                    if isExporting {
                        ProgressView()
                            .tint(Theme.amber)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }
                }
                .frame(width: 40, height: 40)
                .background { Circle().fill(Theme.amber.opacity(0.14)) }
                .overlay { Circle().strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1) }
            }
            .buttonStyle(PressableStyle())
            .disabled(count == 0 || isExporting)
            .opacity(count == 0 ? 0.45 : 1)
            .accessibilityLabel("Export \(count) selected \(count == 1 ? "document" : "documents") as a ZIP archive")

            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "FFE9E4"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background { Capsule().fill(Color(hex: "E2664F")) }
                    .shadow(color: Color(hex: "E2664F").opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(PressableStyle())
            .disabled(count == 0)
            .opacity(count == 0 ? 0.45 : 1)
            .accessibilityLabel("Delete \(count) selected \(count == 1 ? "document" : "documents")")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            LinearGradient(
                colors: [Theme.ink.opacity(0), Theme.ink.opacity(0.92), Theme.ink],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}
