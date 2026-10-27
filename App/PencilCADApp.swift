import Security
import SwiftUI

@main
struct PencilCADApp: App {
    @StateObject private var projects = ProjectStore()

    init() {
        // KI-Assistent entfernt (Kai): früher gespeicherten Claude-API-Schlüssel aus dem Schlüsselbund löschen
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PencilCAD",
            kSecAttrAccount as String: "anthropic-api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(projects)
        }
    }
}

/// Startseite oder geöffnetes Projekt.
struct RootView: View {
    @EnvironmentObject private var projects: ProjectStore
    @State private var workspace: Workspace?

    var body: some View {
        if let workspace {
            WorkspaceView(workspace: workspace) {
                workspace.model.commitPreview()
                workspace.saveThumbnail()
                // Sauber geschlossen: keine Hänger-Marke übrig lassen (HangGuard.swift)
                HangGuard.clear(in: workspace.project.folder)
                projects.touch(workspace.project.id)
                self.workspace = nil
                Workspace.resetLengthUnit()
            }
            .id(workspace.project.id)
        } else {
            HomeView(open: { project, importURL in
                openProject(project, importURL: importURL)
            }, openSafely: { project in
                // „Sicher öffnen“: wie nach einem Hänger – das letzte Feature wird unterdrückt
                HangGuard.requestSafeOpen(in: project.folder)
                openProject(project, importURL: nil)
            })
        }
    }

    /// Projekt öffnen. Hänger-Schutz (HangGuard.swift): Marke vor dem Laden, gelöscht, sobald der Arbeitsbereich
    /// dargestellt ist. Liegt beim Öffnen noch eine alte Marke, öffnet das Projekt im sicheren Modus.
    @MainActor
    private func openProject(_ project: Project, importURL: URL?) {
        let folder = project.folder
        let leftover = HangGuard.marker(in: folder)
        HangGuard.beginOpen(in: folder)
        let opened = Workspace(project: project, safeOpen: leftover)
        if let importURL, MeshFileReader.extensions.contains(importURL.pathExtension.lowercased()) {
            opened.model.importMesh(from: importURL) { opened.send(.fitAll) }
        } else if let importURL {
            opened.model.importSTEP(from: importURL)
            opened.send(.fitAll)
        }
        workspace = opened
        // Läuft erst, wenn der Hauptthread nach der ersten Darstellung wieder frei ist
        let store = projects
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            HangGuard.endOpen(in: folder)
            store.markerRevision += 1
        }
    }
}
