import SwiftUI
import simd

// Linien der Blechbefehle im Ansichtsfenster (eingehängt in Viewport.updateLines nach addToolOverlays):
// - gewählte Blechkanten (Flansch, Pfadflansch, Umkantung) in Auswahlfarbe
// - gewählte Skizzenlinien (Konturflansch, Pfadflansch, Falten)
// - In Blech umwandeln: Biegekanten grün durchgezogen, offene Kanten rot gestrichelt, Grundfläche getönt
// Farben linear für Metal (wie SketchTheme.Metal), hell/dunkel nach AppTheme.

@MainActor
enum SheetUIOverlay {
    /// Biegekante: SolidCraft bend_up (dunkel 110,200,120 · hell 30,140,50)
    static var bendColor: SIMD3<Float> {
        AppTheme.isDark ? SketchTheme.linear(110, 200, 120) : SketchTheme.linear(30, 140, 50)
    }

    /// Offene Kante: Fehlerrot (dunkel 240,100,96 · hell 210,40,40)
    static var openColor: SIMD3<Float> {
        AppTheme.isDark ? SketchTheme.linear(240, 100, 96) : SketchTheme.linear(210, 40, 40)
    }

    /// Gewählte Kanten und Linien: Auswahlfarbe (dunkel #007FFF wie sel_edge, hell orange)
    static var pickColor: SIMD3<Float> {
        AppTheme.isDark ? SketchTheme.Metal.selection : SIMD3<Float>(0.98, 0.5, 0.06)
    }

    static func add(to groups: inout [LineGroup], fills: inout [FillGroup], workspace: Workspace, model: ModelStore,
                    perPoint: Double) {
        guard let cmd = workspace.command, cmd.editing == nil else { return }
        switch cmd.id {
        case .sheetFlange:
            addEdges(SheetEdgePicks.list(cmd, SheetFlangeDriver.edgesKey), to: &groups)
            addSketchLines(cmd, model, to: &groups)
        case .sheetPathFlange:
            addEdges(SheetEdgePicks.list(cmd, SheetPathFlangeDriver.edgeKey), to: &groups)
            addSketchLines(cmd, model, to: &groups)
        case .sheetHem:
            addEdges(SheetEdgePicks.list(cmd, SheetHemDriver.edgesKey), to: &groups)
        case .sheetFold:
            addSketchLines(cmd, model, to: &groups)
        case .sheetConvert:
            addConvert(cmd, model, to: &groups, fills: &fills, perPoint: perPoint)
        default:
            break
        }
    }

    /// Gewählte Blechkanten (Linienzüge vom Antippen; nach einer Vorschau bleiben sie an derselben Stelle)
    private static func addEdges(_ picks: [SheetEdgePick], to groups: inout [LineGroup]) {
        let lines = picks.flatMap(\.lines).map { $0.map { SIMD3<Float>($0) } }.filter { $0.count >= 2 }
        guard !lines.isEmpty else { return }
        groups.append(LineGroup(polylines: lines, color: pickColor, width: 4, onTop: true))
    }

    private static func addSketchLines(_ cmd: ModelCommand, _ model: ModelStore, to groups: inout [LineGroup]) {
        guard let sketch = SheetLines.sketch(cmd, model) else { return }
        let lines = SheetLines.worldLines(model, sketch: sketch, selected: SheetLines.selected(cmd))
            .map { $0.map { SIMD3<Float>($0) } }
        guard !lines.isEmpty else { return }
        groups.append(LineGroup(polylines: lines, color: pickColor, width: 4, onTop: true))
    }

    private static func addConvert(_ cmd: ModelCommand, _ model: ModelStore, to groups: inout [LineGroup],
                                   fills: inout [FillGroup], perPoint: Double) {
        guard let face = SheetConvertDriver.baseFace(cmd), model.bodies.indices.contains(face.body) else { return }
        let open = SheetConvertDriver.openEdges(cmd)
        var bendLines: [[SIMD3<Float>]] = []
        var openLines: [[SIMD3<Float>]] = []
        let dash = Float(max(perPoint, 1e-6) * 7)
        // Nur die Haut der Grundfläche (Kanten der anderen Seite gehören nicht zum Blech)
        let edges = SheetConvertDriver.isPlate(cmd, model) ? [] : SheetConvertDriver.skinCandidates(cmd, model)
        for edge in edges {
            let line = [SIMD3<Float>(edge.start), SIMD3<Float>(edge.end)]
            if open.contains(edge.edge) {
                openLines += dashed(line, dash: dash)
            } else {
                bendLines.append(line)
            }
        }
        // Grundfläche getönt (nur ohne 3D-Vorschau: dann zeigt das Netz den Ausgangskörper)
        if !model.hasPreview {
            let triangles = model.mesh.trianglePoints(of: face)
            if !triangles.isEmpty {
                let color = bendColor
                fills.append(FillGroup(triangles: triangles, color: SIMD4<Float>(color.x, color.y, color.z, 0.28)))
            }
        }
        if !bendLines.isEmpty {
            groups.append(LineGroup(polylines: bendLines, color: bendColor, width: 4, onTop: true))
        }
        if !openLines.isEmpty {
            groups.append(LineGroup(polylines: openLines, color: openColor, width: 4, onTop: true))
        }
    }

    /// Strecke in Striche zerlegen (Strich = Lücke = dash, Weltlänge)
    static func dashed(_ points: [SIMD3<Float>], dash: Float) -> [[SIMD3<Float>]] {
        guard points.count >= 2, dash > 0 else { return [points] }
        var result: [[SIMD3<Float>]] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let length = simd_distance(a, b)
            guard length > 1e-6 else { continue }
            let direction = (b - a) / length
            // Höchstens 400 Striche je Kante (sehr weit herangezoomt: durchgezogen)
            guard length / dash < 800 else {
                result.append([a, b])
                continue
            }
            var t: Float = 0
            while t < length {
                let end = min(t + dash, length)
                result.append([a + direction * t, a + direction * end])
                t += 2 * dash
            }
        }
        return result
    }
}
