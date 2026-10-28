import Foundation
import simd

// Wiedergabe der Blechrezepte und Anbindung an den parametrischen Verlauf (FeatureHistory.swift).
//
// Jeder Blechschritt wird ein Feature „Blech …“ (FeatureKind.sheetMetal). Das Feature speichert nur seine eigenen
// Schritte; beim Nachbau nimmt es das Rezept des Körpers aus dem Stand davor (bzw. eine gespeicherte Kopie) und hängt
// seine Schritte an. So wirken Änderungen an einem frühen Schritt (Wert in der Zeitleiste, Blechregel) auf alle
// späteren. Zahlenwerte der Schritte erscheinen als Feature-Parameter „<Schritt>.<Schlüssel>“ und lassen sich wie
// bei jedem anderen Feature ändern (auch mit Formeln).

/// Blechdaten eines Features (FeatureData.sheet).
struct SheetFeatureData: Codable {
    /// Art: „create“ (neuer Körper aus Skizze), „append“ (Schritt am Körper data.target), „convert“ (Körper
    /// data.target wird Blech), „copy“ (neuer Körper als Kopie von data.target), „replace“ (data.target durch sein
    /// Spiegelbild ersetzt)
    var mode: String
    /// Eigene Schritte dieses Features
    var steps: [SheetStep]
    /// Rezept des Körpers vor dem Schritt (Rückfall, wenn der Stand davor keine Blechdaten trägt)
    var base: SheetBodyInfo?
    /// Neuer Körper: Name im Browser
    var bodyName: String?
    /// Name des Körpers in der Sitzung nach dem Schritt (Alias wie „$copy1“ oder fester Name)
    var kernelBody: String?
    var rule: String?
    /// Umwandeln: Datei des Ausgangskörpers (sheet/<Datei>)
    var sourceFile: String?
    /// Neuer Körper aus Skizze: deren ID (Gruppierung im Browser)
    var sketchID: UUID?
}

/// Ergebnis einer Wiedergabe.
struct SheetReplayResult {
    var shape: PCKShape
    var kernel: SheetKernel
    /// Tatsächlicher Name des Körpers in der Sitzung
    var bodyName: String
    var warnings: [String]
}

/// Ein berechneter Blechschritt, bereit zum Übernehmen bzw. als Vorschau.
struct SheetPlan {
    var bodies: [SceneBody]
    var feature: Feature
    var name: String
    var warnings: [String] = []
}

// MARK: - Wiedergabe

extension SheetStep {
    /// Schritt mit Alias: nach dem Ausführen heißt der erzeugte bzw. geänderte Körper so (z. B. „$src“)
    init(_ title: String, _ command: SheetCommand, alias: String?) {
        self.init(title, command)
        self.alias = alias
    }
}

extension ModelStore {
    /// Rezept in einer frischen Sitzung wiedergeben; directory = Ordner der Ausgangskörper (sheet/).
    nonisolated static func sheetReplay(_ info: SheetBodyInfo, directory: URL) throws -> SheetReplayResult {
        let kernel = try SheetKernel()
        var aliases: [String: String] = [:]
        var warnings: [String] = []
        // Entfaltet: Mitte des gefalteten Teils vor dem letzten Entfalten (Ablage an derselben Stelle, Punkt 11)
        let lastUnfold = info.isUnfolded ? info.steps.lastIndex(where: { $0.command.command == "sheet.unfold" }) : nil
        var foldedCenter: SIMD2<Double>?
        // Verschiebungen des entfalteten Teils (solid.move nach dem Entfalten) kommen auf die Ablage obendrauf
        var movedAfterUnfold = SIMD3<Double>(0, 0, 0)
        for (index, step) in info.steps.enumerated() {
            let command = sheetResolved(step.command, aliases: aliases, info: info, directory: directory)
            if index == lastUnfold {
                let folded = command.params["body"]?.asString ?? aliases[info.kernelBody] ?? info.kernelBody
                if let box = (try? kernel.shape(of: folded))?.boundingBox?.map(\.doubleValue), box.count == 6 {
                    foldedCenter = SIMD2((box[0] + box[3]) / 2, (box[1] + box[4]) / 2)
                }
            }
            if let lastUnfold, index > lastUnfold, step.command.command == "solid.move",
               step.command.params["copy"]?.asBool != true, let moved = step.command.params["translate"]?.asPoint3 {
                movedAfterUnfold += moved
            }
            let result: SheetJSON
            do {
                result = try kernel.execute(command)
            } catch {
                throw SheetKernelError("„\(step.title)“: \(error.localizedDescription)", index: index)
            }
            if let alias = step.alias {
                let created = result["created_bodies"]?[0]?.asString ?? result["changed_bodies"]?[0]?.asString
                    ?? result["bodies"]?[0]?.asString
                guard let created else { throw SheetKernelError("„\(step.title)“ hat keinen Körper erzeugt.", index: index) }
                aliases[alias] = created
            }
            if let warning = result["warning"]?.asString, !warning.isEmpty {
                warnings.append("\(step.title): \(warning)")
            }
        }
        let name = aliases[info.kernelBody] ?? info.kernelBody
        var shape = try kernel.shape(of: name)
        if info.isUnfolded { shape = sheetLaidFlat(shape, center: foldedCenter, lift: movedAfterUnfold) }
        return SheetReplayResult(shape: shape, kernel: kernel, bodyName: name, warnings: warnings)
    }

    /// Entfalteter Körper flach auf die Grundebene (Punkt 11, „beim Entfalten schwebt es“): SolidCraft lässt die
    /// feste Fläche beim Entfalten an ihrem Ort, das Flachteil schwebt dann in deren Höhe bzw. steht hochkant.
    /// Die größte ebene Fläche wird nach unten gedreht (Normale −Z, Z ist oben), die Unterseite liegt bei Z = 0 und
    /// die Mitte in X/Y auf center (Mitte des gefalteten Teils; nil = eigene Mitte bleibt). Nur die Anzeige wird
    /// gedreht/verschoben, die Sitzung behält ihre Lage (Flachmuster, DXF und Zurückfalten bleiben unverändert).
    /// lift = Verschiebung durch den Nutzer nach dem Entfalten (sonst spränge das Teil beim nächsten Schritt zurück).
    nonisolated static func sheetLaidFlat(_ shape: PCKShape, center: SIMD2<Double>?,
                                          lift: SIMD3<Double> = SIMD3(0, 0, 0)) -> PCKShape {
        // Größte ebene Fläche; bei gleich großen Gegenflächen (Ober-/Unterseite) die, die schon am meisten nach unten zeigt
        var faces: [(area: Double, normal: SIMD3<Double>)] = []
        if shape.faceCount > 0 {
            for face in 1...shape.faceCount {
                guard let plane = shape.plane(ofFace: face)?.map(\.doubleValue), plane.count == 6 else { continue }
                let normal = SIMD3(plane[3], plane[4], plane[5])
                guard simd_length(normal) > 1e-9 else { continue }
                faces.append((shape.area(ofFace: face), simd_normalize(normal)))
            }
        }
        var result = shape
        if let largest = faces.max(by: { $0.area < $1.area }) {
            let bottom = faces.filter { $0.area >= largest.area * 0.98 && abs(simd_dot($0.normal, largest.normal)) > 0.999 }
                .min(by: { $0.normal.z < $1.normal.z })?.normal ?? largest.normal
            let down = SIMD3<Double>(0, 0, -1)
            let cosine = max(-1, min(1, simd_dot(bottom, down)))
            if cosine < 1 - 1e-9, let box = result.boundingBox?.map(\.doubleValue), box.count == 6 {
                let middle = SIMD3((box[0] + box[3]) / 2, (box[1] + box[4]) / 2, (box[2] + box[5]) / 2)
                var axis = simd_cross(bottom, down)
                if simd_length(axis) < 1e-9 { axis = SIMD3(1, 0, 0) }    // zeigt genau nach oben: um X wenden
                if let turned = result.rotated(origin: middle, axis: simd_normalize(axis), angle: acos(cosine)) {
                    result = turned
                }
            }
        }
        guard let box = result.boundingBox?.map(\.doubleValue), box.count == 6 else { return result }
        let target = (center ?? SIMD2((box[0] + box[3]) / 2, (box[1] + box[4]) / 2)) + SIMD2(lift.x, lift.y)
        let offset = SIMD3(target.x - (box[0] + box[3]) / 2, target.y - (box[1] + box[4]) / 2, -box[2] + lift.z)
        guard simd_length(offset) > 1e-9 else { return result }
        return result.translated(by: offset) ?? result
    }

    /// Aliasse in body/bodies und die Quelldatei beim Import einsetzen.
    nonisolated static func sheetResolved(_ command: SheetCommand, aliases: [String: String], info: SheetBodyInfo,
                                          directory: URL) -> SheetCommand {
        var result = command
        if let body = command.params["body"]?.asString, let name = aliases[body] {
            result.params["body"] = .string(name)
        }
        if let list = command.params["bodies"]?.asArray {
            result.params["bodies"] = .array(list.map { item in
                if let text = item.asString, let name = aliases[text] { return .string(name) }
                return item
            })
        }
        if command.command == "psk.import_step", command.params["path"]?.asString == "$source", let file = info.sourceFile {
            result.params["path"] = .string(directory.appending(path: file).path(percentEncoded: false))
        }
        return result
    }

    /// Fingerabdruck eines Körpers: Hüllquader und Volumen (erkennt Änderungen außerhalb des Blechmoduls).
    nonisolated static func sheetFingerprint(_ shape: PCKShape) -> [Double]? {
        guard let box = shape.boundingBox?.map(\.doubleValue), box.count == 6 else { return nil }
        return box + [shape.volume]
    }

    /// Sitzung mit wiedergegebenem Rezept des Körpers (zwischengespeichert, solange sich das Rezept nicht ändert).
    func sheetSession(_ body: Int) throws -> (kernel: SheetKernel, name: String) {
        if let reason = sheetUnavailableReason { throw SheetKernelError(reason) }
        guard let info = sheetInfo(body) else { throw SheetKernelError("Kein Blechkörper gewählt.") }
        let document = sheetDocument
        let key = Self.sheetCacheKey(info)
        if let cached = document.sessionCache, cached.key == key {
            return (cached.kernel, cached.name)
        }
        let directory = document.storageDirectory
        let result = try SheetWorker.run { try Self.sheetReplay(info, directory: directory) }
        document.sessionCache = (key, result.kernel, result.bodyName)
        return (result.kernel, result.bodyName)
    }

    /// Schlüssel des Sitzungs-Zwischenspeichers (Rezept, Quelldatei, Körpername).
    static func sheetCacheKey(_ info: SheetBodyInfo) -> Int {
        var hasher = Hasher()
        hasher.combine(info.steps)
        hasher.combine(info.sourceFile)
        hasher.combine(info.kernelBody)
        return hasher.finalize()
    }

    // MARK: Ausführen

    /// Plan berechnen und übernehmen bzw. als Vorschau zeigen; Fehler als Meldung.
    func sheetRun(preview: Bool, _ make: () throws -> SheetPlan) -> Bool {
        let document = sheetDocument
        if document.previewing, hasPreview {
            dropPreview()
        } else {
            commitPreview()
        }
        document.previewing = false
        document.lastError = nil
        document.lastWarning = nil
        if let reason = sheetUnavailableReason {
            document.lastError = reason
            message = reason
            return false
        }
        let plan: SheetPlan
        do {
            plan = try make()
        } catch {
            let text = error.localizedDescription
            document.lastError = text
            message = text
            return false
        }
        if preview {
            showPreview(plan.bodies, name: plan.name)
            featureRecorder.preview = PendingFeature(feature: plan.feature)
            document.previewing = true
        } else {
            featureRecorder.pending = PendingFeature(feature: plan.feature)
            commit(plan.bodies, name: plan.name)
        }
        if !plan.warnings.isEmpty {
            let text = plan.warnings.joined(separator: " · ")
            message = text
            document.lastWarning = text
        }
        return true
    }

    /// Feature für einen Blechschritt (Name, Parameter aus den Zahlenwerten der Schritte).
    static func sheetFeature(_ name: String, data: SheetFeatureData, target: Int?) -> Feature {
        var feature = Feature(name: name, kind: .sheetMetal)
        feature.data.sheet = data
        feature.data.target = target
        feature.parameters = sheetParameters(data.steps)
        return feature
    }

    /// Blechkörper aus einem Rezept (neu bzw. Kopie): Wiedergabe → SceneBody.
    func sheetBuild(_ info: SheetBodyInfo, base: SceneBody?, name: String) throws -> (body: SceneBody, warnings: [String]) {
        let directory = sheetDocument.storageDirectory
        let result = try SheetWorker.run { try Self.sheetReplay(info, directory: directory) }
        var stored = info
        stored.resultBox = Self.sheetFingerprint(result.shape)
        var body = base.map { $0.with(result.shape) } ?? newBody(result.shape, name: name)
        body.sheetMetal = stored
        // Sitzung behalten: Flachmuster und Exporte direkt danach ohne erneute Wiedergabe
        sheetDocument.sessionCache = (Self.sheetCacheKey(stored), result.kernel, result.bodyName)
        return (body, result.warnings)
    }

    /// Schritte an einen vorhandenen Blechkörper hängen.
    func sheetAppendPlan(_ steps: [SheetStep], to body: Int) throws -> SheetPlan {
        guard bodies.indices.contains(body), var info = bodies[body].sheetMetal else {
            throw SheetKernelError("Kein Blechkörper gewählt.")
        }
        let base = info
        var own = try sheetDriftSteps(body)
        own += steps.map { step in
            var step = step
            // Blechbefehle auf diesen Körper richten (Skizzen- und Regelbefehle kennen kein „body“)
            let name = step.command.command
            if name.hasPrefix("sheet."), name != "sheet.manage_rules", step.command.params["body"] == nil {
                step.command = step.command.targeting(info.kernelBody)
            }
            return step
        }
        info.steps += own
        let built = try sheetBuild(info, base: bodies[body], name: bodies[body].name)
        var result = bodies
        result[body] = built.body
        let title = steps.first?.title ?? "Blech"
        let data = SheetFeatureData(mode: "append", steps: own, base: base, kernelBody: info.kernelBody, rule: info.rule)
        return SheetPlan(bodies: result, feature: Self.sheetFeature("Blech: \(title)", data: data, target: body),
                         name: title, warnings: built.warnings)
    }

    /// Wurde der Körper außerhalb des Blechmoduls verschoben, kommt die Verschiebung als solid.move ins Rezept;
    /// andere Änderungen (Abrunden, Drehen …) lassen sich nicht übernehmen.
    func sheetDriftSteps(_ body: Int) throws -> [SheetStep] {
        guard let info = bodies[body].sheetMetal, let stored = info.resultBox, stored.count == 7,
              let now = Self.sheetFingerprint(bodies[body].shape) else { return [] }
        let tolerance = 1e-3 * max(1, abs(stored[3] - stored[0]) + abs(stored[4] - stored[1]) + abs(stored[5] - stored[2]))
        let delta = SIMD3(now[0] - stored[0], now[1] - stored[1], now[2] - stored[2])
        var sameSize = true
        for k in 0..<3 where abs((now[k + 3] - now[k]) - (stored[k + 3] - stored[k])) > tolerance { sameSize = false }
        let sameVolume = abs(now[6] - stored[6]) <= max(1e-6, abs(stored[6]) * 1e-4)
        guard sameSize, sameVolume else {
            throw SheetKernelError("„\(bodies[body].name)“ wurde außerhalb des Blechmoduls verändert (z. B. gedreht oder "
                + "abgerundet). Blechbefehle gehen nur am Blechstand – den Schritt rückgängig machen oder den Körper neu "
                + "„In Blech umwandeln“.")
        }
        guard simd_length(delta) > tolerance else { return [] }
        let move = SheetCommand("solid.move", ["bodies": [.string(info.kernelBody)], "translate": SheetJSON(delta)])
        return [SheetStep("Verschieben", move)]
    }

    /// Ist der Körper ein Blechkörper, der seit der letzten Wiedergabe anders verändert wurde als verschoben?
    func sheetBodyIsModified(_ body: Int) -> Bool {
        guard bodies.indices.contains(body), bodies[body].sheetMetal != nil else { return false }
        return (try? sheetDriftSteps(body)) == nil
    }

    /// Kopie bzw. Spiegelbild eines Blechkörpers (eigenes Rezept, eigenes Flachmuster).
    func sheetCopyPlan(_ body: Int, mirror: (origin: SIMD3<Double>, normal: SIMD3<Double>, keep: Bool)?,
                       offset: SIMD3<Double>) throws -> SheetPlan {
        guard bodies.indices.contains(body), var info = bodies[body].sheetMetal else {
            throw SheetKernelError("Kein Blechkörper gewählt.")
        }
        let base = info
        var own = try sheetDriftSteps(body)
        let alias = "$copy\(UUID().uuidString.prefix(8))"
        let step: SheetStep
        if let mirror {
            let n = simd_normalize(mirror.normal)
            let command = SheetCommand("solid.mirror", [
                "bodies": [.string(info.kernelBody)],
                "plane": ["origin": SheetJSON(mirror.origin), "normal": SheetJSON(n)],
            ])
            step = SheetStep("Spiegeln", command, alias: alias)
        } else {
            let command = SheetCommand("solid.move", [
                "bodies": [.string(info.kernelBody)], "translate": SheetJSON(offset), "copy": true,
            ])
            step = SheetStep("Kopieren", command, alias: alias)
        }
        own.append(step)
        info.steps += own
        info.kernelBody = alias
        var result = bodies
        let replace = mirror.map { !$0.keep } ?? false
        let built = try sheetBuild(info, base: replace ? bodies[body] : nil, name: bodies[body].name)
        var copy = built.body
        if !replace {
            copy.name = bodies[body].name + (mirror == nil ? " Kopie" : " gespiegelt")
            copy.color = bodies[body].color
            copy.material = bodies[body].material
            copy.folder = bodies[body].folder
            result.append(copy)
        } else {
            result[body] = copy
        }
        let data = SheetFeatureData(mode: replace ? "replace" : "copy", steps: own, base: base, bodyName: copy.name,
                                    kernelBody: alias, rule: info.rule)
        return SheetPlan(bodies: result, feature: Self.sheetFeature("Blech: \(step.title)", data: data, target: body),
                         name: step.title, warnings: built.warnings)
    }

    // MARK: Bearbeiten

    /// Schritt eines Rezepts ändern bzw. löschen: im Feature, das ihn angelegt hat, und ab dort nachbauen.
    func sheetEditStep(body: Int, step id: UUID, delete: Bool = false, _ change: (inout SheetStep) -> Void) -> Bool {
        commitPreview()
        guard let info = sheetInfo(body), let position = info.steps.firstIndex(where: { $0.id == id }) else {
            message = "Schritt nicht gefunden."
            return false
        }
        var list = features
        if let index = list.firstIndex(where: { feature in
            feature.kind == .sheetMetal && (feature.data.sheet?.steps.contains { $0.id == id } ?? false)
        }), var data = list[index].data.sheet, let k = data.steps.firstIndex(where: { $0.id == id }) {
            let title = data.steps[k].title
            // Werte aus der Zeitleiste (Feature-Parameter) gelten weiter
            data.steps = Self.sheetSteps(data.steps, parameters: list[index].parameters)
            if delete {
                if data.mode == "create" || data.mode == "convert" || data.steps[k].alias != nil {
                    message = "„\(title)“ erzeugt den Körper – stattdessen den Körper löschen."
                    return false
                }
                data.steps.remove(at: k)
            } else {
                change(&data.steps[k])
            }
            if data.steps.isEmpty {
                list.remove(at: index)
            } else {
                let old = list[index].parameters
                list[index].data.sheet = data
                list[index].parameters = Self.sheetParameters(data.steps, keeping: old)
            }
            replayFeatures(from: index, features: list, sketches: nil,
                           name: delete ? "„\(title)“ löschen" : "„\(title)“ ändern")
            return true
        }
        // Kein Feature (z. B. Verlauf zurückgesetzt): Rezept direkt ändern und als festen Stand übernehmen
        var changed = info
        if delete {
            guard position > 0 else { return false }
            changed.steps.remove(at: position)
        } else {
            change(&changed.steps[position])
        }
        do {
            let built = try sheetBuild(changed, base: bodies[body], name: bodies[body].name)
            var result = bodies
            result[body] = built.body
            commit(result, name: "Blech ändern")
            if !built.warnings.isEmpty { message = built.warnings.joined(separator: " · ") }
            return true
        } catch {
            message = error.localizedDescription
            sheetDocument.lastError = error.localizedDescription
            return false
        }
    }

    /// Geänderte Regel in alle Rezepte übernehmen, die sie verwenden, und nachbauen (ein Schritt).
    func sheetRebuildBodies(usingRule rule: SheetRule) {
        let replace = { (steps: inout [SheetStep]) -> Bool in
            var touched = false
            for k in steps.indices where steps[k].command.command == "sheet.manage_rules"
                && steps[k].command.params["name"]?.asString == rule.name {
                let active = steps[k].command.params["active"]?.asBool ?? true
                steps[k].command = rule.command(active: active)
                touched = true
            }
            return touched
        }
        commitPreview()
        var list = features
        var first: Int?
        for index in list.indices where list[index].kind == .sheetMetal {
            guard var data = list[index].data.sheet else { continue }
            var touched = replace(&data.steps)
            if var base = data.base, replace(&base.steps) {
                data.base = base
                touched = true
            }
            if touched {
                list[index].data.sheet = data
                first = first ?? index
            }
        }
        if let first, PCKShape.kernelAvailable {
            replayFeatures(from: first, features: list, sketches: nil, name: "Blechregel „\(rule.name)“ ändern")
            return
        }
        // Ohne passende Features: Körper direkt neu wiedergeben
        var result = bodies
        var touched = false
        var problems: [String] = []
        for index in result.indices {
            guard var info = result[index].sheetMetal, replace(&info.steps) else { continue }
            do {
                result[index] = try sheetBuild(info, base: result[index], name: result[index].name).body
                touched = true
            } catch {
                problems.append("\(result[index].name): \(error.localizedDescription)")
            }
        }
        if touched { commit(result, name: "Blechregel „\(rule.name)“ ändern") }
        if !problems.isEmpty { message = problems.joined(separator: " · ") }
    }

    // MARK: Nachbau im Verlauf

    /// Nachbau mit anderer Körperzahl (REVIEW 48, Aufruf aus carryingBodyDetails): Blechkörper über ihr Rezept (erster
    /// Schritt + Sitzungsname, Kopien unterscheiden sich im Alias) wiedererkennen und ihre Angaben übernehmen.
    func sheetCarryDetails(_ result: inout [SceneBody]) {
        func key(_ info: SheetBodyInfo) -> String? {
            info.steps.first.map { "\($0.id.uuidString)|\(info.kernelBody)" }
        }
        var previous: [String: SceneBody] = [:]
        for body in bodies {
            if let info = body.sheetMetal, let k = key(info) { previous[k] = body }
        }
        for index in result.indices {
            guard let info = result[index].sheetMetal, let k = key(info), let old = previous[k] else { continue }
            result[index].name = old.name
            result[index].color = old.color
            result[index].isHidden = old.isHidden
            result[index].folder = old.folder
            result[index].material = old.material
            result[index].finish = old.finish
            result[index].threads = old.threads
        }
    }

    /// Feature „Blech“ auf einen Stand anwenden (Aufruf aus applyFeature, FeatureHistory.swift).
    func replaySheetMetal(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let data = feature.data.sheet else { throw FeatureError("Blechdaten fehlen.") }
        guard SheetKernel.isAvailable else { throw FeatureError(SheetKernelError.notBuilt.message) }
        let steps = Self.sheetSteps(data.steps, parameters: feature.parameters)
        let directory = sheetDocument.storageDirectory
        var result = state
        switch data.mode {
        case "create":
            let info = SheetBodyInfo(steps: steps, kernelBody: data.kernelBody ?? "Blech", rule: data.rule ?? "")
            let shape = try Self.sheetReplayShape(info, directory: directory)
            var stored = info
            stored.resultBox = Self.sheetFingerprint(shape)
            let number = result.count
            var body = SceneBody(shape: shape, name: data.bodyName ?? "Blech \(number + 1)",
                                 color: SceneBody.defaultColor)
            body.sheetMetal = stored
            body.sketchID = data.sketchID
            result.append(body)
        case "convert":
            guard let target = feature.data.target, result.indices.contains(target), let file = data.sourceFile else {
                throw FeatureError("Ausgangskörper fehlt.")
            }
            // Ausgangskörper aus dem Stand davor (Änderungen davor wirken mit)
            let url = directory.appending(path: file)
            do {
                try sheetWriteSTEP(result[target].shape, to: url, limit: SheetWorker.replayLimit)
            } catch {
                throw FeatureError("Ausgangskörper ließ sich nicht speichern: \(error.localizedDescription)")
            }
            var info = SheetBodyInfo(steps: steps, kernelBody: data.kernelBody ?? "$sheet", rule: data.rule ?? "")
            info.sourceFile = file
            let shape = try Self.sheetReplayShape(info, directory: directory)
            info.resultBox = Self.sheetFingerprint(shape)
            result[target] = result[target].with(shape)
            result[target].sheetMetal = info
        default:
            guard let target = feature.data.target, result.indices.contains(target) else {
                throw FeatureError("Blechkörper fehlt.")
            }
            guard var info = result[target].sheetMetal ?? data.base else { throw FeatureError("Kein Blechkörper.") }
            info.steps += steps
            if data.mode != "append" { info.kernelBody = data.kernelBody ?? info.kernelBody }
            let shape = try Self.sheetReplayShape(info, directory: directory)
            info.resultBox = Self.sheetFingerprint(shape)
            if data.mode == "copy" {
                var copy = result[target].with(shape)
                copy.name = data.bodyName ?? copy.name
                copy.sheetMetal = info
                copy.componentID = nil
                copy.placement = matrix_identity_double4x4
                result.append(copy)
            } else {
                result[target] = result[target].with(shape)
                result[target].sheetMetal = info
            }
        }
        sheetDocument.sessionCache = nil
        return result
    }

    nonisolated private static func sheetReplayShape(_ info: SheetBodyInfo, directory: URL) throws -> PCKShape {
        do {
            // Nachbau des Verlaufs: großzügiges Zeitlimit (REVIEW 44)
            return try SheetWorker.run(limit: SheetWorker.replayLimit) { try Self.sheetReplay(info, directory: directory).shape }
        } catch {
            throw FeatureError(error.localizedDescription)
        }
    }

    // MARK: Parameter ↔ Schritte

    /// Zahlenwerte, die als Feature-Parameter erscheinen (Schlüssel, Titel, Winkel?).
    private static let sheetParameterKeys: [(key: String, title: String, angle: Bool)] = [
        ("height", "Höhe", false), ("angle", "Winkel", true), ("radius", "Biegeradius", false),
        ("length", "Länge", false), ("gap", "Spalt", false), ("distance", "Breite", false),
        ("diameter", "Durchmesser", false), ("pitch", "Teilung", false), ("margin", "Rand", false),
        ("corner_relief", "Eckfreischnitt", false), ("thickness", "Blechstärke", false),
        ("bend_radius", "Biegeradius (Regel)", false),
    ]

    /// Zahl bzw. „<Zahl> deg“/„<Zahl> mm“ lesen.
    static func sheetNumber(_ value: SheetJSON?) -> Double? {
        guard let value else { return nil }
        if let number = value.asDouble { return number }
        guard var text = value.asString?.trimmingCharacters(in: .whitespaces) else { return nil }
        for unit in ["deg", "mm", "°"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        return Double(text)
    }

    /// Feature-Parameter aus den Zahlenwerten der Schritte (Skizzen und Ausgangskörper ausgenommen).
    static func sheetParameters(_ steps: [SheetStep], keeping old: [FeatureParameter] = []) -> [FeatureParameter] {
        var result: [FeatureParameter] = []
        for (index, step) in steps.enumerated() {
            let name = step.command.command
            guard name.hasPrefix("sheet.") else { continue }
            let prefix = steps.count > 1 ? "\(step.title) · " : ""
            for entry in sheetParameterKeys {
                guard let value = sheetNumber(step.command.params[entry.key]) else { continue }
                let key = "\(index).\(entry.key)"
                var parameter = entry.angle ? FeatureParameter.angle(key, prefix + entry.title, value)
                    : FeatureParameter.length(key, prefix + entry.title, value)
                if let previous = old.first(where: { $0.key == key }), abs(previous.value - value) < 1e-9 {
                    parameter.formula = previous.formula
                }
                result.append(parameter)
            }
        }
        return result
    }

    /// Schritte mit den (evtl. geänderten) Feature-Parametern.
    static func sheetSteps(_ steps: [SheetStep], parameters: [FeatureParameter]) -> [SheetStep] {
        var result = steps
        for parameter in parameters {
            let parts = parameter.key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]), result.indices.contains(index),
                  result[index].command.params[parts[1]] != nil else { continue }
            let value: SheetJSON = parameter.unit == .angle ? SheetCommand.degrees(parameter.value) : .number(parameter.value)
            result[index].command.params[parts[1]] = value
        }
        return result
    }
}
