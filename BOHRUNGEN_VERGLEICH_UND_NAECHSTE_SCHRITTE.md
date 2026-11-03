# Bohrungen: PencilCAD und Shapr3D (Stand Build 23)

## Was PencilCAD jetzt bietet

- Im Bohrungswerkzeug kann eine einzelne Bohrung auf einer ebenen Fläche über bis zu zwei gerade Bezugskanten und numerische Abstände positioniert werden. Daneben gibt es einen Mehrfachmodus mit mehreren angetippten Positionen. Bohrungsart, Durchmesser, Tiefe, Gewinde und weitere Maße sind vor dem Bestätigen einstellbar.
- Nach dem Bestätigen wird das Ergebnis als Körperzustand übernommen. Die Bohrung ist noch kein eigenständiger, wieder aufrufbarer Verlaufschritt mit editierbarem Mittelpunkt oder Bezugsmaß. Zum Ändern der Position bleibt derzeit Rückgängig und Neuanlegen oder eine skizzenbasierte Aussparung.
- Eine Skizze kann mehrere Kreise enthalten; vorhandene Abhängigkeiten und Maße lassen sich für deren Lage nutzen. Das Skizzenmuster kopiert Elemente, erzeugt derzeit aber keine dauerhaft gekoppelte Musterdefinition. Deshalb bleiben vier so erstellte Bohrungen nicht automatisch mit einem gemeinsamen Abstand und Durchmesser verbunden.

## Vergleich mit Shapr3D

Shapr3D bietet eine bearbeitbare Historie: frühere Schritte und deren verfügbare Parameter können nachträglich geändert werden. Das lineare Skizzenmuster unterstützt zwei Achsen, Anzahl sowie Gesamtmaß oder Schrittweite. Seine Musterabhängigkeit hält die Elemente zusammen; Definition, Abstand und Anzahl bleiben bearbeitbar.

Quellen: [History](https://support.shapr3d.com/hc/en-us/articles/11567903089180-History), [Pattern (Sketch)](https://support.shapr3d.com/hc/en-us/articles/7874323891228-Pattern-Sketch), [Sketch pattern constraint](https://support.shapr3d.com/hc/en-us/articles/7321295290012-Sketch-pattern-constraint).

## Sinnvolle nächste Umsetzung

1. Bohrung als eigenen Verlaufschritt mit Fläche, Mittelpunkt, Referenzkanten, Versatz, Durchmesser und Tiefe speichern. Beim Verschieben nur diesen Schritt ändern und alle folgenden Schritte neu berechnen.
2. Für eine Vierergruppe ein 2 × 2-Muster mit zwei Schrittweiten und zwei Anzahlen anbieten. Originalbohrung und Kopien teilen ihre Maße.
3. Bezug auf Skizzenlinie, Punkt und Hilfspunkt als dauerhafte Abhängigkeit speichern. Verlorene Referenzen im Verlauf sichtbar melden, statt Bohrungen still zu verschieben.
4. Regressionsfälle für geänderte Bezugskanten, Musterabstand, Bohrungsdurchmesser und Speichern/Öffnen hinzufügen.

Diese Schritte sind ein Vorschlag; Build 23 implementiert davon noch keine editierbare Bohrung oder parametrische Musterabhängigkeit.
