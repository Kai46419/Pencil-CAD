import Foundation

// Blechrechnungen im Hintergrund mit Zeitlimit (Vorbild BlendJobs.swift, Kais frühere Hänger): Wiedergabe der
// SolidCraft-Rezepte, STEP-Austausch und Flachmuster laufen auf einer eigenen seriellen Warteschlange. Die Schnittstelle
// des Modells bleibt synchron (Oberfläche und Verlauf erwarten das Ergebnis sofort): der Main Actor wartet höchstens
// timeLimit Sekunden. Kehrt die Engine nicht zurück, meldet der Aufruf „zu aufwendig“, die App bleibt bedienbar; die
// hängende Rechnung läuft weiter, bis sie endet, und bis dahin startet keine neue (nicht stapeln).
//
// Die Arbeit darf nichts aus dem Vordergrund anfassen, das gleichzeitig benutzt wird: übergeben werden nur Rezepte,
// Dateipfade und eigene Sitzungen; PencilCAD-Körper werden vorher im Vordergrund als STEP geschrieben.

/// Kapsel für Arbeit und Ergebnis über Threadgrenzen.
private final class SheetJob<Value>: @unchecked Sendable {
    let work: () throws -> Value
    var result: Result<Value, Error>?

    init(_ work: @escaping () throws -> Value) {
        self.work = work
    }
}

/// Zustand der Warteschlange (läuft gerade eine Rechnung über das Zeitlimit hinaus?).
private final class SheetWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func end() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

enum SheetWorker {
    /// Sekunden, die der Vordergrund höchstens wartet
    static let timeLimit: Double = 15
    private static let queue = DispatchQueue(label: "PencilCAD.sheet", qos: .userInitiated)
    private static let state = SheetWorkerState()

    /// Arbeit im Hintergrund ausführen und höchstens timeLimit Sekunden auf das Ergebnis warten.
    @discardableResult
    static func run<Value>(_ work: @escaping () throws -> Value) throws -> Value {
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
        guard done.wait(timeout: .now() + timeLimit) == .success, let result = job.result else {
            throw SheetKernelError("Blechberechnung zu aufwendig (über \(Int(timeLimit)) s) – abgebrochen.", timedOut: true)
        }
        return try result.get()
    }
}
