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
        .floatingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous), elevation: .overlay)
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
        "Einfügen": "STEP-, STL- und 3MF-Datei, Bild als Vorlage (aus Fotos, Dateien oder mit der Kamera), Körper eines anderen Projekts oder eine Variable einfügen.",
        "Konstruieren": "Hilfsebenen, -achsen und -punkte, z. B. eine versetzte Ebene zum Skizzieren.",
        "Transformation": "Ändert nur Lage oder Größe: Körper oder Skizzen verschieben, drehen, übersetzen, skalieren oder ausrichten.",
        "Tools": "Kanten abrunden/fasen, Schale, boolesche Verknüpfung, Drehen, Sweep, Loft, Körper teilen.",
        "Visualisieren": "Anzeigemodus, Farbe, Schnittansicht, Messen und Isolieren.",
        "Extrudieren": "Geschlossenen Skizzenbereich oder ebene Fläche antippen und am Pfeil ziehen bzw. Abstand eingeben.",
        "Ebenen": "Browser wie in Fusion 360: Skizzen mit den Körpern daraus, Konstruktion und Bilder – ein- und ausblenden, wählen, bearbeiten.",
        // Skizzenwerkzeuge nach Fusion 360
        "Langloch": "Mitte zu Mitte: von einem Bogenmittelpunkt zum anderen ziehen, dann die Breite. Gesamt: von Ende zu Ende. Mittelpunkt: von der Mitte zu einem Bogenmittelpunkt.",
        "Mitte zu Mitte": "Langloch: Abstand der beiden Bogenmittelpunkte ziehen, dann die Breite.",
        "Gesamt": "Langloch: Gesamtlänge von Ende zu Ende ziehen, dann die Breite.",
        "2 Punkte": "Kreis über seinen Durchmesser: von einem Randpunkt zum gegenüberliegenden ziehen.",
        "3 Punkte": "Erst zwei Punkte ziehen, dann den dritten – Kreis, Bogen bzw. gedrehtes Rechteck durch alle drei.",
        "Radius bis Ecke": "Polygon innen: der gezogene Radius endet an einer Ecke (Umkreis).",
        "Radius bis Kante": "Polygon außen: der gezogene Radius endet in der Kantenmitte (Inkreis).",
        "Ändern": "Abrunden, Fase, Verlängern, Unterbrechen und Skalieren – wie das Ändern-Menü in Fusion 360. Antippen startet das zuletzt gewählte.",
        "Verlängern": "Linie nahe dem Ende antippen: sie wächst bis zur nächsten Kurve.",
        "Unterbrechen": "Kurve antippen: sie wird an den nächsten Schnittpunkten geteilt, ohne etwas zu löschen. Ohne Schnittpunkte an der angetippten Stelle.",
        "Spiegeln": "Skizze: Elemente antippen, zuletzt die Spiegellinie, dann „Spiegeln“. Vorher erscheint eine Vorschau.",
        "Rechteckmuster": "Elemente antippen, Spalten, Zeilen und Abstände eingeben, dann „Erstellen“.",
        "Kreismuster": "Elemente antippen, zuletzt den Mittelpunkt (sonst Ursprung), Anzahl und Winkel eingeben, dann „Erstellen“.",
        "Kollinear": "Zwei oder mehr Linien antippen: sie liegen danach auf einer gemeinsamen Geraden.",
        // Nach der Skizze (wie Shapr3D)
        "Skizze bearbeiten": "Öffnet die Skizze dieses Bereichs wieder zum Zeichnen und Ändern.",
        "Ausblenden": "Blendet die Skizze aus (wieder einblenden im Ebenen-Browser oder unter Sichtbarkeit).",
        "Sweep": "Gewählten Bereich entlang eines Pfads (offene Skizzenkurve) führen.",
        "Loft": "Körper durch mehrere Querschnitte (Bereiche verschiedener Skizzen) bilden.",
        // Skizzenmodus links
        "Skizzieren beenden": "Skizze übernehmen und zurück ins 3D-Modell. Geschlossene Bereiche lassen sich danach extrudieren.",
        "Auswählen": "Pfeil: zeichnet nicht. Antippen wählt, Ecken und Enden ziehen ändert die Größe, Linien ziehen verschiebt, Kreisrand ziehen ändert den Radius. Stift 1 s ruhig über einem Punkt schweben lassen oder mit dem Finger doppeltippen merkt ihn – zwei gemerkte Punkte zeigen Abstand, Mitte und Mittellinie. Stift drücken öffnet das Werkzeugrad.",
        "Aktive Ebene": "Ebene, auf der gerade gezeichnet wird.",
        "Keine aktive Ebene": "Erst eine Ebene (grau) oder eine ebene Körperfläche antippen.",
        "Linie/Bogen": "Linie: Punkt für Punkt ziehen, zurück zum Start schließt. Rund gezogen wird automatisch ein Kreis (geschlossen) oder Bogen. Finger auflegen, während der Stift zeichnet: tangentialer Bogen am Linienende – Finger heben setzt ihn an der Stiftspitze.",
        "Linie": "Punkt für Punkt ziehen; Länge und Winkel werden angezeigt. Rund ziehen ergibt einen Kreis bzw. Bogen. Zurück zum Startpunkt schließt das Profil.",
        "Bogen": "3 Punkte: von einem Ende zum anderen ziehen, dann die Wölbung. Mittelpunkt: von der Mitte zum Start ziehen, dann das Ende – der Bogen folgt dem Stift, auch über 180°.",
        "Spline": "Freie Kurve durch Punkte (Fit-Punkte) oder über Kontrollpunkte.",
        "Rechteck": "Diagonal, von der Mitte aus oder über drei Punkte (gedreht).",
        "Kreis": "Mittelpunkt: von der Mitte nach außen ziehen (rastet tangential, auf gleichen Radius oder durch Punkte ein). 2 Punkte: Durchmesser ziehen. 3 Punkte: zwei Punkte ziehen, dann den dritten.",
        "Ellipse": "Von der Mitte zur Ecke ziehen – Breite und Höhe ergeben sich daraus.",
        "Polygon": "Regelmäßiges Vieleck von der Mitte aus; Eckenzahl unten einstellen. Radius bis Ecke (innen) oder bis Kantenmitte (außen) wie in Fusion 360.",
        "Projizieren": "Körperkanten oder Flächenränder in die Skizze übernehmen.",
        "Kante versetzen": "Kontur oder Kurve antippen und um einen Abstand parallel versetzen.",
        "Fläche versetzen": "Flächen antippen (mehrere, auch runde) und am Pfeil ziehen: Nachbarflächen wachsen mit. „Gesamt“ setzt das Gesamtmaß des Körpers, „Durchmesser“ macht Zapfen bzw. Bohrungen genau so groß.",
        "Fläche ersetzen": "Flächen antippen, dann unter „Ziel“ eine ebene Fläche: die Flächen werden bis an deren Ebene verlängert oder gekürzt.",
        "Umhüllen und Prägen": "Skizzenbereiche (Text, Logo) antippen, dann eine Zylinderfläche: das Motiv legt sich um den Zylinder und wird erhaben geprägt oder eingraviert.",
        "Kante abdrücken": "Skizzenbereiche, die auf einer Körperfläche liegen, als Kanten auf den Körper übertragen – danach lässt sich der Teil der Fläche einzeln ziehen.",
        "Kopieren": "Startet Verschieben/Rotieren mit eingeschaltetem „Kopieren“: das Original bleibt stehen, verschoben wird eine Kopie (auch mehrere in Reihe).",
        "Gewindebohrung": "Startet die Bohrung mit eingeschaltetem Gewinde: Fläche antippen, Kernloch nach Bohrertabelle, Gewinde nach Norm.",
        "Abrundungen": "Kanten abrunden oder fasen.",
        "Löcher": "Bohrung mit Senkung oder Senkkopf, Gewindebohrung und Gewinde.",
        "Übersetzen": "Körper antippen, dann Start- und Zielpunkt (rastet an Ecken und Kantenmitten): der Körper wandert genau so weit. Mit „Kopieren“ bleibt das Original stehen.",
        "Bild aus Fotos": "Foto aus dem Fotoalbum als Vorlage einfügen, danach gleich auf Maß kalibrieren.",
        "Bild aus Dateien": "PNG, JPEG, HEIC oder die erste Seite eines PDF als Vorlage einfügen, danach gleich auf Maß kalibrieren.",
        "Foto aufnehmen": "Objekt mit der Kamera fotografieren – möglichst senkrecht von oben, mit einem bekannten Maß (z. B. Lineal) im Bild – und danach kalibrieren.",
        "Projekt": "Körper eines anderen Projekts als Kopie einfügen (landen in einem eigenen Ordner).",
        "Variable": "Benannte Werte (z. B. wand = 2 mm), die in jedem Zahlenfeld und in Skizzenmaßen verwendet werden können.",
        "Hilfe": "Kurzanleitungen zu Gesten, Skizzieren, Modellieren, Formeln und Variablen.",
        "Mehr": "Projizieren, Spiegeln, Rechteck- und Kreismuster, Punkt und Text. Antippen startet das zuletzt gewählte.",
        "Alle Werkzeuge": "Zeigt wieder alle Werkzeuggruppen (Skizze, Extrudieren, Formen, Abrundungen, Löcher …).",
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
        "Anzeigemodi": "Schattiert, mit Kanten, Drahtgitter, durchsichtig, verdeckte Kanten gestrichelt, Zebra-Streifen; orthografisch oder perspektivisch.",
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
        "Gleicher Winkel": "Linien haben denselben Winkel zur Waagerechten oder den gespiegelten (z. B. 70° und 110°, symmetrisch zur Senkrechten). Wählen: zwei oder mehr Linien.",
        "Symmetrien": "Zwei Punkte oder Elemente spiegelbildlich zu einer Achse. Wählen: zwei Punkte/Elemente, zuletzt die Achse (Linie).",
        "Trennen": "Löst Einschränkungen an der Auswahl, z. B. trennt zusammenhängende Ecken, damit sie einzeln verschoben werden können.",
        "Verankern": "Fixiert Punkte oder Kurven an ihrer Stelle; sie bewegen sich beim Ändern anderer Elemente nicht mehr.",
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
        "Messen": "Kantenlänge, Fläche, Volumen oder Abstand zweier Punkte anzeigen. In der Skizze: Länge, Radius, Abstand und Winkel – zeigt auch, ob zwei Linien wirklich parallel sind.",
        "Körper wählen": "Antippen wählt ganze Körper statt Flächen – mehrere nacheinander antippen, dann Vereinigen, Abziehen oder Schneiden.",
        "Schneiden": "Behält nur den Bereich, in dem sich die gewählten Körper überlappen.",
        "Rahmenauswahl": "Finger zieht einen Rahmen statt zu drehen. Nach rechts: nur ganz umschlossene Körper, nach links: auch angeschnittene. Mit dem Stift geht der Rahmen immer – einfach ins Leere ziehen. Lange drücken: Lasso statt Rahmen.",
        "Lassoauswahl": "Frei um Körper herumfahren: alles ganz Umschlossene wird gewählt. Lange drücken: zurück zum Rahmen.",
        "Abziehen": "Schneidet heraus: beim Extrudieren aus vorhandenen Körpern, in der Auswahl die übrigen Körper aus dem zuerst gewählten. Als Werkzeug: erst das Ziel, dann die Werkzeuge antippen – Vorschau zeigt das Ergebnis, Spiel macht die Aussparung etwas größer.",
        "Negativform": "Block mit Rand um einen Körper, der Körper wird mit Spiel herausgeschnitten – wahlweise in zwei Formhälften geteilt (Trennebene durch die Mitte). Der Körper bleibt erhalten.",
    ]
}
