import SwiftUI

// Infos beim Schweben: Schwebt der Apple Pencil (oder der Mauszeiger) über einem Symbol, erscheint nach
// kurzer Zeit ein Schild mit Name und Erklärung des Werkzeugs – wie die Tooltips in Fusion 360.
// Die Schilder zeichnet WorkspaceView über allem (hoverTipLayer), damit sie nicht abgeschnitten werden.

/// Ein sichtbares Schild mit der Lage des Symbols, über dem der Stift schwebt.
struct HoverTipEntry {
    let title: String
    let detail: String?
    let anchor: Anchor<CGRect>
}

struct HoverTipPreference: PreferenceKey {
    static var defaultValue: [HoverTipEntry] = []

    static func reduce(value: inout [HoverTipEntry], nextValue: () -> [HoverTipEntry]) {
        value += nextValue()
    }
}

private struct HoverTipModifier: ViewModifier {
    let title: String
    let detail: String?

    @State private var isShown = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                task?.cancel()
                if hovering {
                    task = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) { isShown = true }
                    }
                } else {
                    task = nil
                    withAnimation(.easeOut(duration: 0.1)) { isShown = false }
                }
            }
            .onDisappear {
                task?.cancel()
                isShown = false
            }
            .anchorPreference(key: HoverTipPreference.self, value: .bounds) { anchor in
                isShown ? [HoverTipEntry(title: title, detail: detail, anchor: anchor)] : []
            }
    }
}

extension View {
    /// Schild beim Schweben. Ohne detail wird die Erklärung aus ToolTips genommen (falls vorhanden).
    func hoverTip(_ title: String, _ detail: String? = nil) -> some View {
        modifier(HoverTipModifier(title: title, detail: detail ?? ToolTips.detail(for: title)))
    }

    /// Ebene, auf der die Schilder liegen (einmal ganz außen im Arbeitsbereich).
    func hoverTipLayer() -> some View {
        overlayPreferenceValue(HoverTipPreference.self) { entries in
            GeometryReader { proxy in
                if let entry = entries.last {
                    HoverTipBubble(title: entry.title, detail: entry.detail, target: proxy[entry.anchor],
                                   bounds: proxy.size)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Schild neben dem Symbol: links davon, wenn das Symbol rechts liegt (rechte Leiste), sonst rechts,
/// im unteren Bereich darüber.
private struct HoverTipBubble: View {
    let title: String
    let detail: String?
    let target: CGRect
    let bounds: CGSize

    private let gap: CGFloat = 10
    private let margin: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            bubble
                .alignmentGuide(.leading) { d in -originX(width: d.width) }
                .alignmentGuide(.top) { d in -originY(height: d.height) }
        }
        .transition(.opacity)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .fixedSize()
    }

    private var isLow: Bool { target.minY > bounds.height * 0.72 }

    private func originX(width: CGFloat) -> CGFloat {
        let x: CGFloat
        if isLow {
            x = target.midX - width / 2
        } else if target.midX > bounds.width / 2 {
            x = target.minX - gap - width
        } else {
            x = target.maxX + gap
        }
        return min(max(x, margin), max(bounds.width - width - margin, margin))
    }

    private func originY(height: CGFloat) -> CGFloat {
        let y = isLow ? target.minY - gap - height : target.midY - height / 2
        return min(max(y, margin), max(bounds.height - height - margin, margin))
    }
}

/// Erklärungen zu Werkzeugen und Symbolen (Schlüssel = angezeigter Name).
enum ToolTips {
    static func detail(for title: String) -> String? {
        texts[title]
    }

    private static let texts: [String: String] = [
        // Werkzeuggruppen (3D)
        "Skizze": "Neue Skizze beginnen: Ebene oder ebene Körperfläche antippen, dann mit dem Stift zeichnen.",
        "Einfügen": "Grundkörper (Quader, Zylinder, Kugel …), STEP-Datei oder ein Bild als Vorlage einfügen.",
        "Konstruieren": "Hilfsebenen, -achsen und -punkte, z. B. eine versetzte Ebene zum Skizzieren.",
        "Transformation": "Körper oder Skizzen verschieben, drehen, spiegeln, skalieren, ausrichten oder als Muster vervielfältigen.",
        "Tools": "Kanten abrunden/fasen, Schale, boolesche Verknüpfung, Drehen, Sweep, Loft, Körper teilen.",
        "Visualisieren": "Anzeigemodus, Farbe, Schnittansicht, Messen und Isolieren.",
        "Extrudieren": "Geschlossenen Skizzenbereich oder ebene Fläche antippen und am Pfeil ziehen bzw. Abstand eingeben.",
        "Ebenen": "Browser wie in Fusion 360: Skizzen mit den Körpern daraus, Konstruktion und Bilder – ein- und ausblenden, wählen, bearbeiten.",
        // Skizzenmodus links
        "Skizzieren beenden": "Skizze übernehmen und zurück ins 3D-Modell. Geschlossene Bereiche lassen sich danach extrudieren.",
        "Auswählen": "Pfeil: zeichnet nicht. Antippen wählt, Ecken und Enden ziehen ändert die Größe, Linien ziehen verschiebt, Kreisrand ziehen ändert den Radius. Stift über einem Punkt schweben lassen und drücken (bzw. doppeltippen) merkt ihn – zwei gemerkte Punkte zeigen Mitte und Mittellinie.",
        "Aktive Ebene": "Ebene, auf der gerade gezeichnet wird.",
        "Keine aktive Ebene": "Erst eine Ebene (grau) oder eine ebene Körperfläche antippen.",
        "Linie/Bogen": "Linie: Punkt für Punkt ziehen, zurück zum Start schließt. Rund gezogen wird automatisch ein Kreis (geschlossen) oder Bogen. Kritzeln über Elemente löscht sie.",
        "Linie": "Punkt für Punkt ziehen; Länge und Winkel werden angezeigt. Rund ziehen ergibt einen Kreis bzw. Bogen, Kritzeln löscht. Zurück zum Startpunkt schließt das Profil.",
        "Bogen": "Von einem Ende zum anderen ziehen, dann die Wölbung ziehen.",
        "Spline": "Freie Kurve durch Punkte (Fit-Punkte) oder über Kontrollpunkte.",
        "Rechteck": "Diagonal, von der Mitte aus oder über drei Punkte (gedreht).",
        "Kreis": "Von der Mitte nach außen ziehen. Graue Zeichen zeigen Mitten von Rechtecken, Kreisen und Linien zum Einrasten. Beim Aufziehen rastet der Radius tangential an Linien/Kreise, auf gleichen Radius oder durch Punkte ein – die Abhängigkeit wird als Einschränkung gesetzt.",
        "Ellipse": "Von der Mitte zur Ecke ziehen – Breite und Höhe ergeben sich daraus.",
        "Polygon": "Regelmäßiges Vieleck von der Mitte aus; Eckenzahl unten einstellen.",
        "Projizieren": "Körperkanten oder Flächenränder in die Skizze übernehmen.",
        "Kante versetzen": "Kontur oder Kurve antippen und um einen Abstand parallel versetzen.",
        "Mehr": "Weitere Werkzeuge: Punkt, Text, Skalieren.",
        "Punkt": "Einzelnen Punkt setzen, z. B. als Bezug für Einschränkungen.",
        "Text": "Schrift als Profil, das sich extrudieren lässt.",
        "Skalieren": "Auswahl oder ganze Skizze um einen Faktor vergrößern bzw. verkleinern.",
        "Abrunden": "Skizze: Ecke antippen, an der zwei Linien zusammenstoßen – sie wird mit dem eingestellten Radius gerundet. 3D: Kanten wählen und abrunden.",
        "Fase": "Kanten wählen und um einen Abstand abschrägen.",
        "Beschneiden": "Kurvenstück antippen – es wird bis zu den nächsten Schnittpunkten entfernt.",
        "Löschen": "Gewählte Elemente löschen.",
        "Konstruktion": "Neue Elemente als Konstruktionsgeometrie (gestrichelt, kein Profil).",
        "Schnittansicht": "Schneidet das Modell an der Skizzenebene auf, damit man hineinsieht.",
        // Rechte Leiste
        "Fang": "Magnet: rastet auf Enden, Mitten, Zentren, Schnittpunkte, Raster und Winkel ein.",
        "Raster": "Rastermaß für den Fang, bis 0,001 mm.",
        "Normal zu Skizze": "Senkrecht auf die Skizzenebene schauen.",
        "Finger zeichnet": "Für Geräte ohne Stift: ein Finger zeichnet statt zu drehen.",
        "Anzeigemodi": "Schattiert, mit Kanten, Drahtgitter, durchsichtig; orthografisch oder perspektivisch.",
        "Screenshot": "Bild des Arbeitsbereichs sichern oder teilen.",
        "Verlauf": "Alle Schritte; antippen springt zurück (Rückgängig/Wiederholen).",
        "Sichtbarkeit": "Alle Skizzen, Bilder oder Konstruktionsgeometrie gesammelt ein- und ausblenden.",
        "Einschränkungen": "Regeln zwischen Skizzenelementen. Erst Einschränkung antippen, dann die Elemente – sie wird gesetzt, sobald die Auswahl passt.",
        "Skizzenpalette": "Was in der Skizze angezeigt wird: Profile, Punkte, Bemaßungen, Einschränkungen, Konstruktion, Raster.",
        "Einpassen": "Ganzes Modell in den Bildschirm einpassen.",
        // Einschränkungen
        "Parallel": "Zwei oder mehr Linien laufen in dieselbe Richtung. Wählen: Linien.",
        "Senkrecht": "Zwei Linien stehen im rechten Winkel (90°). Wählen: zwei Linien.",
        "Tangential": "Linie berührt Kreis/Bogen ohne Knick, oder zwei Kreise berühren sich. Wählen: Linie + Kreis oder zwei Kreise.",
        "Zusammenfallend": "Zwei Punkte liegen aufeinander, oder ein Punkt liegt auf einer Kurve. Wählen: Punkt + Punkt oder Punkt + Kurve.",
        "Mittelpunkt": "Ein Punkt sitzt genau in der Mitte einer Linie. Wählen: Punkt + Linie.",
        "Konzentrisch": "Kreise oder Bögen haben dieselbe Mitte. Wählen: zwei oder mehr Kreise/Bögen.",
        "Horizontal/Vertikal": "Linie wird waagrecht bzw. senkrecht (je nachdem, was näher liegt); auch für zwei Punkte. Wählen: Linie(n) oder zwei Punkte.",
        "Gleich": "Gleiche Länge bzw. gleicher Radius. Wählen: zwei Linien oder zwei Kreise/Bögen.",
        "Symmetrien": "Zwei Punkte oder Elemente spiegelbildlich zu einer Achse. Wählen: zwei Punkte/Elemente, zuletzt die Achse (Linie).",
        "Trennen": "Löst Einschränkungen an der Auswahl, z. B. trennt zusammenhängende Ecken, damit sie einzeln verschoben werden können.",
        "Sperren": "Fixiert Punkte oder Kurven an ihrer Stelle; sie bewegen sich beim Ändern anderer Elemente nicht mehr.",
        "Konstruktion erstellen": "Macht die Auswahl zu Konstruktionsgeometrie (gestrichelte Hilfslinien, zählen nicht als Profil). Nochmal: zurück.",
        // Extrudieren
        "Neuer Körper": "Erzeugt einen eigenen, neuen Körper.",
        "Vereinigen": "Verschmilzt zu einem Körper: beim Extrudieren mit dem vorhandenen Körper, in der Auswahl alle gewählten Körper.",
        // Kontextleiste (Auswahl)
        "Alle abwählen": "Hebt die ganze Auswahl auf (wie Tippen ins Leere).",
        "Verschieben/Rotieren": "Körper bzw. Skizze an den farbigen Achsenpfeilen verschieben oder Werte eintippen.",
        "Achse senkrecht": "Erstellt sofort eine Hilfsachse durch die Mitte der gewählten Fläche, senkrecht zu ihr. Zu finden unter Ebenen › Konstruktion.",
        "Ebene Versatz": "Hilfsebene parallel zur gewählten Fläche im eingestellten Abstand (blaue Vorschau), übernehmen mit „Fertig“.",
        "Muster linear": "Gewählte Körper in einer Reihe vervielfältigen: Anzahl, Abstand und Richtung.",
        "Muster kreisförmig": "Gewählte Körper rund um eine Achse vervielfältigen: Anzahl und Winkel.",
        "Skizze skalieren": "Ganze Skizze um einen Faktor vergrößern oder verkleinern.",
        "Achsendrehung": "Skizzenbereich um eine Linie oder Achse drehen (Drehkörper).",
        "Isolieren": "Nur den gewählten Körper zeigen; nochmal tippen blendet alles wieder ein.",
        "Messen": "Kantenlänge, Fläche, Volumen oder Abstand zweier Punkte anzeigen.",
        "Körper wählen": "Antippen wählt ganze Körper statt Flächen – mehrere nacheinander antippen, dann Vereinigen, Abziehen oder Schneiden.",
        "Schneiden": "Behält nur den Bereich, in dem sich die gewählten Körper überlappen.",
        "Rahmenauswahl": "Finger zieht einen Rahmen statt zu drehen. Nach rechts: nur ganz umschlossene Körper, nach links: auch angeschnittene. Mit dem Stift geht der Rahmen immer – einfach ins Leere ziehen.",
        "Abziehen": "Schneidet heraus: beim Extrudieren aus vorhandenen Körpern, in der Auswahl die übrigen Körper aus dem zuerst gewählten.",
    ]
}
