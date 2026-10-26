import SwiftUI
import UniformTypeIdentifiers

/// „Zeichnung erstellen“: Vorschau der technischen Zeichnung (A4 quer) mit Sichern als PDF bzw. DXF und Teilen.
struct DrawingSheet: View {
    @ObservedObject var model: ModelStore
    let projectName: String
    @Environment(\.dismiss) private var dismiss

    @State private var options = DrawingOptions()
    @State private var cache: [DrawingView: DrawingProjection] = [:]
    @State private var cachedBodies: [Int] = []
    @State private var layout: DrawingLayout?
    @State private var preview: UIImage?
    @State private var isWorking = false
    /// Fortschritt: berechnete und zu berechnende Ansichten
    @State private var finishedViews = 0
    @State private var totalViews = 0
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .pdf
    @State private var isExporting = false
    @State private var shareURL: URL?

    /// Gewählte Körper (Körper, Fläche oder Kante gewählt), sonst alle sichtbaren.
    private var selectedBodies: [Int] {
        let chosen = model.selectedBodies.isEmpty ? (model.selectedBody.map { [$0] } ?? []) : model.selectedBodies
        return chosen.filter { model.bodies.indices.contains($0) }
    }

    private var bodies: [Int] {
        if options.onlySelection, !selectedBodies.isEmpty { return selectedBodies }
        return model.bodies.indices.filter { !model.bodies[$0].isHidden }
    }

    private var fileName: String { "\(projectName) Zeichnung" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if isWorking {
                        progressBadge
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .aspectRatio(TechnicalDrawing.sheetWidth / TechnicalDrawing.sheetHeight, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                optionsBar
                if let layout, layout.approximate {
                    Text(PCKShape.kernelAvailable
                         ? "Verdeckte Kanten angenähert (exakte Berechnung nicht möglich)."
                         : "Ohne OpenCASCADE: Ansichten aus dem Anzeige-Netz, verdeckte Kanten angenähert.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Zeichnung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Als PDF sichern …", systemImage: "doc.richtext") { save(pdf: true) }
                        Button("Als DXF sichern …", systemImage: "square.and.arrow.down") { save(pdf: false) }
                    } label: {
                        Label("Sichern", systemImage: "square.and.arrow.down")
                    }
                    .disabled(layout == nil || isWorking)
                    if let shareURL {
                        ShareLink(item: shareURL)
                    }
                }
            }
        }
        .task(id: options) { await rebuild() }
        .fileExporter(isPresented: $isExporting, document: exportFile, contentType: exportType,
                      defaultFilename: fileName) { _ in }
    }

    @ViewBuilder
    private var progressBadge: some View {
        if totalViews > 0 {
            ProgressView(value: Double(finishedViews), total: Double(totalViews)) {
                Text("Ansichten werden berechnet … (\(finishedViews) von \(totalViews))")
            }
            .frame(maxWidth: 280)
        } else {
            ProgressView("Ansichten werden berechnet …")
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 16) {
            if !selectedBodies.isEmpty {
                Picker("Körper", selection: $options.onlySelection) {
                    Text("Auswahl").tag(true)
                    Text("Alle sichtbaren").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            Picker("Projektion", selection: $options.method) {
                ForEach(ProjectionMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Verdeckte Kanten", isOn: $options.showsHidden)
                .fixedSize()
            Toggle("Isometrie", isOn: $options.showsIso)
                .fixedSize()
        }
        .font(.callout)
    }

    /// Ansichten (falls nötig) berechnen, Blatt anordnen, Vorschau und Teilen-Datei erzeugen.
    @MainActor
    private func rebuild() async {
        isWorking = true
        // Kurz warten, damit der Fortschritt sichtbar ist, bevor der Kernel rechnet
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }
        let indices = bodies
        if indices != cachedBodies {
            cache = [:]
            cachedBodies = indices
        }
        let shapes = indices.map { model.bodies[$0].shape }
        var views: [DrawingView] = [.front, .top, options.method.sideView]
        if options.showsIso { views.append(.iso) }
        let missing: [DrawingView] = shapes.isEmpty ? [] : views.filter { cache[$0] == nil }
        if !missing.isEmpty {
            // Verdeckte Kanten (HLR) dauern bei großen Körpern: im Hintergrund rechnen, damit die App bedienbar
            // bleibt. Der Kernel bekommt eigene Kopien (BRepBuilderAPI_Transform mit Kopie), weil die App die
            // Originale währenddessen weiter benutzt (z. B. Netz neu berechnen); OpenCASCADE-Formen sind
            // nicht für gleichzeitigen Zugriff gemacht.
            let copies = shapes.compactMap { $0.translated(by: SIMD3<Double>(0, 0, 0)) }
            let inBackground = copies.count == shapes.count
            finishedViews = 0
            totalViews = missing.count
            for view in missing {
                let projection: DrawingProjection
                if inBackground {
                    projection = await Task.detached(priority: .userInitiated) {
                        TechnicalDrawing.project(copies, view: view)
                    }.value
                } else {
                    projection = TechnicalDrawing.project(shapes, view: view)
                }
                // Inzwischen andere Körper gewählt: Ergebnis gehört nicht mehr zu dieser Zeichnung
                guard indices == cachedBodies else { return }
                cache[view] = projection
                finishedViews += 1
                guard !Task.isCancelled else { return }
            }
            totalViews = 0
        }
        let subtitle = indices.count == 1 ? model.bodies[indices[0]].name : "\(indices.count) Körper"
        let result = TechnicalDrawing.layout(shapes.isEmpty ? [:] : cache, options: options, title: projectName,
                                             subtitle: subtitle)
        layout = result
        preview = TechnicalDrawing.image(result, width: 1400)
        shareURL = writeShareFile(result)
        isWorking = false
    }

    /// PDF im temporären Ordner für „Teilen“.
    @MainActor
    private func writeShareFile(_ layout: DrawingLayout) -> URL? {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).pdf")
        do {
            try TechnicalDrawing.pdfData(layout, title: projectName).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    private func save(pdf: Bool) {
        guard let layout else { return }
        exportFile = ExportFile(data: pdf ? TechnicalDrawing.pdfData(layout, title: projectName)
                                          : TechnicalDrawing.dxfData(layout))
        exportType = pdf ? .pdf : .dxfFile
        isExporting = true
    }
}
