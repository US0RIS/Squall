import Foundation

enum Weather: String, CaseIterable {
    case clear, rain, snow

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .rain: return "Rain"
        case .snow: return "Snow"
        }
    }

    /// Filled symbol for the picker and toast.
    var symbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        }
    }

    /// Outline symbol for the menu bar.
    var menuSymbol: String {
        switch self {
        case .clear: return "sun.max"
        case .rain: return "cloud.rain"
        case .snow: return "cloud.snow"
        }
    }

    var next: Weather {
        let all = Weather.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

/// Persisted preferences. Every change is written straight to UserDefaults.
@MainActor
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let weather = "weather"
        static let intensity = "intensity"
        static let wind = "wind"
        static let settle = "settleOnWindows"
        static let cursor = "cursorInteraction"
        static let gusts = "clickGusts"
    }

    var weather: Weather { didSet { UserDefaults.standard.set(weather.rawValue, forKey: Key.weather) } }
    var intensity: Double { didSet { UserDefaults.standard.set(intensity, forKey: Key.intensity) } }
    var wind: Double { didSet { UserDefaults.standard.set(wind, forKey: Key.wind) } }
    var settleOnWindows: Bool { didSet { UserDefaults.standard.set(settleOnWindows, forKey: Key.settle) } }
    var cursorInteraction: Bool { didSet { UserDefaults.standard.set(cursorInteraction, forKey: Key.cursor) } }
    var clickGusts: Bool { didSet { UserDefaults.standard.set(clickGusts, forKey: Key.gusts) } }

    private init() {
        let d = UserDefaults.standard
        weather = Weather(rawValue: d.string(forKey: Key.weather) ?? "") ?? .snow
        intensity = d.object(forKey: Key.intensity) == nil ? 0.55 : d.double(forKey: Key.intensity)
        wind = d.object(forKey: Key.wind) == nil ? 0.1 : d.double(forKey: Key.wind)
        settleOnWindows = d.object(forKey: Key.settle) == nil ? true : d.bool(forKey: Key.settle)
        cursorInteraction = d.object(forKey: Key.cursor) == nil ? true : d.bool(forKey: Key.cursor)
        clickGusts = d.object(forKey: Key.gusts) == nil ? true : d.bool(forKey: Key.gusts)
    }

    var conditions: Conditions {
        Conditions(weather: weather, intensity: Float(intensity), wind: Float(wind),
                   cursor: cursorInteraction, gusts: clickGusts, settle: settleOnWindows)
    }
}
