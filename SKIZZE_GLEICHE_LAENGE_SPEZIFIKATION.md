# Skizzenfang „Gleiche Länge“ – Spezifikation

## Gewünschter Ablauf

1. Eine bereits gezeichnete gerade Linie dient als Längenreferenz innerhalb derselben Skizze und Ebene.
2. Beim Zeichnen einer neuen Linie wird deren Endpunkt innerhalb eines bildschirmbasierten Fangradius auf die Länge der Referenzlinie gesetzt. Die Richtung der neuen Linie bleibt erhalten; horizontal und vertikal müssen exakt bleiben.
3. Solange der Fang aktiv ist, leuchten Referenzlinie und neue Linienvorschau gelb. Eine gelb gestrichelte Verbindung ihrer Mittelpunkte und das Zeichen `=` zeigen die Beziehung. Beim Verlassen des Fangbereichs kehrt die normale Darstellung zurück.
4. Wird die Linie in diesem Zustand abgesetzt und ist „Automatische Einschränkungen“ aktiv, erhält sie eine `Gleich`-Bedingung zur Referenzlinie. Ohne Auto-Einschränkung bleibt die neue Länge nur geometrisch eingerastet.
5. Vorhandene Punkt- und Kurvenfänge sowie getippte Längen haben Vorrang. Mehrere mögliche Referenzen werden nach Längenabweichung und räumlicher Nähe priorisiert.
6. Die Fangart ist separat im Fang-Menü schaltbar. Andere Skizzen und 3D-Körper dienen nicht als Längenreferenz.

## Verifikation

- Horizontale, vertikale und schräge Referenzen: gleiche Länge mit beliebiger Richtung der neuen Linie.
- Außerhalb des Fangradius keine Farbänderung, kein Längenfang, keine Gleich-Bedingung.
- Punktfang und getippte Länge bleiben vorrangig.
- Wechsel/Abbruch der Skizze entfernt die temporäre Hervorhebung.
