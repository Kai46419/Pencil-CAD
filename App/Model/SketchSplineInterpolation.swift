import Foundation
import simd

// Fit-Spline wie „Fit Point Spline“ in Fusion 360 bzw. die B-Spline-Interpolation in FreeCAD: eine natürliche
// kubische Spline läuft glatt durch alle Fit-Punkte. Es gibt keine vorgegebenen Start- oder Endtangenten, die
// Enden sind frei (Krümmung 0). Zwei Punkte ergeben eine Strecke, drei Punkte einen Bogen ohne Wendepunkt.
//
// Parametrisierung zentripetal (Knotenabstand = Wurzel der Sehnenlänge): Bei ungleichen Punktabständen schwingt
// die Kurve kaum über. Eigene Tangenten (Tangentengriffe) gehen als feste Ableitung in das Gleichungssystem ein,
// die übrigen Punkte passen sich daran an.
//
// Ergebnis ist eine Kette kubischer Bézierkurven (im Kurvenparameter zweimal stetig differenzierbar). Anzeige,
// Fang, Schneiden und Kernel (Pole als Bézierkette, Typ 2 in PCKShape) nutzen alle dieselben Pole aus
// fitBezierPoles – Skizze und Körper zeigen also dieselbe Kurve.
//
// Früher: gleichmäßige Catmull-Rom-Tangenten mit der Sehne zum Nachbarpunkt als Endtangente. Die Kurve startete
// damit genau in Sehnenrichtung und musste zuerst gegen die eigentliche Biegung krümmen – jede Spline begann mit
// einem kleinen Gegenbogen (S-Form), schon bei drei Punkten.

/// Exponent der Parametrisierung: 0,5 = zentripetal, 1 = Sehnenlänge, 0 = gleichmäßig.
private let fitSplineAlpha: Double = 0.5

/// Knotenabstände der Stücke i → i + 1 (geschlossen: n Stücke, offen: n − 1).
private func fitSplineIntervals(_ points: [Point2], closed: Bool) -> [Double] {
    let n = points.count
    let spans = closed ? n : n - 1
    guard spans > 0 else { return [] }
    var raw: [Double] = []
    raw.reserveCapacity(spans)
    for i in 0..<spans {
        let chord: Double = simd_distance(points[i], points[(i + 1) % n])
        raw.append(pow(chord, fitSplineAlpha))
    }
    let total: Double = raw.reduce(0, +)
    guard total > 1e-12, total.isFinite else { return Array(repeating: 1, count: spans) }
    // Doppelte Punkte: winziger Abstand statt Division durch null
    let minimum: Double = total * 1e-6
    return raw.map { max($0, minimum) }
}

/// Umrechnung zwischen Ableitung (nach dem Kurvenparameter) und Tangente in Hermite-Form (mm) am Punkt i:
/// Tangente = Ableitung · Faktor. An offenen Enden ist der Faktor der Knotenabstand des einzigen Stücks, der Pol
/// liegt dort also genau bei Punkt ± Tangente / 3. Innen ist es der Mittelwert beider Nachbarstücke.
private func fitSplineScale(_ h: [Double], index i: Int, count n: Int, closed: Bool) -> Double {
    if closed { return (h[(i - 1 + n) % n] + h[i]) / 2 }
    if i == 0 { return h[0] }
    if i == n - 1 { return h[n - 2] }
    return (h[i - 1] + h[i]) / 2
}

/// Tridiagonales System (Thomas-Verfahren): a = unter, b = auf, c = über der Diagonale, r = rechte Seite.
/// Die Systeme hier sind diagonal dominant, eine Pivotsuche ist nicht nötig.
private func solveTridiagonal(_ a: [Double], _ b: [Double], _ c: [Double], _ r: [Point2]) -> [Point2] {
    let n = b.count
    guard n > 0 else { return [] }
    var cp: [Double] = Array(repeating: 0, count: n)
    var rp: [Point2] = Array(repeating: .zero, count: n)
    cp[0] = c[0] / b[0]
    rp[0] = r[0] / b[0]
    if n > 1 {
        for i in 1..<n {
            let denominator: Double = b[i] - a[i] * cp[i - 1]
            cp[i] = i < n - 1 ? c[i] / denominator : 0
            let rest: Point2 = r[i] - rp[i - 1] * a[i]
            rp[i] = rest / denominator
        }
    }
    var x: [Point2] = Array(repeating: .zero, count: n)
    x[n - 1] = rp[n - 1]
    if n > 1 {
        for i in stride(from: n - 2, through: 0, by: -1) {
            x[i] = rp[i] - x[i + 1] * cp[i]
        }
    }
    return x
}

/// Zyklisch tridiagonales System (geschlossene Spline, n ≥ 3) per Sherman-Morrison: a[0] ist der Eintrag oben
/// rechts (Zeile 0, Spalte n − 1), c[n − 1] der unten links (Zeile n − 1, Spalte 0).
private func solveCyclicTridiagonal(_ a: [Double], _ b: [Double], _ c: [Double], _ r: [Point2]) -> [Point2] {
    let n = b.count
    guard n >= 3 else { return solveTridiagonal(a, b, c, r) }
    let beta: Double = a[0]
    let alpha: Double = c[n - 1]
    let gamma: Double = -b[0]
    var bb = b
    bb[0] = b[0] - gamma
    bb[n - 1] = b[n - 1] - alpha * beta / gamma
    var aa = a
    aa[0] = 0
    var cc = c
    cc[n - 1] = 0
    let x: [Point2] = solveTridiagonal(aa, bb, cc, r)
    var u: [Point2] = Array(repeating: .zero, count: n)
    u[0] = Point2(gamma, 0)
    u[n - 1] = Point2(alpha, 0)
    let z: [Double] = solveTridiagonal(aa, bb, cc, u).map { $0.x }
    let factor: Double = beta / gamma
    let fx: Point2 = x[0] + x[n - 1] * factor
    let fz: Double = 1 + z[0] + z[n - 1] * factor
    guard abs(fz) > 1e-300 else { return x }
    var result: [Point2] = []
    result.reserveCapacity(n)
    for i in 0..<n {
        let correction: Point2 = fx * (z[i] / fz)
        result.append(x[i] - correction)
    }
    return result
}

/// Ableitungen nach dem Kurvenparameter an allen Fit-Punkten (natürliche kubische Spline) und die Knotenabstände.
private func fitSplineDerivatives(_ points: [Point2], closed: Bool,
                                  tangents: [Point2?]?) -> (derivatives: [Point2], intervals: [Double]) {
    let n = points.count
    let h: [Double] = fitSplineIntervals(points, closed: closed)
    guard n >= 2, !h.isEmpty else { return (Array(repeating: .zero, count: n), h) }
    // Geschlossen mit zwei Punkten: kein sinnvoller Bogen, wie bisher hin und zurück
    if closed && n < 3 { return (Array(repeating: .zero, count: n), h) }
    var a: [Double] = Array(repeating: 0, count: n)
    var b: [Double] = Array(repeating: 0, count: n)
    var c: [Double] = Array(repeating: 0, count: n)
    var r: [Point2] = Array(repeating: .zero, count: n)
    for i in 0..<n {
        if let tangents, tangents.indices.contains(i), let custom = tangents[i] {
            // Eigene Tangente: Ableitung fest vorgegeben
            let scale: Double = fitSplineScale(h, index: i, count: n, closed: closed)
            b[i] = 1
            r[i] = custom / scale
            continue
        }
        if !closed && i == 0 {
            // Natürliches Ende: zweite Ableitung 0
            b[i] = 2
            c[i] = 1
            r[i] = (points[1] - points[0]) * (3 / h[0])
            continue
        }
        if !closed && i == n - 1 {
            a[i] = 1
            b[i] = 2
            r[i] = (points[i] - points[i - 1]) * (3 / h[i - 1])
            continue
        }
        // Innen: zweite Ableitung stetig
        let previous: Int = (i - 1 + n) % n
        let next: Int = (i + 1) % n
        let hp: Double = h[previous]
        let hn: Double = h[i]
        a[i] = hn
        b[i] = 2 * (hp + hn)
        c[i] = hp
        let back: Point2 = (points[i] - points[previous]) * (3 * hn / hp)
        let ahead: Point2 = (points[next] - points[i]) * (3 * hp / hn)
        r[i] = back + ahead
    }
    let derivatives: [Point2] = closed ? solveCyclicTridiagonal(a, b, c, r) : solveTridiagonal(a, b, c, r)
    return (derivatives, h)
}

/// Tangenten (Hermite-Form, in mm) aller Fit-Punkte: eigene Vorgabe (Tangentengriff), sonst aus der natürlichen
/// Spline. An offenen Enden liegt der Bézierpol bei Punkt ± Tangente / 3.
func fitSplineTangents(_ points: [Point2], closed: Bool, tangents: [Point2?]? = nil) -> [Point2] {
    let n = points.count
    guard n >= 2 else { return Array(repeating: .zero, count: n) }
    let solved = fitSplineDerivatives(points, closed: closed, tangents: tangents)
    var result: [Point2] = []
    result.reserveCapacity(n)
    for i in 0..<n {
        if let tangents, tangents.indices.contains(i), let custom = tangents[i] {
            result.append(custom)
            continue
        }
        let scale: Double = fitSplineScale(solved.intervals, index: i, count: n, closed: closed)
        result.append(solved.derivatives[i] * scale)
    }
    return result
}

/// Tangente (Hermite-Form, in mm) am Fit-Punkt i, siehe fitSplineTangents.
func fitSplineTangent(_ points: [Point2], closed: Bool, index i: Int, tangents: [Point2?]? = nil) -> Point2 {
    guard points.count >= 2, i >= 0, i < points.count else { return .zero }
    return fitSplineTangents(points, closed: closed, tangents: tangents)[i]
}

/// Tangenten der Stücke an jedem Fit-Punkt, bezogen auf den Parameter 0…1 des einzelnen Bézierstücks: incoming
/// für das Stück, das am Punkt endet (Pol = Punkt − incoming / 3), outgoing für das Stück, das dort beginnt
/// (Pol = Punkt + outgoing / 3). Wird ein Punkt beim Teilen zum Ende, bleibt die Kurve damit genau gleich.
/// Am Anfang einer offenen Spline ist incoming, am Ende outgoing ohne Bedeutung (dort die Endtangente).
func fitSplineSideTangents(_ points: [Point2], closed: Bool,
                           tangents: [Point2?]? = nil) -> (incoming: [Point2], outgoing: [Point2]) {
    let n = points.count
    guard n >= 2 else { return (Array(repeating: .zero, count: n), Array(repeating: .zero, count: n)) }
    let solved = fitSplineDerivatives(points, closed: closed, tangents: tangents)
    let h = solved.intervals
    var incoming: [Point2] = []
    var outgoing: [Point2] = []
    for i in 0..<n {
        let d: Point2 = solved.derivatives[i]
        let before: Double = closed ? h[(i - 1 + n) % n] : h[max(i - 1, 0)]
        let after: Double = closed ? h[i] : h[min(i, n - 2)]
        incoming.append(d * before)
        outgoing.append(d * after)
    }
    return (incoming, outgoing)
}

/// Pole einer Kette kubischer Bézierkurven durch die Punkte (natürliche Fit-Spline, siehe oben). tangents: je
/// Fit-Punkt optional eine eigene Tangente (nil = automatisch). Geschlossen endet die Kette wieder beim ersten Punkt.
func fitBezierPoles(_ points: [Point2], closed: Bool, tangents: [Point2?]? = nil) -> [Point2] {
    let n = points.count
    guard n >= 2 else { return points }
    let solved = fitSplineDerivatives(points, closed: closed, tangents: tangents)
    let d: [Point2] = solved.derivatives
    let h: [Double] = solved.intervals
    var poles: [Point2] = [points[0]]
    poles.reserveCapacity(3 * h.count + 1)
    for i in 0..<h.count {
        let j: Int = (i + 1) % n
        let third: Double = h[i] / 3
        let out: Point2 = points[i] + d[i] * third
        let into: Point2 = points[j] - d[j] * third
        poles += [out, into, points[j]]
    }
    return poles
}
