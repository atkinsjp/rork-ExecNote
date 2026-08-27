//
//  HandwritingTranscriptionService.swift
//  IntelliDocScanSignPDF
//
//  Multimodal handwriting transcription: sends scanned note pages to
//  Gemini 2.5 Flash through the toolkit proxy and gets back clean,
//  structured Markdown.
//

import Foundation
import OSLog
import UIKit

/// Transcribes handwritten and mixed notes from scanned page images.
actor HandwritingTranscriptionService {
    static let shared = HandwritingTranscriptionService()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "handwriting")

    /// Total byte budget for embedded images. The gateway rejects request
    /// bodies above ~4.5 MB; base64 adds ~33%, so keep raw JPEG well under.
    private static let totalByteBudget = 2_600_000
    /// Pages beyond this are ignored — older pages keep the payload sane.
    private static let maxPages = 6

    /// Transcribes `pages` into clean Markdown, preserving lists, indented
    /// structure and diagram descriptions.
    func transcribe(pages: [UIImage]) async throws -> String {
        guard !pages.isEmpty else { throw AIGatewayError.payloadTooLarge }
        let limited = Array(pages.prefix(Self.maxPages))
        let images = Self.prepareImages(limited)

        guard !images.isEmpty else { throw AIGatewayError.payloadTooLarge }

        var content: [[String: Any]] = [
            [
                "type": "text",
                "text": """
                Accurately transcribe all handwritten and mixed text, correcting \
                spelling errors while preserving lists, indented structures, and \
                diagram descriptions.

                Transcribe every page in order into a single continuous document. \
                Preserve bullet lists and indentation as Markdown. Where the page \
                contains a diagram, sketch or chart, describe it in a short \
                bracketed line like [Diagram: organization chart of the rollout team]. \
                If a word is illegible, render your best guess. Output ONLY the \
                transcription as clean Markdown — no preamble, no commentary.
                """,
            ],
        ]
        for image in images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64)"],
            ])
        }

        let body: [String: Any] = [
            "model": AIGatewayClient.model,
            "messages": [["role": "user", "content": content]],
            "temperature": 0.1,
            "max_tokens": 8192,
        ]

        let text = try await AIGatewayClient.complete(body: body)
        logger.info("Handwriting transcription finished (\(text.count, privacy: .public) chars)")
        return Self.stripCodeFence(text)
    }

    // MARK: - Image preparation

    private struct PreparedImage {
        let base64: String
        let byteCount: Int
    }

    /// Downscales pages and walks a JPEG-quality ladder until the whole set
    /// fits the byte budget.
    private static func prepareImages(_ pages: [UIImage]) -> [PreparedImage] {
        let perPageBudget = totalByteBudget / pages.count

        // Pixel ladder first (long edge), then quality ladder.
        let pixelSteps: [CGFloat] = [1400, 1100, 880, 700]
        let qualitySteps: [CGFloat] = [0.78, 0.66, 0.55]

        for maxDimension in pixelSteps {
            for quality in qualitySteps {
                var prepared: [PreparedImage] = []
                var total = 0
                for page in pages {
                    let scaled = downscale(page, maxDimension: maxDimension)
                    guard let jpeg = scaled.jpegData(compressionQuality: quality) else { continue }
                    total += jpeg.count
                    prepared.append(
                        PreparedImage(base64: jpeg.base64EncodedString(), byteCount: jpeg.count)
                    )
                }
                if !prepared.isEmpty,
                   total <= totalByteBudget,
                   prepared.allSatisfy({ $0.byteCount <= perPageBudget * 2 }) {
                    return prepared
                }
            }
        }
        return []
    }

    /// Long-edge downscale; returns the original when already small enough.
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height) * image.scale
        guard largest > maxDimension, largest > 0 else { return image }

        let ratio = maxDimension / largest
        let targetSize = CGSize(
            width: floor(image.size.width * ratio * image.scale) / image.scale,
            height: floor(image.size.height * ratio * image.scale) / image.scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Models often wrap output in a Markdown code fence; unwrap it.
    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
