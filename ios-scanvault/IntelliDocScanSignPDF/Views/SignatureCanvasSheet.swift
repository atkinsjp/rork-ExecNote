//
//  SignatureCanvasSheet.swift
//  IntelliDocScanSignPDF
//

import PencilKit
import SwiftUI
import UIKit

/// Drawing inks offered in the canvas.
nonisolated enum SignatureInk: String, CaseIterable, Identifiable {
    case blue
    case black
    case darkSlate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: "Royal Blue"
        case .black: "Ink Black"
        case .darkSlate: "Dark Slate"
        }
    }

    var color: Color {
        switch self {
        case .blue: Color(hex: "1D4ED8")
        case .black: Color(hex: "111114")
        case .darkSlate: Color(hex: "3A4250")
        }
    }
}

/// PencilKit canvas where users draw a reusable signature, initials or stamp.
///
/// The finished stroke set is cropped to its ink bounding box and exported as
/// a transparent high-resolution bitmap.
struct SignatureCanvasSheet: View {
    /// Called with the cropped, transparent PNG and a suggested title.
    let onSave: (SignatureProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var canvasView = PKCanvasView()
    @State private var ink: SignatureInk = .black
    /// When set, overrides the preset inks with a user-picked color.
    @State private var customColor: Color?
    @State private var pickedColor: Color = .black
    @State private var strokeMultiplier: Double = 1.0
    @State private var title: String = ""
    @State private var type: SignatureType = .signature

    private var canSave: Bool {
        !canvasView.drawing.strokes.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backdrop

                VStack(spacing: 0) {
                    typeSelector
                    canvasCard
                    toolRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle("New Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save()
                    } label: {
                        Text("Save to Kit")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(canSave ? Theme.amber : Theme.textTertiary)
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Sections

    private var typeSelector: some View {
        HStack(spacing: 6) {
            ForEach(SignatureType.allCases, id: \.self) { option in
                Button {
                    type = option
                    Haptics.selection()
                    if title.isEmpty || Self.suggestedTitles.contains(title) {
                        title = Self.suggestedTitle(for: option)
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: option.symbolName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(option.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(type == option ? Theme.amber : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        Capsule(style: .continuous).fill(type == option ? Theme.amber.opacity(0.13) : Color.white.opacity(0.04))
                    }
                    .overlay { Capsule().strokeBorder(type == option ? Theme.amber.opacity(0.55) : Theme.hairline, lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 12)
    }

    private var canvasCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name this signature (e.g. Legal Full)", text: $title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
                }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 1) }

            ZStack {
                // Paper canvas.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.paper)
                    .overlay {
                        // Faint baselines like a signature field.
                        VStack(spacing: 26) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.black.opacity(0.07))
                                    .frame(height: 1)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 34)
                        .allowsHitTesting(false)
                    }

                PencilCanvas(canvasView: $canvasView, ink: ink, customColor: customColor, strokeMultiplier: strokeMultiplier)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
            }
            .frame(height: 250)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        }
        .padding(.bottom, 12)
    }

    private var toolRow: some View {
        HStack(spacing: 12) {
            // Ink swatches + custom picker.
            HStack(spacing: 8) {
                ForEach(SignatureInk.allCases) { option in
                    Button {
                        ink = option
                        customColor = nil
                        Haptics.selection()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 26, height: 26)
                            if customColor == nil && ink == option {
                                Circle()
                                    .strokeBorder(Theme.amber, lineWidth: 2)
                                    .frame(width: 33, height: 33)
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.label)
                }

                ColorPicker(selection: $pickedColor, supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
                .frame(width: 36, height: 36)
                .onChange(of: pickedColor) { _, newValue in
                    customColor = newValue
                    Haptics.selection()
                }
                .accessibilityLabel("Custom ink color")
            }

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)

            // Stroke thickness.
            HStack(spacing: 6) {
                Circle().fill(Theme.textSecondary).frame(width: 3, height: 3)
                Slider(value: $strokeMultiplier, in: 0.5...2.5, step: 0.5)
                    .tint(Theme.amber)
                Circle().fill(Theme.textSecondary).frame(width: 8, height: 8)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)

            // Undo / Clear.
            HStack(spacing: 4) {
                Button {
                    canvasView.undoManager?.undo()
                    Haptics.impact(.light)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Undo stroke")

                Button {
                    canvasView.drawing = PKDrawing()
                    Haptics.warning()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "E2664F"))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear canvas")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.06), lineWidth: 1) }
    }

    // MARK: - Saving

    private static let suggestedTitles = Set(
        SignatureType.allCases.map { suggestedTitle(for: $0) }
    )

    private static func suggestedTitle(for signatureType: SignatureType) -> String {
        switch signatureType {
        case .signature: "Legal Full"
        case .initials: "Initials"
        case .dateStamp: "Date Stamp"
        case .customText: "Custom Stamp"
        }
    }

    /// Exports the drawing cropped to its ink bounds at 3x, transparent background.
    private func save() {
        let drawing = canvasView.drawing
        let bounds = drawing.bounds
        guard !bounds.isEmpty, !bounds.isNull, bounds.width > 4, bounds.height > 4 else { return }

        let padding: CGFloat = 10
        let padded = bounds.insetBy(dx: -padding, dy: -padding)
        let renderScale: CGFloat = 3
        let image = drawing.image(
            from: padded,
            scale: renderScale
        )

        guard let png = image.pngData() else { return }
        Haptics.success()

        onSave(SignatureProfile(
            title: title.trimmingCharacters(in: .whitespaces),
            type: type,
            pngData: png
        ))
        dismiss()
    }
}

// MARK: - PencilKit bridge

/// Smoothing-enabled `PKCanvasView` bound to the selected ink color and weight.
struct PencilCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let ink: SignatureInk
    var customColor: Color?
    let strokeMultiplier: Double

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        // PencilKit re-renders dark inks for dark traits (black becomes
        // white); pin the canvas to light so strokes match the picker.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.tool = makeTool()
        canvasView.drawingGestureRecognizer.isEnabled = true
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = makeTool()
    }

    private func makeTool() -> PKTool {
        let color = customColor.map(UIColor.init) ?? UIColor(ink.color)
        return PKInkingTool(
            .pen,
            color: color,
            width: 3.2 * strokeMultiplier
        )
    }
}

#Preview {
    SignatureCanvasSheet { _ in }
        .preferredColorScheme(.dark)
}
