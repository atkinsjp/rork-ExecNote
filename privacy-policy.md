# IntelliDoc Privacy Policy

**Effective date: August 30, 2026**
**Developer: Atkins Media** · Contact: [atkinsmedia.io/support](https://atkinsmedia.io/support)

This Privacy Policy describes how IntelliDoc ("the app", "we", "us") handles information when you use our iOS application. IntelliDoc is built privacy-first: **your documents are designed to stay on your device.**

## 1. Summary

- Scans, PDFs, OCR text, transcriptions, redactions and signatures are stored **locally** in the app's encrypted sandbox on your iPhone.
- We do **not** collect your document images or their contents on our servers.
- Optional features (iCloud sync, metadata backup, AI rewrite) only transmit data when **you** choose to use them, and only the minimum data required.
- We show **no ads** and sell **no data**. Ever.

## 2. Information We Collect

### 2.1 Information stored only on your device

The following never leaves your device unless you explicitly export, share, or enable sync for it:

- Scanned page images and generated PDF documents
- OCR text extracted from your documents
- Handwriting transcription text
- Redaction records and signature profiles (drawings, typed names, dates)
- Document titles, notes, folder structure, tags and keywords
- App settings and preferences

### 2.2 Optional iCloud sync

If you enable **iCloud Sync**, your vault data syncs between your own Apple devices through **Apple's iCloud** using the app's iCloud Drive container. This data is governed by **Apple's** privacy policy ([apple.com/privacy](https://www.apple.com/privacy/)). We have no access to the contents of your iCloud Drive. Turning off iCloud Sync or deleting documents in the app removes them from iCloud per Apple's file-provider behavior.

### 2.3 Optional metadata backup (Firebase)

If you enable cloud backup in Settings, a **minimal metadata record** may be stored with our backend provider, Google Firebase (Firestore / Cloud Storage):

- A **randomly generated identifier** (not your name, email, or Apple ID)
- Document titles, folder names, page counts and timestamps
- Sync bookkeeping (checksums, deletion tombstones)

We do **not** upload document images, OCR text, transcriptions, or signatures to Firebase. Disabling backup and using **Settings → Manage Data → Delete Account & Data** removes these records.

### 2.4 AI features (optional, explicit)

If you explicitly run an AI feature (for example rewriting or summarizing selected text), only the text you selected is sent through our secured gateway to a large-language-model provider (Google Gemini). The content is processed solely to return your result, is **not used to train models**, and is discarded after the response. No document images are ever sent.

### 2.5 Information we never collect

- We do not collect advertising identifiers and we show no ads.
- We do not use third-party analytics SDKs that profile you. A lightweight, privacy-guarded event log may record anonymous technical events (for example "sync completed") with no document content and no device identifiers.
- We do not ask for your contacts, location, or microphone unless a feature requires it in the moment (e.g., dictation), and we do not retain that data.

## 3. Permissions

| Permission | Purpose | Retention |
|---|---|---|
| Camera | Capturing document scans | Images saved only to your local vault |
| Face ID / Touch ID | Locking the vault | Handled entirely by iOS Secure Enclave; we never see biometric data |
| Photo Library | Importing images to scan/exporting pages | Only at your explicit action |
| iCloud Drive | Optional cross-device sync | Stored in the app's private iCloud container |
| Local Network / Internet | Optional sync, share links, AI features | Only when a network feature is active |

## 4. Share Links

If you create a secure share link, the document is uploaded over an encrypted connection to a storage provider and is accessible only via the generated link. Links **expire automatically** (default 7 days), and you can revoke them by deleting the share in the app. Deleting a share removes the stored file.

## 5. Subscriptions

Purchases and subscriptions are processed entirely by **Apple** through StoreKit. We never see your payment details. Apple provides us an anonymous receipt to validate entitlements. See Apple's privacy policy for how Apple handles your data.

## 6. Legal Bases (EEA/UK)

Where the GDPR applies: we process device-stored data as a **controller** only on your device (your data, your control); optional cloud backup and AI processing rely on your **consent**, which you may withdraw anytime by disabling the feature or deleting your data. We do not transfer personal data to third parties for their own use.

## 7. Your Rights

You control your data at all times:

- **Access & export** — export all user-created data as a portable archive from **Settings → Manage Data**.
- **Erasure** — permanently erase all device and cloud copies via **Delete Account & Data**. Deletion is immediate and irreversible.
- **Withdraw consent** — disable iCloud Sync, backup, or AI features at any time in Settings.
- **GDPR/CCPA requests** — since we do not maintain a profile database with personal information, on-device export/deletion fulfills access and deletion requests. For anything else, contact us at [atkinsmedia.io/support](https://atkinsmedia.io/support).

## 8. Children's Privacy

IntelliDoc is not directed at children under 13 (or the equivalent minimum age in your jurisdiction). We do not knowingly collect personal information from children. Because document data stays on-device, no child data reaches us.

## 9. Data Retention

- **Device data:** retained until you delete it or uninstall the app (uninstalling removes the app sandbox, except data stored in iCloud if sync is enabled).
- **Backup metadata:** retained until you delete your account data or disable backup.
- **Share links:** files deleted automatically when the link expires or is revoked.

## 10. Security

Documents are stored in the iOS app sandbox with iOS data protection. Network features use TLS. Share links use unguessable identifiers and expiration. No system is perfectly secure, but our architecture minimizes risk by keeping the sensitive data on your device.

## 11. Third-Party Services

| Service | Role | When |
|---|---|---|
| Apple iCloud | Sync storage (app-private container) | If iCloud Sync enabled |
| Google Firebase (Firestore/Storage) | Optional metadata backup | If backup enabled |
| Google Gemini (via secured gateway) | AI text transforms | Only when you run an AI action |
| Apple StoreKit | Subscriptions | On purchase |
| Cloudflare | Share-link file storage / TURN | If you create share links |

## 12. Changes to This Policy

We may update this policy as the app evolves. Material changes will be reflected in the app and the effective date above will change. The current version is always available in **Settings → Privacy Policy**.

## 13. Contact

Atkins Media — [atkinsmedia.io/support](https://atkinsmedia.io/support)
