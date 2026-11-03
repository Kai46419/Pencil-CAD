# Abrundung: Fusion, SolidCraft und PencilCAD (31.10.2026)

## Verifizierte Quellen

- Autodesk beschreibt [Fusion-Fillet über die API](https://help.autodesk.com/cloudhelp/ENU/Fusion-360-API/files/FilletFeatureSample_Sample.htm). Das Beispiel ruft `filletFeatures` auf und zeigt konstante, variable und sehnengesteuerte Rundungen. Es enthält den internen Kernel nicht.
- Ein [Autodesk-University-Handout](https://static.au-uw2-prd.autodesk.com/Class_Handout_SD224080_Understanding_Geometry_and_BRep_in_Inventor_and_Fusion_360_Brian_Ekins.pdf) benennt den Autodesk Shape Manager (ASM) als Modellierkernel von Fusion.
- Geprüfter SolidCraft-Stand: [`98b57a3`](https://github.com/tangency-labs/solidcraft/tree/98b57a3588170ec1a1c7acc91b4bf8a60ea29865), MIT/Apache-2.0. Die [Fit-Prüfung](https://github.com/tangency-labs/solidcraft/blob/98b57a3588170ec1a1c7acc91b4bf8a60ea29865/crates/kernel/src/blend_fit.rs) liegt getrennt von der eigentlichen Rundung; [Tests zu Taschen und sich kreuzenden Rundungen](https://github.com/tangency-labs/solidcraft/blob/98b57a3588170ec1a1c7acc91b4bf8a60ea29865/crates/kernel/src/issue_1080_tests.rs) lehnen zu große Radien ausdrücklich ab.

## Technischer Abgleich

| Aspekt | Fusion 360 | SolidCraft 98b57a3 | PencilCAD Build 16 / Arbeitsstand 17 |
|---|---|---|---|
| Kernel | ASM laut Autodesk | Rust/SolidCore | OpenCASCADE |
| Grenzfälle | API bietet Kanten-Sets und Eckoptionen; interner Algorithmus öffentlich nicht dokumentiert | Vorabprüfung eines Versatzkeils je gerader Kante; erkennt Nachbarflächen und überlappende Rundungen, schätzt den größten passenden Radius | OCCT berechnet; Arbeitsstand 17 prüft BRep, triangulierte Flächen und Körpergrenzen vor der Vorschau |
| Projekt 8, Fläche 8, R7 | Nicht mit Originalmodell in Fusion geprüft | Nicht mit Originalmodell in SolidCraft geprüft | Ungültige BRep-/Mesh-Ausgabe reproduziert; Arbeitsstand 17 verwirft sie |
| Verfügbarkeit des Quellcodes | Öffentliche API-Beispiele, kein eigenständig nutzbarer ASM-Quellcode gefunden | Geometriecode offen lizenziert | PencilCAD-Quellcode und eingebundener OCCT-Kernel lokal vorhanden |

## Folgerung

Die SolidCraft-Fit-Prüfung ist als eigenständige Vorprüfung interessant. Ihr Ansatz setzt geradlinige Kanten mit ebenen Nachbarflächen voraus und löst den OCCT-Absturz nicht. Für PencilCAD ist zuerst die Validierung realer Anwendergeometrie wichtig, danach ein gezielter Fit-Test für diese unterstützten Fälle. Eine allgemeine Behauptung, jeder Radius könne bis zum Verschwinden des Körpers funktionieren, wäre geometrisch und durch die Tests nicht gedeckt.
