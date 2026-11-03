# Build 27 – Abnahmeprotokoll

- Signierter Release-Build: `xcodebuild build` erfolgreich; `CFBundleVersion = 27`; `codesign --verify --deep --strict` erfolgreich.
- Simulator: 80/80 Tests bestanden (`Build27_Simulator_Testsummary.json`).
- Echtes iPad: 80/80 Tests bestanden (`Build27_iPad_Testsummary.json`).
- Finale Release-App auf iPad von Kai installiert und erfolgreich gestartet.
- Vor der Installation 113 Projektdateien gesichert. Nach der finalen Installation sind alle 113 ursprünglichen Dateien per SHA-256 unverändert vorhanden. Die App legte drei neue Dateien für ein neues Projekt an; keine bestehende Datei wurde entfernt.
- IPA-Archiv mit `unzip -tq` ohne Fehler geprüft.

**Offen laut anschließendem Praxistest:** Die Werkzeuge werden beim schwebenden Stift hervorgehoben, aber das erwartete haptische Feedback am Pencil Pro ist nicht spürbar. Kleine Werkzeugnamen fehlen ebenfalls. Diese Punkte sind für den virtuellen Folge-Build vorgemerkt. Automatisierte Tests können die reale Pencil-Pro-Haptik nicht belegen.
