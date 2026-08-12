//
//  PDFTextExtractor.swift
//  Ace
//
//  Getting words out of a PDF.
//
//  Two paths, and picking between them per page is what makes this work on real
//  documents: most PDFs carry an embedded text layer, which is perfect and free.
//  Scanned ones don't — those pages are rendered and read with the same Vision
//  OCR a photograph goes through.
//
//  Kept separate from `ShareImporter` (which is bound to SwiftData) so it can be
//  compiled and type-checked by the command-line build. See DECISIONS.md D1.
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum PDFTextExtractor {

/// Extract text from a PDF.
///
/// PDFKit gets the embedded text layer, which most PDFs have and which is
/// perfect. Scanned PDFs have no text layer, so those pages fall through to
/// Vision — the same OCR path a photograph takes.
static func read(data: Data, provider: AIProvider) async throws -> [String] {
    #if canImport(PDFKit)
    guard let document = PDFDocument(data: data) else {
        throw AIProviderError.noTextFound
    }

    var lines: [String] = []
    // A cap: a 400-page textbook would take minutes to OCR and produce
    // material nobody is going to study in one sitting.
    let pageLimit = min(document.pageCount, 20)

    for index in 0..<pageLimit {
        guard let page = document.page(at: index) else { continue }

        if let text = page.string, text.trimmed.count > 40 {
            lines.append(contentsOf: text.components(separatedBy: .newlines))
            continue
        }

        // No text layer — render and read it.
        #if canImport(UIKit)
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.white.set()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        if let jpeg = image.jpegData(compressionQuality: 0.85),
           let recognised = try? await provider.readText(from: jpeg) {
            lines.append(contentsOf: recognised.lines)
        }
        #endif
    }
    return lines
    #else
    throw AIProviderError.noTextFound
    #endif
}
}
