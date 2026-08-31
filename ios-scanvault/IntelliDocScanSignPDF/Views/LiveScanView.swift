//
//  LiveScanView.swift
//  IntelliDocScanSignPDF
//

import AVFoundation
import SwiftUI

// MARK: - Entry point

/// Camera capture entry used by every scan flow. Prefers the custom live
/// scanner (real-time edge detection + auto-capture); falls back to the
/// VisionKit document camera when the custom pipeline can't run.
struct CameraCaptureView: View {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    var body: some View {
        if DocumentEdgeScanner.isHardwareAvailable {
            LiveScanView(onFinish: onFinish, onCancel: onCancel, onError: onError)
        } else {
            DocumentCameraView(onFinish: onFinish, onCancel: onCancel, onError: onError)
        }
    }
}

// MARK: - Scan model

/// Main-actor state for one live scanning session.
@MainActor
@Observable
final class LiveScanModel {
    enum Phase: Equatable {
        case starting
        case running
        case permissionDenied
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var quad: DocumentQuad?
    private(set) var videoAspect: CGFloat = 3.0 / 4.0
    private(set) var pages: [UIImage] = []
    private(set) var isAutoCapturing = false
    /// Bumped on every capture attempt so the view can flash the shutter.
    private(set) var capturePulse = 0

    var isAutoCaptureEnabled = true
    private(set) var isTorchOn = false

    private var edgeScanner: DocumentEdgeScanner?
    var previewSession: AVCaptureSession? { edgeScanner?.session }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                phase = .permissionDenied
                return
            }
        } else if status != .authorized {
            phase = .permissionDenied
            return
        }

        let scanner = DocumentEdgeScanner()
        edgeScanner = scanner
        scanner.onQuadUpdate = { [weak self] quad in
            self?.quad = quad
        }
        scanner.onVideoAspectRatio = { [weak self] aspect in
            self?.videoAspect = aspect
        }
        scanner.onStableDocument = { [weak self] in
            self?.autoCapture()
        }
        scanner.onConfigurationError = { [weak self] message in
            self?.phase = .failed(message)
        }
        scanner.onCapture = { [weak self] image in
            guard let self else { return }
            self.isAutoCapturing = false
            guard let image else { return }
            self.pages.append(image)
            Haptics.success()
        }
        scanner.start()
        phase = .running
    }

    func stop() {
        edgeScanner?.stop()
        edgeScanner = nil
    }

    func captureManually() {
        guard phase == .running, !isAutoCapturing else { return }
        capturePulse += 1
        edgeScanner?.capturePhoto()
    }

    func setTorch(_ enabled: Bool) {
        isTorchOn = enabled
        edgeScanner?.setTorchEnabled(enabled)
    }

    /// Fired by the scanner when a well-framed document has held steady.
    private func autoCapture() {
        guard isAutoCaptureEnabled, phase == .running, !isAutoCapturing else { return }
        isAutoCapturing = true
        Haptics.impact(.light)
        capturePulse += 1
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard phase == .running, isAutoCapturing else { return }
            edgeScanner?.capturePhoto()
        }
    }
}

// MARK: - Live scan view

/// Full-screen live viewfinder with an amber document-edge overlay, framing
/// guidance, and manual + auto capture.
struct LiveScanView: View {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (Error) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = LiveScanModel()
    @State private var isFlashing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .statusBarHidden()
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.capturePulse) { _, _ in
            isFlashing = true
            Task {
                try? await Task.sleep(for: .seconds(0.22))
                isFlashing = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            ProgressView().tint(Theme.amberBright)
        case .permissionDenied:
            blockedState(
                symbol: "video.slash",
                title: "Camera access needed",
                message: "Allow IntelliDoc to use the camera to scan documents into your private on-device vault."
            ) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(Theme.mono(.callout))
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.amber))
                Button("Cancel", action: onCancel)
                    .font(Theme.mono(.callout))
                    .foregroundStyle(.white.opacity(0.75))
            }
        case .failed(let message):
            blockedState(symbol: "exclamationmark.triangle", title: "Scanning problem", message: message) {
                Button("Close") {
                    onError(NSError(
                        domain: "IntelliDocScanner",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                }
                .font(Theme.mono(.callout))
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.amber))
            }
        case .running:
            viewfinder
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        ZStack {
            if let session = model.previewSession {
                CameraPreviewView(session: session)
                    .ignoresSafeArea()
            } else {
                Color.black
            }

            QuadOverlay(quad: model.quad, videoAspect: model.videoAspect)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                VStack(spacing: 16) {
                    if let guidance = guidanceText {
                        Text(guidance)
                            .font(Theme.mono(.footnote))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.black.opacity(0.55)))
                    }
                    controlBar
                }
                .padding(.bottom, 18)
            }

            Color.white
                .ignoresSafeArea()
                .opacity(isFlashing ? 0.85 : 0)
                .allowsHitTesting(false)
        }
        // NOTE: no whole-ZStack animation here — the quad updates ~10×/sec,
        // and a perpetually-restarting spring on this container (which holds
        // the controls) was swallowing taps on the close/torch buttons.
    }

    private var topBar: some View {
        HStack {
            CircleButton(symbol: "xmark") {
                Haptics.impact(.light)
                model.stop()
                onCancel()
                // Belt and suspenders: dismiss the presentation directly in
                // case the caller's cancellation path stalls.
                dismiss()
            }
            Spacer()
            CircleButton(symbol: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                model.setTorch(!model.isTorchOn)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var guidanceText: String? {
        if model.isAutoCapturing { return "Hold steady — capturing" }
        guard let quad = model.quad else { return "Position the document inside the frame" }
        if quad.area < 0.14 { return "Move closer to the document" }
        return model.isAutoCaptureEnabled ? "Hold steady to auto-capture" : "Ready — tap the shutter"
    }

    private var controlBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                autoCapturePill
                if let last = model.pages.last {
                    Image(uiImage: last)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(.rect(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Theme.amber, lineWidth: 1.5)
                        }
                }
            }
            .frame(minWidth: 86, alignment: .leading)

            Spacer()

            shutterButton

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                if model.pages.isEmpty {
                    Text("Pages")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(minWidth: 86, alignment: .trailing)
                } else {
                    Button {
                        onFinish(model.pages)
                    } label: {
                        Text("Done · \(model.pages.count)")
                            .font(Theme.mono(.callout).weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                    }
                    .background(Capsule().fill(Theme.amber))
                }
            }
            .frame(minWidth: 86, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }

    private var autoCapturePill: some View {
        Button {
            model.isAutoCaptureEnabled.toggle()
            Haptics.selection()
        } label: {
            Label("Auto", systemImage: "sparkle")
                .font(Theme.mono(.caption).weight(.semibold))
                .foregroundStyle(model.isAutoCaptureEnabled ? .black : .white.opacity(0.85))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        model.isAutoCaptureEnabled
                            ? Theme.amber
                            : Color.white.opacity(0.16)
                    )
                )
        }
    }

    private var shutterButton: some View {
        Button(action: { model.captureManually() }) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 80, height: 80)
                Circle()
                    .fill(model.isAutoCapturing ? Theme.amber : .white)
                    .frame(width: 64, height: 64)
            }
        }
        .scaleEffect(model.isAutoCapturing ? 0.92 : 1)
        .animation(Theme.soft, value: model.isAutoCapturing)
        .disabled(model.isAutoCapturing)
    }

    // MARK: Shared states

    private func blockedState(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.amber)
            Text(title)
                .font(Theme.mono(.title3).weight(.semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(Theme.mono(.footnote))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            actions()
        }
    }
}

// MARK: - Supporting views

private struct CircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Camera preview layer bound to the scanner's session.
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Draws the live document quad (amber frame + dimmed surroundings), or a
/// dashed guide rectangle while nothing is detected yet.
private struct QuadOverlay: View {
    let quad: DocumentQuad?
    let videoAspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let frame = aspectFilledFrame(in: proxy.size)
            if let quad {
                QuadShape(quad: quad, frame: frame, size: proxy.size)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        Theme.amber.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 7])
                    )
                    .frame(
                        width: frame.width * 0.76,
                        height: frame.height * 0.76
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        // Animate the detection overlay in isolation — never the controls
        // layered above it.
        .animation(Theme.soft, value: quad)
    }

    /// The on-screen rect covered by the aspect-filled video feed.
    private func aspectFilledFrame(in size: CGSize) -> CGRect {
        guard videoAspect > 0 else { return CGRect(origin: .zero, size: size) }
        let viewAspect = size.width / size.height
        if videoAspect > viewAspect {
            let height = size.width / videoAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * videoAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }
}

private struct QuadShape: View {
    let quad: DocumentQuad
    let frame: CGRect
    let size: CGSize

    var body: some View {
        let points = quad.corners.map { corner in
            CGPoint(
                x: frame.origin.x + corner.x * frame.width,
                y: frame.origin.y + corner.y * frame.height
            )
        }
        var quadPath = Path()
        quadPath.move(to: points[0])
        for point in points.dropFirst() { quadPath.addLine(to: point) }
        quadPath.closeSubpath()

        var dimPath = Path()
        dimPath.addRect(CGRect(origin: .zero, size: size))
        dimPath.addPath(quadPath)

        return ZStack {
            dimPath
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            quadPath
                .fill(Theme.amber.opacity(0.08))
            quadPath
                .stroke(Theme.amberBright, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                .shadow(color: Theme.amber, radius: 6)
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(Theme.amberBright)
                    .frame(width: 10, height: 10)
                    .shadow(color: Theme.amber, radius: 4)
                    .position(points[index])
            }
        }
    }
}
