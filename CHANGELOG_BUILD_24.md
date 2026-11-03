# PencilCAD Build 24 – 31.10.2026

## Normteile und Schrauben

- Neue Normteile speichern Art, Größe, Länge, Gewindemodell und gewählte Festigkeitsklasse als Metadaten. Ältere ISO-Schrauben werden anhand ihres Namens erkannt; bei ihnen bleiben Gewindegeometrie und Festigkeitsklasse zunächst als unbekannt bzw. nicht festgelegt gekennzeichnet.
- Ein Tipp auf die Schraube, auch auf eine Schraubenkante vor einer anderen Fläche, wählt den ganzen Körper und aktiviert die Verschiebepfeile. Eine einzelne Schraube aus der Rahmenwahl verhält sich ebenso. Das Normteilfenster erscheint zuerst; die Oberflächenpalette wird nur auf Wunsch geöffnet.
- Das Normteilfenster zeigt ISO-Bezeichnung, metrische Größe, Länge, Regelgewindesteigung und den Sollwert der Gewindelänge. Die Festigkeitsklasse ist auswählbar; ihre Angabe wird nicht aus der Geometrie erraten.
- „An Fläche platzieren“ richtet die Schraubenachse nach einer ebenen Zielfläche aus. Kopfauflage, Kopfoberseite oder Spitze lassen sich mit einem numerischen Versatz bündig setzen. Die Platzierung ist rückgängig machbar, aber noch keine dauerhafte Baugruppen-Verknüpfung.
- „Als Volumenkörper bearbeiten“ hebt den Normteilmodus ausdrücklich auf und gibt die herkömmliche Kanten- und Flächenbearbeitung frei.

## Nachweis

- Gezielte Tests: Auswahl per Kante und Rahmen, Seitenausrichtung nach vorheriger Bewegung, Speichern/Öffnen und Verlaufs-Snapshot nach Klassenänderung bestanden.
- Vollständige Simulator-Suite: 71/71 bestanden.
- iPad Air 11-inch (M4): 71/71 Tests beim vollständigen Wiederholungslauf bestanden. Im ersten Lauf schlug ein bestehender Teilabrundungstest mit fünf Folgefehlern fehl (70/71); derselbe Test bestand isoliert und im vollständigen Wiederholungslauf. Die Ursache der Schwankung ist noch nicht sicher geklärt.
- Signierter Release-Build erfolgreich; Signatur gültig, Bundle-Version 24. Auf dem iPad installiert und gestartet.
- Projektbestand vor und nach Test, Installation und Start bytegleich: 14 Projektordner, 104 Dateien. Sicherung unter `work/device-projects-before-build24/Projects`.
- Quell-ZIP und IPA: Integrität mit `unzip -tq` geprüft; SHA-256-Prüfsummen im Ausgabeverzeichnis.

## Praktische Grenze

Das Gewinde vereinfacht eingesetzter Schrauben ist weiterhin glatte Geometrie. Die angezeigte Gewindelänge ist der Sollwert der vorhandenen Modellformel. Die Platzierung folgt der Fläche einmalig; sie aktualisiert sich nicht automatisch, wenn die Zielfläche später bewegt wird. Physisches Antippen und Ziehen mit dem Apple Pencil können automatisierte Tests nicht vollständig nachstellen.
