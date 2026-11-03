# PencilCAD Build 8 – Konturauswahl beim Abrunden (30.10.2026)

## Änderungen

- Das Werkzeug „Abrunden“ bietet **Kontur** (Vorgabe) und **Einzelkante**. Ein Tipp auf eine Kante einer ebenen Körperfläche wählt im Konturmodus alle Randkanten derselben zusammenhängenden BRep-Kontur. Auch scharfe und einspringende Ecken unterbrechen die Auswahl nicht. Getrennte Ränder, etwa ein Loch, bleiben getrennt und können zusätzlich angetippt werden.
- Die Auswahl folgt echten Körperkanten. Sichtbare Skizzenlinien werden nicht als abrundbare Körperkanten behandelt. Im Einzelkantenmodus ergänzt PencilCAD keine anderen geradlinigen Teilstücke automatisch.
- Wenn mehrere ausgewählte Konturkanten bei keinem geprüften Radius eine gültige Rundung ergeben, erscheint eine verständlichere Fehlermeldung. Der Körper bleibt unverändert.

## Nachstellung am aktuellen iPad-Projekt

Das gesicherte „Titelloses Projekt 2“ enthält einen geschlossenen Körper mit sechs Flächen. Der obere ebene Flächenrand besteht aus vier verschiedenen BRep-Kanten. Die neue Konturauswahl ermittelt vom ersten Randstück aus alle vier Kanten. Das unterscheidet die Auswahl der Körperkontur von der im Bild noch sichtbaren Skizze.

Eine **durchgehende Abrundung aller vier Kanten** war am gesicherten Körper mit 0,1 mm, 0,5 mm, 2 mm, 4 mm, 10 mm und 39,6 mm nicht gültig. Schon drei der vier einzelnen Freiformkanten scheiterten bei 0,5 mm. Zwei weitere OCCT-Filletdarstellungen brachten für diese Form keine gültige Rundung und wurden deshalb nicht in den Build übernommen. Diese Beobachtung belegt eine geometrische Grenze dieses konkreten Körpers; sie belegt keine allgemeine 90°-Grenze für Abrundungen.

## Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Kerntests auf dem Mac | 84 bestanden, 0 fehlgeschlagen |
| App-Tests im Simulator | 15 bestanden, 0 fehlgeschlagen |
| Topologietest mit einspringender L-Kontur | Alle sechs Randkanten ausgewählt, 1-mm-Rundung ergab einen geschlossenen Körper |
| Test des Bedienablaufs Kontur/Einzelkante | Beide Auswahlarten am Quader geprüft |
| Signierter iPad-Build | Erstellt und als Version 0.1.0, Build 8 auf dem iPad installiert |
| App-Tests und Start auf dem iPad | App gestartet; 15 Tests bestanden, 0 fehlgeschlagen |
| Projektdaten vor/nach Installation und Tests | 18/18 Dateien unverändert (Dateivergleich) |

Die gesicherten privaten Projektdaten und die temporären Diagnosetests sind nicht Bestandteil des Quellpakets.

## Verbleibende Grenze

Die automatische Konturauswahl löst das Problem unvollständiger Kantenauswahl. Sie ersetzt keinen Geometriekern, der beliebige Freiformränder mit beliebig großen Radien verrunden kann. Ein Radius kann nur übernommen werden, wenn ein gültiger geschlossener Restkörper entsteht. Insbesondere 39,6 mm an dieser etwa 4 mm dicken Form sind nicht als machbar nachgewiesen. Für eine echte Vollrundung oder einen Übergang, bei dem eine ganze Fläche verschwindet, wäre ein eigenes Werkzeug mit eigener Geometrie- und Eckbehandlung nötig.
