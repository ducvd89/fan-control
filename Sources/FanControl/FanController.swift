import AppKit
import Foundation
import SMCKit

/// Polls sensors, evaluates the active profile's curve and drives the helper.
@MainActor
@Observable
final class FanController {
    enum HelperState: Equatable { case unknown, missing, ok, error(String) }

    let store: ProfileStore
    private let smc: SMC?
    private let helper = HelperClient()
    private let ioQueue = DispatchQueue(label: "fancontrol.sensors")
    private var timer: Timer?
    private var temperatureKeys: [String] = []

    // Live readings
    private(set) var sensors: [TemperatureSensor] = []
    private(set) var fans: [FanReading] = []
    private(set) var hottest: TemperatureSensor?
    private(set) var smoothedTemp: Double?
    private(set) var commandedRPM: [Int: Double] = [:]
    private(set) var currentLevel: Double?
    private(set) var helperState: HelperState = .unknown
    let smcError: String?

    /// Sensor groups whose maximum drives the curve.
    var hotGroups: Set<String> {
        didSet { UserDefaults.standard.set(Array(hotGroups), forKey: "hotGroups.v1"); recomputeHottest() }
    }
    /// How fast the fans may slow down, in rpm per second (they always speed up immediately).
    var rampDownPerSecond: Double {
        didSet { UserDefaults.standard.set(rampDownPerSecond, forKey: "rampDown.v1") }
    }
    let interval: TimeInterval = 2

    var averageRPM: Double? {
        fans.isEmpty ? nil : fans.map(\.actual).reduce(0, +) / Double(fans.count)
    }

    init(store: ProfileStore) {
        self.store = store
        let groups = UserDefaults.standard.stringArray(forKey: "hotGroups.v1")
        hotGroups = groups.map(Set.init) ?? SensorCatalog.defaultHotGroups
        let ramp = UserDefaults.standard.double(forKey: "rampDown.v1")
        rampDownPerSecond = ramp > 0 ? ramp : 150
        do {
            smc = try SMC()
            smcError = nil
        } catch {
            smc = nil
            smcError = "\(error)"
        }
    }

    func start() {
        guard let smc else { return }
        ioQueue.async { [weak self] in
            let keys = smc.temperatureKeys()
            DispatchQueue.main.async {
                self?.temperatureKeys = keys
                self?.tick()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
        checkHelper()

        // Hand the fans back to macOS before sleep; the helper does the same on its side.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    /// True between sleep and wake; the curve is not applied while set.
    private(set) var asleep = false

    private func systemWillSleep() {
        asleep = true
        commandedRPM = [:]
        currentLevel = nil
        if helper.isInstalled { helper.sendAndWait("AUTO") }
    }

    private func systemDidWake() {
        asleep = false
        smoothedTemp = nil          // start fresh: temperatures changed while we were asleep
        tick()
    }

    func checkHelper() {
        guard helper.isInstalled else { helperState = .missing; return }
        helper.send("PING") { [weak self] reply in
            MainActor.assumeIsolated {
                self?.helperState = reply == "OK" ? .ok : .missing
            }
        }
    }

    func activate(_ id: UUID) {
        guard store.activeID != id else { return }
        store.activeID = id
        commandedRPM = [:]
        if store.active.isSystem { returnToAuto() } else { tick() }
    }

    func returnToAuto() {
        commandedRPM = [:]
        currentLevel = nil
        helper.send("AUTO")
    }

    /// Called on quit so fans never stay pinned.
    func shutdown() {
        timer?.invalidate()
        if helper.isInstalled { helper.sendAndWait("AUTO") }
    }

    // MARK: Loop

    private func tick() {
        guard let smc else { return }
        let keys = temperatureKeys
        ioQueue.async { [weak self] in
            let s = smc.temperatures(keys: keys)
            let f = smc.fans()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(sensors: s, fans: f) }
            }
        }
    }

    private func recomputeHottest() {
        let pool = sensors.filter { hotGroups.contains($0.group) }
        hottest = (pool.isEmpty ? sensors : pool).max { $0.value < $1.value }
    }

    private func apply(sensors: [TemperatureSensor], fans: [FanReading]) {
        self.sensors = sensors
        self.fans = fans
        recomputeHottest()
        guard let t = hottest?.value else { return }

        // Smooth the input: react quickly to heat, slowly to cooling, so the fans don't hunt.
        let prev = smoothedTemp ?? t
        let alpha = t > prev ? 0.5 : 0.15
        smoothedTemp = prev + alpha * (t - prev)

        let profile = store.active
        guard !profile.isSystem, !asleep, let temp = smoothedTemp else { currentLevel = nil; return }
        guard helperState == .ok || helperState == .unknown else {
            if helper.isInstalled { checkHelper() }
            return
        }

        let level = profile.level(at: temp)
        currentLevel = level
        let maxDrop = rampDownPerSecond * interval
        for fan in fans {
            var want = level <= 0 ? 0 : fan.min + (fan.max - fan.min) * min(level, 100) / 100
            if let last = commandedRPM[fan.id], want < last {
                // Ease down; when the curve says "off", glide to min first, then stop.
                let eased = last - maxDrop
                want = want == 0 ? (eased <= fan.min ? 0 : eased) : max(want, eased)
            }
            commandedRPM[fan.id] = want
            helper.send("SET \(fan.id) \(Int(want.rounded()))") { [weak self] reply in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if reply == nil { self.helperState = self.helper.isInstalled ? .error("helper not responding") : .missing }
                    else if let r = reply, r.hasPrefix("ERR") { self.helperState = .error(String(r.dropFirst(4))) }
                    else { self.helperState = .ok }
                }
            }
        }
    }
}
