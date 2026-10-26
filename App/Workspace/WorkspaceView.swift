import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Arbeitsbereich eines Projekts: Viewport mit schwebenden Leisten (Aufbau wie bei Shapr3D).
struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    let close: () -> Void

    var body: some View {
        WorkspaceContent(workspace: workspace, model: workspace.model, sketch: workspace.sketch, close: close)
    }
}

private struct WorkspaceContent: View {
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    let close: () -> Void

    @State private var openGroup: ToolGroup?
    @State private var panel: SidePanel?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var exportFile: ExportFile?
    @State private var exportType: UTType = .stl
    @State private var exportName: String?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isClearConfirmationShown = false
    /// Erklärung zur Auswahl eingeklappt (bleibt gespeichert)
    @State private var screenshot: Screenshot?
    @State private var photoItem: PhotosPickerItem?
    /// AR Quick Look: USDZ-Datei, die gerade gezeigt wird
    @State private var arPreview: URL?
    /// Zeitleiste des Verlaufs: automatisch, ein- oder ausgeblendet (TimelineBar.swift)
    @AppStorage(TimelineVisibility.storageKey) private var timelineVisibility = TimelineVisibility.automatic.rawValue

    private var projectName: String {
        projects.project(workspace.project.id)?.name ?? workspace.project.name
    }

    var body: some View {
        ZStack {
            Viewport(workspace: workspace, model: model, sketch: sketch)
                .overlay {
                    LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0), Color.black.opacity(0.025)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if let location = workspace.quickToolsLocation {
                        QuickToolsPalette(workspace: workspace, sketch: sketch, location: location)
                    }
                }
                .animation(.spring(duration: 0.2), value: workspace.quickToolsLocation)
                .ignoresSafeArea()
            // Leisten innerhalb des sicheren Bereichs; die leere Fläche lässt Berührungen zum Viewport durch.
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .top) { topArea }
                .overlay(alignment: .topLeading) {
                    ToolRail(workspace: workspace, model: model, sketch: sketch, openGroup: $openGroup) {
                        isImporting = true
                    }
                    .padding(.leading, 16)
                    .padding(.top, 76)
                }
                // Browser „Ebenen“ wie in Fusion 360: Reiter oben links, das Fenster liegt über der Werkzeugleiste
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        layersTab
                        if workspace.showsLayers {
                            LayersPanel(workspace: workspace, model: model, projectName: projectName,
                                        export: exportBodies) {
                                workspace.showsLayers = false
                            }
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 12)
                    .animation(Theme.spring, value: workspace.showsLayers)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(alignment: .top, spacing: 12) {
                        switch panel {
                        case .history:
                            HistoryPanel(model: model) { panel = nil }
                        case .properties:
                            PropertiesPanel(workspace: workspace, model: model) { panel = nil }
                        case nil:
                            EmptyView()
                        }
                        RightRail(workspace: workspace, sketch: sketch, panel: $panel, screenshot: takeScreenshot)
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 76)
                }
                .overlay(alignment: .bottom) { bottomArea }
                .overlay(alignment: .bottomLeading) { undoRedo }
        }
        .hoverTipLayer()
        .onChange(of: workspace.tool) { openGroup = nil }
        .onChange(of: model.selectionRevision) {
            openGroup = nil
            let hasSelection = model.selection != nil || !model.selectedEdges.isEmpty || !model.selectedBodies.isEmpty
                || !model.selectedRegions.isEmpty
            if !hasSelection { workspace.showsAllTools = false }
        }
        .onChange(of: model.variables) {
            // Offene Skizze: Maße mit Variablen gleich nachziehen
            if sketch.isActive { sketch.reevaluateExpressions(model.variableValues) }
        }
        .photosPicker(isPresented: $workspace.isPickingImage, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await insertImage(item) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                workspace.saveThumbnail()
            } else {
                // Mehrere Fenster (iPad) teilen sich LengthUnit.current: das aktive Projekt bestimmt die Einheit
                workspace.activateLengthUnit()
            }
        }
        .alert("Projekt umbenennen", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") { projects.rename(workspace.project.id, to: newName) }
        }
        .confirmationDialog(sketch.isActive ? "Skizze leeren?" : "Alle Körper und Skizzen löschen?",
                            isPresented: $isClearConfirmationShown, titleVisibility: .visible) {
            if sketch.isActive {
                Button("Skizze leeren", role: .destructive, action: sketch.clearAll)
            } else {
                Button("Alles löschen", role: .destructive, action: model.clear)
            }
        } message: {
            Text(sketch.isActive ? "Alle Elemente der offenen Skizze werden entfernt. Rückgängig holt sie zurück."
                                 : "Körper, Skizzen, Konstruktion und Bilder werden entfernt. Rückgängig holt sie zurück.")
        }
        .fileExporter(isPresented: $isExporting, document: exportFile, contentType: exportType,
                      defaultFilename: exportName ?? projectName) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.stepFile, .stpFile, .svg, .dxfFile]) { result in
            guard case .success(let url) = result else { return }
            if ["svg", "dxf"].contains(url.pathExtension.lowercased()) {
                workspace.importVectorFile(url)
            } else {
                model.importSTEP(from: url)
                workspace.send(.fitAll)
            }
        }
        .onChange(of: workspace.pendingExport?.id) {
            guard let pending = workspace.pendingExport else { return }
            workspace.pendingExport = nil
            export(pending.data, as: pending.type, name: pending.name)
        }
        .quickLookPreview($arPreview)
        .sheet(isPresented: $workspace.showsCommandSearch) { CommandSearchSheet(workspace: workspace) }
        .sheet(item: $screenshot) { ScreenshotSheet(screenshot: $0) }
        .sheet(isPresented: $workspace.showsVariables) { VariablesSheet(model: model) }
        .sheet(isPresented: $workspace.showsDrawing) { DrawingSheet(model: model, projectName: projectName) }
        .sheet(isPresented: $workspace.showsProjectPicker) {
            ProjectPickerSheet(current: workspace.project.id) { project in
                model.insertProject(from: project.folder, name: project.name)
                workspace.send(.fitAll)
            }
        }
        .sheet(item: $workspace.helpTopic) { HelpSheet(topic: $0) }
        .environment(\.variableValues, model.variableValues)
        .sheet(isPresented: Binding(get: { sketch.pendingTextAnchor != nil },
                                    set: { if !$0 { sketch.pendingTextAnchor = nil } })) {
            TextEntrySheet(sketch: sketch)
        }
    }

    // MARK: Oben

    /// Reiter „Ebenen“ (Browser) oben links.
    private var layersTab: some View {
        Button {
            workspace.showsLayers.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                Text("Ebenen")
                    .font(Theme.barFont)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(workspace.showsLayers ? 180 : 0))
            }
            .foregroundStyle(workspace.showsLayers ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: Theme.barHeight)
            .floatingSurface(workspace.showsLayers ? Color.accentColor : Theme.surface, in: Capsule(), elevation: .floating)
            .animation(Theme.snappy, value: workspace.showsLayers)
        }
        .buttonStyle(.pressable)
        .hoverTip("Ebenen")
    }

    private var topArea: some View {
        VStack(spacing: 10) {
            titleBar
            if let hint = workspace.hint {
                Text(hint)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .floatingSurface(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.top, 12)
        .animation(Theme.snappy, value: workspace.hint)
    }

    /// Schwebende Titelleiste: Startseite, Projektname, Menü.
    private var titleBar: some View {
        HStack(spacing: 4) {
            Button(action: close) {
                Image(systemName: "house")
                    .frame(width: 44, height: Theme.barHeight)
            }
            .accessibilityLabel("Startseite")
            Divider()
                .frame(height: 20)
            Button {
                newName = projectName
                isRenaming = true
            } label: {
                HStack(spacing: 6) {
                    Text(projectName)
                        .font(Theme.barFont)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: Theme.barHeight)
            }
            Menu {
                ForEach(HelpTopic.allCases) { topic in
                    Button(topic.rawValue, systemImage: topic.systemImage) { workspace.helpTopic = topic }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Hilfe")
                        .font(.callout)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: Theme.barHeight)
            }
            .accessibilityLabel("Hilfe")
            .hoverTip("Hilfe")
            Divider()
                .frame(height: 20)
            Button {
                workspace.showsCommandSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: Theme.barHeight)
            }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Befehl suchen")
            .hoverTip("Befehl suchen", "Jedes Werkzeug per Name finden. Mit Tastatur: ⌘K, Eingabe startet den ersten Treffer.")
            Divider()
                .frame(height: 20)
            Menu {
                Button("Importieren (STEP, SVG, DXF) …", systemImage: "square.and.arrow.down") { isImporting = true }
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            exportBodies(format, nil, projectName)
                        } label: {
                            Label("\(format.rawValue) – \(format.subtitle)", systemImage: format.systemImage)
                        }
                    }
                } label: {
                    Label("Alle Körper exportieren", systemImage: "square.and.arrow.up")
                }
                Button("Zeichnung erstellen (PDF, DXF) …", systemImage: "doc.richtext") {
                    workspace.showsDrawing = true
                }
                Button("In AR ansehen", systemImage: "arkit") {
                    arPreview = model.usdzFile()
                }
                Button(timelineSetting ? "Zeitleiste ausblenden" : "Zeitleiste einblenden",
                       systemImage: "clock.arrow.circlepath") {
                    let next: TimelineVisibility = timelineSetting ? .hidden : .shown
                    timelineVisibility = next.rawValue
                }
                Divider()
                Button("Projekt umbenennen …", systemImage: "pencil") {
                    newName = projectName
                    isRenaming = true
                }
                Button(role: .destructive) {
                    isClearConfirmationShown = true
                } label: {
                    Label(sketch.isActive ? "Skizze leeren …" : "Alles löschen …", systemImage: "trash")
                }
                Divider()
                Text(PCKShape.kernelAvailable ? "Kernel: OpenCASCADE" : "Ohne OpenCASCADE (siehe README)")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: Theme.barHeight)
            }
            .accessibilityLabel("Menü")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .floatingSurface(in: Capsule(), elevation: .floating)
        .buttonStyle(.plain)
    }

    // MARK: Unten

    private var bottomArea: some View {
        VStack(spacing: 10) {
            if sketch.isActive, let notice = sketch.notice {
                Button {
                    sketch.notice = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text(notice)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingSurface(in: Capsule(), elevation: .floating)
                }
                .buttonStyle(.plain)
            }
            if let message = model.message {
                Button {
                    model.message = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .floatingSurface(in: Capsule(), elevation: .floating)
                }
                .buttonStyle(.plain)
            }
            // Foto in der Skizze kalibrieren: Maß-Eingabe auch hier (sonst in der Bild-Karte)
            if sketch.isActive, let calibration = workspace.canvasCalibration {
                CanvasTraceCard(workspace: workspace, model: model, canvasID: calibration.canvas)
            }
            ParameterCard(workspace: workspace, model: model, sketch: sketch)
            if workspace.showsDoneBar {
                doneBar
            }
            if timelineSetting, !sketch.isActive {
                TimelineBar(model: model)
            }
        }
        .padding(.horizontal, 120)
        .padding(.bottom, 18)
    }

    /// „Abbrechen“ und „Fertig“ wie bei Shapr3D.
    private var doneBar: some View {
        HStack(spacing: 12) {
            Button(action: workspace.cancel) {
                Text("Abbrechen")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 110, minHeight: 44)
                    .foregroundStyle(.primary)
                    .floatingSurface(in: Capsule(), elevation: .floating)
            }
            Button(action: workspace.done) {
                Text("Fertig")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 110, minHeight: 44)
                    .foregroundStyle(.white)
                    .floatingSurface(workspace.canFinish ? Color.accentColor : Color.gray, in: Capsule(), elevation: .floating)
            }
            .disabled(!workspace.canFinish)
        }
        .buttonStyle(.pressable)
    }

    private var undoRedo: some View {
        HStack(spacing: 10) {
            RailButton(systemImage: "arrow.uturn.backward", label: "Rückgängig", action: undo)
                .disabled(!canUndo)
                .opacity(canUndo ? 1 : 0.4)
            RailButton(systemImage: "arrow.uturn.forward", label: "Wiederholen", action: model.redo)
                .disabled(!model.canRedo)
                .opacity(model.canRedo ? 1 : 0.4)
        }
        .padding(.leading, 16)
        .padding(.bottom, 18)
    }

    // MARK: Aktionen

    /// Zeitleiste gewünscht (automatisch: ab zwei Features)
    private var timelineSetting: Bool {
        let setting = TimelineVisibility(rawValue: timelineVisibility) ?? .automatic
        return setting.isVisible(featureCount: model.features.count)
    }

    /// In der Skizze nimmt Rückgängig zuerst Skizzenschritte zurück.
    private var canUndo: Bool {
        (sketch.isActive && sketch.canUndo) || model.canUndo
    }

    private func undo() {
        if sketch.isActive, sketch.canUndo {
            sketch.undo()
        } else {
            model.undo()
        }
    }

    private func takeScreenshot() {
        guard let image = workspace.snapshot?(CGSize(width: 1024, height: 768)) else {
            model.message = "Screenshot nicht möglich."
            return
        }
        screenshot = Screenshot(image: image)
    }

    /// Foto als Bild (Canvas) einfügen: höchstens 2048 Pixel, Ausrichtung normalisiert.
    private func insertImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0 else {
            model.message = "Bild konnte nicht geladen werden."
            return
        }
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.85) else { return }
        model.addCanvas(jpeg, aspect: Double(size.height / size.width))
        if let canvas = model.canvases.last {
            if !sketch.isActive { workspace.activate(.canvas(canvas.id)) }
            // Gleich kalibrieren (Kai): bekannte Strecke antippen, echtes Maß eingeben
            workspace.startCalibration(canvas.id)
        }
    }

    private func export(_ data: Data, as type: UTType, name: String? = nil) {
        exportFile = ExportFile(data: data)
        exportType = type
        exportName = name
        isExporting = true
    }

    /// Körper (nil = alle) als 3MF, STL, OBJ oder STEP sichern bzw. teilen.
    private func exportBodies(_ format: ExportFormat, _ bodies: [Int]?, _ name: String) {
        guard let data = model.exportData(format, bodies: bodies) else { return }
        export(data, as: format.type, name: name)
    }
}
