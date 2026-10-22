import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ModelStore()
    @StateObject private var sketch = SketchController()
    @State private var exportDocument: STLDocument?
    @State private var isExporting = false
    @State private var extrudeHeight: Double = 10
    @State private var extrudeMode: ExtrudeMode = .newBody

    var body: some View {
        NavigationStack {
            Viewport(mesh: model.mesh, revision: model.revision, sketch: sketch)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) { statusBar }
                .overlay(alignment: .top) { if sketch.isActive { sketchBar } }
                .overlay(alignment: .bottom) { if sketch.profile != nil { extrudePanel } }
                .navigationTitle("PencilCAD")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Toggle(isOn: $sketch.isActive) {
                            Label("Skizze", systemImage: "pencil.and.outline")
                        }
                        .toggleStyle(.button)
                        Button("Neuer Quader", systemImage: "cube", action: model.newBlock)
                        Button("Bohrung", systemImage: "circle.circle", action: model.drillHole)
                        Button("Kanten runden", systemImage: "square.on.square.squareshape.controlhandles",
                               action: model.roundEdges)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Rückgängig", systemImage: "arrow.uturn.backward", action: model.undo)
                            .disabled(!model.canUndo)
                        Button("STL exportieren", systemImage: "square.and.arrow.up") {
                            exportDocument = STLDocument(data: model.stlData())
                            isExporting = true
                        }
                    }
                }
                .fileExporter(isPresented: $isExporting, document: exportDocument,
                              contentType: .stl, defaultFilename: "Teil") { _ in }
        }
    }

    private var sketchBar: some View {
        HStack(spacing: 16) {
            Picker("Werkzeug", selection: $sketch.tool) {
                ForEach(SketchTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if sketch.tool == .polyline, sketch.hasOpenPolyline {
                Button("Punkt zurück", systemImage: "delete.backward", action: sketch.undoPoint)
            }

            HStack(spacing: 4) {
                Text("Ebene Z")
                TextField("Z", value: $sketch.planeZ, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                Text("mm")
            }

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

    private var extrudePanel: some View {
        HStack(spacing: 16) {
            Picker("Modus", selection: $extrudeMode) {
                ForEach(ExtrudeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            HStack(spacing: 4) {
                Text("Höhe")
                TextField("Höhe", value: $extrudeHeight, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Text("mm")
            }

            Button("Verwerfen", role: .destructive, action: sketch.reset)
            Button("Extrudieren") {
                if let profile = sketch.profile {
                    model.extrude(profile, planeZ: sketch.planeZ, height: extrudeHeight, mode: extrudeMode)
                    sketch.reset()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(extrudeHeight == 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 24)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.message {
                Text(message)
            }
            Text("\(model.mesh.triangleCount) Dreiecke · Kernel: \(PCKShape.kernelAvailable ? "OpenCASCADE" : "Fallback")")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }
}

extension UTType {
    static let stl = UTType(filenameExtension: "stl", conformingTo: .data) ?? .data
}

struct STLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stl] }

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
