//
//  AppearanceMode.swift
//  ScanVault
//

import SwiftUI

/// User-selectable appearance, persisted in `UserDefaults` and applied at the
/// scene root so every pushed screen and presented sheet follows along.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "sv.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// The concrete scheme to hand to `.preferredColorScheme`; `nil` follows
    /// the OS setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Reads the persisted mode without needing a view context.
    /// Fresh installs default to Light.
    static var stored: AppearanceMode {
        AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: storageKey) ?? ""
        ) ?? .light
    }
}
