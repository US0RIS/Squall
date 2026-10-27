import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine!
    private var statusItem: NSStatusItem!
    private var panel: ControlPanel!
    private var toast: Toast!

    private var settings: Settings { Settings.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = Engine()
        toast = Toast()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Squall — click for controls, right-click to change the weather"
        }

        panel = ControlPanel(actions: .init(
            weather: { [weak self] weather in self?.setWeather(weather, fromMenuBar: false) },
            changed: { [weak self] in self?.apply() },
            shakeOff: { [weak self] in self?.engine.shakeOff() }
        ))

        updateGlyph()
        apply()
        engine.start()

        if !engine.isRendering {
            let alert = NSAlert()
            alert.messageText = "Squall can't draw on this Mac"
            alert.informativeText = "Metal isn't available, so the weather overlay can't run."
            alert.runModal()
        }
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.hide()
            setWeather(settings.weather.next, fromMenuBar: true)
        } else {
            panel.toggle(below: statusItem.button)
        }
    }

    private func setWeather(_ weather: Weather, fromMenuBar: Bool) {
        settings.weather = weather
        apply()
        updateGlyph()
        if fromMenuBar {
            panel.syncFromSettings(animated: false)
            toast.show(weather.title, symbol: weather.symbol, tint: weather.tint)
        }
    }

    private func apply() {
        engine.conditions = settings.conditions
    }

    private func updateGlyph() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: settings.weather.menuSymbol, accessibilityDescription: "Squall")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
    }
}
