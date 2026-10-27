import Foundation

// Blechrechnungen im Hintergrund mit Zeitlimit (Vorbild BlendJobs.swift, Kais frühere Hänger): Wiedergabe der
// SolidCraft-Rezepte, STEP-Austausch und Flachmuster laufen auf einer eigenen seriellen Warteschlange. Die Schnittstelle
// des Modells bleibt synchron (Oberfläche und Verlauf erwarten das Ergebnis sofort): der Main Actor wartet höchstens
// timeLimit Sekunden (Nachbau des Verlaufs replayLimit). Kehrt die Engine nicht zurück, meldet der Aufruf „zu aufwendig“,
// die App bleibt bedienbar; die hängende Rechnung läuft weiter, höchstens ein neuer Auftrag wartet dahinter.
//
// Die Arbeit darf nichts aus dem Vordergrund anfassen, das gleichzeitig benutzt wird: übergeben werden nur Rezepte,
// Dateipfade und eigene Sitzungen; PencilCAD-Körper als unabhängige Kopie (PCKShape.independentCopy), die erst hier
// als STEP geschrieben wird.

/// Körper als STEP schreiben – auf der Warteschlange des Blechmoduls, an einer unabhängigen Kopie.
func sheetWriteSTEP(_ shape: PCKShape, to url: URL, limit: Double = SheetWorker.timeLimit) throws {
    let copy = shape.independentCopy() ?? shape
    let path = url.path(percentEncoded: false)
    try SheetWorker.run(limit: limit) { () throws -> Void in
        guard PCKShape.writeSTEP([copy], path: path) else {
            throw SheetKernelError("Körper ließ sich nicht als STEP schreiben.")
        }
    }
}

/// Kapsel für Arbeit und Ergebnis über Threadgrenzen.
private final class SheetJob<Value>: @unchecked Sendable {
    let work: () throws -> Value
    var result: Result<Value, Error>?

    init(_ work: @escaping () throws -> Value) {
        self.work = work
    }
}

/// Zustand der Warteschlange: Anzahl der Aufträge (laufend + wartend). Nach einem Zeitlimit wartet höchstens ein
/// neuer Auftrag hinter der alten Rechnung (nicht stapeln); sobald sie endet, geht es normal weiter.
private final class SheetWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending >= 2 { return false }
        pending += 1
        return true
    }

    func end() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }
}

enum SheetWorker {
    /// Sekunden, die der Vordergrund bei Vorschau und Befehlen höchstens wartet
    static let timeLimit: Double = 15
    /// Nachbau des Verlaufs (auch beim Öffnen eines Projekts): großzügig, damit große Rezepte nicht scheitern
    static let replayLimit: Double = 120
    private static let queue = DispatchQueue(label: "PencilCAD.sheet", qos: .userInitiated)
    private static let state = SheetWorkerState()

    /// Arbeit im Hintergrund ausführen und höchstens limit Sekunden auf das Ergebnis warten. Auch alles STEP-Lesen und
    /// -Schreiben des Blechmoduls läuft hier (eine serielle Warteschlange: OCCT-STEP nutzt globale Einstellungen).
    @discardableResult
    static func run<Value>(limit: Double = SheetWorker.timeLimit, _ work: @escaping () throws -> Value) throws -> Value {
        guard state.begin() else {
            throw SheetKernelError("Das Blechmodul rechnet noch an einem früheren, sehr aufwendigen Schritt – bitte kurz "
                + "warten und erneut versuchen.", timedOut: true)
        }
        let job = SheetJob(work)
        let done = DispatchSemaphore(value: 0)
        let state = self.state
        queue.async {
            job.result = Result { try job.work() }
            state.end()
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success, let result = job.result else {
            throw SheetKernelError("Blechberechnung zu aufwendig (über \(Int(limit)) s) – abgebrochen.", timedOut: true)
        }
        return try result.get()
    }
}
