import Foundation

// Formeln in Zahlenfeldern wie bei Shapr3D bzw. Fusion 360: „10 + 2*3“, „(40 - 2 × wand) / 2“, „1,5 cm“,
// „sqrt(2) * a“, „30 deg“. Längen werden in mm, Winkel in Grad gerechnet.

/// Benannter Wert des Projekts (Einfügen › Variable). Der Ausdruck darf andere Variablen verwenden.
struct ProjectVariable: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var expression: String
}

struct ExpressionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Formula {
    /// Wert eines Ausdrucks. variables: Name → Wert (mm bzw. Grad).
    static func evaluate(_ text: String, variables: [String: Double] = [:]) throws -> Double {
        try evaluate(text, variables: variables, lengthScale: 1)
    }

    /// Wie oben, Längeneinheiten aber geteilt durch lengthScale (mm je Projekteinheit, siehe evaluateLength).
    static func evaluate(_ text: String, variables: [String: Double], lengthScale: Double) throws -> Double {
        guard lengthScale.isFinite, lengthScale > 0 else { throw ExpressionError("Ungültige Längeneinheit.") }
        var parser = Parser(tokens: try tokenize(text), variables: variables, lengthScale: lengthScale)
        let value = try parser.parseSum()
        guard parser.isAtEnd else { throw ExpressionError("Unerwartetes Zeichen „\(parser.current.text)“.") }
        guard value.isFinite else { throw ExpressionError("Ergebnis ist keine Zahl.") }
        return value
    }

    /// Nur eine Zahl (ohne Rechenzeichen, Einheit oder Namen)?
    static func isPlainNumber(_ text: String) -> Bool {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))?.isFinite == true
    }

    /// Namen, die im Ausdruck vorkommen (für Verknüpfungen mit Variablen).
    static func names(in text: String) -> Set<String> {
        guard let tokens = try? tokenize(text) else { return [] }
        return Set(tokens.compactMap { if case .name(let name) = $0.kind { return name } else { return nil } })
    }

    static let functionNames = ["sqrt", "abs", "round", "floor", "ceil", "min", "max", "avg", "mod", "sin", "cos", "tan",
                                "asin", "acos", "atan", "atan2", "radians", "degrees", "sign",
                                "ceiling", "mean", "tg", "arcsin", "arccos", "arctan", "arctan2"]

    /// Gültiger Variablenname: Buchstaben, Ziffern, Unterstrich, nicht mit Ziffer beginnend, keine Funktion.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_", name.count < 100,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !functionNames.contains(name), !units.keys.contains(name), name != "pi", name != "π", name != "e" else { return false }
        return true
    }

    /// Werte aller Variablen; Variablen dürfen sich gegenseitig verwenden (ohne Kreis).
    static func resolve(_ variables: [ProjectVariable]) -> [String: Double] {
        var values: [String: Double] = [:]
        var visiting = Set<String>()
        let byName = Dictionary(variables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func value(of name: String) -> Double? {
            if let known = values[name] { return known }
            guard let variable = byName[name], !visiting.contains(name) else { return nil }
            visiting.insert(name)
            defer { visiting.remove(name) }
            var context: [String: Double] = [:]
            for other in names(in: variable.expression) where other != name {
                if let v = value(of: other) { context[other] = v }
            }
            guard let result = try? evaluate(variable.expression, variables: context) else { return nil }
            values[name] = result
            return result
        }
        for variable in variables { _ = value(of: variable.name) }
        unitlessVariableNames = unitlessNames(variables)
        return values
    }

    /// Build 41 (schwacher Bugfix 3): Variablen ohne Längenbezug. Variablen sind nicht typisiert (nur Name und
    /// Ausdruck, Werte als Double); als Länge gilt eine Variable, deren Ausdruck eine Längeneinheit (mm, cm, m, in, ft,
    /// " bzw. ') oder eine Längenvariable enthält. Die übrigen („n = 4“, „faktor = 1,5“) sind reine Zahlen:
    /// evaluateLength teilt sie nicht durch die Projekteinheit (im Zollprojekt war „abstand * n“ sonst um 25,4 falsch).
    /// Gesetzt von resolve (ModelStore.variableValues ruft es vor jeder Auswertung auf).
    private(set) static var unitlessVariableNames: Set<String> = []

    static func unitlessNames(_ variables: [ProjectVariable]) -> Set<String> {
        let byName = Dictionary(variables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var known: [String: Bool] = [:]
        var visiting = Set<String>()
        func isLength(_ name: String) -> Bool {
            if let cached = known[name] { return cached }
            guard let variable = byName[name], !visiting.contains(name),
                  let tokens = try? tokenize(variable.expression) else { return false }
            visiting.insert(name)
            defer { visiting.remove(name) }
            let result = tokens.contains { token in
                switch token.kind {
                case .symbol(let symbol):
                    return symbol == "\"" || symbol == "'"
                case .name(let other):
                    if byName[other] != nil { return other != name && isLength(other) }
                    return ["mm", "cm", "m", "in", "ft"].contains(other)
                default:
                    return false
                }
            }
            known[name] = result
            return result
        }
        return Set(variables.map(\.name).filter { !isLength($0) })
    }

    // MARK: Zerlegen

    fileprivate struct Token {
        enum Kind: Equatable {
            case number(Double)
            case name(String)
            case symbol(Character)
            case end
        }
        var kind: Kind
        var text: String
    }

    /// Einheiten in mm bzw. Grad
    fileprivate static let units: [String: Double] = [
        "mm": 1, "cm": 10, "m": 1000, "in": 25.4, "ft": 304.8, "deg": 1, "rad": 180 / .pi,
    ]

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c.isNumber || ((c == "." || c == ",") && i + 1 < characters.count && characters[i + 1].isNumber) {
                var j = i
                var literal = ""
                var seenSeparator = false
                while j < characters.count {
                    let d = characters[j]
                    if d.isNumber {
                        literal.append(d)
                    } else if (d == "." || d == ","), j + 1 < characters.count, characters[j + 1].isNumber {
                        // Komma zwischen Ziffern ist ein Dezimalkomma; Argumente trennt „;“ oder „, “
                        guard !seenSeparator else {
                            // Build 41: „1,5,3“ war still 1,5 · 0,3 (unsichtbares Mal) – jetzt ein Fehler
                            throw ExpressionError("Zahl „\(String(characters[i...j]))…“ hat zwei Dezimalzeichen; "
                                + "Werte mit „;“ trennen.")
                        }
                        seenSeparator = true
                        literal.append(".")
                    } else {
                        break
                    }
                    j += 1
                }
                if j < characters.count, characters[j] == "e" || characters[j] == "E" {
                    var exponentEnd = j + 1
                    if exponentEnd < characters.count, characters[exponentEnd] == "+" || characters[exponentEnd] == "-" {
                        exponentEnd += 1
                    }
                    let digitStart = exponentEnd
                    while exponentEnd < characters.count, characters[exponentEnd].isNumber { exponentEnd += 1 }
                    if exponentEnd > digitStart {
                        literal += String(characters[j..<exponentEnd])
                        j = exponentEnd
                    } else {
                        // Build 41: „2e“ bzw. „2e+“ ohne Ziffern war still 2·e (5,44). Folgt dem e ein weiterer
                        // Buchstabe, ist es ein Name („2eps“ = 2·eps) und bleibt erlaubt.
                        let signed = digitStart > j + 1
                        let next = j + 1 < characters.count ? characters[j + 1] : " "
                        if signed || !(next.isLetter || next.isNumber || next == "_") {
                            throw ExpressionError("Zahl „\(String(characters[i..<digitStart]))“: Exponent fehlt "
                                + "(für das Produkt mit e „*e“ schreiben).")
                        }
                    }
                }
                guard let value = Double(literal), value.isFinite else { throw ExpressionError("Zahl „\(literal)“ ungültig.") }
                tokens.append(Token(kind: .number(value), text: literal))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                var name = ""
                while j < characters.count, characters[j].isLetter || characters[j].isNumber || characters[j] == "_" {
                    name.append(characters[j])
                    j += 1
                }
                tokens.append(Token(kind: .name(name), text: name))
                i = j
                continue
            }
            switch c {
            case "+", "-", "−", "*", "×", "·", "/", "÷", "(", ")", ";", ",", "^", "°", "\"", "'", "%":
                let normalized: Character = switch c {
                case "−": "-"
                case "×", "·": "*"
                case "÷": "/"
                default: c
                }
                tokens.append(Token(kind: .symbol(normalized), text: String(c)))
                i += 1
            default:
                throw ExpressionError("Zeichen „\(c)“ ist nicht erlaubt.")
            }
        }
        tokens.append(Token(kind: .end, text: ""))
        return tokens
    }

    // MARK: Rechnen

    /// Rekursiver Abstieg: Summe → Produkt → Potenz → Vorzeichen → Wert (mit Einheit).
    private struct Parser {
        let tokens: [Token]
        let variables: [String: Double]
        /// mm je Projekteinheit: „10 mm“ im Zollprojekt ergibt 10 / 25,4
        let lengthScale: Double
        var index = 0

        var current: Token { tokens[min(index, tokens.count - 1)] }
        var isAtEnd: Bool { current.kind == .end }

        mutating func advance() { index += 1 }

        mutating func accept(_ symbol: Character) -> Bool {
            if current.kind == .symbol(symbol) {
                advance()
                return true
            }
            return false
        }

        mutating func parseSum() throws -> Double {
            var value = try parseProduct()
            while true {
                if accept("+") { value += try parseProduct() } else if accept("-") { value -= try parseProduct() } else { break }
            }
            return value
        }

        mutating func parseProduct() throws -> Double {
            var value = try parseUnary()
            while true {
                if accept("*") {
                    value *= try parseUnary()
                } else if accept("/") {
                    let divisor = try parseUnary()
                    guard divisor != 0 else { throw ExpressionError("Division durch 0.") }
                    value /= divisor
                } else if case .number = current.kind {
                    // „2 a“ oder „2(3+1)“: unsichtbares Mal
                    value *= try parseUnary()
                } else if case .name = current.kind {
                    value *= try parseUnary()
                } else if current.kind == .symbol("(") {
                    value *= try parseUnary()
                } else {
                    break
                }
            }
            return value
        }

        mutating func parsePower() throws -> Double {
            let base = try parseUnit(try parsePrimary())
            if accept("^") { return pow(base, try parseUnary()) }
            return base
        }

        mutating func parseUnary() throws -> Double {
            if accept("-") { return -(try parseUnary()) }
            if accept("+") { return try parseUnary() }
            return try parsePower()
        }

        /// Einheit direkt nach einem Wert: „10 cm“, „30°“, „2 in“, „5"“; „%“ = Hundertstel.
        mutating func parseUnit(_ value: Double) throws -> Double {
            if accept("°") { return value }
            if accept("\"") { return value * 25.4 / lengthScale }
            if accept("'") { return value * 304.8 / lengthScale }
            if accept("%") { return value / 100 }
            if case .name(let name) = current.kind, let factor = Formula.units[name], variables[name] == nil {
                advance()
                let isAngle = name == "deg" || name == "rad"
                return value * (isAngle ? factor : factor / lengthScale)
            }
            return value
        }

        mutating func parsePrimary() throws -> Double {
            switch current.kind {
            case .number(let value):
                advance()
                return value
            case .symbol("("):
                advance()
                let value = try parseSum()
                guard accept(")") else { throw ExpressionError("Schließende Klammer fehlt.") }
                return value
            case .name(let name):
                advance()
                if current.kind == .symbol("("), Formula.functionNames.contains(name) {
                    advance()
                    var arguments: [Double] = []
                    if !accept(")") {
                        repeat { arguments.append(try parseSum()) } while accept(";") || accept(",")
                        guard accept(")") else { throw ExpressionError("Schließende Klammer fehlt.") }
                    }
                    return try call(name, arguments)
                }
                if let value = variables[name] { return value }
                switch name {
                case "pi", "π": return .pi
                case "e": return M_E
                default: throw ExpressionError("„\(name)“ ist keine Variable.")
                }
            case .end:
                throw ExpressionError("Ausdruck unvollständig.")
            default:
                throw ExpressionError("Unerwartetes „\(current.text)“.")
            }
        }

        /// Winkelfunktionen rechnen in Grad (wie die Winkelfelder der App).
        func call(_ name: String, _ a: [Double]) throws -> Double {
            guard a.allSatisfy(\.isFinite) else { throw ExpressionError("Funktionsargument ist keine endliche Zahl.") }
            func need(_ count: Int) throws {
                guard a.count == count else { throw ExpressionError("\(name) braucht \(count) Wert\(count == 1 ? "" : "e").") }
            }
            let toRadians = Double.pi / 180
            switch name {
            case "sqrt":
                try need(1)
                guard a[0] >= 0 else { throw ExpressionError("Wurzel aus negativer Zahl.") }
                return a[0].squareRoot()
            case "abs": try need(1); return abs(a[0])
            case "sign": try need(1); return a[0] > 0 ? 1 : a[0] < 0 ? -1 : 0
            case "round": try need(1); return a[0].rounded()
            case "floor": try need(1); return a[0].rounded(.down)
            case "ceil", "ceiling": try need(1); return a[0].rounded(.up)
            case "min":
                guard !a.isEmpty else { throw ExpressionError("min braucht Werte.") }
                return a.min()!
            case "max":
                guard !a.isEmpty else { throw ExpressionError("max braucht Werte.") }
                return a.max()!
            case "avg", "mean":
                guard !a.isEmpty else { throw ExpressionError("avg braucht Werte.") }
                return a.reduce(0, +) / Double(a.count)
            case "mod":
                try need(2)
                guard a[1] != 0 else { throw ExpressionError("mod durch 0.") }
                return a[0].truncatingRemainder(dividingBy: a[1])
            case "sin": try need(1); return sin(a[0] * toRadians)
            case "cos": try need(1); return cos(a[0] * toRadians)
            case "tan", "tg": try need(1); return tan(a[0] * toRadians)
            case "asin", "arcsin": try need(1); return asin(a[0]) / toRadians
            case "acos", "arccos": try need(1); return acos(a[0]) / toRadians
            case "atan", "arctan": try need(1); return atan(a[0]) / toRadians
            case "atan2", "arctan2": try need(2); return atan2(a[0], a[1]) / toRadians
            case "radians": try need(1); return a[0] * toRadians
            case "degrees": try need(1); return a[0] / toRadians
            default: throw ExpressionError("Funktion „\(name)“ unbekannt.")
            }
        }
    }
}
