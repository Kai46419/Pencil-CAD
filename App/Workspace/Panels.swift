import SwiftUI
import simd

// MARK: Bausteine

/// Zahlenfeld mit Titel und Einheit. Übernimmt den Wert beim Bestätigen.
struct NumberField: View {
    let title: String
    let value: Double
    var unit = "mm"
    var width: CGFloat = 72
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField(title, value: Binding(get: { value }, set: set),
                      format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .textFieldStyle(.roundedBorder)
            if !unit.isEmpty {
                Text(unit)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

/// Weiße, schwebende Karte.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.callout)
            .padding(14)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

extension Color {
    init(_ rgb: SIMD3<Float>) {
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

// MARK: Parameterkarte

/// Parameter des aktiven Werkzeugs (unten in der Mitte, über „Abbrechen/Fertig“).
struct ParameterCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController

    var body: some View {
        if sketch.isActive {
            sketchCard
        } else {
            switch workspace.tool {
            case .select:
                if !model.selectedEdges.isEmpty {
                    edgeCard
                } else if !model.selectedRegions.isEmpty {
                    regionCard
                } else if model.selection != nil, model.faceHandle != nil {
                    faceCard
                }
            case .insert(let primitive):
                insertCard(primitive)
            case .boolean(let kind):
                booleanCard(kind)
            case .move:
                moveCard
            case .mirror:
                mirrorCard
            case .shell:
                shellCard
            case .color:
                colorCard
            case .pattern(let kind):
                patternCard(kind)
            case .scale:
                scaleCard
            case .align:
                alignCard
            case .revolve:
                revolveCard
            case .sweep:
                sweepCard
            case .loft:
                loftCard
            case .split:
                splitCard
            case .section:
                sectionCard
            case .measure:
                measureCard
            case .construct(let kind):
                constructCard(kind)
            case .canvas(let id):
                canvasCard(id)
            case .scaleSketch:
                sketchScaleCard
            case .offsetEdges:
                Card {
                    Label("Kante versetzen: ebene Fläche antippen", systemImage: "square.dashed.inset.filled")
                }
            }
        }
    }

    // MARK: Skizze

    @ViewBuilder
    private var sketchCard: some View {
        if sketch.isChoosingPlane {
            planeChoiceCard
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        Label(sketch.tool.rawValue, systemImage: sketch.tool.systemImage)
                            .font(.callout.weight(.semibold))
                        planeMenu
                        if !sketch.plane.isOnFace, sketch.isEmpty {
                            NumberField(title: "Abstand", value: sketch.planeOffset, width: 60) { sketch.planeOffset = $0 }
                        }
                        if let label = sketch.liveLabel {
                            Text(label)
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    toolOptions
                }
            }
        }
    }

    /// Ebenenwahl beim Start einer Skizze.
    private var planeChoiceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Skizzenebene wählen")
                    .font(.callout.weight(.semibold))
                Text("Eine Ebene im Modell oder eine ebene Fläche antippen – oder hier wählen:")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        planeButton(.top)
                        planeButton(.front)
                        planeButton(.right)
                    }
                    GridRow {
                        planeButton(.bottom)
                        planeButton(.back)
                        planeButton(.left)
                    }
                }
            }
        }
    }

    private func planeButton(_ side: BasePlane) -> some View {
        Button {
            workspace.chooseSketchPlane(side)
        } label: {
            Text(side.rawValue)
                .font(.callout.weight(.medium))
                .frame(width: 92, height: 38)
        }
        .buttonStyle(.bordered)
    }

    /// Aktuelle Ebene; Wechsel auf eine Standardebene leert die Skizze.
    private var planeMenu: some View {
        Menu {
            ForEach(BasePlane.allCases) { side in
                Button(side.rawValue) { workspace.chooseSketchPlane(side) }
            }
        } label: {
            Label("Ebene: \(sketch.plane.name)", systemImage: "square.dashed")
        }
        .fixedSize()
    }

    /// Einstellungen des aktiven Skizzenwerkzeugs.
    @ViewBuilder
    private var toolOptions: some View {
        switch sketch.tool {
        case .polygon:
            Stepper("\(sketch.polygonSides) Seiten", value: $sketch.polygonSides, in: 3...24)
                .fixedSize()
        case .rectangle:
            Picker("Art", selection: $sketch.rectangleMode) {
                ForEach(RectangleMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        case .scale:
            HStack(spacing: 14) {
                NumberField(title: "Faktor", value: sketch.scaleFactor, unit: "×", width: 60) { value in
                    if value > 0 { sketch.scaleFactor = value }
                }
                Text(sketch.selection.isEmpty ? "Ganze Skizze" : "\(sketch.selection.count) gewählt")
                    .foregroundStyle(.secondary)
                Button("Skalieren", systemImage: "checkmark", action: sketch.applyScale)
                    .buttonStyle(.borderedProminent)
            }
        case .trim:
            Text("Kurvenstück antippen (Stift oder Finger)")
                .foregroundStyle(.secondary)
        case .project:
            Text("Körperkante oder Fläche antippen")
                .foregroundStyle(.secondary)
        case .polyline:
            if sketch.hasOpenChain {
                Button("Linie absetzen", systemImage: "scissors", action: sketch.endChain)
            }
        case .spline:
            HStack(spacing: 14) {
                Picker("Art", selection: $sketch.splineKind) {
                    ForEach(SplineKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if sketch.hasOpenSpline {
                    Button("Spline beenden", systemImage: "checkmark", action: sketch.finishSpline)
                }
            }
        case .text:
            HStack(spacing: 14) {
                Picker("Schrift", selection: $sketch.textFont) {
                    ForEach(SketchText.fonts) { Text($0.title).tag($0.name) }
                }
                .fixedSize()
                NumberField(title: "Höhe", value: sketch.textHeight, width: 56) { value in
                    if value > 0 { sketch.textHeight = value }
                }
                Picker("Ausrichtung", selection: $sketch.textAlignment) {
                    ForEach(TextAlignmentOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        case .offset:
            HStack(spacing: 14) {
                Picker("Art", selection: $sketch.offsetKind) {
                    ForEach(OffsetKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                NumberField(title: "Abstand", value: sketch.offsetDistance, width: 60) { sketch.offsetDistance = $0 }
                if sketch.hasOffsetTarget {
                    Button("Übernehmen", systemImage: "checkmark", action: sketch.applyOffset)
                        .buttonStyle(.borderedProminent)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Auswahl

    private var edgeCard: some View {
        Card {
            HStack(spacing: 16) {
                Picker("Operation", selection: $model.edgeOperation) {
                    ForEach(EdgeOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                NumberField(title: model.edgeOperation == .fillet ? "Radius" : "Breite", value: model.edgeValue) {
                    model.setEdgeValue($0)
                }
                Text(model.selectedEdges.count == 1 ? "1 Kante" : "\(model.selectedEdges.count) Kanten")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    /// Gewählte Skizzenbereiche extrudieren (Pfeil oder Wert).
    private var regionCard: some View {
        Card {
            HStack(spacing: 16) {
                Label("Extrudieren", systemImage: "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
                Picker("Modus", selection: $model.regionMode) {
                    ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                NumberField(title: "Abstand", value: model.regionValue) { model.setRegionValue($0) }
                Text(model.selectedRegions.count == 1 ? "1 Bereich" : "\(model.selectedRegions.count) Bereiche")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var faceCard: some View {
        Card {
            HStack(spacing: 16) {
                Label("Extrudieren", systemImage: "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
                NumberField(title: "Abstand", value: model.faceValue) { model.setFaceValue($0) }
            }
        }
    }

    // MARK: Werkzeuge

    private func insertCard(_ primitive: Primitive) -> some View {
        Card {
            HStack(spacing: 16) {
                Label(primitive.rawValue, systemImage: primitive.systemImage)
                    .font(.callout.weight(.semibold))
                switch primitive {
                case .box:
                    sizeField("Breite", 0)
                    sizeField("Tiefe", 1)
                    sizeField("Höhe", 2)
                case .cylinder, .cone:
                    sizeField("Ø", 0)
                    sizeField("Höhe", 2)
                case .sphere:
                    sizeField("Ø", 0)
                case .torus:
                    sizeField("Ø", 0)
                    sizeField("Rohr Ø", 2)
                }
            }
        }
    }

    private func sizeField(_ title: String, _ index: Int) -> some View {
        NumberField(title: title, value: workspace.insertSize[index]) { value in
            guard value > 0 else { return }
            workspace.insertSize[index] = value
            workspace.updateInsertPreview()
        }
    }

    private func booleanCard(_ kind: BooleanKind) -> some View {
        Card {
            HStack(spacing: 16) {
                Label(kind.rawValue, systemImage: kind.systemImage)
                    .font(.callout.weight(.semibold))
                if let target = model.selectedBodies.first, model.bodies.indices.contains(target) {
                    Text("Ziel: \(model.bodies[target].name)")
                    let tools = model.selectedBodies.dropFirst().filter { model.bodies.indices.contains($0) }
                    if !tools.isEmpty {
                        Text("Werkzeug: \(tools.map { model.bodies[$0].name }.joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Zuerst den Zielkörper antippen")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var moveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { axis in
                        NumberField(title: ["X", "Y", "Z"][axis], value: model.moveOffset[axis], width: 64) { value in
                            var offset = model.moveOffset
                            offset[axis] = value
                            model.setMoveOffset(offset)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Drehen")
                        .foregroundStyle(.secondary)
                    ForEach(0..<3, id: \.self) { axis in
                        let name = ["X", "Y", "Z"][axis]
                        let vector = Self.unitAxis(axis)
                        Button("\(name) −90°") { rotate(axis: vector, degrees: -90) }
                        Button("\(name) +90°") { rotate(axis: vector, degrees: 90) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.selectedBodies.isEmpty && model.movingSketch == nil)
            }
        }
    }

    private static func unitAxis(_ axis: Int) -> SIMD3<Double> {
        var vector = SIMD3<Double>(0, 0, 0)
        vector[axis] = 1
        return vector
    }

    /// Körper drehen, oder die Skizze, die gerade verschoben wird.
    private func rotate(axis: SIMD3<Double>, degrees: Double) {
        if let index = model.movingSketch {
            model.rotateSketch(index, axis: axis, degrees: degrees)
        } else {
            model.rotateSelected(axis: axis, degrees: degrees)
        }
    }

    private var mirrorCard: some View {
        Card {
            HStack(spacing: 16) {
                Label("Spiegeln", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.callout.weight(.semibold))
                Picker("Ebene", selection: Binding(get: { workspace.mirrorPlane }, set: { plane in
                    workspace.mirrorPlane = plane
                    workspace.updateMirrorPreview()
                })) {
                    ForEach(MirrorPlane.allCases) { Text("Ebene \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Original behalten", isOn: Binding(get: { workspace.mirrorKeepsOriginal }, set: { keep in
                    workspace.mirrorKeepsOriginal = keep
                    workspace.updateMirrorPreview()
                }))
                .fixedSize()
            }
        }
    }

    private var shellCard: some View {
        Card {
            HStack(spacing: 16) {
                Label("Schale", systemImage: "shippingbox")
                    .font(.callout.weight(.semibold))
                NumberField(title: "Wandstärke", value: workspace.shellThickness) { value in
                    guard value > 0 else { return }
                    workspace.shellThickness = value
                    workspace.updateShellPreview()
                }
            }
        }
    }

    private var colorCard: some View {
        Card {
            HStack(spacing: 10) {
                Label("Farbe", systemImage: "paintpalette")
                    .font(.callout.weight(.semibold))
                    .padding(.trailing, 6)
                ForEach(SceneBody.palette.indices, id: \.self) { index in
                    let color = SceneBody.palette[index]
                    let current = model.selectedBodies.first.flatMap {
                        model.bodies.indices.contains($0) ? model.bodies[$0].color : nil
                    }
                    Button {
                        model.setColor(color, of: model.selectedBodies)
                    } label: {
                        Circle()
                            .fill(Color(color))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if current == color {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(model.selectedBodies.isEmpty)
        }
    }
}

// MARK: Neue Werkzeuge

extension ParameterCard {
    private static let axisNames = ["X", "Y", "Z"]

    /// Auswahl einer Bezugsachse (Weltachsen, Konstruktionsachsen, optional Linien einer Skizze).
    func axisPicker(_ title: String, selection: Binding<ReferenceAxis>, sketchIndex: Int? = nil) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<3, id: \.self) { Text("\(Self.axisNames[$0])-Achse").tag(ReferenceAxis.world($0)) }
            if let sketchIndex {
                ForEach(model.sketchLines(sketchIndex)) { line in
                    Text(line.name).tag(ReferenceAxis.sketchLine(line.index))
                }
            }
            ForEach(model.constructions.filter { $0.kind == .axis }) { item in
                Text(item.name).tag(ReferenceAxis.construction(item.id))
            }
        }
        .fixedSize()
    }

    /// Auswahl einer Bezugsebene (Weltebenen, Konstruktionsebenen, angetippte Fläche).
    func planePicker(_ title: String, selection: Binding<ReferencePlane>) -> some View {
        var tappedFace: FaceRef?
        if case .face(let face) = selection.wrappedValue { tappedFace = face }
        return Picker(title, selection: selection) {
            Text("YZ (Normale X)").tag(ReferencePlane.world(0))
            Text("XZ (Normale Y)").tag(ReferencePlane.world(1))
            Text("XY (Normale Z)").tag(ReferencePlane.world(2))
            ForEach(model.constructions.filter { $0.kind == .plane }) { item in
                Text(item.name).tag(ReferencePlane.construction(item.id))
            }
            if let tappedFace {
                Text("Angetippte Fläche").tag(ReferencePlane.face(tappedFace))
            }
        }
        .fixedSize()
    }

    private func preview<T>(_ keyPath: ReferenceWritableKeyPath<Workspace, T>) -> Binding<T> {
        Binding(get: { workspace[keyPath: keyPath] }, set: { value in
            workspace[keyPath: keyPath] = value
            workspace.updatePreview()
        })
    }

    private func bodyCount() -> some View {
        Text(model.selectedBodies.isEmpty ? "Körper antippen"
             : model.selectedBodies.count == 1 ? "1 Körper" : "\(model.selectedBodies.count) Körper")
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    func patternCard(_ kind: PatternKind) -> some View {
        Card {
            HStack(spacing: 14) {
                Label(kind.rawValue, systemImage: kind.systemImage)
                    .font(.callout.weight(.semibold))
                Stepper("Anzahl \(workspace.patternCount)", value: preview(\.patternCount), in: 2...100)
                    .fixedSize()
                if kind == .linear {
                    NumberField(title: "Abstand", value: workspace.patternSpacing, width: 60) { value in
                        workspace.patternSpacing = value
                        workspace.updatePreview()
                    }
                    axisPicker("Richtung", selection: preview(\.patternAxis))
                } else {
                    NumberField(title: "Winkel", value: workspace.patternAngle, unit: "°", width: 56) { value in
                        workspace.patternAngle = max(-360, min(360, value))
                        workspace.updatePreview()
                    }
                    axisPicker("Achse", selection: preview(\.patternAxis))
                }
                bodyCount()
            }
        }
    }

    var scaleCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Skalieren", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.semibold))
                Toggle("Gleichmäßig", isOn: preview(\.scaleUniform))
                    .fixedSize()
                if workspace.scaleUniform {
                    NumberField(title: "Faktor", value: workspace.scaleFactors.x, unit: "×", width: 56) { value in
                        guard value > 0 else { return }
                        workspace.scaleFactors = SIMD3(repeating: value)
                        workspace.updatePreview()
                    }
                } else {
                    ForEach(0..<3, id: \.self) { axis in
                        NumberField(title: Self.axisNames[axis], value: workspace.scaleFactors[axis], unit: "×",
                                    width: 50) { value in
                            guard value > 0 else { return }
                            workspace.scaleFactors[axis] = value
                            workspace.updatePreview()
                        }
                    }
                }
                bodyCount()
            }
        }
    }

    var alignCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Ausrichten", systemImage: "align.horizontal.center")
                    .font(.callout.weight(.semibold))
                ForEach(0..<3, id: \.self) { axis in
                    Picker(Self.axisNames[axis], selection: Binding(get: { workspace.alignModes[axis] }, set: { mode in
                        workspace.alignModes[axis] = mode
                        workspace.updatePreview()
                    })) {
                        ForEach(AlignMode.allCases) { Text("\(Self.axisNames[axis]): \($0.rawValue)").tag($0) }
                    }
                    .fixedSize()
                }
                Text(model.selectedBodies.count < 2 ? "Bezug + Körper antippen"
                     : "An \(model.bodies.indices.contains(model.selectedBodies[0]) ? model.bodies[model.selectedBodies[0]].name : "")")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var solidModePicker: some View {
        Picker("Ergebnis", selection: preview(\.solidMode)) {
            ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var regionCount: some View {
        Text(model.selectedRegions.isEmpty ? "Bereich antippen"
             : model.selectedRegions.count == 1 ? "1 Bereich" : "\(model.selectedRegions.count) Bereiche")
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    var revolveCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Achsendrehung", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                axisPicker("Achse", selection: preview(\.revolveAxis), sketchIndex: model.selectedRegions.first?.sketch)
                NumberField(title: "Winkel", value: workspace.revolveAngle, unit: "°", width: 56) { value in
                    workspace.revolveAngle = max(-360, min(360, value))
                    workspace.updatePreview()
                }
                solidModePicker
                regionCount
            }
        }
    }

    var sweepCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Sweep", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))
                Picker("Pfad", selection: preview(\.sweepPath)) {
                    Text("Pfad wählen").tag(Int?.none)
                    ForEach(model.pathSketches, id: \.self) { index in
                        Text("Pfad: \(model.sketches[index].name)").tag(Int?.some(index))
                    }
                }
                .fixedSize()
                solidModePicker
                regionCount
            }
        }
    }

    var loftCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Loft", systemImage: "square.3.layers.3d")
                    .font(.callout.weight(.semibold))
                Text(model.selectedRegions.isEmpty ? "Querschnitte nacheinander antippen"
                     : "\(model.selectedRegions.count) Querschnitte")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                solidModePicker
                if !model.selectedRegions.isEmpty {
                    Button("Neu beginnen", systemImage: "arrow.counterclockwise") {
                        model.resetSelection()
                    }
                }
            }
        }
    }

    var splitCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Körper teilen", systemImage: "rectangle.split.2x1")
                    .font(.callout.weight(.semibold))
                planePicker("Ebene", selection: preview(\.splitPlane))
                NumberField(title: "Versatz", value: workspace.splitOffset, width: 60) { value in
                    workspace.splitOffset = value
                    workspace.updatePreview()
                }
                bodyCount()
            }
        }
    }

    var sectionCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Schnittansicht", systemImage: "square.split.diagonal.2x2")
                    .font(.callout.weight(.semibold))
                planePicker("Ebene", selection: Binding(get: { workspace.section?.plane ?? .world(1) },
                                                         set: { workspace.section?.plane = $0 }))
                NumberField(title: "Versatz", value: workspace.section?.offset ?? 0, width: 60) { value in
                    workspace.section?.offset = value
                }
                Toggle("Umkehren", isOn: Binding(get: { workspace.section?.flipped ?? false },
                                                 set: { workspace.section?.flipped = $0 }))
                    .fixedSize()
                Button("Aus", systemImage: "xmark") {
                    workspace.section = nil
                    workspace.activate(.select)
                }
            }
        }
    }

    var measureCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Label("Messen", systemImage: "ruler")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 3) {
                    if workspace.measureLines.isEmpty {
                        Text("Kante, Fläche oder zwei Punkte antippen")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(workspace.measureLines, id: \.self) { line in
                        Text(line)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    func constructCard(_ kind: ConstructionKind) -> some View {
        Card {
            HStack(spacing: 14) {
                Label("\(kind.rawValue) erstellen", systemImage: kind.systemImage)
                    .font(.callout.weight(.semibold))
                switch kind {
                case .plane:
                    planePicker("Bezug", selection: $workspace.constructReference)
                    NumberField(title: "Abstand", value: workspace.constructOffset, width: 60) {
                        workspace.constructOffset = $0
                    }
                case .axis:
                    if let custom = workspace.constructCustomAxis {
                        Text("Durch \(custom.name)")
                        Button("Weltachse", systemImage: "xmark") { workspace.constructCustomAxis = nil }
                    } else {
                        axisPicker("Achse", selection: $workspace.constructAxis)
                        Text("oder Kante/Fläche antippen")
                            .foregroundStyle(.secondary)
                    }
                case .point:
                    ForEach(0..<3, id: \.self) { axis in
                        NumberField(title: Self.axisNames[axis], value: workspace.constructPoint[axis], width: 60) {
                            workspace.constructPoint[axis] = $0
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func canvasCard(_ id: UUID) -> some View {
        if let canvas = model.canvases.first(where: { $0.id == id }) {
            Card {
                HStack(spacing: 14) {
                    Label(canvas.name, systemImage: "photo")
                        .font(.callout.weight(.semibold))
                    Picker("Ebene", selection: Binding(get: { canvas.plane }, set: { plane in
                        var changed = canvas
                        changed.plane = plane
                        model.updateCanvas(changed)
                    })) {
                        ForEach(BasePlane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    NumberField(title: "Breite", value: canvas.width, width: 60) { value in
                        guard value > 0 else { return }
                        var changed = canvas
                        changed.width = value
                        model.updateCanvas(changed)
                    }
                    NumberField(title: "X", value: canvas.offset.x, width: 54) { value in
                        var changed = canvas
                        changed.offset.x = value
                        model.updateCanvas(changed)
                    }
                    NumberField(title: "Y", value: canvas.offset.y, width: 54) { value in
                        var changed = canvas
                        changed.offset.y = value
                        model.updateCanvas(changed)
                    }
                    Slider(value: Binding(get: { canvas.opacity }, set: { value in
                        var changed = canvas
                        changed.opacity = value
                        model.updateCanvas(changed)
                    }), in: 0.1...1)
                    .frame(width: 90)
                    Button(role: .destructive) {
                        model.deleteCanvas(id)
                        workspace.activate(.select)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    var sketchScaleCard: some View {
        Card {
            HStack(spacing: 14) {
                Label("Skizze skalieren", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.semibold))
                NumberField(title: "Faktor", value: workspace.sketchScaleFactor, unit: "×", width: 56) { value in
                    if value > 0 { workspace.sketchScaleFactor = value }
                }
                if let index = model.selectedRegions.first?.sketch, model.sketches.indices.contains(index) {
                    Text(model.sketches[index].name)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bereich der Skizze antippen")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Verlauf

/// Liste der Schritte; Antippen springt zu diesem Stand (auch vorwärts).
struct HistoryPanel: View {
    @ObservedObject var model: ModelStore
    let close: () -> Void

    var body: some View {
        SidePanelFrame(title: "Verlauf", close: close) {
            row(step: 0, name: "Start", systemImage: "flag", isCurrent: model.history.isEmpty, isUndone: false)
            ForEach(Array(model.history.enumerated()), id: \.offset) { index, entry in
                row(step: index + 1, name: entry.name, systemImage: "checkmark.circle",
                    isCurrent: index + 1 == model.history.count, isUndone: false)
            }
            ForEach(Array(model.future.reversed().enumerated()), id: \.offset) { index, entry in
                row(step: model.history.count + index + 1, name: entry.name, systemImage: "arrow.uturn.forward.circle",
                    isCurrent: false, isUndone: true)
            }
            if let preview = model.previewName {
                Label("\(preview) (Vorschau)", systemImage: "ellipsis.circle")
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func row(step: Int, name: String, systemImage: String, isCurrent: Bool, isUndone: Bool) -> some View {
        Button {
            model.jump(toStep: step)
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(name)
                Spacer(minLength: 0)
                Text("\(step)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .foregroundStyle(isUndone ? Color.secondary : Color.primary)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Elemente

/// Körper der Szene: Farbe, Name, Sichtbarkeit; Antippen wählt den Körper.
struct ElementsPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    let close: () -> Void

    @State private var renaming: Int?
    @State private var newName = ""

    var body: some View {
        SidePanelFrame(title: "Elemente", close: close) {
            if model.bodies.isEmpty && model.sketches.isEmpty && model.constructions.isEmpty && model.canvases.isEmpty {
                Text("Noch keine Körper oder Skizzen")
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            if !model.sketches.isEmpty {
                sectionTitle("Skizzen")
                ForEach(model.sketches.indices, id: \.self) { index in
                    sketchRow(index)
                }
                if !model.bodies.isEmpty { sectionTitle("Körper") }
            }
            if !model.constructions.isEmpty {
                sectionTitle("Konstruktion")
                ForEach(model.constructions) { item in
                    constructionRow(item)
                }
            }
            if !model.canvases.isEmpty {
                sectionTitle("Bilder")
                ForEach(model.canvases) { canvas in
                    canvasRow(canvas)
                }
            }
            if !model.bodies.isEmpty, !model.constructions.isEmpty || !model.canvases.isEmpty, model.sketches.isEmpty {
                sectionTitle("Körper")
            }
            ForEach(model.bodies.indices, id: \.self) { index in
                let item = model.bodies[index]
                let isSelected = model.selectedBodies.contains(index) || model.selectedBody == index
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(item.color))
                        .frame(width: 14, height: 14)
                    Text(item.name)
                        .lineLimit(1)
                        .foregroundStyle(item.isHidden ? Color.secondary : Color.primary)
                    Spacer(minLength: 0)
                    Button {
                        model.setHidden(!item.isHidden, body: index)
                    } label: {
                        Image(systemName: item.isHidden ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { select(index) }
                .contextMenu {
                    Button("Umbenennen", systemImage: "pencil") {
                        newName = item.name
                        renaming = index
                    }
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        model.toggleBody(index, exclusive: true)
                        model.deleteSelected()
                    }
                }
            }
        }
        .alert("Körper umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") {
                if let renaming { model.rename(body: renaming, to: newName) }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    /// Skizze: antippen öffnet sie zum Bearbeiten, Auge blendet sie aus.
    private func sketchRow(_ index: Int) -> some View {
        let item = model.sketches[index]
        return HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(item.isHidden ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
            Button {
                model.setSketchHidden(!item.isHidden, sketch: index)
            } label: {
                Image(systemName: item.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(model.selectedRegions.first?.sketch == index ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { workspace.editSketch(index) }
        .contextMenu {
            Button("Bearbeiten", systemImage: "pencil") { workspace.editSketch(index) }
            Button("Löschen", systemImage: "trash", role: .destructive) { model.deleteSketch(index) }
        }
    }

    /// Konstruktionsebene, -achse oder -punkt: Ebenen lassen sich direkt als Skizzenebene nutzen.
    private func constructionRow(_ item: ConstructionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(.orange)
                .frame(width: 14)
            Text(item.name)
                .lineLimit(1)
                .foregroundStyle(item.isHidden ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
            Button {
                model.setConstructionHidden(!item.isHidden, id: item.id)
            } label: {
                Image(systemName: item.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.kind == .plane { workspace.startSketch(on: item.sketchPlane) }
        }
        .contextMenu {
            if item.kind == .plane {
                Button("Skizze auf dieser Ebene", systemImage: "pencil.and.outline") {
                    workspace.startSketch(on: item.sketchPlane)
                }
            }
            Button("Löschen", systemImage: "trash", role: .destructive) { model.deleteConstruction(item.id) }
        }
    }

    private func canvasRow(_ canvas: CanvasImage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(canvas.name)
                .lineLimit(1)
                .foregroundStyle(canvas.isHidden ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
            Button {
                var changed = canvas
                changed.isHidden.toggle()
                model.updateCanvas(changed)
            } label: {
                Image(systemName: canvas.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(workspace.tool == .canvas(canvas.id) ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(.canvas(canvas.id)) }
        .contextMenu {
            Button("Bearbeiten", systemImage: "slider.horizontal.3") { workspace.activate(.canvas(canvas.id)) }
            Button("Löschen", systemImage: "trash", role: .destructive) { model.deleteCanvas(canvas.id) }
        }
    }

    /// Im Auswahlwerkzeug wird der Körper allein gewählt, in Körperwerkzeugen hinzugefügt.
    private func select(_ index: Int) {
        switch workspace.tool {
        case .boolean, .mirror, .color, .pattern, .scale, .align:
            model.toggleBody(index)
            workspace.updateMirrorPreview()
            workspace.updatePreview()
        case .split:
            model.toggleBody(index, exclusive: true)
            workspace.updatePreview()
        default:
            model.toggleBody(index, exclusive: true)
        }
    }
}

/// Rahmen der rechten Fenster (Verlauf, Elemente). Lange Listen scrollen.
struct SidePanelFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(list)
            panel(ScrollView { list })
        }
        .frame(maxHeight: 460, alignment: .top)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
    }

    private func panel(_ inner: some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
            inner
        }
        .font(.callout)
        .padding(14)
        .frame(width: 280)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

// MARK: Text

/// Eingabe des Textinhalts nach dem Antippen der Position (wie Shapr3D: Inhalt, Schrift, Höhe, Ausrichtung).
struct TextEntrySheet: View {
    @ObservedObject var sketch: SketchController
    @State private var content = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Inhalt", text: $content)
                    .focused($isFocused)
                Picker("Schrift", selection: $sketch.textFont) {
                    ForEach(SketchText.fonts) { Text($0.title).tag($0.name) }
                }
                HStack {
                    Text("Höhe")
                    Spacer()
                    NumberField(title: "", value: sketch.textHeight, width: 70) { value in
                        if value > 0 { sketch.textHeight = value }
                    }
                }
                Picker("Ausrichtung", selection: $sketch.textAlignment) {
                    ForEach(TextAlignmentOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { sketch.pendingTextAnchor = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") { sketch.addText(content) }
                        .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }
}

// MARK: Screenshot

struct Screenshot: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ScreenshotSheet: View {
    let screenshot: Screenshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Image(uiImage: screenshot.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
                .navigationTitle("Screenshot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        let image = Image(uiImage: screenshot.image)
                        ShareLink(item: image, preview: SharePreview("PencilCAD Screenshot", image: image))
                    }
                }
        }
    }
}
