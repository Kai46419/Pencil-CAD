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
        var parser = Parser(tokens: try tokenize(text), variables: variables)
        let value = try parser.parseSum()
        guard parser.isAtEnd else { throw ExpressionError("Unerwartetes Zeichen „\(parser.current.text)“.") }
        guard value.isFinite else { throw ExpressionError("Ergebnis ist keine Zahl.") }
        return value
    }

    /// Nur eine Zahl (ohne Rechenzeichen, Einheit oder Namen)?
    static func isPlainNumber(_ text: String) -> Bool {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) != nil
    }

    /// Namen, die im Ausdruck vorkommen (für Verknüpfungen mit Variablen).
    static func names(in text: String) -> Set<String> {
        guard let tokens = try? tokenize(text) else { return [] }
        return Set(tokens.compactMap { if case .name(let name) = $0.kind { return name } else { return nil } })
    }

    static let functionNames = ["sqrt", "abs", "round", "floor", "ceil", "min", "max", "avg", "mod", "sin", "cos", "tan",
                                "asin", "acos", "atan", "atan2", "radians", "degrees", "sign"]

    /// Gültiger Variablenname: Buchstaben, Ziffern, Unterstrich, nicht mit Ziffer beginnend, keine Funktion.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_", name.count < 100,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !functionNames.contains(name), !units.keys.contains(name), name != "pi", name != "e" else { return false }
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
        return values
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
            if c.isNumber || (c == "." && i + 1 < characters.count && characters[i + 1].isNumber) {
                var j = i
                var literal = ""
                var seenSeparator = false
                while j < characters.count {
                    let d = characters[j]
                    if d.isNumber {
                        literal.append(d)
                    } else if (d == "." || d == ","), !seenSeparator, j + 1 < characters.count, characters[j + 1].isNumber {
                        // Komma zwischen Ziffern ist ein Dezimalkomma; Argumente trennt „;“ oder „, “
                        seenSeparator = true
                        literal.append(".")
                    } else {
                        break
                    }
                    j += 1
                }
                guard let value = Double(literal) else { throw ExpressionError("Zahl „\(literal)“ ungültig.") }
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
            var value = try parsePower()
            while true {
                if accept("*") {
                    value *= try parsePower()
                } else if accept("/") {
                    let divisor = try parsePower()
                    guard divisor != 0 else { throw ExpressionError("Division durch 0.") }
                    value /= divisor
                } else if case .number = current.kind {
                    // „2 a“ oder „2(3+1)“: unsichtbares Mal
                    value *= try parsePower()
                } else if case .name = current.kind {
                    value *= try parsePower()
                } else if current.kind == .symbol("(") {
                    value *= try parsePower()
                } else {
                    break
                }
            }
            return value
        }

        mutating func parsePower() throws -> Double {
            let base = try parseUnary()
            if accept("^") { return pow(base, try parsePower()) }
            return base
        }

        mutating func parseUnary() throws -> Double {
            if accept("-") { return -(try parseUnary()) }
            if accept("+") { return try parseUnary() }
            return try parseUnit(try parsePrimary())
        }

        /// Einheit direkt nach einem Wert: „10 cm“, „30°“, „2 in“, „5"“; „%“ = Hundertstel.
        mutating func parseUnit(_ value: Double) throws -> Double {
            if accept("°") { return value }
            if accept("\"") { return value * 25.4 }
            if accept("'") { return value * 304.8 }
            if accept("%") { return value / 100 }
            if case .name(let name) = current.kind, let factor = Formula.units[name], variables[name] == nil {
                advance()
                return value * factor
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
                if current.kind == .symbol("(") {
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
