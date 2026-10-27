import Foundation

// Extrudieren bzw. Press Pull ebener Körperflächen absturzsicher (Kai, Build 221: „Fläche 1824“ eines importierten
// STEP-Körpers mit tausenden Flächen und dünnen gebogenen Lamellen um 40 mm gezogen – die App stürzte ab).
//
// Ursache: ModelStore.setFaceValue rief PCKShape.extruding(faces:distance:) (Prisma + BRepAlgoAPI_Fuse/Cut,
// ShapeUpgrade_UnifySameDomain, BRepCheck_Analyzer/ShapeFix) synchron auf dem Main-Thread auf, bei jedem Wert und
// jedem Pfeil-Frame, anschließend vernetzte remesh() das Ergebnis ebenfalls im Vordergrund. C++-Ausnahmen fing der
// Kernel schon ab (catch (...)); was die App beendet, sind Fehler, die keine Ausnahme sind: Stapelüberlauf in der
// tiefen Rekursion von BOP/IntTools/BRepMesh bei solchen Körpern und Speicherspitzen. Dazu teilte das Ergebnis
// seine unveränderten Flächen (TShapes) mit dem angezeigten Körper, in die BRepMesh beim Vernetzen schreibt.
//
// Jetzt (Vorbild BlendJobs.swift):
// - Hintergrund: eigener Thread mit großem Stapel (KernelThread, 32 MB statt 512 KB GCD bzw. 1 MB Main-Thread), an
//   einer unabhängigen Kopie des Körpers samt Netz (PCKShape.independentCopyKeepingMesh). Das Ergebnis wird dort
//   auch gleich vernetzt (das Netz bleibt am Körper gemerkt, remesh() im Vordergrund findet es fertig vor).
// - Höchstens eine Rechnung zugleich; neue Werte warten (nur der neueste), alte Ergebnisse werden verworfen.
// - Zeitlimit 8 s: Meldung „zu aufwendig“, Vorschau verworfen, OK gesperrt, Wert als Fehlschlag gemerkt. Der hängende
//   Aufruf läuft an seiner Kopie weiter, bis OCCT zurückkehrt; bis dahin startet nichts Neues.
// - HangGuard-Marke während der Rechnung (ein Vorschau-Feature, das nie im gespeicherten Verlauf steht).
// - Scheitert es: Vorschau verworfen, „Extrudieren an dieser Fläche nicht möglich.“, OK übernimmt nicht.
// - Nachrechnen des Verlaufs (Öffnen, Rückgängig, Bearbeiten): FaceExtrudeKernel.extrudeGuarded – ebenfalls an
//   einer Kopie auf dem großen Stapel, mit großzügigem Zeitlimit (Feature wird rot statt die App zu beenden).
//
// OSD::SetSignal/OCC_CATCH_SIGNALS bleiben bewusst aus: Signal-Handler gelten für den ganzen Prozess (auch Swift-
// Traps und Metal), der Sprung aus dem Handler ließe OCCT-Zustand halb zurück, und ein Stapelüberlauf erreicht den
// Handler ohne eigenen Signal-Stapel ohnehin nicht. Die Absicherung ist deshalb die Isolation oben.

/// OCCT-Arbeit auf einem eigenen Thread mit großem Stapel (GCD-Threads haben nur 512 KB).
enum KernelThread {
    /// Stapelgröße (Vielfaches von 4 KB)
    static let stackSize = 32 << 20

    /// work ist @Sendable: die Closure darf nicht die Isolation des Aufrufers (Main Actor) erben, sie läuft ja auf
    /// diesem Thread (sonst Absturz, sobald die Laufzeit Actor-Isolation prüft).
    static func start(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let job = UncheckedBox(work)
        let thread = Thread { job.value() }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Arbeit auf dem großen Stapel ausführen und auf das Ergebnis warten. limit nil = ohne Zeitlimit (nur für Arbeit
    /// an Körpern, die auch der Aufrufer benutzt: er wartet ja, also rechnet nie jemand gleichzeitig daran).
    /// nil = Zeitlimit überschritten (die Arbeit läuft weiter, ihr Ergebnis verfällt).
    static func wait<Value>(_ name: String, limit: Double?, _ work: @escaping @Sendable () -> Value) -> Value? {
        let box = KernelResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        start(name) {
            box.set(work())
            done.signal()
        }
        if let limit {
            guard done.wait(timeout: .now() + limit) == .success else { return nil }
        } else {
            done.wait()
        }
        return box.get()
    }
}

/// Ergebnis über Threadgrenzen (gesperrt, weil der Wartende nach dem Zeitlimit nicht mehr liest).
private final class KernelResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Ein Körper der Anfrage: seine gezogenen Flächen und der Körper, an dem gerechnet wird.
struct FaceExtrudePart {
    var body: Int
    var faces: [NSNumber]
    var shape: PCKShape
}

/// Ergebnis aus dem Hintergrund.
struct FaceExtrudeResult {
    /// Neue Körper je Körpernummer; nil = nicht möglich
    var shapes: [Int: PCKShape]?
    /// Zeitlimit überschritten
    var timedOut = false
}

/// Eine Anfrage (Vorschau für einen Abstand).
struct FaceExtrudeRequest {
    var generation: Int
    var faces: [FaceRef]
    var distance: Double
    /// Körper beim Start (zum Prüfen beim Zurückkommen und für den Merker)
    var sources: [Int: PCKShape]

    /// Dieselbe Rechnung (gleiche Flächen, gleicher Abstand, dieselben Körper)?
    func matches(_ other: FaceExtrudeRequest) -> Bool {
        guard faces == other.faces, distance == other.distance, sources.count == other.sources.count else { return false }
        for (body, shape) in sources {
            guard let otherShape = other.sources[body], otherShape === shape else { return false }
        }
        return true
    }
}

/// Zustand des Flächen-Extrudierens im Hintergrund (ModelStore.faceJobs, nicht veröffentlicht).
final class FaceExtrudeJobs {
    /// Zählt jede neue Anfrage; ältere Ergebnisse werden verworfen
    var generation = 0
    /// Laufende Anfrage (auch nach dem Zeitlimit, bis OCCT zurückkehrt)
    var current: FaceExtrudeRequest?
    var jobNumber = 0
    /// Die laufende Anfrage hat das Zeitlimit überschritten (ihr Ergebnis wird ignoriert)
    var overdue = false
    /// Nächste Anfrage (nur die neueste)
    var queued: FaceExtrudeRequest?
    /// Ergebnisse (auch Fehlschläge), die neuesten hinten – wenige, weil jedes Ergebnis ein ganzer Körper ist
    var memo: [(request: FaceExtrudeRequest, result: FaceExtrudeResult)] = []
    /// Nach jedem angekommenen Ergebnis (offenes Extrudieren-/Press-Pull-Panel aktualisieren)
    var finished: (() -> Void)?

    var running: Bool { current != nil }

    static let timeLimit = 8.0
    /// Nachrechnen des Verlaufs: großzügig (große Körper brauchen beim Öffnen länger als in der Vorschau)
    static let replayLimit = 90.0
    static let memoLimit = 2
    /// Wie ModelStore.remesh (sonst rechnet der Vordergrund das Netz noch einmal)
    static let deflection = 0.05
    static let threadName = "PencilCAD.extrude"
}

/// Rechnen (nur Kernel-Aufrufe, kein Zugriff auf den ModelStore).
enum FaceExtrudeKernel {
    /// Alle Körper der Anfrage ziehen; mesh: gleich vernetzen (nur an Kopien, die sonst niemand benutzt).
    static func run(_ parts: [FaceExtrudePart], distance: Double, mesh: Bool) -> [Int: PCKShape]? {
        var shapes: [Int: PCKShape] = [:]
        for part in parts {
            guard let result = part.shape.extruding(faces: part.faces, distance: distance) else { return nil }
            shapes[part.body] = result
        }
        if mesh {
            for shape in shapes.values { _ = shape.triangulate(deflection: FaceExtrudeJobs.deflection) }
        }
        return shapes
    }

    /// Verlauf (Nachbau, OK beim Bearbeiten): an einer Kopie auf dem großen Stapel, mit Zeitlimit. Scheitert die Kopie,
    /// am Original, dann aber ohne Zeitlimit (der Aufrufer wartet, niemand rechnet gleichzeitig daran).
    static func extrudeGuarded(_ shape: PCKShape, faces: [NSNumber], distance: Double,
                               limit: Double = FaceExtrudeJobs.replayLimit) -> (shape: PCKShape?, timedOut: Bool) {
        // Netz mitkopieren: unveränderte Flächen behalten es, der Vordergrund vernetzt danach nur die neuen
        let copy = shape.independentCopyKeepingMesh()
        let independent = copy != nil && copy !== shape
        let part = FaceExtrudePart(body: 0, faces: faces, shape: independent ? (copy ?? shape) : shape)
        let box = UncheckedBox(part)
        let outcome = KernelThread.wait(FaceExtrudeJobs.threadName, limit: independent ? limit : nil) {
            UncheckedBox(FaceExtrudeKernel.run([box.value], distance: distance, mesh: false)?[0])
        }
        guard let outcome else { return (nil, true) }
        return (outcome.value, false)
    }
}

extension ModelStore {
    static let faceExtrudeTooHeavyMessage =
        "Extrudieren an dieser Fläche zu aufwendig (über 8 s) – abgebrochen. Anderen Abstand oder eine andere Fläche versuchen."
    static let faceExtrudeFailedMessage = "Extrudieren an dieser Fläche nicht möglich."

    /// Auswahl aufgehoben, Vorschau abgebrochen bzw. übernommen: nichts mehr zeigen, was noch rechnet.
    func cancelFaceExtrudeJobs() {
        faceJobs.generation += 1
        faceJobs.queued = nil
        if isFaceComputing { isFaceComputing = false }
    }

    /// setFaceValue: gewählte ebene Flächen um distance ziehen (gemerkt sofort, sonst im Hintergrund).
    func requestFaceExtrude(_ faces: [FaceRef], distance: Double) {
        let jobs = faceJobs
        jobs.generation += 1
        jobs.queued = nil
        var sources: [Int: PCKShape] = [:]
        for face in faces where bodies.indices.contains(face.body) {
            sources[face.body] = bodies[face.body].shape
        }
        guard !sources.isEmpty else { return }
        let request = FaceExtrudeRequest(generation: jobs.generation, faces: faces, distance: distance, sources: sources)
        // Schon gerechnet (auch Fehlschlag bzw. Zeitlimit): sofort
        if let known = jobs.memo.last(where: { $0.request.matches(request) }) {
            if isFaceComputing { isFaceComputing = false }
            applyFaceExtrudeResult(known.result, request: request)
            return
        }
        // Läuft schon dieselbe Rechnung: übernehmen statt noch einmal
        if let current = jobs.current, current.matches(request) {
            if jobs.overdue {
                if isFaceComputing { isFaceComputing = false }
                message = Self.faceExtrudeTooHeavyMessage
                dropPreview()
                return
            }
            jobs.current?.generation = jobs.generation
            isFaceComputing = true
            return
        }
        isFaceComputing = true
        if jobs.running {
            // Nicht parallel stapeln: wartet, bis die laufende Rechnung zurück ist (nur die neueste)
            jobs.queued = request
            if jobs.overdue {
                message = "Die vorige Extrusion rechnet noch (zu aufwendig) – der neue Wert folgt, sobald sie fertig ist."
            }
            return
        }
        startFaceExtrudeJob(request)
    }

    private func startFaceExtrudeJob(_ request: FaceExtrudeRequest) {
        let jobs = faceJobs
        jobs.current = request
        jobs.overdue = false
        jobs.jobNumber += 1
        let number = jobs.jobNumber
        isFaceComputing = true
        // Hänger-Marke (HangGuard.swift): Vorschau-Feature, das nie im gespeicherten Verlauf steht
        var marker = Feature(name: request.faces.count > 1 ? "Flächen ziehen" : "Fläche ziehen", kind: .faceExtrude)
        marker.parameters.append(.length("distance", "Abstand", request.distance))
        HangGuard.willRun(marker, in: folder)
        // Unabhängige Kopien samt Netz: der Vordergrund vernetzt und pickt weiter am Original
        var parts: [FaceExtrudePart] = []
        var independent = true
        for body in request.sources.keys.sorted() {
            guard let source = request.sources[body] else { continue }
            let numbers = request.faces.filter { $0.body == body }.map { NSNumber(value: $0.face) }
            if let copy = source.independentCopyKeepingMesh(), copy !== source {
                parts.append(FaceExtrudePart(body: body, faces: numbers, shape: copy))
            } else {
                independent = false
                parts.append(FaceExtrudePart(body: body, faces: numbers, shape: source))
            }
        }
        let distance = request.distance
        let box = UncheckedBox(parts)
        guard independent else {
            // Kopie gescheitert: das Original darf nicht in den Hintergrund (nach dem Zeitlimit liefe die Rechnung dort
            // weiter, während der Vordergrund denselben Körper vernetzt). Dann wartend auf dem großen Stapel.
            let shapes = KernelThread.wait(FaceExtrudeJobs.threadName, limit: nil) {
                UncheckedBox(FaceExtrudeKernel.run(box.value, distance: distance, mesh: false))
            }
            faceExtrudeJobReturned(FaceExtrudeResult(shapes: shapes?.value), number: number)
            return
        }
        KernelThread.start(FaceExtrudeJobs.threadName) {
            let shapes = FaceExtrudeKernel.run(box.value, distance: distance, mesh: true)
            let out = UncheckedBox(FaceExtrudeResult(shapes: shapes))
            Task { @MainActor [weak self] in
                self?.faceExtrudeJobReturned(out.value, number: number)
            }
        }
        // Erst nach einer Weile melden (kurze Rechnungen ohne Flackern)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.faceJobs.jobNumber == number, let current = self.faceJobs.current,
                  !self.faceJobs.overdue, current.generation == self.faceJobs.generation else { return }
            self.message = "Extrudieren wird berechnet …"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FaceExtrudeJobs.timeLimit) { [weak self] in
            self?.faceExtrudeJobTimedOut(number)
        }
    }

    private func faceExtrudeJobTimedOut(_ number: Int) {
        let jobs = faceJobs
        guard jobs.jobNumber == number, let current = jobs.current, !jobs.overdue else { return }
        jobs.overdue = true
        // Denselben Wert nicht noch einmal starten
        rememberFaceExtrude(current, FaceExtrudeResult(shapes: nil, timedOut: true))
        guard isCurrentFaceExtrude(current) else { return }
        message = Self.faceExtrudeTooHeavyMessage
        dropPreview()
        isFaceComputing = jobs.queued != nil
        jobs.finished?()
    }

    private func faceExtrudeJobReturned(_ result: FaceExtrudeResult, number: Int) {
        let jobs = faceJobs
        guard jobs.jobNumber == number, let request = jobs.current else { return }
        HangGuard.didRun(in: folder)
        let wasOverdue = jobs.overdue
        jobs.current = nil
        jobs.overdue = false
        // Nach dem Zeitlimit: Ergebnis ignorieren (gemerkt ist es schon als Fehlschlag)
        if !wasOverdue { rememberFaceExtrude(request, result) }
        if let next = jobs.queued {
            jobs.queued = nil
            if next.generation == jobs.generation {
                startFaceExtrudeJob(next)
            } else {
                isFaceComputing = false
            }
        } else {
            isFaceComputing = false
        }
        if !wasOverdue, isCurrentFaceExtrude(request) { applyFaceExtrudeResult(result, request: request) }
        jobs.finished?()
    }

    private func rememberFaceExtrude(_ request: FaceExtrudeRequest, _ result: FaceExtrudeResult) {
        var memo = faceJobs.memo
        memo.removeAll { $0.request.matches(request) }
        memo.append((request: request, result: result))
        if memo.count > FaceExtrudeJobs.memoLimit { memo.removeFirst(memo.count - FaceExtrudeJobs.memoLimit) }
        faceJobs.memo = memo
    }

    /// Gilt die Anfrage noch (keine neuere, gleiche Flächen, gleicher Abstand, unveränderte Körper)?
    private func isCurrentFaceExtrude(_ request: FaceExtrudeRequest) -> Bool {
        guard request.generation == faceJobs.generation, selectedFaces == request.faces,
              faceValue == request.distance else { return false }
        for (body, shape) in request.sources {
            guard bodies.indices.contains(body), bodies[body].shape === shape else { return false }
        }
        return true
    }

    /// Ergebnis als Vorschau zeigen bzw. melden, warum es nicht geht (dann ohne Vorschau: OK übernimmt nicht).
    private func applyFaceExtrudeResult(_ result: FaceExtrudeResult, request: FaceExtrudeRequest) {
        guard let shapes = result.shapes, !shapes.isEmpty else {
            if result.timedOut {
                message = Self.faceExtrudeTooHeavyMessage
            } else {
                message = request.faces.count > 1 ? "Diese Flächen lassen sich nicht zusammen extrudieren."
                    : Self.faceExtrudeFailedMessage
            }
            dropPreview()
            return
        }
        var preview = bodies
        for (body, shape) in shapes where preview.indices.contains(body) {
            preview[body] = preview[body].with(shape)
        }
        message = nil
        showPreview(preview, name: request.faces.count > 1 ? "Flächen extrudieren" : "Extrudieren")
        noteFaceExtrude(distance: request.distance)
    }
}

/// Offenes Extrudieren- bzw. Press-Pull-Panel nach einem Ergebnis aus dem Hintergrund aktualisieren.
@MainActor
enum FaceExtrudePanel {
    static func finished(_ cmd: ModelCommand, _ ws: Workspace) -> () -> Void {
        { [weak ws, weak cmd] in
            guard let ws, let cmd, let open = ws.command, open === cmd, open.editing == nil else { return }
            let model = ws.model
            let error: String? = model.hasPreview || model.isFaceComputing ? nil
                : (model.message ?? ModelStore.faceExtrudeFailedMessage)
            open.error = error
            CommandCache.mark(open, error: error)
        }
    }
}
