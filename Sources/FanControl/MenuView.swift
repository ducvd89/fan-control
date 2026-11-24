import SwiftUI
import SMCKit

struct MenuView: View {
    @Environment(FanController.self) private var controller
    @Environment(ProfileStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readings
            Divider()
            profiles
            if !store.active.isSystem {
                CurveEditor(points: .constant(store.active.points),
                            liveTemp: controller.smoothedTemp,
                            liveLevel: controller.currentLevel,
                            editable: false, compact: true)
                    .frame(height: 70)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            helperStatus
            Divider()
            HStack {
                Button("Edit Profiles…") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { controller.checkHelper() }
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(controller.hottest.map { String(format: "%.1f°C", $0.value) } ?? "--")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                if let h = controller.hottest {
                    Text("\(h.group) · \(h.key)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let lvl = controller.currentLevel {
                    Text(lvl <= 0 ? "off" : "\(Int(lvl))%")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            ForEach(controller.fans) { fan in
                HStack {
                    Image(systemName: "fan").foregroundStyle(.secondary)
                    Text("Fan \(fan.id + 1)")
                    Spacer()
                    Text("\(Int(fan.actual)) rpm").monospacedDigit()
                    ProgressView(value: min(fan.actual / max(fan.max, 1), 1))
                        .frame(width: 70)
                }
                .font(.callout)
            }
            if let err = controller.smcError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var profiles: some View {
        VStack(spacing: 2) {
            ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, p in
                Button {
                    controller.activate(p.id)
                } label: {
                    HStack {
                        Image(systemName: p.id == store.activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(p.id == store.activeID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(p.name)
                        Spacer()
                        if index < 9 {
                            Text("⌃⌥⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(p.id == store.activeID ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var helperStatus: some View {
        switch controller.helperState {
        case .ok, .unknown:
            EmptyView()
        case .missing:
            VStack(alignment: .leading, spacing: 6) {
                Label("Fan control helper not installed", systemImage: "lock.shield")
                    .font(.callout)
                Text("Reading sensors works, but setting fan speeds needs a small root helper.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Install Helper…") {
                    installError = HelperInstaller.run("install")
                    controller.checkHelper()
                }
                if let installError { Text(installError).font(.caption).foregroundStyle(.red) }
            }
        case .error(let msg):
            Label("Helper: \(msg)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
