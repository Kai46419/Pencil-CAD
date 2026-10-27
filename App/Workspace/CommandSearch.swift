import SwiftUI

// Befehlssuche (wie Fusion 360 „S“ bzw. Shapr3D-Suche): jedes Werkzeug per Name finden und starten.
// Mit Tastatur: ⌘K öffnet die Suche, Eingabetaste startet den ersten Treffer.

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// Weitere Suchwörter (englische Namen aus Fusion 360 und Shapr3D)
    var keywords = ""
    let action: () -> Void
}

extension Workspace {
    /// Alle Befehle für die Suche.
    var commandItems: [CommandItem] {
        func toolItem(_ tool: ModelTool, _ subtitle: String, _ systemImage: String, _ keywords: String = "") -> CommandItem {
            CommandItem(id: "tool.\(tool.title)", title: tool.title, subtitle: subtitle, systemImage: systemImage,
                        keywords: keywords) { [weak self] in self?.activate(tool) }
        }
        var items: [CommandItem] = [
            CommandItem(id: "sketch", title: "Skizze", subtitle: "Neue Skizze", systemImage: "pencil.and.outline",
                        keywords: "sketch zeichnen") { [weak self] in self?.startSketch() },
            CommandItem(id: "extrude", title: "Extrudieren", subtitle: "Bereich oder Fläche antippen, am Pfeil ziehen",
                        systemImage: "square.stack.3d.up", keywords: "extrude push pull") { [weak self] in
                self?.activate(.select)
                self?.model.message = "Skizzenbereich oder ebene Fläche antippen, dann am blauen Pfeil ziehen."
            },
        ]
        // Reihenfolge ungefähr wie die Gruppen der Leiste: Formen, Löcher, Vervielfältigen, Abrundungen, Flächen,
        // Kombinieren, Verschieben, Einfügen …
        items += [
            toolItem(.revolve, "Bereich um Achse drehen", "arrow.triangle.2.circlepath", "revolve drehen"),
            toolItem(.sweep, "Bereich entlang Pfad", "point.3.connected.trianglepath.dotted", "sweep"),
            toolItem(.loft, "Durch Querschnitte", "square.3.layers.3d", "loft"),
            toolItem(.part(.thinLines), "Linien einer Skizze als Wand", PartTool.thinLines.systemImage, "thin dünn wand linie"),
            toolItem(.part(.helix), "Feder, Gewinde", PartTool.helix.systemImage, "helix spirale feder gewinde thread spring"),
            toolItem(.hole, "Schrauben, Gewindeeinsätze, Senkungen", "circle.circle", "hole bohren gewinde ruthex"),
            CommandItem(id: "tappedHole", title: "Gewindebohrung", subtitle: "Bohrung mit Gewinde, Kernloch nach Tabelle",
                        systemImage: "circle.dashed.inset.filled", keywords: "tapped hole gewinde bohrung m3 m4 m5 m6") { [weak self] in
                guard let self else { return }
                self.activate(.hole)
                self.setHoleThread(self.holeSpec.thread ?? HoleThread())
            },
            toolItem(.part(.thread), "Metrisch, UNC, G, Trapez … an Bolzen, Bohrung oder als Gewindebohrung", PartTool.thread.systemImage,
                     "gewinde thread schraube mutter metrisch m6 m8 unc unf trapez whitworth npt rohrgewinde"),
            toolItem(.mirror, "Körper spiegeln", "arrow.left.and.right.righttriangle.left.righttriangle.right", "mirror"),
            toolItem(.pattern(.linear), "Körper in Reihe", PatternKind.linear.systemImage, "pattern array"),
            toolItem(.pattern(.circular), "Körper im Kreis", PatternKind.circular.systemImage, "pattern circular"),
            toolItem(.mold, "Form aus Block, mit Spiel, zweiteilig", "cube.transparent",
                     "mold negativ form gussform abformen block würfel spiel"),
        ]
        // ABRUNDUNGEN, FLÄCHEN, KOMBINIEREN
        items += EdgeOperation.allCases.map { operation in
            CommandItem(id: "edge.\(operation.rawValue)", title: operation.rawValue, subtitle: "Kanten",
                        systemImage: operation == .fillet ? "app" : "octagon",
                        keywords: operation == .fillet ? "fillet round radius" : "chamfer") { [weak self] in
                self?.startEdgeOperation(operation)
            }
        }
        items += [
            toolItem(.shell, "Hohl machen, Wandstärke", "shippingbox", "shell aushöhlen"),
            toolItem(.part(.draft), "Flächen neigen, Entformungsschräge", PartTool.draft.systemImage, "draft verjüngung schräge"),
            toolItem(.offsetFace, "Fläche verschieben, Bohrung weiten", "arrow.up.and.down.square", "offset face"),
            toolItem(.replaceFace, "Bis Zielfläche", "rectangle.portrait.and.arrow.forward", "replace face"),
            toolItem(.offsetEdges, "Kanten einer Fläche versetzen", "square.dashed.inset.filled", "offset edge"),
            toolItem(.wrap, "Text oder Logo auf Zylinder", "cylinder.split.1x2", "wrap emboss gravieren"),
            toolItem(.imprint, "Skizze auf Fläche übertragen", "square.on.square.dashed", "imprint"),
        ]
        items += BooleanKind.allCases.map { toolItem(.boolean($0), "Körper kombinieren", $0.systemImage, "boolean combine") }
        items += [
            toolItem(.split, "Mit Ebene, Körper oder Skizze", "rectangle.split.2x1", "split teilen schneiden"),
            toolItem(.meshSculpt, "Pinsel für Netze (STL, 3MF)", "paintbrush.pointed", "mesh netz sculpt pinsel stl 3mf glätten"),
        ]
        // VERSCHIEBEN
        items += [
            toolItem(.move, "Körper oder Skizze, mit Kopien", "move.3d", "move rotate drehen kopieren"),
            CommandItem(id: "copy", title: "Kopieren", subtitle: "Verschieben mit Kopie", systemImage: "plus.square.on.square",
                        keywords: "copy kopie duplizieren duplicate") { [weak self] in
                guard let self else { return }
                self.activate(.move)
                self.model.moveCopies = self.model.movingSketch == nil
            },
            toolItem(.translate, "Punkt zu Punkt", "point.topleft.down.to.point.bottomright.curvepath", "translate"),
            toolItem(.scale, "Körper skalieren", "arrow.up.left.and.arrow.down.right", "scale größe"),
            toolItem(.align, "Körper ausrichten", "align.horizontal.center", "align"),
        ]
        // EINFÜGEN
        items += [
            toolItem(.part(.standard), "Schrauben, Muttern, Scheiben, Kugellager", PartTool.standard.systemImage,
                     "normteil schraube mutter iso din lager bearing"),
            toolItem(.part(.template), "Gehäuse, Stirnrad", PartTool.template.systemImage, "vorlage gehäuse box zahnrad gear"),
        ]
        items += Primitive.allCases.map { toolItem(.insert($0), "Grundkörper", $0.systemImage, "primitive insert") }
        items += ConstructionKind.allCases.map { toolItem(.construct($0), "Konstruktion", $0.systemImage, "construct plane axis point") }
        items += [
            toolItem(.measure, "Länge, Fläche, Winkel, Radius, Abstand", "ruler", "measure"),
            toolItem(.printCheck, "Überhang, Wände, beste Ausrichtung", "printer", "print 3d druck slicer"),
            toolItem(.section, "Schnitt durch das Modell", "square.split.diagonal.2x2", "section cut"),
            CommandItem(id: "fit", title: "Einpassen", subtitle: "Alles zeigen", systemImage: "arrow.up.left.and.arrow.down.right",
                        keywords: "fit zoom") { [weak self] in self?.send(.fitAll) },
            CommandItem(id: "saveView", title: "Ansicht speichern", subtitle: "Blickwinkel merken", systemImage: "camera.viewfinder",
                        keywords: "view kamera") { [weak self] in self?.saveCurrentView() },
            CommandItem(id: "layers", title: "Ebenen", subtitle: "Browser mit Körpern und Skizzen", systemImage: "square.3.layers.3d",
                        keywords: "browser layers") { [weak self] in self?.showsLayers = true },
            CommandItem(id: "variables", title: "Variablen", subtitle: "Name = Wert", systemImage: "x.squareroot",
                        keywords: "parameter variable") { [weak self] in self?.showsVariables = true },
            CommandItem(id: "image", title: "Bild aus Fotos", subtitle: "Foto aus dem Album als Vorlage",
                        systemImage: "photo.on.rectangle", keywords: "bild einfügen canvas foto album vorlage") { [weak self] in
                self?.isPickingImage = true
            },
            CommandItem(id: "imageFile", title: "Bild aus Dateien", subtitle: "PNG, JPEG, HEIC oder PDF als Vorlage",
                        systemImage: "folder", keywords: "bild einfügen canvas datei pdf png jpeg heic vorlage") { [weak self] in
                self?.isImportingImageFile = true
            },
            CommandItem(id: "camera", title: "Foto aufnehmen", subtitle: "Mit der Kamera, als Vorlage",
                        systemImage: "camera", keywords: "bild einfügen kamera camera foto vorlage") { [weak self] in
                if CameraCapture.isAvailable {
                    self?.isTakingPhoto = true
                } else {
                    self?.model.message = "Keine Kamera verfügbar."
                }
            },
            CommandItem(id: "project", title: "Projekt einfügen", subtitle: "Körper eines anderen Projekts",
                        systemImage: "folder.badge.plus", keywords: "insert") { [weak self] in self?.showsProjectPicker = true },
            CommandItem(id: "isolate", title: "Isolieren", subtitle: "Nur den gewählten Körper zeigen", systemImage: "scope",
                        keywords: "isolate") { [weak self] in self?.toggleIsolate() },
            CommandItem(id: "drawing", title: "Zeichnung erstellen", subtitle: "Ansichten mit Maßen als PDF oder DXF",
                        systemImage: "doc.richtext", keywords: "drawing zeichnung technische pdf dxf ansichten") { [weak self] in
                self?.showsDrawing = true
            },
            CommandItem(id: "display.hiddenEdges", title: DisplayMode.hiddenEdges.rawValue, subtitle: "Anzeigemodus",
                        systemImage: DisplayMode.hiddenEdges.systemImage, keywords: "hidden lines verdeckt gestrichelt") { [weak self] in
                self?.displayMode = .hiddenEdges
            },
            CommandItem(id: "display.zebra", title: DisplayMode.zebra.rawValue, subtitle: "Flächenübergänge prüfen",
                        systemImage: DisplayMode.zebra.systemImage, keywords: "zebra stripes streifen tangential") { [weak self] in
                self?.displayMode = .zebra
            },
            CommandItem(id: "component", title: "Als Komponente", subtitle: "Kopien bleiben verknüpft",
                        systemImage: "shippingbox", keywords: "component instance verknüpfen") { [weak self] in
                guard let self else { return }
                let chosen = self.model.selectedBodies.isEmpty ? (self.model.selectedBody.map { [$0] } ?? [])
                    : self.model.selectedBodies
                if chosen.isEmpty {
                    self.model.message = "Erst einen Körper wählen, dann „Als Komponente“."
                } else {
                    self.model.makeComponent(chosen)
                }
            },
            CommandItem(id: "undo", title: "Rückgängig", subtitle: "Zwei Finger tippen", systemImage: "arrow.uturn.backward",
                        keywords: "undo") { [weak self] in self?.undo() },
            CommandItem(id: "redo", title: "Wiederholen", subtitle: "Drei Finger tippen", systemImage: "arrow.uturn.forward",
                        keywords: "redo") { [weak self] in self?.redo() },
        ]
        return items
    }
}

struct CommandSearchSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [CommandItem] {
        let items = workspace.commandItems
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(text) || $0.subtitle.localizedStandardContains(text)
                || $0.keywords.localizedStandardContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { item in
                Button {
                    run(item)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Befehl suchen")
            .onSubmit(of: .search) {
                if let first = results.first { run(first) }
            }
            .navigationTitle("Befehle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run(_ item: CommandItem) {
        dismiss()
        // Erst nach dem Schließen ausführen, sonst überlagern sich Blätter (Variablen, Projekte)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { item.action() }
    }
}
