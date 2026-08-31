//
//  LegalDocumentConfig.swift
//  IntelliDoc
//

import Foundation

/// Which legal artifact to present.
enum LegalDocumentKind: String, CaseIterable, Identifiable {
    case privacyPolicy
    case termsOfService
    case thirdPartyLicenses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacyPolicy: "Privacy Policy"
        case .termsOfService: "Terms of Service"
        case .thirdPartyLicenses: "Licenses & Notices"
        }
    }
}

/// Production URLs for every legally-required link, with remote overrides
/// (`privacy_policy_url` / `terms_url`) so legal pages can move without a
/// binary re-submission, plus bundled Markdown fallbacks for offline reading
/// — the App Store review flow must never dead-end behind a captive portal.
///
/// Guideline coverage: 5.1.1 (privacy policy linked from the paywall +
/// settings), EULA terms (standard Apple EULA unless a custom agreement is
/// hosted), and support contact.
nonisolated enum LegalDocumentConfig {

    /// Apple Standard EULA — used verbatim per Auto-Renewable Subscriptions
    /// Schedule 2 guidance when no custom agreement replaces it.
    static var standardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Support contact published by the developer account.
    static var supportURL = URL(string: "https://atkinsmedia.io/support")!

    /// Privacy policy hosted on GitHub from the project's repository
    /// (atkinsjp/rork-ExecNote). Points at the Markdown source so GitHub
    /// renders it as a formatted document page; Remote Config may override it.
    static var fallbackPrivacyPolicyURL = URL(string: "https://github.com/atkinsjp/rork-ExecNote/blob/main/privacy-policy.md")!

    // MARK: - Resolution

    /// Resolves the best available URL for `kind`, preferring the Remote
    /// Config override so legal destinations remain remotely correctable.
    /// Main-actor isolated: reads the live Remote Config values.
    @MainActor
    static func url(for kind: LegalDocumentKind) -> URL {
        let remote = RemoteConfigManager.shared
        switch kind {
        case .privacyPolicy:
            return remote.privacyPolicyURL ?? fallbackPrivacyPolicyURL
        case .termsOfService:
            return remote.termsOfServiceURL ?? standardEULAURL
        case .thirdPartyLicenses:
            // Rendered natively in-app; served by the recognizer view.
            return fallbackPrivacyPolicyURL
        }
    }

    // MARK: - Offline fallback content

    /// Bundled summary rendered natively when the device cannot reach the
    /// hosted page. Deliberately an accurate short-form summary, not a stub.
    static func fallbackContent(for kind: LegalDocumentKind) -> String {
        switch kind {
        case .privacyPolicy:
            """
            ### IntelliDoc Privacy Policy — Summary

            **What we collect.** IntelliDoc is designed so your paperwork never leaves this device. Scans, OCR text, transcriptions, redactions and signature assets live in the encrypted app sandbox. Only optional metadata you choose to sync (titles, folder names, page counts) travels to our Firebase backend, tied to a random identifier — never your name or email.

            **What we do NOT collect.** We never transmit OCR text, document images, biometric templates or document contents of any kind. No advertising identifiers are collected and no ads are shown.

            **Third-party processing.** Cloud sync uses Google Firebase (Firestore, Storage) as a processor under contract. If you use an AI rewrite feature, only selected text you explicitly send is processed by our AI gateway and discarded after the response.

            **Biometrics.** Face ID / Touch ID hashes are stored by iOS in the Secure Enclave. IntelliDoc never sees or stores them.

            **Your rights.** You can export every piece of user-created data as a portable archive from **Settings → Manage Data**, or permanently erase all device and cloud copies via **Delete Account & Data**. Deletion is immediate and irreversible.

            **Contact.** Questions or requests: [atkinsmedia.io/support](https://atkinsmedia.io/support)

            This offline summary ships with the app. Connect to the internet to read the complete, current policy.
            """
        case .termsOfService:
            """
            ### IntelliDoc Terms of Service — Summary

            **The service.** IntelliDoc provides on-device document scanning, OCR, redaction, classification, transcription, e-signatures and optional cloud sync. Unless you agreed to separate written terms with the developer, these services are licensed under **Apple's Standard EULA** ([apple.com/legal/internet-services/itunes/dev/stdeula](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)), which governs this app's permitted use, maintenance, liability and warranty terms.

            **Subscriptions.** Pro features renew automatically through your Apple ID unless cancelled at least 24 hours before period end. Manage or cancel anytime in App Store → Subscriptions. Restore purchases from any paywall.

            **Acceptable use.** Do not use IntelliDoc to forge signatures, bypass the law, or violate the rights of others. Documents you scan remain yours.

            **No legal advice.** Redaction and signing tools are utilities; verify results where outcomes matter to you.

            **Termination & data.** You may stop using the service anytime and permanently delete all data from Settings → Manage Data & Account Deletion.

            This offline summary ships with the app. Connect to the internet to read the complete, current terms.
            """
        case .thirdPartyLicenses:
            """
            ### Third-Party Licenses & SDK Notices

            IntelliDoc is built with first-party Swift code and the following third-party components and services. Full license texts are maintained in the repository `THIRD_PARTY_NOTICES.md`.

            **Google Firebase (Firestore, Storage, Functions)** — used for optional metadata sync and secure share links. Data processed only as described in the Privacy Policy. © Google LLC.

            **Apple frameworks** — SwiftUI, PDFKit, VisionKit, Vision, PencilKit, NaturalLanguage, CryptoKit, Network, SafariServices, StoreKit, WidgetKit and ActivityKit. Runtime subject to Apple's iOS SDK license.

            **Google Gemini via gateway proxy** — used only when you explicitly run an AI transform on selected note text. Prompts are proxied server-side, never logged with document content, and discarded after generation.

            **Fonts & icons** — typography and SF Symbols render under Apple's system font license.

            All trademarks belong to their respective owners. This notice is provided without modification of the underlying license terms. For questions, contact [atkinsmedia.io/support](https://atkinsmedia.io/support).
            """
        }
    }
}
