import AppKit

extension Weather {
    /// Top and bottom of the selection's gradient.
    var accent: (top: SIMD4<Double>, bottom: SIMD4<Double>) {
        switch self {
        case .clear: return (SIMD4(1.00, 0.76, 0.32, 1), SIMD4(0.98, 0.50, 0.30, 1))
        case .rain: return (SIMD4(0.36, 0.64, 1.00, 1), SIMD4(0.22, 0.38, 0.92, 1))
        case .snow: return (SIMD4(0.66, 0.82, 1.00, 1), SIMD4(0.56, 0.52, 0.98, 1))
        }
    }

    var tint: NSColor {
        let t = accent.top
        return NSColor(srgbRed: t.x, green: t.y, blue: t.z, alpha: 1)
    }
}

/// Three glass tiles — Clear · Rain · Snow — with a lit selection that springs between them and
/// blends its color on the way.
@MainActor
final class WeatherPicker: NSView {
    var onSelect: ((Weather) -> Void)?
    private(set) var selection: Weather = .snow

    private let items = Weather.allCases
    private var position: CGFloat = 2
    private var velocity: CGFloat = 0
    private var hover: Int?
    private var timer: Timer?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 268, height: 84) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelection(_ weather: Weather, animated: Bool) {
        selection = weather
        if animated {
            startAnimation()
        } else {
            timer?.invalidate()
            timer = nil
            position = target
            velocity = 0
            needsDisplay = true
        }
    }

    private var target: CGFloat { CGFloat(items.firstIndex(of: selection) ?? 0) }

    private func startAnimation() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animationStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func animationStep() {
        velocity = velocity * 0.72 + (target - position) * 0.12
        position += velocity
        if abs(target - position) < 0.001 && abs(velocity) < 0.001 {
            position = target
            velocity = 0
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    private func tileRect(_ i: CGFloat) -> CGRect {
        let gap: CGFloat = 8
        let w = (bounds.width - gap * 2) / 3
        return CGRect(x: i * (w + gap), y: 0, width: w, height: bounds.height).insetBy(dx: 0.75, dy: 0.75)
    }

    private func roundRect(_ r: CGRect) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: 13, cornerHeight: 13, transform: nil)
    }

    /// Accent colors interpolated across the tiles the selection is passing over.
    private func accent(at pos: CGFloat) -> (CGColor, CGColor) {
        let clamped = min(max(pos, 0), CGFloat(items.count - 1))
        let i = Int(clamped.rounded(.down))
        let j = min(i + 1, items.count - 1)
        let f = Double(clamped - CGFloat(i))
        let a = items[i].accent, b = items[j].accent
        func color(_ x: SIMD4<Double>, _ y: SIMD4<Double>) -> CGColor {
            let m = x + (y - x) * f
            return CGColor(srgbRed: m.x, green: m.y, blue: m.z, alpha: m.w)
        }
        return (color(a.top, b.top), color(a.bottom, b.bottom))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Resting tiles.
        for i in 0..<items.count {
            let hovered = hover == i
            let tint = dark ? Glass.white(hovered ? 0.11 : 0.06) : CGColor(gray: 0, alpha: hovered ? 0.08 : 0.045)
            Glass.draw(roundRect(tileRect(CGFloat(i))), in: ctx,
                       style: .init(tint: tint, sheen: dark ? 0.12 : 0.35, rim: dark ? 0.35 : 0.7, rimWidth: 1))
        }

        // The lit selection.
        let path = roundRect(tileRect(position))
        let (top, bottom) = accent(at: position)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: top.copy(alpha: 0.6))
        ctx.addPath(path)
        ctx.setFillColor(top)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let box = path.boundingBox
        if let g = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY),
                                   end: CGPoint(x: box.midX, y: box.minY), options: [])
        }
        ctx.restoreGState()
        Glass.draw(path, in: ctx, style: .init(tint: Glass.white(0), sheen: 0.4, rim: 0.9, rimWidth: 1.5))

        // Symbols and titles, turning white as the selection slides under them.
        let idle = dark ? NSColor(white: 1, alpha: 0.72) : NSColor(white: 0, alpha: 0.6)
        for (i, weather) in items.enumerated() {
            let r = tileRect(CGFloat(i))
            let cover = max(0, 1 - abs(position - CGFloat(i)))
            let fg = idle.blended(withFraction: cover, of: .white) ?? .white
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [fg]))
            if let img = NSImage(systemSymbolName: weather.symbol, accessibilityDescription: weather.title)?
                .withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2 + 9,
                                    width: s.width, height: s.height))
            }
            let title = NSAttributedString(string: weather.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: fg,
            ])
            let ts = title.size()
            title.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.minY + 11))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<items.count where tileRect(CGFloat(i)).contains(p) {
            let weather = items[i]
            if weather != selection {
                setSelection(weather, animated: true)
                onSelect?(weather)
            }
            return
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = (0..<items.count).first { tileRect(CGFloat($0)).contains(p) }
        if h != hover {
            hover = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }
}
