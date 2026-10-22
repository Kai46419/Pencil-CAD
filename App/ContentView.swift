import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ModelStore()
    @State private var exportDocument: STLDocument?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            Viewport(mesh: model.mesh, revision: model.revision)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomLeading) { statusBar }
                .navigationTitle("PencilCAD")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
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
