import Foundation

public struct FanReading: Sendable, Identifiable, Equatable {
    public let id: Int
    public let actual: Double
    public let min: Double
    public let max: Double
    public let target: Double?
    public let manual: Bool
}

public struct TemperatureSensor: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let value: Double
    public var group: String { SensorCatalog.group(for: key) }
}

/// Rough grouping of Apple SMC temperature keys. The exact set differs per chip,
/// so we classify by prefix instead of hard-coding a per-model table.
public enum SensorCatalog {
    public static func group(for key: String) -> String {
        let p = String(key.prefix(2))
        switch p {
        case "Tp", "Te", "TC", "Tc", "Ts": return "CPU"
        case "Tg", "TG": return "GPU"
        case "Tm", "TM": return "Memory"
        case "TB", "Tb": return "Battery"
        case "TW", "Tw": return "Wireless"
        case "TH", "TN", "TS": return "Storage"
        case "Ta", "TA", "Tf": return "Ambient"
        default: return "Other"
        }
    }

    /// Groups whose maximum is used as "hottest" by default.
    public static let defaultHotGroups: Set<String> = ["CPU", "GPU"]
}

extension SMC {
    public func fanCount() -> Int {
        Int(readNumber("FNum") ?? 0)
    }

    private func modeKey(_ fan: Int) -> String? {
        if hasKey("F\(fan)Md") { return "F\(fan)Md" }
        if hasKey("F\(fan)md") { return "F\(fan)md" }
        return nil
    }

    public func fans() -> [FanReading] {
        (0..<fanCount()).map { i in
            let mode = modeKey(i).flatMap { readNumber($0) } ?? 0
            return FanReading(
                id: i,
                actual: readNumber("F\(i)Ac") ?? 0,
                min: readNumber("F\(i)Mn") ?? 0,
                max: readNumber("F\(i)Mx") ?? 0,
                target: readNumber("F\(i)Tg"),
                manual: mode == 1
            )
        }
    }

    /// All `T***` keys that decode to a plausible temperature.
    public func temperatureKeys() -> [String] {
        allKeys().filter { key in
            guard key.hasPrefix("T"), let v = readNumber(key) else { return false }
            return v > 5 && v < 130
        }
    }

    public func temperatures(keys: [String]) -> [TemperatureSensor] {
        keys.compactMap { k in
            guard let v = readNumber(k), v > 5, v < 130 else { return nil }
            return TemperatureSensor(key: k, value: v)
        }
    }

    // MARK: Writing (root only)

    /// Puts a fan into manual mode and sets its target speed.
    /// Apple Silicon firmware on newer chips needs the `Ftst` unlock first, and
    /// thermalmonitord may hold the fan for a moment, so the mode write is retried.
    public func setFan(_ fan: Int, rpm: Double) throws {
        guard let mk = modeKey(fan) else {
            try setFanIntel(fan, rpm: rpm)
            return
        }
        if readNumber(mk) != 1 {
            if hasKey("Ftst") { try? write("Ftst", number: 1) }
            var lastError: Error?
            for _ in 0..<30 {
                do {
                    try write(mk, number: 1)
                    if readNumber(mk) == 1 { lastError = nil; break }
                } catch { lastError = error }
                usleep(100_000)
            }
            if let lastError { throw lastError }
        }
        try write("F\(fan)Tg", number: rpm)
    }

    public func setFanAuto(_ fan: Int) throws {
        if let mk = modeKey(fan) {
            try write(mk, number: 0)
        } else if hasKey("FS! ") {
            let mask = UInt16(readNumber("FS! ") ?? 0) & ~(1 << UInt16(fan))
            try write("FS! ", bytes: [UInt8(mask >> 8), UInt8(mask & 0xff)])
        }
    }

    /// Returns every fan to system control and re-locks the firmware.
    public func setAllAuto() {
        for i in 0..<fanCount() { try? setFanAuto(i) }
        if hasKey("Ftst") { try? write("Ftst", number: 0) }
    }

    private func setFanIntel(_ fan: Int, rpm: Double) throws {
        let mask = UInt16(readNumber("FS! ") ?? 0) | (1 << UInt16(fan))
        try write("FS! ", bytes: [UInt8(mask >> 8), UInt8(mask & 0xff)])
        try write("F\(fan)Tg", number: rpm)
    }
}
