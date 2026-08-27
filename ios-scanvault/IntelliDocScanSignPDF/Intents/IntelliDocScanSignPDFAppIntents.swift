//
//  IntelliDocScanSignPDFAppIntents.swift
//  IntelliDocScanSignPDF
//
//  Siri + Shortcuts surface: open the scanner, redact the clipboard, and ask
//  for the latest filed documents. The App Shortcuts provider registers these
//  automatically with localized invocation phrases.
//

import AppIntents
import UIKit

// MARK: - Scan

/// "Hey Siri, scan a document in IntelliDocScanSignPDF" — opens straight into the
/// VisionKit document camera.
struct ScanDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Document"
    static var description = IntentDescription("Opens IntelliDocScanSignPDF's document camera to capture a multi-page PDF.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkRouter.shared.open(.scan)
        return .result()
    }
}

// MARK: - Redact clipboard

/// Takes an image from the clipboard (or a file passed by Shortcuts), detects
/// PII on-device and files a sanitized copy into the vault.
struct RedactClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Redact Clipboard"
    static var description = IntentDescription("Redacts personal information from an image on the clipboard and files the sanitized copy.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let image = UIPasteboard.general.image else {
            return .result(dialog: "There's no image on the clipboard to redact. Copy a screenshot or photo first.")
        }

        let store = VaultStore()
        await store.bootstrap()

        guard let document = await store.saveScan(
            pages: [image],
            title: "Clipboard Redaction",
            folderId: AppFolder.inboxID
        ) else {
            return .result(dialog: "The clipboard image couldn't be saved to the vault.")
        }

        var sourceURL: URL? = document.localURL
        if sourceURL == nil {
            sourceURL = await PDFManager.shared.existingURL(documentId: document.id)
        }
        guard let sourceURL else {
            return .result(dialog: "The scanned copy couldn't be found on this device.")
        }

        let pages = await PDFManager.shared.pageImages(for: sourceURL)
        var boxes: [RedactionBox] = []
        for (index, page) in pages.enumerated() {
            boxes += await OCRRedactionService.shared.analyzePage(page, pageIndex: index)
        }

        // Respect the free-tier redaction allowance.
        if !SubscriptionManager.shared.hasPro,
           boxes.count > SubscriptionManager.freeRedactionLimit {
            boxes = Array(boxes.prefix(SubscriptionManager.freeRedactionLimit))
        }

        guard !boxes.isEmpty else {
            return .result(dialog: "Filed the clipboard image. No personal information was detected on it.")
        }

        let applied = await store.applyRedactions(to: document, pages: pages, regions: boxes)
        return .result(
            dialog: applied
                ? "Filed a sanitized copy with \(boxes.count) redaction\(boxes.count == 1 ? "" : "s") burned in."
                : "The document was filed, but redaction failed. Open the app to retry."
        )
    }
}

// MARK: - Recent documents

/// Siri voice query returning the names of the last three filed documents.
struct GetRecentDocumentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Recent Documents"
    static var description = IntentDescription("Returns the names of your most recently filed documents.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let store = VaultStore()
        await store.bootstrap()

        let names = store.documents.prefix(3).map(\.title)
        let dialog: IntentDialog = names.isEmpty
            ? "Your vault is empty — scan something to get started."
            : "Your latest documents are \(names.enumerated().map { "\($0.offset + 1), \($0.element)" }.joined(separator: ". "))"

        return .result(value: Array(names), dialog: dialog)
    }
}

// MARK: - App Shortcuts

/// Registers automatic shortcuts in the iOS Shortcuts app and Siri.
struct IntelliDocScanSignPDFShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: [
                "Scan a document in \(.applicationName)",
                "New scan in \(.applicationName)",
                "Scan paperwork with \(.applicationName)",
            ],
            shortTitle: "Scan Document",
            systemImageName: "doc.viewfinder"
        )
        AppShortcut(
            intent: RedactClipboardIntent(),
            phrases: [
                "Redact the clipboard with \(.applicationName)",
            ],
            shortTitle: "Redact Clipboard",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: GetRecentDocumentsIntent(),
            phrases: [
                "What are my recent scans in \(.applicationName)",
                "Ask \(.applicationName) for recent documents",
            ],
            shortTitle: "Recent Scans",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
