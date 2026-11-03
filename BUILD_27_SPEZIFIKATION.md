# Build 27 – Linienvorschau und Bemaßung nach Konturschluss

## Sollverhalten

1. Bei einem Gleichlängen-Fang leuchten alle durch aktive Gleichlängen-Abhängigkeiten
   verbundenen Bezugslinien gelb, auch transitiv (Linie 1 = Linie 2 = neue Linie 3).
   Die laufende Linie bleibt gelb und die Verbindung zur Bezugslinie gestrichelt.
2. Beim Parallel-Fang im Standard-Eingabestil leuchten laufende Linie und
   Bezugslinie grün. Diese Anzeige existiert bisher nur im klassischen Stil.
3. Tippt der Nutzer zum ersten Punkt eines Linienzuges zurück und schließt damit
   die Fläche, endet das Linienwerkzeug. Auswählen bleibt aktiv; ein Tipp auf eine
   Linie zeigt ihr bearbeitbares Längenmaß. Das gilt in beiden Eingabestilen.
4. Offene Linienzüge und andere Werkzeuge behalten ihren bisherigen Ablauf.
5. Im aktiven Skizzenmodus öffnet Apple-Pencil-Pro-Drücken das Skizzen-Werkzeugrad
   bereits bei Beginn des Drucks. Schweben über einem Werkzeug hebt es hervor und
   gibt genau beim Wechsel auf ein anderes Werkzeug haptisches Feedback. Loslassen
   übernimmt das hervorgehobene Werkzeug. Ohne Treffer bleibt das Rad zum Antippen offen.
   Doppeltippen am älteren Pencil öffnet dasselbe Rad; Tippen bleibt als Alternative.

## Abnahme

- Gezielte Modelltests für transitive Gelbgruppe, grünen Parallel-Fang und
  Werkzeugwechsel nach Konturschluss.
- Geometrie- und Aktionsprüfung für das Werkzeugrad sowie Gerätetest der Skizzenwerkzeuge.
- Alle bestehenden Simulator- und iPad-Tests; signierter Release-Build, Installation
  und Prüfung der gespeicherten iPad-Projektdateien.
- Sternengrafik nach dem Update mit unveränderten Fusion-/Shapr3D-Werten.
