import AppKit

// Build-time hook: `Squall --render-iconset <dir>` writes the app icon PNGs and exits.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-iconset"), i + 1 < args.count {
    do {
        try Logo.renderIconset(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write("icon render failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Menu-bar agent: no Dock icon.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()   // never returns, so `delegate` stays alive
}
