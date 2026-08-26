//
//  PDFSignerService.swift
//  ScanVault
//

import CryptoKit
import Foundation
import PDFKit
import SwiftUI
import UIKit

nonisolated enum SignatureServiceError: LocalizedError {
    case noPages
    case missingProfile
    case renderFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPages: "This document has no pages to sign."
        case .missingProfile: "One of the placed signatures could not be found."
        case .renderFailed: "The signed PDF could not be rendered."
        case .saveFailed(let reason): "The signed PDF could not be saved: \(reason)"
        }
    }
}

/// Result of finalizing a signed document.
nonisolated struct SignedPDFResult: Sendable {
    let url: URL
    let data: Data
    let audit: SignatureAuditRecord
}

/// Burns signature stamps into a document, then produces a cryptographic audit
/// trail (SHA-256) and an appended Certificate of Completion page.
@MainActor
final class PDFSignerService {
    static let shared = PDFSignerService()

    private let pdf = PDFManager.shared

    /// Rasterizes every page of `url` for on-screen placement editing.
    func pageImages(for url: URL) async -> [UIImage] {
        await pdf.pageImages(for: url)
    }

    /// Flattens `placements` onto the document, hashes the result, and (when
    /// requested) appends a styled audit certificate page.
    ///
    /// The output is image-only: stamps are drawn straight into the page
    /// graphics context, so they can never be moved, selected or extracted.
    func finalize(
        documentId: String,
        sourceURL: URL,
        placements: [PlacementData],
        profiles: [SignatureProfile],
        signerName: String,
        signerEmail: String,
        includeAuditPage: Bool
    ) async throws -> SignedPDFResult {
        let pages = await pdf.pageImages(for: sourceURL)
        guard !pages.isEmpty else { throw SignatureServiceError.noPages }

        let profileById = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for placement in placements where profileById[placement.profileId] == nil {
            throw SignatureServiceError.missingProfile
        }

        // 1. Burn the stamps into image-only pages.
        let stampedPages = await Self.renderStampedPages(pages: pages, placements: placements, profileById: profileById)

        // 2. Hash the signed document *before* the audit page is attached, so
        //    the certificate can carry the hash of the content pages.
        let signedData = try await Self.renderPDF(pages: stampedPages)
        let digest = SHA256.hash(data: signedData)
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        let audit = SignatureAuditRecord(
            documentId: documentId,
            signerName: signerName,
            signerEmail: signerEmail,
            deviceModel: Self.deviceModel,
            documentSHA256: hash,
            signaturePlacements: placements
        )

        // 3. Append the Certificate of Completion.
        var finalData = signedData
        if includeAuditPage {
            let thumbnails = placements.compactMap { profileById[$0.profileId] }
            let certificate = await Self.renderCertificatePage(audit: audit, signatures: thumbnails)
            finalData = try await Self.renderPDF(pages: stampedPages + [certificate])
        }

        // 4. Persist.
        do {
            let url = try await pdf.save(finalData, documentId: documentId)
            return SignedPDFResult(url: url, data: finalData, audit: audit)
        } catch {
            throw SignatureServiceError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Rendering (off the main actor)

    /// Draws each page, then composites every stamp placed on it.
    ///
    /// Placement rects are normalized top-left over the page *image*, so they
    /// are translated through the same aspect-fit frame the scan uses on the
    /// Letter page — regardless of zoom, pan or page rotation the editor saw.
    nonisolated private static func renderStampedPages(
        pages: [UIImage],
        placements: [PlacementData],
        profileById: [UUID: SignatureProfile]
    ) async -> [UIImage] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        var output: [UIImage] = []
        for (index, page) in pages.enumerated() {
            let renderer = UIGraphicsImageRenderer(size: page.size, format: format)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: page.size))
                page.draw(at: .zero)

                for placement in placements where placement.pageIndex == index {
                    guard let profile = profileById[placement.profileId],
                          let stamp = UIImage(data: profile.pngData)
                    else { continue }

                    let frame = CGRect(
                        x: placement.rect.minX * page.size.width,
                        y: placement.rect.minY * page.size.height,
                        width: placement.rect.width * page.size.width,
                        height: placement.rect.height * page.size.height
                    )
                    draw(stamp: stamp, in: frame, rotationDegrees: placement.rotationDegrees)
                }
            }
            output.append(image)
        }
        return output
    }

    /// Draws `stamp` centered in `frame`, rotated about its center.
    nonisolated private static func draw(
        stamp: UIImage,
        in frame: CGRect,
        rotationDegrees: Double
    ) {
        guard frame.width > 1, frame.height > 1 else { return }
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        defer { context?.restoreGState() }

        context?.translateBy(x: frame.midX, y: frame.midY)
        if rotationDegrees != 0 {
            context?.rotate(by: CGFloat(rotationDegrees) * .pi / 180)
        }
        let centered = CGRect(
            x: -frame.width / 2,
            y: -frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        stamp.draw(in: centered)
    }

    /// Composites `pages` into one multi-page PDF.
    nonisolated private static func renderPDF(pages: [UIImage]) async throws -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "ScanVault Sign",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PDFManager.pageSize), format: format)

        let data = renderer.pdfData { context in
            for image in pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: PDFManager.pageSize))
                image.draw(in: PDFManager.aspectFitRect(for: image.size, in: PDFManager.pageSize))
            }
        }

        guard !data.isEmpty else { throw SignatureServiceError.renderFailed }
        return data
    }

    /// The "Certificate of Completion" audit page: document ID, signer, dual
    /// timestamps, verification hash and previews of every placed stamp.
    nonisolated private static func renderCertificatePage(
        audit: SignatureAuditRecord,
        signatures: [SignatureProfile]
    ) async -> UIImage {
        let size = PDFManager.pageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let cg = context.cgContext
            let canvas = CGRect(origin: .zero, size: size)

            // Paper backdrop with a subtle warm wash.
            UIColor(Theme.paper).setFill()
            cg.fill(canvas)
            UIColor(Color(hex: "E8A33D")).withAlphaComponent(0.05).setFill()
            cg.fill(canvas)

            let ink = UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
            let muted = UIColor(red: 0.35, green: 0.37, blue: 0.41, alpha: 1)

            func draw(_ text: String, font: UIFont, color: UIColor, at point: CGPoint, maxWidth: CGFloat) {
                (text as NSString).draw(
                    with: CGRect(x: point.x, y: point.y, width: maxWidth, height: 200),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: font, .foregroundColor: color],
                    context: nil
                )
            }

            let margin: CGFloat = 64
            var y: CGFloat = 72

            // Header rule + title.
            draw("SCANVAULT",
                 font: .monospacedSystemFont(ofSize: 11, weight: .semibold),
                 color: UIColor(Color(hex: "E8A33D")),
                 at: CGPoint(x: margin, y: y), maxWidth: size.width - margin * 2)
            y += 22
            draw("Certificate of Completion",
                 font: .systemFont(ofSize: 27, weight: .semibold),
                 color: ink,
                 at: CGPoint(x: margin, y: y), maxWidth: size.width - margin * 2)
            y += 34
            draw("Audit trail for an electronically signed document. The SHA-256 digest below "
               + "verifies the signed pages byte-for-byte; any later edit invalidates it.",
                 font: .systemFont(ofSize: 10.5, weight: .regular),
                 color: muted,
                 at: CGPoint(x: margin, y: y), maxWidth: size.width - margin * 2)
            y += 44

            cg.setStrokeColor(UIColor(red: 0.85, green: 0.83, blue: 0.78, alpha: 1).cgColor)
            cg.setLineWidth(1)
            cg.move(to: CGPoint(x: margin, y: y))
            cg.addLine(to: CGPoint(x: size.width - margin, y: y))
            cg.strokePath()
            y += 24

            // Key/value rows.
            let utc = ISO8601DateFormatter().string(from: audit.timestamp)
            let local = audit.timestamp.formatted(
                date: .long, time: .standard
            )

            let rows: [(String, String)] = [
                ("Document ID", audit.documentId),
                ("Signed by", "\(audit.signerName)  ·  \(audit.signerEmail)"),
                ("Timestamp (UTC)", utc),
                ("Timestamp (local)", local),
                ("Device", audit.deviceModel),
                ("Signatures placed", "\(audit.signaturePlacements.count) across \(Set(audit.signaturePlacements.map(\.pageIndex)).count) page(s)"),
            ]

            let labelFont = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
            let valueFont = UIFont.systemFont(ofSize: 12, weight: .medium)

            for (label, value) in rows {
                draw(label.uppercased(), font: labelFont, color: muted, at: CGPoint(x: margin, y: y), maxWidth: 180)
                draw(value, font: valueFont, color: ink, at: CGPoint(x: margin + 190, y: y - 2), maxWidth: size.width - margin * 2 - 190)
                y += 26
            }

            y += 14
            draw("VERIFICATION SHA-256",
                 font: labelFont, color: muted,
                 at: CGPoint(x: margin, y: y), maxWidth: 300)
            y += 16

            // Hash, wrapped across two monospaced lines.
            let hashFont = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
            let half = audit.documentSHA256.count / 2
            draw(String(audit.documentSHA256.prefix(half)), font: hashFont, color: ink,
                 at: CGPoint(x: margin, y: y), maxWidth: size.width - margin * 2)
            y += 18
            draw(String(audit.documentSHA256.suffix(audit.documentSHA256.count - half)), font: hashFont, color: ink,
                 at: CGPoint(x: margin, y: y), maxWidth: size.width - margin * 2)
            y += 36

            // Stamp previews.
            if !signatures.isEmpty {
                draw("PLACED SIGNATURES", font: labelFont, color: muted,
                     at: CGPoint(x: margin, y: y), maxWidth: 300)
                y += 18

                var x = margin
                let previewHeight: CGFloat = 56
                for profile in signatures.prefix(5) {
                    guard let stamp = UIImage(data: profile.pngData) else { continue }
                    let aspect = stamp.size.width / max(stamp.size.height, 1)
                    let frame = CGRect(
                        x: x,
                        y: y,
                        width: min(previewHeight * aspect, 170),
                        height: previewHeight
                    )
                    // Card behind each stamp.
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: frame.insetBy(dx: -8, dy: -6), cornerRadius: 8).fill()
                    UIColor(red: 0.85, green: 0.83, blue: 0.78, alpha: 1).setStroke()
                    UIBezierPath(roundedRect: frame.insetBy(dx: -8, dy: -6), cornerRadius: 8).stroke()
                    stamp.draw(in: frame)

                    draw(profile.title, font: .systemFont(ofSize: 8, weight: .medium), color: muted,
                         at: CGPoint(x: frame.minX - 8, y: frame.maxY + 10), maxWidth: frame.width + 16)

                    x += frame.width + 34
                    if x > size.width - margin - 60 { break }
                }
            }

            // Footer.
            draw("Generated on-device by ScanVault · No server processed this document.",
                 font: .systemFont(ofSize: 9, weight: .regular), color: muted,
                 at: CGPoint(x: margin, y: size.height - 56), maxWidth: size.width - margin * 2)
        }
    }

    /// Marketing model identifier (e.g. "iPhone16,1"), used in the audit record.
    nonisolated private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
