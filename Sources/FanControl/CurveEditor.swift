import SwiftUI

/// Draggable fan curve. Drag points to move them, double-click empty space to add one,
/// select a point and press Delete (or right-click it) to remove it.
struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var liveTemp: Double?
    var liveLevel: Double?
    var editable = true
    var compact = false

    @State private var selected: UUID?
    @State private var dragging: UUID?
    @FocusState private var focused: Bool

    private let tRange = FanProfile.tempRange
    private var inset: EdgeInsets {
        compact ? EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
                : EdgeInsets(top: 12, leading: 40, bottom: 28, trailing: 14)
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: inset.leading, y: inset.top,
                              width: geo.size.width - inset.leading - inset.trailing,
                              height: geo.size.height - inset.top - inset.bottom)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(in: ctx, plot: plot) }
                if editable {
                    ForEach(points) { p in
                        let pos = position(p, plot)
                        Circle()
                            .fill(p.id == selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: 13, height: 13)
                            .position(pos)
                            .contextMenu {
                                Button("Delete Point", role: .destructive) { remove(p.id) }
                                    .disabled(points.count <= 2)
                            }
                            .help("\(Int(p.temp))°C → \(Int(p.percent))%")
                    }
                    if let id = dragging ?? selected, let p = points.first(where: { $0.id == id }) {
                        tooltip(p).position(x: position(p, plot).x, y: max(position(p, plot).y - 22, 10))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(editable ? drag(plot) : nil)
            .simultaneousGesture(editable ? addGesture(plot) : nil)
        }
        .focusable(editable)
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.delete) { deleteSelected() }
        .onKeyPress(.deleteForward) { deleteSelected() }
    }

    // MARK: Geometry

    private func position(_ p: CurvePoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + (p.temp - tRange.lowerBound) / (tRange.upperBound - tRange.lowerBound) * r.width,
                y: r.maxY - p.percent / 100 * r.height)
    }

    private func value(at loc: CGPoint, _ r: CGRect) -> (Double, Double) {
        let t = tRange.lowerBound + Double((loc.x - r.minX) / r.width) * (tRange.upperBound - tRange.lowerBound)
        let pct = Double((r.maxY - loc.y) / r.height) * 100
        return (min(max(t, tRange.lowerBound), tRange.upperBound).rounded(), min(max(pct, 0), 100).rounded())
    }

    // MARK: Gestures

    private func drag(_ plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                focused = true
                if dragging == nil {
                    let hit = points.min { dist($0, g.startLocation, plot) < dist($1, g.startLocation, plot) }
                    if let hit, dist(hit, g.startLocation, plot) < 14 { dragging = hit.id; selected = hit.id } else { selected = nil; return }
                }
                guard let id = dragging, let i = points.firstIndex(where: { $0.id == id }) else { return }
                var (t, pct) = value(at: g.location, plot)
                // Keep points ordered: a point can't pass its neighbours.
                if i > 0 { t = max(t, points[i - 1].temp + 1) }
                if i < points.count - 1 { t = min(t, points[i + 1].temp - 1) }
                points[i].temp = t
                points[i].percent = pct
            }
            .onEnded { _ in dragging = nil }
    }

    private func addGesture(_ plot: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { e in
            let (t, pct) = value(at: e.location, plot)
            guard !points.contains(where: { abs($0.temp - t) < 1 }) else { return }
            let p = CurvePoint(temp: t, percent: pct)
            points.append(p)
            points.sort { $0.temp < $1.temp }
            selected = p.id
        }
    }

    private func dist(_ p: CurvePoint, _ loc: CGPoint, _ r: CGRect) -> CGFloat {
        let q = position(p, r)
        return hypot(q.x - loc.x, q.y - loc.y)
    }

    private func deleteSelected() -> KeyPress.Result {
        guard let s = selected else { return .ignored }
        remove(s)
        return .handled
    }

    private func remove(_ id: UUID) {
        guard points.count > 2 else { return }
        points.removeAll { $0.id == id }
        selected = nil
    }

    // MARK: Drawing

    private func tooltip(_ p: CurvePoint) -> some View {
        Text("\(Int(p.temp))°C · \(p.percent == 0 ? "off" : "\(Int(p.percent))%")")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    private func draw(in ctx: GraphicsContext, plot r: CGRect) {
        let grid = Color.secondary.opacity(0.18)
        if !compact {
            for t in stride(from: 20.0, through: 110, by: 10) {
                let x = r.minX + (t - tRange.lowerBound) / (tRange.upperBound - tRange.lowerBound) * r.width
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: r.minY)); $0.addLine(to: CGPoint(x: x, y: r.maxY)) }, with: .color(grid))
                ctx.draw(Text("\(Int(t))°").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x, y: r.maxY + 12))
            }
            for pct in stride(from: 0.0, through: 100, by: 25) {
                let y = r.maxY - pct / 100 * r.height
                ctx.stroke(Path { $0.move(to: CGPoint(x: r.minX, y: y)); $0.addLine(to: CGPoint(x: r.maxX, y: y)) }, with: .color(grid))
                ctx.draw(Text("\(Int(pct))%").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: r.minX - 18, y: y))
            }
        }

        let sorted = points.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return }
        var line = Path()
        line.move(to: CGPoint(x: r.minX, y: position(first, r).y))
        for p in sorted { line.addLine(to: position(p, r)) }
        line.addLine(to: CGPoint(x: r.maxX, y: position(last, r).y))

        var fill = line
        fill.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        fill.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.03)]),
                                              startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
        ctx.stroke(line, with: .color(.accentColor), lineWidth: compact ? 1.5 : 2)

        if let t = liveTemp {
            let x = r.minX + (min(max(t, tRange.lowerBound), tRange.upperBound) - tRange.lowerBound) / (tRange.upperBound - tRange.lowerBound) * r.width
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: r.minY)); $0.addLine(to: CGPoint(x: x, y: r.maxY)) },
                       with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let lvl = liveLevel {
                let y = r.maxY - lvl / 100 * r.height
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.orange))
            }
        }
    }
}
