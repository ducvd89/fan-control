import ServiceManagement
import SMCKit
import SwiftUI

struct EditorView: View {
    @Environment(FanController.self) private var controller
    @Environment(ProfileStore.self) private var store
    @State private var selection: UUID?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Profiles") {
                    ForEach(store.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == store.activeID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .tag(p.id)
                        .contextMenu {
                            Button("Activate") { controller.activate(p.id) }
                            Button("Duplicate") { selection = store.add(copying: p) }
                            Button("Delete", role: .destructive) { store.delete(p.id) }.disabled(store.profiles.count <= 1)
                        }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(Self.settingsID)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .toolbar {
                ToolbarItem {
                    Button { selection = store.add() } label: { Label("New Profile", systemImage: "plus") }
                }
            }
        } detail: {
            if selection == Self.settingsID {
                SettingsPane()
            } else if let id = selection, let i = store.binding(for: id) {
                ProfileDetail(profile: Bindable(store).profiles[i])
                    .id(id)
            } else {
                Text("Select a profile").foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection == nil { selection = store.activeID } }
    }

    static let settingsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

private struct ProfileDetail: View {
    @Binding var profile: FanProfile
    @Environment(FanController.self) private var controller
    @Environment(ProfileStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Name", text: $profile.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Spacer()
                if profile.id == store.activeID {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                } else {
                    Button("Activate") { controller.activate(profile.id) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }

            Toggle("Let macOS control the fans (ignore curve)", isOn: $profile.isSystem)
                .onChange(of: profile.isSystem) { _, sys in
                    if sys, profile.points.isEmpty == false, profile.id == store.activeID { controller.returnToAuto() }
                    if !sys, profile.points.count < 2 {
                        profile.points = FanProfile.curve([(40, 0), (60, 30), (80, 70), (95, 100)])
                    }
                }

            if !profile.isSystem {
                CurveEditor(points: $profile.points,
                            liveTemp: controller.smoothedTemp,
                            liveLevel: profile.id == store.activeID ? controller.currentLevel : profile.level(at: controller.smoothedTemp ?? 0))
                    .frame(minHeight: 260)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

                Text("Drag points to shape the curve. Double-click to add a point; select one and press Delete, or right-click it, to remove. 0% lets the fans stop; 1–100% spans each fan's min…max speed.")
                    .font(.caption).foregroundStyle(.secondary)

                pointsTable
            } else {
                Spacer()
            }
        }
        .padding(20)
    }

    private var pointsTable: some View {
        let range = controller.fans.first.map { ($0.min, $0.max) }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Temp").foregroundStyle(.secondary)
                Text("Level").foregroundStyle(.secondary)
                Text("≈ rpm").foregroundStyle(.secondary)
                Text("")
            }
            .font(.caption)
            ForEach($profile.points) { $p in
                GridRow {
                    TextField("", value: $p.temp, format: .number).frame(width: 60)
                        .onSubmit { profile.points.sort { $0.temp < $1.temp } }
                    TextField("", value: $p.percent, format: .number).frame(width: 60)
                    Text(range.map { r in p.percent <= 0 ? "off" : "\(Int(r.0 + (r.1 - r.0) * min(p.percent, 100) / 100))" } ?? "–")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        profile.points.removeAll { $0.id == p.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(profile.points.count <= 2)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

private struct SettingsPane: View {
    @Environment(FanController.self) private var controller
    @Environment(ProfileStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?

    private let groups = ["CPU", "GPU", "Memory", "Storage", "Battery", "Wireless", "Ambient", "Other"]

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section("Temperature source") {
                Text("The curve follows the hottest sensor in the selected groups.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(groups, id: \.self) { g in
                    let sensors = controller.sensors.filter { $0.group == g }
                    Toggle(isOn: Binding(
                        get: { controller.hotGroups.contains(g) },
                        set: { on in if on { controller.hotGroups.insert(g) } else if controller.hotGroups.count > 1 { controller.hotGroups.remove(g) } }
                    )) {
                        HStack {
                            Text(g)
                            Spacer()
                            if let m = sensors.map(\.value).max() {
                                Text("\(sensors.count) sensors · max \(String(format: "%.1f", m))°C")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(sensors.isEmpty)
                }
            }

            Section("Behaviour") {
                LabeledContent("Slow-down rate") {
                    HStack {
                        Slider(value: $controller.rampDownPerSecond, in: 25...1000, step: 25)
                        Text("\(Int(controller.rampDownPerSecond)) rpm/s").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { message = error.localizedDescription }
                    }
                LabeledContent("Shortcuts", value: "⌃⌥⌘1–9 pick a profile · ⌃⌥⌘0 next profile")
            }

            Section("Privileged helper") {
                LabeledContent("Status") {
                    switch controller.helperState {
                    case .ok: Text("Running").foregroundStyle(.green)
                    case .unknown: Text("Checking…")
                    case .missing: Text("Not installed").foregroundStyle(.orange)
                    case .error(let m): Text(m).foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Install / Update Helper…") { message = HelperInstaller.run("install"); controller.checkHelper() }
                    Button("Uninstall Helper…") {
                        controller.returnToAuto()
                        message = HelperInstaller.run("uninstall")
                        controller.checkHelper()
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
            }

            Section {
                Button("Restore Default Profiles", role: .destructive) { store.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}
