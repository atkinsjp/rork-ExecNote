//
//  ShareLinkSheetView.swift
//  IntelliDocScanSignPDF
//
//  "Share via Link": pick an expiry, optionally protect with a password,
//  mint a capability-token URL through the Cloud Function, then copy or
//  hand the link to the system share sheet.
//

import SwiftUI

struct ShareLinkSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let document: ScannedDocument

    private enum ExpiryOption: Int, CaseIterable, Identifiable {
        case oneDay = 24
        case oneWeek = 168

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .oneDay: "24 Hours"
            case .oneWeek: "7 Days"
            }
        }

        var symbolName: String {
            self == .oneDay ? "clock.badge.checkmark" : "calendar.day.timeline.left"
        }

        /// Short human hint shown under each option.
        var subtitle: String {
            switch self {
            case .oneDay: "Best for quick turnarounds"
            case .oneWeek: "For ongoing collaborations"
            }
        }
    }

    @State private var expiryHours: Int = ExpiryOption.oneDay.rawValue
    @State private var usePassword = false
    @State private var password = ""
    @State private var isCreating = false
    @State private var result: ShareLinkResult?
    @State private var didCopy = false
    @State private var errorMessage: String?
    @State private var showsSystemShare = false

    /// The user-facing minimum; the backend enforces the real policy.
    private static let minimumPasswordLength = 4

    private var canCreate: Bool {
        !isCreating && (!usePassword || password.count >= Self.minimumPasswordLength)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header

                        if let errorMessage {
                            errorBanner(errorMessage)
                        }

                        if let result {
                            resultSection(result)
                        } else {
                            expirySection
                            passwordSection
                            createButton
                            footnote
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Share via Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(result == nil ? "Cancel" : "Close") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if result != nil {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Theme.amberBright)
                    }
                }
            }
            .overlay {
                if isCreating { creatingOverlay }
            }
            .sheet(isPresented: $showsSystemShare) {
                if let result {
                    ShareSheet(items: [result.url])
                        .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: - Configure sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(document.title, systemImage: "link.icloud.fill")
                .font(Theme.display(.headline))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text("Secure, time-limited download straight from your cloud vault")
                .font(Theme.mono(.caption))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var expirySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Expires After")

            HStack(spacing: 10) {
                ForEach(ExpiryOption.allCases) { option in
                    expiryCard(option)
                }
            }
        }
    }

    private func expiryCard(_ option: ExpiryOption) -> some View {
        let isSelected = expiryHours == option.rawValue
        return Button {
            Haptics.selection()
            withAnimation(Theme.snap) { expiryHours = option.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: option.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.amber : Theme.textSecondary)
                Text(option.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(option.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? Theme.amber.opacity(0.08) : Color.white.opacity(0.02))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.amber.opacity(0.7) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityLabel("\(option.title) expiry")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Password Protection")

            Toggle(isOn: $usePassword.animation(Theme.snap)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Require a password")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Recipients must type it before downloading.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .tint(Theme.amber)

            if usePassword {
                HStack(spacing: 10) {
                    SecureField("Password", text: $password)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Haptics.selection()
                        password = ShareLinkService.generateSuggestedPassword()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.amberBright)
                            .frame(width: 34, height: 34)
                            .background { Circle().fill(Theme.surfaceHigh) }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Suggest a strong password")

                    Image(systemName: password.count >= Self.minimumPasswordLength ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 16))
                        .foregroundStyle(password.count >= Self.minimumPasswordLength ? Color(hex: "3FB0A0") : Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface) }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var createButton: some View {
        Button {
            Task { await createLink() }
        } label: {
            Label("Create Secure Link", systemImage: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1206"))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(
                        LinearGradient(colors: [Theme.amberBright, Theme.amber], startPoint: .top, endPoint: .bottom)
                    )
                }
                .opacity(canCreate ? 1 : 0.45)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(!canCreate)
        .animation(Theme.snap, value: canCreate)
    }

    private var footnote: some View {
        Label {
            Text("The key lives inside the link itself — nothing expires early, but you can always cut access short by deleting the scan.")
        } icon: {
            Image(systemName: "key.horizontal.fill")
        }
        .font(Theme.mono(.caption2))
        .foregroundStyle(Theme.textTertiary)
        .padding(.bottom, 8)
    }

    // MARK: - Result section

    private func resultSection(_ share: ShareLinkResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status summary.
            HStack(spacing: 12) {
                Image(systemName: share.requiresPassword ? "lock.rotation" : "link.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 44, height: 44)
                    .background { Circle().fill(Theme.amber.opacity(0.14)) }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Link is live")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(expiryLine(for: share))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background { RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.surface) }
            .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }

            // The link itself.
            VStack(alignment: .leading, spacing: 10) {
                Text(share.url.absoluteString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = share.url.absoluteString
                        Haptics.success()
                        withAnimation(Theme.snap) { didCopy = true }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(Theme.snap) { didCopy = false }
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Link",
                              systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "1A1206"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background { Capsule().fill(didCopy ? Color(hex: "3FB0A0") : Theme.amber) }
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))

                    Button {
                        Haptics.selection()
                        showsSystemShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.amberBright)
                            .frame(width: 46, height: 46)
                            .background { Circle().fill(Theme.amber.opacity(0.14)) }
                    }
                    .buttonStyle(PressableStyle(scale: 0.95))
                    .accessibilityLabel("Share the link with other apps")
                }
            }
            .padding(14)
            .background { RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.02)) }
            .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }

            Button {
                withAnimation(Theme.soft) {
                    result = nil
                    password = ""
                    didCopy = false
                    errorMessage = nil
                }
            } label: {
                Label("Create Another Link", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func expiryLine(for result: ShareLinkResult) -> String {
        let until = result.expiresAt.formatted(date: .abbreviated, time: .shortened)
        return result.requiresPassword
            ? "Valid until \(until) · password required"
            : "Anyone with this link can download until \(until)"
    }

    // MARK: - Feedback states

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: "FFB4A0"))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: "5A2B22").opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(hex: "FFB4A0").opacity(0.35), lineWidth: 1)
            }
    }

    private var creatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.amber)
                Text("Securing your link…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(30)
            .cardSurface(cornerRadius: 24)
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    // MARK: - Data

    private func createLink() async {
        guard canCreate else { return }
        Haptics.impact(.medium)
        errorMessage = nil
        isCreating = true

        let ownerId = VaultIdentity.userId
        let storagePath = document.storagePath.isEmpty
            ? ScannedDocument.storagePath(userId: ownerId, documentId: document.id)
            : document.storagePath

        do {
            let share = try await ShareLinkService.create(
                documentId: document.id,
                userId: ownerId,
                storagePath: storagePath,
                expiryHours: expiryHours,
                password: usePassword ? password : nil
            )
            withAnimation(Theme.soft) { result = share }
            Haptics.success()
            TelemetryService.track(.shareLinkCreated, attributes: ["hours": String(expiryHours)])
        } catch {
            Haptics.warning()
            withAnimation(Theme.soft) { errorMessage = error.localizedDescription }
        }
        isCreating = false
    }
}

#Preview {
    ShareLinkSheetView(document: ScannedDocument.mockList[0])
        .preferredColorScheme(.dark)
}
