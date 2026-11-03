# PencilCAD Build 27 – Änderungen und Tests

## Änderungen

- Apple Pencil Pro: Druckbeginn öffnet im aktiven Skizzenmodus sofort das Rad mit Skizzenwerkzeugen. Der schwebende Stift hebt das getroffene Icon hervor; beim Wechsel des Icons wird ein haptisches Signal angefordert. Loslassen übernimmt das Werkzeug. Ohne Treffer bleibt das Rad zum Antippen offen. Pencil-Doppeltippen und Tippen auf Icons bleiben verfügbar. Beim anschließenden Praxistest war das Signal am Stift nicht spürbar; Nachbesserung folgt.
- Geschlossene Linienzüge wechseln zur Auswahl und lassen sich direkt bemaßen.
- Die laufende parallele Linie und ihre Bezugslinie werden wieder grün angezeigt; bei gleicher Länge leuchten alle transitiv verbundenen Bezugslinien gelb.

## Verifikation

- Simulator: 80 von 80 Tests bestanden, einschließlich Werkzeugrad-Geometrie, Auswahlaktion, einmaligem Feedback und Linienregressionen.
- iPad: 80 von 80 Tests bestanden.
- Der tatsächliche Druck-/Schwebe-/Haptikablauf mit einem Apple Pencil Pro kann von XCTest nicht erzeugt werden. Der spätere Praxistest bestätigte die Hervorhebung, aber nicht die Haptik.

## Auslieferung

Signierten Release-Build, Installation, Projektdateivergleich und Quellcode-Paket nach Abschluss in `Pruefprotokolle/BUILD_27_ABNAHME.md` dokumentieren.
