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
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: radius * 2 + 64, height: radius * 2 + 64)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 3)
                    .position(center)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = Double(index) / Double(items.count) * 2 * .pi - .pi / 2
                    Button {
                        item.action()
                        close()
                    } label: {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: 50, height: 50)
                            .foregroundStyle(item.isActive ? Color.white : Color.primary)
                            .background(item.isActive ? Color.accentColor : Color(.systemBackground), in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
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
                .buttonStyle(.plain)
                .accessibilityLabel("Schließen")
                .position(center)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
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
            let tools: [SketchTool] = [.select, .polyline, .rectangle, .circle, .arc, .spline, .offset]
            return tools.map { tool in
                Item(id: tool.rawValue, systemImage: tool.systemImage, isActive: sketch.tool == tool) {
                    sketch.tool = tool
                }
            } + [
                Item(id: "Fang", systemImage: "dot.scope", isActive: sketch.snapEnabled) {
                    sketch.snapEnabled.toggle()
                },
                Item(id: "Rückgängig", systemImage: "arrow.uturn.backward") {
                    if sketch.canUndo { sketch.undo() } else { model.undo() }
                },
            ]
        }
        return [
            Item(id: "Skizze", systemImage: "pencil.and.outline") { workspace.startSketch() },
            Item(id: "Abrunden", systemImage: "app") { workspace.startEdgeOperation(.fillet) },
            Item(id: "Fase", systemImage: "octagon") { workspace.startEdgeOperation(.chamfer) },
            Item(id: "Verschieben", systemImage: "move.3d", isActive: workspace.tool == .move) {
                workspace.activate(.move)
            },
            Item(id: "Spiegeln", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                 isActive: workspace.tool == .mirror) {
                workspace.activate(.mirror)
            },
            Item(id: "Einpassen", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.send(.fitAll) },
            Item(id: "Rückgängig", systemImage: "arrow.uturn.backward") { model.undo() },
            Item(id: "Wiederholen", systemImage: "arrow.uturn.forward") { model.redo() },
        ]
    }
}
