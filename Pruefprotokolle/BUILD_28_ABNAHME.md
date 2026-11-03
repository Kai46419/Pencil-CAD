# Build 28 – Abnahmeprotokoll

| Prüfung | Ergebnis |
| --- | --- |
| Gezielte Skizzen-Tests | 42/42 bestanden |
| Vollständige iOS-Simulator-Suite | 84/84 bestanden |
| iOS-Release-Build ohne Gerätesignierung | `xcodebuild build` für `generic/platform=iOS`: erfolgreich; Buildnummer 28 |
| Signierter iPad-Release-Build | Erfolgreich; `CFBundleVersion = 28`; `codesign --verify --deep --strict` bestanden |
| Installation und Start auf Kais iPad | Erfolgreich; installierte Version 28, PencilCAD-Prozess gestartet |
| Projektdaten | Vorher 125 Dateien gesichert; nach Installation und Start 125/125 bytegleich, keine Datei entfernt oder verändert |
| Manueller Pencil-Pro-Test | Nutzer meldet Werkzeugnamen und haptisches Feedback als funktionierend; Bogenfang und weitere Skizzenabläufe noch offen |
| ZIP-Integrität und SHA-256 | Siehe Prüfsummen-Datei im Ausgabeverzeichnis |

Der Build ist für den manuellen iPad-Test bereit. Aus Installation und Prozessstart folgt noch keine Abnahme der Stiftinteraktion.
