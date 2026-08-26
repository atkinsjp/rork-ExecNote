//
//  VaultWidgetSnapshot.swift
//  ScanVault
//
//  Shared data feed between the app and the widget suite: recent documents
//  and the monthly scan count, persisted in the App Group container.
//

import Foundation

/// App Group used by the app, widget extension and Live Activity.
nonisolated enum VaultAppGroup {
    static let identifier = "group.app.rork.z4zldr54ge2drzlwxaace"

    /// Container directory shared across targets; nil when entitlements are
    /// missing (e.g. previews), in which case features degrade gracefully.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Compact document record readable by the widget without loading the vault.
nonisolated struct WidgetDocumentSnapshot: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let createdAt: Date
    let pageCount: Int
    /// Small JPEG thumbnail bytes rendered by the widget.
    let thumbnailData: Data?
}

/// Aggregated vault stats shown on the Lock Screen accessory widget.
nonisolated struct VaultWidgetStats: Codable, Sendable, Equatable {
    var monthScans: Int
    var totalDocuments: Int
}

/// Wire format persisted in the App Group container.
private nonisolated struct VaultWidgetPayload: Codable {
    var recent: [WidgetDocumentSnapshot]
    var stats: VaultWidgetStats
}

nonisolated enum VaultWidgetStore {
    private static var snapshotURL: URL? {
        VaultAppGroup.containerURL?.appending(path: "widget-snapshot.json")
    }

    // MARK: - Write (main app)

    /// Persists the recent documents + stats consumed by the widgets.
    static func save(recent: [WidgetDocumentSnapshot], stats: VaultWidgetStats) {
        guard let url = snapshotURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(VaultWidgetPayload(recent: recent, stats: stats)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Read (widget)

    /// Recent documents, newest first (at most the handful the widgets show).
    static func loadRecentDocuments() -> [WidgetDocumentSnapshot] {
        loadPayload()?.recent ?? []
    }

    static func loadStats() -> VaultWidgetStats {
        loadPayload()?.stats ?? VaultWidgetStats(monthScans: 0, totalDocuments: 0)
    }

    private static func loadPayload() -> VaultWidgetPayload? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(VaultWidgetPayload.self, from: data)
        } catch {
            return nil
        }
    }
}
