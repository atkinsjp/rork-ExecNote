//
//  FeatureTourView.swift
//  IntelliDocScanSignPDF
//

import SwiftUI

// MARK: - Page model

/// One page of the how-to walkthrough.
struct TourPage: Identifiable {
    let id: Int
    let symbol: String
    let tint: Color
    let title: String
    let headline: String
    let steps: [String]
}

// MARK: - Feature tour

/// Paged "how to use IntelliDoc" walkthrough. Runs inside the launch
/// onboarding flow, and can be replayed any time from Settings via
/// `isReplay`, which swaps the header for an explicit close button.
struct FeatureTourView: View {
    /// Called when the user finishes or skips the tour.
    let onFinish: () -> Void

    /// Replay mode (from Settings) adds a close button in the top bar.
    var isReplay = false

    @State private var pageIndex = 0

    private let pages: [TourPage] = [
        TourPage(
            id: 0,
            symbol: "doc.viewfinder",
            tint: Theme.amber,
            title: "Scan anything",
            headline: "The camera finds the page edges for you.",
            steps: [
                "Tap the amber Scan button on the dashboard or inside any folder",
                "Hold the page in view — the frame locks onto its edges and captures on its own",
                "Keep capturing more pages, then tap Done when you're finished",
            ]
        ),
        TourPage(
            id: 1,
            symbol: "folder.fill",
            tint: Color(hex: "3FB0A0"),
            title: "Review & file it",
            headline: "Your pages become one tidy PDF.",
            steps: [
                "Give the scan a name you'll recognize later",
                "Pick a folder — anything unfiled waits in the Inbox",
                "Reopen it any time from Recent scans on the dashboard",
            ]
        ),
        TourPage(
            id: 2,
            symbol: "eye.slash.fill",
            tint: Color(hex: "E2664F"),
            title: "Redact with one tap",
            headline: "SSNs, cards and phones are found for you.",
            steps: [
                "Open a document and choose Redact from its menu",
                "Detected sensitive items appear — tap each one to burn it out",
                "Redaction is permanent and runs entirely on this device",
            ]
        ),
        TourPage(
            id: 3,
            symbol: "signature",
            tint: Theme.amber,
            title: "Sign & finalize",
            headline: "From scan to signed PDF in seconds.",
            steps: [
                "Open the document and tap the amber Sign & Finalize button",
                "Draw your signature with a finger or Apple Pencil and place it",
                "Export the signed PDF with a tamper-evident audit trail",
            ]
        ),
        TourPage(
            id: 4,
            symbol: "text.magnifyingglass",
            tint: Color(hex: "8A7CE0"),
            title: "Find anything fast",
            headline: "Search reads the words on every page.",
            steps: [
                "Search matches titles, tags and the actual text captured by OCR",
                "Add custom tags to group related documents",
                "Sort your vault by name, date or file size",
            ]
        ),
        TourPage(
            id: 5,
            symbol: "lock.shield.fill",
            tint: Color(hex: "4A90D9"),
            title: "Private by design",
            headline: "Your vault stays yours.",
            steps: [
                "Scanning, redaction and signing all happen on this device",
                "Cloud backup only happens when you allow it",
                "Face ID keeps sensitive folders sealed — even in the app switcher",
            ]
        ),
    ]

    private var isLastPage: Bool {
        pageIndex >= pages.count - 1
    }

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                topBar

                TabView(selection: $pageIndex) {
                    ForEach(pages) { page in
                        TourPageContent(page: page)
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                controls
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if isReplay {
                Button {
                    Haptics.selection()
                    onFinish()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.surfaceHigh) }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close tour")
            }

            Spacer()

            Text(isReplay ? "Feature tour" : "How it works")
                .font(Theme.mono(.caption, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(pages) { page in
                    Capsule()
                        .fill(page.id == pageIndex ? Theme.amber : Theme.hairline)
                        .frame(width: page.id == pageIndex ? 22 : 7, height: 7)
                }
            }
            .animation(Theme.snap, value: pageIndex)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                if pageIndex > 0 {
                    Button {
                        Haptics.selection()
                        withAnimation(Theme.flight) { pageIndex -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 52, height: 52)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Previous page")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                Button {
                    Haptics.impact(.medium)
                    if isLastPage {
                        onFinish()
                    } else {
                        withAnimation(Theme.flight) { pageIndex += 1 }
                    }
                } label: {
                    Text(isLastPage ? "Get Started" : "Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            Capsule().fill(
                                LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                            )
                        }
                }
                .buttonStyle(PressableStyle(scale: 0.97))
            }
            .padding(.horizontal, 26)
            .animation(Theme.snap, value: pageIndex)

            Group {
                if !isLastPage {
                    Button {
                        Haptics.selection()
                        onFinish()
                    } label: {
                        Text("Skip tour")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Skip the feature tour")
                }
            }
            .frame(height: 20)
        }
    }
}

// MARK: - Page content

private struct TourPageContent: View {
    let page: TourPage

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)

            visual

            VStack(spacing: 8) {
                Text(page.title)
                    .font(Theme.display(.title2))
                    .foregroundStyle(Theme.textPrimary)
                Text(page.headline)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)

            VStack(spacing: 12) {
                ForEach(Array(page.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(page.tint)
                            .frame(width: 22, height: 22)
                            .background { Circle().fill(page.tint.opacity(0.14)) }

                        Text(step)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 18)

            Spacer(minLength: 18)
        }
    }

    /// Light-table styled visual: the feature's symbol floating over a
    /// dashed guide frame with ghosted "document" lines beneath it.
    private var visual: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.surfaceHigh)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    page.tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                .padding(18)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(page.tint.opacity(0.14))
                        .frame(width: 74, height: 74)
                    Image(systemName: page.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(page.tint)
                }

                VStack(spacing: 7) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(width: 132, height: 6)
                    Capsule().fill(Color.white.opacity(0.09)).frame(width: 96, height: 6)
                    Capsule().fill(Color.white.opacity(0.06)).frame(width: 112, height: 6)
                }
            }
        }
        .frame(height: 210)
        .padding(.horizontal, 34)
    }
}

// MARK: - Preview

#Preview {
    FeatureTourView(isReplay: true) {}
        .preferredColorScheme(.dark)
}
