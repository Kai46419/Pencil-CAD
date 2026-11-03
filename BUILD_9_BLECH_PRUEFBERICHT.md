# PencilCAD Build 9 – Prüfung der Blechwerkzeuge (30.10.2026)

## Ergebnis

Die Blechwerkzeuge wurden anhand ihrer Befehle, Geometriepfade, Vorschau, Regeln, Verlaufsspeicherung und Ausgabe geprüft. Drei nachgestellte Logikfehler sind korrigiert. Die geprüften Arbeitsfolgen bestehen auf iPad und Simulator. Ein vollständiger Nachweis für jede denkbare Blechgeometrie ist damit nicht erbracht.

## Korrekturen

1. **Umwandlungsvorschau:** Jede erneute Vorschau von „In Blech umwandeln“ erzeugte bisher eine zusätzliche, ungenutzte STEP-Datei im Projekt. Eine verworfene Vorschau löscht ihre Datei jetzt. Eine übernommene Umwandlung behält genau die Quelldatei, die der Verlauf zum Nachbau braucht. Der Fehler wurde vor der Korrektur durch einen fehlschlagenden Test nachgestellt.
2. **Blechregel ändern:** Der Verlauf schrieb beim Nachbau alte Zahlenwerte über die geänderte Regel. Die Verlaufsparameter werden zusammen mit dem Rezept aktualisiert. Geprüft wurde ein Kasten, dessen Dicke von 2,5 auf 1,5 mm geändert und nach erneutem Öffnen bestätigt wurde.
3. **Dateiexport:** Laser-DXF und Abwicklungs-DXF konnten denselben temporären Dateinamen verwenden. Ein späterer Export konnte dadurch die frühere Datei entfernen. Jeder Export erhält jetzt einen eigenen Dateinamen. Ein Fehler beim Lesen des Laser-DXF für die Abwicklungszeichnung wird gemeldet, statt still eine Zeichnung ohne Kontur zu erzeugen.

## Funktionsprüfung

| Bereich | Geprüfter Ablauf | Ergebnis |
| --- | --- | --- |
| Blechteil aus Skizze | Geschlossenes Rechteck → Grundflansch | bestanden |
| Lasche | Grundblech → Kantenflansch | bestanden |
| Profil biegen | Offene Linienkette → Konturflansch mit Biegung und eigener Regel | bestanden |
| Pfadflansch | Quer zur Kante liegende Skizze → Pfadflansch | bestanden |
| Kanten | Außenkante wählen, vorhandenes Blech hochkanten, Zuschnittgröße vergleichen | bestanden |
| Kasten aus Maßen | Vier Laschen, Außenmaße und geschlossener Körper; Abwicklung nach erneutem Öffnen | bestanden |
| Umkantung, Falten, Perforieren | Je ein gültiger Befehl auf einem Grundblech; Abwicklung bzw. Lochangaben prüfen | bestanden |
| In Blech umwandeln | Ebene Platte, wiederholte Vorschau, Abbruch, Übernahme und erneutes Öffnen | bestanden |
| Entfalten und Zurückfalten | Lasche entfalten und wieder falten | bestanden |
| Blechregeln | Geänderte Dicke und Radius auf vorhandenen Kasten anwenden, speichern, neu öffnen | bestanden |
| Verlauf | Lasche bearbeiten, speichern, neu öffnen und löschen | bestanden |
| Ausgabe | Flachmuster, Laser-DXF, Abwicklungs-DXF, Biegetabelle als CSV und PDF-Erzeugung | bestanden |

## Tests und Gerät

- Mac: **84 Kerntests bestanden, 0 fehlgeschlagen**.
- iPad-Simulator: **24 App-Tests bestanden, 0 fehlgeschlagen**.
- Physisches iPad: **24 App-Tests bestanden, 0 fehlgeschlagen**; PencilCAD 0.1.0, **Build 9** installiert. Der signierte App-Build wurde geprüft.
- Projektdaten vor und nach Installation und Tests: **19 vorhandene Dateien unverändert**. Die App ergänzte nur ein zuvor fehlendes `thumbnail.png`.

## Grenzen dieser Prüfung

Die Tests decken repräsentative, gültige Blechformen und die genannten Bedienabläufe ab. Komplexe Umwandlungen mit mehreren gekrümmten Wänden, mehrfache benachbarte Kantungen ohne Eckfreischnitt sowie alle möglichen Regelkombinationen wurden nicht geometrisch verifiziert. Die PDF-Datei wurde erzeugt und als PDF erkannt; ihre Druckansicht wurde nicht visuell abgenommen. Direkte Stiftgesten auf dem iPad wurden nicht automatisiert.

Die privaten iPad-Projekte und Diagnosedateien sind nicht im Projektpaket enthalten.
