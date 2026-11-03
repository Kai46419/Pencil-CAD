# Build 33 – Eckenrundungen, Auswahl und Bewertung

## Ziel

Überlappende Rundungen an Ecken sollen nur dann als Erfolg gelten, wenn alle gewählten Kanten im Ergebnis bearbeitet wurden und der Restkörper gültig ist. Die Einzelkantenauswahl bleibt Standard; tangentiale Ketten werden nur über den vorhandenen ausdrücklichen Auswahlmodus ergänzt. Die auf GitHub vorhandene PencilCAD-Historie soll mit dem aktuellen Projekt verbunden sein.

## Prüffälle

1. Quader: mehrere Kanten einer Ecke gemeinsam mit unterschiedlichen Radien; gültiger Einzelkörper, keine stillschweigend ausgelassene Kante.
2. Sequenzieller Rückfall: falls eine gewählte Kante beim Runden der anderen verschwindet, darf das Ergebnis nicht fälschlich als vollständige Mehrkantenrundung gelten.
3. Zylinder: Nahtkante darf gemeinsam mit echter Kreiskante keine Teilrundung vortäuschen.
4. Projekt 8 und Projekt 21 bleiben Regressionen; der ungültige 27,5-mm-Standardradius wird weiterhin abgelehnt.
5. Simulator und iPad mit vollständiger Testsuite, Release-Build, Installation, Abgleich der Projektdateien.

## Nicht zu übernehmen ohne eigene Prüfung

Das externe Review schlägt eine globale tangentiale Kettenauswahl und den Nachbau von bis zu zwölf Verlaufsschritten auf dem Main-Thread vor. Beides verändert Auswahl bzw. Vorschauleistung grundlegend und wird nicht pauschal übernommen.

## Wertung

4/5 für Abrunden/Fasen erst, wenn die Mehrkanten-Eckenfälle und die vorhandenen Projektregressionen auf Simulator und iPad bestehen. Der Wert beschreibt dann den geprüften Funktionsstand, keine unbegrenzte Radiusfähigkeit.
