import Foundation
import IOKit.pwr_mgt
import SMCKit

// Privileged fan helper. Runs as root under launchd and accepts line commands on a
// Unix socket. It holds no curve logic: the app sends target speeds, and the helper
// returns every fan to automatic control whenever the app goes quiet or disconnects.
//
// Protocol (one line per request, one line per reply):
//   PING            -> OK
//   SET <fan> <rpm> -> OK | ERR <reason>
//   AUTO [fan]      -> OK
//
// Debug: `FanControlHelper --list` prints sensors and fans (works without root).

let socketPath = "/var/run/fancontrol.sock"
let watchdogSeconds: TimeInterval = 20

setvbuf(stdout, nil, _IOLBF, 0)

let smc: SMC
do { smc = try SMC() } catch {
    FileHandle.standardError.write("SMC open failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if CommandLine.arguments.contains("--list") {
    let keys = smc.temperatureKeys()
    for s in smc.temperatures(keys: keys).sorted(by: { $0.value > $1.value }) {
        print(String(format: "%@  %-8@ %6.1f °C", s.key, s.group, s.value))
    }
    for f in smc.fans() {
        print("Fan \(f.id): \(Int(f.actual)) rpm  (min \(Int(f.min)), max \(Int(f.max)), target \(f.target.map { String(Int($0)) } ?? "-"), manual \(f.manual))")
    }
    for k in ["FNum", "Ftst", "F0Md", "F0md", "F0Tg", "F0Ac", "FS! "] {
        if let v = try? smc.read(k) { print("\(k) type='\(v.info.type)' size=\(v.info.size) value=\(v.number.map { String($0) } ?? "?")") }
    }
    exit(0)
}

guard getuid() == 0 else {
    FileHandle.standardError.write("FanControlHelper must run as root\n".data(using: .utf8)!)
    exit(1)
}

let queue = DispatchQueue(label: "fancontrol.helper")
var anyManual = false
var lastCommand = Date()
var clients: [Int32: DispatchSourceRead] = [:]
var buffers: [Int32: Data] = [:]

var systemSleeping = false

func log(_ s: String) { print("[\(Date())] \(s)") }

func restoreAuto(_ reason: String) {
    guard anyManual else { return }
    smc.setAllAuto()
    anyManual = false
    log("fans returned to auto (\(reason))")
}

func handle(_ line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first?.uppercased() else { return "ERR empty" }
    lastCommand = Date()
    switch cmd {
    case "PING":
        return "OK"
    case "SET":
        guard parts.count == 3, let fan = Int(parts[1]), let rpm = Double(parts[2]) else { return "ERR usage: SET <fan> <rpm>" }
        guard fan >= 0, fan < smc.fanCount() else { return "ERR no such fan" }
        let lo = smc.readNumber("F\(fan)Mn") ?? 0
        let hi = smc.readNumber("F\(fan)Mx") ?? 10000
        // 0 means "let the fan stop" (MacBook fans idle at 0 rpm); anything else is clamped.
        let clamped = rpm <= 0 ? 0 : min(max(rpm, lo), hi)
        // While the system is going to sleep, ignore speed requests so the SMC stays on auto.
        if systemSleeping { return "OK paused" }
        do {
            try smc.setFan(fan, rpm: clamped)
            anyManual = true
            return "OK"
        } catch {
            return "ERR \(error)"
        }
    case "AUTO":
        if parts.count == 2, let fan = Int(parts[1]) {
            try? smc.setFanAuto(fan)
        } else {
            anyManual = true
            restoreAuto("requested")
        }
        return "OK"
    default:
        return "ERR unknown command"
    }
}

func closeClient(_ fd: Int32) {
    clients[fd]?.cancel()
    clients[fd] = nil
    buffers[fd] = nil
    if clients.isEmpty { restoreAuto("client disconnected") }
}

func serve(_ fd: Int32) {
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    clients[fd] = src
    buffers[fd] = Data()
    src.setEventHandler {
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { closeClient(fd); return }
        buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
        while let nl = buffers[fd]?.firstIndex(of: 0x0A) {
            let lineData = buffers[fd]![buffers[fd]!.startIndex..<nl]
            buffers[fd]!.removeSubrange(buffers[fd]!.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = handle(line) + "\n"
            _ = reply.withCString { write(fd, $0, strlen($0)) }
        }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
}

// MARK: Socket setup

unlink(socketPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { perror("socket"); exit(1) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    let bytes = Array(socketPath.utf8)
    for (i, b) in bytes.enumerated() where i < raw.count - 1 { raw[i] = b }
}
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0 else { perror("bind"); exit(1) }
// Any local user may talk to the helper; speeds are always clamped to the fan's
// own min/max, and the firmware keeps its thermal protection.
chmod(socketPath, 0o666)
guard listen(listenFD, 4) == 0 else { perror("listen"); exit(1) }

let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
acceptSource.setEventHandler {
    let fd = accept(listenFD, nil, nil)
    if fd >= 0 { serve(fd) }
}
acceptSource.resume()

// Watchdog: if the app stops sending updates (hung, crashed), hand control back.
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 5, repeating: 5)
watchdog.setEventHandler {
    if anyManual, Date().timeIntervalSince(lastCommand) > watchdogSeconds { restoreAuto("watchdog") }
}
watchdog.resume()

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    s.setEventHandler {
        anyManual = true
        restoreAuto("signal \(sig)")
        unlink(socketPath)
        exit(0)
    }
    s.resume()
    _ = Unmanaged.passRetained(s as AnyObject)
}

// MARK: System sleep
//
// Manual fan mode lives in the SMC and survives sleep, while this process and the app are
// frozen, so a fan left at a fixed speed would keep spinning with the lid closed.
// Hand control back to macOS before sleep and refuse SETs until the system is fully on.

let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemWillPowerOn: UInt32 = 0xE000_0320
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

var powerPort: io_connect_t = 0
var powerNotifier: io_object_t = 0
var powerNotifyPort: IONotificationPortRef?

powerPort = IORegisterForSystemPower(nil, &powerNotifyPort, { _, _, messageType, messageArgument in
    switch messageType {
    case kMsgCanSystemSleep:
        IOAllowPowerChange(powerPort, Int(bitPattern: messageArgument))
    case kMsgSystemWillSleep:
        systemSleeping = true
        anyManual = true          // force a reset even if we think we're already on auto
        restoreAuto("system sleep")
        IOAllowPowerChange(powerPort, Int(bitPattern: messageArgument))
    case kMsgSystemHasPoweredOn:
        if systemSleeping { log("system woke") }
        systemSleeping = false
        lastCommand = Date()
    default:
        break
    }
}, &powerNotifier)

if powerPort != 0, let p = powerNotifyPort {
    IONotificationPortSetDispatchQueue(p, queue)
} else {
    log("warning: could not register for sleep notifications")
}

log("FanControlHelper listening on \(socketPath), \(smc.fanCount()) fan(s)")
dispatchMain()
