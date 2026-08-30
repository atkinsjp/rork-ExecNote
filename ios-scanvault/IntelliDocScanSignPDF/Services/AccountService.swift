//
//  AccountService.swift
//  IntelliDocScanSignPDF
//

import AuthenticationServices
import Observation
import SwiftUI

/// Owns the Sign in with Apple session. The vault stays local-first — the
/// account only anchors identity (and later cloud sync), so users can sign
/// back in on a new device to restore purchases and shared links.
///
/// Apple reveals full name and email exactly once — on first authorization —
/// so both are cached alongside the stable `user` identifier and reused for
/// every subsequent launch.
@MainActor
@Observable
final class AccountService {
    static let shared = AccountService()

    private enum Keys {
        static let userID = "account.appleUserID"
        static let name = "account.fullName"
        static let email = "account.appleEmail"
        static let signOutLock = "account.signOutLock"
    }

    private(set) var appleUserID: String?
    private(set) var fullName: String?
    private(set) var email: String?

    /// Set when the user signs out from Settings. While true the vault stays
    /// behind the Apple sign-in gate until they sign back in — a deliberate
    /// barrier after an explicit logout (data itself never leaves the device).
    private(set) var requiresSignIn: Bool

    /// Message for the most recent sign-in failure, surfaced by whichever
    /// screen presented the Apple button. Cleared once shown.
    private(set) var lastError: String?

    var isSignedIn: Bool { appleUserID != nil }

    /// Best-effort friendly label: real name → mailbox → generic.
    var displayName: String {
        if let fullName, !fullName.isEmpty { return fullName }
        if let email {
            return email.split(separator: "@").first.map(String.init) ?? email
        }
        return "Apple ID"
    }

    private init() {
        let defaults = UserDefaults.standard
        appleUserID = defaults.string(forKey: Keys.userID)
        fullName = defaults.string(forKey: Keys.name)
        email = defaults.string(forKey: Keys.email)
        requiresSignIn = defaults.bool(forKey: Keys.signOutLock)
    }

    // MARK: - Authorization

    /// Consumes the SwiftUI button's result. Only overwrites name/email when
    /// Apple actually provides them again (they are nil on repeat sign-ins).
    func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                return
            }
            appleUserID = credential.user

            if let components = credential.fullName {
                let resolved = PersonNameComponentsFormatter().string(from: components)
                if !resolved.isEmpty { fullName = resolved }
            }
            if let email = credential.email { self.email = email }

            persist()
            setSignOutLock(false)
            Haptics.success()

        case .failure(let error):
            Haptics.warning()
            // A deliberate cancel stays silent; every other failure gets an
            // explainer — most often the device has no Apple ID signed in
            // (typical on simulators), which otherwise looks like a dead tap.
            if let authError = error as? ASAuthorizationError,
               authError.code == .canceled {
                lastError = nil
            } else {
                lastError = "Sign in with Apple didn't complete. Check that you're signed in to an Apple ID in Settings, then try again."
            }
        }
    }

    /// Dismisses the sign-in error alert.
    func clearError() {
        lastError = nil
    }

    /// Re-checks the stored credential against Apple; clears the local
    /// session if the user revoked access from iOS Settings.
    func refreshCredentialState() async {
        guard let userID = appleUserID else { return }
        let provider = ASAuthorizationAppleIDProvider()
        let state: ASAuthorizationAppleIDProvider.CredentialState? = await withCheckedContinuation { continuation in
            provider.getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
        if state == .revoked || state == .notFound {
            clearSession()
        }
    }

    /// Forgets the identity inside the vault AND seals it: reopening requires
    /// signing back in with Apple. Scans and folders stay untouched on device.
    func signOut() {
        guard isSignedIn else { return }
        clearSession()
        setSignOutLock(true)
        Haptics.selection()
    }

    private func clearSession() {
        appleUserID = nil
        fullName = nil
        email = nil
        persist()
    }

    private func setSignOutLock(_ locked: Bool) {
        withAnimation(Theme.flight) { requiresSignIn = locked }
        UserDefaults.standard.set(locked, forKey: Keys.signOutLock)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(appleUserID, forKey: Keys.userID)
        defaults.set(fullName, forKey: Keys.name)
        defaults.set(email, forKey: Keys.email)
    }
}
