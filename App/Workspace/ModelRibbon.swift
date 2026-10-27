import SwiftUI

// Daten des Modell-Ribbons nach SolidCraft (B.1): Gruppen Skizze · Erstellen · Ändern · Anordnen · Konstruieren ·
// Prüfen · Einfügen · Ansicht, je Gruppe Befehle mit Zwischenüberschriften, hervorgehobene (1–4) und angeheftete
// (UserDefaults „ribbon.pins“). Jeder Eintrag startet einen Modellbefehl (`workspace.startCommand`) bzw. eine direkte
// Aktion (Import, Variable, Anzeige). Die Darstellung steht in ToolRail.swift.

/// Ein Befehl der Leiste (Kachel bzw. Zeile im Gruppenmenü).
struct RibbonCommand: Identifiable {
    /// Stabil, auch Schlüssel der Stecknadel (z. B. "fillet", "plane.Mittelebene")
    let id: String
    let title: String
    var subtitle: String?
    let icon: String
    /// Zwischenüberschrift im Gruppenmenü (KANTEN, FLÄCHEN …)
    var heading: String?
    /// Tastenkürzel (Anzeige rechts, Hardware-Tastatur)
    var shortcut: String?
    /// Hervorgehoben: steht als Kachel direkt in der Leiste
    var featured = false
    var isActive = false
    var isEnabled = true
    let run: () -> Void
}

@MainActor
enum ModelRibbon {
    /// Angeheftete Befehle (kommagetrennte IDs)
    static let pinsKey = "ribbon.pins"
    /// Einstellung „Kontextvorschläge (Shapr3D)“: Leiste mit Aktionen zur Auswahl statt Gruppen (Std. aus)
    static let contextKey = "model.contextSuggestions"
    /// Höchstens so viele Kacheln je Gruppe
    static let maxTiles = 4

    static func pins(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Stecknadel umschalten; Ergebnis wieder als Text für @AppStorage
    static func toggled(_ id: String, in raw: String) -> String {
        var set = pins(raw)
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: ",")
    }

    /// Kacheln einer Gruppe: hervorgehobene und angeheftete in Menü-Reihenfolge
    static func tiles(_ commands: [RibbonCommand], pins: Set<String>, limit: Int = maxTiles) -> [RibbonCommand] {
        let featured = commands.filter { $0.featured }
        let pinned = commands.filter { !$0.featured && pins.contains($0.id) }
        return Array((featured + pinned).prefix(max(limit, 1)))
    }

    // MARK: Gruppen

    static func commands(for group: ToolGroup, ws: Workspace, importFile: @escaping () -> Void) -> [RibbonCommand] {
        let model = ws.model
        switch group {
        case .sketch:
            return [RibbonCommand(id: "sketch.new", title: "Neue Skizze", icon: "sc.sketch", featured: true,
                                  isActive: ws.sketch.isActive) { ws.startSketch() }]
        case .create:
            let drilling = ws.tool == .hole
            let threaded = ws.holeSpec.thread != nil
            var list: [RibbonCommand] = [
                command(.extrude, "Extrudieren", "Bereich oder Fläche, Pfeil ziehen", "sc.extrude", heading: "PROFIL",
                        shortcut: "E", featured: true, ws),
                command(.revolve, "Drehen", "Bereich um Achse", "sc.revolve", heading: "PROFIL", featured: true, ws),
                command(.sweep, "Sweep", "Bereich entlang Pfad", "sc.sweep", heading: "PROFIL", ws),
                command(.loft, "Loft", "Durch Querschnitte", "sc.loft", heading: "PROFIL", ws),
                command(.thinExtrude, "Dünn extrudieren", "Linien als Wand", PartTool.thinLines.systemImage,
                        heading: "PROFIL", ws),
                command(.helix, "Helix", "Feder, Spirale", PartTool.helix.systemImage, heading: "PROFIL", ws),
                RibbonCommand(id: "hole", title: "Bohrung", subtitle: "Senkung, Senkkopf, Einsätze", icon: "sc.hole",
                              heading: "BOHRUNGEN", featured: true, isActive: drilling && !threaded) {
                    ws.startCommand(.hole)
                    if ws.holeSpec.thread != nil { ws.setHoleThread(nil) }
                },
                // ★ Gewindebohrung als eigener Eintrag (Bohrung mit Gewinde)
                RibbonCommand(id: "hole.tapped", title: "Gewindebohrung", subtitle: "Kernloch mit Gewinde",
                              icon: "sc.hole", heading: "BOHRUNGEN", isActive: drilling && threaded) {
                    ws.startCommand(.hole)
                    ws.startTappedHole()
                },
                command(.thread, "Gewinde", "Bolzen, Bohrung, jede Fläche", PartTool.thread.systemImage,
                        heading: "BOHRUNGEN", ws),
            ]
            let primitives: [(ModelCommandID, Primitive)] = [(.box, .box), (.cylinder, .cylinder), (.sphere, .sphere),
                                                            (.torus, .torus), (.cone, .cone)]
            list += primitives.map { id, primitive in
                command(id, primitive.rawValue, "Grundkörper", primitive.systemImage, heading: "GRUNDKÖRPER", ws)
            }
            return list
        case .modify:
            let hasSelection = model.selection != nil || !model.selectedBodies.isEmpty || !model.selectedEdges.isEmpty
            return [
                command(.fillet, "Abrunden", "Kanten", "sc.fillet", heading: "KANTEN", shortcut: "F", featured: true, ws),
                command(.chamfer, "Fasen", "Kanten", "sc.chamfer", heading: "KANTEN", featured: true, ws),
                command(.offsetEdges, "Kante versetzen", "Ebene Fläche antippen", SketchTool.offset.systemImage,
                        heading: "KANTEN", ws),
                command(.pressPull, "Press Pull", "Fläche, Kante oder Profil", "sc.presspull", heading: "FLÄCHEN",
                        shortcut: "Q", featured: true, ws),
                command(.shell, "Schale", "Fläche öffnen, Wandstärke", "sc.shell", heading: "FLÄCHEN", featured: true, ws),
                command(.draft, "Formschräge", "Flächen neigen", "sc.draft", heading: "FLÄCHEN", ws),
                command(.offsetFace, "Fläche versetzen", "Auch Bohrungen", "sc.offset_face", heading: "FLÄCHEN", ws),
                command(.replaceFace, "Fläche ersetzen", "Bis Zielfläche", "sc.replace_face", heading: "FLÄCHEN", ws),
                command(.combine, "Kombinieren", "Vereinigen, Abziehen, Schneiden", "sc.combine", heading: "KÖRPER", ws),
                command(.splitBody, "Körper teilen", "Ebene, Körper, Skizze", "sc.split_body", heading: "KÖRPER", ws),
                command(.scale, "Skalieren", "Gleichmäßig", "sc.scale", heading: "KÖRPER", ws),
                RibbonCommand(id: "delete", title: "Löschen", subtitle: "Auswahl", icon: "sc.delete", heading: "KÖRPER",
                              isEnabled: hasSelection) {
                    model.deleteSelected()
                },
                command(.wrap, "Umhüllen und Prägen", "Auf Zylinder", "sc.emboss", heading: "SPEZIAL", ws),
                command(.imprint, "Kante abdrücken", "Skizze auf Fläche", "sc.project_surface", heading: "SPEZIAL", ws),
                command(.mold, "Negativform", "Form aus Block", "cube.transparent", heading: "SPEZIAL", ws),
            ]
        case .arrange:
            return [
                command(.move, "Verschieben", "Verschieben, Drehen, Punkt zu Punkt", "sc.move", featured: true, ws),
                command(.copy, "Kopieren", "Verschieben mit Kopie", "sc.copy", ws),
                command(.translate, "Punkt zu Punkt", "Mit Fangpunkten", "point.topleft.down.to.point.bottomright.curvepath",
                        ws),
                command(.align, "Ausrichten", "Am ersten Körper", "sc.align", ws),
                command(.mirror, "Spiegeln", "Körper", "sc.mirror", featured: true, ws),
                command(.patternRect, "Rechteckmuster", "Zwei Richtungen", "sc.pattern_rect", featured: true, ws),
                command(.patternCircular, "Kreismuster", "Um eine Achse", "sc.pattern_circ", ws),
                RibbonCommand(id: "scaleSketch", title: "Skizze skalieren", subtitle: "Bereich antippen",
                              icon: "sc.sketch_scale", isActive: ws.tool == .scaleSketch) {
                    ws.activate(.scaleSketch)
                },
            ]
        case .construct:
            var list: [RibbonCommand] = PlaneMethod.allCases.map { method in
                RibbonCommand(id: "plane.\(method.rawValue)", title: method == .offset ? "Versetzte Ebene" : method.rawValue,
                              subtitle: "Ebene", icon: "sc.plane", heading: "EBENEN", featured: method == .offset,
                              isActive: ws.tool == .construct(.plane) && ws.planeMethod == method) {
                    ws.planeMethod = method
                    ws.startCommand(.constructPlane)
                    ws.resetConstructPicks()
                }
            }
            list += AxisMethod.allCases.map { method in
                RibbonCommand(id: "axis.\(method.rawValue)", title: method == .pick ? "Achse" : method.rawValue,
                              subtitle: "Achse", icon: "sc.axis", heading: "ACHSEN",
                              isActive: ws.tool == .construct(.axis) && ws.axisMethod == method) {
                    ws.axisMethod = method
                    ws.constructCustomAxis = nil
                    ws.startCommand(.constructAxis)
                    ws.resetConstructPicks()
                }
            }
            list.append(RibbonCommand(id: "axis.normal", title: "Achse senkrecht", subtitle: "Zur gewählten Fläche",
                                      icon: "sc.axis_normal_to_face", heading: "ACHSEN",
                                      isEnabled: model.selection != nil && model.faceHandle != nil) {
                ws.createNormalAxis()
            })
            list.append(command(.constructPoint, "Punkt", "Koordinaten oder antippen", "sc.point", heading: "PUNKTE", ws))
            return list
        case .inspect:
            return [
                command(.measure, "Messen", "Länge, Fläche, Abstand", "sc.measure", featured: true, ws),
                RibbonCommand(id: "section", title: "Schnittansicht", subtitle: ws.section == nil ? "Aus" : "Ein",
                              icon: "sc.section", featured: true, isActive: ws.tool == .section || ws.section != nil) {
                    ws.startCommand(.section)
                },
                command(.printCheck, "Druckprüfung", "Überhang, Wände", "printer", ws),
                RibbonCommand(id: "isolate", title: "Isolieren", subtitle: model.isIsolated ? "Ein" : "Aus",
                              icon: "scope", isActive: model.isIsolated) {
                    ws.toggleIsolate()
                },
            ]
        case .insert:
            return insertCommands(ws, importFile: importFile)
        case .visualize:
            return visualizeCommands(ws)
        case .sheetMetal:
            return SheetUI.ribbonCommands(ws)
        }
    }

    private static func insertCommands(_ ws: Workspace, importFile: @escaping () -> Void) -> [RibbonCommand] {
        let model = ws.model
        return [
            RibbonCommand(id: "insert.standard", title: "Normteile", subtitle: "Schrauben, Muttern, Lager",
                          icon: PartTool.standard.systemImage, heading: "TEILE",
                          isActive: ws.tool == .part(.standard)) { ws.activate(.part(.standard)) },
            RibbonCommand(id: "insert.template", title: "Vorlagen", subtitle: "Gehäuse, Stirnrad",
                          icon: PartTool.template.systemImage, heading: "TEILE",
                          isActive: ws.tool == .part(.template)) { ws.activate(.part(.template)) },
            RibbonCommand(id: "insert.step", title: "STEP-Datei", subtitle: ".step / .stp", icon: "sc.import",
                          heading: "DATEIEN", featured: true, run: importFile),
            RibbonCommand(id: "insert.mesh", title: "STL / 3MF", subtitle: "Netz als Körper (3D-Druck)", icon: "triangle",
                          heading: "DATEIEN", run: importFile),
            RibbonCommand(id: "insert.vector", title: "SVG / DXF", subtitle: "Als Skizze (Laser, CNC, Logos)",
                          icon: "sc.svg", heading: "DATEIEN", run: importFile),
            command(.meshSculpt, "Netz bearbeiten", "Pinsel, STL/3MF", "paintbrush.pointed", heading: "DATEIEN", ws),
            RibbonCommand(id: "insert.image", title: "Bild aus Fotos", subtitle: "Fotoalbum, als Vorlage",
                          icon: "sc.canvas", heading: "BILD") { ws.isPickingImage = true },
            RibbonCommand(id: "insert.imageFile", title: "Bild aus Dateien", subtitle: "PNG, JPEG, HEIC, PDF",
                          icon: "folder", heading: "BILD") { ws.isImportingImageFile = true },
            RibbonCommand(id: "insert.camera", title: "Foto aufnehmen",
                          subtitle: CameraCapture.isAvailable ? "Kamera, als Vorlage" : "Keine Kamera verfügbar",
                          icon: "camera", heading: "BILD", isEnabled: CameraCapture.isAvailable) { ws.isTakingPhoto = true },
            RibbonCommand(id: "insert.project", title: "Projekt", subtitle: "Körper eines anderen Projekts",
                          icon: "folder.badge.plus", heading: "PROJEKT") { ws.showsProjectPicker = true },
            RibbonCommand(id: "insert.variable", title: "Variable",
                          subtitle: model.variables.isEmpty ? "Name = Wert" : "\(model.variables.count) im Projekt",
                          icon: "sc.params", heading: "PROJEKT") { ws.showsVariables = true },
        ]
    }

    private static func visualizeCommands(_ ws: Workspace) -> [RibbonCommand] {
        var list: [RibbonCommand] = DisplayMode.allCases.map { mode in
            RibbonCommand(id: "visualize.\(mode.rawValue)", title: mode.rawValue, icon: mode.systemImage,
                          heading: "DARSTELLUNG", isActive: ws.displayMode == mode) { ws.displayMode = mode }
        }
        list.append(RibbonCommand(id: "visualize.ortho", title: "Orthografisch", subtitle: "Projektion",
                                  icon: "cube.transparent", heading: "DARSTELLUNG", isActive: ws.isOrthographic) {
            ws.isOrthographic.toggle()
        })
        list.append(RibbonCommand(id: "visualize.color", title: "Farbe", subtitle: "Körper", icon: "sc.appearance",
                                  heading: "DARSTELLUNG", featured: true, isActive: ws.tool == .color) {
            ws.activate(.color)
        })
        list.append(RibbonCommand(id: "visualize.drawing", title: "Zeichnung", subtitle: "PDF, DXF",
                                  icon: "doc.richtext", heading: "AUSGABE") { ws.showsDrawing = true })
        let suggestions = UserDefaults.standard.bool(forKey: contextKey)
        list.append(RibbonCommand(id: "visualize.context", title: "Kontextvorschläge (Shapr3D)",
                                  subtitle: suggestions ? "Ein: Aktionen zur Auswahl links" : "Aus",
                                  icon: "rectangle.stack.badge.person.crop", heading: "LEISTE", isActive: suggestions) {
            UserDefaults.standard.set(!suggestions, forKey: contextKey)
        })
        return list
    }

    // MARK: Befehle

    static func command(_ id: ModelCommandID, _ title: String, _ subtitle: String?, _ icon: String,
                        heading: String? = nil, shortcut: String? = nil, featured: Bool = false,
                        _ ws: Workspace) -> RibbonCommand {
        RibbonCommand(id: id.rawValue, title: title, subtitle: subtitle, icon: icon, heading: heading, shortcut: shortcut,
                      featured: featured, isActive: isActive(id, ws)) {
            ws.startCommand(id)
        }
    }

    /// Läuft dieser Befehl gerade? Offenes Eigenschaften-Panel zuerst, sonst das bisherige Werkzeug.
    static func isActive(_ id: ModelCommandID, _ ws: Workspace) -> Bool {
        if let current = ws.command?.id { return current == id }
        let model = ws.model
        switch id {
        case .extrude, .pressPull:
            return ws.tool == .select && !ws.sketch.isActive
                && (!model.selectedRegions.isEmpty || model.faceHandle != nil) && model.selectedEdges.isEmpty
        case .fillet, .chamfer:
            return ws.tool == .select && !model.selectedEdges.isEmpty
                && model.edgeOperation == (id == .fillet ? EdgeOperation.fillet : EdgeOperation.chamfer)
        case .move:
            return ws.tool == .move && !model.moveCopies
        case .copy:
            return ws.tool == .move && model.moveCopies
        case .combine:
            if case .boolean = ws.tool { return true }
            return false
        case .patternRect, .patternCircular:
            return ws.tool == Workspace.legacyModelTool(for: id)
        default:
            guard let tool = Workspace.legacyModelTool(for: id) else { return false }
            return ws.tool == tool
        }
    }

    // MARK: Kontextvorschläge

    /// Befehle zur jetzigen Auswahl (früher die Kontextleiste): Menü „Auswahl“ oben im Ribbon (ToolRail.swift) und
    /// Werkzeugrad (QuickTools.swift).
    static func contextCommands(_ ws: Workspace) -> [RibbonCommand] {
        let model = ws.model
        let hasRegions = !model.selectedRegions.isEmpty
        let face = model.selection
        let planarFace = face != nil && model.faceHandle != nil
        var list: [RibbonCommand] = []
        if hasRegions || planarFace {
            list.append(command(.extrude, "Extrudieren", "Pfeil ziehen", "sc.extrude", ws))
        }
        if hasRegions {
            list.append(command(.revolve, "Drehen", nil, "sc.revolve", ws))
            list.append(command(.sweep, "Sweep", nil, "sc.sweep", ws))
            list.append(command(.loft, "Loft", nil, "sc.loft", ws))
            list.append(command(.wrap, "Umhüllen und Prägen", nil, "sc.emboss", ws))
            list.append(command(.imprint, "Kante abdrücken", nil, "sc.project_surface", ws))
            if let index = model.selectedRegions.first?.sketch, model.sketches.indices.contains(index) {
                list.append(RibbonCommand(id: "context.editSketch", title: "Skizze bearbeiten",
                                          subtitle: model.sketches[index].name, icon: "pencil.line") {
                    ws.editSketch(index)
                })
            }
        }
        if !model.selectedEdges.isEmpty {
            list.append(command(.fillet, "Abrunden", nil, "sc.fillet", ws))
            list.append(command(.chamfer, "Fasen", nil, "sc.chamfer", ws))
        }
        if face != nil {
            list.append(command(.offsetFace, "Fläche versetzen", nil, "sc.offset_face", ws))
            list.append(command(.shell, "Schale", nil, "sc.shell", ws))
            list.append(command(.draft, "Formschräge", nil, "sc.draft", ws))
        }
        if planarFace {
            list.append(command(.replaceFace, "Fläche ersetzen", nil, "sc.replace_face", ws))
            list.append(command(.offsetEdges, "Kante versetzen", nil, SketchTool.offset.systemImage, ws))
            list.append(RibbonCommand(id: "axis.normal", title: "Achse senkrecht", icon: "sc.axis_normal_to_face") {
                ws.createNormalAxis()
            })
        }
        if model.selectedBodies.count > 1 {
            list.append(command(.combine, "Kombinieren", "\(model.selectedBodies.count) Körper", "sc.combine", ws))
            list.append(command(.align, "Ausrichten", nil, "sc.align", ws))
        }
        if !model.selectedBodies.isEmpty || face != nil || !model.selectedEdges.isEmpty || hasRegions {
            list.append(command(.move, "Verschieben", nil, "sc.move", ws))
        }
        if !model.selectedBodies.isEmpty || face != nil || !model.selectedEdges.isEmpty {
            list.append(command(.copy, "Kopieren", nil, "sc.copy", ws))
            list.append(command(.mirror, "Spiegeln", nil, "sc.mirror", ws))
            list.append(command(.patternRect, "Rechteckmuster", nil, "sc.pattern_rect", ws))
            list.append(command(.scale, "Skalieren", nil, "sc.scale", ws))
            list.append(command(.splitBody, "Körper teilen", nil, "sc.split_body", ws))
        }
        list.append(command(.measure, "Messen", nil, "sc.measure", ws))
        return list
    }
}
