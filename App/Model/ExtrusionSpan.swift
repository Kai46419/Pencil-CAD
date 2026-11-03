import Foundation

enum ExtrudeDirection: String, CaseIterable, Identifiable {
    case oneSide = "Eine Seite"
    case symmetric = "Symmetrisch"
    case twoSides = "Zwei Seiten"

    var id: Self { self }
}

struct ExtrusionSpan {
    let start: Double
    let length: Double

    static func make(distance: Double, direction: ExtrudeDirection, secondDistance: Double,
                     sign: Double, isCut: Bool) -> ExtrusionSpan? {
        guard distance.isFinite, distance != 0, secondDistance.isFinite, sign == 1 || sign == -1 else { return nil }
        let main = sign * distance
        let start: Double
        let length: Double
        switch direction {
        case .oneSide:
            start = isCut ? (main >= 0 ? -0.01 : 0.01) : 0
            length = main - start
        case .symmetric:
            start = -main
            length = 2 * main
        case .twoSides:
            start = abs(secondDistance) * (main >= 0 ? -1 : 1)
            length = main - start
        }
        guard start.isFinite, length.isFinite, length != 0 else { return nil }
        return ExtrusionSpan(start: start, length: length)
    }
}
