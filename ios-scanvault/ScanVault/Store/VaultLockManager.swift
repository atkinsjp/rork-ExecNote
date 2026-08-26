//
//  VaultLockManager.swift
//  ScanVault
//

import Foundation
import Observation

/// Isolated vault state: whether the whole document vault is sealed behind
/// Face ID / Touch ID, and which biometric-protected folders are unlocked in
/// this session.
///
/// The app-level gate seals at launch and re-seals whenever the app leaves
/// the foreground, so nothing is visible without an unlock. Locked folders
/// additionally re-seal independently (`scenePhase == .background`).
@MainActor
@Observable
final class VaultLockManager {
    static let shared = VaultLockManager()

    /// Whole-app gate: sealed until a successful biometric/passcode unlock.
    private(set) var isAppSealed: Bool = true

    /// Folder IDs unlocked during this foreground session.
    private(set) var unlockedFolderIds: Set<String> = []

    /// Folder currently showing its authentication prompt (drives UI states).
    private(set) var isAuthenticating: Bool = false

    /// Human-readable failure from the last unlock attempt, if any.
    var lastError: String?

    private init() {}

    // MARK: - Queries

    func isUnlocked(_ folder: AppFolder) -> Bool {
        guard folder.isBiometricLocked else { return true }
        return unlockedFolderIds.contains(folder.id)
    }

    func isLocked(_ folder: AppFolder) -> Bool {
        folder.isBiometricLocked && !unlockedFolderIds.contains(folder.id)
    }

    /// Documents hidden from search / recents while their folder is sealed.
    func hidesContents(of folder: AppFolder) -> Bool {
        isLocked(folder)
    }

    // MARK: - App gate

    /// Re-seals the entire vault. Called when the scene leaves the foreground.
    /// Skipped mid-authentication so sealing never fights an active prompt.
    func sealApp() {
        guard !isAuthenticating else { return }
        isAppSealed = true
    }

    /// Runs the Face ID / Touch ID / passcode prompt and opens the vault on
    /// success.
    @discardableResult
    func unsealApp() async -> Bool {
        guard isAppSealed else { return true }
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        let result = await BiometricAuthService.authenticate(
            reason: "Unlock your document vault"
        )
        switch result {
        case .success:
            isAppSealed = false
            return true
        case .failure(let message):
            lastError = message
            return false
        }
    }

    // MARK: - Locking

    /// Re-seals every vault folder. Called when the scene leaves the foreground.
    func lockAll() {
        guard !unlockedFolderIds.isEmpty else { return }
        unlockedFolderIds.removeAll()
    }

    func lock(_ folder: AppFolder) {
        unlockedFolderIds.remove(folder.id)
    }

    // MARK: - Unlocking

    /// Prompts Face ID / passcode and unlocks `folder` on success.
    @discardableResult
    func unlock(_ folder: AppFolder) async -> Bool {
        guard folder.isBiometricLocked else { return true }
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        let result = await BiometricAuthService.authenticate(
            reason: "Unlock the \(folder.name) folder"
        )
        switch result {
        case .success:
            unlockedFolderIds.insert(folder.id)
            return true
        case .failure(let message):
            lastError = message
            return false
        }
    }
}
