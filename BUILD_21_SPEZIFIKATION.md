# Build 21: Zwischenstand vor letzter Rundung

## Beobachtung
Nach erneutem Öffnen enthält der Speicher nur den letzten Feature-Zustand. Bei einer angrenzenden Rundung rekonstruiert `findBlendMerge` den Körper vor der letzten Rundung auf dem MainActor. Im Projekt-8-Diagnosefall dauerte der erste Zugriff etwa 105 ms.

## Änderung
Der Körper vor dem letzten Rundungs-Feature wird beim Speichern als entbehrlicher STEP-Zwischenstand abgelegt. `features.json` verweist mit einer eindeutigen ID auf diese Datei. Beim Öffnen wird sie nur benutzt, wenn der letzte Feature-Typ, die Feature-ID und der Körperindex passen. Fehlt sie oder ist sie ungültig, bleibt der bisherige Verlauf-Nachbau aktiv. Änderungen am Modell verwerfen den geladenen Hinweis.

## Akzeptanz
- Altes Projekt ohne Zwischenstand öffnet und rundet wie bisher.
- Nach Speichern und erneutem Öffnen kann die angrenzende Rundung den vorigen Körper ohne ersten Feature-Nachbau finden.
- Undo/Redo und geänderte Features nutzen keinen veralteten Zwischenstand.
- Ein unterbrochener Speichervorgang hinterlässt keinen verwendbaren Verweis auf eine falsche Geometrie.
- Simulator- und iPad-Tests sowie signierter Release-Build bestehen.
