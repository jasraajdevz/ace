//
//  make_icon.swift
//  Ace — asset generation
//
//  Renders the app icon and launch mark with CoreGraphics, so the artwork is
//  source-controlled as code rather than as opaque binaries.
//
//  Run:  swift Tools/gen/make_icon.swift
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (must match Ace/DesignSystem/Theme.swift)

let accent = CGColor(red: 0x7C / 255, green: 0x5C / 255, blue: 0xFF / 255, alpha: 1)
let accentAlt = CGColor(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1)
let onAccent = CGColor(red: 0x0A / 255, green: 0x0A / 255, blue: 0x11 / 255, alpha: 1)

// MARK: - The "A" glyph

// MARK: Glyph geometry
//
// These MUST match `AceGlyphGeometry` in Ace/DesignSystem/AceMark.swift.
// Coordinates are normalised and y-down, exactly as in the SwiftUI shape; `p()`
// flips them for CoreGraphics, which is y-up.

let glyphOuter: [(CGFloat, CGFloat)] = [(0.455, 0.00), (0.545, 0.00), (1.000, 1.00), (0.000, 1.00)]
let glyphCounter: [(CGFloat, CGFloat)] = [(0.500, 0.30), (0.635, 0.63), (0.365, 0.63)]
let glyphNotch: [(CGFloat, CGFloat)] = [(0.280, 0.80), (0.720, 0.80), (0.820, 1.00), (0.180, 1.00)]

/// The same geometry as `AGlyph` in AceMark.swift. Fill this with `.evenOdd`.
func aGlyphPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()

    func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * (1 - fy))
    }

    func add(_ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        path.move(to: p(first.0, first.1))
        for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
        path.closeSubpath()
    }

    add(glyphOuter)
    add(glyphCounter)
    add(glyphNotch)
    return path
}

// MARK: - Renderers

func makeContext(size: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}

/// The app icon: full-bleed brand gradient with the mark punched through it.
/// No rounded corners and no transparency — iOS applies the mask itself, and a
/// pre-rounded icon gets rejected.
func renderAppIcon(size: Int) -> CGImage {
    let context = makeContext(size: size)
    let s = CGFloat(size)

    // Diagonal brand gradient.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [accent, accentAlt] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // A soft light bloom in the top-left so the icon has depth rather than
    // reading as a flat gradient swatch.
    let bloom = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        bloom,
        startCenter: CGPoint(x: s * 0.24, y: s * 0.80), startRadius: 0,
        endCenter: CGPoint(x: s * 0.24, y: s * 0.80), endRadius: s * 0.72,
        options: []
    )

    // The mark.
    let glyphWidth = s * 0.50
    let glyphHeight = glyphWidth * 0.96
    let glyphRect = CGRect(
        x: (s - glyphWidth) / 2,
        y: (s - glyphHeight) / 2,
        width: glyphWidth,
        height: glyphHeight
    )

    // A subtle drop shadow lifts the glyph off the gradient.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    context.addPath(aGlyphPath(in: glyphRect))
    context.setFillColor(onAccent)
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    return context.makeImage()!
}

/// The launch-screen mark: the glyph alone, in brand colour, on transparency.
func renderLaunchMark(size: Int) -> CGImage {
    let context = makeContext(size: size)
    let s = CGFloat(size)

    let glyphRect = CGRect(x: s * 0.06, y: s * 0.10, width: s * 0.88, height: s * 0.80)

    context.saveGState()
    context.addPath(aGlyphPath(in: glyphRect))
    context.clip(using: .evenOdd)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [accent, accentAlt] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - Writing

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        print("!! could not create destination at \(path)")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    if CGImageDestinationFinalize(destination) {
        print("   wrote \(path)")
    } else {
        print("!! failed writing \(path)")
    }
}

// MARK: - Main

let root = FileManager.default.currentDirectoryPath
let assets = "\(root)/Ace/Assets.xcassets"

print("Generating Ace artwork…")
write(renderAppIcon(size: 1024), to: "\(assets)/AppIcon.appiconset/icon-1024.png")
write(renderLaunchMark(size: 120), to: "\(assets)/LaunchMark.imageset/mark-120.png")
write(renderLaunchMark(size: 240), to: "\(assets)/LaunchMark.imageset/mark-240.png")
write(renderLaunchMark(size: 360), to: "\(assets)/LaunchMark.imageset/mark-360.png")
print("Done.")
