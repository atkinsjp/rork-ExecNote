//
//  NoteTransform.swift
//  ScanVault
//
//  Models for the handwriting Notes Studio: target output formats, writing
//  tones, and the persisted record of each AI-generated variation.
//

import Foundation

// MARK: - Output formats

/// Structured destinations the raw meeting notes can be transformed into.
nonisolated enum NoteTransformFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Formal minutes with header, decisions, action-item table and discussion.
    case meetingMinutes
    /// Concise executive follow-up email with call-to-action blocks.
    case executiveEmail
    /// 5–7 slide outline with takeaways and speaker notes.
    case slideDeck
    /// LinkedIn thought-leadership post with hook and hashtags.

    case linkedinPost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingMinutes: "Official Meeting Minutes"
        case .executiveEmail: "Executive Follow-Up Email"
        case .slideDeck: "Presentation Slide Outline"
        case .linkedinPost: "LinkedIn Industry Post"
        }
    }

    var subtitle: String {
        switch self {
        case .meetingMinutes: "Header, decisions, action items & discussion"
        case .executiveEmail: "Bulleted summary with a clear call to action"
        case .slideDeck: "5–7 slides, takeaways & speaker notes"
        case .linkedinPost: "Hook, insights, line breaks & hashtags"
        }
    }

    var symbolName: String {
        switch self {
        case .meetingMinutes: "doc.text.fill"
        case .executiveEmail: "envelope.fill"
        case .slideDeck: "rectangle.stack.fill"
        case .linkedinPost: "bubble.left.and.text.bubble.right.fill"
        }
    }

    /// Default file-name suffix for exports of this format.
    var fileSuffix: String {
        switch self {
        case .meetingMinutes: "Meeting Minutes"
        case .executiveEmail: "Follow-Up Email"
        case .slideDeck: "Slide Outline"
        case .linkedinPost: "LinkedIn Post"
        }
    }

    /// Structured system prompt describing the target document shape.
    var systemPrompt: String {
        switch self {
        case .meetingMinutes:
            """
            Transform the notes into FORMAL MEETING MINUTES in Markdown with exactly these sections:
            1. A header block listing Date, Attendees, and Agenda (infer from the notes; write "Not recorded" only when truly absent).
            2. "## Key Decisions Made" — every decision as a bullet.
            3. "## Action Items" — a Markdown table with the columns Task, Assignee, Due Date. Use "Unassigned" / "TBD" when the notes do not say.
            4. "## Discussion Notes" — the substantive conversation, organized by topic.
            """
        case .executiveEmail:
            """
            Transform the notes into an EXECUTIVE FOLLOW-UP EMAIL in Markdown:
            - Start with a one-line subject header as a level-2 heading, prefixed with "Subject:".
            - Open with a 1–2 sentence framing paragraph.
            - "## Executive Summary" — 3–5 tight bullets covering outcomes, numbers and risks.
            - "## Action Items" — bullets naming owner and date.
            - Finish with a distinct "## Call to Action" block: what you need from the reader, by when.
            """
        case .slideDeck:
            """
            Transform the notes into a PRESENTATION SLIDE OUTLINE in Markdown:
            - Produce 5–7 slides (fewer only if the notes are very thin).
            - Each slide is a level-2 heading "## Slide N — Title".
            - Under each slide: exactly 3 key takeaways as bullets, then a "**Speaker Notes:**" paragraph with 2–3 sentences of narration.
            - Open with a level-1 title for the whole deck.
            """
        case .linkedinPost:
            """
            Transform the notes into a LINKEDIN THOUGHT-LEADERSHIP POST:
            - Open with a scroll-stopping hook of one short line.
            - Use short paragraphs separated by blank lines, with tasteful emojis on key lines.
            - Break the core insight into 3–5 clearly separated points.
            - End with one engaging question to the reader.
            - Close with a line of 4–6 relevant industry hashtags.
            - Output plain text with line breaks (not headings or tables), ready to paste into LinkedIn.
            """
        }
    }
}

// MARK: - Tones

/// Voice applied on top of the format's structure prompt.
nonisolated enum WritingTone: String, CaseIterable, Codable, Sendable, Identifiable {
    case professional
    case casual
    case direct
    case persuasive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .professional: "Professional"
        case .casual: "Casual"
        case .direct: "Direct"
        case .persuasive: "Persuasive"
        }
    }

    var symbolName: String {
        switch self {
        case .professional: "briefcase.fill"
        case .casual: "hand.thumbsup.fill"
        case .direct: "arrow.forward.square.fill"
        case .persuasive: "flame.fill"
        }
    }

    /// Sentence-level instruction appended to the system prompt.
    var directive: String {
        switch self {
        case .professional:
            "Tone: polished, formal business language. Complete sentences, no slang."
        case .casual:
            "Tone: warm, conversational and human. Contractions welcome, never stiff."
        case .direct:
            "Tone: blunt and efficient. Cut filler, lead with the point, short sentences."
        case .persuasive:
            "Tone: compelling and momentum-building. Emphasize benefits and urgency without hype."
        }
    }
}

// MARK: - Persisted variation

/// One AI-generated variation of a document's notes, stored with the document
/// metadata so it survives restarts and syncs through Firestore.
nonisolated struct NoteTransformRecord: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let format: NoteTransformFormat
    let tone: WritingTone
    var content: String
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        format: NoteTransformFormat,
        tone: WritingTone,
        content: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.format = format
        self.tone = tone
        self.content = content
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, format, tone, content, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        format = try container.decodeIfPresent(NoteTransformFormat.self, forKey: .format) ?? .meetingMinutes
        tone = try container.decodeIfPresent(WritingTone.self, forKey: .tone) ?? .professional
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

// MARK: - Firestore value mapping

nonisolated extension NoteTransformRecord {
    /// Firestore map representation, embedded in the document's metadata.
    var firestoreFields: [String: Any] {
        [
            "id": ["stringValue": id],
            "format": ["stringValue": format.rawValue],
            "tone": ["stringValue": tone.rawValue],
            "content": ["stringValue": content],
            "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: createdAt)],
        ]
    }

    init?(firestore fields: [String: Any]) {
        func string(_ key: String) -> String? {
            (fields[key] as? [String: Any])?["stringValue"] as? String
        }
        guard let id = string("id"),
              let content = string("content"),
              let rawFormat = string("format"),
              let format = NoteTransformFormat(rawValue: rawFormat)
        else { return nil }

        let rawTone = string("tone").flatMap(WritingTone.init(rawValue:)) ?? .professional
        var createdAt = Date.now
        if let stamp = string("createdAt"),
           let date = ISO8601DateFormatter().date(from: stamp) {
            createdAt = date
        }

        self.init(
            id: id,
            format: format,
            tone: rawTone,
            content: content,
            createdAt: createdAt
        )
    }
}
