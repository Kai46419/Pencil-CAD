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
    private struct SelectionKey: Hashable {
        let shapeHash: Int
        let edges: [Int]
        let family: Int
    }

    private static let blockLock = NSLock()
    private static var blockedSelections = Set<SelectionKey>()

    private static func key(_ brep: Data, _ edges: [NSNumber], _ mode: Int) -> SelectionKey {
        // Modus 98 simuliert im Debug-Worker einen Abbruch derselben Fillet-Familie.
        let family = [0, 2, 3, 5, 98].contains(mode) ? 0 : [1, 4].contains(mode) ? 1 : mode
        return SelectionKey(shapeHash: brep.hashValue, edges: edges.map(\.intValue).sorted(), family: family)
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

    static func wasBlocked(shape: PCKShape, edges: [NSNumber], mode: Int) -> Bool {
        guard let brep = shape.brepData() else { return false }
        return isBlocked(key(brep, edges, mode))
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var payload: Data?
        let hostReady = DispatchSemaphore(value: 0)
        let workerReady = DispatchSemaphore(value: 0)

        @discardableResult
        func finish(_ data: Data?) -> Bool {
            lock.lock()
            guard !completed else { lock.unlock(); return false }
            payload = data
            completed = true
            lock.unlock()
            hostReady.signal()
            workerReady.signal()
            return true
        }

        func result() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return payload
        }
    }

    static func run(shape: PCKShape, edges: [NSNumber], mode: Int, value: Double,
                    second: Double? = nil, start: Double? = nil, stop: Double? = nil,
                    radii: [Double]? = nil) -> PCKShape? {
        guard #available(iOS 26.0, *),
              let brep = shape.brepData(), !brep.isEmpty,
              !edges.isEmpty, edges.count <= 100,
              value.isFinite, value > 0,
              radii == nil || (radii?.count == edges.count && radii?.allSatisfy { $0.isFinite && $0 > 0 } == true)
        else { return nil }
        let selection = key(brep, edges, mode)
        guard !isBlocked(selection) else { return nil }
        let request = BlendWorkerRequest(shape: brep, edges: edges.map(\.intValue), mode: mode,
                                         value: value, second: second, start: start, stop: stop, radii: radii)
        guard let encoded = try? JSONEncoder().encode(request) else { return nil }
        let reply = Reply()
        let workerFailed: @Sendable () -> Void = {
            if reply.finish(nil) {
                block(selection)
                NSLog("PencilCAD BlendWorker unterbrochen: Modus %ld, %ld Kanten, Wert %.4f mm",
                      mode, edges.count, value)
            }
        }
        Task.detached(priority: .userInitiated) {
            do {
                let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .blendWorker)
                guard let identity = monitor.identities.first else { reply.finish(nil); return }
                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity, onInterruption: workerFailed))
                let connection = try process.makeXPCConnection()
                connection.remoteObjectInterface = NSXPCInterface(with: BlendWorkerProtocol.self)
                connection.interruptionHandler = workerFailed
                connection.invalidationHandler = workerFailed
                connection.resume()
                guard let worker = connection.remoteObjectProxyWithErrorHandler({ _ in workerFailed() })
                    as? BlendWorkerProtocol else {
                    reply.finish(nil)
                    connection.invalidate()
                    process.invalidate()
                    return
                }
                worker.compute(encoded) { reply.finish($0) }
                _ = reply.workerReady.wait(timeout: .now() + 8)
                connection.invalidate()
                process.invalidate()
            } catch {
                reply.finish(nil)
            }
        }
        // Eigener Wartepfad: auch ein vollständig hängender Worker darf keine App-Threads dauerhaft halten.
        guard reply.hostReady.wait(timeout: .now() + 8) == .success else {
            block(selection)
            reply.finish(nil)
            return nil
        }
        guard let data = reply.result() else { return nil }
        return PCKShape.fromBRepData(data)
    }
}
