import Foundation
import simd

// Abrunden/Fasen im Hintergrund (Kai: „variable Abrundung – jetzt ist mir das Programm eingefroren“).
//
// Ursache: setEdgeValue rief BRepFilletAPI_MakeFillet synchron auf dem Main-Thread auf, bei jedem Wert (Pfeil-Frame,
// Eintippen, „Variabel“ ein, Endradius) – und EdgeBlendCommand.refresh rechnete beim Ändern des Endradius sogar
// zweimal. Läuft eine variable Rundung in eine schon verrundete Nachbarkante (Eckübergang auf eine B-Spline-
// Rundungsfläche), rechnet OCCT dort Minuten oder kehrt nie zurück; OCCT 7.7 kann eine Rundung nicht abbrechen
// (BRepFilletAPI_MakeFillet::Build ignoriert Message_ProgressRange).
//
// Jetzt:
// - Gemerkt: Ergebnisse und Fehlschläge je Körper, Kanten, Werten und Verlauf – derselbe Wert rechnet nie zweimal.
// - Hintergrund: eigener Thread mit großem Stapel, an einer unabhängigen Kopie des Körpers (PCKShape.independentCopy;
//   Vernetzen im Vordergrund schreibt sonst in dieselben OCCT-Flächen/Kanten). Der eigentliche Fillet-Aufruf läuft
//   ab iPadOS 26 in einer Extension als separatem Prozess. Es rechnet immer höchstens eine
//   Rundung; neue Werte warten (nur der neueste), alte Ergebnisse werden verworfen (generation).
// - Zeitlimit 8 s: Meldung „zu aufwendig“, Vorschau verworfen, Werte als Fehlschlag gemerkt.
//   Ein hängender Worker kann vom System noch weiterlaufen; bis zur Rückkehr startet nichts Neues.
// - Ineinanderlaufende Rundungen (BlendBeforeCuts.swift blendMerge): mit der vorigen Rundung in EINEM Abrunden.
// - Variable Rundung: Radien ≥ 0,01 mm, Anfang = Ende → gleichbleibende Rundung.
// - Rundung und Fase rechnen nur den verlangten Wert. Eine zusätzliche Maximalwertsuche nach einem Fehlschlag
//   stürzte bei einer komplexen Form im OCCT-Fillet-Kernel ab (iPad-Bericht vom 30.10.2026, 22:55:52).
//   Auch ein direkter Versuch stürzte in Build 12 ab (23:07:14). Scheitert der isolierte Wert,
//   bleibt der Körper unverändert und „Fertig“ übernimmt nichts.

/// Ergebnis einer Rundung bzw. Fase aus dem Hintergrund.
struct BlendJobResult {
    /// Neuer Körper; nil = nicht möglich
    var shape: PCKShape?
    /// Der vom Nutzer angeforderte Wert; es erfolgt kein automatisches Klemmen.
    var amount: Double
    /// Mit der vorigen Rundung zusammengefasst
    var merged = false
    /// Zeitlimit überschritten (Host-Zeitlimit oder Worker-Zeitlimit; nur dieser Wert ist gesperrt)
    var timedOut = false
    /// Worker-Prozess abgebrochen bzw. Auswahl nach einem früheren Abbruch gesperrt
    var crashed = false
    /// Zusammenfassen mit der letzten Rundung gescheitert; bewusst kein Rückfall auf eine Rundung auf der schon
    /// gerundeten Fläche (Schwacher Bugfix 3)
    var mergeFailed = false
    /// Diagnose nach einem Fehlschlag mit mehreren Kanten: Kanten, die OCCT gar nicht annimmt (nil = noch unbekannt)
    var unblendable: [Int]? = nil
    /// Build 42: Rundung mit Optionen (Setback/G2 …) vom Worker abgelehnt – kein stiller Rückfall auf Standard
    var optionsFailed = false
}

/// Eingaben für den Hintergrund: nur Kopien und Zahlen, nichts aus dem Vordergrund.
struct BlendJobInput {
    var operation: EdgeOperation
    /// Unabhängige Kopie des Körpers
    var shape: PCKShape
    var edges: [NSNumber]
    var value: Double
    var second: Double?
    var end: Double?
    var partialRange: ClosedRange<Double>?
    /// Gemeinsam mit der vorigen Rundung: Körper vor ihr (Kopie) und alle Kanten
    var mergeShape: PCKShape?
    var mergeEdges: [NSNumber] = []
    var mergeRadii: [Double]? = nil
    /// Build 42: normalisierte Rundungsoptionen (nil = Standard); nur bei konstanter Rundung
    var options: BlendOptions? = nil
}

struct BlendJobKey: Equatable {
    var edges: [EdgeRef]
    var operation: EdgeOperation
    var value: Double
    var second: Double?
    var end: Double?
    var partialRange: ClosedRange<Double>?
    var featureIDs: [UUID]
    /// Build 42: normalisierte Rundungsoptionen (nil = Standard); requestBlend setzt sie ausdrücklich.
    var options: BlendOptions?
}

/// Eine Anfrage (Vorschau für einen Wert).
struct BlendJobRequest {
    var key: BlendJobKey
    var generation: Int
    var body: Int
    /// Körper beim Start (nur zum Prüfen beim Zurückkommen; gerechnet wird an input.shape)
    var source: PCKShape
    var selection: [EdgeRef]
    var blendEdges: [EdgeRef]
    var input: BlendJobInput
    /// Zusammengefasste Rundung (ersetzt features[mergeIndex])
    var mergeFeature: Feature?
    var mergeIndex: Int?
}

/// Zustand der Hintergrund-Rundung (ModelStore.blendJobs, nicht veröffentlicht).
final class BlendJobs {
    /// Zählt jede neue Anfrage; ältere Ergebnisse werden verworfen
    var generation = 0
    /// Laufende Anfrage (auch nach dem Zeitlimit, bis OCCT zurückkehrt)
    var current: BlendJobRequest?
    var jobNumber = 0
    /// Die laufende Anfrage hat das Zeitlimit überschritten (ihr Ergebnis wird ignoriert)
    var overdue = false
    /// Nächste Anfrage (nur die neueste); startet, sobald die laufende zurück ist
    var queued: BlendJobRequest?
    /// Ergebnisse je Anfrage (auch Fehlschläge), die neuesten hinten
    var memo: [(key: BlendJobKey, source: PCKShape, result: BlendJobResult)] = []
    /// Entprellen „Rundung vor Schnitt“ (BlendBeforeCuts.swift)
    var orderedToken = 0
    /// Nach jedem angekommenen Ergebnis (offenes Abrunden-/Fasen-Panel aktualisieren)
    var finished: (() -> Void)?
    let queue = DispatchQueue(label: "PencilCAD.blend", qos: .userInitiated)

    var running: Bool { current != nil }

    /// Build 42: dasselbe Limit wie der Worker (nicht doppelt pflegen)
    static let timeLimit: TimeInterval = IsolatedBlend.workerTimeout
    static let memoLimit = 24
}

/// Rechnen im Hintergrund (nur Kernel-Aufrufe an Kopien, kein Zugriff auf den ModelStore).
enum BlendKernel {
    /// Genau EIN Worker-Lauf je Anfrage: so bleibt isBlendComputing höchstens BlendJobs.timeLimit gesetzt
    /// (früher Merge + Rückfall = zwei Läufe mit je 8 s gegen ein Zeitlimit von 8 s).
    static func run(_ input: BlendJobInput) -> BlendJobResult {
        let value = input.value
        // Build 42: Optionen gelten nur für Rundungen; Fase ignoriert sie (hat keine)
        let options = input.operation == .fillet ? input.options?.normalized : nil
        func result(_ done: (shape: PCKShape?, outcome: IsolatedBlend.Outcome), merged: Bool = false,
                    mergeAttempt: Bool = false) -> BlendJobResult {
            var out = BlendJobResult(shape: done.shape, amount: value, merged: merged && done.shape != nil)
            out.timedOut = done.shape == nil && done.outcome == .timedOut
            out.crashed = done.shape == nil && done.outcome == .crashed
            // Nur ein echter Fehlschlag der gemeinsamen Rundung; Absturz/Zeitlimit haben eigene Meldungen
            out.mergeFailed = mergeAttempt && done.shape == nil && done.outcome == .answered
            out.optionsFailed = options != nil && done.shape == nil && done.outcome == .answered
            return out
        }
        if let options {
            // Setback/G2 nur bei konstanter Rundung: Teil/variabel mit Optionen startet nicht (kein Rückfall)
            guard input.partialRange == nil, input.end == nil, options.isValid else {
                return BlendJobResult(shape: nil, amount: value)
            }
        }
        if input.operation == .fillet, let range = input.partialRange {
            guard input.edges.count == 1 else { return BlendJobResult(shape: nil, amount: value) }
            return result(IsolatedBlend.runReporting(shape: input.shape, edges: input.edges, mode: 2, value: value,
                                                     start: range.lowerBound, stop: range.upperBound))
        }
        if input.operation == .fillet, let mergeShape = input.mergeShape, !input.mergeEdges.isEmpty {
            // Schwacher Bugfix 3: Grenzt die Auswahl an die letzte Rundung, gilt wie beim Merge mit einer früheren
            // Rundung (BlendBeforeCuts.previewMergedBlend) „keine direkte Teilrundung als Ersatz“. Scheitert die
            // gemeinsame Rundung, wird NICHT auf den direkten Fillet auf der schon gerundeten Fläche ausgewichen
            // (lief am Tangentenbogen der ersten Rundung weiter: Artefakte, Kais Fall). Ergebnis nil, Meldung in
            // applyBlendResult.
            let attempt: (shape: PCKShape?, outcome: IsolatedBlend.Outcome)
            if let radii = input.mergeRadii {
                attempt = IsolatedBlend.runReporting(shape: mergeShape, edges: input.mergeEdges, mode: 5,
                                                 value: value, radii: radii, options: options)
            } else if let end = input.end {
                attempt = IsolatedBlend.runReporting(shape: mergeShape, edges: input.mergeEdges, mode: 3,
                                                 value: value, second: end)
            } else {
                attempt = IsolatedBlend.runReporting(shape: mergeShape, edges: input.mergeEdges, mode: 0,
                                                     value: value, options: options)
            }
            return result(attempt, merged: true, mergeAttempt: true)
        }
        let shape = input.shape
        let numbers = input.edges
        if input.operation == .fillet, let end = input.end {
            return result(IsolatedBlend.runReporting(shape: shape, edges: numbers, mode: 3, value: value, second: end))
        }
        if input.operation == .chamfer, let second = input.second {
            return result(IsolatedBlend.runReporting(shape: shape, edges: numbers, mode: 4, value: value,
                                                     second: second))
        }
        let chamfer = input.operation == .chamfer
        return result(IsolatedBlend.runReporting(shape: shape, edges: numbers, mode: chamfer ? 1 : 0, value: value,
                                                 options: options))
    }

    /// Meldung aus der Diagnose (IsolatedBlend.unblendableEdges); nil, wenn keine Kante auffällt.
    static func unblendableMessage(_ edges: [Int], chamfer: Bool) -> String? {
        guard !edges.isEmpty else { return nil }
        let verb = chamfer ? "gefast" : "abgerundet"
        if edges.count == 1 {
            return "Kante \(edges[0]) ist eine Naht- oder tangentiale Kante und kann nicht \(verb) werden – "
                + "aus der Auswahl entfernen."
        }
        let list = edges.map(String.init).joined(separator: ", ")
        return "Kanten \(list) sind Naht- oder tangentiale Kanten und können nicht \(verb) werden – "
            + "aus der Auswahl entfernen."
    }
}

/// Sucht auf ausdrücklichen Wunsch den größten geprüften Radius einer Einzelkante.
/// Jeder Versuch läuft im isolierten Kernelprozess; ein Absturz beendet die Suche. Ein Zeitlimit sperrt seit
/// Build 41 nur diesen einen Radius (IsolatedBlend.ValueKey) und zählt hier als „geht nicht“ – die Suche läuft weiter.
enum BlendMaximumSearch {
    static func find(shape: PCKShape, edge: Int, ceiling: Double) -> Double? {
        guard edge > 0, ceiling.isFinite, ceiling >= 0.01 else { return nil }
        let selection = [NSNumber(value: edge)]
        func works(_ radius: Double) -> Bool {
            IsolatedBlend.run(shape: shape, edges: selection, mode: 0, value: radius) != nil
        }
        let seed = min(0.1, ceiling)
        guard works(seed) else { return nil }
        if ceiling <= seed { return seed }
        let upperWorks = works(ceiling)
        if IsolatedBlend.wasBlocked(shape: shape, edges: selection, mode: 0) { return nil }
        if upperWorks { return ceiling }
        var lower = seed
        var upper = ceiling
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for _ in 0..<12 where upper - lower > 0.01 {
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            let middle = (lower + upper) / 2
            if works(middle) { lower = middle } else { upper = middle }
            if IsolatedBlend.wasBlocked(shape: shape, edges: selection, mode: 0) { return nil }
        }
        return lower
    }
}

extension ModelStore {
    static let blendTooHeavyMessage = "Rundung zu aufwendig bzw. nicht möglich – Radius verkleinern."
    /// Schwacher Bugfix 6: ein Zeitlimit ist kein Absturz – nur dieser Wert ist gesperrt
    static let blendTimeLimitMessage = "Zeitlimit überschritten – diese Rundung bzw. Fase ist zu aufwendig. "
        + "Anderen Wert versuchen oder weniger Kanten wählen."

    /// Sucht auf Wunsch eine gültige Geometriegrenze. Kein weiterer OCCT-Aufruf beim normalen Ziehen.
    @MainActor
    func searchLargestFillet(_ apply: @escaping @MainActor (Double) -> Void) {
        guard edgeOperation == .fillet, edgeEndValue == nil, edgePartialRange == nil,
              selectedEdges.count == 1, let selected = selectedEdges.first,
              bodies.indices.contains(selected.body), !isBlendComputing, !isBlendMaximumComputing else {
            message = "Maximalradius: eine Kante und eine konstante Rundung wählen; laufende Vorschau abwarten."
            return
        }
        // Build 42: die Suche prüft nur die Standard-Rundung (Rolling Ball, G1) – mit Optionen wäre ihr Ergebnis falsch
        guard effectiveBlendOptions == nil else {
            message = Self.blendMaximumNeedsStandardMessage
            return
        }
        let source = bodies[selected.body].shape
        guard let copy = source.independentCopy(), copy !== source else {
            message = "Körper für die Radiusprüfung nicht kopierbar."
            return
        }
        let box = source.boundingBox?.map(\.doubleValue) ?? []
        let diagonal = box.count == 6
            ? simd_length(SIMD3<Double>(box[3] - box[0], box[4] - box[1], box[5] - box[2])) : 10
        let ceiling = min(max(edgeValue, diagonal, 0.1), 10_000)
        let generation = blendJobs.generation
        isBlendMaximumComputing = true
        message = "Größten gültigen Radius prüfen …"
        let input = UncheckedBox((copy, selected.edge, ceiling))
        KernelThread.start("PencilCAD.blend.maximum") { [weak self] in
            let value = BlendMaximumSearch.find(shape: input.value.0, edge: input.value.1, ceiling: input.value.2)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBlendMaximumComputing = false
                guard self.blendJobs.generation == generation,
                      self.selectedEdges == [selected], self.bodies.indices.contains(selected.body),
                      self.bodies[selected.body].shape === source else { return }
                guard let value else {
                    self.message = "Kein gültiger Radius gefunden; Kante oder Geometrie prüfen."
                    return
                }
                self.message = "Größter geprüfter Radius: \(value.formatted(.number.precision(.fractionLength(2)))) mm."
                apply(value)
            }
        }
    }

    /// setEdgeValue: neue Anfrage – noch laufende bzw. wartende Ergebnisse gelten nicht mehr.
    func beginBlendRequest() {
        blendJobs.generation += 1
        blendJobs.queued = nil
        blendJobs.orderedToken += 1
        if isBlendComputing { isBlendComputing = false }
    }

    /// Ein anderes Ergebnis (Rundung vor Schnitt) hat Vorrang: Hintergrund-Ergebnis verwerfen.
    func supersedeBlendJobs() {
        blendJobs.generation += 1
        blendJobs.queued = nil
        if isBlendComputing { isBlendComputing = false }
    }

    /// Auswahl aufgehoben bzw. Vorschau abgebrochen: nichts mehr zeigen, was noch rechnet.
    func cancelBlendJobs() {
        supersedeBlendJobs()
        blendJobs.orderedToken += 1
    }

    /// Rundung bzw. Fase der gewählten Kanten rechnen (gemerkt sofort, sonst im Hintergrund).
    func requestBlend(body: Int, value requested: Double, blendEdges: [EdgeRef]) {
        guard requested.isFinite, edgeSecondValue?.isFinite ?? true, edgeEndValue?.isFinite ?? true else {
            message = "Radius und Abstände müssen endliche Zahlen sein."
            dropPreview()
            return
        }
        let operation = edgeOperation
        let second: Double? = operation == .chamfer ? edgeSecondValue : nil
        var end: Double? = operation == .fillet ? edgeEndValue : nil
        var value = requested
        if let given = end {
            // Variable Rundung: Radien ab 0,01 mm; Anfang = Ende ist eine gleichbleibende Rundung
            value = max(0.01, value)
            let clamped = max(0.01, given)
            end = abs(clamped - value) < 1e-6 ? nil : clamped
        }
        let shape = bodies[body].shape
        let partialRange = operation == .fillet ? edgePartialRange : nil
        // Build 42: Rundungsoptionen (nil = Standard, Fase: immer nil)
        let options = effectiveBlendOptions
        let key = BlendJobKey(edges: blendEdges, operation: operation, value: value, second: second, end: end,
                              partialRange: partialRange,
                              featureIDs: features.map(\.id), options: options)
        let numbers = blendEdges.filter { $0.body == body }.map { NSNumber(value: $0.edge) }
        // Eine frühere Rundung braucht zuerst einen vollständigen Nachbau des Verlaufs.
        // Nur die unmittelbar letzte Rundung darf hier direkt ersetzt werden.
        let merge = operation == .fillet && partialRange == nil
            ? blendMerge(body: body, value: value, end: end).flatMap { $0.index == features.count - 1 ? $0 : nil }
            : nil
        let input = BlendJobInput(operation: operation, shape: shape, edges: numbers, value: value, second: second,
                                  end: end, partialRange: partialRange, mergeShape: merge?.shape,
                                  mergeEdges: (merge?.edges ?? []).map { NSNumber(value: $0) },
                                  mergeRadii: merge?.radii, options: options)
        let request = BlendJobRequest(key: key, generation: blendJobs.generation, body: body, source: shape,
                                      selection: selectedEdges, blendEdges: blendEdges, input: input,
                                      mergeFeature: merge?.feature, mergeIndex: merge?.index)
        // Schon gerechnet (auch Fehlschlag bzw. Zeitlimit): sofort
        if let known = blendJobs.memo.last(where: { $0.key == key && $0.source === shape }) {
            applyBlendResult(known.result, request: request)
            return
        }
        // Build 49 (Kai: „wenn ich so weit runter abrunde … sehr am Ruckeln“): Über einem schon gescheiterten Radius
        // scheitert auch jeder größere – nicht neu rechnen (jeder Fehlversuch dauerte Sekunden und ließ die Vorschau
        // springen), sondern sofort den größten gelungenen Radius darunter zeigen.
        if let limited = knownBlendLimit(key: key, shape: shape, request: request) {
            applyBlendResult(limited, request: request)
            return
        }
        // Läuft schon dieselbe Rechnung: übernehmen statt noch einmal
        if let current = blendJobs.current, current.key == key, current.source === shape {
            if blendJobs.overdue {
                message = Self.blendTooHeavyMessage
                dropPreview()
                return
            }
            blendJobs.current?.generation = blendJobs.generation
            isBlendComputing = true
            return
        }
        isBlendComputing = true
        if blendJobs.running {
            // Nicht parallel stapeln: wartet, bis die laufende Rundung zurück ist (nur die neueste)
            blendJobs.queued = request
            if blendJobs.overdue {
                message = "Die vorige Rundung rechnet noch (zu aufwendig) – der neue Wert folgt, sobald sie fertig ist."
            }
            return
        }
        startBlendJob(request)
    }

    /// Build 49: Ergebnis aus dem Gedächtnis, wenn der verlangte Radius über einem schon gescheiterten liegt –
    /// der größte gelungene Radius darunter (Vorschau bleibt stehen) bzw. der Fehlschlag. nil = rechnen.
    /// Nur konstante Standard-Rundung ohne Zusammenfassen (dort gilt „größer scheitert auch“ verlässlich).
    private func knownBlendLimit(key: BlendJobKey, shape: PCKShape, request: BlendJobRequest) -> BlendJobResult? {
        guard key.operation == .fillet, key.end == nil, key.partialRange == nil, key.options == nil,
              request.mergeFeature == nil else { return nil }
        let entries = blendJobs.memo.filter { entry in
            entry.source === shape && entry.key.edges == key.edges && entry.key.operation == key.operation
                && entry.key.end == nil && entry.key.partialRange == nil && entry.key.options == nil
                && entry.key.featureIDs == key.featureIDs
        }
        let failures = entries.filter { entry in
            let r = entry.result
            return r.shape == nil && !r.timedOut && !r.crashed && !r.mergeFailed && !r.optionsFailed
        }
        guard let limit = failures.map({ $0.key.value }).filter({ $0 <= key.value }).min() else { return nil }
        let best = entries.filter { $0.result.shape != nil && !$0.result.merged && $0.key.value < limit }
            .max { $0.key.value < $1.key.value }
        if let best {
            var result = best.result
            result.amount = best.key.value
            return result
        }
        return BlendJobResult(shape: nil, amount: key.value)
    }

    private func startBlendJob(_ request: BlendJobRequest) {
        let jobs = blendJobs
        jobs.current = request
        jobs.overdue = false
        jobs.jobNumber += 1
        let number = jobs.jobNumber
        isBlendComputing = true
        // Hänger-Marke (HangGuard.swift): Vorschau-Feature, das nie im gespeicherten Verlauf steht – nach einem Absturz
        // öffnet das Projekt normal (das Feature wurde nie übernommen)
        let marker = request.mergeFeature ?? Self.blendFeature(request.input.operation, value: request.input.value,
                                                               second: request.input.second, end: request.input.end,
                                                               partialRange: request.input.partialRange,
                                                               options: request.input.options)
        HangGuard.willRun(marker, in: folder)
        // Im Hintergrund nur an unabhängigen Kopien rechnen (die Kopie kostet Millisekunden; erst hier, damit beim
        // Ziehen wartende Anfragen nicht jedes Mal kopieren)
        var input = request.input
        var independent = true
        if let copy = input.shape.independentCopy(), copy !== input.shape {
            input.shape = copy
        } else {
            independent = false
        }
        if let mergeShape = input.mergeShape {
            if let copy = mergeShape.independentCopy(), copy !== mergeShape {
                input.mergeShape = copy
            } else {
                independent = false
            }
        }
        guard independent else {
            // Eine gescheiterte Kopie darf weder den Main-Thread blockieren noch das Original in einem
            // weiterlaufenden Kernel-Thread bearbeiten.
            blendJobReturned(BlendJobResult(shape: nil, amount: request.input.value), number: number)
            return
        }
        let box = UncheckedBox(input)
        // Eigener Thread mit großem Stapel (FaceExtrudeJobs.swift KernelThread): GCD-Threads haben nur 512 KB, tiefe
        // Rekursion in OCCT liefe dort über. Es rechnet ohnehin immer höchstens eine Rundung (current/queued)
        KernelThread.start("PencilCAD.blend") {
            let result = BlendKernel.run(box.value)
            // BRepMesh schreibt in die neue Form. Noch auf diesem isolierten Kernel-Thread
            // vernetzen, bevor die Form an die UI geht; remesh() nutzt danach den Mesh-Cache.
            if let shape = result.shape { _ = shape.triangulate(deflection: 0.05) }
            let out = UncheckedBox(result)
            Task { @MainActor [weak self] in
                self?.blendJobReturned(out.value, number: number)
            }
        }
        // Erst nach einer Weile melden (kurze Rechnungen ohne Flackern)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.blendJobs.jobNumber == number, let current = self.blendJobs.current,
                  !self.blendJobs.overdue, current.generation == self.blendJobs.generation else { return }
            self.message = "\(current.input.operation == .fillet ? "Rundung" : "Fase") wird berechnet …"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BlendJobs.timeLimit) { [weak self] in
            self?.blendJobTimedOut(number)
        }
    }

    private func blendJobTimedOut(_ number: Int) {
        let jobs = blendJobs
        guard jobs.jobNumber == number, let current = jobs.current, !jobs.overdue else { return }
        jobs.overdue = true
        // Dieselben Werte nicht noch einmal starten
        rememberBlend(current, BlendJobResult(shape: nil, amount: current.input.value, timedOut: true))
        guard isCurrentBlend(current) else { return }
        message = Self.blendTooHeavyMessage
        dropPreview()
        isBlendComputing = jobs.queued != nil
        jobs.finished?()
    }

    private func blendJobReturned(_ result: BlendJobResult, number: Int) {
        let jobs = blendJobs
        guard jobs.jobNumber == number, let request = jobs.current else { return }
        HangGuard.didRun(in: folder)
        let wasOverdue = jobs.overdue
        jobs.current = nil
        jobs.overdue = false
        // Nach dem Zeitlimit: Ergebnis ignorieren (gemerkt ist es schon als Fehlschlag)
        if !wasOverdue { rememberBlend(request, result) }
        if let next = jobs.queued {
            jobs.queued = nil
            if isCurrentBlend(next) {
                startBlendJob(next)
            } else {
                isBlendComputing = false
            }
        } else {
            isBlendComputing = false
        }
        if !wasOverdue, isCurrentBlend(request) { applyBlendResult(result, request: request) }
        jobs.finished?()
    }

    private func rememberBlend(_ request: BlendJobRequest, _ result: BlendJobResult) {
        var memo = blendJobs.memo
        memo.removeAll { $0.key == request.key && $0.source === request.source }
        memo.append((key: request.key, source: request.source, result: result))
        if memo.count > BlendJobs.memoLimit { memo.removeFirst(memo.count - BlendJobs.memoLimit) }
        blendJobs.memo = memo
    }

    /// Startet die Diagnose (Worker-Modus 6) im Hintergrund; das Ergebnis ersetzt die Meldung, solange die Anfrage
    /// noch gilt, und wird beim gemerkten Fehlschlag mitgespeichert (kein zweiter Lauf für dieselben Werte).
    private func diagnoseUnblendableEdges(_ request: BlendJobRequest) {
        let input = request.input
        // Wie startBlendJob: nur an einer unabhängigen Kopie rechnen (der Vordergrund vernetzt das Original)
        guard let copy = input.shape.independentCopy(), copy !== input.shape else { return }
        let chamfer = input.operation == .chamfer
        let box = UncheckedBox((copy, input.edges, input.value, chamfer))
        let pending = UncheckedBox(request)
        KernelThread.start("PencilCAD.blend.diagnose") { [weak self] in
            let bad = IsolatedBlend.unblendableEdges(shape: box.value.0, edges: box.value.1, value: box.value.2,
                                                     chamfer: box.value.3)
            let out = UncheckedBox(bad)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keine Auskunft (Worker nicht verfügbar) als leere Liste merken: kein zweiter Lauf
                let bad = out.value ?? []
                let request = pending.value
                if let index = self.blendJobs.memo.lastIndex(where: {
                    $0.key == request.key && $0.source === request.source && $0.result.shape == nil
                }) {
                    self.blendJobs.memo[index].result.unblendable = bad
                }
                guard self.isCurrentBlend(request), !self.hasPreview,
                      let text = BlendKernel.unblendableMessage(bad, chamfer: chamfer) else { return }
                self.message = text
                self.blendJobs.finished?()
            }
        }
    }

    /// Gilt die Anfrage noch (keine neuere, gleicher Körper, gleiche Auswahl)?
    private func isCurrentBlend(_ request: BlendJobRequest) -> Bool {
        request.generation == blendJobs.generation && bodies.indices.contains(request.body)
            && bodies[request.body].shape === request.source && selectedEdges == request.selection
            && edgeOperation == request.key.operation
            // Build 42: eine Vorschau mit anderen Rundungsoptionen gilt nicht mehr
            && effectiveBlendOptions == request.key.options
    }

    /// Ergebnis als Vorschau zeigen bzw. melden, warum es nicht geht.
    private func applyBlendResult(_ result: BlendJobResult, request: BlendJobRequest) {
        let body = request.body
        let input = request.input
        let operation = input.operation
        guard let shape = result.shape else {
            if #unavailable(iOS 26.0) {
                message = "Abrunden und Fasen benötigen iPadOS 26 oder neuer."
                dropPreview()
                return
            }
            // Absturz und Zeitlimit kommen als Kennzeichen aus BlendKernel.run (kein erneutes Serialisieren des
            // Körpers auf dem Main-Thread wie früher über IsolatedBlend.wasBlocked, N3).
            if result.timedOut {
                // Schwacher Bugfix 6: Zeitlimit ≠ Absturz; andere Werte derselben Auswahl bleiben möglich
                message = Self.blendTimeLimitMessage
                dropPreview()
                return
            }
            if result.crashed {
                message = "Geometriekernel bei dieser Kantenauswahl abgebrochen. Auswahl oder Körper ändern; Projekt bleibt erhalten."
                dropPreview()
                return
            }
            if let options = input.options, operation == .fillet,
               result.optionsFailed || input.partialRange != nil || input.end != nil {
                // Build 42: kein stiller Rückfall auf Rolling Ball/G1 – Meldung mit Ausweg (C4 vergleicht die Texte)
                message = Self.blendOptionsFailureMessage(options, constantOnly: input.partialRange != nil
                                                          || input.end != nil)
                dropPreview()
                return
            }
            if result.mergeFailed {
                let name = request.mergeIndex.flatMap { features.indices.contains($0) ? features[$0].name : nil }
                    ?? "der vorigen Rundung"
                message = "Gemeinsame Rundung mit ‚\(name)‘ nicht möglich – Radius verkleinern oder die frühere "
                    + "Rundung zuerst ändern."
                dropPreview()
                return
            }
            if input.partialRange != nil {
                message = "Teilabrundung mit diesem Radius und Abschnitt nicht möglich – Start, Ende oder Radius ändern."
            } else if let end = input.end {
                // Wert bleibt stehen (kein Zurückspringen), Körper unverändert, „OK“ übernimmt nicht
                message = "Rundung mit diesem Radius nicht möglich (\(input.value.formatted()) → \(end.formatted()) mm)."
            } else if operation == .fillet {
                let text = request.blendEdges.count > 1
                    ? "Diese Kontur kann nicht durchgehend abgerundet werden – Einzelkante oder anderes Profil wählen"
                    : "Rundung mit diesem Radius nicht möglich"
                message = text + "."
            } else if let second = input.second {
                message = "Fase \(input.value.formatted()) × \(second.formatted()) mm an dieser Kante nicht möglich."
            } else {
                message = "\(operation.rawValue) an dieser Kante nicht möglich."
            }
            dropPreview()
            // Diagnose bei mehreren Kanten (konstante Rundung bzw. Fase mit einem Abstand): die Meldung nennt die
            // Kante, die OCCT gar nicht annimmt, statt pauschal „Kontur nicht möglich“.
            if input.edges.count > 1, input.partialRange == nil, input.end == nil, input.second == nil {
                if let known = result.unblendable {
                    if let text = BlendKernel.unblendableMessage(known, chamfer: operation == .chamfer) {
                        message = text
                    }
                } else {
                    diagnoseUnblendableEdges(request)
                }
            }
            return
        }
        var preview = bodies
        preview[body] = preview[body].with(shape)
        previewHiddenSketch = bodies[body].sketchID
        let name = input.partialRange != nil ? "Teilweise abrunden"
            : operation == .fillet && input.end != nil ? "Variabel abrunden" : operation.rawValue
        showPreview(preview, name: name)
        if result.merged, let feature = request.mergeFeature, let index = request.mergeIndex,
           features.indices.contains(index) {
            // Beim Übernehmen ersetzt die gemeinsame Rundung die vorige (nach showPreview, das die Aufzeichnung leert)
            var list = features
            let previousName = list[index].name
            list[index] = feature
            featureRecorder.orderedPreview = OrderedBlendPreview(features: list, states: [feature.id: preview])
            message = "Mit „\(previousName)“ zu einer Rundung zusammengefasst – die Ecke läuft sauber ineinander."
            return
        }
        // Build 49: über der gefundenen Grenze bleibt die Vorschau beim größten gelungenen Radius stehen
        message = result.amount < input.value - 1e-9
            ? "\(operation.rawValue): \(input.value.formatted()) mm geht hier nicht – gezeigt und übernommen wird "
                + "\(result.amount.formatted()) mm." : nil
        noteBlend(operation, value: result.amount, second: input.second, end: input.end,
                  partialRange: input.partialRange, edges: request.blendEdges,
                  options: operation == .fillet ? input.options : nil)
    }
}
