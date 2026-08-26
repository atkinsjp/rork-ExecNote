//
//  Theme.swift
//  ScanVault
//

import SwiftUI

/// Central design tokens for ScanVault's "archive light-table" aesthetic:
/// graphite ink surfaces, warm amber light, and paper-white documents.
/// Every color is a dynamic provider, so the whole palette re-resolves when
/// the user switches between Light and Dark mode in Settings.
enum Theme {
    // MARK: Surfaces (light "warm archive paper" / dark "graphite vault")
    static let ink = adaptive("F3F0E7", "0B0C0F")
    static let inkRaised = adaptive("FFFFFF", "121419")
    static let surface = adaptive("FFFFFF", "16181D")
    static let surfaceHigh = adaptive("EDE9DE", "1E2128")
    static let hairline = adaptive("E0DACC", "2A2E38")
    static let vignette = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor(red: 0.46, green: 0.42, blue: 0.34, alpha: 0.10)
    })
    static let cardShadow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.40)
            : UIColor.black.withAlphaComponent(0.13)
    })

    // MARK: Accent
    static let amber = Color(hex: "E8A33D")
    static let amberBright = Color(hex: "F7CD7C")
    static let amberDim = Color(hex: "8A6221")

    // MARK: Content
    static let paper = Color(hex: "F4F1EA")
    static let textPrimary = adaptive("23272F", "F1F0ED")
    static let textSecondary = adaptive("5C616B", "9497A1")
    static let textTertiary = adaptive("8F929B", "62656F")

    /// Dynamic color that resolves per interface style.
    private static func adaptive(_ lightHex: String, _ darkHex: String) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? darkHex : lightHex
            return UIColor(Color(hex: hex))
        })
    }

    /// Deep atmospheric backdrop used behind every screen.
    static var backdrop: some View {
        ZStack {
            ink
            RadialGradient(
                colors: [adaptive("E6E1D3", "1C2029").opacity(0.9), .clear],
                center: .init(x: 0.5, y: -0.05),
                startRadius: 8,
                endRadius: 520
            )
            RadialGradient(
                colors: [amber.opacity(0.10), .clear],
                center: .init(x: 0.92, y: 0.02),
                startRadius: 4,
                endRadius: 340
            )
            LinearGradient(
                colors: [.clear, vignette],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Typography
    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, design: .serif, weight: .semibold)
    }

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    // MARK: Motion
    static let flight = Animation.spring(response: 0.62, dampingFraction: 0.74)
    static let snap = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let soft = Animation.spring(response: 0.45, dampingFraction: 0.85)

    /// Palette offered when creating a folder.
    static let folderPalette: [String] = [
        "E8A33D", "3FB0A0", "E2664F", "8A7CE0",
        "4A90D9", "B4C74A", "D9598A", "6B7A99",
    ]

    static let folderSymbols: [String] = [
        "folder.fill", "briefcase.fill", "heart.text.square.fill", "creditcard.fill",
        "graduationcap.fill", "house.fill", "airplane", "stethoscope",
        "car.fill", "doc.text.fill", "building.columns.fill", "shippingbox.fill",
    ]
}

extension Color {
    /// Creates a color from a 6-digit RGB hex string. Falls back to mid-grey on bad input.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Color(white: 0.5)
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1
        )
    }
}

// MARK: - Reusable surface treatment

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 22
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.surfaceHigh, Theme.surface],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: highlighted
                                ? [Theme.amber.opacity(0.65), Theme.amber.opacity(0.12)]
                                : [Color.white.opacity(0.09), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 14, y: 8)
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = 22, highlighted: Bool = false) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}
