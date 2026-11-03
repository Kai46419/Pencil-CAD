# PencilCAD Build 25 – 31.10.2026

## Projekt 14: Schraube wieder als Einheit auswählen

- Ursache: Die Projektdatei enthält fünf logische Körper. Der bisherige STEP-Lader zerlegte die mehrteilige Schraube beim Öffnen in einzelne Volumen und erzeugte sechs Körper. Der zusätzliche Körper hatte keine Normteil-Metadaten und konnte als gewöhnliche Kante oder Fläche behandelt werden.
- Interne Projekt- und Verlaufsdateien werden jetzt nach STEP-Wurzeln geladen. Ein zusammengesetzter Normkörper behält seine Zuordnung zu genau einer Zeile in `bodies.json`. Der externe STEP-Import zerlegt weiterhin Volumen wie zuvor.
- Ein Tipp auf ein Normteil hat Vorrang vor einem noch geöffneten Rundungs- oder anderen Modellbefehl. Der Tipp wählt den ganzen Körper und öffnet Verschieben. Ein darüberliegender Ziehpfeil verschluckt den Tipp nicht mehr. Bei gewähltem Normteil erscheint dessen Eigenschaftenfenster auch dann, wenn zuvor eine andere Eigenschaftenansicht offen war.

## Verifikation

- Regressionstest mit einer Kopie der tatsächlichen STEP- und Metadaten aus Projekt 14: fünf Körper nach dem Öffnen; Schraube als Normteil erkannt; echter Viewport-Strahl trifft den Schraubenkörper; Tipp bei aktivem Abrunden wählt ausschließlich die Schraube; Verschiebevorschau mit 1,5 mm funktioniert.
- Vollständige Testsuite: Simulator 72/72, iPad 72/72 bestanden.
- Signierter Release-Build erfolgreich; Signatur gültig und Bundle-Version 25. Auf dem iPad installiert und gestartet.
- Projektbestand nach Gerätetests, Installation und Start unverändert: 14 Ordner, 104 Dateien, bytegleich zur Sicherung vor dem Test.

## Grenze

Automatisierte Modell- und Gerätetests ersetzen keinen manuellen Apple-Pencil-Tipp in der laufenden Projektoberfläche. Der Nutzer sollte nach Installation Projekt 14 öffnen, die Schraube an Kopf und Schaft einmal antippen und die Verschiebepfeile prüfen.
