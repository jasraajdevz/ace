//
//  OCRService.swift
//  Ace
//
//  On-device text recognition with Vision. No key, no network, no cost — this
//  is why Demo Mode can read a real worksheet.
//

import Foundation
import Vision
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Reads text out of images.
///
/// Vision returns one observation per recognised line, in reading order, each
/// with a confidence. We keep both: the lines feed `SourceTextCleaner`, and the
/// average confidence tells the UI whether to suggest a retake.
struct OCRService: Sendable {

    /// Words the recogniser should expect. Subject vocabulary is exactly what a
    /// general language model gets wrong, so seeding it measurably improves a
    /// science or history page.
    private static let customWords = [
        "photosynthesis", "chloroplast", "chlorophyll", "mitochondria", "mitosis",
        "meiosis", "eukaryote", "prokaryote", "hypotenuse", "denominator",
        "numerator", "coefficient", "polynomial", "quadratic", "derivative",
        "integral", "covalent", "ionic", "electronegativity", "stoichiometry",
        "onomatopoeia", "protagonist", "metaphor", "alliteration"
    ]

    init() {}

    /// Recognise text in raw image data.
    func recognizeText(in imageData: Data) async throws -> RecognizedText {
        guard let cgImage = Self.makeCGImage(from: imageData) else {
            throw AIProviderError.noTextFound
        }
        return try await recognizeText(in: cgImage)
    }

    /// Recognise text in a `CGImage` — used directly by the document scanner,
    /// which already hands us decoded pages.
    func recognizeText(in cgImage: CGImage) async throws -> RecognizedText {
        // Vision's completion handler can be called on an arbitrary queue, and
        // `perform` blocks, so the request runs off the main actor and the
        // result is bridged back through a continuation.
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: AIProviderError.transport(error.localizedDescription))
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(returning: .empty)
                    return
                }

                var lines: [String] = []
                var confidenceTotal: Double = 0
                for observation in observations {
                    guard let best = observation.topCandidates(1).first else { continue }
                    lines.append(best.string)
                    confidenceTotal += Double(best.confidence)
                }

                let average = lines.isEmpty ? 0 : confidenceTotal / Double(lines.count)
                continuation.resume(returning: RecognizedText(lines: lines, confidence: average))
            }

            // `.accurate` is roughly 3× slower than `.fast` but dramatically
            // better on the small, dense type of a textbook page. Reading a
            // page is a one-shot operation the student expects to take a
            // moment, so accuracy wins.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.customWords = Self.customWords
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: AIProviderError.transport(error.localizedDescription))
            }
        }
    }

    /// Recognise several pages (a multi-page scan) and concatenate in order.
    func recognizeText(in images: [CGImage]) async throws -> RecognizedText {
        var allLines: [String] = []
        var confidences: [Double] = []

        for image in images {
            let result = try await recognizeText(in: image)
            allLines.append(contentsOf: result.lines)
            if !result.lines.isEmpty { confidences.append(result.confidence) }
        }

        let average = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return RecognizedText(lines: allLines, confidence: average)
    }

    // MARK: - Image decoding

    static func makeCGImage(from data: Data) -> CGImage? {
        #if canImport(UIKit)
        return UIImage(data: data)?.cgImage
        #else
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
        #endif
    }
}

#if canImport(ImageIO)
import ImageIO
#endif
