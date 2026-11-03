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
    // Winkelmaße von Hand (Punkt 15): Werkzeug, erste angetippte Kante, Auswahl, Verschieben
    @State private var manualAngles: [DrawingAngle] = []
    @State private var angleTool = false
    @State private var manualLengths: [DrawingLength] = []
    @State private var lengthTool = false
    @State private var lengthKind = DrawingLengthKind.aligned
    @State private var firstVertex: DrawingVertex?
    @State private var selectedLength: UUID?
    @State private var draggedLength: UUID?
    @State private var dragStartLengthHandle = Point2.zero
    @State private var pickedEdge: (Point2, Point2)?
    @State private var pickedTap = Point2.zero
    @State private var selectedAngle: UUID?
    @State private var draggedAngle: UUID?
    @State private var dragStartHandle = Point2.zero
    @State private var isDragging = false
    /// Startstelle der laufenden Geste (erkennt eine neue Geste, falls eine abgebrochene kein onEnded lieferte)
    @State private var dragStartLocation = CGPoint.zero
    @State private var angleOverlay: UIImage?
    @State private var angleHint: String?

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
                    if let angleOverlay {
                        Image(uiImage: angleOverlay)
                            .resizable()
                            .scaledToFit()
                            .allowsHitTesting(false)
                    }
                    GeometryReader { proxy in
                        angleHighlights(size: proxy.size)
                            .contentShape(Rectangle())
                            .gesture(sheetGesture(size: proxy.size))
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
                angleBar
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
                    if selectedAngle != nil || selectedLength != nil {
                        Button("Maß löschen", systemImage: "trash", role: .destructive) { deleteSelectedDimension() }
                    }
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
            // Ersteller im Schriftfeld („Created by …“), wird für alle Zeichnungen gemerkt
            TextField("Erstellt von", text: $options.author)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 170)
                .onChange(of: options.author) { _, name in DrawingOptions.savedAuthor = name }
        }
        .font(.callout)
    }

    /// Zweite Zeile: Winkelmaße automatisch bzw. von Hand setzen
    private var angleBar: some View {
        HStack(spacing: 16) {
            Toggle("Winkelmaße automatisch", isOn: $options.showsAngles)
                .fixedSize()
            Toggle(isOn: $angleTool) {
                Label("Winkelmaß setzen", systemImage: "angle")
            }
            .toggleStyle(.button)
            .onChange(of: angleTool) { _, _ in
                pickedEdge = nil
                angleHint = nil
                if angleTool { lengthTool = false; firstVertex = nil }
            }
            Toggle(isOn: $lengthTool) {
                Label("Längenmaß setzen", systemImage: "ruler")
            }
            .toggleStyle(.button)
            .onChange(of: lengthTool) { _, _ in
                firstVertex = nil
                angleHint = nil
                if lengthTool { angleTool = false; pickedEdge = nil }
            }
            if lengthTool {
                Picker("Messart", selection: $lengthKind) {
                    ForEach(DrawingLengthKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Text(angleHint ?? angleToolText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private var angleToolText: String {
        if lengthTool { return firstVertex == nil ? "Ersten Endpunkt antippen" : "Zweiten Endpunkt derselben Ansicht antippen" }
        if angleTool { return pickedEdge == nil ? "Erste Kante antippen" : "Zweite Kante antippen" }
        if !manualAngles.isEmpty { return "Winkelmaß ziehen zum Verschieben, antippen zum Auswählen" }
        return ""
    }

    /// Blattpunkt (mm, y nach oben) aus einer Stelle der Vorschau.
    private func sheetPoint(_ location: CGPoint, size: CGSize) -> Point2 {
        let k = max(Double(size.width), 1) / TechnicalDrawing.sheetWidth
        return Point2(Double(location.x) / k, TechnicalDrawing.sheetHeight - Double(location.y) / k)
    }

    /// Hervorhebung der gewählten Kante bzw. des gewählten Winkelmaßes.
    private func angleHighlights(size: CGSize) -> some View {
        let k = Double(size.width) / TechnicalDrawing.sheetWidth
        let edge = pickedEdge
        let selected = manualAngles.first { $0.id == selectedAngle }.flatMap { TechnicalDrawing.angleShape($0) }
        let selectedLinear = manualLengths.first { $0.id == selectedLength }.flatMap { TechnicalDrawing.lengthShape($0) }
        let vertex = firstVertex?.point
        return Canvas { context, _ in
            func point(_ p: Point2) -> CGPoint { CGPoint(x: p.x * k, y: (TechnicalDrawing.sheetHeight - p.y) * k) }
            if let vertex {
                let p = point(vertex)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                               with: .color(.accentColor), lineWidth: 3)
            }
            if let edge {
                var path = Path()
                path.move(to: point(edge.0))
                path.addLine(to: point(edge.1))
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            if let selected {
                var path = Path()
                path.addLines(selected.arc.map(point))
                let a = point(selected.label.min), b = point(selected.label.max)
                path.addRect(CGRect(x: min(a.x, b.x) - 3, y: min(a.y, b.y) - 3,
                                    width: abs(b.x - a.x) + 6, height: abs(b.y - a.y) + 6))
                context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            if let selectedLinear {
                var path = Path()
                path.addLines(selectedLinear.line.map(point))
                context.stroke(path, with: .color(.accentColor), lineWidth: 3)
            }
        }
    }

    /// Eine Geste für Antippen (Kante wählen, Winkelmaß auswählen) und Ziehen (Winkelmaß verschieben).
    @MainActor
    private func sheetGesture(size: CGSize) -> some Gesture {
        let k = max(Double(size.width), 1) / TechnicalDrawing.sheetWidth
        return DragGesture(minimumDistance: 0)
            .onChanged { value in dragChanged(value, size: size, k: k) }
            .onEnded { value in dragEnded(value, size: size, k: k) }
    }

    /// Trifft die Stelle ein von Hand gesetztes Winkelmaß?
    private func manualAngle(at point: Point2, tolerance: Double) -> DrawingAngle? {
        manualAngles.first { angle in
            guard let shape = TechnicalDrawing.angleShape(angle) else { return false }
            return TechnicalDrawing.hits(shape, point, tolerance: tolerance)
        }
    }

    private func manualLength(at point: Point2, tolerance: Double) -> DrawingLength? {
        manualLengths.first { length in
            guard let shape = TechnicalDrawing.lengthShape(length) else { return false }
            return TechnicalDrawing.hitsLength(shape, point, tolerance: tolerance)
        }
    }

    @MainActor
    private func dragChanged(_ value: DragGesture.Value, size: CGSize, k: Double) {
        if !isDragging || value.startLocation != dragStartLocation {
            isDragging = true
            dragStartLocation = value.startLocation
            let hit = manualAngle(at: sheetPoint(value.startLocation, size: size), tolerance: 16 / k)
            draggedAngle = hit?.id
            dragStartHandle = hit?.handle ?? .zero
            let linear = manualLength(at: sheetPoint(value.startLocation, size: size), tolerance: 16 / k)
            draggedLength = hit == nil ? linear?.id : nil
            dragStartLengthHandle = linear?.handle ?? .zero
        }
        let distance = hypot(Double(value.translation.width), Double(value.translation.height))
        if let id = draggedLength, distance > 6,
           let index = manualLengths.firstIndex(where: { $0.id == id }) {
            let delta = Point2(Double(value.translation.width) / k, -Double(value.translation.height) / k)
            manualLengths[index].handle = dragStartLengthHandle + delta
            selectedLength = id
            selectedAngle = nil
            refreshAngleOverlay()
            return
        }
        guard let id = draggedAngle, distance > 6,
              let index = manualAngles.firstIndex(where: { $0.id == id }) else { return }
        let delta = Point2(Double(value.translation.width) / k, -Double(value.translation.height) / k)
        manualAngles[index].handle = dragStartHandle + delta
        selectedAngle = id
        refreshAngleOverlay()
    }

    @MainActor
    private func dragEnded(_ value: DragGesture.Value, size: CGSize, k: Double) {
        let moved = hypot(Double(value.translation.width), Double(value.translation.height)) > 6
        let wasDragging = draggedAngle != nil || draggedLength != nil
        isDragging = false
        draggedAngle = nil
        draggedLength = nil
        if !moved {
            tapSheet(at: sheetPoint(value.location, size: size), tolerance: 16 / k)
        } else if wasDragging {
            refreshShareFile()
        }
    }

    /// Antippen: Winkelmaß auswählen bzw. mit dem Werkzeug Kanten wählen.
    @MainActor
    private func tapSheet(at point: Point2, tolerance: Double) {
        if let hit = manualLength(at: point, tolerance: tolerance) {
            selectedLength = selectedLength == hit.id ? nil : hit.id
            selectedAngle = nil
            return
        }
        if let hit = manualAngle(at: point, tolerance: tolerance) {
            selectedAngle = selectedAngle == hit.id ? nil : hit.id
            selectedLength = nil
            return
        }
        selectedAngle = nil
        selectedLength = nil
        if lengthTool, let layout {
            guard let vertex = TechnicalDrawing.nearestVertex(in: layout, to: point, maxDistance: tolerance) else {
                angleHint = "Keinen Endpunkt getroffen – näher an eine Kante tippen"
                return
            }
            guard let first = firstVertex else {
                firstVertex = vertex
                angleHint = nil
                return
            }
            guard first.view == vertex.view else {
                angleHint = "Beide Punkte müssen in derselben Ansicht liegen"
                return
            }
            guard let length = TechnicalDrawing.length(from: first, to: vertex, kind: lengthKind) else {
                angleHint = "Zwei verschiedene Punkte für dieses Maß wählen"
                return
            }
            firstVertex = nil
            angleHint = nil
            manualLengths.append(length)
            selectedLength = length.id
            refreshAngleOverlay()
            refreshShareFile()
            return
        }
        guard angleTool, let layout else { return }
        guard let edge = TechnicalDrawing.nearestEdge(in: layout, to: point, maxDistance: tolerance * 1.4) else {
            angleHint = "Keine Kante getroffen – näher an eine Linie tippen"
            return
        }
        angleHint = nil
        guard let first = pickedEdge else {
            pickedEdge = edge
            pickedTap = point
            return
        }
        pickedEdge = nil
        guard let angle = TechnicalDrawing.angle(edge: first, tap: pickedTap, edge: edge, tap: point) else {
            angleHint = "Die Kanten sind parallel – kein Winkel"
            return
        }
        manualAngles.append(angle)
        selectedAngle = angle.id
        refreshAngleOverlay()
        refreshShareFile()
    }

    @MainActor
    private func deleteSelectedDimension() {
        manualAngles.removeAll { $0.id == selectedAngle }
        manualLengths.removeAll { $0.id == selectedLength }
        selectedAngle = nil
        selectedLength = nil
        refreshAngleOverlay()
        refreshShareFile()
    }

    /// Ebene mit den von Hand gesetzten Winkelmaßen über der Vorschau (schnell beim Verschieben).
    @MainActor
    private func refreshAngleOverlay() {
        var elements: [DrawingElement] = []
        for angle in manualAngles {
            if let shape = TechnicalDrawing.angleShape(angle) { elements += shape.elements }
        }
        for length in manualLengths {
            if let shape = TechnicalDrawing.lengthShape(length) { elements += shape.elements }
        }
        angleOverlay = elements.isEmpty ? nil : TechnicalDrawing.overlayImage(elements, width: 1400)
    }

    @MainActor
    private func refreshShareFile() {
        guard let layout else { return }
        shareURL = writeShareFile(layout)
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
                guard indices == cachedBodies else {
                    totalViews = 0
                    return
                }
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
        // Von Hand gesetzte Winkelmaße behalten, solange ihre Kanten noch auf dem Blatt sind
        manualAngles.removeAll { angle in
            !TechnicalDrawing.containsEdge(result, angle.a0, angle.a1)
                || !TechnicalDrawing.containsEdge(result, angle.b0, angle.b1)
        }
        manualLengths.removeAll { length in
            !TechnicalDrawing.containsVertex(length.from, in: result)
                || !TechnicalDrawing.containsVertex(length.to, in: result)
        }
        if let id = selectedAngle, !manualAngles.contains(where: { $0.id == id }) { selectedAngle = nil }
        if let id = selectedLength, !manualLengths.contains(where: { $0.id == id }) { selectedLength = nil }
        pickedEdge = nil
        firstVertex = nil
        refreshAngleOverlay()
        shareURL = writeShareFile(result)
        isWorking = false
    }

    /// PDF im temporären Ordner für „Teilen“.
    @MainActor
    private func writeShareFile(_ layout: DrawingLayout) -> URL? {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).pdf")
        do {
            try TechnicalDrawing.pdfData(TechnicalDrawing.withDimensions(layout, angles: manualAngles, lengths: manualLengths), title: projectName,
                                         author: options.author).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    private func save(pdf: Bool) {
        guard let base = layout else { return }
        let layout = TechnicalDrawing.withDimensions(base, angles: manualAngles, lengths: manualLengths)
        exportFile = ExportFile(data: pdf ? TechnicalDrawing.pdfData(layout, title: projectName, author: options.author)
                                          : TechnicalDrawing.dxfData(layout))
        exportType = pdf ? .pdf : .dxfFile
        isExporting = true
    }
}
