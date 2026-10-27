import AppKit
import ServiceManagement

/// Borderless panel that can take key (for Esc) without activating the app.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The glass panel that drops from the menu bar: weather picker, intensity, wind, behavior.
@MainActor
final class ControlPanel: NSObject {
    struct Actions {
        var weather: (Weather) -> Void
        var changed: () -> Void
        var shakeOff: () -> Void
    }

    static let width: CGFloat = 300
    private static let inner: CGFloat = 268

    private let panel: FloatingPanel
    private let picker = WeatherPicker()
    private let intensitySlider = NSSlider(value: 0.55, minValue: 0.05, maxValue: 1, target: nil, action: nil)
    private let windSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let settleSwitch = NSSwitch()
    private let cursorSwitch = NSSwitch()
    private let gustSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()
    private let actions: Actions
    private var outsideMonitor: Any?

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0.05 }

    init(actions: Actions) {
        self.actions = actions
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.hide() }

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Header
        let icon = NSImageView(image: Logo.image(size: 22))
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let header = UI.row([icon, UI.label("Squall", size: 14, weight: .semibold), UI.flex(),
                             UI.label("v\(UI.version)", size: 11, color: .tertiaryLabelColor)])
        header.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true

        // Picker
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        picker.heightAnchor.constraint(equalToConstant: 84).isActive = true
        picker.onSelect = { [weak self] weather in self?.actions.weather(weather) }

        // Sliders
        windSlider.numberOfTickMarks = 3
        windSlider.allowsTickMarkValuesOnly = false
        let intensityRow = sliderRow("drop.fill", "Intensity", intensitySlider, #selector(intensityChanged(_:)))
        let windRow = sliderRow("wind", "Wind", windSlider, #selector(windChanged(_:)))

        // Behavior
        let settleRow = switchRow("Settle on windows", settleSwitch, #selector(settleChanged(_:)))
        let cursorRow = switchRow("Cursor pushes weather", cursorSwitch, #selector(cursorChanged(_:)))
        let gustRow = switchRow("Clicks make gusts", gustSwitch, #selector(gustChanged(_:)))
        let loginRow = switchRow("Launch at login", loginSwitch, #selector(loginChanged(_:)))

        // Footer
        let shake = NSButton(title: "Shake Off", image: UI.image("wind.snow", size: 11, weight: .medium) ?? NSImage(),
                             target: self, action: #selector(shakeOffPressed))
        shake.imagePosition = .imageLeading
        shake.bezelStyle = .rounded
        shake.controlSize = .small
        shake.toolTip = "Knock everything off your windows"
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        let footer = UI.row([shake, UI.flex(), quit])
        footer.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true

        let stack = UI.column([
            header, picker,
            UI.separator(width: Self.inner), intensityRow, windRow,
            UI.separator(width: Self.inner), settleRow, cursorRow, gustRow, loginRow,
            UI.separator(width: Self.inner), footer,
        ], spacing: 10)
        stack.setCustomSpacing(14, after: header)
        stack.setCustomSpacing(14, after: picker)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        panel.contentView = bg
        let size = stack.fittingSize
        panel.setContentSize(NSSize(width: Self.width, height: size.height))
    }

    private func sliderRow(_ symbol: String, _ title: String, _ slider: NSSlider, _ action: Selector) -> NSView {
        slider.target = self
        slider.action = action
        slider.controlSize = .small
        slider.isContinuous = true
        let img = NSImageView(image: UI.image(symbol, size: 12, weight: .medium) ?? NSImage())
        img.contentTintColor = .secondaryLabelColor
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = UI.label(title, size: 12, color: .secondaryLabelColor)
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        slider.widthAnchor.constraint(equalToConstant: Self.inner - 18 - 62 - 16).isActive = true
        return UI.row([img, label, slider])
    }

    private func switchRow(_ title: String, _ toggle: NSSwitch, _ action: Selector) -> NSView {
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = action
        let row = UI.row([UI.label(title, size: 12.5), UI.flex(), toggle])
        row.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true
        return row
    }

    // MARK: - Showing

    func toggle(below button: NSStatusBarButton?) {
        if isVisible { hide() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton?) {
        syncFromSettings(animated: false)
        guard let buttonWindow = button?.window else { return }
        let item = buttonWindow.frame
        let size = panel.frame.size
        var x = item.midX - size.width / 2
        if let vf = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        }
        let y = item.minY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y + 8))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: x, y: y))
        }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func hide() {
        if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
        guard panel.isVisible else { return }
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if p.alphaValue < 0.05 { p.orderOut(nil) }
            }
        })
    }

    func syncFromSettings(animated: Bool) {
        let s = Settings.shared
        picker.setSelection(s.weather, animated: animated)
        intensitySlider.doubleValue = s.intensity
        windSlider.doubleValue = s.wind
        settleSwitch.state = s.settleOnWindows ? .on : .off
        cursorSwitch.state = s.cursorInteraction ? .on : .off
        gustSwitch.state = s.clickGusts ? .on : .off
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func intensityChanged(_ sender: NSSlider) {
        Settings.shared.intensity = sender.doubleValue
        actions.changed()
    }

    @objc private func windChanged(_ sender: NSSlider) {
        // Snap to calm near the middle.
        var v = sender.doubleValue
        if abs(v) < 0.06 {
            v = 0
            sender.doubleValue = 0
        }
        Settings.shared.wind = v
        actions.changed()
    }

    @objc private func settleChanged(_ sender: NSSwitch) {
        Settings.shared.settleOnWindows = sender.state == .on
        actions.changed()
    }

    @objc private func cursorChanged(_ sender: NSSwitch) {
        Settings.shared.cursorInteraction = sender.state == .on
        actions.changed()
    }

    @objc private func gustChanged(_ sender: NSSwitch) {
        Settings.shared.clickGusts = sender.state == .on
        actions.changed()
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func shakeOffPressed() { actions.shakeOff() }

    @objc private func quitPressed() { NSApp.terminate(nil) }
}
