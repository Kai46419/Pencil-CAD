import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ModelStore()
    @StateObject private var sketch = SketchController()
    @State private var viewCommand = ViewCommand()

    @State private var extrudeDistance: Double = 10
    @State private var extrudeMode: ExtrudeMode = .newBody

    @State private var edgeOperation: EdgeOperation = .fillet
    @State private var edgeValue: Double = 1
    @State private var isEdgeDialogShown = false

    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .stl
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isClearConfirmationShown = false

    var body: some View {
        NavigationStack {
            Viewport(model: model, sketch: sketch, command: viewCommand)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) { if sketch.isActive { sketchBar } }
                .overlay(alignment: .bottom) { bottomBar }
                .navigationTitle("PencilCAD")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .onChange(of: sketch.isActive) { _, isActive in
                    // Ist beim Einschalten eine ebene Fläche gewählt, wird sie zur Skizzenebene.
                    if isActive, let face = model.selection, let plane = model.plane(of: face) {
                        sketch.plane = plane
                        send(.alignToSketchPlane)
                    }
                }
                .alert(edgeOperation.rawValue, isPresented: $isEdgeDialogShown) {
                    TextField("mm", value: $edgeValue, format: .number)
                        .keyboardType(.decimalPad)
                    Button("Abbrechen", role: .cancel) {}
                    Button("Anwenden") { model.applyEdgeOperation(edgeOperation, value: edgeValue) }
                } message: {
                    Text(edgeOperation == .fillet
                         ? "Radius in mm für alle Kanten der gewählten Fläche"
                         : "Fasenbreite in mm für alle Kanten der gewählten Fläche")
                }
                .confirmationDialog("Alle Körper löschen?", isPresented: $isClearConfirmationShown,
                                    titleVisibility: .visible) {
                    Button("Alles löschen", role: .destructive, action: model.clear)
                }
                .fileExporter(isPresented: $isExporting, document: exportFile,
                              contentType: exportType, defaultFilename: "Teil") { _ in }
                .fileImporter(isPresented: $isImporting, allowedContentTypes: [.stepFile, .stpFile]) { result in
                    if case .success(let url) = result {
                        model.importSTEP(from: url)
                        send(.fitAll)
                    }
                }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Toggle(isOn: $sketch.isActive) {
                toolbarLabel("Skizze", "pencil.and.outline")
            }
            .toggleStyle(.button)

            Button(action: model.newBlock) {
                toolbarLabel("Quader", "cube")
            }

            Menu {
                Button("Kanten runden …", systemImage: "app") {
                    edgeOperation = .fillet
                    edgeValue = 1
                    isEdgeDialogShown = true
                }
                Button("Kanten fasen …", systemImage: "octagon") {
                    edgeOperation = .chamfer
                    edgeValue = 1
                    isEdgeDialogShown = true
                }
            } label: {
                toolbarLabel("Kanten", "square.on.square.squareshape.controlhandles")
            }
            .disabled(model.selection == nil)

            Button(action: model.deleteSelectedBody) {
                toolbarLabel("Löschen", "trash")
            }
            .disabled(model.selection == nil)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Rückgängig", systemImage: "arrow.uturn.backward", action: model.undo)
                .disabled(!model.canUndo)
            Button("Wiederholen", systemImage: "arrow.uturn.forward", action: model.redo)
                .disabled(!model.canRedo)
            Button("Einpassen", systemImage: "arrow.up.left.and.arrow.down.right") { send(.fitAll) }

            Menu {
                Button("STEP öffnen …", systemImage: "folder") { isImporting = true }
                Button("Als STEP exportieren …", systemImage: "square.and.arrow.up") {
                    if let data = model.stepData() {
                        export(data, as: .stepFile)
                    }
                }
                Button("Als STL exportieren …", systemImage: "square.and.arrow.up") {
                    export(model.stlData(), as: .stl)
                }
                Divider()
                Button(role: .destructive) {
                    isClearConfirmationShown = true
                } label: {
                    Label("Alles löschen …", systemImage: "trash")
                }
            } label: {
                toolbarLabel("Datei", "doc")
            }
        }
    }

    /// Symbol plus Text als feste Ansicht; ein Label zeigt in der iPadOS-Toolbar sonst nur das Symbol.
    private func toolbarLabel(_ title: String, _ systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .fixedSize()
    }

    // MARK: Skizzenleiste

    private var sketchBar: some View {
        HStack(spacing: 14) {
            Picker("Werkzeug", selection: $sketch.tool) {
                ForEach(SketchTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 330)

            if sketch.tool == .polyline, sketch.hasOpenPolyline {
                Button("Punkt zurück", systemImage: "delete.backward", action: sketch.undoPoint)
            }

            if sketch.plane.isOnFace {
                Text("Ebene: Fläche")
                Button("Boden") { sketch.plane = .ground }
            } else {
                HStack(spacing: 4) {
                    Text("Boden Z")
                    TextField("Z", value: $sketch.groundHeight, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Text("mm")
                }
            }

            Button("Draufsicht", systemImage: "scope") { send(.alignToSketchPlane) }

            Toggle("Finger zeichnet", isOn: $sketch.fingerDraws)
                .fixedSize()

            if let label = sketch.liveLabel {
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.blue)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }

    // MARK: Unten: Extrudieren + Status

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sketch.profile != nil {
                extrudePanel
                    .frame(maxWidth: .infinity)
            }
            statusBar
        }
        .padding()
    }

    private var extrudePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                if sketch.rectangleSize != nil {
                    numberField("Breite", value: rectangleBinding(\.x))
                    numberField("Tiefe", value: rectangleBinding(\.y))
                } else if sketch.circleDiameter != nil {
                    numberField("Ø", value: Binding(
                        get: { sketch.circleDiameter ?? 0 },
                        set: { sketch.circleDiameter = $0 }
                    ))
                }
                numberField(extrudeMode == .cut ? "Abziehen um" : "Höhe", value: $extrudeDistance)
            }

            HStack(spacing: 14) {
                Picker("Modus", selection: $extrudeMode) {
                    ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer(minLength: 0)

                Button("Verwerfen", role: .destructive, action: sketch.reset)
                    .fixedSize()
                Button("Extrudieren") {
                    if let profile = sketch.profile {
                        model.extrude(profile, on: sketch.plane, distance: extrudeDistance, mode: extrudeMode)
                        sketch.reset()
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(extrudeDistance == 0)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .fixedSize()
            TextField(title, value: value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
            Text("mm")
                .fixedSize()
        }
    }

    private func rectangleBinding(_ component: WritableKeyPath<SIMD2<Double>, Double>) -> Binding<Double> {
        Binding(
            get: { sketch.rectangleSize?[keyPath: component] ?? 0 },
            set: { newValue in
                guard var size = sketch.rectangleSize else { return }
                size[keyPath: component] = newValue
                sketch.rectangleSize = size
            }
        )
    }

    // MARK: Status

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.message {
                Text(message)
            } else if sketch.isActive {
                Text(sketch.fingerDraws
                     ? "Finger/Maus zeichnet · zum Drehen „Finger zeichnet“ ausschalten"
                     : "Pencil zeichnet · Finger-Tipp auf eine ebene Fläche skizziert darauf")
            } else if model.selection != nil {
                Text("Fläche gewählt: Kanten runden/fasen, Körper löschen oder „Skizze“ tippen, um darauf zu zeichnen")
            } else {
                Text("Start: oben „Skizze“ tippen und ein Rechteck aufziehen · Fläche antippen = auswählen")
            }
            Text(PCKShape.kernelAvailable
                 ? "\(model.mesh.triangleCount) Dreiecke · Kernel: OpenCASCADE"
                 : "\(model.mesh.triangleCount) Dreiecke · Fallback ohne OpenCASCADE: nur Skizze + Neuer Körper (siehe README)")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Hilfen

    private func send(_ kind: ViewCommand.Kind) {
        viewCommand = ViewCommand(id: viewCommand.id + 1, kind: kind)
    }

    private func export(_ data: Data, as type: UTType) {
        exportFile = ExportFile(data: data)
        exportType = type
        isExporting = true
    }
}

extension UTType {
    static let stl = UTType(filenameExtension: "stl", conformingTo: .data) ?? .data
    static let stepFile = UTType(filenameExtension: "step", conformingTo: .data) ?? .data
    static let stpFile = UTType(filenameExtension: "stp", conformingTo: .data) ?? .data
}

/// Fertige Exportdaten (STL oder STEP) für den Datei-Export.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.stl, .stepFile] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
