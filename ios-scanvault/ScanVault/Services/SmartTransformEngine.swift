//
//  SmartTransformEngine.swift
//  ScanVault
//
//  Transformation coordinator: turns raw transcribed notes into structured
//  outputs (minutes, emails, slide outlines, LinkedIn posts) with Gemini 2.5
//  Flash, streaming tokens back to the UI as they arrive.
//

import Foundation
import OSLog

/// Applies format + tone system prompts to raw notes and streams the result.
actor SmartTransformEngine {
    static let shared = SmartTransformEngine()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "transform")

    /// Transforms `text` into the target format, invoking `onDelta` for every
    /// streamed token chunk. Returns the finished document.
    ///
    /// - Parameters:
    ///   - context: document title, used to ground generated headers.
    @discardableResult
    func transform(
        text: String,
        format: NoteTransformFormat,
        tone: WritingTone,
        context: String,
        onDelta: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { throw AIGatewayError.emptyResponse }

        let body: [String: Any] = [
            "model": AIGatewayClient.model,
            "messages": [
                [
                    "role": "system",
                    "content": Self.systemPrompt(format: format, tone: tone, context: context),
                ],
                ["role": "user", "content": "Raw meeting notes:\n\n\(notes)"],
            ],
            "stream": true,
            "temperature": Self.temperature(for: format),
            "max_tokens": 8192,
        ]

        let result = try await AIGatewayClient.stream(body: body, onDelta: onDelta)
        logger.info(
            "Transform to \(format.rawValue, privacy: .public) finished (\(result.count, privacy: .public) chars)"
        )
        return result
    }

    // MARK: - Prompt assembly

    private static func systemPrompt(
        format: NoteTransformFormat,
        tone: WritingTone,
        context: String
    ) -> String {
        """
        You are SmartTransform, the note-rewriting engine inside ScanVault, a \
        document scanner app. You convert raw, messy handwritten meeting notes \
        into polished, structured business documents.

        \(format.systemPrompt)

        \(tone.directive)

        Grounding rules:
        - The notes belong to the scan "\(context)".
        - Use ONLY facts present in or directly implied by the notes. Never invent numbers, names or dates.
        - Resolve obvious handwriting artifacts and fragments into grammatical prose.
        - Output ONLY the finished document as clean Markdown. No preamble like "Here is", no closing commentary.
        """
    }

    /// Slightly more creative for social copy, tighter for formal minutes.
    private static func temperature(for format: NoteTransformFormat) -> Double {
        switch format {
        case .linkedinPost: 0.85
        case .executiveEmail: 0.5
        case .slideDeck: 0.6
        case .meetingMinutes: 0.3
        }
    }
}
