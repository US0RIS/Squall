import AppKit

/// Liquid-glass look built from layers over a behind-window blur:
/// tint → vertical sheen (bright top, clear bottom) → specular rim that is brightest
/// at the top-left and fades around the edge.
enum Glass {
    struct Style {
        var tint: CGColor
        var sheen: CGFloat        // alpha of the top highlight
        var rim: CGFloat          // alpha of the specular edge
        var rimWidth: CGFloat = 1.5
    }

    static func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }

    static func draw(_ path: CGPath, in ctx: CGContext, style s: Style) {
        let box = path.boundingBox

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(s.tint)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()
        if let g = CGGradient(colorsSpace: nil,
                              colors: [white(s.sheen), white(s.sheen * 0.18), white(0)] as CFArray,
                              locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY),
                                   end: CGPoint(x: box.midX, y: box.minY), options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(s.rimWidth)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let g = CGGradient(colorsSpace: nil,
                              colors: [white(s.rim), white(s.rim * 0.22), white(s.rim * 0.55)] as CFArray,
                              locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.maxY),
                                   end: CGPoint(x: box.maxX, y: box.minY), options: [])
        }
        ctx.restoreGState()
    }
}
