import CryptoKit
import Foundation
import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var blendWorker: AppExtensionPoint {
        Name("BlendWorker")
    }
}

/// OCCT darf bei einer fehlerhaften Rundung nur den Worker-Prozess beenden, niemals die App.
enum IsolatedBlend {
    /// Wie ein Worker-Lauf endete (nil-Ergebnis unterscheiden: Absturz ≠ Zeitlimit ≠ „nicht möglich“).
    enum Outcome {
        /// Worker hat geantwortet (auch mit nil = Rundung nicht möglich)
        case answered
        /// Worker-Prozess abgebrochen bzw. Verbindung unterbrochen: ganze Auswahl gesperrt
        case crashed
        /// Zeitlimit überschritten: nur dieser Wert gesperrt
        case timedOut
        /// Nicht gestartet (ungültige Eingabe, kein iPadOS 26, gesperrt)
        case notStarted
    }

    private struct SelectionKey: Hashable {
        /// N1: SHA256 über den ganzen BRep-Inhalt. `Data.hashValue` hasht in Foundation nur Länge und die ersten
        /// 80 Bytes – der BRep-Kopf ist bei allen Körpern gleich, gleich lange Körper wurden fälschlich gesperrt.
        let shapeDigest: Data
        let edges: [Int]
        /// Build 42: + 10 bei Rundungsoptionen ≠ Standard (ein Absturz im Setback-/G2-Pfad sperrt die
        /// Standard-Rundung derselben Auswahl nicht)
        let family: Int
    }

    /// Schwacher Bugfix 6: ein Zeitlimit gilt nur für genau diese Werte, nicht für die ganze Auswahl
    /// (sonst sperrte ein Versuch der Maximalradius-Suche mit der Diagonale alle Radien dieser Kante).
    private struct ValueKey: Hashable {
        let selection: SelectionKey
        let mode: Int
        let values: [Double?]
        /// Build 42: normalisierte Rundungsoptionen (nil = Standard)
        let options: BlendOptions?
    }

    private static let blockLock = NSLock()
    /// Abstürze: ganze Auswahl (Körper, Kanten, Fillet-Familie) für die Sitzung gesperrt
    private static var blockedSelections = Set<SelectionKey>()
    /// Zeitlimits: nur diese Werte
    private static var timedOutValues = Set<ValueKey>()
    /// Zeit, die der Host höchstens auf einen Worker wartet
    static let workerTimeout: TimeInterval = 8

    private static func key(_ brep: Data, _ edges: [NSNumber], _ mode: Int,
                            _ options: BlendOptions? = nil) -> SelectionKey {
        // Modus 98 simuliert im Debug-Worker einen Abbruch derselben Fillet-Familie.
        let base = [0, 2, 3, 5, 98].contains(mode) ? 0 : [1, 4].contains(mode) ? 1 : mode
        // Build 42: eigener Sperrbereich für Rundungen mit Optionen (Familien bisher 0, 1, 6, 99 → 10, 11, 16, 109)
        let family = options?.normalized == nil ? base : base + 10
        return SelectionKey(shapeDigest: Data(SHA256.hash(data: brep)), edges: edges.map(\.intValue).sorted(),
                            family: family)
    }

    private static func valueKey(_ selection: SelectionKey, mode: Int, value: Double, second: Double?,
                                 start: Double?, stop: Double?, radii: [Double]?,
                                 options: BlendOptions? = nil) -> ValueKey {
        let base: [Double?] = [value, second, start, stop]
        return ValueKey(selection: selection, mode: mode, values: base + (radii ?? []).map { Optional($0) },
                        options: options?.normalized)
    }

    private static func isBlocked(_ key: SelectionKey) -> Bool {
        blockLock.lock()
        defer { blockLock.unlock() }
        return blockedSelections.contains(key)
    }

    private static func block(_ key: SelectionKey) {
        blockLock.lock()
        blockedSelections.insert(key)
        blockLock.unlock()
    }

    private static func hasTimedOut(_ key: ValueKey) -> Bool {
        blockLock.lock()
        defer { blockLock.unlock() }
        return timedOutValues.contains(key)
    }

    private static func noteTimeout(_ key: ValueKey) {
        blockLock.lock()
        timedOutValues.insert(key)
        blockLock.unlock()
    }

    /// Ist diese Auswahl nach einem Worker-ABSTURZ gesperrt? Ein Zeitlimit zählt hier nicht (wasTimedOut).
    static func wasBlocked(shape: PCKShape, edges: [NSNumber], mode: Int, options: BlendOptions? = nil) -> Bool {
        guard let brep = shape.brepData() else { return false }
        return isBlocked(key(brep, edges, mode, options))
    }

    /// Hat genau dieser Wert schon einmal das Zeitlimit überschritten?
    static func wasTimedOut(shape: PCKShape, edges: [NSNumber], mode: Int, value: Double,
                            second: Double? = nil, start: Double? = nil, stop: Double? = nil,
                            radii: [Double]? = nil, options: BlendOptions? = nil) -> Bool {
        guard let brep = shape.brepData() else { return false }
        return hasTimedOut(valueKey(key(brep, edges, mode, options), mode: mode, value: value, second: second,
                                    start: start, stop: stop, radii: radii, options: options))
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var payload: Data?
        private var ending = Outcome.notStarted
        let hostReady = DispatchSemaphore(value: 0)
        let workerReady = DispatchSemaphore(value: 0)

        /// Nur der erste Aufruf zählt. note läuft vor dem Wecken des Hosts (Sperre bzw. Zeitlimit ist dann schon
        /// gemerkt, wenn der Aufrufer gleich danach wasBlocked fragt).
        @discardableResult
        func finish(_ data: Data?, outcome: Outcome = .answered, note: (() -> Void)? = nil) -> Bool {
            lock.lock()
            guard !completed else { lock.unlock(); return false }
            payload = data
            ending = outcome
            completed = true
            lock.unlock()
            note?()
            hostReady.signal()
            workerReady.signal()
            return true
        }

        func result() -> (data: Data?, outcome: Outcome) {
            lock.lock()
            defer { lock.unlock() }
            return (payload, ending)
        }
    }

    static func run(shape: PCKShape, edges: [NSNumber], mode: Int, value: Double,
                    second: Double? = nil, start: Double? = nil, stop: Double? = nil,
                    radii: [Double]? = nil, options: BlendOptions? = nil) -> PCKShape? {
        runReporting(shape: shape, edges: edges, mode: mode, value: value, second: second, start: start,
                     stop: stop, radii: radii, options: options).shape
    }

    /// Wie run, zusätzlich mit dem Ausgang (BlendKernel unterscheidet damit Zeitlimit und Absturz).
    static func runReporting(shape: PCKShape, edges: [NSNumber], mode: Int, value: Double,
                             second: Double? = nil, start: Double? = nil, stop: Double? = nil,
                             radii: [Double]? = nil,
                             options: BlendOptions? = nil) -> (shape: PCKShape?, outcome: Outcome) {
        // Build 42: Optionen nur für Modus 0/5 (98/99: Debug-Absturztest); Standard = nil im Protokoll
        let options = options?.normalized
        guard #available(iOS 26.0, *),
              let brep = shape.brepData(), !brep.isEmpty,
              !edges.isEmpty, edges.count <= 100,
              value.isFinite, value > 0,
              radii == nil || (radii?.count == edges.count && radii?.allSatisfy { $0.isFinite && $0 > 0 } == true),
              options?.isValid ?? true,
              options == nil || [0, 5, 98, 99].contains(mode)
        else { return (nil, .notStarted) }
        let selection = key(brep, edges, mode, options)
        guard !isBlocked(selection) else { return (nil, .crashed) }
        let values = valueKey(selection, mode: mode, value: value, second: second, start: start, stop: stop,
                              radii: radii, options: options)
        guard !hasTimedOut(values) else { return (nil, .timedOut) }
        let request = BlendWorkerRequest(shape: brep, edges: edges.map(\.intValue), mode: mode,
                                         value: value, second: second, start: start, stop: stop, radii: radii,
                                         options: options)
        let (data, outcome) = exchange(request, selection: selection, values: values)
        guard let data else { return (nil, outcome) }
        return (PCKShape.fromBRepData(data), outcome)
    }

    /// Diagnose (Worker-Modus 6): welche der gewählten Kanten nimmt OCCT gar nicht an (Naht, tangentialer
    /// Übergang)? Läuft wie jede Rundung im Worker-Prozess – auch BRepFilletAPI_Add kann im Kernel abstürzen.
    /// Der Worker antwortet über dasselbe Protokoll (Data) mit JSON-kodierten Kantennummern statt einem BRep.
    /// nil = keine Auskunft (Worker nicht verfügbar, Zeitlimit, Absturz). Nicht auf dem Main-Thread aufrufen.
    static func unblendableEdges(shape: PCKShape, edges: [NSNumber], value: Double, chamfer: Bool) -> [Int]? {
        guard #available(iOS 26.0, *),
              let brep = shape.brepData(), !brep.isEmpty,
              !edges.isEmpty, edges.count <= 100, value.isFinite, value > 0 else { return nil }
        let mode = 6
        let selection = key(brep, edges, mode)
        guard !isBlocked(selection) else { return nil }
        // second = 1: Fase, sonst Rundung (das Protokoll in Shared/ bleibt unverändert)
        let flag: Double? = chamfer ? 1 : nil
        let values = valueKey(selection, mode: mode, value: value, second: flag, start: nil, stop: nil, radii: nil)
        guard !hasTimedOut(values) else { return nil }
        let request = BlendWorkerRequest(shape: brep, edges: edges.map(\.intValue), mode: mode,
                                         value: value, second: flag, start: nil, stop: nil, radii: nil)
        guard let data = exchange(request, selection: selection, values: values).data else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }

    /// Ein Worker-Lauf: Prozess starten, Anfrage senden, höchstens workerTimeout warten.
    /// Absturz → ganze Auswahl sperren; Zeitlimit → nur diese Werte merken.
    private static func exchange(_ request: BlendWorkerRequest, selection: SelectionKey,
                                 values: ValueKey) -> (data: Data?, outcome: Outcome) {
        guard #available(iOS 26.0, *), let encoded = try? JSONEncoder().encode(request) else {
            return (nil, .notStarted)
        }
        let mode = request.mode
        let edgeCount = request.edges.count
        let value = request.value
        let reply = Reply()
        let workerFailed: @Sendable () -> Void = {
            if reply.finish(nil, outcome: .crashed, note: { block(selection) }) {
                NSLog("PencilCAD BlendWorker unterbrochen: Modus %ld, %ld Kanten, Wert %.4f mm",
                      mode, edgeCount, value)
            }
        }
        let timedOut: @Sendable () -> Void = {
            // Zuerst abschließen, dann merken: ein danach eintreffender Invalidierungs-Handler findet die Antwort
            // schon abgeschlossen vor und wertet das Zeitlimit nicht als Absturz.
            if reply.finish(nil, outcome: .timedOut, note: { noteTimeout(values) }) {
                NSLog("PencilCAD BlendWorker Zeitlimit: Modus %ld, %ld Kanten, Wert %.4f mm",
                      mode, edgeCount, value)
            }
        }
        Task.detached(priority: .userInitiated) {
            do {
                let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .blendWorker)
                guard let identity = monitor.identities.first else { reply.finish(nil, outcome: .notStarted); return }
                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity, onInterruption: workerFailed))
                let connection = try process.makeXPCConnection()
                connection.remoteObjectInterface = NSXPCInterface(with: BlendWorkerProtocol.self)
                connection.interruptionHandler = workerFailed
                connection.invalidationHandler = workerFailed
                connection.resume()
                guard let worker = connection.remoteObjectProxyWithErrorHandler({ _ in workerFailed() })
                    as? BlendWorkerProtocol else {
                    reply.finish(nil, outcome: .notStarted)
                    connection.invalidate()
                    process.invalidate()
                    return
                }
                worker.compute(encoded) { reply.finish($0) }
                if reply.workerReady.wait(timeout: .now() + workerTimeout) == .timedOut { timedOut() }
                connection.invalidate()
                process.invalidate()
            } catch {
                reply.finish(nil, outcome: .notStarted)
            }
        }
        // Eigener Wartepfad: auch ein vollständig hängender Worker darf keine App-Threads dauerhaft halten.
        if reply.hostReady.wait(timeout: .now() + workerTimeout) != .success { timedOut() }
        // Bei einem Wettlauf (Absturz genau am Zeitlimit) gilt, was zuerst abgeschlossen wurde
        return reply.result()
    }
}
