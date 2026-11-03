# Build 34 – Verlauf und Parametrik

## Ausgangslage

`runFeatures` stoppt nach dem ersten fehlgeschlagenen Schritt alle späteren Features. Das sperrt auch Features an anderen Körpern und vollständige gespeicherte Zwischenstände. Der Nachbau läuft auf dem Main-Thread; zusätzliche Kernelversuche sind daher auf sichere Fälle zu begrenzen.

## Änderungen

1. Nach einem fehlgeschlagenen, körperzahlstabilen Feature darf ein späteres Feature an einem nachweislich anderen Körper weiterlaufen. Nur Featurearten mit eindeutiger Körperreferenz und unveränderter Körperzahl sind dafür freigegeben. Eine neue Grundform darf als unabhängiger Körper angehängt werden.
2. Ein vollständiger Snapshot darf nach einem Fehler den gespeicherten Zustand wiederherstellen; danach laufen spätere Schritte normal weiter. Ein partieller Snapshot darf Fehler an seinem betroffenen Körper nicht verdecken.
3. Fehlgeschlagene oder blockierte Zwischenstände dürfen nicht als gültige Cachebasis für spätere Replayläufe verwendet werden. Fehlermeldungen nennen den blockierenden Schritt.
4. Beim Zurücksetzen eines ungültigen Parameters müssen abhängige Schritte wieder reproduzierbar werden. Speichern, Wiederöffnen und Timeline-Auswahl bleiben funktionsfähig.

## Abnahme

- Zwei Körper: ungültige Rundung an Körper A blockiert dessen Folgeschritt, eine Rundung an Körper B läuft durch.
- Vollständiger Snapshot nach Fehler setzt den Zustand zurück; ein späterer Grundkörper wird berechnet.
- Fehler korrigieren: alle abhängigen Features werden wieder aktiv, Volumen und Feature-IDs bleiben nach Wiederöffnen stabil.
- Simulator und iPad: komplette Suite grün; signierter Release-Build, Projektdateien vor/nach Installation gleich.
- 4/5 nur für diese nachgewiesenen Verlaufsfälle; 5/5 erfordert zusätzlich durchgängige, stabile Topologiebezüge und modellweite Abhängigkeiten ohne Snapshot-Grenzen.
