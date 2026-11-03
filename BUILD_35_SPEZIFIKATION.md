# Build 35 – Blech: sichere Umwandlung im Verlauf

## Fehler

`replaySheetMetal` überschreibt bei „In Blech umwandeln“ die ursprüngliche STEP-Quelldatei, bevor der neue Blechkörper erfolgreich berechnet und übernommen ist. Eine fehlgeschlagene Berechnung oder eine verworfene Vorschau kann damit die Quelle des gespeicherten Körpers verändern.

## Sollverhalten

1. Jeder neu berechnete Umwandlungsstand bekommt eine eigene STEP-Quelldatei. Die bisherige Quelle bleibt bytegleich.
2. Ein fehlgeschlagener oder zeitlich abgebrochener Nachbau behält die bisherige Quelle und entfernt seine temporäre Datei nach Ende der Hintergrundarbeit.
3. Ein erfolgreich übernommener Stand speichert den neuen Dateinamen im Körperrezept. Abwicklung, Export und Wiederöffnen benutzen diese Quelle.
4. Nicht mehr referenzierte Replay-Quelldateien werden nach Abschluss oder Verwerfen einer Vorschau aufgeräumt, ohne ursprüngliche Quellen anzutasten.

## Abnahme

- Vollkörper → Blech umwandeln → Größe des früheren Grundkörpers ändern: neuer Blechkörper und neues Flachmuster, ursprüngliche Quelldatei unverändert.
- Ungültiger Parameter bzw. verworfene Vorschau: kein Überschreiben der alten Quelle, keine unreferenzierte Replay-Datei.
- Simulator und iPad: vollständige Testsuite; signierter Build 35 auf dem iPad; Projektdateien vor/nach Installation unverändert.
- 4/5 Sterne für Blech erst nach diesen Nachweisen. Der fünfte Stern braucht eine breitere geometrische Abnahme komplexer Biegungen und Freischnitte.
