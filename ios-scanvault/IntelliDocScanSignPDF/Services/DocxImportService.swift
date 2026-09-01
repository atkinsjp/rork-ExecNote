//
//  DocxImportService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

/// Converts Files-picked Word documents (.docx) into paginated Letter-sized
/// page images so they flow through the same review pipeline as scans.
///
/// iOS `NSAttributedString` cannot read DOCX (that importer is macOS-only),
/// so this service unzips the document with ZIPFoundation, parses
/// `word/document.xml` with `XMLParser`, rebuilds the text as an
/// `NSAttributedString` (headings, bold/italic/underline, sizes, alignment,
/// bullets, tabs and line breaks), and lays it out into 612×792pt pages with
/// print-style margins via TextKit.
nonisolated enum DocxImportService {

    /// The Word .docx UTType, for file pickers.
    static let docxType = UTType(filenameExtension: "docx") ?? .data

    /// Safety cap so a pathological document can never loop forever.
    private static let maxPages = 300

    enum DocxImportError: LocalizedError {
        case unreadable
        case missingDocument

        var errorDescription: String? {
            switch self {
            case .unreadable: "The Word document could not be opened."
            case .missingDocument: "The Word document has no readable text layer."
            }
        }
    }

    /// Renders every page of the document. Work is moved off the main actor —
    /// XML parsing plus TextKit layout can take a moment on large files.
    static func pages(for url: URL) async throws -> [UIImage] {
        try await Task.detached(priority: .userInitiated) {
            try renderPages(at: url)
        }.value
    }

    // MARK: - Rendering

    private static func renderPages(at url: URL) throws -> [UIImage] {
        let data = try Data(contentsOf: url)
        let attributed = try attributedText(fromDocxData: data)
        guard attributed.length > 0 else { return [] }
        return paginate(attributed)
    }

    /// Unzips the DOCX container and returns `word/document.xml` payload.
    private static func documentXML(fromDocxData data: Data) throws -> Data {
        let archive = try Archive(data: data, accessMode: .read)
        guard let entry = archive.first(where: { $0.path == "word/document.xml" }) else {
            throw DocxImportError.missingDocument
        }
        var xml = Data()
        _ = try archive.extract(entry, bufferSize: 65_536) { chunk in
            xml.append(chunk)
        }
        return xml
    }

    private static func attributedText(fromDocxData data: Data) throws -> NSAttributedString {
        let xml = try documentXML(fromDocxData: data)
        let delegate = DocxXMLParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse(), !delegate.paragraphs.isEmpty else {
            throw DocxImportError.unreadable
        }
        return attributedString(from: delegate.paragraphs)
    }

    // MARK: - TextKit pagination

    private static func paginate(_ attributed: NSAttributedString) -> [UIImage] {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 54
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2

        var images: [UIImage] = []
        while images.count < maxPages {
            let container = NSTextContainer(size: textRect.size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 else { break }

            let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                context.cgContext.translateBy(x: textRect.minX, y: textRect.minY)
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
            }
            images.append(image)
        }
        return images
    }

    // MARK: - Attributed text building

    private struct HeadingStyle {
        let size: CGFloat
        let isBold: Bool
    }

    /// Maps Word's built-in paragraph styles onto point sizes.
    private static func headingStyle(for name: String?) -> HeadingStyle? {
        switch name?.lowercased() {
        case "title": HeadingStyle(size: 24, isBold: true)
        case "heading1": HeadingStyle(size: 20, isBold: true)
        case "heading2": HeadingStyle(size: 16, isBold: true)
        case "heading3", "heading4": HeadingStyle(size: 14, isBold: true)
        default: nil
        }
    }

    private static func font(bold: Bool, italic: Bool, size: CGFloat) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return UIFont.systemFont(ofSize: size) }
        let base = UIFont.systemFont(ofSize: size).fontDescriptor
        guard let descriptor = base.withSymbolicTraits(traits) else {
            return UIFont.systemFont(ofSize: size)
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func attributedString(from paragraphs: [DocxParagraph]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = font(bold: false, italic: false, size: 11)

        for paragraph in paragraphs {
            let heading = headingStyle(for: paragraph.style)

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 1.5
            style.alignment = paragraph.alignment
            style.paragraphSpacingBefore = heading == nil ? 0 : 12
            style.paragraphSpacing = heading == nil ? 8 : 6

            var base: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .foregroundColor: UIColor.black,
                .paragraphStyle: style,
            ]

            if paragraph.isBulleted {
                result.append(NSAttributedString(string: "•  ", attributes: base))
            }

            for run in paragraph.runs where !run.text.isEmpty {
                let size = run.fontSize ?? heading?.size ?? 11
                base[.font] = font(bold: run.bold || (heading?.isBold ?? false), italic: run.italic, size: size)
                if run.underline {
                    base[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: run.text, attributes: base))
                if run.underline {
                    base.removeValue(forKey: .underlineStyle)
                }
            }

            // The trailing newline both terminates the paragraph and gives
            // empty paragraphs their blank-line height.
            base[.font] = bodyFont
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
        return result
    }
}

// MARK: - WordprocessingML model

private struct DocxRun {
    var text: String = ""
    var bold = false
    var italic = false
    var underline = false
    var fontSize: CGFloat?
}

private struct DocxParagraph {
    var runs: [DocxRun] = []
    var style: String?
    var isBulleted = false
    var alignment: NSTextAlignment = .natural
}

// MARK: - WordprocessingML parser

/// Extracts paragraphs and character formatting from `word/document.xml`.
/// Handles the common formatting subset; unsupported elements (tables render
/// as stacked cell paragraphs, images are skipped) degrade gracefully.
///
/// `nonisolated` — this parser runs entirely off the main actor inside
/// `DocxImportService.pages`, so it opts out of the project's MainActor
/// default.
nonisolated private final class DocxXMLParser: NSObject, XMLParserDelegate {

    private(set) var paragraphs: [DocxParagraph] = []

    private var current = DocxParagraph()
    private var currentRun = DocxRun()
    private var textBuffer = ""
    private var inRunProperties = false
    private var inParagraphProperties = false
    private var isCollectingText = false

    /// OOXML element names carry prefixes ("w:p"); the namespace URI may or
    /// may not be resolved by XMLParser, so normalize both shapes.
    private static func local(_ name: String) -> String {
        name.contains(":") ? String(name.split(separator: ":").last ?? "") : name
    }

    /// `<w:b/>` means true; `<w:b w:val="false"/>` means false.
    private static func flag(_ attributes: [String: String]) -> Bool {
        switch attributes["val"]?.lowercased() {
        case "false", "0", "off": false
        default: true
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Self.local(elementName) {
        case "p":
            current = DocxParagraph()
        case "pPr":
            inParagraphProperties = true
        case "r":
            currentRun = DocxRun()
            textBuffer = ""
        case "rPr":
            inRunProperties = true
        case "t":
            isCollectingText = true
        case "br":
            textBuffer += "\n"
        case "tab":
            textBuffer += "\t"
        case "b":
            if inRunProperties { currentRun.bold = Self.flag(attributeDict) }
        case "i":
            if inRunProperties { currentRun.italic = Self.flag(attributeDict) }
        case "u":
            if inRunProperties { currentRun.underline = attributeDict["val"]?.lowercased() != "none" }
        case "sz":
            if inRunProperties, let halfPoints = Double(attributeDict["val"] ?? "") {
                currentRun.fontSize = CGFloat(halfPoints / 2)
            }
        case "jc":
            if inParagraphProperties {
                switch attributeDict["val"]?.lowercased() {
                case "center": current.alignment = .center
                case "right", "end": current.alignment = .right
                case "both", "justify": current.alignment = .justified
                default: break
                }
            }
        case "pStyle":
            if inParagraphProperties { current.style = attributeDict["val"] }
        case "numPr":
            if inParagraphProperties { current.isBulleted = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingText {
            textBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.local(elementName) {
        case "t":
            isCollectingText = false
        case "rPr":
            inRunProperties = false
        case "pPr":
            inParagraphProperties = false
        case "r":
            if !textBuffer.isEmpty {
                currentRun.text = textBuffer
                current.runs.append(currentRun)
            }
            textBuffer = ""
        case "p":
            paragraphs.append(current)
            current = DocxParagraph()
        default:
            break
        }
    }
}
