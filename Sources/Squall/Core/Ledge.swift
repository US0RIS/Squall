import Foundation

/// A horizontal surface weather settles on: the top edge of a window, or the bottom of a screen.
/// Coordinates are global Quartz points (origin at the top-left of the primary display, y grows
/// downward), so `y` is the edge line and snow and water heights rise from it toward smaller y.
final class Ledge {
    /// Nominal cell width in points. Masses are expressed as heights over a cell this wide.
    static let nominalCell: Float = 3

    let id: Int
    let isFloor: Bool
    private(set) var x: Float
    private(set) var y: Float
    private(set) var width: Float
    private(set) var cw: Float

    var snow: [Float]
    var water: [Float]
    /// Zero-mean surface displacement of the water, purely visual (ripples and slosh).
    var ripple: [Float]
    var rippleVel: [Float]
    /// Cells not covered by a window in front.
    var visible: [Bool]

    /// Collides and draws only when enabled (edge not under the menu bar, settling allowed…).
    var enabled = true
    /// The window still exists but is off screen (minimized, another Space): keep its load hidden.
    var hibernating = false
    var vx: Float = 0
    var vy: Float = 0

    let maxSnow: Float
    let maxWater: Float

    /// Mass waiting to fall off each end (snow) or run off it (water).
    var spillLeft: Float = 0
    var spillRight: Float = 0
    var dripLeft: Float = 0
    var dripRight: Float = 0

    var count: Int { snow.count }

    init(id: Int, isFloor: Bool, x: Float, y: Float, width: Float) {
        let w = max(width, 1)
        let n = Ledge.cellCount(for: w)
        self.id = id
        self.isFloor = isFloor
        self.x = x
        self.y = y
        self.width = w
        self.cw = w / Float(n)
        snow = [Float](repeating: 0, count: n)
        water = [Float](repeating: 0, count: n)
        ripple = [Float](repeating: 0, count: n)
        rippleVel = [Float](repeating: 0, count: n)
        visible = [Bool](repeating: true, count: n)
        maxSnow = isFloor ? 24 : 42
        maxWater = isFloor ? 8 : 4.5
    }

    static func cellCount(for width: Float) -> Int { max(1, Int((width / nominalCell).rounded())) }

    func cell(at gx: Float) -> Int? {
        let f = (gx - x) / cw
        guard f >= 0, f < Float(count) else { return nil }
        return Int(f)
    }

    func centerX(_ i: Int) -> Float { x + (Float(i) + 0.5) * cw }
    func surface(_ i: Int) -> Float { y - snow[i] - water[i] }

    var totalSnow: Float { snow.reduce(0, +) }
    var totalWater: Float { water.reduce(0, +) }
    var isEmpty: Bool { totalSnow + totalWater < 0.05 }

    func move(x nx: Float, y ny: Float) {
        x = nx
        y = ny
    }

    /// Material that left the ledge, in nominal-cell mass units, at its last position.
    struct Loose {
        var x: Float
        var y: Float
        var snow: Float
        var water: Float
    }

    /// Changes the geometry, keeping every cell at its absolute screen position (a window resized
    /// from the right keeps the snow on its left). Cells that no longer lie on the ledge are returned
    /// so the caller can let them fall.
    @discardableResult
    func reshape(x nx: Float, y ny: Float, width nw: Float) -> [Loose] {
        let w = max(nw, 1)
        let n = Ledge.cellCount(for: w)
        let ncw = w / Float(n)
        var ns = [Float](repeating: 0, count: n)
        var nwa = [Float](repeating: 0, count: n)
        var nr = [Float](repeating: 0, count: n)
        var loose: [Loose] = []
        let scale = cw / ncw
        let k = cw / Ledge.nominalCell
        for i in 0..<count {
            let gx = centerX(i)
            let f = (gx - nx) / ncw
            if f >= 0 && f < Float(n) {
                let j = Int(f)
                ns[j] += snow[i] * scale
                nwa[j] += water[i] * scale
                nr[j] = ripple[i]
            } else if snow[i] > 0.01 || water[i] > 0.01 {
                loose.append(Loose(x: gx, y: y - snow[i] - water[i], snow: snow[i] * k, water: water[i] * k))
            }
        }
        x = nx
        y = ny
        width = w
        cw = ncw
        snow = ns
        water = nwa
        ripple = nr
        rippleVel = [Float](repeating: 0, count: n)
        visible = [Bool](repeating: true, count: n)
        return loose
    }

    /// Empties the ledge and returns everything that was on it.
    func takeAll() -> [Loose] {
        var out: [Loose] = []
        let k = cw / Ledge.nominalCell
        for i in 0..<count where snow[i] > 0.01 || water[i] > 0.01 {
            out.append(Loose(x: centerX(i), y: y - snow[i] - water[i], snow: snow[i] * k, water: water[i] * k))
        }
        clear()
        return out
    }

    func clear() {
        for i in 0..<count {
            snow[i] = 0
            water[i] = 0
            ripple[i] = 0
            rippleVel[i] = 0
        }
        spillLeft = 0
        spillRight = 0
        dripLeft = 0
        dripRight = 0
    }

    /// Adds snow centered on a cell with a small spread, so single flakes build smooth drifts.
    func addSnow(at i: Int, _ mass: Float) {
        let h = mass * Ledge.nominalCell / cw
        let n = count
        snow[i] += h * 0.5
        snow[i > 0 ? i - 1 : i] += h * 0.25
        snow[i < n - 1 ? i + 1 : i] += h * 0.25
    }

    func addWater(at i: Int, _ mass: Float) {
        water[i] += mass * Ledge.nominalCell / cw
    }

    /// Angle of repose: slopes steeper than about 48° slide. On a window, snow piled past the lip of
    /// either end falls off; a screen floor has walls.
    func relaxSnow() {
        let n = count
        let step = cw * 1.15
        for _ in 0..<2 {
            if n > 1 {
                for i in 0..<(n - 1) {
                    let d = snow[i] - snow[i + 1]
                    if d > step {
                        let m = (d - step) * 0.25
                        snow[i] -= m
                        snow[i + 1] += m
                    } else if d < -step {
                        let m = (-d - step) * 0.25
                        snow[i + 1] -= m
                        snow[i] += m
                    }
                }
            }
            if !isFloor {
                let lip = step * 1.4
                if snow[0] > lip {
                    let m = (snow[0] - lip) * 0.3
                    snow[0] -= m
                    spillLeft += m
                }
                if snow[n - 1] > lip {
                    let m = (snow[n - 1] - lip) * 0.3
                    snow[n - 1] -= m
                    spillRight += m
                }
            }
        }
        for i in 0..<n where snow[i] > maxSnow {
            let excess = snow[i] - maxSnow
            snow[i] = maxSnow
            if isFloor { continue }   // the floor just packs down
            if i < n / 2 { spillLeft += excess } else { spillRight += excess }
        }
    }

    /// Water levels out along the ledge and, on a window, runs off both ends as drips.
    /// `k` scales the per-frame rates (1 at 60 fps).
    func flowWater(k: Float) {
        let n = count
        let rate = 0.22 * min(1, k)
        if n > 1 {
            for _ in 0..<3 {
                for i in 0..<(n - 1) {
                    let f = (water[i] - water[i + 1]) * rate
                    water[i] -= f
                    water[i + 1] += f
                }
            }
        }
        if !isFloor {
            let film: Float = 0.12
            let drain = 0.12 * min(1, k)
            if water[0] > film {
                let m = (water[0] - film) * drain
                water[0] -= m
                dripLeft += m
            }
            if water[n - 1] > film {
                let m = (water[n - 1] - film) * drain
                water[n - 1] -= m
                dripRight += m
            }
        }
        for i in 0..<n where water[i] > maxWater {
            let excess = water[i] - maxWater
            water[i] = maxWater
            if isFloor { continue }
            if i < n / 2 { dripLeft += excess } else { dripRight += excess }
        }
    }

    /// 1-D wave equation on the water surface.
    func stepRipples() {
        let n = count
        guard n > 2 else { return }
        for i in 0..<n {
            let l = i > 0 ? ripple[i - 1] : ripple[i]
            let r = i < n - 1 ? ripple[i + 1] : ripple[i]
            rippleVel[i] += 0.4 * (l + r - 2 * ripple[i])
        }
        for i in 0..<n {
            rippleVel[i] = rippleVel[i] * 0.965 - ripple[i] * 0.004
            ripple[i] = max(-3, min(3, ripple[i] + rippleVel[i]))
        }
    }

    func melt(rate: Float, dt: Float) {
        let d = rate * dt
        for i in 0..<count where snow[i] > 0 {
            let m = min(snow[i], d)
            snow[i] -= m
            water[i] += m * 0.7
        }
    }

    func evaporate(rate: Float, dt: Float) {
        let d = rate * dt
        for i in 0..<count where water[i] > 0 {
            water[i] = max(0, water[i] - d)
        }
    }
}
