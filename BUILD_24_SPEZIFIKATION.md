# Build 24: Normteil als Einheit auswählen und platzieren

## Ausgangspunkt

Eine eingefügte ISO-Schraube ist bislang ein gewöhnlicher Körper. Ein Tipp kann Kanten/Flächen auswählen und die Oberflächenpalette öffnen. Normdaten sind nach dem Einfügen nicht am Körper gespeichert. Dadurch fehlt eine gezielte Normteilansicht und eine einfache Platzierung.

## Verhalten

- Ein Tipp auf eine Schraube (auch auf ihre Kante) wählt den ganzen Schraubenkörper und aktiviert die vorhandenen Verschiebepfeile. Die Rahmenauswahl bleibt eine Körperauswahl.
- Die Auswahl zeigt zuerst ein Normteilfenster mit Bezeichnung, metrischer Größe, Länge, Regelgewindesteigung, theoretischer Gewindelänge, Festigkeitsklasse und Geometriehinweis. Oberflächen werden über eine eigene Schaltfläche geöffnet.
- Neue Normteile tragen ihre Spezifikation auch nach Speichern/Öffnen und in Verlaufs-Snapshots. Bestehende, am Namen erkennbare ISO-Teile bleiben auswählbar; bei ihnen gelten nicht gespeicherte Angaben als unbekannt.
- „An Fläche platzieren“ richtet eine Schraube auf eine angetippte ebene Zielfläche aus. Wählbar sind Kopfauflage bündig, Kopfoberseite bündig und Spitze bündig plus Versatz. Die Platzierung ist ein rückgängig machbarer Modellschritt; sie ist keine dauerhafte Baugruppen-Verknüpfung.
- Standardmäßige Kantenauswahl/Fillet der Schraube wird im Auswahlmodus verhindert. Ein expliziter Wechsel zum Volumenkörper erlaubt freie Geometriebearbeitung.

## Prüfung

- Einheitliche Auswahl per Tipp und Rahmen; Normteilfenster statt automatischer Materialpalette.
- Platzierung auf horizontaler und schräger ebener Fläche sowie auf bereits versetztem/gedrehtem Teil.
- Speichern/Öffnen und Verlauf erhalten Normdaten; Vorher/Nachher-Projektbestand auf dem iPad vergleichen.
