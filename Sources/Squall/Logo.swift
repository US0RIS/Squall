import AppKit

/// The Squall mark, drawn in code so the app icon and the panel header come from one source.
/// The .icns is rendered at build time via `Squall --render-iconset <dir>` (see build.sh).
enum Logo {
    /// Full-color app icon: a night-sky squircle, a glass cloud, rain and snow falling onto a drift.
    static func draw(in rect: CGRect, context ctx: CGContext) {
        let s = rect.width
        let body = rect.insetBy(dx: s * 0.098, dy: s * 0.098)
        let radius = body.width * 0.225
        let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let u = body.width
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * u, y: body.minY + y * u) }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                      color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(squircle)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.62, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        if let g = CGGradient(colorsSpace: nil, colors: [
            CGColor(red: 0.16, green: 0.18, blue: 0.46, alpha: 1),
            CGColor(red: 0.17, green: 0.42, blue: 0.80, alpha: 1),
            CGColor(red: 0.32, green: 0.80, blue: 0.92, alpha: 1),
        ] as CFArray, locations: [0, 0.6, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.minX + u * 0.2, y: body.maxY),
                                   end: CGPoint(x: body.maxX - u * 0.2, y: body.minY), options: [])
        }
        if let glow = CGGradient(colorsSpace: nil, colors: [Glass.white(0.28), Glass.white(0)] as CFArray,
                                 locations: [0, 1]) {
            let p = P(0.25, 0.82)
            ctx.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p,
                                   endRadius: u * 0.7, options: [])
        }

        let rim = s * 0.007
        // Drift settled along the bottom edge.
        let drift = CGMutablePath()
        drift.move(to: P(-0.05, -0.05))
        drift.addLine(to: P(-0.05, 0.15))
        drift.addCurve(to: P(0.46, 0.13), control1: P(0.12, 0.22), control2: P(0.30, 0.20))
        drift.addCurve(to: P(1.05, 0.20), control1: P(0.63, 0.06), control2: P(0.86, 0.25))
        drift.addLine(to: P(1.05, -0.05))
        drift.closeSubpath()
        Glass.draw(drift, in: ctx, style: .init(tint: Glass.white(0.9), sheen: 0.3, rim: 1, rimWidth: rim))

        // Rain on the left, snow on the right.
        for (x, y, r) in [(0.33, 0.33, 0.034), (0.45, 0.25, 0.028), (0.27, 0.22, 0.024)] as [(CGFloat, CGFloat, CGFloat)] {
            Glass.draw(drop(center: P(x, y), r: r * u), in: ctx,
                       style: .init(tint: CGColor(red: 0.75, green: 0.9, blue: 1, alpha: 0.85), sheen: 0.45, rim: 1, rimWidth: rim))
        }
        for (x, y, r) in [(0.61, 0.33, 0.03), (0.72, 0.26, 0.024), (0.57, 0.22, 0.02)] as [(CGFloat, CGFloat, CGFloat)] {
            let c = P(x, y)
            let flake = CGPath(ellipseIn: CGRect(x: c.x - r * u, y: c.y - r * u, width: 2 * r * u, height: 2 * r * u),
                               transform: nil)
            Glass.draw(flake, in: ctx, style: .init(tint: Glass.white(0.92), sheen: 0.4, rim: 1, rimWidth: rim))
        }

        // The cloud.
        Glass.draw(cloud(P, u), in: ctx, style: .init(tint: Glass.white(0.34), sheen: 0.5, rim: 1, rimWidth: s * 0.009))
        ctx.restoreGState()
    }

    private static func cloud(_ P: (CGFloat, CGFloat) -> CGPoint, _ u: CGFloat) -> CGPath {
        var shape: CGPath = CGPath(roundedRect: CGRect(origin: P(0.20, 0.44), size: CGSize(width: 0.62 * u, height: 0.16 * u)),
                                   cornerWidth: 0.075 * u, cornerHeight: 0.075 * u, transform: nil)
        for (cx, cy, r) in [(0.36, 0.60, 0.13), (0.54, 0.66, 0.17), (0.70, 0.58, 0.11)] as [(CGFloat, CGFloat, CGFloat)] {
            let c = P(cx, cy)
            let circle = CGPath(ellipseIn: CGRect(x: c.x - r * u, y: c.y - r * u, width: 2 * r * u, height: 2 * r * u),
                                transform: nil)
            shape = shape.union(circle)
        }
        return shape
    }

    private static func drop(center c: CGPoint, r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let tip = CGPoint(x: c.x, y: c.y + r * 2.3)
        p.move(to: tip)
        p.addCurve(to: CGPoint(x: c.x + r, y: c.y),
                   control1: CGPoint(x: c.x + r * 0.35, y: c.y + r * 1.5),
                   control2: CGPoint(x: c.x + r, y: c.y + r * 0.8))
        p.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi, clockwise: true)
        p.addCurve(to: tip,
                   control1: CGPoint(x: c.x - r, y: c.y + r * 0.8),
                   control2: CGPoint(x: c.x - r * 0.35, y: c.y + r * 1.5))
        p.closeSubpath()
        return p
    }

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: rect, context: ctx)
            return true
        }
    }

    // MARK: - Build-time icon rendering

    static func renderIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let data = png(pixels: base * scale) else {
                    throw NSError(domain: "Squall", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed"])
                }
                try data.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    private static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)), context: g.cgContext)
        g.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
