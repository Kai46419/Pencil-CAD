import SwiftUI
import UniformTypeIdentifiers

/// Startseite: zuletzt bearbeitete Projekte mit Vorschaubild, neues Projekt, STEP importieren.
struct HomeView: View {
    @EnvironmentObject private var projects: ProjectStore
    /// Öffnet ein Projekt; die URL ist eine STEP-Datei, die dabei importiert werden soll.
    let open: (Project, URL?) -> Void
    /// Sicher öffnen (HangGuard.swift): Verlauf bis vor das hängende bzw. letzte Feature nachbauen
    var openSafely: (Project) -> Void = { _ in }

    @State private var isImporting = false
    @State private var renaming: Project?
    @State private var newName = ""
    @State private var deleting: Project?
    /// Auswahlmodus „Löschen“: Häkchen an den Kacheln, dann alle gewählten auf einmal löschen
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var isBulkDeleteShown = false
    @State private var showsBackups = false
    @State private var backupMessage: String?
    /// Design (AppTheme): beobachtet, damit das Symbol im Knopf „Design“ mitwechselt
    @AppStorage(AppTheme.modeKey) private var appearanceMode = ""

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                Text(isSelecting ? "Projekte zum Löschen antippen" : "Projekte (\(projects.projects.count))")
                    .font(.title2.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    if !isSelecting {
                        newProjectCard
                    }
                    ForEach(projects.projects) { project in
                        ProjectCard(project: project, revision: projects.thumbnailRevision &+ projects.markerRevision,
                                    isSelected: isSelecting ? selected.contains(project.id) : nil)
                            .onTapGesture {
                                if isSelecting {
                                    if selected.contains(project.id) { selected.remove(project.id) } else { selected.insert(project.id) }
                                } else {
                                    open(project, nil)
                                }
                            }
                            .contextMenu { if !isSelecting { contextMenu(for: project) } }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .background(Theme.homeBackground.ignoresSafeArea())
        .appTheme()
        .onAppear { projects.reload() }
        .sheet(isPresented: $showsBackups) { backupSheet }
        .alert("Projektsicherung", isPresented: Binding(get: { backupMessage != nil },
                                                        set: { if !$0 { backupMessage = nil } })) {
            Button("OK") { backupMessage = nil }
        } message: {
            Text(backupMessage ?? "")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.stepFile, .stpFile, .stl, .threeMF]) { result in
            guard case .success(let url) = result else { return }
            open(projects.create(name: url.deletingPathExtension().lastPathComponent), url)
        }
        .alert("Projekt umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") {
                if let renaming { projects.rename(renaming.id, to: newName) }
            }
        }
        .confirmationDialog("Projekt löschen?", isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let deleting { projects.delete(deleting.id) }
            }
        } message: {
            Text("„\(deleting?.name ?? "")“ wird endgültig gelöscht.")
        }
        .confirmationDialog(selected.count == 1 ? "1 Projekt löschen?" : "\(selected.count) Projekte löschen?",
                            isPresented: $isBulkDeleteShown, titleVisibility: .visible) {
            Button(selected.count == 1 ? "1 Projekt löschen" : "\(selected.count) Projekte löschen", role: .destructive) {
                projects.delete(selected)
                selected = []
                isSelecting = false
            }
        } message: {
            Text("Die gewählten Projekte werden endgültig gelöscht. Das lässt sich nicht rückgängig machen.")
        }
        .onChange(of: projects.projects.map(\.id)) { _, ids in
            selected.formIntersection(ids)
        }
    }

    /// „Version 0.1.1 (12) · Build 67 · 6447eb0 · 23.10.2026 20:47“: in Klammern die CFBundleVersion
    /// (Upload-Nummer in TestFlight); „Build N“ samt Stand schreibt scripts/generate-project.sh in BuildInfo.txt
    private static let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let bundleVersion = info?["CFBundleVersion"] as? String ?? "?"
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "txt"),
           let stand = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           stand.hasPrefix("Build ") {
            return "Version \(version) (\(bundleVersion)) · \(stand)"
        }
        return "Version \(version) · Build \(bundleVersion)"
    }()

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [Color.accentColor.opacity(0.82), Color.accentColor],
                                               startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PencilCAD")
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    Text(Self.versionText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if isSelecting {
                    selectionButtons
                } else {
                    normalButtons
                }
            }
        }
        .buttonBorderShape(.capsule)
    }

    /// Im Auswahlmodus: alle wählen, abbrechen, gewählte löschen (mit Rückfrage).
    @ViewBuilder
    private var selectionButtons: some View {
        let allSelected = !projects.projects.isEmpty && selected.count == projects.projects.count
        Button(allSelected ? "Keine auswählen" : "Alle auswählen") {
            selected = allSelected ? [] : Set(projects.projects.map(\.id))
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        Button("Abbrechen") {
            selected = []
            isSelecting = false
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        Button(role: .destructive) {
            isBulkDeleteShown = true
        } label: {
            Label(selected.isEmpty ? "Löschen" : "Löschen (\(selected.count))", systemImage: "trash")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selected.isEmpty)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var normalButtons: some View {
        Button {
            projects.reloadBackups()
            showsBackups = true
        } label: {
            Label("Sicherungen", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        // Helles bzw. dunkles Design (Anthrazit nach SolidCraft) für die ganze App
        Menu {
            AppearanceToggle()
        } label: {
            Label("Design", systemImage: AppTheme.mode.systemImage)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        Button {
            selected = []
            isSelecting = true
        } label: {
            Label("Löschen", systemImage: "trash")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        .disabled(projects.projects.isEmpty)
        .fixedSize(horizontal: true, vertical: false)
        Button {
            isImporting = true
        } label: {
            Label("Importieren", systemImage: "square.and.arrow.down")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
        Button {
            open(projects.create(), nil)
        } label: {
            Label("Neues Projekt", systemImage: "plus")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var newProjectCard: some View {
        Button {
            open(projects.create(), nil)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    }
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Color.accentColor, in: Circle())
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 3)
                    }
                Text("Neues Projekt")
                    .font(.headline)
                Text(" ")
                    .font(.subheadline)
            }
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func contextMenu(for project: Project) -> some View {
        Button("Öffnen", systemImage: "arrow.up.forward.app") { open(project, nil) }
        // Hänger-Schutz: immer anbieten (auch ohne Marke, z. B. Projekte aus älteren Builds)
        Button("Sicher öffnen (letztes Feature unterdrückt)", systemImage: "cross.case") { openSafely(project) }
        Button("Umbenennen", systemImage: "pencil") {
            newName = project.name
            renaming = project
        }
        Button("Duplizieren", systemImage: "plus.square.on.square") { projects.duplicate(project.id) }
        Button("Sicherung erstellen", systemImage: "square.and.arrow.down") {
            do {
                try projects.makeBackup(project.id)
                backupMessage = "„\(project.name)“ wurde gesichert. Unter „Sicherungen“ kannst du es als neue Kopie wiederherstellen."
            } catch {
                backupMessage = "Sicherung fehlgeschlagen: \(error.localizedDescription)"
            }
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) { deleting = project }
    }

    private var backupSheet: some View {
        NavigationStack {
            List {
                if projects.backups.isEmpty {
                    Text("Noch keine Sicherungen. Halte eine Projektkachel gedrückt und wähle „Sicherung erstellen“.")
                        .foregroundStyle(.secondary)
                }
                ForEach(projects.backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.name)
                                .font(.headline)
                            Text(backup.created.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Wiederherstellen") {
                            do {
                                let restored = try projects.restoreBackup(backup.id)
                                showsBackups = false
                                backupMessage = "„\(restored.name)“ ist jetzt als eigenes Projekt in der Übersicht."
                            } catch {
                                backupMessage = "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Sicherungen (\(projects.backups.count))")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { showsBackups = false }
                }
            }
        }
    }
}

/// Kachel mit Vorschaubild, Name und Änderungsdatum.
private struct ProjectCard: View {
    let project: Project
    /// Nur damit SwiftUI das Bild nach dem Schließen eines Projekts neu lädt.
    let revision: Int
    /// Auswahlmodus: Häkchen gesetzt bzw. leer; nil = kein Auswahlmodus
    var isSelected: Bool? = nil
    /// Stift oder Zeiger schwebt über der Kachel
    @State private var isHovered = false

    /// Grund hinter dem Vorschaubild: hell weiß, dunkel Viewport-Anthrazit #2E3440
    private static let tileBackground = Color(SketchTheme.dynamic(light: .white, dark: SketchTheme.uiRGB(46, 52, 64)))

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(shape)
                .hairlineBorder(shape)
                .overlay {
                    if isSelected == true {
                        shape
                            .strokeBorder(Color.red, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Hänger-Marke (HangGuard.swift): der letzte Versuch hing – öffnet im sicheren Modus
                    if HangGuard.hasMarker(in: project.folder) {
                        Label("Hing beim letzten Mal – öffnet sicher", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange, in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let isSelected {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.red : Color.secondary)
                            .background(Circle().fill(Theme.surface).padding(2))
                            .shadow(color: .black.opacity(0.2), radius: 2)
                            .padding(10)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.16 : 0.09), radius: isHovered ? 14 : 8, y: isHovered ? 6 : 3)
                .scaleEffect(isHovered ? 1.02 : 1)
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Text(project.modified, format: .relative(presentation: .named))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Theme.snappy) { isHovered = hovering }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = UIImage(contentsOfFile: project.thumbnailURL.path(percentEncoded: false)) {
            Self.tileBackground.overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            Self.tileBackground.overlay {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
