//
//  DocumentEdgeScanner.swift
//  IntelliDocScanSignPDF
//

@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import Vision

// MARK: - Detected quad

/// A detected document edge quad, normalized 0…1 with a top-left origin
/// (SwiftUI/UIKit convention) so overlays and mappers share one space.
nonisolated struct DocumentQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var confidence: Float

    /// Flips Vision's bottom-left-origin rectangle into UI space and clamps
    /// the corners back inside the frame (detector edges can overshoot 1.0).
    init(observation: VNRectangleObservation) {
        func ui(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(1 - point.y, 0), 1))
        }
        topLeft = ui(observation.topLeft)
        topRight = ui(observation.topRight)
        bottomRight = ui(observation.bottomRight)
        bottomLeft = ui(observation.bottomLeft)
        confidence = observation.confidence
    }

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Fraction of the frame covered by the quad (shoelace formula).
    var area: CGFloat {
        let ring = corners
        var sum: CGFloat = 0
        for index in 0..<ring.count {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Largest corner-to-corner drift between two consecutive readings.
    func drift(from other: DocumentQuad) -> CGFloat {
        zip(corners, other.corners)
            .map { hypot($0.x - $1.x, $0.y - $1.y) }
            .max() ?? .infinity
    }
}

// MARK: - Edge scanner

/// Live document edge scanner: pipes the camera through AVFoundation, feeds
/// frames to Vision's rectangle detector, tracks framing stability for
/// auto-capture, and returns perspective-corrected page images.
///
/// All capture work runs on a private serial queue; results are bounced to the
/// main actor through the handler closures. Handlers must be assigned before
/// `start()` and never reassigned afterwards.
nonisolated final class DocumentEdgeScanner: NSObject, @unchecked Sendable {
    /// True on hardware; false on devices without a rear camera (simulator),
    /// where callers fall back to the VisionKit document camera.
    static var isHardwareAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    var onQuadUpdate: (@MainActor @Sendable (DocumentQuad?) -> Void)?
    var onVideoAspectRatio: (@MainActor @Sendable (CGFloat) -> Void)?
    var onStableDocument: (@MainActor @Sendable () -> Void)?
    var onCapture: (@MainActor @Sendable (UIImage?) -> Void)?
    var onConfigurationError: (@MainActor @Sendable (String) -> Void)?

    /// Live session — safe to attach to an `AVCaptureVideoPreviewLayer`.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "com.atkinsmedia.intellidoc.edge-scanner",
        qos: .userInitiated
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private static let ciContext = CIContext()

    // Session-queue state only.
    private var isRunning = false
    private var isCapturingStill = false
    private var hasPublishedAspect = false
    private var lastQuad: DocumentQuad?
    private var stableSince: Date?
    private var lastDetectionAt = Date.distantPast
    private var lastAutoCaptureFire = Date.distantPast

    // MARK: Lifecycle

    func start() {
        sessionQueue.async { self.configureAndRun() }
    }

    func stop() {
        sessionQueue.async {
            guard self.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }

    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first?.device,
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch {}
        }
    }

    private func configureAndRun() {
        guard !isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.onConfigurationError?("The camera couldn't be opened. Check camera permissions or import from Photos instead.")
            }
            return
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.onConfigurationError?("The camera couldn't be set up on this device.")
            }
            return
        }
        session.addOutput(videoOutput)

        // Portrait frames, so detection results match what the user sees.
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let connection = photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()
        session.startRunning()
        isRunning = true
    }

    // MARK: Still capture

    func capturePhoto() {
        sessionQueue.async {
            guard self.isRunning, !self.isCapturingStill else { return }
            self.isCapturingStill = true
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.maxPhotoQualityPrioritization == .quality {
                settings.photoQualityPrioritization = .quality
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Detection + stability (session queue)

    private func updateTracking(with quad: DocumentQuad?) {
        let now = Date()
        defer { lastQuad = quad }

        guard let quad, quad.area >= 0.13, quad.confidence >= 0.6 else {
            stableSince = nil
            return
        }
        if let previous = lastQuad, previous.drift(from: quad) < 0.02 {
            let anchor = stableSince ?? now
            stableSince = anchor
            if now.timeIntervalSince(anchor) >= 0.6,
               now.timeIntervalSince(lastAutoCaptureFire) >= 2.8,
               !isCapturingStill {
                lastAutoCaptureFire = now
                stableSince = nil
                Task { @MainActor in self.onStableDocument?() }
            }
        } else {
            stableSince = now
        }
    }

    private static func makeRectangleRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.55
        request.minimumSize = 0.2
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 18
        return request
    }

    private static func detectQuad(in pixelBuffer: CVPixelBuffer) -> DocumentQuad? {
        let request = makeRectangleRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return DocumentQuad(observation: observation)
    }

    private static func detectQuad(in image: CIImage) -> DocumentQuad? {
        let request = makeRectangleRequest()
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return DocumentQuad(observation: observation)
    }

    // MARK: Photo processing

    private func processPhoto(_ photo: AVCapturePhoto, error: (any Error)?) -> UIImage? {
        guard error == nil, let data = photo.fileDataRepresentation() else { return nil }
        let exif = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        guard var image = CIImage(data: data)?.oriented(forExifOrientation: Int32(exif)) else { return nil }
        image = image.cropped(to: image.extent)

        // Re-detect on the full-resolution still; fall back to the last live
        // quad, then to the uncropped frame.
        let quad = Self.detectQuad(in: image) ?? lastQuad
        guard let quad else { return render(image) }
        guard let corrected = Self.correct(image: image, quad: quad) else { return render(image) }
        return render(corrected)
    }

    private func render(_ image: CIImage) -> UIImage? {
        guard let cgImage = Self.ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Warps the quad region into a flat, front-facing rectangle sized to the
    /// document's average edge lengths.
    private static func correct(image: CIImage, quad: DocumentQuad) -> CIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        func pixel(_ point: CGPoint) -> CGPoint {
            // UI-normalized → CI pixels (CI's origin is bottom-left).
            CGPoint(
                x: point.x * extent.width + extent.origin.x,
                y: (1 - point.y) * extent.height + extent.origin.y
            )
        }
        let topLeft = pixel(quad.topLeft)
        let topRight = pixel(quad.topRight)
        let bottomLeft = pixel(quad.bottomLeft)
        let bottomRight = pixel(quad.bottomRight)

        // Perspective-correct the quad region into a front-facing rectangle.
        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter?.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        guard let output = filter?.outputImage else { return nil }
        return output.cropped(to: output.extent)
    }
}

// MARK: - Capture delegates

nonisolated extension DocumentEdgeScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Runs on sessionQueue.
        guard isRunning,
              !isCapturingStill,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Publish the rotated frame's aspect once, from the first real buffer.
        if !hasPublishedAspect {
            hasPublishedAspect = true
            let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            Task { @MainActor in self.onVideoAspectRatio?(aspect) }
        }

        let now = Date()
        guard now.timeIntervalSince(lastDetectionAt) >= 0.09 else { return }
        lastDetectionAt = now

        let quad = Self.detectQuad(in: pixelBuffer)
        updateTracking(with: quad)
        Task { @MainActor in self.onQuadUpdate?(quad) }
    }
}

nonisolated extension DocumentEdgeScanner: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        // Delegate queue → finish all state on sessionQueue.
        sessionQueue.async {
            self.isCapturingStill = false
            let image = self.processPhoto(photo, error: error)
            Task { @MainActor in self.onCapture?(image) }
        }
    }
}
