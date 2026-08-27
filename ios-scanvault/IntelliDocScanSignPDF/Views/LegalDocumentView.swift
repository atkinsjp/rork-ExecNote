//
//  LegalDocumentView.swift
//  IntelliDocScanSignPDF
//

import SafariServices
import SwiftUI

/// In-app legal document browser used by every mandated link surface
/// (paywall footer, Settings → Legal & Privacy).
///
/// - **Online:** renders the hosted page inside `SFSafariViewController`
///   (shared cookies, Safari-grade accessibility, no context loss).
/// - **Offline:** falls back to an accurate bundled Markdown summary so App
///   Store review and airplane-mode users never hit a dead link.
/// - Third-party license notices are rendered natively by design.
struct LegalDocumentView: View {
    let kind: LegalDocumentKind

    @Environment(\.dismiss) private var dismiss
    @State private var resolvedURL: URL?

    private var usesNativeReader: Bool {
        kind == .thirdPartyLicenses || !OfflineSyncCoordinator.shared.isNetworkAvailable || resolvedURL == nil
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                headerBar

                if usesNativeReader {
                    nativeReader(LegalDocumentConfig.fallbackContent(for: kind))
                } else if let resolvedURL {
                    SafariViewController(url: resolvedURL)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .task {
            // One coarse event per viewing surface — the document identity is
            // developer-controlled, not user data.
            TelemetryService.track(.legalPolicyViewed, attributes: ["surface": kind.rawValue])
            guard kind != .thirdPartyLicenses else { return }
            resolvedURL = LegalDocumentConfig.url(for: kind)
        }
    }

    // MARK: - Chrome

    /// Custom navigation bar: explicit close affordance + hand-off to Safari.
    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background { Circle().fill(Theme.surfaceHigh) }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close \(kind.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(usesNativeReader ? "Offline copy" : "Updated remotely")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if !usesNativeReader, let resolvedURL {
                Button {
                    Haptics.impact(.light)
                    UIApplication.shared.open(resolvedURL)
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.amber)
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.amber.opacity(0.12)) }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Open in Safari")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Native fallback reader

    private func nativeReader(_ markdown: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(formattedMarkdown(markdown))
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
        }
    }

    private func formattedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(markdown)
    }
}

// MARK: - Safari bridge

private struct SafariViewController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor.systemOrange
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

#Preview("Privacy · offline") {
    LegalDocumentView(kind: .privacyPolicy)
}
