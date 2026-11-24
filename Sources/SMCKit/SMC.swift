import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(UInt8)
    case unsupportedType(String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed (\(kr))"
        case .callFailed(let kr):
            return kr == kIOReturnNotPrivileged ? "not privileged (needs root)" : "SMC call failed (\(String(format: "0x%x", kr)))"
        case .smcResult(let r): return r == 0x84 ? "key not found" : "SMC error \(String(format: "0x%02x", r))"
        case .unsupportedType(let t): return "unsupported data type '\(t)'"
        }
    }
}

public struct SMCKeyInfo: Sendable {
    public let size: Int
    public let type: String
}

public struct SMCValue: Sendable {
    public let key: String
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    /// Decodes the raw bytes as a number when the type is a known numeric format.
    public var number: Double? {
        let b = bytes
        switch info.type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag":
            return b.first.map(Double.init)
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "fp88":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        default:
            return nil
        }
    }
}

/// Thin wrapper over the AppleSMC user client. Reading works for any user; writing needs root.
public final class SMC: @unchecked Sendable {
    // Byte offsets inside the 80-byte SMCKeyData_t struct the kernel expects.
    // Using a raw buffer avoids Swift struct-layout surprises (tail padding reuse).
    private enum Off {
        static let key = 0, dataSize = 28, dataType = 32, result = 40, data8 = 42, data32 = 44, bytes = 48
        static let total = 80
    }
    private enum Cmd: UInt8 { case readBytes = 5, writeBytes = 6, keyAtIndex = 8, keyInfo = 9 }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private let lock = NSLock()

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit { IOServiceClose(conn) }

    // MARK: FourCC helpers

    public static func code(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func string(_ c: UInt32) -> String {
        String(bytes: [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? "????"
    }

    // MARK: Raw calls

    private func put32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        buf.withUnsafeMutableBytes { $0.storeBytes(of: v, toByteOffset: off, as: UInt32.self) }
    }

    private func get32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
    }

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Off.total)
        var outSize = Off.total
        let kr = input.withUnsafeBytes { inp in
            output.withUnsafeMutableBytes { out in
                IOConnectCallStructMethod(conn, 2, inp.baseAddress, Off.total, out.baseAddress, &outSize)
            }
        }
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        let result = output[Off.result]
        guard result == 0 else { throw SMCError.smcResult(result) }
        return output
    }

    public func info(_ key: String) throws -> SMCKeyInfo {
        let code = Self.code(key)
        lock.lock(); defer { lock.unlock() }
        if let cached = infoCache[code] { return cached }
        var input = [UInt8](repeating: 0, count: Off.total)
        put32(&input, Off.key, code)
        input[Off.data8] = Cmd.keyInfo.rawValue
        let out = try call(input)
        let info = SMCKeyInfo(size: Int(get32(out, Off.dataSize)), type: Self.string(get32(out, Off.dataType)))
        infoCache[code] = info
        return info
    }

    public func hasKey(_ key: String) -> Bool { (try? info(key)) != nil }

    public func read(_ key: String) throws -> SMCValue {
        let info = try info(key)
        var input = [UInt8](repeating: 0, count: Off.total)
        put32(&input, Off.key, Self.code(key))
        put32(&input, Off.dataSize, UInt32(info.size))
        input[Off.data8] = Cmd.readBytes.rawValue
        let out = try lock.withLock { try call(input) }
        let n = min(info.size, 32)
        return SMCValue(key: key, info: info, bytes: Array(out[Off.bytes..<Off.bytes + n]))
    }

    public func readNumber(_ key: String) -> Double? {
        try? read(key).number
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let info = try info(key)
        var input = [UInt8](repeating: 0, count: Off.total)
        put32(&input, Off.key, Self.code(key))
        put32(&input, Off.dataSize, UInt32(info.size))
        input[Off.data8] = Cmd.writeBytes.rawValue
        for (i, b) in bytes.prefix(min(info.size, 32)).enumerated() { input[Off.bytes + i] = b }
        _ = try lock.withLock { try call(input) }
    }

    /// Writes a number using the key's own data type.
    public func write(_ key: String, number: Double) throws {
        let info = try info(key)
        let bytes: [UInt8]
        switch info.type {
        case "flt ":
            let bits = Float(number).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "ui8 ", "flag":
            bytes = [UInt8(clamping: Int(number))]
        case "ui16":
            let v = UInt16(clamping: Int(number)); bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "fpe2":
            let v = UInt16(clamping: Int(number * 4)); bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            throw SMCError.unsupportedType(info.type)
        }
        try write(key, bytes: bytes)
    }

    // MARK: Enumeration

    public func keyCount() throws -> Int {
        Int(try read("#KEY").number ?? 0)
    }

    public func key(at index: Int) throws -> String {
        var input = [UInt8](repeating: 0, count: Off.total)
        put32(&input, Off.data32, UInt32(index))
        input[Off.data8] = Cmd.keyAtIndex.rawValue
        let out = try lock.withLock { try call(input) }
        return Self.string(get32(out, Off.key))
    }

    public func allKeys() -> [String] {
        guard let n = try? keyCount() else { return [] }
        return (0..<n).compactMap { try? key(at: $0) }
    }
}
