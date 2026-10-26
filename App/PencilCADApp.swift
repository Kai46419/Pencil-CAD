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
                projects.touch(workspace.project.id)
                self.workspace = nil
                Workspace.resetLengthUnit()
            }
            .id(workspace.project.id)
        } else {
            HomeView { project, importURL in
                let opened = Workspace(project: project)
                if let importURL {
                    opened.model.importSTEP(from: importURL)
                    opened.send(.fitAll)
                }
                workspace = opened
            }
        }
    }
}
