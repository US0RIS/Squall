import AppKit

/// A small glass bubble near the top of the active screen, used when the weather is changed
/// from the menu bar without opening the panel. It never takes focus.
@MainActor
final class Toast {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTimer: Timer?

    func show(_ text: String, symbol: String, tint: NSColor) {
        let p = panel ?? makePanel()
        panel = p
        label.stringValue = text
        icon.image = UI.image(symbol, size: 15, weight: .semibold)
        icon.contentTintColor = tint

        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 160, height: 40)
        let width = max(size.width, 140)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrame(NSRect(x: vf.midX - width / 2, y: vf.maxY - size.height - 14, width: width, height: size.height),
                       display: true)
        }
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if p.alphaValue < 0.05 { p.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.topAnchor.constraint(equalTo: bg.topAnchor),
            row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
        ])
        p.contentView = bg
        return p
    }
}
