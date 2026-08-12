//
//  CapturePickers.swift
//  Ace
//
//  UIKit bridges for the three ways a student can hand Ace an image.
//
//  All three are `UIViewControllerRepresentable` wrappers. They are kept in one
//  file, and deliberately thin: each one's only job is to hand back image data
//  and dismiss. Nothing here knows what OCR is.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
import PhotosUI
import VisionKit
#endif

#if canImport(UIKit)

// MARK: - Camera

/// A plain camera capture. `UIImagePickerController` rather than a custom
/// `AVCaptureSession` because for "photograph this worksheet" the system UI is
/// better than anything worth hand-rolling.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Guard the source type: the Simulator has no camera, and asking for
        // one there throws.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.normalizedForOCR().jpegData(compressionQuality: 0.9) else {
                parent.onCancel()
                return
            }
            parent.onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

// MARK: - Photo library

/// `PHPickerViewController` — runs out of process, so it needs no photo-library
/// permission at all. That's one fewer prompt on first run.
struct LibraryPicker: UIViewControllerRepresentable {
    let onPick: ([Data]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        // Several pages of the same chapter is a normal thing to want.
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: LibraryPicker
        init(_ parent: LibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }

            // Results load asynchronously and out of order, so they're gathered
            // into a fixed-size array and reassembled by index.
            Task {
                var images = [Data?](repeating: nil, count: results.count)
                await withTaskGroup(of: (Int, Data?).self) { group in
                    for (index, result) in results.enumerated() {
                        group.addTask {
                            (index, await Self.loadImageData(from: result))
                        }
                    }
                    for await (index, data) in group {
                        images[index] = data
                    }
                }
                let ordered = images.compactMap { $0 }
                await MainActor.run {
                    if ordered.isEmpty { parent.onCancel() } else { parent.onPick(ordered) }
                }
            }
        }

        private static func loadImageData(from result: PHPickerResult) async -> Data? {
            guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
            return await withCheckedContinuation { continuation in
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    let image = object as? UIImage
                    continuation.resume(
                        returning: image?.normalizedForOCR().jpegData(compressionQuality: 0.9)
                    )
                }
            }
        }
    }
}

// MARK: - Document scanner

/// VisionKit's document scanner: edge detection, perspective correction and
/// multi-page capture for free. For a textbook page this beats a raw photo
/// every time, which is why it's the recommended option in the UI.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([Data]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: index)
                if let data = image.normalizedForOCR().jpegData(compressionQuality: 0.92) {
                    pages.append(data)
                }
            }
            pages.isEmpty ? parent.onCancel() : parent.onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

// MARK: - Image preparation

extension UIImage {
    /// Prepare an image for text recognition.
    ///
    /// Two things matter to Vision:
    ///   1. Orientation must be baked into the pixels. `CGImage` carries no
    ///      orientation, so a photo taken in portrait arrives sideways and the
    ///      recogniser reads nothing.
    ///   2. Enormous images waste time without improving accuracy. A 12MP photo
    ///      of a worksheet is downscaled to a long edge of 2400px, which is
    ///      still well above what `.accurate` needs for body text.
    func normalizedForOCR(maxDimension: CGFloat = 2400) -> UIImage {
        let longEdge = max(size.width, size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let targetSize = CGSize(width: (size.width * scale).rounded(),
                                height: (size.height * scale).rounded())

        // Drawing into a renderer both resizes and bakes in the orientation.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

/// Whether the device can offer the document scanner. Older hardware and the
/// Simulator can't, and the capture screen hides the option rather than showing
/// a button that fails.
enum ScannerAvailability {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }
    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

#endif
