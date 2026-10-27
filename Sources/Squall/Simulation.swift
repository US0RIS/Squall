import AppKit
import simd

struct Particle {
    enum Kind: UInt8 { case snow = 0, rain = 1, droplet = 2 }

    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var size: Float
    var depth: Float
    var phase: Float
    var mass: Float
    var alpha: Float
    var kind: Kind
    var age: Float = 0
    var dead = false

    init(x: Float, y: Float, vx: Float, vy: Float, size: Float, depth: Float,
         phase: Float, mass: Float, alpha: Float, kind: Kind) {
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.size = size
        self.depth = depth
        self.phase = phase
        self.mass = mass
        self.alpha = alpha
        self.kind = kind
    }

    /// The near layer collides with ledges and feels the cursor; the far layer drifts past.
    var near: Bool { depth >= 0.6 }
}

struct ScreenInfo: Equatable {
    let id: Int
    /// Global Quartz rect.
    let rect: CGRect
    /// Quartz y of the bottom of the menu bar on this screen.
    let visibleTop: CGFloat
}

struct Conditions: Equatable {
    var weather: Weather = .snow
    var intensity: Float = 0.55
    var wind: Float = 0.1
    var cursor = true
    var gusts = true
    var settle = true
}

/// All weather state: falling particles plus the snow and water resting on ledges.
/// Everything is in global Quartz points (origin top-left of the primary display, y down).
@MainActor
final class Simulation {
    var conditions = Conditions()

    private(set) var particles: [Particle] = []
    private var spawned: [Particle] = []
    private var windowLedges: [Int: Ledge] = [:]
    private var floorLedges: [Int: Ledge] = [:]
    private var ledgeList: [Ledge] = []
    private var order: [TrackedWindow] = []
    private var screens: [ScreenInfo] = []
    private var bounds = CGRect.zero

    private var snowCarry: [Int: Float] = [:]
    private var rainCarry: [Int: Float] = [:]
    private var snowLevel: Float = 0
    private var rainLevel: Float = 0
    private var time: Float = 0
    private var lastPoll: Float = 0
    private var lastSweep: Float = 0
    private var windNow: Float = 0

    private var snowCount = 0
    private var rainCount = 0
    private var dropCount = 0

    private var cursor = SIMD2<Float>(-100_000, -100_000)
    private var cursorVel = SIMD2<Float>(0, 0)
    private var cursorKnown = false

    private struct Segment {
        let ledge: Ledge
        let x0: Float
        let x1: Float
    }

    private struct Hit {
        let ledge: Ledge
        let cell: Int
        let y: Float
    }

    private var segments: [Segment] = []
    private var bins: [[Int]] = []
    private var binOrigin: Float = 0
    private let binWidth: Float = 64

    private var waterVis: [Float] = []
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    private enum Cap {
        static let snow = 4500
        static let rain = 2400
        static let drops = 1600
    }

    // MARK: - Public

    var isIdle: Bool {
        guard conditions.weather == .clear, snowLevel < 0.002, rainLevel < 0.002,
              particles.isEmpty, spawned.isEmpty else { return false }
        for ledge in ledgeList where !ledge.isEmpty { return false }
        return true
    }

    func step(dt: Float, windows: [TrackedWindow]?, screens newScreens: [ScreenInfo], cursor point: CGPoint) {
        time += dt
        windNow = conditions.wind + sinf(time * 0.21) * 0.12 + sinf(time * 0.67 + 1.3) * 0.06

        var topologyChanged = false
        if newScreens != screens {
            screens = newScreens
            updateFloors()
            topologyChanged = true
        }
        updateCursor(point, dt: dt)

        if !conditions.settle && !windowLedges.isEmpty {
            for ledge in windowLedges.values { spill(ledge.takeAll(), vx: ledge.vx * 0.3, vy: 0) }
            windowLedges.removeAll()
            topologyChanged = true
        }
        if let windows {
            syncWindows(windows)
            topologyChanged = true
        }
        if topologyChanged {
            ledgeList = Array(windowLedges.values) + Array(floorLedges.values)
            computeVisibility()
            buildSegments()
        }

        emit(dt)
        integrate(dt)
        if conditions.cursor && cursorKnown { dig() }
        updateLedges(dt)

        particles.removeAll { $0.dead }
        if !spawned.isEmpty {
            particles.append(contentsOf: spawned)
            spawned.removeAll(keepingCapacity: true)
        }
    }

    /// A click: a puff of air that scatters nearby flakes and blasts snow off ledges.
    func gust(at point: CGPoint) {
        let c = SIMD2<Float>(Float(point.x), Float(point.y))
        let reach: Float = 230
        for k in particles.indices {
            var p = particles[k]
            let dx = p.x - c.x, dy = p.y - c.y
            let d2 = dx * dx + dy * dy
            guard d2 < reach * reach, d2 > 0.01 else { continue }
            let d = d2.squareRoot()
            let f = 1 - d / reach
            let impulse = f * f * 1100 * (0.4 + 0.6 * p.depth)
            p.vx += dx / d * impulse
            p.vy += dy / d * impulse - f * 160
            particles[k] = p
        }

        let blast: Float = 110
        for ledge in ledgeList where ledge.enabled {
            guard c.x > ledge.x - blast, c.x < ledge.x + ledge.width + blast,
                  abs(c.y - ledge.y) < blast + ledge.maxSnow else { continue }
            let ia = max(0, Int((c.x - blast - ledge.x) / ledge.cw))
            let ib = min(ledge.count - 1, Int((c.x + blast - ledge.x) / ledge.cw))
            guard ia <= ib else { continue }
            for i in ia...ib where ledge.visible[i] {
                let px = ledge.centerX(i), py = ledge.surface(i)
                let dx = px - c.x, dy = py - c.y
                let d = max(1, (dx * dx + dy * dy).squareRoot())
                guard d < blast else { continue }
                let f = 1 - d / blast
                let s = ledge.snow[i] * min(0.85, f * 1.1)
                if s > 0.03 {
                    ledge.snow[i] -= s
                    emitChunks(mass: s * ledge.cw / Ledge.nominalCell, x: px, y: ledge.surface(i) - 1,
                               vx: dx / d * 420 * f, vy: -170 * f - 60, spread: 140)
                }
                if ledge.water[i] > 0.05 {
                    ledge.rippleVel[i] -= 2.4 * f
                    let w = ledge.water[i] * 0.4 * f
                    if w > 0.05 {
                        ledge.water[i] -= w
                        emitDrops(mass: w * ledge.cw / Ledge.nominalCell, x: px, y: ledge.surface(i) - 1,
                                  vx: dx / d * 300 * f, vy: -260 * f, spread: 160)
                    }
                }
            }
        }
    }

    /// Knocks every window's load off and sweeps the screen floors.
    func shakeOff() {
        for ledge in windowLedges.values {
            if ledge.hibernating || !ledge.enabled {
                ledge.clear()
            } else {
                spill(ledge.takeAll(), vx: 0, vy: -40)
            }
        }
        for ledge in floorLedges.values {
            // A puff of powder for show (massless, so it doesn't settle again).
            var i = 0
            while i < ledge.count {
                if ledge.snow[i] > 0.5 && ledge.visible[i] && snowCount < Cap.snow + 2000 {
                    spawn(Particle(x: ledge.centerX(i), y: ledge.surface(i), vx: (rand() - 0.5) * 160,
                                   vy: -(160 + rand() * 260), size: 2 + rand() * 3, depth: 1, phase: rand(),
                                   mass: 0, alpha: 0.9, kind: .snow))
                }
                i += 3
            }
            ledge.clear()
        }
    }

    // MARK: - Geometry

    private func updateFloors() {
        var union = CGRect.null
        var keep = Set<Int>()
        for s in screens {
            union = union.union(s.rect)
            keep.insert(s.id)
            let x = Float(s.rect.minX), y = Float(s.rect.maxY), w = Float(s.rect.width)
            if let ledge = floorLedges[s.id] {
                if abs(ledge.width - w) > 0.5 {
                    ledge.reshape(x: x, y: y, width: w)
                } else {
                    ledge.move(x: x, y: y)
                }
            } else {
                floorLedges[s.id] = Ledge(id: -s.id - 1, isFloor: true, x: x, y: y, width: w)
            }
        }
        for id in Array(floorLedges.keys) where !keep.contains(id) { floorLedges[id] = nil }
        bounds = union.isNull ? .zero : union
    }

    private func updateCursor(_ p: CGPoint, dt: Float) {
        let c = SIMD2<Float>(Float(p.x), Float(p.y))
        if cursorKnown {
            var v = (c - cursor) / max(dt, 1 / 240)
            let m = simd_length(v)
            if m > 6000 { v *= 6000 / m }
            cursorVel = cursorVel * 0.55 + v * 0.45
        }
        cursor = c
        cursorKnown = true
    }

    private func syncWindows(_ wins: [TrackedWindow]) {
        let pdt = max(time - lastPoll, 1 / 240)
        lastPoll = time
        order = wins

        var seen = Set<Int>()
        var resized: [(Ledge, CGRect)] = []
        for w in wins {
            seen.insert(w.id)
            let nx = Float(w.rect.minX), ny = Float(w.rect.minY), nw = Float(w.rect.width)
            guard let ledge = windowLedges[w.id] else {
                if conditions.settle {
                    windowLedges[w.id] = Ledge(id: w.id, isFloor: false, x: nx, y: ny, width: nw)
                }
                continue
            }
            ledge.hibernating = false
            if abs(nw - ledge.width) > 0.5 {
                resized.append((ledge, w.rect))
                continue
            }
            let dx = nx - ledge.x, dy = ny - ledge.y
            if abs(dx) + abs(dy) > 260 {
                // Teleported (snapped, tiled, restored elsewhere): everything falls where it was.
                spill(ledge.takeAll(), vx: 0, vy: 0)
                ledge.move(x: nx, y: ny)
                ledge.vx = 0
                ledge.vy = 0
                continue
            }
            let previousVx = ledge.vx
            ledge.vx = ledge.vx * 0.4 + (dx / pdt) * 0.6
            ledge.vy = ledge.vy * 0.4 + (dy / pdt) * 0.6
            if dx != 0 || dy != 0 { ledge.move(x: nx, y: ny) }
            shake(ledge, previousVx: previousVx)
        }

        if resized.count >= 3 {
            // Many windows changing size at once is Mission Control or a display change: hold still.
            for (ledge, _) in resized { ledge.hibernating = true }
        } else {
            for (ledge, r) in resized {
                spill(ledge.reshape(x: Float(r.minX), y: Float(r.minY), width: Float(r.width)), vx: 0, vy: 0)
                ledge.vx = 0
                ledge.vy = 0
            }
        }

        let missing = windowLedges.keys.filter { !seen.contains($0) }
        guard !missing.isEmpty else { return }
        let fresh = missing.contains { windowLedges[$0]?.hibernating == false }
        guard fresh || time - lastSweep > 2 else { return }
        lastSweep = time
        let alive = WindowTracker.allWindowIDs()
        for id in missing {
            guard let ledge = windowLedges[id] else { continue }
            if alive.contains(id) {
                ledge.hibernating = true
            } else {
                // Closed: its load falls.
                if !ledge.hibernating { spill(ledge.takeAll(), vx: ledge.vx * 0.3, vy: 0) }
                windowLedges[id] = nil
            }
        }
    }

    /// Dragging a window throws snow off it, and stopping hard flings the rest forward.
    private func shake(_ ledge: Ledge, previousVx pvx: Float) {
        let ax = ledge.vx - pvx
        let n = ledge.count
        if abs(ax) > 40 && n > 1 {
            let inv = 1 / Float(n - 1)
            for i in 0..<n where ledge.water[i] > 0.02 {
                ledge.rippleVel[i] += (Float(i) * inv - 0.5) * ax * 0.0022
            }
        }
        let moving = (abs(ledge.vx) + max(0, ledge.vy) * 0.7 - 300) / 6000
        let jerk = (abs(ax) - 380) / 5000
        let frac = min(0.2, max(0, moving) + max(0, jerk))
        guard frac > 0.003, ledge.enabled else { return }
        let throwVx = (abs(ax) > abs(ledge.vx) * 0.5 ? pvx : ledge.vx) * 0.85
        let throwVy = min(ledge.vy * 0.6, 0) - 30
        let k = ledge.cw / Ledge.nominalCell
        for i in 0..<n where ledge.visible[i] {
            let s = ledge.snow[i] * frac
            if s > 0.03 {
                ledge.snow[i] -= s
                emitChunks(mass: s * k, x: ledge.centerX(i), y: ledge.surface(i) - 1,
                           vx: throwVx, vy: throwVy, spread: 50)
            }
            let w = ledge.water[i] * min(0.5, frac * 1.5)
            if w > 0.04 {
                ledge.water[i] -= w
                emitDrops(mass: w * k, x: ledge.centerX(i), y: ledge.surface(i) - 1,
                          vx: throwVx, vy: throwVy - 40, spread: 70)
            }
        }
    }

    private func computeVisibility() {
        var front: [CGRect] = []
        front.reserveCapacity(order.count)
        for w in order {
            if let ledge = windowLedges[w.id] {
                ledge.enabled = conditions.settle && !ledge.hibernating && edgeIsOpen(ledge)
                if ledge.enabled { markVisible(ledge, behind: front) }
            }
            front.append(w.rect)
        }
        for ledge in floorLedges.values {
            ledge.enabled = true
            markVisible(ledge, behind: front)
        }
    }

    /// A window whose top edge is tucked under the menu bar (maximized, off the top) has no
    /// room for a pile.
    private func edgeIsOpen(_ ledge: Ledge) -> Bool {
        let p = CGPoint(x: CGFloat(ledge.x + ledge.width * 0.5), y: CGFloat(ledge.y) + 1)
        guard let s = screens.first(where: { $0.rect.contains(p) }) else { return false }
        return CGFloat(ledge.y) >= s.visibleTop + 4
    }

    private func markVisible(_ ledge: Ledge, behind rects: [CGRect]) {
        let top = CGFloat(ledge.y) - 3, bottom = CGFloat(ledge.y) - 1
        var spans: [(Float, Float)] = []
        for r in rects where r.minY < bottom && r.maxY > top {
            spans.append((Float(r.minX), Float(r.maxX)))
        }
        for i in 0..<ledge.count {
            let cx = ledge.centerX(i)
            var vis = true
            for s in spans where cx >= s.0 && cx <= s.1 {
                vis = false
                break
            }
            ledge.visible[i] = vis
        }
    }

    private func buildSegments() {
        segments.removeAll(keepingCapacity: true)
        for ledge in ledgeList where ledge.enabled {
            let n = ledge.count
            var i = 0
            while i < n {
                if !ledge.visible[i] {
                    i += 1
                    continue
                }
                var j = i
                while j < n && ledge.visible[j] { j += 1 }
                segments.append(Segment(ledge: ledge, x0: ledge.x + Float(i) * ledge.cw,
                                        x1: ledge.x + Float(j) * ledge.cw))
                i = j
            }
        }
        binOrigin = Float(bounds.minX) - 512
        let count = max(1, Int((Float(bounds.width) + 1024) / binWidth) + 1)
        if bins.count != count {
            bins = Array(repeating: [], count: count)
        } else {
            for k in bins.indices { bins[k].removeAll(keepingCapacity: true) }
        }
        for (si, s) in segments.enumerated() {
            let fa = (s.x0 - binOrigin) / binWidth, fb = (s.x1 - binOrigin) / binWidth
            guard fb >= 0, fa < Float(count) else { continue }
            let a = max(0, Int(fa)), b = min(count - 1, Int(fb))
            if a <= b { for k in a...b { bins[k].append(si) } }
        }
    }

    @inline(__always)
    private func collide(x: Float, prevY: Float, y: Float) -> Hit? {
        let fb = (x - binOrigin) / binWidth
        guard fb >= 0, fb < Float(bins.count) else { return nil }
        var best: Hit?
        for si in bins[Int(fb)] {
            let s = segments[si]
            guard x >= s.x0, x < s.x1 else { continue }
            let ledge = s.ledge
            var i = Int((x - ledge.x) / ledge.cw)
            if i < 0 { i = 0 } else if i >= ledge.count { i = ledge.count - 1 }
            let sy = ledge.y - ledge.snow[i] - ledge.water[i]
            if prevY <= sy + 0.5 && y >= sy {
                if let b = best, b.y <= sy { continue }
                best = Hit(ledge: ledge, cell: i, y: sy)
            }
        }
        return best
    }

    // MARK: - Particles

    @inline(__always) private func rand() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Float(seed >> 40) * (1.0 / 16_777_216.0)
    }

    private func spawn(_ p: Particle) {
        spawned.append(p)
        switch p.kind {
        case .snow: snowCount += 1
        case .rain: rainCount += 1
        case .droplet: dropCount += 1
        }
    }

    private func emit(_ dt: Float) {
        let target = conditions.intensity
        snowLevel += ((conditions.weather == .snow ? target : 0) - snowLevel) * min(1, dt * 0.7)
        rainLevel += ((conditions.weather == .rain ? target : 0) - rainLevel) * min(1, dt * 0.9)
        for s in screens {
            let w = Float(s.rect.width), h = Float(s.rect.height)
            if snowLevel > 0.002 {
                var n = (snowCarry[s.id] ?? 0) + snowLevel * 0.24 * w * dt
                while n >= 1 && snowCount < Cap.snow {
                    spawnFlake(s, w: w, h: h)
                    n -= 1
                }
                snowCarry[s.id] = n.truncatingRemainder(dividingBy: 1)
            }
            if rainLevel > 0.002 {
                var n = (rainCarry[s.id] ?? 0) + rainLevel * 1.3 * w * dt
                while n >= 1 && rainCount < Cap.rain {
                    spawnRaindrop(s, w: w, h: h)
                    n -= 1
                }
                rainCarry[s.id] = n.truncatingRemainder(dividingBy: 1)
            }
        }
    }

    private func spawnFlake(_ s: ScreenInfo, w: Float, h: Float) {
        let depth = 0.35 + 0.65 * rand()
        let size = (1.5 + 3.4 * rand()) * (0.45 + 0.75 * depth)
        let term = (26 + size * 8) * (0.55 + 0.45 * depth)
        let drift = windNow * 80 * (h / max(term, 1))
        let pad = min(abs(drift), 2000)
        let x0 = Float(s.rect.minX) - (drift > 0 ? pad : 0)
        spawn(Particle(x: x0 + rand() * (w + pad), y: Float(s.rect.minY) - 6 - rand() * 40,
                       vx: windNow * 80, vy: term * 0.7, size: size, depth: depth, phase: rand(),
                       mass: 0.055 * size, alpha: 0.3 + 0.65 * depth, kind: .snow))
    }

    private func spawnRaindrop(_ s: ScreenInfo, w: Float, h: Float) {
        let depth = 0.4 + 0.6 * rand()
        let vy = 950 + 650 * depth
        let vx = windNow * 430 * (0.6 + 0.4 * depth)
        let drift = vx * (h / vy)
        let pad = min(abs(drift), 2000)
        let x0 = Float(s.rect.minX) - (drift > 0 ? pad : 0)
        spawn(Particle(x: x0 + rand() * (w + pad), y: Float(s.rect.minY) - 20 - rand() * 80,
                       vx: vx, vy: vy, size: 0.8 + depth, depth: depth, phase: rand(),
                       mass: 0.035 + 0.035 * depth, alpha: 0.16 + 0.42 * depth, kind: .rain))
    }

    /// Snow chunks carrying `mass`. Small amounts round stochastically so mass is kept on average
    /// without spawning a flake per cell.
    private func emitChunks(mass: Float, x: Float, y: Float, vx: Float, vy: Float, spread: Float) {
        guard snowCount < Cap.snow + 3000, mass > 0 else { return }
        let unit: Float = 0.3
        var n = Int(mass / unit)
        if rand() < (mass - Float(n) * unit) / unit { n += 1 }
        guard n > 0 else { return }
        let m: Float
        if n > 2 {
            n = 2
            m = mass / 2
        } else {
            m = unit
        }
        for _ in 0..<n {
            spawn(Particle(x: x + (rand() - 0.5) * 3, y: y - rand() * 2,
                           vx: vx + (rand() - 0.5) * spread, vy: vy - rand() * spread * 0.5,
                           size: 2.2 + min(4, m * 3) + rand() * 1.2, depth: 1, phase: rand(),
                           mass: m, alpha: 0.95, kind: .snow))
        }
    }

    private func emitDrops(mass: Float, x: Float, y: Float, vx: Float, vy: Float, spread: Float) {
        guard dropCount < Cap.drops + 1000, mass > 0 else { return }
        let unit: Float = 0.2
        var n = Int(mass / unit)
        if rand() < (mass - Float(n) * unit) / unit { n += 1 }
        guard n > 0 else { return }
        let m: Float
        if n > 2 {
            n = 2
            m = mass / 2
        } else {
            m = unit
        }
        for _ in 0..<n {
            spawn(Particle(x: x + (rand() - 0.5) * 3, y: y,
                           vx: vx + (rand() - 0.5) * spread, vy: vy - rand() * spread * 0.5,
                           size: 1.6 + rand() * 1.2, depth: 1, phase: 0,
                           mass: m, alpha: 0.85, kind: .droplet))
        }
    }

    private func spill(_ loose: [Ledge.Loose], vx: Float, vy: Float) {
        for l in loose {
            if l.snow > 0.02 { emitChunks(mass: l.snow, x: l.x, y: l.y, vx: vx, vy: vy, spread: 40) }
            if l.water > 0.03 { emitDrops(mass: l.water, x: l.x, y: l.y, vx: vx, vy: vy, spread: 40) }
        }
    }

    private func integrate(_ dt: Float) {
        let windSnow = windNow * 80
        let windRain = windNow * 430
        let c = cursor, cv = cursorVel
        let cursorOn = conditions.cursor && cursorKnown
        let reach: Float = 80, reach2 = reach * reach
        let bottom = Float(bounds.maxY) + 40
        let left = Float(bounds.minX) - 2200, right = Float(bounds.maxX) + 2200
        var ns = 0, nr = 0, nd = 0

        particles.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                var p = buf[i]
                if p.dead { continue }
                p.age += dt
                let prevY = p.y

                switch p.kind {
                case .snow:
                    let term = (26 + p.size * 8) * (0.55 + 0.45 * p.depth)
                    p.vy += (term - p.vy) * min(1, dt * 2.2)
                    let flutter = sinf(p.age * (1.1 + p.phase * 0.9) + p.phase * 6.283) * (10 + 18 * p.phase)
                    let tvx = windSnow * (0.5 + 0.5 * p.depth) + flutter
                    p.vx += (tvx - p.vx) * min(1, dt * 1.6)
                case .rain:
                    p.vx += (windRain * (0.6 + 0.4 * p.depth) - p.vx) * min(1, dt * 3)
                case .droplet:
                    p.vy += 1700 * dt
                    p.vx -= p.vx * min(1, dt * 0.8)
                }

                if cursorOn && p.near {
                    let dx = p.x - c.x, dy = p.y - c.y
                    let d2 = dx * dx + dy * dy
                    if p.kind == .rain {
                        if d2 < 14 * 14 {
                            p.dead = true
                            splashOffCursor(p)
                        }
                    } else if d2 < reach2 && d2 > 0.01 {
                        let d = d2.squareRoot()
                        let f = 1 - d / reach
                        let push = f * f * 2200 * dt
                        p.vx += dx / d * push
                        p.vy += dy / d * push
                        let drag = min(1, f * dt * 9)
                        p.vx += (cv.x - p.vx) * drag
                        p.vy += (cv.y - p.vy) * drag
                    }
                }

                if !p.dead {
                    p.x += p.vx * dt
                    p.y += p.vy * dt
                    if p.near, let hit = collide(x: p.x, prevY: prevY, y: p.y) { land(&p, hit) }
                    if p.y > bottom || p.x < left || p.x > right || p.age > 90 { p.dead = true }
                }
                if !p.dead {
                    switch p.kind {
                    case .snow: ns += 1
                    case .rain: nr += 1
                    case .droplet: nd += 1
                    }
                }
                buf[i] = p
            }
        }

        for p in spawned {
            switch p.kind {
            case .snow: ns += 1
            case .rain: nr += 1
            case .droplet: nd += 1
            }
        }
        snowCount = ns
        rainCount = nr
        dropCount = nd
    }

    private func splashOffCursor(_ p: Particle) {
        guard dropCount < Cap.drops else { return }
        for _ in 0..<2 {
            spawn(Particle(x: p.x, y: p.y, vx: (rand() - 0.5) * 260 + cursorVel.x * 0.3,
                           vy: -(80 + rand() * 160), size: 1.3 + rand() * 1.0, depth: 1, phase: 0,
                           mass: 0, alpha: 0.75, kind: .droplet))
        }
    }

    private func land(_ p: inout Particle, _ h: Hit) {
        let ledge = h.ledge, i = h.cell
        switch p.kind {
        case .snow:
            if ledge.water[i] > 1.2 {
                ledge.addWater(at: i, p.mass * 0.6)
                ledge.rippleVel[i] -= 0.1
            } else if p.mass > 0 {
                ledge.addSnow(at: i, p.mass)
            }
        case .rain:
            if ledge.snow[i] > 0.4 {
                ledge.snow[i] = max(0, ledge.snow[i] - p.mass * 0.4)
                ledge.addWater(at: i, p.mass * 0.5)
            } else {
                ledge.addWater(at: i, p.mass)
            }
            ledge.rippleVel[i] -= 0.35 * p.depth
            if dropCount < Cap.drops {
                let n = ledge.water[i] > 0.8 ? 1 : 2
                for _ in 0..<n where rand() < 0.7 {
                    spawn(Particle(x: p.x + (rand() - 0.5) * 2, y: h.y - 1.5,
                                   vx: (rand() - 0.5) * 220 + p.vx * 0.15,
                                   vy: -(110 + rand() * 210) * p.depth,
                                   size: 1.4 + rand() * 1.2, depth: 1, phase: 0,
                                   mass: 0, alpha: 0.75, kind: .droplet))
                }
            }
        case .droplet:
            if p.mass > 0 { ledge.addWater(at: i, p.mass) }
            ledge.rippleVel[i] -= 0.12
        }
        p.dead = true
    }

    /// The cursor ploughs through piles, flinging snow along its path, and stirs puddles.
    private func dig() {
        let speed = simd_length(cursorVel)
        guard speed > 12 else { return }
        let r: Float = 15
        let c = cursor
        let tip = c.y + r * 0.6
        for ledge in ledgeList where ledge.enabled {
            guard c.x > ledge.x - r, c.x < ledge.x + ledge.width + r,
                  c.y > ledge.y - ledge.maxSnow - ledge.maxWater - r, c.y < ledge.y + r else { continue }
            let ia = max(0, Int((c.x - r - ledge.x) / ledge.cw))
            let ib = min(ledge.count - 1, Int((c.x + r - ledge.x) / ledge.cw))
            guard ia <= ib else { continue }
            let k = ledge.cw / Ledge.nominalCell
            for i in ia...ib where ledge.visible[i] {
                let dxn = (ledge.centerX(i) - c.x) / r
                let fall = 1 - dxn * dxn
                if fall <= 0 { continue }
                let top = ledge.y - ledge.snow[i]
                if ledge.snow[i] > 0.05 && tip > top && c.y - r < ledge.y {
                    let take = min(ledge.snow[i], (tip - top) * 0.55 * fall)
                    if take > 0.01 {
                        ledge.snow[i] -= take
                        emitChunks(mass: take * k, x: ledge.centerX(i), y: top - 1,
                                   vx: cursorVel.x * 0.55, vy: min(cursorVel.y * 0.45, 0) - 70, spread: 120)
                    }
                }
                let waterTop = top - ledge.water[i]
                if ledge.water[i] > 0.05 && tip > waterTop && c.y - r < top {
                    ledge.rippleVel[i] += (cursorVel.y * 0.0015 - abs(cursorVel.x) * 0.0012) * fall
                    if speed > 450 && dropCount < Cap.drops && rand() < 0.12 * fall {
                        spawn(Particle(x: ledge.centerX(i), y: waterTop - 1,
                                       vx: cursorVel.x * 0.4 + (rand() - 0.5) * 80, vy: -(120 + rand() * 180),
                                       size: 1.5 + rand(), depth: 1, phase: 0,
                                       mass: 0, alpha: 0.8, kind: .droplet))
                    }
                }
            }
        }
    }

    // MARK: - Ledges

    private func updateLedges(_ dt: Float) {
        let melt: Float, evap: Float
        switch conditions.weather {
        case .clear:
            melt = 0.45
            evap = 0.3
        case .rain:
            melt = 0.9
            evap = 0.03
        case .snow:
            melt = 0
            evap = 0.12
        }
        let k = min(1, dt * 60)
        for ledge in ledgeList {
            if melt > 0 { ledge.melt(rate: melt, dt: dt) }
            ledge.evaporate(rate: evap, dt: dt)
            if ledge.hibernating { continue }
            ledge.relaxSnow()
            ledge.flowWater(k: k)
            ledge.stepRipples()
            if ledge.enabled {
                releaseSpill(ledge)
            } else {
                ledge.spillLeft = 0
                ledge.spillRight = 0
                ledge.dripLeft = 0
                ledge.dripRight = 0
            }
        }
    }

    /// Snow sliding off the ends of a window and water dripping from its corners.
    private func releaseSpill(_ ledge: Ledge) {
        let last = ledge.count - 1
        var budget = 8
        while ledge.spillLeft >= 0.3 && budget > 0 {
            ledge.spillLeft -= 0.3
            budget -= 1
            spawn(Particle(x: ledge.x - 1.5, y: ledge.y - max(1, ledge.snow[0] * 0.6),
                           vx: -12 - rand() * 30, vy: 15, size: 2.4 + rand() * 2, depth: 1, phase: rand(),
                           mass: 0.3, alpha: 0.95, kind: .snow))
        }
        budget = 8
        while ledge.spillRight >= 0.3 && budget > 0 {
            ledge.spillRight -= 0.3
            budget -= 1
            spawn(Particle(x: ledge.x + ledge.width + 1.5, y: ledge.y - max(1, ledge.snow[last] * 0.6),
                           vx: 12 + rand() * 30, vy: 15, size: 2.4 + rand() * 2, depth: 1, phase: rand(),
                           mass: 0.3, alpha: 0.95, kind: .snow))
        }
        budget = 6
        while ledge.dripLeft >= 0.12 && budget > 0 {
            ledge.dripLeft -= 0.12
            budget -= 1
            spawn(Particle(x: ledge.x - 1.2, y: ledge.y + 2, vx: 0, vy: 30, size: 1.8 + rand() * 0.8,
                           depth: 1, phase: 0, mass: 0.12, alpha: 0.85, kind: .droplet))
        }
        budget = 6
        while ledge.dripRight >= 0.12 && budget > 0 {
            ledge.dripRight -= 0.12
            budget -= 1
            spawn(Particle(x: ledge.x + ledge.width + 1.2, y: ledge.y + 2, vx: 0, vy: 30, size: 1.8 + rand() * 0.8,
                           depth: 1, phase: 0, mass: 0.12, alpha: 0.85, kind: .droplet))
        }
    }

    // MARK: - Drawing

    /// Fills `out` with the instances to draw on one screen, back to front.
    func fill(_ out: inout [Instance], for rect: CGRect) {
        out.removeAll(keepingCapacity: true)
        let o = SIMD2<Float>(Float(rect.minX), Float(rect.minY))
        let lo = SIMD2<Float>(o.x - 40, o.y - 80)
        let hi = SIMD2<Float>(o.x + Float(rect.width) + 40, o.y + Float(rect.height) + 40)
        for p in particles where !p.near && !p.dead { appendParticle(p, o, lo, hi, &out) }
        for ledge in ledgeList where ledge.enabled {
            guard ledge.x < hi.x, ledge.x + ledge.width > lo.x,
                  ledge.y > lo.y, ledge.y - ledge.maxSnow - ledge.maxWater < hi.y else { continue }
            appendLedge(ledge, o, lo.x, hi.x, &out)
        }
        for p in particles where p.near && !p.dead { appendParticle(p, o, lo, hi, &out) }
    }

    private func appendParticle(_ p: Particle, _ o: SIMD2<Float>, _ lo: SIMD2<Float>, _ hi: SIMD2<Float>,
                                _ out: inout [Instance]) {
        guard p.x > lo.x, p.x < hi.x, p.y > lo.y, p.y < hi.y else { return }
        let lx = p.x - o.x, ly = p.y - o.y
        switch p.kind {
        case .snow:
            let fade = min(1, p.age * 2.5)
            let soft: Float = p.near ? 0.5 + 0.25 * min(1, p.size / 6) : 0.75
            let t: Float = p.near ? 1 : 0.9
            out.append(Instance(a: SIMD4(lx, ly, p.size, p.size), b: SIMD4(0, 0, soft, 0),
                                color: SIMD4(t * 0.97, t * 0.985, 1, p.alpha * fade)))
        case .rain:
            let sp = max(1, (p.vx * p.vx + p.vy * p.vy).squareRoot())
            let len = 10 + 26 * p.depth
            let ux = p.vx / sp, uy = p.vy / sp
            out.append(Instance(a: SIMD4(lx - ux * len * 0.5, ly - uy * len * 0.5, p.size * 2, len),
                                b: SIMD4(atan2f(-p.vx, p.vy), 1, 0, 0),
                                color: SIMD4(0.78, 0.86, 1.0, p.alpha)))
        case .droplet:
            out.append(Instance(a: SIMD4(lx, ly, p.size, p.size), b: SIMD4(0, 2, 0, 0),
                                color: SIMD4(0.80, 0.89, 1.0, p.alpha)))
        }
    }

    private func appendLedge(_ ledge: Ledge, _ o: SIMD2<Float>, _ minX: Float, _ maxX: Float,
                             _ out: inout [Instance]) {
        let n = ledge.count
        let i0 = max(0, Int((minX - ledge.x) / ledge.cw))
        let i1 = min(n - 1, Int((maxX - ledge.x) / ledge.cw))
        guard i0 <= i1 else { return }

        if waterVis.count < n { waterVis = [Float](repeating: 0, count: n) }
        var anyWater = false
        for i in 0..<n {
            let w = ledge.water[i]
            var v: Float = 0
            if w > 0.02 { v = max(0, w + ledge.ripple[i] * min(1, w * 1.2)) }
            waterVis[i] = v
            if v > 0.04 { anyWater = true }
        }

        let base = ledge.y - o.y
        let visible = ledge.visible, snow = ledge.snow
        let cw = ledge.cw, x0 = ledge.x - o.x

        if anyWater {
            for i in i0...i1 where visible[i] && waterVis[i] > 0.04 {
                let t = snow[i] + waterVis[i]
                let tl = (i > 0 && visible[i - 1]) ? (snow[i - 1] + waterVis[i - 1] + t) * 0.5 : t * 0.7
                let tr = (i < n - 1 && visible[i + 1]) ? (snow[i + 1] + waterVis[i + 1] + t) * 0.5 : t * 0.7
                let xl = x0 + Float(i) * cw, xr = x0 + Float(i + 1) * cw
                out.append(Instance(a: SIMD4(xl, base, xr - xl, 1), b: SIMD4(tl, tr, 0, 1),
                                    color: SIMD4(0.55, 0.72, 0.96, 0.42)))
            }
        }
        for i in i0...i1 where visible[i] && snow[i] > 0.04 {
            let s = snow[i]
            let sl = (i > 0 && visible[i - 1]) ? (snow[i - 1] + s) * 0.5 : s * 0.55
            let sr = (i < n - 1 && visible[i + 1]) ? (snow[i + 1] + s) * 0.5 : s * 0.55
            let xl = x0 + Float(i) * cw, xr = x0 + Float(i + 1) * cw + 0.3
            out.append(Instance(a: SIMD4(xl, base, xr - xl, 0), b: SIMD4(sl, sr, 0, 1),
                                color: SIMD4(1, 1, 1, 0.97)))
        }
    }
}
