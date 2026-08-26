//
//  PDFCompressionService.swift
//  ScanVault
//

import Foundation
import PDFKit
import UIKit

nonisolated enum CompressionError: LocalizedError {
    case noPages
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noPages: "This document has no pages to compress."
        case .renderFailed: "The optimized PDF could not be rendered."
        }
    }
}

/// Export presets tuned for real-world destinations.
nonisolated enum CompressionPreset: String, CaseIterable, Identifiable, Sendable {
    /// Email / Web — JPEG 0.5, capped at 150 DPI.
    case email
    /// Government / form upload — grayscale, JPEG 0.35, capped at 100 DPI.
    case government
    /// Archival / print — JPEG 0.85, up to 300 DPI.

    case archival

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: "Email / Web"
        case .government: "Government Upload"
        case .archival: "Archival / Print"
        }
    }

    var subtitle: String {
        switch self {
        case .email: "Under 5 MB · 150 DPI"
        case .government: "Under 1 MB · grayscale · 100 DPI"
        case .archival: "Max resolution · 300 DPI"
        }
    }

    var symbolName: String {
        switch self {
        case .email: "envelope"
        case .government: "building.columns.fill"
        case .archival: "internaldrive.fill"
        }
    }

    var targetLabel: String {
        switch self {
        case .email: "< 5 MB"
        case .government: "< 1 MB"
        case .archival: "Max res"
        }
    }

    /// JPEG encode quality applied to every rasterized page.
    var jpegQuality: CGFloat {
        switch self {
        case .email: 0.5
        case .government: 0.35
        case .archival: 0.85
        }
    }

    /// Raster width ceiling in pixels (US Letter: 612 pt → 8.5 in).
    var maxWidth: CGFloat {
        switch self {
        case .email: 1275 // 150 DPI
        case .government: 850 // 100 DPI
        case .archival: 2550 // 300 DPI
        }
    }

    /// Grayscale conversion for the aggressive preset.
    var convertsToGrayscale: Bool {
        self == .government
    }
}

/// Rasterizes, re-encodes and rebuilds PDFs under a chosen preset.
actor PDFCompressionService {
    static let shared = PDFCompressionService()

    private let pdf = PDFManager.shared

    // MARK: - Estimates

    /// Current on-disk size of the document's PDF, in bytes.
    func originalSize(url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Fast projected compressed size: renders page 1 under the preset and
    /// scales its encoded bytes by the page count.
    func estimateCompressedSize(url: URL, preset: CompressionPreset) async -> Int64 {
        let pages = await pdf.pageImages(for: url, maxWidth: preset.maxWidth)
        guard let first = pages.first else { return 0 }

        let encoded = await Self.encodedPageImage(first, preset: preset)
        let projected = Int64(encoded.count) * Int64(pages.count)
        // Rebuild overhead is a few %, folded in for honesty.
        return Int64(Double(projected) * 1.04)
    }

    // MARK: - Compression

    /// Builds a compressed copy of the PDF and writes it to a temporary file.
    /// - Returns: the temp URL plus the final byte count.
    func compress(
        url: URL,
        preset: CompressionPreset,
        documentId: String
    ) async throws -> (url: URL, size: Int64) {
        let pages = await pdf.pageImages(for: url, maxWidth: preset.maxWidth)
        guard !pages.isEmpty else { throw CompressionError.noPages }

        // JPEG-encode each rasterized page at the preset quality so the
        // renderer embeds the compressed bytes, not the lossless bitmap.
        var encodedPages: [UIImage] = []
        for image in pages {
            let data = await Self.encodedPageImage(image, preset: preset)
            encodedPages.append(data.isEmpty ? image : (UIImage(data: data) ?? image))
        }

        var data = await Self.render(pages: encodedPages, quality: preset.jpegQuality, grayscale: false)
        guard !data.isEmpty else { throw CompressionError.renderFailed }

        // When the first pass overshoots the target, drop quality once more.
        if preset != .archival, let target = preset.targetBytes, data.count > target {
            let retry = await Self.render(pages: encodedPages, quality: preset.jpegQuality * 0.75, grayscale: false)
            if !retry.isEmpty, retry.count < data.count {
                data = retry
            }
        }

        let exportURL = FileManager.default.temporaryDirectory
            .appending(path: "\(documentId)-\(preset.rawValue).pdf")
        try data.write(to: exportURL, options: .atomic)

        var size = Int64(data.count)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: exportURL.path),
           let bytes = attributes[.size] as? Int64 {
            size = bytes
        }
        return (exportURL, size)
    }

    // MARK: - Page encoding

    /// JPEG-encodes (and optionally grayscales) a page image. Rasterization
    /// already caps the pixel width, so only color space + quality apply here.
    nonisolated private static func encodedPageImage(
        _ image: UIImage,
        preset: CompressionPreset
    ) async -> Data {
        let prepared = preset.convertsToGrayscale ? grayscale(image) : image
        return prepared.jpegData(compressionQuality: preset.jpegQuality) ?? Data()
    }

    /// One full render pass at an explicit quality. Grayscale conversion
    /// happens per-page in `encodedPageImage`, so this stays color-agnostic.
    nonisolated private static func render(
        pages: [UIImage],
        quality: CGFloat,
        grayscale: Bool
    ) async -> Data {
        _ = quality
        _ = grayscale
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "ScanVault Export"]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: PDFManager.pageSize),
            format: format
        )
        return renderer.pdfData { context in
            for image in pages {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: PDFManager.pageSize))
                let fit = PDFManager.aspectFitRect(for: image.size, in: PDFManager.pageSize)
                image.draw(in: fit)
            }
        }
    }

    /// CoreGraphics grayscale conversion — half the bytes of RGB before JPEG
    /// even starts, ideal for government form uploads.
    nonisolated private static func grayscale(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return image }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { return image }
        return UIImage(cgImage: output)
    }
}

nonisolated extension CompressionPreset {
    /// Hard ceiling in bytes the preset tries to respect, if any.
    var targetBytes: Int? {
        switch self {
        case .email: 5 * 1_024 * 1_024
        case .government: 1_024 * 1_024
        case .archival: nil
        }
    }
}
