import SwiftUI
import simd

// Extrudieren nach SolidCraft (MIT, crates/ui-egui/src/dialogs.rs:784-803 Felder, dialogs_dense.rs:220-342 Panel,
// smart_extrude.rs Operation-Automatik, canvas.rs:21-70/546-631 Pfeile): Profile (Skizzenbereiche oder ebene
// Körperflächen) · Richtung · Ausmaß · Abstand · Abstand 2 · Operation · OPTIONEN (Dünn, Umkehren, ★ Innen
// aussparen) · ERWEITERT (Start, Versatz, Verjüngung). Gerechnet wird mit ModelStore.setRegionValue bzw. für Flächen
// mit setFaceValue (★ echtes Press Pull). Symmetrisch = Gesamtabstand (neue Extrusionen; alte behalten „je Seite“).

enum ExtrudeCommand: ModelCommandDriver {
    static let id: ModelCommandID = .extrude
    static let title = "Extrudieren"
    static let icon = "sc.extrude"
    static var explanation: String? {
        "Skizzenbereiche oder ebene Flächen antippen, dann am Pfeil ziehen oder den Abstand eingeben. Hinein ins "
            + "Material schneidet, daneben verbindet (Automatik, bis eine Operation von Hand gewählt wird). Eine "
            + "angetippte Stelle gibt die Höhe vor, Doppeltippen wiederholt die letzte Höhe."
    }

    enum Key {
        static let distance = "distance"
        static let distance2 = "distance2"
        static let offset = "offset"
        static let startOffset = "startOffset"
        static let taper = "taper"
        static let thickness = "thickness"
        static let thickness2 = "thickness2"
    }

    /// Wandlage „Zwei Seiten“ (innen Wandstärke, außen eigene Stärke)
    static let bothSides = "both"

    static func profilesInput() -> PickInput {
        PickInput(id: "profiles", title: "Profile", accepts: [.regions, .planarFaces], multiple: true,
                  hint: "Skizzenbereiche oder ebene Flächen im Viewport antippen")
    }

    static func toObjectInput() -> PickInput {
        PickInput(id: "toObject", title: "Bis Objekt", accepts: [.points], multiple: false,
                  hint: "Fläche, Kante oder Punkt antippen, bis zu dem extrudiert wird")
    }

    static func fromObjectInput() -> PickInput {
        PickInput(id: "fromObject", title: "Von Objekt", accepts: [.points], multiple: false,
                  hint: "Stelle antippen, auf deren Höhe das Profil beginnt")
    }

    // MARK: Anlegen

    static func make(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        var input = profilesInput()
        var picks: [Pick] = model.selectedRegions.map { Pick.region($0) }
        if picks.isEmpty {
            picks = model.selectedFaces.filter { model.plane(of: $0) != nil }.map { Pick.face($0) }
        }
        if picks.isEmpty, let last = model.sketches.indices.last, !model.sketches[last].isHidden,
           model.sketches[last].regions.count == 1, model.bodies(fromSketch: last).isEmpty {
            // Profil-Automatik (SolidCraft `default_profiles`): das eine noch unbenutzte Profil der letzten Skizze
            picks = [.region(RegionRef(sketch: last, region: 0))]
        }
        input.items = picks
        let cmd = ModelCommand(.extrude, inputs: [input])
        cmd.setNumber(Key.distance, 10)
        cmd.setNumber(Key.distance2, 10)
        cmd.setNumber(Key.offset, 0)
        cmd.setNumber(Key.startOffset, 5)
        cmd.setNumber(Key.taper, 0)
        cmd.setNumber(Key.thickness, 2)
        cmd.setNumber(Key.thickness2, 1)
        cmd.choices["direction"] = ExtrudeDirection.oneSide.rawValue
        cmd.choices["extent"] = ExtrudeExtent.distance.rawValue
        cmd.choices["start"] = "profile"
        cmd.choices["thinSide"] = ThinSide.inside.rawValue
        cmd.flags["throughHoles"] = model.regionThroughHoles
        cmd.flags["symmetricTotal"] = true
        cmd.autoOperation = true
        return cmd
    }

    static func primaryValueKey(_ cmd: ModelCommand) -> String? { Key.distance }

    // MARK: Auswahl

    static func regionRefs(_ cmd: ModelCommand) -> [RegionRef] {
        var refs: [RegionRef] = []
        for pick in cmd.items("profiles") {
            if case .region(let ref) = pick, refs.first.map({ $0.sketch == ref.sketch }) ?? true { refs.append(ref) }
        }
        return refs
    }

    static func faceRefs(_ cmd: ModelCommand) -> [FaceRef] {
        cmd.items("profiles").compactMap { pick -> FaceRef? in
            if case .face(let face) = pick { return face }
            return nil
        }
    }

    static func extent(_ cmd: ModelCommand) -> ExtrudeExtent {
        ExtrudeExtent(rawValue: cmd.choice("extent", default: ExtrudeExtent.distance.rawValue)) ?? .distance
    }

    /// Felder „Bis Objekt“/„Von Objekt“ passend zu Ausmaß und Start
    static func syncInputs(_ cmd: ModelCommand) {
        if extent(cmd) == .toObject {
            cmd.ensureInput(toObjectInput(), after: "profiles")
        } else {
            cmd.removeInput("toObject")
        }
        if cmd.choice("start", default: "profile") == "object" {
            cmd.ensureInput(fromObjectInput())
        } else {
            cmd.removeInput("fromObject")
        }
        cmd.advance()
    }

    static func point(_ pick: Pick?) -> SIMD3<Double>? {
        guard let pick else { return nil }
        if case .point(let p) = pick { return p }
        return nil
    }

    // MARK: Vorschau

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        // Bearbeiten aus dem Verlauf: gerechnet wird bei OK mit dem Nachbau (kein Doppel auf dem jetzigen Stand)
        if cmd.editing != nil { return nil }
        let regions = regionRefs(cmd)
        if regions.isEmpty {
            let faces = faceRefs(cmd)
            guard !faces.isEmpty else {
                model.resetSelection()
                return nil
            }
            return previewFaces(faces, cmd, ws)
        }
        return previewRegions(regions, cmd, ws)
    }

    /// Ebene Körperflächen: echtes Press Pull (Kernel `extruding(faces:)`), mehrere Flächen zugleich.
    private static func previewFaces(_ faces: [FaceRef], _ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        if model.selectedFaces != faces {
            model.select(face: faces[0])
            for face in faces.dropFirst() { model.toggleFace(face, commitsPreview: false) }
        }
        guard model.faceHandle != nil else { return "Nur ebene Flächen lassen sich so extrudieren." }
        var value = cmd.number(Key.distance, default: 10)
        if cmd.flag("flip") { value = -value }
        model.message = nil
        model.setFaceValue(value)
        if value != 0, !model.hasPreview { return model.message ?? "Extrudieren der Fläche nicht möglich." }
        return nil
    }

    private static func previewRegions(_ regions: [RegionRef], _ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sketches.indices.contains(regions[0].sketch) else { return "Die Skizze gibt es nicht mehr." }
        let sketch = model.sketches[regions[0].sketch]
        let plane = sketch.plane
        let direction = CommandDirection.direction(cmd)
        let extent = Self.extent(cmd)
        let thin = cmd.flag("thin")
        let flip = cmd.flag("flip")
        // selectRegions setzt den Wert auf 0: die Einstellungen danach rechnen nicht zwischendurch
        model.selectRegions(regions)
        guard let handle = model.regionHandle else { return "Bereich nicht gefunden." }

        var mode = CommandOperation.mode(cmd, default: model.bodies.isEmpty ? .newBody : .union)
        if cmd.autoOperation {
            let entered = cmd.number(Key.distance, default: 10)
            let side: Int = (entered >= 0) != flip ? 1 : -1
            mode = automaticMode(cmd, ws, regions: regions, plane: plane, center: handle.origin, side: side)
            cmd.choices["operation"] = mode.rawValue
        }
        model.regionMode = mode
        // Abziehen auf der Körperfläche (eine Seite): immer ins Material, egal welches Vorzeichen im Feld steht
        // (Kai: „ins Negative“ mit „Abziehen“ schnitt vorher aus dem Körper heraus und ließ ihn geschlossen)
        let faceCut = isFaceCut(plane: plane, mode: mode, direction: direction)
        // Pfeilrichtung hängt vom Modus ab (Abziehen auf Fläche = hinein): nach dem Setzen neu lesen
        let arrow = model.regionHandle ?? handle
        model.regionDirection = direction
        model.regionSecondValue = abs(cmd.number(Key.distance2, default: 10))
        model.regionTaper = direction == .oneSide && !thin ? cmd.number(Key.taper, default: 0) : 0
        model.regionThin = thin
        model.regionThinThickness = max(0.01, cmd.number(Key.thickness, default: 2))
        let wall = cmd.choice("thinSide", default: ThinSide.inside.rawValue)
        if wall == bothSides {
            model.regionThinSide = .inside
            model.regionThinThickness2 = max(0.01, cmd.number(Key.thickness2, default: 1))
        } else {
            model.regionThinSide = ThinSide(rawValue: wall) ?? .inside
            model.regionThinThickness2 = nil
        }
        model.regionThroughHoles = cmd.flag("throughHoles")
        model.regionSymmetricTotal = cmd.flag("symmetricTotal")
        let fromPoint = point(cmd.items("fromObject").first)
        let start: Double
        switch cmd.choice("start", default: "profile") {
        case "offset":
            start = cmd.number(Key.startOffset, default: 5)
        case "object":
            start = fromPoint.map { simd_dot($0 - plane.origin, plane.normal) } ?? 0
        default:
            start = 0
        }
        model.regionStartOffset = start

        // Abstand je Ausmaß, entlang des Pfeils (Pfeilrichtung = Skizzennormale, beim Schneiden auf Flächen hinein)
        let axis: SIMD3<Double> = simd_normalize(arrow.direction)
        let base: SIMD3<Double> = arrow.origin + plane.normal * start
        let toPoint = point(cmd.items("toObject").first)
        var value: Double
        switch extent {
        case .distance:
            value = cmd.number(Key.distance, default: 10)
            if flip { value = -value }
            if faceCut { value = abs(value) }
        case .all:
            model.dropPreview()
            value = throughAll(model, origin: base, direction: axis, backwards: flip && !faceCut)
            guard value != 0 else { return "Kein Körper in Richtung des Profils." }
        case .toObject:
            guard let target = toPoint else {
                model.dropPreview()
                return nil
            }
            let raw: Double = simd_dot(target - base, axis)
            guard abs(raw) > 1e-4 else { return "Das Ziel liegt in der Profilebene." }
            value = raw + (raw >= 0 ? 1 : -1) * cmd.number(Key.offset, default: 0)
        }
        model.message = nil
        model.setRegionValue(value)
        guard value == 0 || model.hasPreview else {
            return model.message ?? "Bereich lässt sich nicht extrudieren."
        }
        model.notePanelData(extent: extent.rawValue, toObject: toPoint, fromObject: fromPoint,
                            operationAuto: cmd.autoOperation, flipped: flip)
        return nil
    }

    /// „Alle“: so weit, dass das Profil durch alle sichtbaren Körper reicht (wie ModelStore.extrudeThroughAll).
    private static func throughAll(_ model: ModelStore, origin: SIMD3<Double>, direction: SIMD3<Double>,
                                   backwards: Bool) -> Double {
        var ahead = 0.0
        var behind = 0.0
        for body in model.bodies.indices where !model.bodies[body].isHidden {
            guard let box = model.mesh.bounds(ofBody: body) else { continue }
            for k in 0..<8 {
                let x = Double(k & 1 == 0 ? box.min.x : box.max.x)
                let y = Double(k & 2 == 0 ? box.min.y : box.max.y)
                let z = Double(k & 4 == 0 ? box.min.z : box.max.z)
                let t: Double = simd_dot(SIMD3<Double>(x, y, z) - origin, direction)
                ahead = max(ahead, t)
                behind = min(behind, t)
            }
        }
        // Toleranz 1e-3 (Float-Hüllquader): eine Skizze auf der Körperfläche liegt nicht um Rundungsreste „vor“ ihm
        let value: Double
        if backwards {
            value = behind < -1e-3 ? behind - 1 : ahead > 1e-3 ? ahead + 1 : 0
        } else {
            value = ahead > 1e-3 ? ahead + 1 : behind < -1e-3 ? behind - 1 : 0
        }
        return (value * 1000).rounded() / 1000
    }

    /// Abziehen in eine Seite auf einer Körperfläche: der Abstand zählt immer ins Material.
    static func isFaceCut(plane: SketchPlane, mode: ExtrudeMode, direction: ExtrudeDirection) -> Bool {
        plane.isOnFace && mode == .cut && direction == .oneSide
    }

    /// Läuft gerade ein Abziehen auf einer Körperfläche (Vorschau des Befehls)?
    private static func faceCutActive(_ cmd: ModelCommand, _ model: ModelStore) -> Bool {
        let regions = regionRefs(cmd)
        guard let first = regions.first, model.sketches.indices.contains(first.sketch) else { return false }
        return isFaceCut(plane: model.sketches[first.sketch].plane, mode: model.regionMode,
                         direction: CommandDirection.direction(cmd))
    }

    // MARK: Operation-Automatik (SolidCraft smart_extrude.rs)

    /// In Material hinein = Schneiden, an einen Körper heran = Verbinden, frei im Raum = Neuer Körper. Die erste
    /// Wahl je Seite bleibt (ein Schnitt bleibt Schnitt, auch wenn er durchbricht).
    private static func automaticMode(_ cmd: ModelCommand, _ ws: Workspace, regions: [RegionRef], plane: SketchPlane,
                                      center: SIMD3<Double>, side: Int) -> ExtrudeMode {
        let key = "auto\(side)"
        if let stored = cmd.choices[key], let mode = ExtrudeMode(rawValue: stored) { return mode }
        let model = ws.model
        let mode: ExtrudeMode
        if model.bodies.isEmpty {
            mode = .newBody
        } else if plane.isOnFace {
            // Auf einer Körperfläche: herausziehen verbindet, hineindrücken schneidet – das Panel zeigt dann auch
            // „Abziehen“ (vorher stand dort „Verbinden“; wer daraufhin „Abziehen“ wählte, schnitt ins Leere)
            mode = side < 0 && CommandDirection.direction(cmd) == .oneSide ? .cut : .union
        } else {
            // Ohne Vorschau prüfen (die Vorschau hätte andere Körper)
            model.dropPreview()
            let normal: SIMD3<Double> = plane.normal * Double(side)
            if insideMaterial(model, from: center, along: normal) {
                mode = .cut
            } else if touchesBody(model, regions: regions, plane: plane, along: normal,
                                  length: max(1, abs(cmd.number(Key.distance, default: 10)))) {
                mode = .union
            } else {
                mode = .newBody
            }
        }
        cmd.choices[key] = mode.rawValue
        return mode
    }

    /// Liegt der Punkt knapp vor dem Profil im Material? Der erste Treffer entlang der Richtung ist dann eine
    /// Austrittsfläche (Normale zeigt mit der Richtung).
    private static func insideMaterial(_ model: ModelStore, from center: SIMD3<Double>, along normal: SIMD3<Double>) -> Bool {
        let start = SIMD3<Float>(center + normal * 0.05)
        guard let hit = model.pick(origin: start, direction: SIMD3<Float>(simd_normalize(normal))),
              let face = model.plane(of: hit.face) else { return false }
        return simd_dot(face.normal, normal) > 0.2
    }

    /// Berührt bzw. überlappt der Extrusionsquader einen Körper (Hüllquader)?
    private static func touchesBody(_ model: ModelStore, regions: [RegionRef], plane: SketchPlane,
                                    along normal: SIMD3<Double>, length: Double) -> Bool {
        guard model.sketches.indices.contains(regions[0].sketch) else { return false }
        let sketch = model.sketches[regions[0].sketch]
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        for ref in regions where sketch.regions.indices.contains(ref.region) {
            for p in sketch.regions[ref.region].polygon {
                let a: SIMD3<Double> = plane.world(p)
                let b: SIMD3<Double> = a + normal * length
                low = simd_min(low, simd_min(a, b))
                high = simd_max(high, simd_max(a, b))
            }
        }
        guard low.x <= high.x else { return false }
        let margin = 0.01
        for body in model.bodies.indices where !model.bodies[body].isHidden {
            guard let box = model.mesh.bounds(ofBody: body) else { continue }
            let boxLow = SIMD3<Double>(box.min) - margin
            let boxHigh = SIMD3<Double>(box.max) + margin
            let overlaps = low.x <= boxHigh.x && high.x >= boxLow.x && low.y <= boxHigh.y && high.y >= boxLow.y
                && low.z <= boxHigh.z && high.z >= boxLow.z
            if overlaps { return true }
        }
        return false
    }

    // MARK: Antippen

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        let model = ws.model
        guard let profiles = cmd.inputIndex("profiles") else { return false }
        let activeID: String = cmd.inputs.indices.contains(cmd.activeInput) ? cmd.inputs[cmd.activeInput].id : "profiles"
        if cmd.editing != nil {
            model.message = "Beim Bearbeiten bleiben die Profile; Werte im Panel ändern."
            return true
        }
        // Bis Objekt / Von Objekt: die angetippte Stelle
        if activeID == "toObject" || activeID == "fromObject", let p = tap.point {
            cmd.setItems(activeID, [.point(model.snappedModelPoint(p, tolerance: ws.pickTolerance))])
            cmd.advance()
            ws.refreshCommandPreview()
            return true
        }
        let regions = regionRefs(cmd)
        if let region = tap.region {
            if let first = regions.first, first.sketch != region.sketch {
                // ★ Bereich einer parallelen Skizze in anderer Höhe: Höhe bis dorthin; sonst neu beginnen
                if parallel(model, first.sketch, region.sketch), let p = tap.point, extendTo(p, cmd, ws) { return true }
                cmd.inputs[profiles].items = [.region(region)]
            } else if regions.isEmpty {
                cmd.inputs[profiles].items = [.region(region)]
            } else if let index = cmd.inputs[profiles].items.firstIndex(of: .region(region)) {
                cmd.inputs[profiles].items.remove(at: index)
            } else {
                cmd.inputs[profiles].items.append(.region(region))
            }
            cmd.activeInput = profiles
            cmd.error = nil
            ws.refreshCommandPreview()
            return true
        }
        guard let face = tap.face else {
            // Kante bei Profilen: Höhe bis dorthin (wie „Bis Objekt“ ohne Umschalten)
            if !regions.isEmpty, tap.edge != nil, let p = tap.point { return extendTo(p, cmd, ws) }
            return false
        }
        if !regions.isEmpty {
            // ★ Fusion „Bis Objekt“ ohne Umschalten: angetippte Stelle gibt die Höhe vor (noch nicht gezogen: nur
            // parallele ebene Flächen)
            let drawn = cmd.number(Key.distance, default: 0) != 0
            if let p = tap.point, drawn || parallel(model, face: face, sketch: regions[0].sketch) {
                _ = extendTo(p, cmd, ws)
            }
            return true
        }
        guard model.plane(of: face) != nil else {
            model.message = "Nur ebene Flächen lassen sich extrudieren – für gewölbte Flächen „Fläche versetzen“."
            return true
        }
        if let index = cmd.inputs[profiles].items.firstIndex(of: .face(face)) {
            cmd.inputs[profiles].items.remove(at: index)
        } else {
            cmd.inputs[profiles].items.append(.face(face))
        }
        cmd.activeInput = profiles
        cmd.error = nil
        ws.refreshCommandPreview()
        return true
    }

    private static func parallel(_ model: ModelStore, _ a: Int, _ b: Int) -> Bool {
        guard model.sketches.indices.contains(a), model.sketches.indices.contains(b) else { return false }
        let n1 = simd_normalize(model.sketches[a].plane.normal)
        let n2 = simd_normalize(model.sketches[b].plane.normal)
        return abs(simd_dot(n1, n2)) > 0.999
    }

    private static func parallel(_ model: ModelStore, face: FaceRef, sketch: Int) -> Bool {
        guard model.sketches.indices.contains(sketch), let plane = model.plane(of: face) else { return false }
        return abs(simd_dot(simd_normalize(plane.normal), simd_normalize(model.sketches[sketch].plane.normal))) > 0.999
    }

    /// Abstand so setzen, dass die Extrusion bis zur Stelle p reicht.
    private static func extendTo(_ p: SIMD3<Double>, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        let model = ws.model
        guard let handle = model.regionHandle, simd_length(handle.direction) > 1e-12 else { return false }
        let regions = regionRefs(cmd)
        guard let first = regions.first, model.sketches.indices.contains(first.sketch) else { return false }
        let plane = model.sketches[first.sketch].plane
        let base: SIMD3<Double> = handle.origin + plane.normal * model.regionStartOffset
        let raw: Double = (simd_dot(p - base, simd_normalize(handle.direction)) * 10_000).rounded() / 10_000
        guard abs(raw) > 1e-4 else { return false }
        var value = raw
        if CommandDirection.direction(cmd) == .symmetric, cmd.flag("symmetricTotal") { value = raw * 2 }
        if faceCutActive(cmd, model) {
            // Pfeil zeigt ins Material: wie beim Ziehen ins Feld umrechnen (Automatik: negativ = hinein)
            value = cmd.autoOperation ? (cmd.flag("flip") ? raw : -raw)
                : (cmd.number(Key.distance, default: 10) < 0 ? -1 : 1) * abs(raw)
        } else if cmd.flag("flip") {
            value = -value
        }
        cmd.choices["extent"] = ExtrudeExtent.distance.rawValue
        syncInputs(cmd)
        cmd.setNumber(Key.distance, value)
        ws.refreshCommandPreview()
        model.message = "Bis zur angetippten Stelle: \(LengthUnit.current.format(raw))"
        return true
    }

    // MARK: Pfeile

    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        let model = ws.model
        let blue = Workspace.handleBlue
        if cmd.editing != nil { return [] }
        let regions = regionRefs(cmd)
        if regions.isEmpty {
            guard !faceRefs(cmd).isEmpty, let handle = model.faceHandle else { return [] }
            return [DragHandle(kind: .command(Key.distance), axisOrigin: SIMD3<Float>(handle.origin),
                               direction: simd_normalize(SIMD3<Float>(handle.direction)), value: model.faceValue,
                               color: blue)]
        }
        guard let handle = model.regionHandle, model.sketches.indices.contains(regions[0].sketch) else { return [] }
        let plane = model.sketches[regions[0].sketch].plane
        let axis: SIMD3<Double> = simd_normalize(handle.direction)
        let origin: SIMD3<Double> = handle.origin + plane.normal * model.regionStartOffset
        let value = model.regionValue
        let direction = model.regionDirection
        let halves = direction == .symmetric && model.regionSymmetricTotal
        var list: [DragHandle] = [
            DragHandle(kind: .command(Key.distance), axisOrigin: SIMD3<Float>(origin), direction: SIMD3<Float>(axis),
                       value: halves ? value / 2 : value, color: blue),
        ]
        if direction == .twoSides {
            // Zweiter Pfeil in Gegenrichtung (SolidCraft canvas.rs:546-566)
            let back: SIMD3<Double> = value >= 0 ? -axis : axis
            list.append(DragHandle(kind: .command(Key.distance2), axisOrigin: SIMD3<Float>(origin),
                                   direction: SIMD3<Float>(back), value: model.regionSecondValue, color: blue))
        }
        if direction == .oneSide, !model.regionThin, value != 0 {
            // Verjüngungsgriff neben der Pfeilspitze: seitlich ziehen neigt die Wände (canvas.rs:600-631)
            let tip: SIMD3<Double> = origin + axis * value
            let sideways: SIMD3<Double> = simd_normalize(plane.u)
            let lean: Double = abs(value) * tan(model.regionTaper * .pi / 180)
            list.append(DragHandle(kind: .command(Key.taper), axisOrigin: SIMD3<Float>(tip),
                                   direction: SIMD3<Float>(sideways), value: lean,
                                   color: SIMD3<Float>(0.95, 0.55, 0.12), scale: 0.6))
        }
        return list
    }

    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = handle else { return }
        let model = ws.model
        switch key {
        case Key.distance:
            var entered = value
            if !regionRefs(cmd).isEmpty, CommandDirection.direction(cmd) == .symmetric, cmd.flag("symmetricTotal") {
                entered = value * 2
            }
            if faceCutActive(cmd, model) {
                // Pfeil zeigt ins Material, value = Tiefe. Automatik: im Feld negativ = hinein (umgekehrt positiv),
                // herausgezogen (value < 0) wird es wieder Verbinden. Von Hand „Abziehen“: Vorzeichen bleibt.
                if cmd.autoOperation {
                    entered = cmd.flag("flip") ? value : -value
                } else {
                    entered = (cmd.number(Key.distance, default: 10) < 0 ? -1 : 1) * abs(value)
                }
            } else if cmd.flag("flip") {
                entered = -entered
            }
            if extent(cmd) != .distance {
                // Ziehen heißt Abstand (wie SolidCraft: der Pfeil zeigt dann den Wert)
                cmd.choices["extent"] = ExtrudeExtent.distance.rawValue
                syncInputs(cmd)
            } else if entered == cmd.number(Key.distance, default: 10) {
                return
            }
            cmd.setNumber(Key.distance, entered)
        case Key.distance2:
            let second = abs(value)
            guard second != cmd.number(Key.distance2, default: 10) else { return }
            cmd.setNumber(Key.distance2, second)
        case Key.taper:
            let height = abs(model.regionValue)
            guard height > 1e-9 else { return }
            var degrees: Double = atan2(value, height) * 180 / .pi
            degrees = min(45, max(-45, (degrees * 2).rounded() / 2))
            guard degrees != cmd.number(Key.taper, default: 0) else { return }
            cmd.setNumber(Key.taper, degrees)
        default:
            return
        }
        ws.refreshCommandPreview()
    }

    static func valueText(handle: HandleKind, value: Double, _ cmd: ModelCommand) -> String? {
        guard case .command(let key) = handle else { return nil }
        switch key {
        case Key.taper:
            let degrees = cmd.number(Key.taper, default: 0)
            return "∠ " + degrees.formatted(.number.precision(.fractionLength(0...1))) + "°"
        case Key.distance:
            guard !regionRefs(cmd).isEmpty, CommandDirection.direction(cmd) == .symmetric, cmd.flag("symmetricTotal") else {
                return nil
            }
            return "↔ " + LengthUnit.current.format(value * 2)
        default:
            return nil
        }
    }

    // MARK: OK, Abbrechen, Bearbeiten

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil && cmd.number(Key.distance, default: 0) != 0 }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        if let id = cmd.editing {
            commitEdit(id, cmd, ws)
        } else {
            ws.model.commitPreview()
        }
        resetModelExtras(ws.model)
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.cancelPreview()
        resetModelExtras(ws.model)
    }

    /// Nur das Panel kennt diese Einstellungen; der alte Pfeil-Weg (Karte unten) beginnt wieder ohne sie.
    private static func resetModelExtras(_ model: ModelStore) {
        model.regionStartOffset = 0
        model.regionThinThickness2 = nil
        model.regionSymmetricTotal = false
    }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        guard feature.kind == .extrude || feature.kind == .faceExtrude else { return nil }
        let model = ws.model
        var input = profilesInput()
        input.isOptional = true
        input.items = (feature.data.regions ?? []).compactMap { probe -> Pick? in
            guard let index = model.sketches.firstIndex(where: { $0.id == probe.sketchID }) else { return nil }
            let region = model.sketches[index].region(containing: probe.point) ?? probe.index
            guard model.sketches[index].regions.indices.contains(region) else { return nil }
            return .region(RegionRef(sketch: index, region: region))
        }
        input.hint = "Beim Bearbeiten bleiben die Profile des Features"
        let cmd = ModelCommand(.extrude, inputs: [input])
        let data = feature.data
        let direction = ExtrudeDirection(rawValue: data.direction ?? "") ?? .oneSide
        let total = data.symmetricTotal == true && direction == .symmetric
        let perSide = feature.value("distance") ?? 10
        let flipped = data.flipped == true
        let shown: Double = (total ? perSide * 2 : perSide) * (flipped ? -1 : 1)
        cmd.setNumber(Key.distance, shown)
        cmd.setNumber(Key.distance2, feature.value("second") ?? 10)
        cmd.setNumber(Key.taper, feature.value("taper") ?? 0)
        cmd.setNumber(Key.thickness, feature.value("thickness") ?? 2)
        cmd.setNumber(Key.thickness2, 1)
        cmd.setNumber(Key.offset, 0)
        cmd.setNumber(Key.startOffset, 5)
        cmd.choices["direction"] = direction.rawValue
        cmd.choices["extent"] = ExtrudeExtent.distance.rawValue
        cmd.choices["start"] = "profile"
        cmd.choices["operation"] = data.mode ?? ExtrudeMode.newBody.rawValue
        cmd.choices["thinSide"] = data.thinSide ?? ThinSide.inside.rawValue
        cmd.flags["thin"] = data.thin == true
        cmd.flags["throughHoles"] = data.throughHoles == true
        cmd.flags["symmetricTotal"] = data.symmetricTotal == true
        cmd.flags["flip"] = flipped
        cmd.flags["faceEdit"] = feature.kind == .faceExtrude
        cmd.autoOperation = false
        cmd.editing = feature.id
        return cmd
    }

    /// OK beim Bearbeiten: Werte ins Feature schreiben und ab dort nachbauen (ein Rückgängig-Schritt).
    private static func commitEdit(_ id: UUID, _ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        guard let index = model.features.firstIndex(where: { $0.id == id }) else { return }
        var list = model.features
        var feature = list[index]
        let flip = cmd.flag("flip")
        var entered = cmd.number(Key.distance, default: 10)
        if flip { entered = -entered }
        if feature.kind == .faceExtrude {
            setParameter(&feature, .length("distance", "Abstand", entered))
        } else {
            let direction = CommandDirection.direction(cmd)
            let total = direction == .symmetric && cmd.flag("symmetricTotal")
            var mode = CommandOperation.mode(cmd)
            let thin = cmd.flag("thin")
            if feature.data.onFace == true, direction == .oneSide {
                // Wie in der Vorschau: auf der Körperfläche schneidet Abziehen immer ins Material, Verbinden mit
                // negativem Abstand wird Abziehen (der Nachbau kennt diese Automatik nicht)
                if mode == .union, entered < 0 {
                    mode = .cut
                    entered = -entered
                } else if mode == .cut {
                    entered = abs(entered)
                }
            }
            setParameter(&feature, .length("distance", "Abstand", total ? entered / 2 : entered))
            setParameter(&feature, direction == .twoSides
                         ? .length("second", "Zweite Seite", abs(cmd.number(Key.distance2, default: 10))) : nil, key: "second")
            let taper = cmd.number(Key.taper, default: 0)
            setParameter(&feature, direction == .oneSide && !thin && taper != 0
                         ? .angle("taper", "Verjüngung", taper) : nil, key: "taper")
            setParameter(&feature, thin ? .length("thickness", "Wandstärke", cmd.number(Key.thickness, default: 2)) : nil,
                         key: "thickness")
            feature.data.mode = mode.rawValue
            feature.data.direction = direction.rawValue
            feature.data.thin = thin
            let wall = cmd.choice("thinSide", default: ThinSide.inside.rawValue)
            feature.data.thinSide = wall == bothSides ? ThinSide.inside.rawValue : wall
            feature.data.throughHoles = cmd.flag("throughHoles")
            feature.data.symmetricTotal = total ? true : nil
            feature.data.flipped = flip ? true : nil
            feature.data.operationAuto = false
            if feature.name.hasPrefix("Extrudieren") {
                feature.name = mode == .newBody ? "Extrudieren" : "Extrudieren (\(mode.rawValue))"
            }
        }
        list[index] = feature
        model.replayFeatures(from: index, features: list, sketches: nil, name: "„\(feature.name)“ ändern")
    }

    /// Parameter setzen (Formel bleibt, wenn der Wert gleich ist) bzw. entfernen (nil).
    static func setParameter(_ feature: inout Feature, _ parameter: FeatureParameter?, key: String? = nil) {
        let name = parameter?.key ?? key ?? ""
        if let index = feature.parameters.firstIndex(where: { $0.key == name }) {
            if let parameter {
                if feature.parameters[index].value != parameter.value {
                    feature.parameters[index].value = parameter.value
                    feature.parameters[index].formula = nil
                }
            } else {
                feature.parameters.remove(at: index)
            }
        } else if let parameter {
            feature.parameters.append(parameter)
        }
    }

    // MARK: Panel

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ExtrudeRows(cmd: cmd, ws: ws, model: ws.model))
    }
}

/// Panelzeilen Extrudieren (SolidCraft dialogs_dense.rs:220-342).
private struct ExtrudeRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    @ObservedObject var model: ModelStore

    private typealias Key = ExtrudeCommand.Key

    private var usesRegions: Bool { !ExtrudeCommand.regionRefs(cmd).isEmpty }
    private var editing: Bool { cmd.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesRegions || (editing && !cmd.flag("faceEdit")) {
                regionRows
            } else {
                faceRows
            }
        }
    }

    // MARK: Flächen (Press Pull)

    @ViewBuilder private var faceRows: some View {
        value("Abstand", Key.distance, default: 10)
        CheckRow(title: "Richtung umkehren", isOn: commandFlag("flip", cmd, ws))
        PaletteHint(text: "Ebene Flächen werden direkt verschoben (Press Pull). Weitere Flächen antippen zieht sie mit.")
    }

    // MARK: Profile

    @ViewBuilder private var regionRows: some View {
        let direction = CommandDirection.direction(cmd)
        let extent = ExtrudeCommand.extent(cmd)
        PanelSegmentRow(title: "Richtung", options: CommandDirection.options, selected: direction.rawValue) { id in
            cmd.choices["direction"] = id
            ws.refreshCommandPreview()
        }
        if !editing {
            PanelSegmentRow(title: "Ausmaß", options: Self.extentOptions, selected: extent.rawValue) { id in
                cmd.choices["extent"] = id
                ExtrudeCommand.syncInputs(cmd)
                ws.refreshCommandPreview()
            }
        }
        switch extent {
        case .distance:
            value(direction == .symmetric && cmd.flag("symmetricTotal") ? "Abstand ↔" : "Abstand", Key.distance, default: 10)
        case .toObject:
            value("Versatz", Key.offset, default: 0)
        case .all:
            Text("Durch alle Körper: \(LengthUnit.current.format(abs(model.regionValue)))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if direction == .twoSides {
            value("Abstand 2", Key.distance2, default: 10)
        }
        operationRow
        CommandSection("Optionen", command: .extrude, section: "options") {
            optionRows
        }
        if !editing {
            let advancedSet = cmd.choice("start", default: "profile") != "profile" || cmd.number(Key.taper, default: 0) != 0
            CommandSection("Erweitert", command: .extrude, section: "advanced", expanded: false, forceOpen: advancedSet) {
                advancedRows(direction)
            }
        } else if direction == .oneSide, !cmd.flag("thin") {
            value("Verjüngung", Key.taper, unit: "°", default: 0)
        }
    }

    private static let extentOptions: [SegmentOption] = [
        SegmentOption(id: ExtrudeExtent.distance.rawValue, label: "Abstand"),
        SegmentOption(id: ExtrudeExtent.toObject.rawValue, label: "Bis Objekt"),
        SegmentOption(id: ExtrudeExtent.all.rawValue, label: "Alle"),
    ]

    private static let wallOptions: [SegmentOption] = [
        SegmentOption(id: ThinSide.center.rawValue, label: "Mitte"),
        SegmentOption(id: ThinSide.inside.rawValue, label: "Innen"),
        SegmentOption(id: ThinSide.outside.rawValue, label: "Außen"),
        SegmentOption(id: ExtrudeCommand.bothSides, label: "Beide"),
    ]

    private static let startOptions: [SegmentOption] = [
        SegmentOption(id: "profile", label: "Profilebene"),
        SegmentOption(id: "offset", label: "Versatz"),
        SegmentOption(id: "object", label: "Von Objekt"),
    ]

    @ViewBuilder private var operationRow: some View {
        let fallback: ExtrudeMode = model.bodies.isEmpty ? .newBody : .union
        CommandOperation.row(cmd, ws, default: fallback)
        if !editing {
            Button {
                cmd.autoOperation.toggle()
                if cmd.autoOperation {
                    cmd.choices["auto1"] = nil
                    cmd.choices["auto-1"] = nil
                }
                ws.refreshCommandPreview()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: cmd.autoOperation ? "wand.and.stars" : "wand.and.stars.inverse")
                    Text(cmd.autoOperation ? "Automatisch: hinein schneidet, daneben verbindet" : "Von Hand gewählt · Automatik ein")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .font(.caption)
                .foregroundStyle(cmd.autoOperation ? SketchTheme.accent : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var optionRows: some View {
        let thin = cmd.flag("thin")
        CheckRow(title: "Dünn extrudieren", isOn: commandFlag("thin", cmd, ws))
        CheckRow(title: "Richtung umkehren", isOn: commandFlag("flip", cmd, ws))
        if model.selectedRegionsHaveHoles || cmd.flag("throughHoles") {
            // ★ PencilCAD: innere Konturen aussparen oder durchgehend extrudieren
            PanelSegmentRow(title: "Innere Konturen",
                            options: [SegmentOption(id: "0", label: "Aussparen"), SegmentOption(id: "1", label: "Durchgehend")],
                            selected: cmd.flag("throughHoles") ? "1" : "0") { id in
                cmd.flags["throughHoles"] = id == "1"
                ws.refreshCommandPreview()
            }
        }
        if thin {
            let wall = cmd.choice("thinSide", default: ThinSide.inside.rawValue)
            PanelSegmentRow(title: "Wandlage", options: Self.wallOptions, selected: wall) { id in
                cmd.choices["thinSide"] = id
                ws.refreshCommandPreview()
            }
            value(wall == ExtrudeCommand.bothSides ? "Stärke innen" : "Wandstärke", Key.thickness, default: 2)
            if wall == ExtrudeCommand.bothSides {
                value("Stärke außen", Key.thickness2, default: 1)
            }
        }
    }

    @ViewBuilder private func advancedRows(_ direction: ExtrudeDirection) -> some View {
        let start = cmd.choice("start", default: "profile")
        PanelSegmentRow(title: "Start", options: Self.startOptions, selected: start) { id in
            cmd.choices["start"] = id
            ExtrudeCommand.syncInputs(cmd)
            ws.refreshCommandPreview()
        }
        if start == "offset" {
            value("Versatz", Key.startOffset, default: 5)
        }
        if direction == .oneSide, !cmd.flag("thin") {
            value("Verjüngung", Key.taper, unit: "°", default: 0)
        }
    }

    private func value(_ title: String, _ key: String, unit: String = "mm", default fallback: Double) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, unit: unit, value: cmd.number(key, default: fallback)) { newValue in
            cmd.setNumber(key, newValue)
            ws.refreshCommandPreview()
        }
    }
}
