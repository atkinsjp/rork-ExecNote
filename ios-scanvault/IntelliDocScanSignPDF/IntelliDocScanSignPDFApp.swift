//
//  IntelliDocScanSignPDFApp.swift
//  IntelliDocScanSignPDF
//

import AppIntents
import SwiftUI

@main
struct IntelliDocScanSignPDFApp: App {
    /// Bridges Home Screen quick actions into the SwiftUI navigation layer.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Registers App Shortcuts with Siri immediately at launch; without
        // this, spoken phrases and Spotlight tiles can go undiscovered until
        // the Shortcuts app refreshes on its own.
        IntelliDocScanSignPDFShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Theme.amber)
        }
    }
}
