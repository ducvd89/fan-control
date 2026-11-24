import Foundation

struct CurvePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Temperature in °C.
    var temp: Double
    /// Fan level, 0–100. 0 lets the fan stop; 1–100 maps onto the fan's min…max rpm.
    var percent: Double
}

struct FanProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// When true the profile hands the fans back to macOS and ignores the curve.
    var isSystem: Bool = false
    var points: [CurvePoint]

    static let tempRange: ClosedRange<Double> = 20...110

    /// Linear interpolation along the curve; flat beyond the first and last point.
    func level(at temp: Double) -> Double {
        let pts = points.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for (a, b) in zip(pts, pts.dropFirst()) where temp <= b.temp {
            let t = (temp - a.temp) / max(b.temp - a.temp, 0.001)
            return a.percent + t * (b.percent - a.percent)
        }
        return last.percent
    }

    static func curve(_ pairs: [(Double, Double)]) -> [CurvePoint] {
        pairs.map { CurvePoint(temp: $0.0, percent: $0.1) }
    }

    static let defaults: [FanProfile] = [
        FanProfile(name: "System Auto", isSystem: true, points: []),
        FanProfile(name: "Silent", points: curve([(50, 0), (65, 1), (80, 30), (95, 70), (100, 100)])),
        FanProfile(name: "Balanced", points: curve([(45, 0), (55, 10), (70, 40), (85, 75), (95, 100)])),
        FanProfile(name: "Performance", points: curve([(35, 15), (50, 35), (65, 60), (80, 90), (88, 100)])),
        FanProfile(name: "Full Blast", points: curve([(20, 100), (110, 100)])),
    ]
}

/// Persists profiles and the active selection in UserDefaults.
@Observable
final class ProfileStore {
    var profiles: [FanProfile] { didSet { save() } }
    var activeID: UUID { didSet { UserDefaults.standard.set(activeID.uuidString, forKey: Keys.active) } }

    private enum Keys {
        static let profiles = "profiles.v1"
        static let active = "activeProfile.v1"
    }

    init() {
        let d = UserDefaults.standard
        let loaded = d.data(forKey: Keys.profiles).flatMap { try? JSONDecoder().decode([FanProfile].self, from: $0) }
        let list = (loaded?.isEmpty == false ? loaded! : FanProfile.defaults)
        profiles = list
        activeID = d.string(forKey: Keys.active).flatMap(UUID.init).flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
    }

    var active: FanProfile { profiles.first { $0.id == activeID } ?? profiles[0] }

    func binding(for id: UUID) -> Int? { profiles.firstIndex { $0.id == id } }

    func add(copying source: FanProfile? = nil) -> UUID {
        var p = source ?? FanProfile(name: "Custom", points: FanProfile.curve([(40, 0), (60, 30), (80, 70), (95, 100)]))
        p.id = UUID()
        p.isSystem = false
        if p.points.isEmpty { p.points = FanProfile.curve([(40, 0), (60, 30), (80, 70), (95, 100)]) }
        p.points = p.points.map { CurvePoint(temp: $0.temp, percent: $0.percent) }
        p.name = source.map { "\($0.name) Copy" } ?? "Custom"
        profiles.append(p)
        return p.id
    }

    func delete(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles[0].id }
    }

    func move(from: IndexSet, to: Int) { profiles.move(fromOffsets: from, toOffset: to) }

    func resetToDefaults() {
        profiles = FanProfile.defaults
        activeID = profiles[0].id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Keys.profiles)
        }
    }
}
