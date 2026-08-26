//
//  AppDelegate.swift
//  ScanVault
//

import UIKit

// MARK: - Quick action types

/// Home Screen quick action identifiers (long-press / 3D Touch on the icon).
@MainActor
enum QuickActionType {
    static let scan = "com.redactit.scan"
    static let redact = "com.redactit.redact"
    static let vault = "com.redactit.vault"

    /// Routes a quick action type into the SwiftUI navigation layer.
    static func route(_ type: String) {
        switch type {
        case scan: DeepLinkRouter.shared.open(.scan)
        case redact: DeepLinkRouter.shared.open(.redact)
        case vault: DeepLinkRouter.shared.open(.vault)
        default: break
        }
    }
}

/// App entry point extras: installs the dynamic Home Screen quick actions and
/// bridges scene-level quick action taps into `DeepLinkRouter`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        installQuickActions()
        return true
    }

    /// Quick actions are installed dynamically so no static Info.plist arrays
    /// are needed.
    private func installQuickActions() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: QuickActionType.scan,
                localizedTitle: "Scan Document",
                localizedSubtitle: "Open the document camera",
                icon: UIApplicationShortcutIcon(systemImageName: "doc.viewfinder")
            ),
            UIApplicationShortcutItem(
                type: QuickActionType.redact,
                localizedTitle: "Scan & Redact",
                localizedSubtitle: "Capture, then strip PII",
                icon: UIApplicationShortcutIcon(systemImageName: "eye.slash")
            ),
            UIApplicationShortcutItem(
                type: QuickActionType.vault,
                localizedTitle: "Open Vault",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "lock.shield")
            ),
        ]
    }

    /// Gives the SwiftUI scene a custom delegate that receives quick action
    /// taps while SwiftUI keeps managing the window hierarchy.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// Receives quick action taps for both cold and warm launches.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Cold launch: the quick action arrives with the connection options.
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in
                QuickActionType.route(item.type)
            }
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            QuickActionType.route(shortcutItem.type)
        }
        completionHandler(true)
    }
}
