//
//  AceMark.swift
//  Ace
//
//  The logo, drawn in code.
//
//  It's a speech bubble whose lower-left corner resolves into the crossbar of a
//  capital "A" — Ace is a voice and a grade at the same time. Drawn as a `Shape`
//  rather than shipped as a PNG so it stays crisp at any size, tints with the
//  brand gradient, and can animate (the level-up moment in Part 2 uses it).
//

import SwiftUI

/// The Ace mark: rounded bubble + the "A".
struct AceMark: View {
    var size: CGFloat = 64
    var showsBubble: Bool = true

    var body: some View {
        ZStack {
            if showsBubble {
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(Ink.brandGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: size * 0.012)
                    )

                // The bubble's tail, tucked into the lower-left corner.
                BubbleTail()
                    .fill(Ink.accent)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .offset(x: -size * 0.30, y: size * 0.44)
            }

            AGlyph()
                .fill(showsBubble ? Ink.textOnAccent : Ink.textPrimary, style: FillStyle(eoFill: true))
                .frame(width: size * 0.46, height: size * 0.44)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The "A".
///
/// Built as one solid triangle with two pieces cut out of it — the counter (the
/// triangular hole) and the notch between the legs — filled even-odd. Doing it
/// subtractively rather than as two overlapping legs plus a crossbar is what
/// keeps the stroke width even and guarantees the crossbar fills solid: two
/// overlapping subpaths with opposite winding cancel each other out and punch a
/// hole exactly where the bar should be.
///
/// `AceGlyphGeometry` holds the coordinates so the icon renderer in
/// `Tools/gen/make_icon.swift` draws precisely the same shape.
private struct AGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        func p(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + w * point.x, y: rect.minY + h * point.y)
        }

        func add(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: p(first))
            for point in points.dropFirst() { path.addLine(to: p(point)) }
            path.closeSubpath()
        }

        add(AceGlyphGeometry.outer)
        add(AceGlyphGeometry.counter)
        add(AceGlyphGeometry.notch)
        return path
    }
}

/// Normalised (0...1, y-down) coordinates for the Ace "A".
///
/// Shared between the in-app `Shape` and the app-icon renderer so the two can
/// never drift apart.
enum AceGlyphGeometry {
    /// The silhouette. The apex is clipped flat rather than left as a razor
    /// point — a true point disappears at 40pt and looks accidental at 1024.
    static let outer: [CGPoint] = [
        CGPoint(x: 0.455, y: 0.00),
        CGPoint(x: 0.545, y: 0.00),
        CGPoint(x: 1.000, y: 1.00),
        CGPoint(x: 0.000, y: 1.00)
    ]
    /// The triangular hole in the top half.
    static let counter: [CGPoint] = [
        CGPoint(x: 0.500, y: 0.30),
        CGPoint(x: 0.635, y: 0.63),
        CGPoint(x: 0.365, y: 0.63)
    ]
    /// The gap between the legs. A trapezoid following the outer slope, so the
    /// legs keep an even thickness all the way down.
    static let notch: [CGPoint] = [
        CGPoint(x: 0.280, y: 0.80),
        CGPoint(x: 0.720, y: 0.80),
        CGPoint(x: 0.820, y: 1.00),
        CGPoint(x: 0.180, y: 1.00)
    ]
}

/// The little tail that turns a rounded square into a speech bubble.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY),
            control: CGPoint(x: rect.maxX * 0.72, y: rect.height * 0.62)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.42))
        path.closeSubpath()
        return path
    }
}

// MARK: - Flow layout

/// A wrapping row of views — chips that flow onto the next line when they run
/// out of width.
///
/// SwiftUI has no built-in for this (`LazyVGrid` forces a column width, which
/// looks wrong for variable-width chips), so it's a small `Layout`.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s
    var lineSpacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(subviews: subviews, maxWidth: maxWidth)

        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.height
        } + lineSpacing * CGFloat(max(0, rows.count - 1))

        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthIfAdded = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width

            if widthIfAdded > maxWidth && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = widthIfAdded
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
