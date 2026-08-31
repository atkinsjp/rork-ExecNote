//
//  IntelliDocScanSignPDFApp.swift
//  IntelliDocScanSignPDF
//

import AppIntents
import RevenueCat
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

        // Configure RevenueCat once at launch — before SubscriptionManager
        // (which reads Purchases.shared) is ever touched. Falls back to the
        // mock storefront when no key is injected (bare local builds).
        let apiKey: String
        #if DEBUG
        apiKey = Config.EXPO_PUBLIC_REVENUECAT_TEST_API_KEY
        #else
        apiKey = Config.EXPO_PUBLIC_REVENUECAT_IOS_API_KEY
        #endif
        if !apiKey.isEmpty {
            #if DEBUG
            Purchases.logLevel = .debug
            #endif
            Purchases.configure(withAPIKey: apiKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Theme.amber)
        }
    }
}
