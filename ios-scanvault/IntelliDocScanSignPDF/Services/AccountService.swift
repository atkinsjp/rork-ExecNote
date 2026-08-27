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
    }

    private(set) var appleUserID: String?
    private(set) var fullName: String?
    private(set) var email: String?

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
            Haptics.success()

        case .failure:
            Haptics.warning()
        }
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

    /// Forgets the identity inside the vault. Apple offers no programmatic
    /// sign-out of the device-level Apple ID itself — scans stay on device.
    func signOut() {
        guard isSignedIn else { return }
        clearSession()
        Haptics.selection()
    }

    private func clearSession() {
        appleUserID = nil
        fullName = nil
        email = nil
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(appleUserID, forKey: Keys.userID)
        defaults.set(fullName, forKey: Keys.name)
        defaults.set(email, forKey: Keys.email)
    }
}
