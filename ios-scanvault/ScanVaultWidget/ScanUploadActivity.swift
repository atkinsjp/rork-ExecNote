//
//  ScanUploadActivity.swift
//  ScanVaultWidget
//
//  Live Activity for documents moving through the scan → redact → upload
//  pipeline: Lock Screen banner + Dynamic Island (compact, expanded, minimal).
//

import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct ScanUploadActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScanActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.071, green: 0.078, blue: 0.098).opacity(0.92))
                .activitySystemActionForegroundColor(Color(red: 0.910, green: 0.639, blue: 0.239))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))
                        Text("ScanVault")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusBadge(for: context.state.status)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.documentTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        // Animated gradient progress bar.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.969, green: 0.804, blue: 0.486),
                                                Color(red: 0.910, green: 0.639, blue: 0.239),
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(8, proxy.size.width * progressFraction(context.state)))
                            }
                        }
                        .frame(height: 7)

                        HStack(spacing: 8) {
                            // Destination folder badge.
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Filing into \(context.attributes.folderName)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))

                            Spacer(minLength: 4)

                            Text("\(context.attributes.pageCount) pages")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            } compactLeading: {
                // App mini-icon + animated processing spinner.
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))
                    if isProcessing(context.state.status) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color(red: 0.910, green: 0.639, blue: 0.239))
                    }
                }
            } compactTrailing: {
                // Real-time percentage badge.
                Text("\(Int(progressFraction(context.state) * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        context.state.status == .failed
                            ? Color(red: 0.886, green: 0.4, blue: 0.31)
                            : Color(red: 0.910, green: 0.639, blue: 0.239)
                    )
            } minimal: {
                Image(systemName: minimalSymbol(for: context.state.status))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.910, green: 0.639, blue: 0.239))
            }
            .widgetURL(nil)
        }
    }

    // MARK: - Helpers

    private func progressFraction(_ state: ScanActivityAttributes.ContentState) -> Double {
        min(1, max(0, state.uploadProgress))
    }

    private func isProcessing(_ status: UploadStatus) -> Bool {
        status == .scanning || status == .redacting || status == .uploading
    }

    private func minimalSymbol(for status: UploadStatus) -> String {
        switch status {
        case .scanning: "doc.viewfinder"
        case .redacting: "eye.slash"
        case .uploading: "arrow.up.icloud"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private func statusBadge(for status: UploadStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(
            status == .failed
                ? Color(red: 0.886, green: 0.4, blue: 0.31)
                : status == .completed
                    ? Color(red: 0.247, green: 0.690, blue: 0.627)
                    : Color(red: 0.910, green: 0.639, blue: 0.239)
        )
    }
}

// MARK: - Lock Screen banner

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<ScanActivityAttributes>

    private var progress: Double {
        min(1, max(0, context.state.uploadProgress))
    }

    var body: some View {
        HStack(spacing: 13) {
            // Document thumbnail tile / status glyph.
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 46, height: 46)
                Image(systemName: context.state.status.symbolName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: isProcessing)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(context.attributes.documentTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if context.state.status == .completed {
                        Label("Filed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.247, green: 0.690, blue: 0.627))
                    } else {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.969, green: 0.804, blue: 0.486),
                                        Color(red: 0.910, green: 0.639, blue: 0.239),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, proxy.size.width * progress))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    Text("Filing into \(context.attributes.folderName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Quick tap opens the app (Live Activity default action).
                    Label("View in App", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .padding(15)
    }

    private var tint: Color {
        switch context.state.status {
        case .failed: Color(red: 0.886, green: 0.4, blue: 0.31)
        case .completed: Color(red: 0.247, green: 0.690, blue: 0.627)
        default: Color(red: 0.910, green: 0.639, blue: 0.239)
        }
    }

    private var isProcessing: Bool {
        context.state.status == .scanning
            || context.state.status == .redacting
            || context.state.status == .uploading
    }
}
