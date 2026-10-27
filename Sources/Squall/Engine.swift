import AppKit
import QuartzCore

/// Runs the weather: one display-linked loop that polls window geometry, steps the simulation
/// and redraws an overlay on every screen. Stops itself when the sky is clear and nothing is left.
@MainActor
final class Engine: NSObject {
    private let sim = Simulation()
    private let renderer: Renderer?
    private var overlays: [Int: Overlay] = [:]
    private var screens: [ScreenInfo] = []
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var pollCarry: Double = 1
    private var clock: Float = 0
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    var isRendering: Bool { renderer != nil }

    var conditions: Conditions {
        get { sim.conditions }
        set {
            sim.conditions = newValue
            wake()
        }
    }

    override init() {
        renderer = Renderer()
        super.init()
    }

    func start() {
        rebuildScreens()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollCarry = 1
                self?.wake()
            }
        })
        // Watching clicks in other apps needs no permission (only key events do).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }
        wake()
    }

    func shakeOff() {
        sim.shakeOff()
        wake()
    }

    private func clicked() {
        guard sim.conditions.gusts else { return }
        sim.gust(at: Engine.mouseQuartz())
        wake()
    }

    private func screensChanged() {
        rebuildScreens()
        link?.invalidate()
        link = nil
        pollCarry = 1
        wake()
    }

    private func rebuildScreens() {
        let all = NSScreen.screens
        guard let primary = all.first else { return }
        let primaryHeight = primary.frame.height
        var infos: [ScreenInfo] = []
        var keep = Set<Int>()
        for screen in all {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.intValue
            let f = screen.frame
            let rectQ = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            infos.append(ScreenInfo(id: id, rect: rectQ, visibleTop: primaryHeight - screen.visibleFrame.maxY))
            keep.insert(id)
            guard let renderer else { continue }
            if let overlay = overlays[id] {
                overlay.reposition(screen: screen, rectQ: rectQ)
            } else {
                overlays[id] = Overlay(screen: screen, displayID: id, rectQ: rectQ, renderer: renderer)
            }
        }
        for id in Array(overlays.keys) where !keep.contains(id) {
            overlays[id]?.close()
            overlays[id] = nil
        }
        screens = infos
    }

    static func mouseQuartz() -> CGPoint {
        let m = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }

    func wake() {
        guard link == nil, renderer != nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        var dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        dt = min(max(dt, 1.0 / 240), 1.0 / 20)
        lastTimestamp = now
        clock += Float(dt)

        // Window geometry at up to 60 Hz is plenty, and keeps the window-server queries cheap.
        pollCarry += dt
        var windows: [TrackedWindow]?
        if pollCarry >= 1.0 / 60 - 0.002 {
            pollCarry = 0
            windows = WindowTracker.onScreen()
        }

        sim.step(dt: Float(dt), windows: windows, screens: screens, cursor: Engine.mouseQuartz())
        for overlay in overlays.values {
            sim.fill(&overlay.instances, for: overlay.rectQ)
            overlay.time = clock
            overlay.render()
        }
        if sim.isIdle {
            link?.invalidate()
            link = nil
        }
    }
}
