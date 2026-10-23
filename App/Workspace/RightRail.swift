import SwiftUI
import simd

/// Seitenleisten-Fenster rechts.
enum SidePanel: String, Identifiable {
    case history = "Verlauf"
    case elements = "Elemente"

    var id: Self { self }
}

/// Rechte Leiste: Fang, Rastergröße, ViewCube, Einpassen, Anzeigemodus, Screenshot, Verlauf, Elemente.
struct RightRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    @Binding var panel: SidePanel?
    let screenshot: () -> Void

    private static let gridSteps: [Double] = [0.1, 0.5, 1, 5, 10]

    var body: some View {
        VStack(spacing: 10) {
            RailButton(systemImage: "square.grid.3x3.topleft.filled", label: "Fang", isActive: sketch.snapEnabled) {
                sketch.snapEnabled.toggle()
            }
            Menu {
                Picker("Raster", selection: $sketch.gridStep) {
                    ForEach(Self.gridSteps, id: \.self) { step in
                        Text("\(step.formatted()) mm").tag(step)
                    }
                }
            } label: {
                Text(sketch.gridStep.formatted())
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.primary)
                    .background(Color(.systemBackground), in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    .accessibilityLabel("Rastergröße")
            }

            if sketch.isActive {
                RailButton(systemImage: "scope", label: "Normal zu Skizze") {
                    workspace.send(.alignToSketchPlane)
                }
                RailButton(systemImage: "lock", label: "Einschränkungen (bald)") {}
                    .disabled(true)
                    .opacity(0.4)
                RailButton(systemImage: sketch.fingerDraws ? "hand.draw.fill" : "hand.draw",
                           label: "Finger zeichnet", isActive: sketch.fingerDraws) {
                    sketch.fingerDraws.toggle()
                }
            }

            ViewCube(camera: workspace.camera) { normal in
                workspace.send(.look(normal))
            }
            .padding(.vertical, 4)

            RailButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Einpassen") {
                workspace.send(.fitAll)
            }
            Menu {
                Picker("Anzeigemodus", selection: $workspace.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                Divider()
                Toggle("Orthografisch", systemImage: "cube.transparent", isOn: $workspace.isOrthographic)
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

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? Color.accentColor : Color(.systemBackground), in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
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
