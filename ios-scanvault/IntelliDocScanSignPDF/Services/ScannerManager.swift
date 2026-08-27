//
//  ScannerManager.swift
//  IntelliDocScanSignPDF
//

import Observation
import SwiftUI
import UIKit
import VisionKit

/// Where a capture session came from, so the review screen can explain itself.
nonisolated enum CaptureSource: Equatable, Sendable {
    case camera
    case photoImport
}

/// Owns the live capture session state and bridges `VNDocumentCameraViewController`
/// delegate callbacks back into SwiftUI.
@MainActor
@Observable
final class ScannerManager {
    /// Pages captured in the current (unsaved) session, in user-defined order.
    private(set) var pages: [UIImage] = []
    /// Stable identities kept in lockstep with `pages` so SwiftUI keeps page
    /// identity across reorder and delete.
    private(set) var pageIDs: [UUID] = []
    private(set) var source: CaptureSource = .camera
    private(set) var isCapturing: Bool = false
    var errorMessage: String?

    /// True when this device can present the VisionKit document camera.
    var isDocumentCameraAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }

    var hasPages: Bool { !pages.isEmpty }

    /// Pages paired with their stable identity, for `ForEach`.
    var identifiedPages: [IdentifiedPage] {
        zip(pageIDs, pages).map(IdentifiedPage.init)
    }

    func index(of id: UUID) -> Int? {
        pageIDs.firstIndex(of: id)
    }

    func beginCapture() {
        errorMessage = nil
        isCapturing = true
    }

    func endCapture() {
        isCapturing = false
    }

    // MARK: - Delegate results

    func finish(with scanned: [UIImage], source: CaptureSource) {
        self.source = source
        pages.append(contentsOf: scanned)
        pageIDs.append(contentsOf: scanned.map { _ in UUID() })
        isCapturing = false
    }

    func cancel() {
        isCapturing = false
    }

    func fail(_ error: Error) {
        isCapturing = false
        errorMessage = error.localizedDescription
    }

    // MARK: - Page editing

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        pages.move(fromOffsets: offsets, toOffset: destination)
        pageIDs.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Shifts a page one slot left (`-1`) or right (`+1`).
    func swapPage(at index: Int, direction: Int) {
        let target = index + direction
        guard pages.indices.contains(index), pages.indices.contains(target) else { return }
        pages.swapAt(index, target)
        pageIDs.swapAt(index, target)
    }

    func removePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages.remove(at: index)
        pageIDs.remove(at: index)
    }

    func rotatePage(at index: Int) {
        guard pages.indices.contains(index) else { return }
        pages[index] = pages[index].rotatedQuarterTurn()
    }

    func reset() {
        pages.removeAll()
        pageIDs.removeAll()
        errorMessage = nil
        isCapturing = false
    }

    /// Seeds a session with images — used by photo import and SwiftUI previews.
    func load(_ images: [UIImage], source: CaptureSource) {
        pages = images
        pageIDs = images.map { _ in UUID() }
        self.source = source
    }
}

/// A captured page with a stable SwiftUI identity.
struct IdentifiedPage: Identifiable {
    let id: UUID
    let image: UIImage
}

// MARK: - VisionKit bridge

/// SwiftUI wrapper around `VNDocumentCameraViewController`.
struct DocumentCameraView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator

        // Travelling amber scan light across the viewfinder. Non-interactive,
        // so VisionKit's own shutter and corners stay untouched.
        let sweep = ScannerSweepUIKitOverlay(frame: .zero)
        sweep.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(sweep)
        NSLayoutConstraint.activate([
            sweep.topAnchor.constraint(equalTo: controller.view.topAnchor),
            sweep.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            sweep.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            sweep.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
        ])
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([UIImage]) -> Void
        private let onCancel: () -> Void
        private let onError: (Error) -> Void

        init(
            onFinish: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void,
            onError: @escaping (Error) -> Void
        ) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            let captured = images
            Task { @MainActor in
                self.onFinish(captured)
            }
        }

        nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            Task { @MainActor in
                self.onCancel()
            }
        }

        nonisolated func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            Task { @MainActor in
                self.onError(error)
            }
        }
    }
}

// MARK: - Image helpers

extension UIImage {
    /// Rotates the image 90° clockwise, redrawing pixels so the result is flat.
    func rotatedQuarterTurn() -> UIImage {
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { context in
            context.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            draw(in: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }

    /// Renders a lightweight placeholder page — used for SwiftUI previews only.
    static func previewPage(title: String, lines: Int = 14, tint: UIColor = .systemGray4) -> UIImage {
        let size = CGSize(width: 480, height: 620)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            tint.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: CGRect(x: 40, y: 48, width: 240, height: 26), cornerRadius: 6).fill()

            UIColor.systemGray5.setFill()
            for index in 0..<lines {
                let width = Double.random(in: 180...400)
                UIBezierPath(
                    roundedRect: CGRect(x: 40, y: 110 + Double(index) * 28, width: width, height: 10),
                    cornerRadius: 4
                ).fill()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: UIColor.darkGray,
            ]
            title.draw(at: CGPoint(x: 40, y: size.height - 70), withAttributes: attributes)
        }
    }
}
