//
//  SettingsView.swift
//  ScanVault
//

import AppIntents
import SwiftUI

/// App settings sheet: appearance (System / Light / Dark) plus vault facts.
struct SettingsView: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

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
                        siriSection
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

    // MARK: - Siri & Shortcuts

    private var siriSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SIRI & SHORTCUTS")

            VStack(spacing: 0) {
                voicePhraseRow(
                    phrase: "\u{201C}Scan a document in ScanVault\u{201D}",
                    detail: "Opens the camera hands-free"
                )
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                voicePhraseRow(
                    phrase: "\u{201C}New scan in ScanVault\u{201D}",
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
        .preferredColorScheme(.dark)
}
