# Build 28 – virtuelle Skizzenkorrekturen

## Sollverhalten

1. Mittelpunktbogen: Der letzte Punkt rastet an einem tatsächlichen Schnitt der Radius-Kreisbahn mit einer bestehenden Linie/Kurve ein. Der angezeigte Bogen endet exakt dort; ein bloß auf die Kreisbahn projizierter Kurvenfang darf nicht als erfolgreicher Fang gelten.
2. Tangentialbogen: Nach Wahl des Ansatzpunkts lässt sich die Bogenseite bewusst umschalten; Vorschau und gesetzte Geometrie verwenden dieselbe Seite.
3. Text am Bogen: Im Eigenschaftenfenster sind ein klar beschrifteter Pfadwähler, eine Bogen-Vorlage mit einstellbarem Radius sowie Auf/Über/Unter und Abstand erreichbar. Der Text folgt dem gewählten Bogen und dessen späteren Änderungen.
4. Linienzug: Der angezeigte und eintippbare Winkel bezieht sich ab dem zweiten Segment auf das vorherige Segment, nicht auf die globale Horizontale. Die laufende Linie und ihr paralleler Bezug werden grün hervorgehoben, wenn der Parallel-Fang aktiv ist.
5. Werkzeugrad: Kleine Namen unter den Werkzeugen. Der Wechsel der Schwebeauswahl löst Auswahlhaptik am Werkzeugrad aus; der reale Pencil-Pro-Effekt bleibt bis zum nächsten Gerätetest ausdrücklich unbestätigt.

## Abnahme

- Gezielte Modell- und UI-nahe Tests für die neuen Geometrien, Werte und Zustandswechsel.
- Vollständige Simulator-Tests und signierter Simulator-Build. Kein iPad-Zugriff, keine Installation.
- Quellcode-Commit, vollständiges Projektpaket, Änderungsprotokoll und neue Sternengrafik. Bewertungen von Fusion und Shapr3D bleiben unverändert.
