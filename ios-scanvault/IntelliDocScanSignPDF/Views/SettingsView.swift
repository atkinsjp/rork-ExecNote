//
//  SettingsView.swift
//  IntelliDocScanSignPDF
//

import AuthenticationServices
import AppIntents
import SwiftUI

/// App settings sheet: subscription management, appearance (System / Light /
/// Dark), Siri setup and the legally-mandated Legal & Privacy suite.
struct SettingsView: View {
    @Environment(VaultStore.self) private var store
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    @State private var showingPrivacyPolicy = false
    @State private var showingTerms = false
    @State private var showingLicenses = false
    @State private var showingDataManagement = false
    @State private var isConfirmingSignOut = false
    @State private var showingFeatureTour = false
    @State private var showingSignatureKit = false

    private var mode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        appearanceSection
                        learnSection
                        signatureKitSection
                        subscriptionSection
                        accountSection
                        siriSection
                        legalSection
                        aboutSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Close settings")
                }
            }
        }
        .preferredColorScheme(mode.colorScheme)
        .task { await account.refreshCredentialState() }
        .confirmationDialog(
            "Sign out of your Apple account?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                account.signOut()
                // Drop straight back onto the vault's sign-in gate.
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to sign back in with Apple to reopen your vault. Your scans stay safely on this device.")
        }
        .sheet(isPresented: $showingPrivacyPolicy) {
            LegalDocumentView(kind: .privacyPolicy)
        }
        .sheet(isPresented: $showingTerms) {
            LegalDocumentView(kind: .termsOfService)
        }
        .sheet(isPresented: $showingLicenses) {
            LegalDocumentView(kind: .thirdPartyLicenses)
        }
        .sheet(isPresented: $showingDataManagement) {
            NavigationStack {
                DataManagementSheet()
                    .environment(store)
            }
        }
        .fullScreenCover(isPresented: $showingFeatureTour) {
            FeatureTourView(isReplay: true) {
                showingFeatureTour = false
            }
        }
        .sheet(isPresented: $showingSignatureKit) {
            SignatureManagerView()
                .environment(subscriptions)
        }
    }

    // MARK: - Signature kit

    /// Entry into the reusable signature manager (rename, delete, draw new).
    private var signatureKitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SIGNATURE KIT")

            Button {
                Haptics.selection()
                showingSignatureKit = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.amber.opacity(0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: "signature")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved signatures")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Manage the signatures, initials and stamps you reuse when signing")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.surfaceHigh)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .accessibilityLabel("Manage saved signatures")
        }
    }

    // MARK: - Getting started

    /// Replay entry for the launch walkthrough (scan → file → redact → sign).
    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "GETTING STARTED")

            Button {
                Haptics.selection()
                showingFeatureTour = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.amber.opacity(0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Feature tour")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Replay the walkthrough of scanning, redaction and signing")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.surfaceHigh)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .accessibilityLabel("Replay the feature tour")
        }
    }

    // MARK: - Subscription

    private var subscriptionSubtitle: String {
        if subscriptions.hasPro {
            let source = subscriptions.plans.isEmpty ? PlanPresentation.mockCatalog : subscriptions.plans
            if let id = subscriptions.activePlanID,
               let plan = source.first(where: { $0.id == id }) {
                return "Pro · \(plan.title) plan"
            }
            return "Pro unlocked"
        }
        return "Free plan · Upgrade or restore anytime"
    }

    /// Entry point into the dedicated plan-management screen.
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "INTELLIDOC PRO")

            NavigationLink {
                SubscriptionManagementView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .frame(width: 36, height: 36)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.amber.opacity(0.14))
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage Subscription")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(subscriptionSubtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.99))
            .accessibilityLabel("Manage your IntelliDoc Pro subscription")
        }
    }

    // MARK: - Legal & Privacy

    /// Guideline 5.1.1 mandated surface: privacy policy, terms/EULA,
    /// third-party notices and the account/data deletion flow.
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "LEGAL & PRIVACY")

            VStack(spacing: 0) {
                settingsLinkRow(symbol: "hand.raised.fill", title: "Privacy Policy") {
                    showingPrivacyPolicy = true
                }
                hairline
                settingsLinkRow(symbol: "doc.plaintext.fill", title: "Terms of Service") {
                    showingTerms = true
                }
                hairline
                settingsLinkRow(symbol: "list.bullet.rectangle.fill", title: "Third-Party Licenses & SDK Notices") {
                    showingLicenses = true
                }
                hairline
                settingsLinkRow(
                    symbol: "trash.slash.fill",
                    title: "Manage Data & Account Deletion",
                    tint: Color(hex: "C0453B")
                ) {
                    showingDataManagement = true
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }

            Text("Legal pages open in an in-app reader when online and fall back to an accurate bundled copy offline.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private func settingsLinkRow(
        symbol: String,
        title: String,
        tint: Color = Theme.textPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint == Theme.textPrimary ? Theme.amber : tint)
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tint == Theme.textPrimary ? Theme.amber.opacity(0.14) : tint.opacity(0.12))
                    }

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityLabel(title)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "APPEARANCE")

            VStack(spacing: 0) {
                ForEach(AppearanceMode.allCases) { candidate in
                    appearanceRow(candidate)
                    if candidate != AppearanceMode.allCases.last {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }

            Text("Applies instantly across the whole vault, including every sheet and scan screen.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func appearanceRow(_ candidate: AppearanceMode) -> some View {
        let isSelected = candidate == mode

        return Button {
            Haptics.selection()
            withAnimation(Theme.snap) { appearanceRaw = candidate.rawValue }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: candidate.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Theme.amber.opacity(0.14) : Theme.surfaceHigh)
                    }

                Text(candidate.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                if candidate == .system {
                    Text("Follows your device")
                        .font(Theme.mono(.caption2))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityLabel("\(candidate.label) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Account

    /// Sign in with Apple identity + logout. Scans never leave the device
    /// through this — the account anchors purchases and future cloud sync.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "ACCOUNT")

            if account.isSignedIn {
                signedInCard
            } else {
                signInCard
            }

            Text(account.isSignedIn
                 ? "Signed in with Apple. Your scans remain stored on this device only."
                 : "Uses your Apple ID privately — we never see your password, and scans stay on this device.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .alert("Sign in with Apple", isPresented: Binding(
            get: { account.lastError != nil },
            set: { if !$0 { account.clearError() } }
        )) {
            Button("OK", role: .cancel) { account.clearError() }
        } message: {
            Text(account.lastError ?? "")
        }
    }

    private var signInCard: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                account.handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                // White mount so the standard black button reads on the
                // graphite surface, matching the system look.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .padding(-5)
            }
        }
    }

    private var signedInCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 40, height: 40)
                    .background { Circle().fill(Theme.amber.opacity(0.14)) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(account.email ?? "Apple account")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "3FB0A0"))
            }
            .padding(14)

            // Prominent heads-up so sealing on sign-out is never a surprise.
            Label("Signing out locks your vault — sign back in with Apple to reopen it.", systemImage: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.amber.opacity(0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Text("✓ Your scans stay safely on this device.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: "3FB0A0"))
                .padding(.horizontal, 14)
                .padding(.top, 8)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Button {
                Haptics.selection()
                isConfirmingSignOut = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "E2664F"))
                        .frame(width: 28, height: 28)
                        .background { Circle().fill(Color(hex: "E2664F").opacity(0.12)) }

                    Text("Sign Out")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "E2664F"))

                    Spacer()
                }
                .padding(14)
                .contentShape(.rect)
            }
            .buttonStyle(PressableStyle(scale: 0.99))
            .accessibilityLabel("Sign out of your Apple account")
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: - Siri & Shortcuts

    private var siriSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SIRI & SHORTCUTS")

            VStack(spacing: 0) {
                voicePhraseRow(
                    phrase: "\u{201C}Scan a document in IntelliDoc\u{201D}",
                    detail: "Opens the camera hands-free"
                )
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                voicePhraseRow(
                    phrase: "\u{201C}New scan in IntelliDoc\u{201D}",
                    detail: "Same action, shorter phrase"
                )
            }
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }

            // Deep-links the system App Shortcuts setup so users can pin a
            // Home Screen button or edit phrases without hunting for it.
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 36, height: 36)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.amber.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up shortcuts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Pin one to your Home Screen or Lock Screen")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                ShortcutsLink()
                    .buttonStyle(.plain)
                    .tint(Theme.amber)
                    .font(.system(size: 13, weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .cardSurface(cornerRadius: 16)

            Text("Siri works out of the box — no account or network needed for scanning.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func voicePhraseRow(phrase: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .frame(width: 36, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.amber.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(phrase)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "VAULT")

            HStack(spacing: 14) {
                stat(icon: "doc.fill", value: "\(store.documents.count)", label: "documents")
                stat(icon: "paperclip", value: "\(store.totalPages)", label: "pages")
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "3FB0A0"))
                Text("On-device OCR, redaction and classification. Only metadata you choose syncs to the cloud.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func stat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(Theme.mono(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(label)
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .cardSurface(cornerRadius: 16)
    }
}

#Preview {
    SettingsView()
        .environment(VaultStore.mock())
        .environment(AccountService.shared)
        .preferredColorScheme(.dark)
}
