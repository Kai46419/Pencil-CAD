# PencilCAD Build 36 – Blechabwicklung

## Änderung

- Vor dem DXF Export wird das Flachmuster mit der vorhandenen Überlappungsprüfung geprüft. Eine erkannte ungültige Abwicklung liefert eine Fehlermeldung, bevor eine DXF Datei entsteht.
- Die Konturprüfung erkennt jetzt auch überdeckte und an nicht benachbarten Stellen berührende Segmente. Leere Teilkonturen werden zurückgewiesen.
- Regressionstests ergänzen einen Kasten mit vier benachbarten, unterschiedlich hohen Laschen und Innenmaß sowie selbst schneidende und überdeckte Testkonturen.

## Nachweise

- Simulator: 122 Tests bestanden, 0 Fehler (`/tmp/PencilCAD_B36_full_test.log`).
- Physisches iPad: 49 Blechtests bestanden, 0 Fehler (`/tmp/PencilCAD_B36_device_test.log`).
- Release Build und strenge Codesign Prüfung bestanden; App auf iPad installiert und gestartet.
- 145 Projektdateien vor und nach der Installation SHA-256 bytegleich.

## Grenze der Prüfung

Die Überschneidungsprüfung analysiert Einzelkonturen mit bis zu 4000 Punkten. Eine vollständige Fertigungsfreigabe für beliebige komplexe Abwicklungen folgt daraus nicht. Die Blechbewertung bleibt daher bei 4/5 Sternen.
