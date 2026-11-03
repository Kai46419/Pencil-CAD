import Foundation

@objc protocol BlendWorkerProtocol {
    func compute(_ request: Data, withReply reply: @escaping (Data?) -> Void)
}

struct BlendWorkerRequest: Codable {
    /// Native BRep statt STEP, damit die Kantennummern beim Transfer erhalten bleiben.
    let shape: Data
    let edges: [Int]
    /// 0 Abrunden, 1 Fase, 2 Teilabrundung, 3 variabler Radius, 4 Fase mit zwei Abständen,
    /// 5 gemeinsame Rundung mit einem Radius je Kante.
    let mode: Int
    let value: Double
    let second: Double?
    let start: Double?
    let stop: Double?
    let radii: [Double]?
}
