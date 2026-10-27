import SwiftUI

/// Werkzeugrad an der Stiftspitze: öffnet sich durch Drücken des Apple Pencil Pro bzw. Doppeltippen.
struct QuickToolsPalette: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    let location: CGPoint

    private struct Item: Identifiable {
        let id: String
        let systemImage: String
        var isActive = false
        let action: () -> Void
    }

    private let radius: CGFloat = 82

    var body: some View {
        GeometryReader { proxy in
            let center = clamped(location, in: proxy.size)
            ZStack {
                // Tippen daneben schließt das Rad
                Color.black.opacity(0.001)
                    .onTapGesture(perform: close)
                FloatingShape(shape: Circle(), fill: Material.regularMaterial, elevation: .overlay)
                    .frame(width: radius * 2 + 64, height: radius * 2 + 64)
                    .position(center)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = Double(index) / Double(items.count) * 2 * .pi - .pi / 2
                    Button {
                        item.action()
                        close()
                    } label: {
                        icon(item)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(item.id)
                    .position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Schließen")
                .position(center)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    /// SF Symbol aktiv weiß auf Akzentfarbe; SolidCraft-Bild aktiv auf hellem Akzentgrund mit Ring.
    @ViewBuilder private func icon(_ item: Item) -> some View {
        if ToolIcon.isCustom(item.systemImage) {
            ToolIcon(item.systemImage, size: 30)
                .frame(width: 50, height: 50)
                .background(item.isActive ? Color.accentColor.opacity(0.22) : Color.clear, in: Circle())
                .floatingSurface(Theme.surface, in: Circle())
                .overlay {
                    if item.isActive {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 50, height: 50)
                .foregroundStyle(item.isActive ? Color.white : Color.primary)
                .floatingSurface(item.isActive ? Color.accentColor : Theme.surface, in: Circle())
        }
    }

    private func close() {
        workspace.quickToolsLocation = nil
    }

    /// Rad vollständig im sichtbaren Bereich halten.
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let margin = radius + 40
        return CGPoint(x: min(max(p.x, margin), max(size.width - margin, margin)),
                       y: min(max(p.y, margin), max(size.height - margin, margin)))
    }

    private var items: [Item] {
        let model = workspace.model
        if sketch.isActive {
            let tools: [SketchTool] = [.select, .polyline, .rectangle, .circle, .offset, .trim, .measure]
            return tools.map { tool in
                Item(id: tool.rawValue, systemImage: tool.systemImage,
                     isActive: sketch.tool == tool && !(tool == .polyline && sketch.arcNext)) {
                    sketch.tool = tool
                }
            } + [
                // Tangentialer Bogen ohne Finger: nächster Strich ist ein Bogen am Linienende
                Item(id: "Bogen", systemImage: SketchTool.arc.systemImage,
                     isActive: sketch.tool == .polyline && sketch.arcNext) {
                    if sketch.tool != .polyline { sketch.tool = .polyline }
                    sketch.arcNext = true
                },
                Item(id: "Fang", systemImage: "dot.scope", isActive: sketch.snapEnabled) {
                    sketch.snapEnabled.toggle()
                },
                Item(id: "Rückgängig", systemImage: "arrow.uturn.backward") {
                    if sketch.canUndo { sketch.undo() } else { model.undo() }
                },
            ]
        }
        // Mit Auswahl (ohne offenes Panel): die Aktionen zur Auswahl wie im Menü „Auswahl“ (ModelRibbon)
        let hasSelection = model.selection != nil || !model.selectedEdges.isEmpty || !model.selectedBodies.isEmpty
            || !model.selectedRegions.isEmpty
        if hasSelection, workspace.command == nil {
            let actions = ModelRibbon.contextCommands(workspace).filter(\.isEnabled).prefix(7)
            return actions.map { command in
                Item(id: command.title, systemImage: command.icon, isActive: command.isActive, action: command.run)
            } + [Item(id: "Rückgängig", systemImage: "arrow.uturn.backward") { model.undo() }]
        }
        return [
            Item(id: "Skizze", systemImage: ToolGroup.sketch.systemImage) { workspace.startSketch() },
            Item(id: "Abrunden", systemImage: "sc.fillet", isActive: workspace.command?.id == .fillet) {
                workspace.startCommand(.fillet)
            },
            Item(id: "Fase", systemImage: "sc.chamfer", isActive: workspace.command?.id == .chamfer) {
                workspace.startCommand(.chamfer)
            },
            Item(id: "Verschieben", systemImage: "sc.move", isActive: workspace.command?.id == .move) {
                workspace.startCommand(.move)
            },
            Item(id: "Spiegeln", systemImage: "sc.mirror", isActive: workspace.command?.id == .mirror) {
                workspace.startCommand(.mirror)
            },
            Item(id: "Einpassen", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.send(.fitAll) },
            Item(id: "Rückgängig", systemImage: "arrow.uturn.backward") { model.undo() },
            Item(id: "Wiederholen", systemImage: "arrow.uturn.forward") { model.redo() },
        ]
    }
}
