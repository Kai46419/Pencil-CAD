import SwiftUI

// Kurze Werkzeugerklärung (Kai: „man weiß gar nicht, was das Werkzeug macht“): beim Öffnen eines Werkzeugs
// erscheint unten eine kleine Kapsel mit einem Satz und – wo es hilft – einer Mini-Grafik vorher → nachher.
// Sie verschwindet nach einigen Sekunden oder beim Antippen. Lange drücken auf eine Werkzeugkachel zeigt sie erneut.

/// Inhalt der Kapsel.
struct ToolExplanation: Equatable {
    var id = UUID()
    var title: String
    var text: String
    /// SF Symbols für vorher → nachher (nil = nur Text)
    var before: String?
    var after: String?
}

enum ToolExplainer {
    /// Ein Satz je Werkzeug; nil = keine Kapsel (Auswahl).
    static func text(for tool: ModelTool) -> String? {
        switch tool {
        case .select:
            return nil
        case .insert(let primitive):
            return "\(primitive.rawValue): auf eine Ebene oder Fläche tippen, Maße unten eingeben oder am Pfeil ziehen."
        case .part(let kind):
            return partText(kind)
        case .boolean(.union):
            return "Körper antippen: sie verschmelzen zu einem einzigen Körper."
        case .boolean(.subtract):
            return "Erst den Körper antippen, der bleibt (Ziel), dann die Werkzeugkörper – die Vorschau zeigt das "
                + "Ergebnis, Werkzeuge rot. Mit Spiel wird die Aussparung etwas größer, damit das Teil hineinpasst."
        case .boolean(.intersect):
            return "Körper antippen: übrig bleibt nur der Bereich, in dem sie sich überlappen."
        case .move:
            return "Körper oder Skizze antippen, an den farbigen Pfeilen verschieben bzw. an den Bögen drehen "
                + "(rastet alle 15°) – mit „Kopieren“ wird eine Kopie bewegt, das Original bleibt stehen."
        case .mirror:
            return "Körper antippen, dann die Spiegelebene oder ebene Fläche – es entsteht ein gespiegeltes Gegenstück."
        case .shell:
            return "Fläche antippen, die offen sein soll: der Körper wird hohl, mit der eingestellten Wandstärke."
        case .color:
            return "Körper antippen und Farbe bzw. Material wählen."
        case .pattern(.linear):
            return "Körper antippen: er wird in einer Reihe vervielfältigt (Anzahl, Abstand, Richtung)."
        case .pattern(.circular):
            return "Körper antippen: er wird rund um eine Achse vervielfältigt (Anzahl, Winkel)."
        case .scale:
            return "Körper antippen und am Pfeil ziehen oder Faktor eingeben – immer gleichmäßig um die Mitte."
        case .align:
            return "Körper antippen und an einem anderen ausrichten (bündig, mittig)."
        case .revolve:
            return "Skizzenbereich antippen, dann die Achse: der Bereich wird zu einem Drehkörper."
        case .sweep:
            return "Skizzenbereich antippen, dann einen Pfad: das Profil wird entlang des Pfads geführt."
        case .loft:
            return "Mehrere Querschnitte nacheinander antippen: dazwischen entsteht ein fließender Körper."
        case .split:
            return "Körper antippen, dann Ebene, Körper oder Skizze: der Körper wird daran in Teile getrennt."
        case .section:
            return "Schneidet die Ansicht auf, damit man hineinsieht – am Pfeil ziehen führt den Schnitt durch den "
                + "Körper. Am Modell ändert sich nichts."
        case .measure:
            return "Kante, Fläche oder zwei Punkte antippen: Länge, Fläche, Radius oder Abstand erscheinen unten."
        case .construct(let kind):
            return "Hilfs-\(kind.rawValue) erstellen, z. B. als Bezug zum Skizzieren – sie wird nicht gedruckt."
        case .canvas:
            return "Bild als Vorlage: auf Maß kalibrieren und darauf nachzeichnen."
        case .scaleSketch:
            return "Ganze Skizze um einen Faktor vergrößern oder verkleinern."
        case .offsetEdges:
            return "Ebene Fläche antippen: ihre Umrandung wird als neue Skizze nach innen oder außen versetzt."
        case .offsetFace:
            return "Flächen antippen: sie wandern senkrecht nach außen oder innen, die Nachbarflächen wachsen mit."
        case .replaceFace:
            return "Flächen antippen, dann eine Zielfläche: die Flächen werden bis an deren Ebene verlängert oder gekürzt."
        case .wrap:
            return "Text oder Logo (Skizzenbereich) antippen, dann eine Zylinderfläche: das Motiv wird herumgelegt und geprägt."
        case .imprint:
            return "Skizzenbereiche auf einer Fläche werden zu Kanten im Körper – danach lässt sich der Teil einzeln ziehen."
        case .translate:
            return "Körper antippen, dann Start- und Zielpunkt: er wandert genau diese Strecke (mit „Kopieren“ als Kopie)."
        case .hole:
            return "Fläche antippen (eben oder gewölbt): Bohrung für Schraube, Gewindeeinsatz oder mit Gewinde, Senkung wählbar."
        case .printCheck:
            return "Zeigt Überhänge, zu dünne Wände und eine gute Druckausrichtung für den 3D-Druck."
        case .meshSculpt:
            return "Körper antippen und mit dem Stift darüberstreichen: anheben, absenken, glätten oder abflachen (Netze aus STL/3MF)."
        case .mold:
            return "Körper antippen: ein Block mit Rand entsteht um ihn, der Körper wird mit Spiel herausgeschnitten – "
                + "wahlweise in zwei Formhälften geteilt. Der Körper selbst bleibt erhalten."
        }
    }

    private static func partText(_ kind: PartTool) -> String? {
        switch kind {
        case .standard: "Schrauben, Muttern, Scheiben oder Lager nach Norm einfügen."
        case .template: "Fertige Vorlagen wie Gehäuse oder Zahnrad einfügen und anpassen."
        case .helix: "Feder oder Spirale um eine Achse erzeugen."
        case .thread: "Bolzen bekommen ein Außen-, Bohrungen ein Innengewinde nach Norm; jede andere Fläche eine Gewindebohrung am Tippunkt."
        case .thinLines: "Skizzenlinien (auch offene) werden zu einer Wand mit fester Dicke."
        case .draft: "Seitenflächen antippen: sie werden um einen Winkel geneigt (Entformungsschräge)."
        }
    }

    /// Mini-Grafik vorher → nachher, wo sie die Wirkung klarer macht.
    static func symbols(for tool: ModelTool) -> (before: String, after: String)? {
        switch tool {
        case .boolean(.union): ("square.on.square", "square.fill")
        case .boolean(.subtract): ("square.on.square", "square.bottomhalf.filled")
        case .shell: ("cube.fill", "shippingbox")
        case .mirror: ("cube", "square.split.2x1")
        case .scale: ("cube", "arrow.up.left.and.arrow.down.right")
        case .offsetFace: ("square", "arrow.up.and.down.square")
        case .hole: ("square.fill", "circle.circle")
        case .pattern(.linear): ("square", "square.grid.3x1.below.line.grid.1x2")
        case .pattern(.circular): ("circle", "circle.grid.cross")
        case .split: ("cube", "square.split.diagonal")
        case .part(.thread): ("cylinder", "barcode")
        case .meshSculpt: ("triangle", "paintbrush.pointed")
        case .mold: ("cube.fill", "cube.transparent")
        default: nil
        }
    }

    static func explanation(for tool: ModelTool) -> ToolExplanation? {
        guard let text = text(for: tool) else { return nil }
        let pair = symbols(for: tool)
        return ToolExplanation(title: tool.title, text: text, before: pair?.before, after: pair?.after)
    }
}

extension Workspace {
    /// Kapsel zeigen und nach einigen Sekunden wieder ausblenden.
    func explain(_ explanation: ToolExplanation?) {
        withAnimation(Theme.spring) { toolExplanation = explanation }
        guard let id = explanation?.id else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard let self, self.toolExplanation?.id == id else { return }
            withAnimation(Theme.spring) { self.toolExplanation = nil }
        }
    }
}

/// Kleine Erklärkapsel unten (antippen schließt).
struct ToolExplainerCapsule: View {
    let explanation: ToolExplanation
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            HStack(spacing: 8) {
                if let before = explanation.before, let after = explanation.after {
                    HStack(spacing: 3) {
                        Image(systemName: before)
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Image(systemName: after)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.callout)
                }
                Text(explanation.title)
                    .fontWeight(.semibold)
                Text(explanation.text)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 640)
            .floatingSurface(in: Capsule(), elevation: .floating)
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityLabel("\(explanation.title): \(explanation.text)")
    }
}
