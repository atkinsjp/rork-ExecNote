//
//  OCRService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import UIKit
import Vision

/// Extracts searchable keywords from scanned pages using on-device Vision text
/// recognition. Runs entirely off the main actor so scanning stays responsive.
actor OCRService {
    static let shared = OCRService()

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "your", "you", "are",
        "was", "will", "have", "has", "not", "all", "any", "but", "can", "may",
        "shall", "into", "such", "which", "their", "there", "been", "were", "than",
        "then", "they", "them", "who", "our", "out", "per", "upon", "each", "also",
    ]

    /// Returns up to `limit` distinctive keywords ranked by frequency.
    func keywords(from images: [UIImage], limit: Int = 24) async -> [String] {
        var counts: [String: Int] = [:]

        for image in images.prefix(6) {
            guard let cgImage = image.cgImage else { continue }
            for token in Self.recognizeTokens(in: cgImage) {
                counts[token, default: 0] += 1
            }
        }

        return counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// Accurate full text per page for a multi-page scan. Pages stay separate
    /// so transcription exports and the search index can split them back out.
    func fullText(from images: [UIImage]) async -> [String] {
        var pageTexts: [String] = []
        for image in images.prefix(10) {
            pageTexts.append(recognizedText(in: image))
        }
        return pageTexts
    }

    /// Full recognized text for a single page, used by the document inspector.
    func recognizedText(in image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func recognizeTokens(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines
            .flatMap { $0.components(separatedBy: CharacterSet.alphanumerics.inverted) }
            .map { $0.lowercased() }
            .filter { $0.count >= 4 && $0.count <= 22 && !stopWords.contains($0) }
    }
}
