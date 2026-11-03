# PencilCAD Build 12 – Abrundungsabsturz nach Maximalradius-Suche (30.10.2026)

## Status: ZURÜCKGEZOGEN

Nach den unten aufgeführten Tests und der Installation stürzte Build 12 am 30.10.2026 um 23:07:14 Uhr beim interaktiven Abrunden erneut ab. `PencilCAD-2026-10-30-230714.ips` meldet `EXC_BAD_ACCESS` / `SIGSEGV` an Adresse 0 im Thread `PencilCAD.blend`. Der Stack führt diesmal **direkt** von `BlendKernel.run` über `PCKShape.filletingEdges:radius:` und `blendOnce` zu `BRepFilletAPI_MakeFillet::Build` / `ChFi3d_Builder::PerformSetOfKGen`. Es war kein automatischer Maximalradius-Suchaufruf. Der Fix in Build 12 behebt diesen zweiten Absturz somit nicht. Build 12 wird nicht als iPad-Testpaket ausgeliefert oder als stabil bezeichnet.

Die gespeicherten vier Features von „Titelloses Projekt 6“ und `model.step` liegen in der Sicherung nach dem Absturz vor. Die fünfte Abrundung war eine nicht gespeicherte Vorschau; ihre Radiuszahl ist weder in `features.json` noch im IPS-Bericht enthalten. Ein C++-`catch` und der vorhandene Timeout können einen nativen SIGSEGV im App-Prozess nicht abfangen. Für eine robuste Lösung muss die riskante Kernelberechnung außerhalb des App-Prozesses laufen; bis dahin ist der konkrete Fillet-Fall offen.

## Befund aus dem iPad-Absturzbericht

Build 11 stürzte am 30.10.2026 um 22:55:52 Uhr im Vordergrund ab. `PencilCAD-2026-10-30-225552.ips` meldet `EXC_BAD_ACCESS`, `SIGSEGV`, Adresse 0. Der ausgelöste Thread `PencilCAD.blend` durchlief `BlendKernel.run` → `PCKShape.maximumBlendForEdges` → `blendOnce` → `BRepFilletAPI_MakeFillet::Build` → `ChFi3d_Builder::PerformSetOfKGen`. Der Nutzer hatte an einem Volumenkörper erneut eine Abrundung bearbeitet. Die Hänger-Marke zeigt eine nicht gespeicherte Abrundungsvorschau in „Titelloses Projekt 6“; der Projektordner wurde vor Änderungen kopiert. Die gewünschte Radiuszahl steht nicht im Absturzbericht.

## Änderung

- Nach einer gescheiterten Abrundung oder Fase startet PencilCAD keine automatische Suche nach einem maximal möglichen Wert mehr. Die OCCT-Suchmethode wurde aus der öffentlichen Kernel-Schnittstelle und beiden Implementierungen entfernt.
- Dieselbe automatische Suche wurde aus „Rundung vor Schnitt“ entfernt. Das verhindert den belegten Zusatzaufruf auch auf diesem Pfad.
- Der eingegebene Radius bzw. Fasenabstand bleibt unverändert. Scheitert der direkte Versuch, bleibt der Körper unverändert und „Fertig“ kann kein fehlendes Ergebnis übernehmen. Ein „max. X mm“-Hinweis und das automatische Klemmen einer Fase entfallen.
- Die tangentiale Kantenauswahl aus Build 11 bleibt enthalten.

## Prüfung

- Im App-Code gibt es keine Aufrufstelle von `maximumBlend` mehr.
- Regressionstest: absichtlich unmöglicher Abrundungsradius und Fasenabstand auf einem einfachen Volumenkörper führen zu `nil` ohne automatisches Klemmen und ohne Absturz.
- Mac-Kerntests: 84 bestanden, 0 fehlgeschlagen.
- iPad-Simulator: 30 App-Tests bestanden, 0 fehlgeschlagen.
- Physisches iPad: 30 App-Tests bestanden, 0 fehlgeschlagen.
- Die signierte App-Version 12 wurde ohne Testmodul installiert und gestartet; der Prozess lief bei der anschließenden Statusprüfung.
- Vor der Prüfung waren sechs Projektordner auf dem iPad vorhanden. Nach den Tests waren sie bytegleich. Nach Installation und Start blieben alle Modelldateien bytegleich; nur die nach dem Absturz vorhandene `haenger.json` des betroffenen Projekts wurde beim Neustart entfernt. Die Kopie vor dem Neustart enthält diese Marke weiterhin.

## Grenze und nächster Qualitätsmaßstab

Der konkrete Absturzpfad der automatischen Suchversuche ist entfernt. Ein direkter OCCT-Aufruf mit einer anderen schwierigen Geometrie kann weiterhin abstürzen; eine generelle Stabilitätsgarantie wäre nicht belegt. Das Absturzprojekt ist als unveränderte Kopie vorhanden, aber der beim Absturz eingestellte Radius wurde nicht gespeichert. Ein zukünftiger robuster Fillet-Kernel muss auf weiteren realen Modellen und Radiuswerten geprüft werden.

Build 12 erreicht keine vollständige Shapr3D-Parität. [Shapr3D bietet beim Abrunden und Fasen](https://support.shapr3d.com/hc/en-us/articles/7874402399900-Chamfer-Fillet) unter anderem G2, Sehnenbreite, Eck- und Überlaufoptionen. Diese Punkte sind für PencilCAD offen. Quellcode von Shapr3D wurde nicht übernommen.
