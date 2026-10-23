import SwiftUI

/// Gruppen der linken Werkzeugleiste (Aufbau wie bei Shapr3D).
enum ToolGroup: String, CaseIterable, Identifiable {
    case sketch = "Skizze"
    case insert = "Einfügen"
    case construct = "Konstruieren"
    case transform = "Transformation"
    case tools = "Tools"
    case visualize = "Visualisieren"
    case extrude = "Extrudieren"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .sketch: "pencil.and.outline"
        case .insert: "cube"
        case .construct: "square.dashed"
        case .transform: "move.3d"
        case .tools: "wrench.and.screwdriver"
        case .visualize: "eye"
        case .extrude: "square.stack.3d.up"
        }
    }

    /// Extrudieren ist eine direkte Aktion ohne Untermenü.
    var hasFlyout: Bool { self != .extrude }
}

/// Eintrag in einem Untermenü der Werkzeugleiste.
struct ToolItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    var isEnabled = true
    var isActive = false
    var action: () -> Void = {}
}

/// Linke Werkzeugleiste: Kacheln mit Beschriftung, Gruppen öffnen ein Untermenü rechts daneben.
struct ToolRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    @Binding var openGroup: ToolGroup?
    let importSTEP: () -> Void

    private let tileSize: CGFloat = 52
    private let spacing: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(ToolGroup.allCases) { group in
                    Button {
                        tapped(group)
                    } label: {
                        RailTile(title: group.rawValue, systemImage: group.systemImage,
                                 isActive: isActive(group), isOpen: openGroup == group, size: tileSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let openGroup, let index = ToolGroup.allCases.firstIndex(of: openGroup) {
                Flyout(title: openGroup.rawValue, items: items(for: openGroup)) {
                    self.openGroup = nil
                }
                .padding(.top, CGFloat(index) * (tileSize + spacing))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: openGroup)
    }

    private func tapped(_ group: ToolGroup) {
        guard group.hasFlyout else {
            openGroup = nil
            startExtrude()
            return
        }
        openGroup = openGroup == group ? nil : group
    }

    private func isActive(_ group: ToolGroup) -> Bool {
        switch group {
        case .sketch:
            return sketch.isActive
        case .insert:
            if case .insert = workspace.tool { return true }
            return false
        case .construct:
            return false
        case .transform:
            return workspace.tool == .move || workspace.tool == .mirror
        case .tools:
            if case .boolean = workspace.tool { return true }
            return workspace.tool == .shell || (workspace.tool == .select && !model.selectedEdges.isEmpty)
        case .visualize:
            return workspace.tool == .color
        case .extrude:
            return (sketch.isActive && sketch.hasProfile) || (workspace.tool == .select && model.faceHandle != nil)
        }
    }

    /// Wie bei Shapr3D: Profil oder ebene Fläche wählen, dann am Pfeil ziehen.
    private func startExtrude() {
        if sketch.isActive {
            if !sketch.hasProfile {
                model.message = "Erst ein geschlossenes Profil zeichnen, dann am Pfeil ziehen."
            }
            return
        }
        if workspace.tool != .select {
            workspace.activate(.select)
        }
        if model.faceHandle == nil {
            model.message = "Ebene Fläche antippen und am blauen Pfeil ziehen."
        }
    }

    // MARK: Einträge

    private func items(for group: ToolGroup) -> [ToolItem] {
        switch group {
        case .sketch:
            var items = SketchTool.allCases.map { tool in
                ToolItem(id: "sketch.\(tool.rawValue)", title: tool.rawValue, subtitle: tool.subtitle,
                         systemImage: tool.systemImage, isActive: sketch.isActive && sketch.tool == tool) {
                    sketch.tool = tool
                    if !sketch.isActive {
                        workspace.startSketch()
                    }
                }
            }
            items += [soon("Projizieren", "square.and.arrow.down.on.square"), soon("Trimmen", "scissors")]
            if sketch.isActive {
                items.append(ToolItem(id: "sketch.end", title: "Skizze beenden", systemImage: "xmark.circle") {
                    workspace.endSketch()
                })
            }
            return items
        case .insert:
            var items = Primitive.allCases.map { primitive in
                ToolItem(id: "insert.\(primitive.rawValue)", title: primitive.rawValue, systemImage: primitive.systemImage,
                         isActive: workspace.tool == .insert(primitive)) {
                    workspace.activate(.insert(primitive))
                }
            }
            items.append(ToolItem(id: "insert.step", title: "STEP-Datei", subtitle: ".step / .stp",
                                  systemImage: "square.and.arrow.down", action: importSTEP))
            items += [soon("Bild", "photo"), soon("Torus", "circle.dashed")]
            return items
        case .construct:
            return [soon("Ebene", "square.dashed"), soon("Achse", "line.diagonal.arrow"),
                    soon("Punkt", "smallcircle.filled.circle")]
        case .transform:
            return [
                ToolItem(id: "transform.move", title: "Verschieben/Drehen", subtitle: "Körper",
                         systemImage: "move.3d", isActive: workspace.tool == .move) {
                    workspace.activate(.move)
                },
                ToolItem(id: "transform.mirror", title: "Spiegeln", subtitle: "Körper",
                         systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                         isActive: workspace.tool == .mirror) {
                    workspace.activate(.mirror)
                },
                soon("Lineares Muster", "square.grid.3x1.below.line.grid.1x2"),
                soon("Kreismuster", "circle.grid.cross"),
                soon("Skalieren", "arrow.up.left.and.arrow.down.right"),
                soon("Ausrichten", "align.horizontal.center"),
            ]
        case .tools:
            var items = EdgeOperation.allCases.map { operation in
                ToolItem(id: "tools.\(operation.rawValue)", title: operation.rawValue, subtitle: "Kanten",
                         systemImage: operation == .fillet ? "app" : "octagon",
                         isActive: workspace.tool == .select && !model.selectedEdges.isEmpty
                             && model.edgeOperation == operation) {
                    workspace.startEdgeOperation(operation)
                }
            }
            items.append(ToolItem(id: "tools.shell", title: "Schale", subtitle: "Fläche öffnen",
                                  systemImage: "shippingbox", isActive: workspace.tool == .shell) {
                workspace.activate(.shell)
            })
            items += BooleanKind.allCases.map { kind in
                ToolItem(id: "tools.\(kind.rawValue)", title: kind.rawValue, subtitle: "Boolesch",
                         systemImage: kind.systemImage, isActive: workspace.tool == .boolean(kind)) {
                    workspace.activate(.boolean(kind))
                }
            }
            items.append(ToolItem(id: "tools.delete", title: "Löschen", subtitle: "Körper", systemImage: "trash",
                                  isEnabled: model.hasSelection) {
                model.deleteSelected()
            })
            items += [
                soon("Rotieren", "arrow.triangle.2.circlepath"),
                soon("Sweep", "point.3.connected.trianglepath.dotted"),
                soon("Loft", "square.3.layers.3d"),
                soon("Kante versetzen", "square.dashed.inset.filled"),
                soon("Beschneiden", "scissors"),
                soon("Teilen", "rectangle.split.2x1"),
            ]
            return items
        case .visualize:
            var items = DisplayMode.allCases.map { mode in
                ToolItem(id: "visualize.\(mode.rawValue)", title: mode.rawValue, systemImage: mode.systemImage,
                         isActive: workspace.displayMode == mode) {
                    workspace.displayMode = mode
                }
            }
            items.append(ToolItem(id: "visualize.ortho", title: "Orthografisch", subtitle: "Projektion",
                                  systemImage: "cube.transparent", isActive: workspace.isOrthographic) {
                workspace.isOrthographic.toggle()
            })
            items.append(ToolItem(id: "visualize.color", title: "Farbe", subtitle: "Körper", systemImage: "paintpalette",
                                  isActive: workspace.tool == .color) {
                workspace.activate(.color)
            })
            items += [soon("Schnittansicht", "square.split.diagonal.2x2"), soon("Messen", "ruler")]
            return items
        case .extrude:
            return []
        }
    }

    /// Noch nicht umgesetztes Werkzeug (grau).
    private func soon(_ title: String, _ systemImage: String) -> ToolItem {
        ToolItem(id: "soon.\(title)", title: title, subtitle: "Bald", systemImage: systemImage, isEnabled: false)
    }
}

/// Kachel der Werkzeugleiste mit Beschriftung daneben.
struct RailTile: View {
    let title: String
    let systemImage: String
    var isActive = false
    var isOpen = false
    var size: CGFloat = 52

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(isActive ? Color.accentColor : Color(.systemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if isOpen {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
        }
        .contentShape(Rectangle())
    }
}

/// Untermenü einer Werkzeuggruppe.
private struct Flyout: View {
    let title: String
    let items: [ToolItem]
    let close: () -> Void

    var body: some View {
        // Lange Listen scrollen, wenn sie nicht auf den Bildschirm passen.
        ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .frame(width: 240)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(items) { item in
                Button {
                    item.action()
                    close()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(item.isActive ? Color.white : Color.primary)
                            .background(item.isActive ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }
        }
        .padding(10)
    }
}
