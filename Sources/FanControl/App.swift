import AppKit
import SwiftUI

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(delegate.controller)
                .environment(delegate.store)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("Fan Profiles", id: "editor") {
            EditorView()
                .environment(delegate.controller)
                .environment(delegate.store)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ProfileStore()
    lazy var controller = FanController(store: store)
    private var hotKeys: HotKeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        hotKeys = HotKeys { [weak self] index in
            MainActor.assumeIsolated {
                guard let self else { return }
                let list = self.store.profiles
                if index < 0 {
                    let cur = list.firstIndex { $0.id == self.store.activeID } ?? 0
                    self.controller.activate(list[(cur + 1) % list.count].id)
                } else if index < list.count {
                    self.controller.activate(list[index].id)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

/// Menu bar label: two stacked rows, hottest temperature on top, average fan speed below.
/// MenuBarExtra only lays out a single line, so the rows are rendered into a template
/// image, which macOS then tints for light/dark menu bars like any system icon.
struct MenuBarLabel: View {
    let controller: FanController

    var body: some View {
        let temp = controller.hottest.map { "\(Int($0.value.rounded()))°C" } ?? "--°C"
        let rpm = controller.averageRPM.map { $0 < 1 ? "0" : String(format: "%.0f", $0) } ?? "--"
        let custom = !controller.store.active.isSystem
        Image(nsImage: Self.render(temp: temp, rpm: rpm, custom: custom))
            .accessibilityLabel("Hottest \(temp), fans \(rpm) rpm")
    }

    @MainActor
    static func render(temp: String, rpm: String, custom: Bool) -> NSImage {
        let content = TwoRowLabel(temp: temp, rpm: rpm, custom: custom)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct TwoRowLabel: View {
    let temp: String
    let rpm: String
    let custom: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "thermometer.medium", text: temp)
            // Filled fan while a custom curve is in control; outlined under System Auto.
            row(icon: custom ? "fan.fill" : "fan", text: rpm)
        }
        // Fixed width so neighbouring menu bar items don't shift as digits change.
        .frame(width: 46, height: 22, alignment: .leading)
        .foregroundStyle(.black)
    }

    private func row(icon: String, text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
            Text(text)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .fixedSize()
        }
        .frame(height: 10.5)
    }
}
