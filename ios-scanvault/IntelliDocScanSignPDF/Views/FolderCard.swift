//
//  FolderCard.swift
//  IntelliDocScanSignPDF
//

import SwiftUI

/// Folder tile with a badge count. Pulses when a freshly filed document lands.
/// While a biometric vault folder is sealed its contents blur away behind an
/// animated lock.
struct FolderCard: View {
    let folder: AppFolder
    let count: Int
    var isPulsing: Bool = false
    var isLocked: Bool = false
    /// A dragged document is hovering over this tile.
    var isDropTarget: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(folder.tint.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: folder.iconName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(folder.tint)
                    }

                    Spacer(minLength: 0)

                    if folder.isBiometricLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(6)
                            .background { Circle().fill(Color.white.opacity(0.06)) }
                    }
                }

                Spacer(minLength: 10)

                Text(folder.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(isLocked ? "Locked" : countLabel)
                        .font(Theme.mono(.caption2, weight: .semibold))
                        .foregroundStyle(isPulsing ? folder.tint : Theme.textTertiary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Image(systemName: isLocked ? "lock.fill" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary.opacity(0.7))
                }
                .padding(.top, 3)
            }
            .padding(14)
            .frame(height: 138, alignment: .topLeading)
            .background(alignment: .bottom) {
                LinearGradient(
                    colors: [folder.tint.opacity(isPulsing ? 0.30 : 0.13), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 76)
            }
            .cardSurface(highlighted: isPulsing)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(folder.tint.opacity(isPulsing ? 0.95 : 0.45))
                    .frame(height: isPulsing ? 3 : 2)
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay {
                if isLocked {
                    LockVeil(tint: folder.tint)
                }
            }
            .overlay {
                // Amber halo while a dragged document hovers over the tile.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isDropTarget ? Theme.amber : .clear, lineWidth: 3)
                    .shadow(color: Theme.amber.opacity(isDropTarget ? 0.6 : 0), radius: 14)
            }
            .scaleEffect(isDropTarget ? 1.06 : (isPulsing ? 1.045 : 1))
            .shadow(color: folder.tint.opacity(isPulsing || isDropTarget ? 0.45 : 0), radius: 20)
        }
        .buttonStyle(PressableStyle())
        .animation(Theme.soft, value: isPulsing)
        .animation(Theme.soft, value: count)
        .animation(Theme.snap, value: isDropTarget)
        .accessibilityLabel("\(folder.name) folder, \(countLabel)\(isDropTarget ? ", ready to receive" : "")")
    }

    private var countLabel: String {
        count == 1 ? "1 doc" : "\(count) docs"
    }
}

/// Frosted veil + animated lock shown over a sealed vault folder.
private struct LockVeil: View {
    let tint: Color

    @State private var shimmer = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.25))

            VStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse)

                Text("Face ID Required")
                    .font(Theme.mono(.caption2, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
    }
}

/// Dashed ghost tile that opens the folder editor.
struct NewFolderCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 42, height: 42)
                    .background {
                        Circle().fill(Theme.amber.opacity(0.12))
                    }
                Text("New Folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 138)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.02))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Theme.hairline,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
        }
        .buttonStyle(PressableStyle())
    }
}

#Preview {
    ZStack {
        Theme.backdrop
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            FolderCard(folder: AppFolder.mockList[1], count: 8) {}
            FolderCard(folder: AppFolder.mockList[2], count: 3, isPulsing: true) {}
            NewFolderCard {}
        }
        .padding(20)
    }
    .preferredColorScheme(.dark)
}
