//
//  ContentView.swift
//  ScanVault
//

import SwiftUI

/// Root container: owns the shared vault + scanner + subscription state,
/// greets first-time users with the landing hero, runs the onboarding
/// conversion flow, and hands everything down through the environment.
struct ContentView: View {
    @State private var store = VaultStore()
    @State private var scanner = ScannerManager()
    @State private var subscriptions = SubscriptionManager.shared
    @State private var locks = VaultLockManager.shared

    /// Landing → onboarding → live vault. Returning users land straight in.
    @State private var launchPhase: LaunchPhase = OnboardingPaywallCoordinator.hasCompletedBefore ? .app : .landing
    @Environment(\.scenePhase) private var scenePhase

    /// Scene-wide appearance override; every sheet and cover inherits this.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.light.rawValue

    var body: some View {
        launchRoot
            .environment(store)
            .environment(scanner)
            .environment(subscriptions)
            .environment(locks)
            .environment(DeepLinkRouter.shared)
            .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .light).colorScheme)
            .onOpenURL { url in
                handleDeepLink(url)
            }
            .onChange(of: scenePhase) { _, phase in
                // Every vault folder re-seals the moment the app backgrounds.
                if phase != .active {
                    locks.lockAll()
                }
            }
            .alert(
                "Scanning problem",
                isPresented: Binding(
                    get: { scanner.errorMessage != nil },
                    set: { if !$0 { scanner.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { scanner.errorMessage = nil }
            } message: {
                Text(scanner.errorMessage ?? "")
            }
    }

    // MARK: - Launch flow

    private enum LaunchPhase {
        case landing
        case onboarding
        case app
    }

    @ViewBuilder
    private var launchRoot: some View {
        switch launchPhase {
        case .landing:
            HomeLandingView {
                launchPhase = .onboarding
            }
            .transition(.opacity.combined(with: .scale(scale: 1.04)))
        case .onboarding:
            OnboardingFlowView { persona in
                launchPhase = .app
                Task {
                    await store.bootstrap()
                    if let persona {
                        await store.applyPersona(persona)
                    }
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .opacity
            ))
        case .app:
            MainDashboardView()
                .transition(.opacity)
        }
    }

    /// Deep links raised by widgets, quick actions and App Intents:
    /// `scanvault://scan`, `scanvault://redact`, `scanvault://vault`.
    private func handleDeepLink(_ url: URL) {
        let link = url.host.flatMap(DeepLink.init(rawValue:))
            ?? DeepLink(rawValue: url.lastPathComponent)
        guard let link else { return }
        DeepLinkRouter.shared.open(link)
    }
}

#Preview {
    MainDashboardView()
        .environment(VaultStore.mock())
        .environment(ScannerManager())
        .environment(SubscriptionManager.previewInstance)
        .environment(VaultLockManager.shared)
        .environment(DeepLinkRouter.shared)
}
