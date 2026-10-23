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

    /// Skizze und Extrudieren sind direkte Aktionen ohne Untermenü.
    var hasFlyout: Bool { self != .extrude && self != .sketch }
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

/// Eintrag der linken Leiste im Skizzen- und Kontextmodus: Aktion oder Untermenü.
private struct RailEntry: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    var isActive = false
    /// Ausgegraut und nicht antippbar (z. B. „Keine aktive Ebene“, „Löschen“ ohne Auswahl)
    var isEnabled = true
    var flyout: [ToolItem]?
    var action: () -> Void = {}
}

/// Linke Werkzeugleiste (Aufbau wie bei Shapr3D):
/// im Skizzenmodus die Skizzenwerkzeuge, mit Auswahl die passenden Aktionen, sonst die Werkzeuggruppen.
struct ToolRail: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    @Binding var openGroup: ToolGroup?
    let importSTEP: () -> Void

    @State private var openEntry: String?

    private let tileSize: CGFloat = 52
    private let spacing: CGFloat = 10

    var body: some View {
        if sketch.isActive {
            entryRail(sketchEntries, tile: 46, header: sketchHeader)
        } else if showsContext {
            entryRail(contextEntries, tile: 46, header: nil)
        } else {
            modelTools
        }
    }

    // MARK: Leiste mit Einträgen

    private func entryRail(_ entries: [RailEntry], tile: CGFloat, header: String?) -> some View {
        let gap: CGFloat = 7
        let list = VStack(alignment: .leading, spacing: gap) {
            if let header {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            ForEach(entries) { entry in
                Button {
                    if entry.flyout != nil {
                        openEntry = openEntry == entry.id ? nil : entry.id
                    } else {
                        openEntry = nil
                        entry.action()
                    }
                } label: {
                    RailTile(title: entry.title, subtitle: entry.subtitle, systemImage: entry.systemImage,
                             isActive: entry.isActive, isOpen: openEntry == entry.id, size: tile)
                }
                .buttonStyle(.plain)
                .disabled(!entry.isEnabled)
                .opacity(entry.isEnabled ? 1 : 0.45)
                .hoverTip(entry.title)
            }
        }
        return HStack(alignment: .top, spacing: 12) {
            ViewThatFits(in: .vertical) {
                list
                ScrollView(showsIndicators: false) { list }
            }
            if let openEntry, let index = entries.firstIndex(where: { $0.id == openEntry }),
               let items = entries[index].flyout {
                Flyout(title: entries[index].title, items: items) { self.openEntry = nil }
                    .padding(.top, CGFloat(index) * (tile + gap) + (header == nil ? 0 : 30))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: openEntry)
    }

    // MARK: Skizzenmodus

    private var sketchHeader: String {
        if let index = workspace.editingSketchIndex, model.sketches.indices.contains(index) {
            return model.sketches[index].name
        }
        return "Skizze \(model.sketches.count + 1)"
    }

    private func toolEntry(_ tool: SketchTool, subtitle: String? = nil) -> RailEntry {
        RailEntry(id: "sketch.\(tool.rawValue)", title: tool.rawValue, subtitle: subtitle, systemImage: tool.systemImage,
                  isActive: sketch.tool == tool) {
            sketch.tool = tool
        }
    }

    private func toolItem(_ tool: SketchTool, title: String? = nil, subtitle: String? = nil,
                          isActive: Bool? = nil, then: @escaping () -> Void = {}) -> ToolItem {
        ToolItem(id: "item.\(tool.rawValue).\(title ?? "")", title: title ?? tool.rawValue,
                 subtitle: subtitle ?? tool.subtitle, systemImage: tool.systemImage,
                 isActive: isActive ?? (sketch.tool == tool)) {
            sketch.tool = tool
            then()
        }
    }

    private static func polygonName(_ sides: Int) -> String {
        switch sides {
        case 3: "Dreieck"
        case 4: "Viereck"
        case 5: "Fünfeck"
        case 6: "Sechseck"
        case 8: "Achteck"
        default: "\(sides)-Eck"
        }
    }

    /// Name der Skizzenebene: Standardebene, sonst Fläche bzw. Konstruktionsebene.
    private var activePlaneName: String {
        guard !sketch.plane.isOnFace else { return "Fläche" }
        return BasePlane.allCases.first { $0.normal == sketch.plane.normal }?.rawValue ?? "Ebene"
    }

    private var sketchEntries: [RailEntry] {
        let lineTool = sketch.tool == .arc ? SketchTool.arc : .polyline
        return [
            RailEntry(id: "sketch.finish", title: "Skizzieren beenden", systemImage: "xmark") {
                workspace.finishSketch()
            },
            // Pfeil: zeichnet nicht, sondern wählt, verschiebt und zieht Eck- und Endpunkte
            RailEntry(id: "sketch.select", title: SketchTool.select.rawValue, subtitle: SketchTool.select.subtitle,
                      systemImage: SketchTool.select.systemImage, isActive: sketch.tool == .select) {
                sketch.tool = .select
            },
            // Wie bei Shapr3D: Werkzeuge lassen sich schon vor der Ebenenwahl wählen
            RailEntry(id: "sketch.plane", title: sketch.isChoosingPlane ? "Keine aktive Ebene" : "Aktive Ebene",
                      subtitle: sketch.isChoosingPlane ? nil : activePlaneName,
                      systemImage: "square.dashed", isEnabled: false),
            RailEntry(id: "sketch.line", title: "Linie/Bogen", subtitle: lineTool.subtitle,
                      systemImage: lineTool.systemImage, isActive: sketch.tool == .polyline || sketch.tool == .arc,
                      flyout: [toolItem(.polyline, title: "Linie"), toolItem(.arc, title: "Bogen")]),
            RailEntry(id: "sketch.spline", title: "Spline", subtitle: sketch.splineKind.rawValue,
                      systemImage: SketchTool.spline.systemImage, isActive: sketch.tool == .spline,
                      flyout: SplineKind.allCases.map { kind in
                          toolItem(.spline, title: kind.rawValue, subtitle: "Spline",
                                   isActive: sketch.tool == .spline && sketch.splineKind == kind) {
                              sketch.splineKind = kind
                          }
                      }),
            RailEntry(id: "sketch.rectangle", title: "Rechteck", subtitle: sketch.rectangleMode.rawValue,
                      systemImage: SketchTool.rectangle.systemImage, isActive: sketch.tool == .rectangle,
                      flyout: RectangleMode.allCases.map { mode in
                          ToolItem(id: "rect.\(mode.rawValue)", title: mode.rawValue, subtitle: "Rechteck",
                                   systemImage: mode.systemImage,
                                   isActive: sketch.tool == .rectangle && sketch.rectangleMode == mode) {
                              sketch.tool = .rectangle
                              sketch.rectangleMode = mode
                          }
                      }),
            toolEntry(.circle),
            toolEntry(.ellipse),
            toolEntry(.polygon, subtitle: Self.polygonName(sketch.polygonSides)),
            toolEntry(.project),
            toolEntry(.offset),
            RailEntry(id: "sketch.more", title: "Mehr", systemImage: "ellipsis.circle",
                      isActive: [SketchTool.point, .text, .scale, .fillet].contains(sketch.tool),
                      flyout: [toolItem(.fillet), toolItem(.point), toolItem(.text), toolItem(.scale)]),
            toolEntry(.trim),
            RailEntry(id: "sketch.delete", title: "Löschen", subtitle: sketch.selection.isEmpty ? nil : "Auswahl",
                      systemImage: "trash", isEnabled: !sketch.selection.isEmpty) {
                sketch.deleteSelection()
            },
            RailEntry(id: "sketch.construction", title: "Konstruktion", subtitle: sketch.constructionMode ? "Ein" : "Aus",
                      systemImage: "line.diagonal.arrow", isActive: sketch.constructionMode) {
                sketch.constructionMode.toggle()
            },
            RailEntry(id: "sketch.section", title: "Schnittansicht", subtitle: workspace.sketchSection ? "Ein" : "Aus",
                      systemImage: "square.split.diagonal.2x2", isActive: workspace.sketchSection) {
                workspace.sketchSection.toggle()
            },
        ]
    }

    // MARK: Kontext (Auswahl im 3D-Modus)

    private var hasSelection: Bool {
        model.selection != nil || !model.selectedEdges.isEmpty || !model.selectedBodies.isEmpty
            || !model.selectedRegions.isEmpty
    }

    private var showsContext: Bool {
        workspace.tool == .select && hasSelection && !workspace.showsAllTools
    }

    private var selectionSummary: String {
        if !model.selectedRegions.isEmpty {
            return model.selectedRegions.count == 1 ? "1 Bereich" : "\(model.selectedRegions.count) Bereiche"
        }
        if !model.selectedEdges.isEmpty {
            return model.selectedEdges.count == 1 ? "1 Kante" : "\(model.selectedEdges.count) Kanten"
        }
        if model.selection != nil { return "1 Außenfläche" }
        return model.selectedBodies.count == 1 ? "1 Körper" : "\(model.selectedBodies.count) Körper"
    }

    private var contextEntries: [RailEntry] {
        let hasRegions = !model.selectedRegions.isEmpty
        let face = model.selection
        let planarFace = face != nil && model.faceHandle != nil
        var entries = [
            RailEntry(id: "context.clear", title: "Alle abwählen", subtitle: "(\(selectionSummary))",
                      systemImage: "xmark.circle") {
                model.resetSelection()
            },
            RailEntry(id: "context.sketch", title: "Skizze", systemImage: ToolGroup.sketch.systemImage) {
                workspace.startSketch()
            },
            RailEntry(id: "context.move", title: "Verschieben/Rotieren", systemImage: "move.3d") {
                workspace.activate(.move)
            },
        ]
        if hasRegions {
            entries.append(RailEntry(id: "context.scaleSketch", title: "Skizze skalieren",
                                     systemImage: "arrow.up.left.and.arrow.down.right") {
                workspace.activate(.scaleSketch)
            })
        } else {
            entries.append(RailEntry(id: "context.scale", title: "Skalieren",
                                     systemImage: "arrow.up.left.and.arrow.down.right") {
                workspace.activate(.scale)
            })
        }
        entries += PatternKind.allCases.map { kind in
            RailEntry(id: "context.\(kind.rawValue)", title: kind.rawValue, systemImage: kind.systemImage) {
                workspace.activate(.pattern(kind))
            }
        }
        if model.selectedBodies.count > 1 {
            let combine = BooleanKind.allCases.map { kind in
                RailEntry(id: "context.\(kind.rawValue)", title: kind.rawValue,
                          subtitle: kind == .union ? "\(model.selectedBodies.count) → 1" : nil,
                          systemImage: kind.systemImage, isActive: kind == .union) {
                    workspace.combineSelectedBodies(kind)
                }
            }
            entries.insert(contentsOf: combine, at: 1)
        }
        if hasRegions || planarFace {
            entries.append(RailEntry(id: "context.extrude", title: "Extrudieren", subtitle: "Pfeil ziehen",
                                     systemImage: ToolGroup.extrude.systemImage, isActive: true) {
                model.message = "Am blauen Pfeil ziehen oder den Abstand unten eingeben."
            })
        }
        if planarFace {
            entries.append(RailEntry(id: "context.axis", title: "Achse senkrecht", systemImage: "line.diagonal.arrow") {
                workspace.createNormalAxis()
            })
            entries.append(RailEntry(id: "context.plane", title: "Ebene Versatz", systemImage: "square.dashed") {
                workspace.activate(.construct(.plane))
            })
            entries.append(RailEntry(id: "context.offsetEdges", title: "Kante versetzen",
                                     systemImage: SketchTool.offset.systemImage) {
                workspace.activate(.offsetEdges)
            })
        }
        if hasRegions || planarFace {
            entries.append(RailEntry(id: "context.text", title: "Text", systemImage: "textformat") {
                if let region = model.selectedRegions.first, model.sketches.indices.contains(region.sketch) {
                    workspace.startSketch(on: model.sketches[region.sketch].plane)
                } else {
                    workspace.startSketch()
                }
                sketch.tool = .text
            })
        }
        if hasRegions {
            entries.append(RailEntry(id: "context.revolve", title: "Achsendrehung",
                                     systemImage: "arrow.triangle.2.circlepath") {
                workspace.activate(.revolve)
            })
        }
        entries += [
            RailEntry(id: "context.more", title: "Mehr", systemImage: "ellipsis.circle") {
                workspace.showsAllTools = true
            },
            RailEntry(id: "context.delete", title: "Löschen", systemImage: "trash") {
                if let region = model.selectedRegions.first {
                    model.deleteSketch(region.sketch)
                } else {
                    model.deleteSelected()
                }
            },
            RailEntry(id: "context.isolate", title: "Isolieren", subtitle: model.isIsolated ? "Ein" : "Aus",
                      systemImage: "scope", isActive: model.isIsolated) {
                workspace.toggleIsolate()
            },
            RailEntry(id: "context.section", title: "Schnittansicht", subtitle: workspace.section == nil ? "Aus" : "Ein",
                      systemImage: "square.split.diagonal.2x2", isActive: workspace.section != nil) {
                workspace.activate(.section)
            },
            RailEntry(id: "context.measure", title: "Messen", systemImage: "ruler") {
                workspace.activate(.measure)
            },
        ]
        return entries
    }

    // MARK: Werkzeuggruppen

    private var modelTools: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: spacing) {
                if workspace.showsAllTools, hasSelection {
                    Button {
                        workspace.showsAllTools = false
                    } label: {
                        RailTile(title: "Zurück", subtitle: "Auswahl", systemImage: "chevron.backward", size: tileSize)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(ToolGroup.allCases) { group in
                    Button {
                        tapped(group)
                    } label: {
                        RailTile(title: group.rawValue, systemImage: group.systemImage,
                                 isActive: isActive(group), isOpen: openGroup == group, size: tileSize)
                    }
                    .buttonStyle(.plain)
                    .hoverTip(group.rawValue)
                }
            }
            if let openGroup, let index = ToolGroup.allCases.firstIndex(of: openGroup) {
                Flyout(title: openGroup.rawValue, items: items(for: openGroup)) {
                    self.openGroup = nil
                }
                .padding(.top, CGFloat(index + (workspace.showsAllTools && hasSelection ? 1 : 0)) * (tileSize + spacing))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: openGroup)
    }

    private func tapped(_ group: ToolGroup) {
        guard group.hasFlyout else {
            openGroup = nil
            if group == .sketch {
                workspace.startSketch()
            } else {
                startExtrude()
            }
            return
        }
        openGroup = openGroup == group ? nil : group
    }

    private func isActive(_ group: ToolGroup) -> Bool {
        switch workspace.tool {
        case .insert, .canvas:
            return group == .insert
        case .construct:
            return group == .construct
        case .move, .mirror, .pattern, .scale, .align, .scaleSketch:
            return group == .transform
        case .boolean, .shell, .revolve, .sweep, .loft, .split, .offsetEdges:
            return group == .tools
        case .color, .section, .measure:
            return group == .visualize
        case .select:
            switch group {
            case .sketch: return sketch.isActive
            case .tools: return !model.selectedEdges.isEmpty
            case .extrude: return !model.selectedRegions.isEmpty || model.faceHandle != nil
            default: return false
            }
        }
    }

    /// Wie bei Shapr3D: Skizzenbereich oder ebene Fläche antippen, dann am Pfeil ziehen.
    private func startExtrude() {
        if workspace.tool != .select {
            workspace.activate(.select)
        }
        if model.faceHandle == nil, model.selectedRegions.isEmpty {
            model.message = model.sketches.isEmpty
                ? "Erst eine Skizze mit geschlossenem Profil zeichnen, oder eine ebene Fläche antippen."
                : "Skizzenbereich oder ebene Fläche antippen, dann am blauen Pfeil ziehen."
        }
    }

    // MARK: Einträge

    private func item(_ tool: ModelTool, _ title: String, subtitle: String? = nil, _ systemImage: String) -> ToolItem {
        ToolItem(id: "tool.\(title)", title: title, subtitle: subtitle, systemImage: systemImage,
                 isActive: workspace.tool == tool) {
            workspace.activate(tool)
        }
    }

    private func items(for group: ToolGroup) -> [ToolItem] {
        switch group {
        case .sketch, .extrude:
            return []
        case .insert:
            var items = Primitive.allCases.map { primitive in
                item(.insert(primitive), primitive.rawValue, primitive.systemImage)
            }
            items.append(ToolItem(id: "insert.step", title: "STEP-Datei", subtitle: ".step / .stp",
                                  systemImage: "square.and.arrow.down", action: importSTEP))
            items.append(ToolItem(id: "insert.image", title: "Bild", subtitle: "Aus Fotos, als Vorlage",
                                  systemImage: "photo") {
                workspace.isPickingImage = true
            })
            return items
        case .construct:
            return ConstructionKind.allCases.map { kind in
                item(.construct(kind), kind.rawValue, subtitle: "Konstruktion", kind.systemImage)
            }
        case .transform:
            return [
                item(.move, "Verschieben/Rotieren", subtitle: "Körper oder Skizze", "move.3d"),
                item(.mirror, "Spiegeln", subtitle: "Körper", "arrow.left.and.right.righttriangle.left.righttriangle.right"),
                item(.pattern(.linear), "Muster linear", subtitle: "Körper", PatternKind.linear.systemImage),
                item(.pattern(.circular), "Muster kreisförmig", subtitle: "Körper", PatternKind.circular.systemImage),
                item(.scale, "Skalieren", subtitle: "Körper", "arrow.up.left.and.arrow.down.right"),
                item(.scaleSketch, "Skizze skalieren", subtitle: "Bereich antippen", "arrow.up.left.and.arrow.down.right"),
                item(.align, "Ausrichten", subtitle: "Körper", "align.horizontal.center"),
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
            items.append(item(.shell, "Schale", subtitle: "Fläche öffnen", "shippingbox"))
            items += BooleanKind.allCases.map { kind in
                item(.boolean(kind), kind.rawValue, subtitle: "Boolesch", kind.systemImage)
            }
            items += [
                item(.revolve, "Achsendrehung", subtitle: "Bereich um Achse", "arrow.triangle.2.circlepath"),
                item(.sweep, "Sweep", subtitle: "Bereich entlang Pfad", "point.3.connected.trianglepath.dotted"),
                item(.loft, "Loft", subtitle: "Durch Querschnitte", "square.3.layers.3d"),
                item(.offsetEdges, "Kante versetzen", subtitle: "Fläche antippen", "square.dashed.inset.filled"),
                item(.split, "Körper teilen", subtitle: "An Ebene", "rectangle.split.2x1"),
            ]
            items.append(ToolItem(id: "tools.delete", title: "Löschen", subtitle: "Körper", systemImage: "trash",
                                  isEnabled: model.hasSelection) {
                model.deleteSelected()
            })
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
            items += [
                item(.color, "Farbe", subtitle: "Körper", "paintpalette"),
                item(.section, "Schnittansicht", subtitle: workspace.section == nil ? "Aus" : "Ein",
                     "square.split.diagonal.2x2"),
                item(.measure, "Messen", subtitle: "Länge, Fläche, Abstand", "ruler"),
            ]
            items.append(ToolItem(id: "visualize.isolate", title: "Isolieren",
                                  subtitle: model.isIsolated ? "Alle zeigen" : "Gewählten Körper",
                                  systemImage: "scope", isActive: model.isIsolated) {
                workspace.toggleIsolate()
            })
            return items
        }
    }
}

/// Kachel der Werkzeugleiste mit Beschriftung daneben.
struct RailTile: View {
    let title: String
    var subtitle: String?
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
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                .hoverTip(item.title, ToolTips.detail(for: item.title) ?? item.subtitle)
            }
        }
        .padding(10)
    }
}
