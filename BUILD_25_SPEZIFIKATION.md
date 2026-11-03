# Build 25 – Schraubenauswahl in Projekt 14

## Befund

Projekt 14 enthält fünf logisch gespeicherte Körper. Der alte STEP-Lader zerlegt die Schraube beim Öffnen in zwei Volumen und lädt dadurch sechs Körper; nur einer erhält die Normteil-Metadaten. Zusätzlich verarbeitet ein offener Modellbefehl Viewport-Tipps vor der Normteil-Auswahl. Damit kann ein Tipp auf die Schraube erneut eine Kante bzw. Rundung auswählen.

## Sollverhalten

Ein einzelner Tipp auf die sichtbare Schraube wählt den ganzen Normteilkörper und öffnet das Verschieben-Werkzeug. Ein offener Rundungsbefehl wird dabei verworfen. Die Schraube bleibt als ein Körper auswählbar, auch wenn der Kantenpicker eine nahe Kante eines anderen Körpers findet. Ein Tipp auf gewöhnliche Körper und deren Kanten behält das bisherige Verhalten. Die absichtliche Bearbeitung der Schraubengeometrie erfordert den expliziten Wechsel in den Geometriemodus.

## Prüfung

Regression mit gespeicherter Kopie von Projekt 14: erkannte Schraube nach dem Laden, Auswahl bei offenem Rundungsbefehl, Auswahl trotz konkurrierendem Kantenfund, aktive Verschiebung. Anschließend kompletter Testlauf auf Simulator und iPad, Release-Build, Installation und unveränderter Projektbestand.
