//
//  AppFolder.swift
//  IntelliDocScanSignPDF
//

import Foundation
import SwiftUI

/// A user-created filing folder that groups scanned documents.
nonisolated struct AppFolder: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var iconName: String
    var colorHex: String
    var isBiometricLocked: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        iconName: String = "folder.fill",
        colorHex: String = "E8A33D",
        isBiometricLocked: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.isBiometricLocked = isBiometricLocked
        self.createdAt = createdAt
    }
}

extension AppFolder {
    var tint: Color { Color(hex: colorHex) }

    /// Folder used for scans the user never explicitly filed.
    static let inboxID = "inbox"

    static let inbox = AppFolder(
        id: inboxID,
        name: "Inbox",
        iconName: "tray.full.fill",
        colorHex: "E8A33D",
        createdAt: .distantPast
    )

    static let mockList: [AppFolder] = [
        inbox,
        AppFolder(id: "f-work", name: "Work", iconName: "briefcase.fill", colorHex: "4A90D9"),
        AppFolder(id: "f-health", name: "Health", iconName: "stethoscope", colorHex: "3FB0A0", isBiometricLocked: true),
        AppFolder(id: "f-home", name: "Home", iconName: "house.fill", colorHex: "E2664F"),
        AppFolder(id: "f-travel", name: "Travel", iconName: "airplane", colorHex: "8A7CE0"),
    ]
}
