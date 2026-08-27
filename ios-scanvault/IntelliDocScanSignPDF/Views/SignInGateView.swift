//
//  SignInGateView.swift
//  IntelliDocScanSignPDF
//

import AuthenticationServices
import SwiftUI

/// Full-screen gate shown after an explicit sign-out: everything stays on
/// device, but the vault won't open again until the user signs back in with
/// Apple. Replacing the gate with the dashboard is driven by
/// `AccountService.requiresSignIn`, so a successful authorization clears it.
struct SignInGateView: View {
    @Environment(AccountService.self) private var account

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                ZStack(alignment: .bottom) {
                    BrandMark()
                        .frame(width: 138, height: 138)
                        .scanSweep(active: false)

                    // Amber lock badge, mirroring the Face ID seal style.
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1206"))
                        .frame(width: 34, height: 34)
                        .background { Circle().fill(Theme.amber) }
                        .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 2.5) }
                        .offset(y: 6)
                }
                .shadow(color: Theme.amber.opacity(0.18), radius: 30, y: 10)

                Text("Vault Locked")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 30)

                Text("You signed out, so your vault is sealed.\nSign back in with Apple to reopen it.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                Label("Your scans stay safely on this device.", systemImage: "internaldrive.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "3FB0A0"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: "3FB0A0").opacity(0.10))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(hex: "3FB0A0").opacity(0.35), lineWidth: 1)
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 18)

                Spacer(minLength: 16)

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    account.handle(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 54)
                .clipShape(Capsule())
                .background {
                    // White mount keeps Apple's black button legible on the
                    // graphite backdrop — same treatment as Settings/onboarding.
                    Capsule().fill(Color.white).padding(-5)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .accessibilityHint("Reopen your sealed vault")
                .padding(.horizontal, 30)

                Label(
                    "Nothing leaves this iPhone — sign-in only reopens the door",
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
    }
}

#Preview {
    SignInGateView()
        .environment(AccountService.shared)
}
