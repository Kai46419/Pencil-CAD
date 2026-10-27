import SwiftUI
import simd

// Ändern › Vereinigen/Abziehen/Schneiden mit sichtbaren Rollen (Ziel orange umrandet, Werkzeuge halbtransparent rot),
// Live-Vorschau und Spiel beim Abziehen, dazu Erstellen › Negativform (Block um einen Körper, Körper mit Spiel
// herausgeschnitten, wahlweise zweiteilig). Rechnen: MoldTools.swift.

/// Einstellungen von Abziehen-Spiel und Negativform (eigenes Objekt, damit Workspace nur eine Zeile dazubekommt).
@MainActor
final class MoldSettings: ObservableObject {
    /// Spiel beim Abziehen in mm (0 = genau)
    @Published var subtractClearance: Double = 0
    @Published var spec = MoldSpec()
}

// MARK: - Ablauf

extension Workspace {
    /// Spiel der Operation: nur Abziehen dickt die Werkzeuge auf.
    func booleanClearance(_ kind: BooleanKind) -> Double {
        kind == .subtract ? mold.subtractClearance : 0
    }

    /// Vorschau mit den gewählten Körpern (der erste ist das Ziel); unter zwei Körpern keine Vorschau.
    func updateBooleanPreview(_ kind: BooleanKind) {
        let chosen = model.selectedBodies
        guard let target = chosen.first, chosen.count > 1 else {
            model.dropPreview()
            return
        }
        model.previewBoolean(kind, target: target, tools: Array(chosen.dropFirst()), clearance: booleanClearance(kind))
    }

    /// „Fertig“: Vorschau verwerfen und die Operation wirklich ausführen (mit Verlauf und Spiel).
    func applyBooleanTool(_ kind: BooleanKind) {
        let chosen = model.selectedBodies
        model.dropPreview()
        guard let target = chosen.first, chosen.count > 1 else { return }
        model.applyBoolean(kind, target: target, tools: Array(chosen.dropFirst()), keepTools: booleanKeepsTools,
                           clearance: booleanClearance(kind))
    }

    /// Einen Werkzeugkörper zum Ziel machen (das bisherige Ziel wird Werkzeug).
    func makeBooleanTarget(_ body: Int) {
        var chosen = model.selectedBodies
        guard let index = chosen.firstIndex(of: body), index > 0 else { return }
        chosen.remove(at: index)
        chosen.insert(body, at: 0)
        // selectBodies übernimmt eine offene Vorschau – die boolesche Vorschau vorher verwerfen
        model.dropPreview()
        model.selectBodies(chosen)
        updatePreview()
    }

    /// Körper aus der Auswahl nehmen (auch ausgeblendete Werkzeuge, die sich nicht antippen lassen).
    func removeFromBoolean(_ body: Int) {
        model.toggleBody(body)
        updatePreview()
    }

    /// Körper der Negativform: der zuletzt gewählte.
    var moldBody: Int? {
        guard let last = model.selectedBodies.last, model.bodies.indices.contains(last) else { return nil }
        return last
    }

    func updateMoldPreview() {
        guard let body = moldBody else {
            model.dropPreview()
            return
        }
        model.previewMold(body: body, spec: mold.spec)
    }

    /// Antippen in der Negativform: Körper wählen. Die Form der Vorschau selbst (neue Körper) zählt nicht.
    func moldTapped(_ body: Int?) {
        guard let body, model.bodies.indices.contains(body) else { return }
        model.toggleBody(body, exclusive: true)
        updateMoldPreview()
    }
}

// MARK: - Karten

/// Spielfeld mit Vorlagen (FDM, Harz, ohne).
struct ClearanceField: View {
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            NumberField(title: "Spiel", value: value, width: 56) { newValue in
                set(min(max(newValue, 0), 5))
            }
            .hoverTip("Spiel", "Abstand zwischen Teil und Aussparung: der Werkzeugkörper wird vor dem Abziehen rundum "
                + "um diesen Wert aufgedickt, damit das Teil später hineinpasst. 0 = genau.")
            Menu {
                ForEach(ClearancePreset.allCases) { preset in
                    let current: Bool = abs(value - preset.clearance) < 1e-9
                    Button {
                        set(preset.clearance)
                    } label: {
                        if current {
                            Label("\(preset.title) mm", systemImage: "checkmark")
                        } else {
                            Text("\(preset.title) mm")
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .fixedSize()
            .hoverTip("Spiel-Vorlagen", "FDM 0,2 mm, Harz (SLA) 0,1 mm oder ohne Spiel. Im Feld ist jeder Wert möglich.")
        }
    }
}

/// Karte von Vereinigen, Abziehen und Schneiden: Rollen der gewählten Körper, Spiel (nur Abziehen), Werkzeuge behalten.
struct BooleanCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var settings: MoldSettings
    let kind: BooleanKind

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Label(kind.rawValue, systemImage: kind.systemImage)
                        .font(.callout.weight(.semibold))
                    if kind == .subtract {
                        ClearanceField(value: settings.subtractClearance) { value in
                            settings.subtractClearance = value
                            workspace.updatePreview()
                        }
                    }
                    Toggle("Werkzeuge behalten", isOn: $workspace.booleanKeepsTools)
                        .fixedSize()
                        .hoverTip("Werkzeuge behalten", "Wie Fusion 360: die Werkzeugkörper bleiben nach dem Abziehen bzw. Schneiden stehen, z. B. um sie noch einmal zu verwenden.")
                }
                roles
            }
        }
    }

    private var chosen: [Int] {
        model.selectedBodies.filter { model.bodies.indices.contains($0) }
    }

    @ViewBuilder
    private var roles: some View {
        let list = chosen
        if let target = list.first {
            HStack(spacing: 8) {
                RoleBadge(title: "Ziel", color: .orange)
                Text(model.bodies[target].name)
                    .lineLimit(1)
                removeButton(target)
            }
            let tools: [Int] = Array(list.dropFirst())
            if tools.isEmpty {
                Text(kind == .union ? "Weitere Körper antippen, die dazukommen" : "Werkzeugkörper antippen")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tools, id: \.self) { tool in
                    HStack(spacing: 8) {
                        RoleBadge(title: "Werkzeug", color: .red)
                        Text(model.bodies[tool].name)
                            .lineLimit(1)
                        Button("Als Ziel") { workspace.makeBooleanTarget(tool) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .hoverTip("Als Ziel", "Dieser Körper bleibt stehen, das bisherige Ziel wird zum Werkzeug.")
                        removeButton(tool)
                    }
                }
            }
        } else {
            Text("Zuerst den Zielkörper antippen – er bleibt, die weiteren sind die Werkzeuge")
                .foregroundStyle(.secondary)
        }
    }

    private func removeButton(_ body: Int) -> some View {
        Button {
            workspace.removeFromBoolean(body)
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverTip("Aus der Auswahl nehmen")
    }
}

/// Kleines farbiges Schild „Ziel“ bzw. „Werkzeug“ (Farben wie im Viewport).
private struct RoleBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

/// Karte der Negativform.
struct MoldCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var settings: MoldSettings

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Label("Negativform", systemImage: "cube.transparent")
                        .font(.callout.weight(.semibold))
                    if let index = workspace.moldBody {
                        Text(model.bodies[index].name)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Körper antippen")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    NumberField(title: "Rand", value: settings.spec.margin, width: 56) { value in
                        guard value > 0 else { return }
                        change { $0.margin = value }
                    }
                    .hoverTip("Rand", "Wandstärke des Blocks rund um den Körper (je Seite).")
                    ClearanceField(value: settings.spec.clearance) { value in
                        change { $0.clearance = value }
                    }
                }
                HStack(spacing: 14) {
                    Toggle("In zwei Hälften teilen", isOn: Binding(get: { settings.spec.halves }, set: { halves in
                        change { $0.halves = halves }
                    }))
                    .fixedSize()
                    .hoverTip("In zwei Hälften teilen", "Teilt die Form an einer Ebene durch die Körpermitte – so lässt sich das Teil herausnehmen.")
                    if settings.spec.halves {
                        Picker("Trennebene", selection: Binding(get: { settings.spec.parting }, set: { parting in
                            change { $0.parting = parting }
                        })) {
                            ForEach(MoldParting.allCases) { parting in
                                Text(parting.title).tag(parting)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func change(_ edit: (inout MoldSpec) -> Void) {
        var spec = settings.spec
        edit(&spec)
        settings.spec = spec
        workspace.updatePreview()
    }
}

// MARK: - Viewport

/// Werkzeugkörper der booleschen Vorschau als Dreiecke und Kantenlinien, zwischengespeichert (die Linien werden
/// bei jedem Schweben neu zusammengestellt) – ebenso die Kanten des Ziels.
@MainActor
final class BooleanToolOverlay {
    static let shared = BooleanToolOverlay()

    private var toolShapes: [PCKShape] = []
    private var toolTriangles: [SIMD3<Float>] = []
    private var toolLines: [[SIMD3<Float>]] = []
    private var targetKey: (revision: Int, body: Int)?
    private var targetLines: [[SIMD3<Float>]] = []

    func tools(_ shapes: [PCKShape]) -> (triangles: [SIMD3<Float>], lines: [[SIMD3<Float>]]) {
        var same = shapes.count == toolShapes.count
        if same {
            for index in shapes.indices where shapes[index] !== toolShapes[index] {
                same = false
                break
            }
        }
        if !same {
            var triangles: [SIMD3<Float>] = []
            var lines: [[SIMD3<Float>]] = []
            for shape in shapes {
                let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
                for index in mesh.indices {
                    triangles.append(mesh.vertices[Int(index)].position)
                }
                var k = 0
                while k + 1 < mesh.edges.count {
                    lines.append([mesh.edges[k], mesh.edges[k + 1]])
                    k += 2
                }
            }
            toolShapes = shapes
            toolTriangles = triangles
            toolLines = lines
        }
        return (toolTriangles, toolLines)
    }

    func target(_ body: Int, in mesh: Mesh, revision: Int) -> [[SIMD3<Float>]] {
        if let key = targetKey, key.revision == revision, key.body == body { return targetLines }
        var lines: [[SIMD3<Float>]] = []
        for (index, ref) in mesh.edgeRefs.enumerated() where ref.body == body {
            let a = 2 * index
            guard a + 1 < mesh.edges.count else { break }
            lines.append([mesh.edges[a], mesh.edges[a + 1]])
        }
        targetKey = (revision: revision, body: body)
        targetLines = lines
        return lines
    }
}

extension ViewportView {
    /// Boolesche Vorschau: Werkzeuge halbtransparent rot mit roten Kanten (auch durch das Ziel hindurch sichtbar),
    /// Kanten des Ziels orange.
    func addBooleanOverlay(to groups: inout [LineGroup], fills: inout [FillGroup]) {
        guard let workspace, case .boolean = workspace.tool else { return }
        let model = workspace.model
        guard model.hasPreview else { return }
        let chosen: [Int] = model.selectedBodies.filter { model.bodies.indices.contains($0) }
        guard let target = chosen.first, chosen.count > 1 else { return }
        let shapes: [PCKShape] = chosen.dropFirst().map { model.bodies[$0].shape }
        let overlay = BooleanToolOverlay.shared.tools(shapes)
        if !overlay.triangles.isEmpty {
            fills.append(FillGroup(triangles: overlay.triangles, color: SIMD4<Float>(0.92, 0.22, 0.24, 0.22)))
        }
        groups.append(LineGroup(polylines: overlay.lines, color: SIMD3<Float>(0.86, 0.16, 0.2), width: 1.4,
                                onTop: true))
        let targetLines = BooleanToolOverlay.shared.target(target, in: model.mesh, revision: model.revision)
        groups.append(LineGroup(polylines: targetLines, color: SIMD3<Float>(0.98, 0.62, 0.18), width: 2.2,
                                onTop: false))
    }
}
