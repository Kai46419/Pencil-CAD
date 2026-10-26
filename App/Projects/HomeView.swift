import SwiftUI
import UniformTypeIdentifiers

/// Startseite: zuletzt bearbeitete Projekte mit Vorschaubild, neues Projekt, STEP importieren.
struct HomeView: View {
    @EnvironmentObject private var projects: ProjectStore
    /// Öffnet ein Projekt; die URL ist eine STEP-Datei, die dabei importiert werden soll.
    let open: (Project, URL?) -> Void

    @State private var isImporting = false
    @State private var renaming: Project?
    @State private var newName = ""
    @State private var deleting: Project?
    /// Auswahlmodus „Löschen“: Häkchen an den Kacheln, dann alle gewählten auf einmal löschen
    @State private var isSelecting = false
    @State private var selected: Set<UUID> = []
    @State private var isBulkDeleteShown = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                Text(isSelecting ? "Projekte zum Löschen antippen" : "Letzte Projekte")
                    .font(.title2.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    if !isSelecting {
                        newProjectCard
                    }
                    ForEach(projects.projects) { project in
                        ProjectCard(project: project, revision: projects.thumbnailRevision,
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.stepFile, .stpFile]) { result in
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

    /// „Version 0.1.0 · Build 47 · 6447eb0 · 23.10.2026 20:47“: Build und Stand schreibt
    /// scripts/generate-project.sh (Build-Nummer = Anzahl der Commits, Stand in BuildInfo.txt)
    private static let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var text = "Version \(version) · Build \(build)"
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "txt"),
           let stand = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !stand.isEmpty {
            text += " · \(stand)"
        }
        return text
    }()

    private var header: some View {
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
                Text(Self.versionText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelecting {
                selectionButtons
            } else {
                normalButtons
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
        Button("Abbrechen") {
            selected = []
            isSelecting = false
        }
        .buttonStyle(.bordered)
        Button(role: .destructive) {
            isBulkDeleteShown = true
        } label: {
            Label(selected.isEmpty ? "Löschen" : "Löschen (\(selected.count))", systemImage: "trash")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selected.isEmpty)
    }

    @ViewBuilder
    private var normalButtons: some View {
        Button {
            selected = []
            isSelecting = true
        } label: {
            Label("Löschen", systemImage: "trash")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        .disabled(projects.projects.isEmpty)
        Button {
            isImporting = true
        } label: {
            Label("Importieren", systemImage: "square.and.arrow.down")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.bordered)
        Button {
            open(projects.create(), nil)
        } label: {
            Label("Neues Projekt", systemImage: "plus")
                .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
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
        Button("Umbenennen", systemImage: "pencil") {
            newName = project.name
            renaming = project
        }
        Button("Duplizieren", systemImage: "plus.square.on.square") { projects.duplicate(project.id) }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) { deleting = project }
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
                .overlay(alignment: .topTrailing) {
                    if let isSelected {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.red : Color.secondary)
                            .background(Circle().fill(Color.white).padding(2))
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
            Color.white.overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        } else {
            Color.white.overlay {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
