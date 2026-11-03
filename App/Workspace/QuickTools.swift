import SwiftUI

/// Werkzeugrad an der Stiftspitze: Drücken und schwebend wählen (Pencil Pro), Doppeltippen/Antippen als Alternative.
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
                        icon(item, hovered: workspace.quickToolsHoverIndex == index)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(item.id)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: workspace.updateQuickToolsHover(index)
                        case .ended:
                            if workspace.quickToolsHoverIndex == index { workspace.updateQuickToolsHover(nil) }
                        }
                    }
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
    @ViewBuilder private func icon(_ item: Item, hovered: Bool) -> some View {
        if ToolIcon.isCustom(item.systemImage) {
            ToolIcon(item.systemImage, size: 30)
                .frame(width: 50, height: 50)
                .background(item.isActive || hovered ? Color.accentColor.opacity(0.22) : Color.clear, in: Circle())
                .floatingSurface(Theme.surface, in: Circle())
                .overlay {
                    if item.isActive || hovered {
                        Circle().strokeBorder(Color.accentColor, lineWidth: hovered ? 3 : 2)
                    }
                }
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 50, height: 50)
                .foregroundStyle(item.isActive || hovered ? Color.white : Color.primary)
                .floatingSurface(item.isActive || hovered ? Color.accentColor : Theme.surface, in: Circle())
        }
    }

    private func close() {
        workspace.quickToolsLocation = nil
        workspace.quickToolsHoverIndex = nil
    }

    /// Dieselbe Geometrie wie die Schaltflächen; ein Treffer benötigt das Icon, nicht nur seinen Kreissektor.
    func hoverIndex(at point: CGPoint, in size: CGSize) -> Int? {
        let center = clamped(location, in: size)
        var nearest: (index: Int, distance: CGFloat)?
        for index in items.indices {
            let icon = iconCenter(index: index, center: center)
            let distance = hypot(point.x - icon.x, point.y - icon.y)
            if distance <= 30, distance < (nearest?.distance ?? .infinity) {
                nearest = (index, distance)
            }
        }
        return nearest?.index
    }

    func iconCenter(index: Int, in size: CGSize) -> CGPoint {
        iconCenter(index: index, center: clamped(location, in: size))
    }

    private func iconCenter(index: Int, center: CGPoint) -> CGPoint {
        let angle = Double(index) / Double(items.count) * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// Beim Loslassen des Drucks dieselbe Aktion wie beim Antippen ausführen.
    @discardableResult static func performSelection(_ index: Int, workspace: Workspace, sketch: SketchController) -> Bool {
        let palette = QuickToolsPalette(workspace: workspace, sketch: sketch,
                                        location: workspace.quickToolsLocation ?? .zero)
        guard palette.items.indices.contains(index) else { return false }
        palette.items[index].action()
        workspace.quickToolsLocation = nil
        workspace.quickToolsHoverIndex = nil
        return true
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
