import ExtensionFoundation
import Foundation

@main
struct BlendWorkerExtension: AppExtension {
    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "de.kai46419.pencilcad", name: "BlendWorker")
    }

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler { connection in
            connection.exportedInterface = NSXPCInterface(with: BlendWorkerProtocol.self)
            connection.exportedObject = BlendWorkerObject()
            connection.resume()
            return true
        }
    }
}

private final class BlendWorkerObject: NSObject, BlendWorkerProtocol {
    func compute(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
        guard let input = try? JSONDecoder().decode(BlendWorkerRequest.self, from: request),
              input.shape.count <= 100 * 1024 * 1024,
              input.edges.count > 0, input.edges.count <= 100,
              input.value.isFinite, input.value > 0,
              input.second?.isFinite ?? true,
              input.start?.isFinite ?? true,
              input.stop?.isFinite ?? true,
              input.radii == nil || (input.radii?.count == input.edges.count &&
                                    input.radii?.allSatisfy { $0.isFinite && $0 > 0 } == true),
              let shape = PCKShape.fromBRepData(input.shape) else {
            reply(nil)
            return
        }
        let numbers = input.edges.map(NSNumber.init(value:))
#if DEBUG
        // Testpfad: beweist, dass ein nativer Worker-Abbruch den Host nicht beendet.
        if input.mode == 98 || input.mode == 99 { fatalError("BlendWorker crash isolation test") }
#endif
        let result: PCKShape?
        switch input.mode {
        case 0:
            result = shape.filleting(edges: numbers, radius: input.value)
        case 1:
            result = shape.chamfering(edges: numbers, distance: input.value)
        case 2:
            if numbers.count == 1, let start = input.start, let stop = input.stop {
                result = shape.partiallyFilleting(edge: numbers[0].intValue, radius: input.value, start: start, end: stop)
            } else { result = nil }
        case 3:
            result = input.second.flatMap { shape.filleting(edges: numbers, radius: input.value, endRadius: $0) }
        case 4:
            result = input.second.flatMap { shape.chamfering(edges: numbers, distance: input.value, distance2: $0) }
        case 5:
            result = input.radii.flatMap { shape.filleting(edges: numbers, radii: $0.map(NSNumber.init(value:))) }
        default:
            result = nil
        }
        guard let result, result.isValidBlendPreview(from: shape),
              input.mode != 0 || numbers.count != 1 ||
              result.hasPlausibleSingleEdgeFilletVolume(from: shape, edge: numbers[0].intValue, radius: input.value) else {
            reply(nil)
            return
        }
        reply(result.brepData())
    }
}
