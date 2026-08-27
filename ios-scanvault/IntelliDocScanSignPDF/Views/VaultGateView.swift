//
//  VaultGateView.swift
//  IntelliDocScanSignPDF
//

import SwiftUI

/// Whole-vault biometric gate shown before the main document vault unlocks —
/// at cold launch and again whenever the app returns from the background.
/// Prompts once automatically per appearance; after that, retries come from
/// the Unlock button so a cancelled prompt never loops.
struct VaultGateView: View {
    @Environment(VaultLockManager.self) private var locks

    @State private var hasAutoPrompted = false
    @State private var failureMessage: String?
    @State private var isAttempting = false

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                ZStack(alignment: .bottom) {
                    BrandMark()
                        .frame(width: 138, height: 138)
                        .scanSweep(active: false)

                    // Amber seal badge.
                    Image(systemName: BiometricLock.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.amber) }
                        .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 2.5) }
                        .offset(y: 6)
                }
                .shadow(color: Theme.amber.opacity(0.18), radius: 30, y: 10)

                Text("Vault Sealed")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 30)

                Text("Your documents stay private until you say otherwise.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                if let failureMessage {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(hex: "E2664F"))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(hex: "E2664F").opacity(0.10))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color(hex: "E2664F").opacity(0.35), lineWidth: 1)
                        }
                        .padding(.horizontal, 34)
                        .padding(.top, 18)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: 16)

                Button {
                    Haptics.impact(.medium)
                    Task { await attemptUnlock() }
                } label: {
                    HStack(spacing: 9) {
                        if isAttempting {
                            ProgressView()
                                .tint(Color(hex: "1A1206"))
                        } else {
                            Image(systemName: BiometricLock.symbolName)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        Text(isAttempting ? "Waiting…" : "Unlock Vault")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: "1A1206"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background {
                        Capsule().fill(
                            LinearGradient(
                                colors: [Theme.amberBright, Theme.amber],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .shadow(color: Theme.amber.opacity(0.35), radius: 18, y: 8)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .disabled(isAttempting)
                .padding(.horizontal, 30)

                Label(
                    "Use \(BiometricLock.biometryLabel) or your device passcode",
                    systemImage: "lock.shield.fill"
                )
                .font(Theme.mono(.caption2))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 16)
                .padding(.bottom, 22)
            }
        }
        // One automatic prompt per appearance so returning users never tap;
        // cancelled prompts surface the Unlock button instead of nagging.
        .task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !hasAutoPrompted else { return }
            await autoPromptIfEligible()
        }
    }

    @Environment(\.scenePhase) private var scenePhaseForAutoPrompt

    private func autoPromptIfEligible() async {
        guard scenePhaseForAutoPrompt == .active, !hasAutoPrompted else { return }
        hasAutoPrompted = true
        await attemptUnlock()
    }

    private func attemptUnlock() async {
        guard !isAttempting else { return }
        isAttempting = true
        defer { isAttempting = false }

        let unlocked = await locks.unsealApp()
        withAnimation(Theme.snap) {
            failureMessage = unlocked ? nil : (locks.lastError ?? "Authentication was not completed.")
        }
        if unlocked {
            Haptics.success()
        } else {
            Haptics.warning()
        }
    }
}

#Preview {
    VaultGateView()
        .environment(VaultLockManager.shared)
}
