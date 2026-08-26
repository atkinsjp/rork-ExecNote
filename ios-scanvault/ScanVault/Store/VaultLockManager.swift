//
//  VaultLockManager.swift
//  ScanVault
//

import Foundation
import Observation

/// Isolated vault state: which biometric-protected folders are currently
/// unlocked in this session.
///
/// Every locked folder re-seals the moment the app enters the background
/// (`scenePhase == .background`), so a scan left on the table never leaks
/// private contents.
@MainActor
@Observable
final class VaultLockManager {
    static let shared = VaultLockManager()

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
