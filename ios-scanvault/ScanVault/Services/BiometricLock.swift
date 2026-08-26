//
//  BiometricLock.swift
//  ScanVault
//

import Foundation
import LocalAuthentication

/// Wraps Face ID / Touch ID checks used to open folders marked as private.
nonisolated enum BiometricLock {
    enum Result: Sendable, Equatable {
        case success
        case failed(String)
    }

    /// Human-readable name of the enrolled biometry, e.g. "Face ID".
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

    static var symbolName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType == .touchID ? "touchid" : "faceid"
    }

    /// Prompts the user, falling back to the device passcode when biometry is
    /// unavailable. Devices with no passcode at all are allowed through so the
    /// user is never locked out of their own documents.
    static func authenticate(reason: String) async -> Result {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .success
        }

        do {
            let granted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return granted ? .success : .failed("Authentication was not completed.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
