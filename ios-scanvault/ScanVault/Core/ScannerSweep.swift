//
//  ScannerSweep.swift
//  ScanVault
//

import SwiftUI
import UIKit

// MARK: - SwiftUI sweep

/// Overlays an amber scanner light that sweeps across the content while
/// scanning or analysis is running. Respects Reduce Motion by parking the
/// beam mid-content as a steady glow.
struct ScanSweepModifier: ViewModifier {
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { proxy in
                        SweepBeam(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            reduceMotion: reduceMotion
                        )
                    }
                    .allowsHitTesting(false)
                    .clipped()
                }
            }
            .animation(Theme.soft, value: active)
    }
}

private struct SweepBeam: View {
    let width: CGFloat
    let height: CGFloat
    let reduceMotion: Bool

    /// One full down-and-up cycle, in seconds.
    private let period: Double = 1.9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            beam(progress: reduceMotion ? 0.5 : progress(at: timeline.date.timeIntervalSinceReferenceDate))
        }
    }

    private func beam(progress: CGFloat) -> some View {
        LinearGradient(
            colors: [
                .clear,
                Theme.amber.opacity(0.05),
                Theme.amber.opacity(0.30),
                Theme.amber.opacity(0.05),
                .clear,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: width, height: bandHeight)
        .overlay(alignment: .center) {
            Capsule()
                .fill(Theme.amberBright)
                .frame(width: width, height: 2.5)
                .shadow(color: Theme.amber, radius: 7)
        }
        .offset(y: -bandHeight + progress * (height + bandHeight * 2))
        .blendMode(.plusLighter)
    }

    private var bandHeight: CGFloat { max(46, height * 0.12) }

    /// Ping-pong progress: top → bottom → top over `period` seconds.
    private func progress(at interval: TimeInterval) -> CGFloat {
        let phase = interval.truncatingRemainder(dividingBy: period) / period
        return phase < 0.5 ? phase * 2 : (1 - phase) * 2
    }
}

extension View {
    /// Overlays the amber scan light while `active`.
    func scanSweep(active: Bool) -> some View {
        modifier(ScanSweepModifier(active: active))
    }
}

// MARK: - UIKit sweep (VisionKit camera)

/// UIKit twin of the SwiftUI beam, layered over VisionKit's document camera
/// so the viewfinder gets the same travelling light. Non-interactive, so the
/// system shutter and corners keep working.
final class ScannerSweepUIKitOverlay: UIView {
    private let beam = CAGradientLayer()
    private let amber = UIColor(red: 0.909, green: 0.639, blue: 0.239, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        beam.colors = [
            amber.withAlphaComponent(0).cgColor,
            amber.withAlphaComponent(0.05).cgColor,
            amber.withAlphaComponent(0.34).cgColor,
            amber.withAlphaComponent(0.05).cgColor,
            amber.withAlphaComponent(0).cgColor,
        ]
        beam.locations = [0, 0.34, 0.5, 0.66, 1]
        beam.startPoint = CGPoint(x: 0.5, y: 0)
        beam.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(beam)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        beam.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 64)
        CATransaction.commit()

        guard beam.animation(forKey: "sv.sweep") == nil else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = -72
        sweep.toValue = bounds.height + 72
        sweep.duration = 1.9
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        beam.add(sweep, forKey: "sv.sweep")
    }
}
