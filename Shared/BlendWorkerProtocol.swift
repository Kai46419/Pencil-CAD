import Foundation

@objc protocol BlendWorkerProtocol {
    func compute(_ request: Data, withReply reply: @escaping (Data?) -> Void)
}

struct BlendWorkerRequest: Codable {
    /// Native BRep statt STEP, damit die Kantennummern beim Transfer erhalten bleiben.
    let shape: Data
    let edges: [Int]
    /// 0 Abrunden, 1 Fase, 2 Teilabrundung, 3 variabler Radius, 4 Fase mit zwei Abständen,
    /// 5 gemeinsame Rundung mit einem Radius je Kante,
    /// 6 Diagnose: Kanten, die OCCT nicht annimmt (second == 1: Fase). Antwort = JSON [Int] statt BRep.
    /// (Debug: 98/99 Absturztest.)
    let mode: Int
    let value: Double
    let second: Double?
    let start: Double?
    let stop: Double?
    let radii: [Double]?
    /// Build 42: Rundungsoptionen (Shared/BlendOptions.swift), nur Modus 0 und 5. nil bzw. Standard = wie bisher;
    /// ungültige Optionen bzw. Nicht-Standard in anderen Modi → Antwort nil. `var` mit Vorgabe, damit Anfragen ohne
    /// diesen Schlüssel dekodierbar bleiben und der Memberwise-Init ohne options weiter gilt.
    var options: BlendOptions? = nil
}
