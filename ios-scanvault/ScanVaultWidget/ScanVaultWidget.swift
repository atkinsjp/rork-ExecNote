//
//  ScanVaultWidget.swift
//  ScanVaultWidget
//
//  Home Screen + Lock Screen widget suite: one-tap scan actions, the two most
//  recent documents, and monthly scan stats — fed from the App Group snapshot.
//

import SwiftUI
import WidgetKit

// MARK: - Design tokens (mirrors the app's graphite/amber aesthetic)

private enum WidgetTheme {
    static let ink = Color(red: 0.043, green: 0.047, blue: 0.059)
    static let inkRaised = Color(red: 0.071, green: 0.078, blue: 0.098)
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.114)
    static let hairline = Color(white: 1, opacity: 0.08)
    static let amber = Color(red: 0.910, green: 0.639, blue: 0.239)
    static let amberBright = Color(red: 0.969, green: 0.804, blue: 0.486)
    static let textPrimary = Color(red: 0.945, green: 0.941, blue: 0.929)
    static let textSecondary = Color(red: 0.580, green: 0.592, blue: 0.631)
    static let textTertiary = Color(red: 0.384, green: 0.396, blue: 0.435)
    static let paper = Color(red: 0.957, green: 0.945, blue: 0.918)
}

// MARK: - Timeline

struct VaultWidgetEntry: TimelineEntry {
    let date: Date
    let documents: [WidgetDocumentSnapshot]
    let stats: VaultWidgetStats

    static let placeholder = VaultWidgetEntry(
        date: .now,
        documents: [
            WidgetDocumentSnapshot(id: "w1", title: "Apartment Lease Agreement", createdAt: .now.addingTimeInterval(-3_600), pageCount: 12, thumbnailData: nil),
            WidgetDocumentSnapshot(id: "w2", title: "Q3 Expense Receipts", createdAt: .now.addingTimeInterval(-86_400), pageCount: 5, thumbnailData: nil),
        ],
        stats: VaultWidgetStats(monthScans: 17, totalDocuments: 84)
    )
}

struct VaultWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> VaultWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (VaultWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VaultWidgetEntry>) -> Void) {
        // Refresh hourly; the app also reloads timelines after every change.
        let next = Calendar.current.date(byAdding: .minute, value: 60, to: .now) ?? .now
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> VaultWidgetEntry {
        VaultWidgetEntry(
            date: .now,
            documents: VaultWidgetStore.loadRecentDocuments(),
            stats: VaultWidgetStore.loadStats()
        )
    }
}

// MARK: - Home Screen widgets

/// Small: a single 1-tap "Scan Document" action button.
/// Medium: scan + redact buttons on the left, the two most recent documents
/// on the right.
struct QuickScanWidget: Widget {
    let kind = "QuickScanWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VaultWidgetProvider()) { entry in
            QuickScanWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Scan")
        .description("Scan documents instantly and jump back into your recent files.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickScanWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: VaultWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumScanView(entry: entry)
        default:
            SmallScanView()
        }
    }
}

// MARK: Small

private struct SmallScanView: View {
    var body: some View {
        VStack(spacing: 10) {
            Button(intent: OpenScannerIntent()) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [WidgetTheme.amberBright, WidgetTheme.amber],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 58, height: 58)
                        Image(systemName: "doc.viewfinder.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(WidgetTheme.ink)
                    }
                    Text("Scan")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [WidgetTheme.inkRaised, WidgetTheme.ink],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: Medium

private struct MediumScanView: View {
    let entry: VaultWidgetEntry

    var body: some View {
        HStack(spacing: 14) {
            // Left: quick actions.
            VStack(spacing: 8) {
                Button(intent: OpenScannerIntent()) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.viewfinder.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Quick Scan")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(WidgetTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        Capsule().fill(
                            LinearGradient(
                                colors: [WidgetTheme.amberBright, WidgetTheme.amber],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    }
                }
                .buttonStyle(.plain)

                Button(intent: OpenRedactIntent()) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Redact PII")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(WidgetTheme.amberBright)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        Capsule().fill(WidgetTheme.amber.opacity(0.16))
                    }
                    .overlay { Capsule().strokeBorder(WidgetTheme.amber.opacity(0.5), lineWidth: 1) }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .frame(width: 118)

            Rectangle()
                .fill(WidgetTheme.hairline)
                .frame(width: 1)

            // Right: the two most recent documents.
            VStack(alignment: .leading, spacing: 8) {
                if entry.documents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 16))
                            .foregroundStyle(WidgetTheme.textTertiary)
                        Text("Nothing scanned yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WidgetTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ForEach(entry.documents.prefix(2)) { document in
                        RecentDocumentRow(document: document)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [WidgetTheme.inkRaised, WidgetTheme.ink],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct RecentDocumentRow: View {
    let document: WidgetDocumentSnapshot

    var body: some View {
        Button(intent: OpenVaultIntent()) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(WidgetTheme.paper.opacity(0.9))
                        .frame(width: 26, height: 34)
                    if let data = document.thumbnailData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 32)
                            .clipShape(.rect(cornerRadius: 4, style: .continuous))
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(WidgetTheme.ink.opacity(0.7))
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(document.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(document.pageCount) pg · \(document.createdAt, format: .relative(presentation: .named))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(WidgetTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen accessory widgets

/// Lock Screen companions: a circular one-tap camera trigger and a
/// rectangular stats readout (monthly scans + latest filed title).
struct VaultAccessoryWidget: Widget {
    let kind = "VaultAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VaultWidgetProvider()) { entry in
            VaultAccessoryView(entry: entry)
        }
        .configurationDisplayName("IntelliDoc Lock Screen")
        .description("One-tap camera trigger and your latest scans.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct VaultAccessoryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: VaultWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: OpenScannerIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "doc.viewfinder.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .containerBackground(for: .widget) { Color.clear }

        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.stats.monthScans) scans this month")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(entry.stats.totalDocuments) documents in vault")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                if let latest = entry.documents.first {
                    Text(latest.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    Text("Tap to scan your first doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}
