//
//  OCRRedactionService.swift
//  ScanVault
//

import Foundation
import UIKit
import Vision

nonisolated enum RedactionError: LocalizedError {
    case nothingToRedact
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .nothingToRedact: "Select at least one region to redact."
        case .renderFailed: "The sanitized PDF could not be rendered."
        }
    }
}

/// On-device PII detection and permanent redaction.
///
/// Detection runs Vision's accurate text recognizer over each rasterized page
/// and maps every regex match back to its bounding box in the image. The
/// renderer then burns opaque black rectangles over the selected regions into
/// a brand-new, image-only PDF — because the output is fully rasterized it
/// carries no text layer, so redacted content cannot be copied, searched or
/// recovered from the raw PDF binary.
actor OCRRedactionService {
    static let shared = OCRRedactionService()

    // MARK: - Detection patterns

    /// `123-45-6789`
    private static let ssnStrict = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)
    /// Nine bare digits (SSNs printed without separators).
    private static let ssnLoose = try! NSRegularExpression(pattern: #"\b\d{9}\b"#)
    /// RFC 5322-style address, practical subset.
    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    /// 13–18 digits possibly grouped by dashes/spaces; Luhn-validated afterwards.
    private static let card = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){12,17}\d\b"#)
    /// US + international forms: +1 415 555 0132, (415) 555-0132, 415.555.0132.
    private static let phone = try! NSRegularExpression(pattern: #"\b(?:\+?\d{1,3}[\s.\-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.\-]?\d{3}[\s.\-]?\d{3,4}\b"#)

    private struct Match {
        let kind: RedactionKind
        let text: String
        let range: Range<String.Index>
    }

    // MARK: - Analysis

    /// Runs accurate OCR on one page and returns every PII detection with a
    /// bounding box normalized to the page image (top-left origin).
    ///
    /// When `customTerm` is provided, occurrences of that user-supplied string
    /// are flagged in addition to the automatic categories.
    func analyzePage(_ image: UIImage, pageIndex: Int, customTerm: String? = nil) -> [RedactionBox] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        var boxes: [RedactionBox] = []
        let term = customTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string

            for match in Self.matches(in: line) {
                appendBox(
                    for: match,
                    candidate: candidate,
                    pageIndex: pageIndex,
                    into: &boxes
                )
            }

            for range in Self.customRanges(of: term, in: line) {
                appendBox(
                    for: Match(kind: .custom, text: term, range: range),
                    candidate: candidate,
                    pageIndex: pageIndex,
                    into: &boxes
                )
            }
        }

        return boxes
    }

    private func appendBox(
        for match: Match,
        candidate: VNRecognizedText,
        pageIndex: Int,
        into boxes: inout [RedactionBox]
    ) {
        guard let observation = try? candidate.boundingBox(for: match.range) else { return }
        let raw = observation.boundingBox
        // Vision reports normalized boxes with a bottom-left origin; flip to
        // the top-left origin used by UIKit and our canvas overlay.
        let rect = CGRect(x: raw.minX, y: 1 - raw.maxY, width: raw.width, height: raw.height)
        guard rect.width >= 0.004, rect.height >= 0.004 else { return }
        guard !boxes.contains(where: { Self.overlaps($0.rect, rect) }) else { return }

        boxes.append(
            RedactionBox(
                pageIndex: pageIndex,
                rect: rect,
                kind: match.kind,
                matchedText: match.text,
                isManual: false,
                isSelected: true
            )
        )
    }

    /// All PII matches in a recognized line of text.
    private static func matches(in line: String) -> [Match] {
        var result: [Match] = []
        let full = NSRange(line.startIndex..., in: line)

        func add(
            _ regex: NSRegularExpression,
            _ kind: RedactionKind,
            validate: (String) -> Bool = { _ in true }
        ) {
            for match in regex.matches(in: line, range: full) {
                guard let range = Range(match.range, in: line) else { continue }
                let text = String(line[range])
                guard validate(text) else { continue }
                result.append(Match(kind: kind, text: text, range: range))
            }
        }

        // Priority order matters: earlier categories win overlapping regions.
        add(ssnStrict, .ssn)
        add(ssnLoose, .ssn)
        add(email, .email)
        add(card, .creditCard, validate: luhnCard)
        add(phone, .phone, validate: { text in
            // Digit runs that pass Luhn are card numbers, already flagged above.
            let digits = text.filter(\.isNumber)
            return !((13...16).contains(digits.count) && luhnCard(text))
        })

        return result
    }

    /// Case- and diacritic-insensitive occurrences of a user search term.
    private static func customRanges(of term: String, in line: String) -> [Range<String.Index>] {
        guard term.count >= 2 else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = line.startIndex
        while cursor < line.endIndex,
              let found = line.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: cursor..<line.endIndex
              )
        {
            ranges.append(found)
            cursor = found.upperBound
        }
        return ranges
    }

    /// True when two normalized rects overlap substantially.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0 else { return false }
        let area = intersection.width * intersection.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return area > 0.4 * smaller
    }

    /// Luhn checksum over 13–16 digit sequences — real card numbers only.
    private static func luhnCard(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...16).contains(digits.count) else { return false }

        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }

    // MARK: - Rendering

    /// Burns the selected redactions into a fresh, image-only PDF and replaces
    /// the document's cached file. The output is a pure raster — no text
    /// objects, no selectable content and minimal document metadata.
    func renderRedactedPDF(
        pages: [UIImage],
        regions: [RedactionBox],
        documentId: String
    ) async throws -> (url: URL, data: Data) {
        let applied = regions.filter(\.isSelected)
        guard !pages.isEmpty, !applied.isEmpty else { throw RedactionError.nothingToRedact }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "ScanVault"]

        let bounds = CGRect(origin: .zero, size: PDFManager.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        let data = renderer.pdfData { context in
            for (index, image) in pages.enumerated() {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)

                let fit = PDFManager.aspectFitRect(for: image.size, in: PDFManager.pageSize)
                image.draw(in: fit)

                let pageRegions = applied.filter { $0.pageIndex == index }
                guard !pageRegions.isEmpty else { continue }

                UIColor.black.setFill()
                for region in pageRegions {
                    context.fill(Self.pageRect(for: region.rect, fit: fit))
                }
            }
        }

        guard !data.isEmpty else { throw RedactionError.renderFailed }
        let url = try await PDFManager.shared.save(data, documentId: documentId)
        return (url, data)
    }

    /// Single-page preview with the selected boxes burned in, used by the
    /// before/after confirmation sheet.
    func renderPreviewImage(page: UIImage, regions: [RedactionBox]) -> UIImage? {
        let size = page.size
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            page.draw(in: CGRect(origin: .zero, size: size))

            let applied = regions.filter(\.isSelected)
            guard !applied.isEmpty else { return }

            UIColor.black.setFill()
            for region in applied {
                var rect = CGRect(
                    x: region.rect.minX * size.width,
                    y: region.rect.minY * size.height,
                    width: region.rect.width * size.width,
                    height: region.rect.height * size.height
                )
                rect = rect.insetBy(dx: -3, dy: -3)
                let clamped = rect.intersection(CGRect(origin: .zero, size: size))
                guard !clamped.isNull, clamped.width > 0 else { continue }
                context.fill(clamped)
            }
        }
    }

    /// Maps a normalized top-left rect into PDF page coordinates, feathered
    /// slightly outward so glyph edges at the box boundary are fully covered.
    private static func pageRect(for normalized: CGRect, fit: CGRect) -> CGRect {
        var rect = CGRect(
            x: fit.minX + normalized.minX * fit.width,
            y: fit.minY + normalized.minY * fit.height,
            width: normalized.width * fit.width,
            height: normalized.height * fit.height
        )
        rect = rect.insetBy(
            dx: -max(fit.width * 0.004, 1),
            dy: -max(fit.height * 0.006, 1)
        )
        let clamped = rect.intersection(CGRect(origin: .zero, size: PDFManager.pageSize))
        return clamped.isNull ? .zero : clamped
    }
}
