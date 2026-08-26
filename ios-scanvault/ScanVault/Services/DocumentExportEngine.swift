//
//  DocumentExportEngine.swift
//  ScanVault
//
//  Multi-format generation for the Notes Studio: editable DOCX files built
//  from raw OOXML packaging, and branded PDFs with typography, tables and
//  page numbering rendered through UIGraphicsPDFRenderer.
//

import Foundation
import PDFKit
import SwiftUI
import UIKit

// MARK: - Markdown-lite parsing

/// One styled inline text run (`**bold**` or plain).
nonisolated struct InlineRun: Equatable, Sendable {
    let text: String
    let isBold: Bool
}

/// A single layout block extracted from the AI's Markdown output.
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, runs: [InlineRun])
    case paragraph(runs: [InlineRun])
    case bullet(runs: [InlineRun])
    case table(header: [String], rows: [[String]])
}

/// Line-based Markdown parser covering everything the transform prompts emit:
/// headings, bullets, pipe tables, bold runs and plain paragraphs.
nonisolated enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var tableLines: [String] = []

        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let table = parseTable(tableLines) { blocks.append(table) }
            tableLines = []
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Table row accumulation.
            if trimmed.hasPrefix("|") {
                tableLines.append(trimmed)
                continue
            }
            flushTable()

            if trimmed.isEmpty { continue }

            // Heading.
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                continue
            }

            // Bullet.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append(.bullet(runs: parseRuns(text)))
                continue
            }

            blocks.append(.paragraph(runs: parseRuns(trimmed)))
        }
        flushTable()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard let hashIndex = line.firstIndex(where: { $0 != "#" }) else { return nil }
        let level = line.distance(from: line.startIndex, to: hashIndex)
        guard (1...4).contains(level) else { return nil }
        let text = String(line[line.index(line.startIndex, offsetBy: level)...])
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, runs: parseRuns(text))
    }

    private static func parseTable(_ lines: [String]) -> MarkdownBlock? {
        let cellsPerLine = lines.compactMap { line -> [String]? in
            var inner = line
            if inner.hasPrefix("|") { inner = String(inner.dropFirst()) }
            if inner.hasSuffix("|") { inner = String(inner.dropLast()) }
            let cells = inner.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return cells.isEmpty ? nil : cells
        }
        guard !cellsPerLine.isEmpty else { return nil }

        func isSeparator(_ cells: [String]) -> Bool {
            !cells.isEmpty && cells.allSatisfy { cell in
                let stripped = cell
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
            }
        }

        if let first = cellsPerLine.first, isSeparator(first) {
            // Markdown table with no header row.
            return .table(header: [], rows: Array(cellsPerLine.dropFirst()))
        }

        var header: [String] = []
        var rows: [[String]] = []
        for (index, cells) in cellsPerLine.enumerated() {
            if index == 0 {
                header = cells
            } else if isSeparator(cells) {
                continue
            } else {
                rows.append(cells)
            }
        }
        return .table(header: header, rows: rows)
    }

    /// Splits text on `**…**` markers into bold/plain runs.
    static func parseRuns(_ text: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var isBold = false
        var current = ""

        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if character == "*" {
                if let lookahead = iterator.next() {
                    if lookahead == "*" {
                        if !current.isEmpty {
                            runs.append(InlineRun(text: current, isBold: isBold))
                            current = ""
                        }
                        isBold.toggle()
                    } else {
                        current.append(character)
                        pending = lookahead
                    }
                } else {
                    current.append(character)
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            runs.append(InlineRun(text: current, isBold: isBold))
        }
        return runs.isEmpty ? [InlineRun(text: text, isBold: false)] : runs
    }
}

// MARK: - Export engine

/// Builds shareable DOCX and PDF artifacts from AI-generated note variations.
@MainActor
final class DocumentExportEngine {
    static let shared = DocumentExportEngine()

    nonisolated enum Format: String, CaseIterable {
        case docx
        case pdf
        case pptx

        var fileExtension: String { rawValue }
    }

    nonisolated enum ExportError: LocalizedError {
        case emptyContent
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyContent: "There is nothing to export yet."
            case .writeFailed(let reason): "The export failed: \(reason)"
            }
        }
    }

    // MARK: - Public API

    /// Renders the variation as an editable Word document.
    func exportDOCX(record: NoteTransformRecord, title: String) throws -> URL {
        let blocks = MarkdownParser.parse(record.content)
        guard !blocks.isEmpty else { throw ExportError.emptyContent }

        let xml = Self.DOCXBuilder.documentXML(blocks: blocks)
        let url = try exportURL(title: title, record: record, extension: "docx")

        try ZipArchive.write(
            entries: [
                (name: "[Content_Types].xml", data: Data(Self.DOCXBuilder.contentTypes.utf8)),
                (name: "_rels/.rels", data: Data(Self.DOCXBuilder.rels.utf8)),
                (name: "word/document.xml", data: Data(xml.utf8)),
            ],
            to: url
        )
        return url
    }

    /// Renders the variation as a branded, paginated PDF.
    func exportPDF(record: NoteTransformRecord, title: String) throws -> URL {
        let blocks = MarkdownParser.parse(record.content)
        guard !blocks.isEmpty else { throw ExportError.emptyContent }

        let url = try exportURL(title: title, record: record, extension: "pdf")
        let data = PDFRenderer(record: record, title: title).render(blocks: blocks)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Packages a slide-deck variation as a PowerPoint file (16:9) with amber
    /// title bars, bulleted takeaways and speaker notes.
    func exportPPTX(record: NoteTransformRecord, title: String) throws -> URL {
        let blocks = MarkdownParser.parse(record.content)
        guard !blocks.isEmpty else { throw ExportError.emptyContent }

        let slides = Self.PPTXBuilder.slides(from: blocks, fallbackTitle: title)
        let url = try exportURL(title: title, record: record, extension: "pptx")
        try ZipArchive.write(entries: Self.PPTXBuilder.package(slides: slides), to: url)
        return url
    }

    private func exportURL(title: String, record: NoteTransformRecord, extension ext: String) throws -> URL {
        let safe = sanitizeFileName(title)
        let name = "\(safe) — \(record.format.fileSuffix)"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(name).\(ext)")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func sanitizeFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "ScanVault Notes" : cleaned
    }
}

// MARK: - DOCX builder (OOXML packaging)

private extension DocumentExportEngine {
    enum DOCXBuilder {
        static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        </Types>
        """

        static let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """

        static func documentXML(blocks: [MarkdownBlock]) -> String {
            var body = ""
            for block in blocks {
                switch block {
                case .heading(let level, let runs):
                    body += headingParagraph(level: level, runs: runs)
                case .paragraph(let runs):
                    body += bodyParagraph(runs: runs)
                case .bullet(let runs):
                    body += bulletParagraph(runs: runs)
                case .table(let header, let rows):
                    body += tableXML(header: header, rows: rows)
                }
            }
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
            <w:body>\(body)\
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>\
            </w:body></w:document>
            """
        }

        // MARK: XML pieces

        static func escaped(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }

        static func runXML(_ run: InlineRun, bold: Bool = false, size: Int? = nil) -> String {
            var props = ""
            if run.isBold || bold { props += "<w:b/>" }
            if let size { props += "<w:sz w:val=\"\(size)\"/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escaped(run.text))</w:t></w:r>"
        }

        static func runsXML(_ runs: [InlineRun], bold: Bool = false, size: Int? = nil) -> String {
            runs.map { runXML($0, bold: bold, size: size) }.joined()
        }

        static func headingParagraph(level: Int, runs: [InlineRun]) -> String {
            let (size, spacing): (Int, String) = switch level {
            case 1: (34, "<w:spacing w:before=\"360\" w:after=\"160\"/>")
            case 2: (28, "<w:spacing w:before=\"300\" w:after=\"120\"/>")
            default: (24, "<w:spacing w:before=\"240\" w:after=\"100\"/>")
            }
            return "<w:p><w:pPr>\(spacing)</w:pPr>\(runsXML(runs, bold: true, size: size))</w:p>"
        }

        static func bodyParagraph(runs: [InlineRun]) -> String {
            "<w:p><w:pPr><w:spacing w:after=\"140\"/></w:pPr>\(runsXML(runs))</w:p>"
        }

        static func bulletParagraph(runs: [InlineRun]) -> String {
            let prefixed = [InlineRun(text: "•  ", isBold: false)] + runs
            return "<w:p><w:pPr><w:spacing w:after=\"90\"/>" +
                "<w:ind w:left=\"360\" w:hanging=\"240\"/></w:pPr>\(runsXML(prefixed))</w:p>"
        }

        static func tableXML(header: [String], rows: [[String]]) -> String {
            let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
            guard columnCount > 0 else { return "" }

            let columnWidth = 9360 / columnCount
            let grid = (0..<columnCount)
                .map { _ in "<w:gridCol w:w=\"\(columnWidth)\"/>" }
                .joined()
            let borders = """
            <w:tblBorders>\
            <w:top w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            <w:left w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            <w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            <w:right w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            <w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            <w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"2A2E38\"/>\
            </w:tblBorders>
            """

            func cell(_ text: String, isHeader: Bool) -> String {
                let shading = isHeader ? "<w:tcPr><w:shd w:fill=\"F4EBD8\"/></w:tcPr>" : ""
                let run = runXML(InlineRun(text: text, isBold: isHeader))
                return "<w:tc>\(shading)<w:p><w:pPr><w:spacing w:after=\"40\"/></w:pPr>\(run)</w:p></w:tc>"
            }

            func row(_ cells: [String], isHeader: Bool) -> String {
                let padded = cells + Array(repeating: "", count: max(0, columnCount - cells.count))
                return "<w:tr>" + padded.prefix(columnCount).map { cell($0, isHeader: isHeader) }.joined() + "</w:tr>"
            }

            var allRows = ""
            if !header.isEmpty { allRows += row(header, isHeader: true) }
            for tableRow in rows { allRows += row(tableRow, isHeader: false) }

            return """
            <w:tbl><w:tblPr>\(borders)<w:tblW w:w="9360" w:type="dxa"/></w:tblPr>\
            <w:tblGrid>\(grid)</w:tblGrid>\(allRows)</w:tbl>\
            <w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>
            """
        }
    }
}

// MARK: - Branded PDF renderer

/// Renders parsed blocks into a letter-size PDF: serif headings, amber accents,
/// bordered tables, hairline footers with page numbers.
@MainActor
private struct PDFRenderer {
    let record: NoteTransformRecord
    let title: String

    // Page geometry (US Letter, points).
    private let pageWidth: CGFloat = 612
    private let pageHeight: CGFloat = 792
    private let margin: CGFloat = 56
    private let footerHeight: CGFloat = 46

    private var contentWidth: CGFloat { pageWidth - margin * 2 }

    private var ink: UIColor { UIColor(Theme.ink) }
    private var amber: UIColor { UIColor(Theme.amber) }
    private var hairline: UIColor { UIColor(Theme.hairline) }
    private var tertiary: UIColor { UIColor(Theme.textTertiary) }

    func render(blocks: [MarkdownBlock]) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(title) — \(record.format.fileSuffix)",
            kCGPDFContextCreator as String: "ScanVault",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight),
            format: format
        )

        let pages = paginate(blocks)
        return renderer.pdfData { context in
            for (index, pageBlocks) in pages.enumerated() {
                context.beginPage()
                var y = drawHeader(isFirstPage: index == 0)
                for block in pageBlocks {
                    y = draw(block, at: y)
                }
                drawFooter(page: index + 1, total: pages.count)
            }
        }
    }

    // MARK: Typography

    private func headingFont(level: Int) -> UIFont {
        let size: CGFloat = switch level {
        case 1: 21
        case 2: 15.5
        default: 13
        }
        return .systemFont(ofSize: size, weight: .bold)
    }

    private func attributed(_ runs: [InlineRun], font: UIFont, color: UIColor = .darkText) -> NSAttributedString {
        let string = NSMutableAttributedString()
        for run in runs {
            let weight: UIFont.Weight = run.isBold ? .bold : .regular
            string.append(
                NSAttributedString(
                    string: run.text,
                    attributes: [
                        .font: font.withWeightFallback(weight),
                        .foregroundColor: color,
                        .kern: font.pointSize > 14 ? -0.2 : 0,
                    ]
                )
            )
        }
        return string
    }

    // MARK: Pagination

    private func paginate(_ blocks: [MarkdownBlock]) -> [[MarkdownBlock]] {
        var pages: [[MarkdownBlock]] = [[]]
        var y = headerHeight(isFirstPage: true)

        func push(_ block: MarkdownBlock) {
            pages[pages.count - 1].append(block)
        }

        func newPage() {
            pages.append([])
            y = headerHeight(isFirstPage: false)
        }

        for block in blocks {
            let height = measuredHeight(of: block)

            if y + height > pageHeight - footerHeight {
                if case .table(let header, let rows) = block {
                    // Split long tables row by row.
                    for row in rows {
                        let piece = MarkdownBlock.table(header: header, rows: [row])
                        if y + measuredHeight(of: piece) > pageHeight - footerHeight {
                            newPage()
                            if header.isEmpty {
                                push(piece)
                                y += measuredHeight(of: piece)
                                continue
                            }
                        }
                        push(piece)
                        y += measuredHeight(of: piece)
                    }
                    continue
                }
                newPage()
            }

            push(block)
            y += height
        }
        return pages.filter { !$0.isEmpty }
    }

    private func measuredHeight(of block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading(let level, let runs):
            return textHeight(attributed(runs, font: headingFont(level: level)), width: contentWidth) + 14
        case .paragraph(let runs):
            return textHeight(attributed(runs, font: .systemFont(ofSize: 10.5)), width: contentWidth) + 9
        case .bullet(let runs):
            return textHeight(attributed(runs, font: .systemFont(ofSize: 10.5)), width: contentWidth - 16) + 6
        case .table(let header, let rows):
            let cells = header.isEmpty ? (rows.first ?? []) : header
            let columnCount = max(cells.count, 1)
            let columnWidth = (contentWidth - 20) / CGFloat(columnCount)
            var height: CGFloat = 0
            if !header.isEmpty {
                height += rowHeight(header, columnWidth: columnWidth, bold: true)
            }
            for row in rows {
                height += rowHeight(row, columnWidth: columnWidth, bold: false)
            }
            return height + 8
        }
    }

    private func rowHeight(_ cells: [String], columnWidth: CGFloat, bold: Bool) -> CGFloat {
        let font: UIFont = bold ? .systemFont(ofSize: 9.5, weight: .semibold) : .systemFont(ofSize: 9.5)
        var tallest: CGFloat = 0
        for cell in cells {
            let text = NSAttributedString(
                string: cell,
                attributes: [.font: font, .foregroundColor: UIColor.darkText]
            )
            tallest = max(tallest, textHeight(text, width: columnWidth - 10))
        }
        return max(20, tallest + 10)
    }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(
            text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )
    }

    // MARK: Drawing

    private func headerHeight(isFirstPage: Bool) -> CGFloat {
        isFirstPage ? 118 : margin + 8
    }

    private func drawHeader(isFirstPage: Bool) -> CGFloat {
        guard isFirstPage else { return headerHeight(isFirstPage: false) }

        let eyebrow = "SCANVAULT · NOTES STUDIO"
        eyebrow.draw(
            at: CGPoint(x: margin, y: margin - 8),
            withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: amber,
                .kern: 1.6,
            ]
        )

        let titleString = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold, width: .compressed),
                .foregroundColor: ink,
            ]
        )
        titleString.draw(
            with: CGRect(x: margin, y: margin + 10, width: contentWidth, height: 30),
            options: [.usesLineFragmentOrigin],
            context: nil
        )

        let meta = [
            record.format.title,
            record.tone.label + " tone",
            record.createdAt.formatted(date: .abbreviated, time: .omitted),
        ].joined(separator: "  ·  ")
        meta.draw(
            at: CGPoint(x: margin, y: margin + 46),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: tertiary,
            ]
        )

        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: margin + 66))
        rule.addLine(to: CGPoint(x: margin + contentWidth, y: margin + 66))
        rule.lineWidth = 1.4
        amber.setStroke()
        rule.stroke()

        return margin + 80
    }

    private func draw(_ block: MarkdownBlock, at y: CGFloat) -> CGFloat {
        switch block {
        case .heading(let level, let runs):
            let text = attributed(runs, font: headingFont(level: level), color: ink)
            text.draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            return y + measuredHeight(of: block)

        case .paragraph(let runs):
            let text = attributed(runs, font: .systemFont(ofSize: 10.5), color: ink)
            text.draw(
                with: CGRect(x: margin, y: y, width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            return y + measuredHeight(of: block)

        case .bullet(let runs):
            "•".draw(
                at: CGPoint(x: margin, y: y + 2),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: amber,
                ]
            )
            let text = attributed(runs, font: .systemFont(ofSize: 10.5), color: ink)
            text.draw(
                with: CGRect(x: margin + 16, y: y, width: contentWidth - 16, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
            return y + measuredHeight(of: block)

        case .table(let header, let rows):
            var cursor = y
            let columnCount = max(max(header.count, rows.map(\.count).max() ?? 0), 1)
            let tableWidth = contentWidth - 20
            let columnWidth = tableWidth / CGFloat(columnCount)

            if !header.isEmpty {
                cursor = drawRow(header, at: cursor, columnWidth: columnWidth, columnCount: columnCount, isHeader: true)
            }
            for row in rows {
                cursor = drawRow(row, at: cursor, columnWidth: columnWidth, columnCount: columnCount, isHeader: false)
            }
            return cursor + 8
        }
    }

    private func drawRow(
        _ cells: [String],
        at y: CGFloat,
        columnWidth: CGFloat,
        columnCount: Int,
        isHeader: Bool
    ) -> CGFloat {
        let tableX = margin + 10
        let height = rowHeight(cells, columnWidth: columnWidth, bold: isHeader)

        // Row background for the header + cell borders.
        if isHeader {
            let background = UIBezierPath(
                rect: CGRect(x: tableX, y: y, width: columnWidth * CGFloat(columnCount), height: height)
            )
            UIColor(Theme.amber).withAlphaComponent(0.12).setFill()
            background.fill()
        }
        let borders = UIBezierPath()
        borders.move(to: CGPoint(x: tableX, y: y))
        borders.addLine(to: CGPoint(x: tableX + columnWidth * CGFloat(columnCount), y: y))
        borders.move(to: CGPoint(x: tableX, y: y + height))
        borders.addLine(to: CGPoint(x: tableX + columnWidth * CGFloat(columnCount), y: y + height))
        for index in 0...columnCount {
            let x = tableX + columnWidth * CGFloat(index)
            borders.move(to: CGPoint(x: x, y: y))
            borders.addLine(to: CGPoint(x: x, y: y + height))
        }
        borders.lineWidth = 0.7
        hairline.setStroke()
        borders.stroke()

        let font: UIFont = isHeader
            ? .systemFont(ofSize: 9.5, weight: .semibold)
            : .systemFont(ofSize: 9.5)
        for (index, cell) in cells.enumerated() where index < columnCount {
            let text = NSAttributedString(
                string: cell,
                attributes: [.font: font, .foregroundColor: UIColor.darkText]
            )
            text.draw(
                with: CGRect(
                    x: tableX + columnWidth * CGFloat(index) + 5,
                    y: y + 5,
                    width: columnWidth - 10,
                    height: height - 10
                ),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }
        return y + height
    }

    private func drawFooter(page: Int, total: Int) {
        let baseline = pageHeight - 30

        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: baseline - 12))
        rule.addLine(to: CGPoint(x: margin + contentWidth, y: baseline - 12))
        rule.lineWidth = 0.6
        hairline.setStroke()
        rule.stroke()

        "ScanVault".draw(
            at: CGPoint(x: margin, y: baseline - 4),
            withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: tertiary,
                .kern: 1.2,
            ]
        )
        let label = "Page \(page) of \(total)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 7.5, weight: .medium),
            .foregroundColor: tertiary,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: margin + contentWidth - size.width, y: baseline - 4),
            withAttributes: attributes
        )
    }
}

// MARK: - PPTX builder (OOXML presentation packaging)

private extension DocumentExportEngine {
    /// A single slide grouped out of the parsed Markdown: title, body lines
    /// and any trailing speaker notes.
    struct SlideModel {
        var title: String
        var lines: [[InlineRun]] = []
        var notes: [[InlineRun]] = []
    }

    /// Assembles a minimal, spec-valid PowerPoint package: one slide master,
    /// one blank layout, a theme part and one slide per Markdown section.
    enum PPTXBuilder {
        // 16:9 slide canvas in EMU (12192000 x 6858000).
        private static let namespaces = """
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        """

        /// `nvGrpSpPr` + `grpSpPr` preamble shared by every shape tree.
        private static let spTreeInner = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

        private static var emptySpTree: String { "<p:spTree>\(spTreeInner)</p:spTree>" }

        // MARK: Slide grouping

        static func slides(from blocks: [MarkdownBlock], fallbackTitle: String) -> [SlideModel] {
            var result: [SlideModel] = []
            var current = SlideModel(title: fallbackTitle)
            var inNotes = false

            func flush() {
                guard !current.lines.isEmpty || !current.notes.isEmpty else { return }
                result.append(contentsOf: splitIfCrowded(current))
            }

            for block in blocks {
                switch block {
                case .heading(let level, let runs):
                    if level <= 2 {
                        flush()
                        let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                        current = SlideModel(title: plain.isEmpty ? fallbackTitle : plain)
                        inNotes = false
                    } else {
                        appendLine(runs.map { InlineRun(text: $0.text, isBold: true) }, to: &current, inNotes: &inNotes)
                    }
                case .paragraph(let runs):
                    appendLine(runs, to: &current, inNotes: &inNotes)
                case .bullet(let runs):
                    appendLine(runs, to: &current, inNotes: &inNotes)
                case .table(let header, let rows):
                    if !header.isEmpty {
                        appendLine([InlineRun(text: header.joined(separator: "  —  "), isBold: true)],
                                   to: &current, inNotes: &inNotes)
                    }
                    for row in rows {
                        appendLine([InlineRun(text: row.joined(separator: "  —  "), isBold: false)],
                                   to: &current, inNotes: &inNotes)
                    }
                }
            }
            flush()
            return result.isEmpty ? [SlideModel(title: fallbackTitle)] : result
        }

        private static func appendLine(_ runs: [InlineRun], to slide: inout SlideModel, inNotes: inout Bool) {
            let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { return }
            if plain.lowercased().hasPrefix("speaker notes") {
                inNotes = true
                let remainder = plain.dropFirst("speaker notes".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                if !remainder.isEmpty {
                    slide.notes.append([InlineRun(text: remainder, isBold: false)])
                }
                return
            }
            if inNotes {
                slide.notes.append(runs)
            } else {
                slide.lines.append(runs)
            }
        }

        /// PowerPoint slides die above ~9 bullets; spill into "(cont.)" slides.
        private static func splitIfCrowded(_ slide: SlideModel) -> [SlideModel] {
            let maxLines = 8
            guard slide.lines.count > maxLines else { return [slide] }
            var output: [SlideModel] = []
            var remaining = slide
            var chunk = 0
            while !remaining.lines.isEmpty {
                let slice = Array(remaining.lines.prefix(maxLines))
                remaining.lines.removeFirst(min(maxLines, remaining.lines.count))
                chunk += 1
                var piece = SlideModel(
                    title: chunk == 1 ? slide.title : "\(slide.title) (cont.)",
                    lines: slice
                )
                if remaining.lines.isEmpty { piece.notes = slide.notes }
                output.append(piece)
            }
            return output
        }

        // MARK: Package assembly

        static func package(slides: [SlideModel]) -> [(name: String, data: Data)] {
            var entries: [(name: String, data: Data)] = []

            let slideOverrides = slides.indices.map { index in
                "<Override PartName=\"/ppt/slides/slide\(index + 1).xml\" " +
                "ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            }.joined()

            entries.append((name: "[Content_Types].xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
            \(slideOverrides)\
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
            </Types>
            """.utf8)))

            entries.append((name: "_rels/.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """.utf8)))

            // Slide list in presentation.xml + its relationships.
            let slideIds = slides.indices.map { index in
                "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 2)\"/>"
            }.joined()
            let themeId = "rId\(slides.count + 2)"

            entries.append((name: "ppt/presentation.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation \(namespaces)>\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst>\(slideIds)</p:sldIdLst>\
            <p:sldSz cx="12192000" cy="6858000"/>\
            <p:notesSz cx="6858000" cy="9144000"/>
            </p:presentation>
            """.utf8)))

            let slideRelationships = slides.indices.map { index in
                "<Relationship Id=\"rId\(index + 2)\" " +
                "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" " +
                "Target=\"slides/slide\(index + 1).xml\"/>"
            }.joined()

            entries.append((name: "ppt/_rels/presentation.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
            \(slideRelationships)\
            <Relationship Id="\(themeId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
            </Relationships>
            """.utf8)))

            entries.append((name: "ppt/slideMasters/slideMaster1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldMaster \(namespaces)>\
            <p:cSld>\(emptySpTree)</p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
            </p:sldMaster>
            """.utf8)))

            entries.append((name: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
            </Relationships>
            """.utf8)))

            entries.append((name: "ppt/slideLayouts/slideLayout1.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldLayout \(namespaces) type="blank" preserve="1">\
            <p:cSld name="Blank">\(emptySpTree)</p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sldLayout>
            """.utf8)))

            entries.append((name: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
            </Relationships>
            """.utf8)))

            entries.append((name: "ppt/theme/theme1.xml", data: Data(themeXML.utf8)))

            for (index, slide) in slides.enumerated() {
                entries.append((name: "ppt/slides/slide\(index + 1).xml", data: Data(slideXML(slide).utf8)))
                entries.append((
                    name: "ppt/slides/_rels/slide\(index + 1).xml.rels",
                    data: Data("""
                    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
                    </Relationships>
                    """.utf8)
                ))
            }
            return entries
        }

        // MARK: Slide XML

        private static func slideXML(_ slide: SlideModel) -> String {
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(namespaces)>\
            <p:cSld><p:spTree>\(spTreeInner)\(shapes(slide))</p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sld>
            """
        }

        private static func shapes(_ slide: SlideModel) -> String {
            accentBar + titleShape(slide.title) + bodyShape(slide.lines)
                + (slide.notes.isEmpty ? "" : notesShape(slide.notes))
        }

        private static let accentBar = """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="AccentBar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="548640" y="760000"/><a:ext cx="104775" cy="960000"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        <a:solidFill><a:srgbClr val="E8A33D"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>
        """

        private static func titleShape(_ title: String) -> String {
            """
            <p:sp><p:nvSpPr><p:cNvPr id="10" name="SlideTitle"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="967740" y="700000"/><a:ext cx="10287000" cy="1020000"/></a:xfrm>
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
            <p:txBody><a:bodyPr wrap="square" anchor="b" lIns="0" tIns="0" rIns="0" bIns="0">
            <a:normAutofit fontScale="92500" lnSpcReduction="10000"/></a:bodyPr><a:lstStyle/>
            <a:p><a:pPr algn="l"/>\(runsXML([InlineRun(text: title, isBold: true)], size: 3200, color: "23272F"))</a:p>
            </p:txBody></p:sp>
            """
        }

        private static func bodyShape(_ lines: [[InlineRun]]) -> String {
            guard !lines.isEmpty else { return "" }
            let paragraphs = lines.map { line in
                """
                <a:p><a:pPr marL="285750" indent="-285750">
                <a:lnSpc><a:spcPct val="118000"/></a:lnSpc>
                <a:spcBef><a:spcPts val="800"/></a:spcBef>
                <a:buClr><a:srgbClr val="E8A33D"/></a:buClr>
                <a:buFont typeface="Arial" pitchFamily="34" charset="0"/><a:buChar char="•"/></a:pPr>
                \(runsXML(line, size: 1600, color: "3E4450"))</a:p>
                """
            }.joined()
            return """
            <p:sp><p:nvSpPr><p:cNvPr id="20" name="Takeaways"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="967740" y="1950000"/><a:ext cx="10287000" cy="3700000"/></a:xfrm>
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
            <p:txBody><a:bodyPr wrap="square" anchor="t"><a:normAutofit/></a:bodyPr><a:lstStyle/>
            \(paragraphs)</p:txBody></p:sp>
            """
        }

        private static func notesShape(_ lines: [[InlineRun]]) -> String {
            let paragraphs = lines.map { line in
                """
                <a:p><a:pPr marL="0" indent="0"><a:lnSpc><a:spcPct val="112000"/></a:lnSpc></a:pPr>
                \(runsXML(line, size: 1100, color: "8A9099", italic: true))</a:p>
                """
            }.joined()
            return """
            <p:sp><p:nvSpPr><p:cNvPr id="30" name="SpeakerNotes"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="967740" y="5750000"/><a:ext cx="10287000" cy="850000"/></a:xfrm>
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
            <a:solidFill><a:srgbClr val="F7F5F0"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
            <p:txBody><a:bodyPr wrap="square" anchor="t" lIns="137160" tIns="91440" rIns="137160" bIns="91440">
            <a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
            """
        }

        private static func runsXML(_ runs: [InlineRun], size: Int, color: String, italic: Bool = false) -> String {
            runs.map { run in
                """
                <a:r><a:rPr lang="en-US" sz="\(size)" b="\(run.isBold ? 1 : 0)" i="\(italic ? 1 : 0)" dirty="0">
                <a:solidFill><a:srgbClr val="\(color)"/></a:solidFill>
                <a:latin typeface="Helvetica Neue"/></a:rPr>
                <a:t>\(DOCXBuilder.escaped(run.text))</a:t></a:r>
                """
            }.joined()
        }

        // MARK: Theme

        private static let themeXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="ScanVault">
        <a:themeElements>
        <a:clrScheme name="ScanVault">
        <a:dk1><a:srgbClr val="23272F"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="3E4450"/></a:dk2><a:lt2><a:srgbClr val="F4EBD8"/></a:lt2>
        <a:accent1><a:srgbClr val="E8A33D"/></a:accent1><a:accent2><a:srgbClr val="C9922E"/></a:accent2>
        <a:accent3><a:srgbClr val="3E4450"/></a:accent3><a:accent4><a:srgbClr val="8A7CE0"/></a:accent4>
        <a:accent5><a:srgbClr val="1F6FEB"/></a:accent5><a:accent6><a:srgbClr val="E2664F"/></a:accent6>
        <a:hlink><a:srgbClr val="1F6FEB"/></a:hlink><a:folHlink><a:srgbClr val="8A7CE0"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="ScanVault">
        <a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
        <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="ScanVault">
        <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:fillStyleLst>
        <a:lnStyleLst>
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        <a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln>
        </a:lnStyleLst>
        <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        </a:effectStyleLst>
        <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }
}

// MARK: - Font weight fallback

private extension UIFont {
    /// Rebuilds the font with a new weight, preserving family and size.
    func withWeightFallback(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
