//
//  BiometricAuthService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import LocalAuthentication

nonisolated enum BiometricError: LocalizedError {
    case notAvailable
    case denied

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Biometric authentication is unavailable on this device."
        case .denied: "Authentication was cancelled or failed."
        }
    }
}

/// Face ID / Touch ID gate for vault folders.
///
/// Evaluates `.deviceOwnerAuthenticationWithBiometrics` first so the dedicated
/// biometry prompt appears; when biometry is unavailable, locked out, or not
/// enrolled it falls back to `.deviceOwnerAuthentication` (device passcode).
nonisolated enum BiometricAuthService {
    enum AuthResult: Sendable, Equatable {
        case success
        case failure(String)
    }

    /// The biometry kind enrolled on this device ("Face ID", "Touch ID", …).
    static var biometryLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// SF Symbol matching the enrolled biometry.
    static var symbolName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "eye"
        default: return "passcode"
        }
    }

    static var isBiometryAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Runs the biometric prompt with a passcode fallback.
    ///
    /// Devices with no passcode at all pass through so users are never locked
    /// out of their own documents.
    static func authenticate(reason: String) async -> AuthResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"

        // 1. Try the dedicated biometry policy (Face ID / Touch ID).
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            do {
                let granted = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                return granted ? .success : .failure("Authentication was not completed.")
            } catch {
                // Fall through to the passcode policy below.
            }
        }

        // 2. Passcode fallback (also the only path on passcode-only devices).
        let fallback = LAContext()
        fallback.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard fallback.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .success
        }
        do {
            let granted = try await fallback.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return granted ? .success : .failure("Authentication was not completed.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
