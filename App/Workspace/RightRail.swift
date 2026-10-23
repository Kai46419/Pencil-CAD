import SwiftUI
import simd

/// Seitenleisten-Fenster rechts.
enum SidePanel: String, Identifiable {
    case history = "Verlauf"
    case elements = "Elemente"

    var id: Self { self }
}

/// Fang-Symbol: Hufeisenmagnet (gibt es nicht als SF Symbol).
struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let radius = w * 0.3
        let bottom = CGPoint(x: rect.midX, y: rect.minY + h * 0.58)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - radius, y: rect.minY + h * 0.1))
        path.addLine(to: CGPoint(x: rect.midX - radius, y: bottom.y))
        path.addArc(center: bottom, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.midX + radius, y: rect.minY + h * 0.1))
        return path
    }
}

/// Polenden des Magneten (abgesetzt dargestellt).
struct MagnetPoles: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let radius = w * 0.3
        var path = Path()
        for x in [rect.midX - radius, rect.midX + radius] {
            path.move(to: CGPoint(x: x, y: rect.minY + h * 0.1))
            path.addLine(to: CGPoint(x: x, y: rect.minY + h * 0.3))
        }
        return path
    }
}

struct MagnetRailIcon: View {
    var isActive: Bool
    /// false in einer gemeinsamen Säule (RailGroup), die selbst den Schatten trägt
    var shadowed = true

    var body: some View {
        let ink = isActive ? Color.white : Color.primary
        ZStack {
            MagnetShape()
                .stroke(ink, style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
            MagnetPoles()
                .stroke(isActive ? Color.white.opacity(0.55) : Color.red.opacity(0.8),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
        }
        .frame(width: 20, height: 22)
        .frame(width: 44, height: 44)
        .background(isActive ? Color.accentColor : Color(.systemBackground), in: Circle())
        .shadow(color: .black.opacity(shadowed ? 0.12 : 0), radius: 4, y: 1)
    }
}

/// Fangeinstellungen: Hauptschalter, einzelne Fangarten, Rastermaß.
struct SnapMenu: View {
    @ObservedObject var sketch: SketchController
    let gridSteps: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $sketch.snapEnabled) {
                Text("Fang")
                    .font(.headline)
            }
            Divider()
            ForEach(SnapKind.allCases) { kind in
                Toggle(isOn: Binding(get: { sketch.snapKinds.contains(kind) }, set: { on in
                    if on { sketch.snapKinds.insert(kind) } else { sketch.snapKinds.remove(kind) }
                })) {
                    HStack(spacing: 10) {
                        Image(systemName: kind.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.rawValue)
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(!sketch.snapEnabled)
            Divider()
            Picker("Raster", selection: $sketch.gridStep) {
                ForEach(gridSteps, id: \.self) { step in
                    Text("\(step.formatted()) mm").tag(step)
                }
            }
            .pickerStyle(.segmented)
            Text("Schwebt der Stift über der Skizze, zeigt er Fangpunkte und Knoten an.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 320)
    }
}

/// Rechte Leiste: Fang, Rastergröße, ViewCube, Einpassen, Anzeigemodus, Screenshot, Verlauf, Elemente.
struct RightRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    @Binding var panel: SidePanel?
    let screenshot: () -> Void

    /// Rastermaß bis zum Tausendstel Millimeter
    private static let gridSteps: [Double] = [0.001, 0.01, 0.1, 0.5, 1, 5, 10]
    @State private var isSnapMenuShown = false

    @State private var showsConstraints = true

    var body: some View {
        if sketch.isActive {
            ViewThatFits(in: .vertical) {
                sketchColumn
                ScrollView(showsIndicators: false) { sketchColumn }
            }
        } else {
            mainColumn
        }
    }

    /// Skizzenmodus wie bei Shapr3D: Fang, Raster, Ausrichten und Finger in einer Säule, daneben der Würfel;
    /// darunter Anzeigemodi, Screenshot, Verlauf und die Einschränkungen (vor der Ebenenwahl ausgegraut).
    private var sketchColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ViewCube(camera: workspace.camera) { normal in
                    workspace.send(.look(normal))
                }
                // Nach der Ebenenwahl bleibt die Ansicht senkrecht auf der Skizzenebene
                .disabled(!sketch.isChoosingPlane)
                .opacity(sketch.isChoosingPlane ? 1 : 0.4)
                RailGroup {
                    Button {
                        isSnapMenuShown = true
                    } label: {
                        MagnetRailIcon(isActive: sketch.snapEnabled, shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fang")
                    .popover(isPresented: $isSnapMenuShown, arrowEdge: .trailing) {
                        SnapMenu(sketch: sketch, gridSteps: Self.gridSteps)
                    }
                    gridMenu(stacked: true)
                    Button {
                        workspace.send(.alignToSketchPlane)
                    } label: {
                        RailIcon(systemImage: "cube.transparent", shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Normal zu Skizze")
                    .disabled(sketch.isChoosingPlane)
                    .opacity(sketch.isChoosingPlane ? 0.4 : 1)
                    Button {
                        sketch.fingerDraws.toggle()
                    } label: {
                        RailIcon(systemImage: sketch.fingerDraws ? "hand.draw.fill" : "hand.draw",
                                 isActive: sketch.fingerDraws, shadowed: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Finger zeichnet")
                }
            }

            Menu {
                displayModePicker
            } label: {
                HStack(spacing: 8) {
                    RailLabel(title: "Anzeigemodi", subtitle: workspace.displayMode.rawValue)
                    RailIcon(systemImage: workspace.displayMode.systemImage)
                }
            }
            .accessibilityLabel("Anzeigemodus")
            labeledButton("Screenshot", systemImage: "camera", action: screenshot)
            labeledButton("Verlauf", systemImage: "clock.arrow.circlepath", isActive: panel == .history) {
                panel = panel == .history ? nil : .history
            }

            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 30, height: 3)
                .frame(width: 44)
            labeledButton("Einschränkungen", systemImage: "gearshape.fill", isActive: false) {
                withAnimation(.easeOut(duration: 0.15)) { showsConstraints.toggle() }
            }
            if showsConstraints {
                ConstraintColumn(sketch: sketch, isEnabled: !sketch.isChoosingPlane)
            }
        }
    }

    private func labeledButton(_ title: String, subtitle: String? = nil, systemImage: String, isActive: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RailLabel(title: title, subtitle: subtitle)
                RailIcon(systemImage: systemImage, isActive: isActive)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Rastermaß; im Skizzenmodus wie bei Shapr3D zweizeilig („50“ über „mm“).
    private func gridMenu(stacked: Bool) -> some View {
        Menu {
            Picker("Raster", selection: $sketch.gridStep) {
                ForEach(Self.gridSteps, id: \.self) { step in
                    Text("\(step.formatted()) mm").tag(step)
                }
            }
        } label: {
            Group {
                if stacked {
                    VStack(spacing: -1) {
                        Text(sketch.gridStep.formatted())
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Text("mm")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(width: 44, height: 44)
                } else {
                    Text(sketch.gridStep.formatted())
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(width: 44, height: 44)
                        .background(Color(.systemBackground), in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Rastergröße")
        }
    }

    @ViewBuilder
    private var displayModePicker: some View {
        Picker("Anzeigemodus", selection: $workspace.displayMode) {
            ForEach(DisplayMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
            }
        }
        Divider()
        Toggle("Orthografisch", systemImage: "cube.transparent", isOn: $workspace.isOrthographic)
    }

    private var mainColumn: some View {
        VStack(spacing: 10) {
            Button {
                isSnapMenuShown = true
            } label: {
                MagnetRailIcon(isActive: sketch.snapEnabled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fang")
            .popover(isPresented: $isSnapMenuShown, arrowEdge: .trailing) {
                SnapMenu(sketch: sketch, gridSteps: Self.gridSteps)
            }
            gridMenu(stacked: false)

            ViewCube(camera: workspace.camera) { normal in
                workspace.send(.look(normal))
            }
            .padding(.vertical, 4)

            RailButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Einpassen") {
                workspace.send(.fitAll)
            }
            Menu {
                displayModePicker
            } label: {
                RailIcon(systemImage: workspace.displayMode.systemImage)
                    .accessibilityLabel("Anzeigemodus")
            }
            RailButton(systemImage: "camera", label: "Screenshot", action: screenshot)
            RailButton(systemImage: "clock.arrow.circlepath", label: "Verlauf", isActive: panel == .history) {
                panel = panel == .history ? nil : .history
            }
            RailButton(systemImage: "square.3.layers.3d", label: "Elemente", isActive: panel == .elements) {
                panel = panel == .elements ? nil : .elements
            }
        }
    }
}

/// „Einschränkungen“ im Skizzenmodus (wie Shapr3D): wirken auf die mit dem Finger gewählten Elemente.
/// Die Symbole stehen in weißen Säulen, die Namen links daneben. Passende Einschränkungen sind blau,
/// andere grau; Antippen zeigt dann, was zu wählen ist. Vor der Ebenenwahl ist alles ausgegraut.
struct ConstraintColumn: View {
    @ObservedObject var sketch: SketchController
    var isEnabled = true

    private struct Row: Identifiable {
        let id: String
        let systemImage: String
        let applicable: Bool
        let action: () -> Void
    }

    private var groups: [[Row]] {
        let hasSelection = !sketch.selection.isEmpty
        let kinds = ConstraintKind.allCases.filter { $0 != .lock && $0 != .dimension }.map { kind in
            Row(id: kind.rawValue, systemImage: kind.systemImage, applicable: sketch.canApply(kind)) {
                sketch.applyConstraint(kind)
            }
        }
        return [
            kinds,
            [Row(id: "Trennen", systemImage: "link.badge.plus", applicable: hasSelection) { sketch.detachSelection() }],
            [Row(id: ConstraintKind.lock.rawValue, systemImage: ConstraintKind.lock.systemImage,
                 applicable: sketch.canApply(.lock)) { sketch.applyConstraint(.lock) },
             Row(id: "Konstruktion erstellen", systemImage: "square.dashed", applicable: hasSelection) {
                 sketch.toggleConstruction()
             }],
        ]
    }

    var body: some View {
        let groups = self.groups
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(groups.indices, id: \.self) { index in
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(groups[index]) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 2)
                .background(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                        .frame(width: 44)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                }
            }
        }
        .disabled(!isEnabled)
    }

    private func rowView(_ row: Row) -> some View {
        let active = isEnabled && row.applicable
        return Button(action: row.action) {
            HStack(spacing: 8) {
                RailLabel(title: row.id, dimmed: !active)
                Image(systemName: row.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(isEnabled ? 1 : 0.6))
                    .frame(width: 44, height: 38)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.id)
    }
}

/// Säule mit mehreren Knöpfen auf gemeinsamem weißem Grund (rechte Leiste im Skizzenmodus).
struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

/// Name neben einem Knopf der rechten Leiste, wie bei Shapr3D als helles Schild.
struct RailLabel: View {
    let title: String
    var subtitle: String?
    var dimmed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Runder Knopf der rechten Leiste.
struct RailButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RailIcon(systemImage: systemImage, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct RailIcon: View {
    let systemImage: String
    var isActive = false
    var shadowed = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? Color.accentColor : Color(.systemBackground), in: Circle())
            .shadow(color: .black.opacity(shadowed ? 0.12 : 0), radius: 4, y: 1)
    }
}

/// Würfel, der die Blickrichtung zeigt. Antippen einer Seite dreht die Ansicht senkrecht auf diese Seite.
struct ViewCube: View {
    @ObservedObject var camera: CameraState
    let look: (SIMD3<Float>) -> Void

    private let size: CGFloat = 92

    private struct Side {
        let name: String
        let normal: SIMD3<Float>
        let a: SIMD3<Float>
        let b: SIMD3<Float>

        var corners: [SIMD3<Float>] { [normal - a - b, normal + a - b, normal + a + b, normal - a + b] }
    }

    /// Z oben, „Vorne“ blickt in +Y-Richtung (CAD-Konvention).
    private static let sides = [
        Side(name: "Oben", normal: [0, 0, 1], a: [1, 0, 0], b: [0, 1, 0]),
        Side(name: "Unten", normal: [0, 0, -1], a: [1, 0, 0], b: [0, 1, 0]),
        Side(name: "Vorne", normal: [0, -1, 0], a: [1, 0, 0], b: [0, 0, 1]),
        Side(name: "Hinten", normal: [0, 1, 0], a: [1, 0, 0], b: [0, 0, 1]),
        Side(name: "Rechts", normal: [1, 0, 0], a: [0, 1, 0], b: [0, 0, 1]),
        Side(name: "Links", normal: [-1, 0, 0], a: [0, 1, 0], b: [0, 0, 1]),
    ]

    var body: some View {
        let projection = Projection(yaw: camera.yaw, pitch: camera.pitch, size: size)
        let visible = Self.sides
            .map { (side: $0, facing: simd_dot($0.normal, projection.toCamera)) }
            .filter { $0.facing > 0.01 }
            .sorted { $0.facing < $1.facing }

        Canvas { context, _ in
            for entry in visible {
                var path = Path()
                path.addLines(entry.side.corners.map(projection.point))
                path.closeSubpath()
                let shade = 0.82 + 0.18 * Double(entry.facing)
                context.fill(path, with: .color(Color(white: shade)))
                context.stroke(path, with: .color(Color(white: 0.55)), lineWidth: 1)
                if entry.facing > 0.3 {
                    let text = Text(entry.side.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.2))
                    context.draw(text, at: projection.point(entry.side.normal))
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { location in
            // Vorderste Seite unter dem Finger
            for entry in visible.reversed() {
                let polygon = entry.side.corners.map(projection.point)
                if contains(polygon, location) {
                    look(entry.side.normal)
                    return
                }
            }
        }
        .accessibilityLabel("Ansichtswürfel")
    }

    private func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var sign: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 {
                    sign = cross
                } else if (cross > 0) != (sign > 0) {
                    return false
                }
            }
        }
        return true
    }

    /// Parallelprojektion des Würfels passend zur Kamera.
    private struct Projection {
        let toCamera: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let scale: CGFloat
        let center: CGPoint

        init(yaw: Float, pitch: Float, size: CGFloat) {
            let cp = cos(pitch)
            toCamera = SIMD3(cp * cos(yaw), cp * sin(yaw), sin(pitch))
            let forward = -toCamera
            right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
            up = simd_cross(right, forward)
            scale = size * 0.26
            center = CGPoint(x: size / 2, y: size / 2)
        }

        func point(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: center.x + CGFloat(simd_dot(p, right)) * scale,
                    y: center.y - CGFloat(simd_dot(p, up)) * scale)
        }
    }
}
