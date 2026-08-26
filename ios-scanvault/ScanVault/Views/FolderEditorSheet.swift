//
//  FolderEditorSheet.swift
//  ScanVault
//

import SwiftUI

/// Creates a new folder or edits an existing one: name, symbol, colour and
/// whether it should sit behind a biometric lock.
struct FolderEditorSheet: View {
    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var existing: AppFolder?

    @State private var name: String = ""
    @State private var iconName: String = "folder.fill"
    @State private var colorHex: String = Theme.folderPalette[0]
    @State private var isLocked: Bool = false
    @FocusState private var isNameFocused: Bool

    private let iconColumns = [GridItem(.adaptive(minimum: 52), spacing: 10)]

    private var tint: Color { Color(hex: colorHex) }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Theme.inkRaised.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview

                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Name")
                        TextField("e.g. Tax 2026", text: $name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.amber)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        isNameFocused ? tint.opacity(0.6) : Color.white.opacity(0.07),
                                        lineWidth: 1
                                    )
                            }
                            .animation(Theme.snap, value: isNameFocused)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Colour")
                        HStack(spacing: 10) {
                            ForEach(Theme.folderPalette, id: \.self) { hex in
                                Button {
                                    withAnimation(Theme.snap) { colorHex = hex }
                                    Haptics.selection()
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(Color.white.opacity(colorHex == hex ? 0.9 : 0), lineWidth: 2)
                                                .padding(-4)
                                        }
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel("Colour \(hex)")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Symbol")
                        LazyVGrid(columns: iconColumns, spacing: 10) {
                            ForEach(Theme.folderSymbols, id: \.self) { symbol in
                                Button {
                                    withAnimation(Theme.snap) { iconName = symbol }
                                    Haptics.selection()
                                } label: {
                                    Image(systemName: symbol)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(iconName == symbol ? tint : Theme.textSecondary)
                                        .frame(width: 52, height: 52)
                                        .background {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(iconName == symbol ? tint.opacity(0.16) : Color.white.opacity(0.04))
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(
                                                    iconName == symbol ? tint.opacity(0.7) : Color.clear,
                                                    lineWidth: 1.5
                                                )
                                        }
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel(symbol)
                            }
                        }
                    }

                    Toggle(isOn: $isLocked) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Require \(BiometricLock.biometryLabel)")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Seal this folder until you authenticate.")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .tint(tint)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
                    }

                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.inkRaised)
        .presentationContentInteraction(.scrolls)
        .onAppear(perform: seed)
    }

    private var preview: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "New Folder" : name)
                    .font(Theme.display(.title3))
                    .foregroundStyle(name.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                Text(isLocked ? "Locked · \(BiometricLock.biometryLabel)" : "Open folder")
                    .font(Theme.mono(.caption2))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)

            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(Theme.surfaceHigh) }
                    .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 1) }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close without saving")
        }
        .padding(14)
        .cardSurface(cornerRadius: 20)
        .animation(Theme.snap, value: colorHex)
        .animation(Theme.snap, value: iconName)
    }

    private var saveButton: some View {
        Button {
            commit()
        } label: {
            Text(existing == nil ? "Create Folder" : "Save Changes")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isValid ? Color(hex: "1A1206") : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(isValid ? tint : Color.white.opacity(0.06))
                }
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(!isValid)
        .animation(Theme.snap, value: isValid)
    }

    private func seed() {
        guard let existing else {
            isNameFocused = true
            return
        }
        name = existing.name
        iconName = existing.iconName
        colorHex = existing.colorHex
        isLocked = existing.isBiometricLocked
    }

    private func commit() {
        guard isValid else { return }
        if var folder = existing {
            folder.name = name
            folder.iconName = iconName
            folder.colorHex = colorHex
            folder.isBiometricLocked = isLocked
            store.updateFolder(folder)
        } else {
            store.createFolder(name: name, iconName: iconName, colorHex: colorHex, locked: isLocked)
        }
        Haptics.success()
        dismiss()
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            FolderEditorSheet()
                .environment(VaultStore.mock())
        }
        .preferredColorScheme(.dark)
}
