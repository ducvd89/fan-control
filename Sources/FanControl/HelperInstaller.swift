import AppKit
import Foundation

/// Installs or removes the root helper by running the bundled script with an admin prompt.
enum HelperInstaller {
    static func run(_ action: String) -> String? {
        let contents = currentContentsURL()
        let script = contents.appendingPathComponent("Resources/helper.sh").path
        let helper = contents.appendingPathComponent("MacOS/FanControlHelper").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: helper) else {
            return "Helper files not found in \(contents.deletingLastPathComponent().path). If you moved the app, quit and reopen it."
        }
        let cmd = "/bin/bash \(quoted(script)) \(action) \(quoted(helper))"
        let source = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            return error[NSAppleScript.errorMessage] as? String ?? "Install failed"
        }
        return nil
    }

    /// `Bundle.main` caches the launch path, which goes stale if the app is moved while
    /// running (e.g. dragged into /Applications). The kernel knows where the binary is now.
    private static func currentContentsURL() -> URL {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 {
            let exe = URL(fileURLWithPath: String(cString: buf))
            return exe.deletingLastPathComponent().deletingLastPathComponent()   // …/Contents
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents")
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
