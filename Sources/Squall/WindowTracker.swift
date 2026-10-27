import AppKit

/// An ordinary on-screen window, in global Quartz coordinates.
struct TrackedWindow {
    let id: Int
    let rect: CGRect
}

/// Reads window geometry from the window server. Bounds are available without Screen Recording
/// permission, so Squall needs no permissions at all.
enum WindowTracker {
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Normal-layer windows on screen, front to back.
    static func onScreen() -> [TrackedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [TrackedWindow] = []
        out.reserveCapacity(list.count)
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, Int32(pid) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            if rect.width < 80 || rect.height < 30 { continue }
            out.append(TrackedWindow(id: number, rect: rect))
        }
        return out
    }

    /// Every window that still exists, on screen or not (minimized, other Spaces).
    static func allWindowIDs() -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<Int>()
        for info in list {
            if let number = info[kCGWindowNumber as String] as? Int { ids.insert(number) }
        }
        return ids
    }
}
