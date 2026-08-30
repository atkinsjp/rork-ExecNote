//
//  HomeLandingView.swift
//  IntelliDoc
//

import SwiftUI

/// The first thing a brand-new user sees: the vault logo breathing under its
/// amber scan light, a one-line promise, and a single "Get Started" action
/// that opens the interactive how-it-works onboarding.
struct HomeLandingView: View {
    let onGetStarted: () -> Void

    @State private var isLogoLit = false
    @State private var featuresRevealed = false

    private let features: [(symbol: String, label: String)] = [
        ("doc.viewfinder", "Scan"),
        ("eye.slash.fill", "Redact"),
        ("signature", "Sign"),
        ("archivebox.fill", "File"),
    ]

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                BrandMark()
                    .frame(width: 148, height: 148)
                    // Ambient depth for the icon card.
                    .shadow(color: Color.black.opacity(0.18), radius: 24, y: 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    // Realistic optical scanner beam, tightly clipped to the card.
                    .overlay { HeroScannerBeam(isLit: isLogoLit) }
                    .animation(Theme.soft, value: isLogoLit)

                Text("IntelliDoc")
                    .font(.system(size: 42, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 26)

                Text("Your paper, filed and safe.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)

                // Amber keystone divider echoing the Welcome page header.
                HStack(spacing: 5) {
                    Capsule().fill(Theme.amber).frame(width: 34, height: 3)
                    Circle().fill(Theme.amber.opacity(0.55)).frame(width: 4, height: 4)
                    Capsule().fill(Theme.amber.opacity(0.35)).frame(width: 14, height: 3)
                }
                .padding(.top, 20)

                Spacer(minLength: 10)

                HStack(spacing: 10) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        VStack(spacing: 7) {
                            Image(systemName: feature.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(hex: "E5A93C"))
                                .symbolEffect(.bounce, value: featuresRevealed)
                            Text(feature.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 4)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.04), lineWidth: 1)
                        }
                        .opacity(featuresRevealed ? 1 : 0)
                        .offset(y: featuresRevealed ? 0 : 16)
                        .animation(
                            Theme.flight.delay(Double(index) * 0.09),
                            value: featuresRevealed
                        )
                    }
                }
                .padding(.horizontal, 30)

                Spacer(minLength: 16)

                Button {
                    Haptics.impact(.medium)
                    withAnimation(Theme.flight) {
                        onGetStarted()
                    }
                } label: {
                    Text("Get Started")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Theme.amberBright, Theme.amber],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                // Inner highlight rim: bright lip at the top
                                // edge melting into the gradient below.
                                .overlay {
                                    Capsule().stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.5), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                                }
                        }
                        .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 8)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .padding(.horizontal, 30)

                Label("Private by design • All processing stays on your device.", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .padding(.top, 16)
                    .padding(.bottom, 22)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(0.35))
            withAnimation(Theme.flight) { isLogoLit = true }
            try? await Task.sleep(for: .milliseconds(0.45))
            withAnimation(Theme.flight) { featuresRevealed = true }
            Haptics.selection()
        }
    }
}

// MARK: - Hero scanner beam

/// Realistic optical scanner beam for the welcome hero: a 1.5pt white-gold
/// core line, a 35pt gradient light trail behind the direction of travel,
/// and a soft blurred ambient glow riding the scan head. The beam eases up
/// and down (2.2s per sweep, ease-in-out) with a slight lingering pause at
/// each bound, and is hard-clipped to the dark card's 32pt rounded corners.
private struct HeroScannerBeam: View {
    let isLit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var beamY: CGFloat = -Self.travel
    @State private var isMovingDown = true

    /// Card half-height minus an inset so the beam never kisses the corners.
    private static let travel: CGFloat = 58
    private static let trailHeight: CGFloat = 35

    var body: some View {
        ZStack {
            // Ambient glow riding the scan head.
            Capsule()
                .fill(Color(hex: "FFC533").opacity(0.55))
                .frame(height: 5)
                .frame(maxWidth: .infinity)
                .blur(radius: 4)
                .offset(y: beamY)

            // Light trail behind the scan direction.
            LinearGradient(
                colors: [Color(hex: "FFB800").opacity(0.35), .clear],
                startPoint: isMovingDown ? .bottom : .top,
                endPoint: isMovingDown ? .top : .bottom
            )
            .frame(height: Self.trailHeight)
            .frame(maxWidth: .infinity)
            .offset(y: beamY + (isMovingDown ? -Self.trailHeight / 2 : Self.trailHeight / 2))

            // High-intensity core beam: bright white-yellow center,
            // dissolving to nothing at the card edges.
            LinearGradient(
                colors: [
                    Color(hex: "FFB800").opacity(0),
                    Color(hex: "FFF7DB"),
                    Color(hex: "FFC533"),
                    Color(hex: "FFB800").opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
            .offset(y: beamY)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .opacity(reduceMotion ? (isLit ? 0.6 : 0) : (isLit ? 1 : 0))
        .animation(Theme.soft, value: isLit)
        .task(id: isLit) {
            guard isLit, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(0.55))
            while !Task.isCancelled {
                isMovingDown = true
                withAnimation(.easeInOut(duration: 2.2)) { beamY = Self.travel }
                try? await Task.sleep(for: .seconds(2.6))
                isMovingDown = false
                withAnimation(.easeInOut(duration: 2.2)) { beamY = -Self.travel }
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }
}

// MARK: - Logo

/// The IntelliDoc mark, drawn in code: a graphite vault-fronted folder holding
/// a paper-white page, sealed by an amber dial. The traveling scan light in
/// `.scanSweep` plays over it while the hero is lit.
struct BrandMark: View {
    var body: some View {
        ZStack {
            // Vault-front folder body.
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "22252D"), Color(hex: "12141A")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1.5)
                }

            // Folder tab (kept inside the card so nothing pokes above it).

            // Stacked pages peeking out.
            VStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { offset in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.paper.shadow(.drop(color: .black.opacity(0.25), radius: 3, y: 2)))
                        .frame(width: CGFloat(78 - offset * 8), height: 8)
                        .opacity(offset == 0 ? 1 : 0.75)
                        .rotationEffect(.degrees(offset == 0 ? -2 : 1.5))
                }
            }
            .offset(y: -34)

            // The page itself.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.paper)
                .frame(width: 62, height: 76)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Theme.amber).frame(width: 30, height: 4)
                        Capsule().fill(Color(hex: "C9C4B8")).frame(height: 3)
                        Capsule().fill(Color(hex: "C9C4B8")).frame(width: 40, height: 3)
                        Capsule().fill(Color(hex: "DDD8CC")).frame(width: 24, height: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, 9)
                }
                .rotationEffect(.degrees(-3))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                .offset(y: 12)

            // Amber vault dial.
            ZStack {
                Circle()
                    .strokeBorder(Theme.amber, lineWidth: 4)
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(Theme.amber)
                    .frame(width: 7, height: 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: -20, y: -18)
        }
    }
}

#Preview {
    HomeLandingView(onGetStarted: {})
}
