import SwiftUI
import simd

// MARK: - Werkzeuge: Normteile, Vorlagen, Helix, dünne Linien, Verjüngung

/// Werkzeuge, die neue Körper erzeugen bzw. Flächen neigen (ModelTool.part).
enum PartTool: Equatable {
    /// Einfügen › Normteile (Schrauben, Muttern, Scheiben, Kugellager)
    case standard
    /// Einfügen › Vorlagen (Gehäuse, Stirnrad)
    case template
    /// Erstellen › Helix (Feder, Gewinde)
    case helix
    /// Erstellen › Gewinde: Bolzen bzw. Bohrung antippen, Normgewinde modellieren; andere Flächen bekommen eine
    /// Gewindebohrung am Tippunkt (ThreadPanel.swift, SurfaceHoles.swift)
    case thread
    /// Erstellen › Dünn extrudieren: Linien einer Skizze (auch offene) als Wand
    case thinLines
    /// Ändern › Verjüngung (Entformungsschräge an Seitenflächen)
    case draft

    var title: String {
        switch self {
        case .standard: "Normteile"
        case .template: "Vorlagen"
        case .helix: "Helix"
        case .thread: "Gewinde"
        case .thinLines: "Dünn extrudieren"
        case .draft: "Verjüngung"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "screwdriver"
        case .template: "gearshape.2"
        case .helix: "tornado"
        case .thread: "barcode"
        case .thinLines: "square.dashed"
        case .draft: "trapezoid.and.line.vertical"
        }
    }

    /// Gruppe der Werkzeugleiste, in der das Werkzeug liegt
    var group: ToolGroup {
        switch self {
        case .standard, .template: .insert
        case .helix, .thread, .thinLines: .create
        case .draft: .modify
        }
    }
}

/// Einstellungen dieser Werkzeuge (eigenes Objekt, damit Workspace nur eine Zeile dazubekommt).
@MainActor
final class PartSettings: ObservableObject {
    @Published var standard = StandardPartSpec()
    @Published var template = TemplateSpec()
    @Published var helix = HelixSpec()
    @Published var thread = ThreadSpec()
    /// Gewindebohrungen am Tippunkt (Flächen, die kein Bolzen und keine Bohrung sind; SurfaceHoles.swift)
    @Published var threadHole = ThreadHoleSettings()
    // Dünn extrudieren (Linien)
    @Published var thinSketch: Int?
    @Published var thinThickness: Double = 2
    @Published var thinSide: ThinSide = .center
    @Published var thinHeight: Double = 20
    @Published var thinSymmetric = false
    @Published var thinMode: ExtrudeMode = .newBody
    // Verjüngung
    @Published var draftAngle: Double = 3
    /// Zugrichtung: 0 = X, 1 = Y, 2 = Z
    @Published var draftAxis = 2
    @Published var draftFlip = false
    // Sweep entlang Körperkanten
    @Published var sweepEdges: [EdgeRef] = []
    @Published var sweepEdgeLines: [[SIMD3<Double>]] = []
}

extension Workspace {
    /// Werkzeug starten (aus activate); faces = vorher gewählte Flächen (Verjüngung).
    func startPart(_ kind: PartTool, faces: [FaceRef] = []) {
        switch kind {
        case .thinLines:
            if parts.thinSketch.map({ !model.sketches.indices.contains($0) }) ?? true {
                parts.thinSketch = model.pathSketches.last
            }
        case .draft:
            if let first = faces.first {
                model.selectForTool(first)
                for face in faces.dropFirst() where face.body == first.body {
                    model.toggleFace(face, commitsPreview: false)
                }
            }
        case .helix:
            // Frei im Ursprung beginnen; eine Zylinderfläche antippen schneidet ein Gewinde
            parts.helix.onCylinder = false
            parts.helix.origin = .zero
            parts.helix.axis = [0, 0, 1]
            parts.helix.sourceBody = nil
        case .thread:
            // Körpernummern können sich geändert haben: Fläche neu antippen
            parts.thread.target = nil
            parts.threadHole.points = []
            parts.threadHole.lastTap = nil
        case .standard, .template:
            break
        }
        updatePartPreview()
    }

    /// Vorschau des aktiven Werkzeugs neu berechnen.
    func updatePartPreview() {
        guard case .part(let kind) = tool else { return }
        switch kind {
        case .standard:
            model.previewGenerated(PartBuilder.build(parts.standard), step: "Normteil einfügen")
        case .template:
            model.previewGenerated(PartBuilder.build(parts.template), step: "\(parts.template.kind.rawValue) einfügen")
        case .helix:
            model.previewHelix(parts.helix)
        case .thread:
            previewThreadTool()
        case .thinLines:
            model.previewThinLines(sketch: parts.thinSketch, thickness: parts.thinThickness, side: parts.thinSide,
                                   height: parts.thinHeight, symmetric: parts.thinSymmetric, mode: parts.thinMode)
        case .draft:
            guard !model.selectedFaces.isEmpty else { return }
            model.previewDraft(faces: model.selectedFaces, pull: unitAxis(parts.draftAxis) * (parts.draftFlip ? -1 : 1),
                               angle: parts.draftAngle)
        }
    }

    /// Antippen im Viewport während eines dieser Werkzeuge.
    func partTapped(_ kind: PartTool, face tappedFace: FaceRef?, point: SIMD3<Float>?) {
        // Während der Vorschau gelten die Flächennummern der Vorschau: passende echte Fläche suchen
        let face = tappedFace.flatMap { model.originalFace($0, near: point) }
        switch kind {
        case .helix:
            guard let face else { return }
            model.cancelPreview()
            guard let cylinder = model.cylinder(of: face),
                  let span = model.span(ofCylinderFace: face, origin: cylinder.origin, axis: cylinder.axis) else {
                model.message = "Für ein Gewinde eine Zylinderfläche (Bolzen oder Bohrung) antippen."
                updatePartPreview()
                return
            }
            var spec = parts.helix
            spec.profile = .thread
            spec.onCylinder = true
            spec.convex = cylinder.convex
            spec.diameter = 2 * cylinder.radius
            spec.origin = cylinder.origin + cylinder.axis * span.low
            spec.axis = cylinder.axis
            spec.height = span.high - span.low
            spec.sourceBody = face.body
            // Steigung der passenden Regelgewinde-Größe (Bohrung: Kernloch ≈ d − P)
            let diameter = spec.diameter
            let convex = cylinder.convex
            if let size = MetricSize.all.min(by: { a, b in
                abs((convex ? a.d : a.d - a.pitch) - diameter) < abs((convex ? b.d : b.d - b.pitch) - diameter)
            }), abs((convex ? size.d : size.d - size.pitch) - diameter) < 0.4 {
                spec.pitch = size.pitch
            }
            parts.helix = spec
            updatePartPreview()
        case .thread:
            guard let face else { return }
            threadTapped(face, point: point)
        case .draft:
            guard let face else { return }
            if let first = model.selection, first.body != face.body {
                model.selectForTool(face)
            } else {
                model.toggleFace(face, commitsPreview: false)
            }
            updatePartPreview()
        case .standard, .template, .thinLines:
            break
        }
    }

    /// Hinweis über dem Viewport.
    func partHint(_ kind: PartTool) -> String {
        switch kind {
        case .standard: return "Größe wählen, dann „Fertig“ – das Teil steht im Ursprung"
        case .template: return "Maße eingeben, dann „Fertig“"
        case .helix:
            return parts.helix.onCylinder ? "Gewinde wird in die Fläche geschnitten – „Fertig“ tippen"
                : "Maße eingeben · Zylinderfläche antippen schneidet ein Gewinde"
        case .thread:
            if parts.thread.target != nil { return "Gewindeart und Größe wählen, dann „Fertig“" }
            return parts.threadHole.points.isEmpty
                ? "Fläche antippen: Bolzen = Außengewinde, Bohrung = Innengewinde, sonst Gewindebohrung am Tippunkt"
                : "Weitere Stellen antippen · Gewindebohrung erneut antippen entfernt sie · dann „Fertig“"
        case .thinLines: return parts.thinSketch == nil ? "Skizze mit Linien wählen" : "Stärke, Seite und Höhe einstellen"
        case .draft:
            return model.selection == nil ? "Seitenflächen antippen, die geneigt werden" : "Winkel und Zugrichtung einstellen"
        }
    }

    /// Sweep: Körperkante antippen nimmt sie in den Pfad (bzw. wieder heraus).
    func sweepEdgeTapped(_ edge: EdgeRef) {
        guard model.bodies.indices.contains(edge.body) else { return }
        if model.hasPreview, solidMode != .newBody {
            // Die Vorschau hat den Körper verändert (andere Kantennummern): erst ohne Vorschau wählen
            model.cancelPreview()
            model.message = "Kante bitte noch einmal antippen."
            return
        }
        var edges = parts.sweepEdges
        if edges.first?.body != edge.body { edges = [] }
        if let index = edges.firstIndex(of: edge) {
            edges.remove(at: index)
        } else {
            edges.append(edge)
        }
        parts.sweepEdges = edges
        parts.sweepEdgeLines = edges.flatMap { model.edgePolylines($0) }
        updatePreview()
    }

    func clearSweepEdges() {
        parts.sweepEdges = []
        parts.sweepEdgeLines = []
        updatePreview()
    }
}

// MARK: - Parameterkarte

struct PartCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var parts: PartSettings
    let kind: PartTool

    var body: some View {
        Card {
            switch kind {
            case .standard: standardCard
            case .template: templateCard
            case .helix: helixCard
            case .thread: ThreadCard(workspace: workspace, parts: parts)
            case .thinLines: thinLinesCard
            case .draft: draftCard
            }
        }
    }

    /// Bindung, die nach jeder Änderung die Vorschau neu rechnet.
    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<PartSettings, T>) -> Binding<T> {
        Binding(get: { parts[keyPath: keyPath] }, set: { value in
            parts[keyPath: keyPath] = value
            workspace.updatePartPreview()
        })
    }

    private func field(_ title: String, _ keyPath: ReferenceWritableKeyPath<PartSettings, Double>, unit: String = "mm",
                       width: CGFloat = 60, minimum: Double = 0.01) -> some View {
        NumberField(title: title, value: parts[keyPath: keyPath], unit: unit, width: width) { value in
            guard value >= minimum else { return }
            parts[keyPath: keyPath] = value
            workspace.updatePartPreview()
        }
    }

    private func title(_ text: String, _ systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .fixedSize()
    }

    // MARK: Normteile

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                title("Normteil", parts.standard.kind.systemImage)
                Picker("Art", selection: binding(\.standard.kind)) {
                    ForEach(StandardPartKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                if parts.standard.kind == .bearing {
                    Picker("Lager", selection: binding(\.standard.bearing)) {
                        ForEach(BearingSize.all.indices, id: \.self) { index in
                            let b = BearingSize.all[index]
                            Text("\(b.name) (\(b.d.formatted())×\(b.outer.formatted())×\(b.width.formatted()))").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Picker("Größe", selection: binding(\.standard.size)) {
                        ForEach(MetricSize.all.indices, id: \.self) { index in
                            Text(MetricSize.all[index].name).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            HStack(spacing: 12) {
                if parts.standard.kind.isScrew {
                    field("Länge", \.standard.length, minimum: 1)
                    Menu("Normlänge") {
                        ForEach(parts.standard.metric.standardLengths, id: \.self) { length in
                            Button("\(length.formatted()) mm") {
                                parts.standard.length = length
                                workspace.updatePartPreview()
                            }
                        }
                    }
                    .fixedSize()
                }
                if parts.standard.kind.isScrew || parts.standard.kind == .nut {
                    Toggle("Echtes Gewinde", isOn: binding(\.standard.realThread))
                        .fixedSize()
                        .hoverTip("Echtes Gewinde", "Schraubenförmige Gewindenut statt glattem Schaft. Rechnet einige Sekunden; für den 3D-Druck ab etwa M5 sinnvoll.")
                }
                if parts.standard.kind == .bearing {
                    Toggle("Kugeln mit Käfig", isOn: binding(\.standard.balls))
                        .fixedSize()
                }
                Text(parts.standard.bodyName)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    // MARK: Vorlagen

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                title("Vorlage", parts.template.kind.systemImage)
                Picker("Vorlage", selection: binding(\.template.kind)) {
                    ForEach(TemplateKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            switch parts.template.kind {
            case .enclosure:
                HStack(spacing: 12) {
                    field("L", \.template.boxLength)
                    field("B", \.template.boxWidth)
                    field("H", \.template.boxHeight)
                    field("Wand", \.template.wall, width: 48)
                    field("Ecken R", \.template.cornerRadius, width: 48, minimum: 0)
                    Toggle("Deckel", isOn: binding(\.template.lid))
                        .fixedSize()
                }
            case .gear:
                HStack(spacing: 12) {
                    field("Modul", \.template.module, unit: "", width: 48)
                    NumberField(title: "Zähne", value: Double(parts.template.teeth), unit: "", width: 48) { value in
                        let teeth = Int(value.rounded())
                        guard teeth >= 6, teeth <= 300 else { return }
                        parts.template.teeth = teeth
                        workspace.updatePartPreview()
                    }
                    field("Breite", \.template.gearWidth, width: 48)
                    field("Bohrung", \.template.bore, width: 48, minimum: 0)
                    Text("Teilkreis Ø \((parts.template.module * Double(parts.template.teeth)).formatted()) mm")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .fixedSize()
    }

    // MARK: Helix

    private var helixCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                title("Helix", "tornado")
                Picker("Profil", selection: binding(\.helix.profile)) {
                    ForEach(HelixProfile.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if parts.helix.onCylinder {
                    Text(parts.helix.convex ? "Gewinde auf Bolzen" : "Gewinde in Bohrung")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button("Frei", systemImage: "xmark.circle") {
                        workspace.startPart(.helix)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .hoverTip("Frei", "Gewinde nicht mehr in die Zylinderfläche schneiden, sondern frei am Ursprung erzeugen.")
                } else {
                    Picker("Ergebnis", selection: binding(\.helix.mode)) {
                        ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            HStack(spacing: 12) {
                field("Ø", \.helix.diameter, width: 52)
                field("Steigung", \.helix.pitch, width: 52)
                field("Höhe", \.helix.height, width: 52)
                NumberField(title: "Windungen", value: (parts.helix.turns * 100).rounded() / 100, unit: "", width: 48) { turns in
                    guard turns > 0 else { return }
                    parts.helix.height = turns * parts.helix.pitch
                    workspace.updatePartPreview()
                }
                if parts.helix.profile != .thread {
                    field("Draht", \.helix.wire, width: 48)
                }
                Toggle("Linksgängig", isOn: binding(\.helix.leftHanded))
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    // MARK: Dünn extrudieren (Linien)

    private var thinLinesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                title("Dünn extrudieren", "square.dashed")
                Picker("Skizze", selection: binding(\.thinSketch)) {
                    Text("Skizze wählen").tag(Int?.none)
                    ForEach(model.pathSketches, id: \.self) { index in
                        Text(model.sketches[index].name).tag(Int?.some(index))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Ergebnis", selection: binding(\.thinMode)) {
                    ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(spacing: 12) {
                Picker("Seite", selection: binding(\.thinSide)) {
                    ForEach(ThinSide.allCases) { Text($0.lineTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .hoverTip("Seite", "Wand mittig auf der Linie oder ganz auf einer Seite. Bei geschlossenen Linienzügen ist Seite 1 innen.")
                field("Stärke", \.thinThickness, width: 52)
                NumberField(title: parts.thinSymmetric ? "Je Seite" : "Höhe", value: parts.thinHeight, width: 56) { value in
                    guard value != 0 else { return }
                    parts.thinHeight = value
                    workspace.updatePartPreview()
                }
                Toggle("Symmetrisch", isOn: binding(\.thinSymmetric))
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    // MARK: Verjüngung

    private var draftCard: some View {
        HStack(spacing: 12) {
            title("Verjüngung", "trapezoid.and.line.vertical")
            NumberField(title: "Winkel", value: parts.draftAngle, unit: "°", width: 48) { value in
                guard abs(value) < 89 else { return }
                parts.draftAngle = value
                workspace.updatePartPreview()
            }
            Picker("Zugrichtung", selection: binding(\.draftAxis)) {
                Text("X").tag(0)
                Text("Y").tag(1)
                Text("Z").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .hoverTip("Zugrichtung", "Richtung, in der das Teil aus der Form gezogen wird. Die Flächen werden dazu geneigt; die Neutralebene liegt am unteren Ende des Körpers.")
            Toggle("Umkehren", isOn: binding(\.draftFlip))
                .fixedSize()
            Text(model.selectedFaces.count == 1 ? "1 Fläche" : "\(model.selectedFaces.count) Flächen")
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .fixedSize()
    }
}
