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

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                Text("Letzte Projekte")
                    .font(.title2.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    newProjectCard
                    ForEach(projects.projects) { project in
                        ProjectCard(project: project, revision: projects.thumbnailRevision)
                            .onTapGesture { open(project, nil) }
                            .contextMenu { contextMenu(for: project) }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .background(Color(white: 0.95).ignoresSafeArea())
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            Text("PencilCAD")
                .font(.largeTitle.weight(.bold))
            Spacer()
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
    }

    private var newProjectCard: some View {
        Button {
            open(projects.create(), nil)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.secondary)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                Text("Neues Projekt")
                    .font(.headline)
                Text(" ")
                    .font(.subheadline)
            }
        }
        .buttonStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Text(project.modified, format: .relative(presentation: .named))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
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
