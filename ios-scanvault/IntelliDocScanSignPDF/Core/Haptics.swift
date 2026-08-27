//
//  Haptics.swift
//  IntelliDocScanSignPDF
//

import UIKit

/// Thin wrapper around UIKit feedback generators for imperative call sites.
/// Prefer `.sensoryFeedback` in SwiftUI where a trigger value exists.
@MainActor
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
