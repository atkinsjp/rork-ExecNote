//
//  DocumentSummaryService.swift
//  IntelliDocScanSignPDF
//
//  One-sentence document summaries: sends the on-device OCR text of a scan
//  through the toolkit proxy (Gemini 2.5 Flash) and gets back a single
//  short sentence suitable for the reader's header card.
//

import Foundation
import OSLog

/// Condenses a scanned document's extracted text into one plain sentence.
nonisolated enum DocumentSummaryService {

    private static let logger = Logger(subsystem: "app.rork.scanvault", category: "summary")

    /// Head-truncation budget for the OCR excerpt — front pages carry titles,
    /// senders and totals, which is what the sentence should be built from.
    private static let maxExcerptLength = 9_000

    private static let systemPrompt = """
    You condense scanned documents into exactly ONE short sentence of at most \
    22 words. Plain prose only — no quotes, no Markdown, no preamble, no lists. \
    Name the document kind and its key facts (party, date, amount) when present. \
    End with a period. If the text is too fragmentary to describe, reply with \
    just "SCAN_UNAVAILABLE".
    """

    /// Produces the one-sentence summary for a document.
    ///
    /// - Throws: AI gateway errors, or `emptyResponse` when there is no usable
    ///   OCR text (and thus nothing to summarize).
    static func summarize(
        title: String,
        docType: String?,
        ocrText: String
    ) async throws -> String {
        let excerpt = condense(ocrText)
        guard !excerpt.isEmpty else { throw AIGatewayError.emptyResponse }

        var userContent = "Document title: \(title)\n"
        if let docType {
            userContent += "Document type: \(docType)\n"
        }
        userContent += "\nExtracted text:\n\(excerpt)"

        let body: [String: Any] = [
            "model": AIGatewayClient.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "temperature": 0.2,
            "max_tokens": 90,
        ]

        let reply = try await AIGatewayClient.complete(body: body)
        let cleaned = firstSentence(from: reply)

        guard !cleaned.isEmpty, cleaned != "SCAN_UNAVAILABLE" else {
            throw AIGatewayError.emptyResponse
        }
        logger.info("Summary generated (\(cleaned.count, privacy: .public) chars)")
        return cleaned
    }

    // MARK: - Text shaping

    /// Normalizes OCR artifacts (page separators, ragged whitespace) into one
    /// flowing block, capped at `maxExcerptLength`.
    nonisolated static func condense(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n\u{2029}", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maxExcerptLength else { return flattened }
        return String(flattened.prefix(maxExcerptLength))
    }

    /// Keeps only the model's first real sentence and strips stray quotes or
    /// scaffolding that could sneak into the header.
    nonisolated static func firstSentence(from reply: String) -> String {
        var cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned
            .replacingOccurrences(of: "^```.*\\n?", with: "", options: [.regularExpression])
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleaned.contains(where: { ".!?".contains($0) }) {
            return cleaned.count <= 220 ? cleaned : String(cleaned.prefix(220)) + "…"
        }
        guard let match = cleaned.firstMatch(of: /.+?[.!?](?:\s|$)/) else {
            return String(cleaned.prefix(220))
        }
        return String(match.0)
    }
}
