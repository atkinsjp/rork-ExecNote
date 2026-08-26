//
//  PDFManager.swift
//  ScanVault
//

import Foundation
import PDFKit
import UIKit

nonisolated enum PDFManagerError: LocalizedError {
    case noPages
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPages: "There are no pages to save."
        case .renderFailed: "The pages could not be rendered into a PDF."
        case .writeFailed(let reason): "The PDF could not be saved: \(reason)"
        }
    }
}

/// Converts captured page images into a flattened, multi-page PDF and stores it
/// inside the app sandbox cache. All work happens off the main actor.
actor PDFManager {
    static let shared = PDFManager()

    /// US Letter at 72 dpi — the page box every scan is fitted into.
    static let pageSize = CGSize(width: 612, height: 792)

    private let directoryName = "ScannedDocuments"

    /// Cache directory holding generated PDFs. Created lazily.
    func documentsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: directoryName, directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Flattens `images` into a single multi-page PDF document.
    func makePDFData(from images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw PDFManagerError.noPages }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "IntelliDoc",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: Self.pageSize),
            format: format
        )

        let data = renderer.pdfData { context in
            for image in images {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: Self.pageSize))
                image.draw(in: Self.aspectFitRect(for: image.size, in: Self.pageSize))
            }
        }

        guard !data.isEmpty else { throw PDFManagerError.renderFailed }
        return data
    }

    /// Writes PDF bytes to the sandbox cache and returns the on-disk location.
    func save(_ data: Data, documentId: String) throws -> URL {
        do {
            let url = try documentsDirectory().appending(path: "\(documentId).pdf")
            try data.write(to: url, options: .atomic)
            return url
        } catch let error as PDFManagerError {
            throw error
        } catch {
            throw PDFManagerError.writeFailed(error.localizedDescription)
        }
    }

    /// Convenience: render + persist in one hop.
    func makeAndSave(images: [UIImage], documentId: String) throws -> (url: URL, data: Data) {
        let data = try makePDFData(from: images)
        let url = try save(data, documentId: documentId)
        return (url, data)
    }

    func delete(documentId: String) {
        guard let url = try? documentsDirectory().appending(path: "\(documentId).pdf") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func existingURL(documentId: String) -> URL? {
        guard let url = try? documentsDirectory().appending(path: "\(documentId).pdf") else { return nil }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Renders page 1 of a PDF as a thumbnail image for list rows.
    func thumbnail(for url: URL, width: CGFloat = 220) -> UIImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return nil }
        let scale = width / bounds.width
        let size = CGSize(width: width, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    /// Rasterizes every page of a stored PDF into images at ~`maxWidth`
    /// pixels wide. Feeds the redaction flow: OCR runs on these images and
    /// the sanitized PDF is rebuilt from them.
    func pageImages(for url: URL, maxWidth: CGFloat = 1240) -> [UIImage] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return [] }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        var images: [UIImage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }

            let scale = maxWidth / bounds.width
            let size = CGSize(width: maxWidth, height: bounds.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context.cgContext)
                context.cgContext.restoreGState()
            }
            images.append(image)
        }
        return images
    }

    static func aspectFitRect(for imageSize: CGSize, in pageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: pageSize)
        }
        let scale = min(pageSize.width / imageSize.width, pageSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (pageSize.width - size.width) / 2,
            y: (pageSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
