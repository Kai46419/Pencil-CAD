// Objective-C-Schnittstelle zum Geometriekernel (OpenCASCADE).
// Swift sieht nur diese Klassen; alles C++ bleibt in PCKShape.mm.
#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// Dreiecksnetz und Kantenlinien für den Renderer.
@interface PCKMesh : NSObject
/// Float32 je Vertex: x, y, z, nx, ny, nz
@property (nonatomic, readonly) NSData *vertexData;
/// UInt32, drei Indizes je Dreieck
@property (nonatomic, readonly) NSData *indexData;
/// UInt32 je Dreieck: Nummer der Fläche (ab 1), passend zu planeOfFace:, filletingEdgesOfFace: usw.
@property (nonatomic, readonly) NSData *faceIndexData;
/// Float32-Punktpaare (x, y, z, x, y, z) der sichtbaren Kanten
@property (nonatomic, readonly) NSData *edgeData;
/// UInt32 je Punktpaar: Nummer der Kante (ab 1, 0 = unbekannt), passend zu filletingEdges: usw.
@property (nonatomic, readonly) NSData *edgeIndexData;
@end

/// Unveränderlicher Volumenkörper (B-Rep). Jede Operation liefert einen neuen Körper.
@interface PCKShape : NSObject

/// YES, wenn die App mit OpenCASCADE gebaut wurde.
@property (class, nonatomic, readonly) BOOL kernelAvailable;
/// YES, wenn STEP-Import/-Export verfügbar ist.
@property (class, nonatomic, readonly) BOOL stepAvailable;

/// Quader, in X/Y zentriert, Unterseite auf Z = 0. Maße in mm.
+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height
    NS_SWIFT_NAME(box(width:depth:height:));

/// Zylinder: Grundkreis um base, entlang axis (wird normiert) um height > 0.
+ (nullable PCKShape *)cylinderWithBase:(simd_double3)base axis:(simd_double3)axis
                                 radius:(double)radius height:(double)height
    NS_SWIFT_NAME(cylinder(base:axis:radius:height:));

/// Kugel um center.
+ (nullable PCKShape *)sphereWithCenter:(simd_double3)center radius:(double)radius
    NS_SWIFT_NAME(sphere(center:radius:));

/// Kegel bzw. Kegelstumpf: Grundkreis um base, entlang axis um height > 0. topRadius darf 0 sein.
+ (nullable PCKShape *)coneWithBase:(simd_double3)base axis:(simd_double3)axis
                       bottomRadius:(double)bottomRadius topRadius:(double)topRadius height:(double)height
    NS_SWIFT_NAME(cone(base:axis:bottomRadius:topRadius:height:));

/// Ellipse in der Ebene durch center mit Normale normal (xAxis liegt in der Ebene), verschoben um direction.
+ (nullable PCKShape *)ellipsePrismWithCenter:(simd_double3)center normal:(simd_double3)normal
                                        xAxis:(simd_double3)xAxis radiusX:(double)radiusX
                                      radiusY:(double)radiusY direction:(simd_double3)direction
    NS_SWIFT_NAME(ellipsePrism(center:normal:xAxis:radiusX:radiusY:direction:));

/// Gerades Prisma: geschlossenes ebenes Polygon (xyz abwechselnd), verschoben um direction.
/// nil bei ungültigem Profil.
+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction
    NS_SWIFT_NAME(prism(pointsXYZ:direction:));

/// Prisma aus einem Skizzenprofil mit exakten Kurven, verschoben um direction.
/// wires[0] ist die Außenkontur, weitere Einträge sind Löcher. Jede Kontur ist eine Folge von Segmenten,
/// jeweils Typnummer und Werte in Weltkoordinaten:
///   0 Linie: p1, p2
///   1 Bogen durch drei Punkte: Start, Punkt auf dem Bogen, Ende
///   2 Kette kubischer Bézierkurven: n, dann n = 3k + 1 Pole (Fit-Spline)
///   3 Vollkreis: Mitte, Normale, Radius
///   4 Vollellipse: Mitte, Normale, X-Achse, Radius X, Radius Y
///   5 B-Spline durch Kontrollpunkte, Enden fest: n, dann n Pole
///   6 geschlossener (periodischer) kubischer B-Spline: n, dann n Pole
/// nil bei ungültigem Profil oder ohne Kernel.
+ (nullable PCKShape *)prismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires direction:(simd_double3)direction
    NS_SWIFT_NAME(prism(profileWires:direction:));

/// Prisma wie prismWithProfileWires:, die Seitenflächen um degrees geneigt (Verjüngung wie in Fusion 360,
/// Neutralebene = Profilebene). nil, wenn der Kernel die Neigung nicht bilden kann.
+ (nullable PCKShape *)draftPrismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
                                        direction:(simd_double3)direction angle:(double)degrees
    NS_SWIFT_NAME(draftPrism(profileWires:direction:angle:));

/// Ebene Fläche aus einem Skizzenprofil (Kodierung wie oben), z. B. zum Einfärben eines Bereichs.
+ (nullable PCKShape *)faceWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
    NS_SWIFT_NAME(face(profileWires:));

/// Torus um center, Achse axis; minorRadius < majorRadius.
+ (nullable PCKShape *)torusWithCenter:(simd_double3)center axis:(simd_double3)axis
                           majorRadius:(double)majorRadius minorRadius:(double)minorRadius
    NS_SWIFT_NAME(torus(center:axis:majorRadius:minorRadius:));

/// Rotationskörper eines Skizzenprofils um eine Achse; Winkel im Bogenmaß (negativ = Gegenrichtung, max. 2π).
+ (nullable PCKShape *)revolveProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires axisOrigin:(simd_double3)origin
                             axisDirection:(simd_double3)direction angle:(double)radians
    NS_SWIFT_NAME(revolve(profileWires:axisOrigin:axisDirection:angle:));

/// Profil entlang eines offenen Pfads ziehen (Pfad kodiert wie eine Kontur).
+ (nullable PCKShape *)sweepProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires path:(NSArray<NSNumber *> *)path
    NS_SWIFT_NAME(sweep(profileWires:path:));

/// Übergangskörper durch mehrere geschlossene Konturen (in Reihenfolge).
+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections NS_SWIFT_NAME(loft(sections:));

/// Fasst mehrere Körper zu einem Verbund zusammen (ohne Kernel: nur der erste).
+ (nullable PCKShape *)compoundOfShapes:(NSArray<PCKShape *> *)shapes NS_SWIFT_NAME(compound(_:));

/// Boolesche Operationen. nil, wenn die Operation fehlschlägt oder kein Kernel vorhanden ist.
- (nullable PCKShape *)cutting:(PCKShape *)tool NS_SWIFT_NAME(cutting(_:));
- (nullable PCKShape *)fusing:(PCKShape *)other NS_SWIFT_NAME(fusing(_:));
- (nullable PCKShape *)intersecting:(PCKShape *)other NS_SWIFT_NAME(intersecting(_:));

/// Zieht eine ebene Fläche entlang ihrer Normale: distance > 0 trägt Material auf, < 0 trägt ab.
- (nullable PCKShape *)extrudingFace:(NSInteger)face distance:(double)distance
    NS_SWIFT_NAME(extruding(face:distance:));

/// Mehrere ebene Flächen zugleich entlang ihrer eigenen Normale ziehen (Nummern bleiben gültig, weil alle
/// Prismen aus dem Ausgangskörper entstehen).
- (nullable PCKShape *)extrudingFaces:(NSArray<NSNumber *> *)faces distance:(double)distance
    NS_SWIFT_NAME(extruding(faces:distance:));

/// Fläche versetzen (Shapr3D „Offset Face“): Flächen um distance nach außen (> 0) bzw. innen verschieben,
/// Nachbarflächen werden verlängert oder gekürzt; geht auch mit Zylinderflächen (Bohrung weiter/enger).
- (nullable PCKShape *)offsettingFaces:(NSArray<NSNumber *> *)faces distance:(double)distance
    NS_SWIFT_NAME(offsetting(faces:distance:));

/// Fläche ersetzen (Shapr3D „Replace Face“): ebene Flächen bis an die Zielebene verlängern bzw. kürzen.
- (nullable PCKShape *)replacingFaces:(NSArray<NSNumber *> *)faces planeOrigin:(simd_double3)origin
                          planeNormal:(simd_double3)normal NS_SWIFT_NAME(replacing(faces:planeOrigin:planeNormal:));

/// Zylinderfläche als [ox, oy, oz, dx, dy, dz, r] (Achse und Radius); nil bei anderen Flächen.
- (nullable NSArray<NSNumber *> *)cylinderOfFace:(NSInteger)face NS_SWIFT_NAME(cylinder(ofFace:));

/// Körper zwischen zwei geschlossenen Linienzügen gleicher Punktzahl (x, y, z je Punkt), Seiten geradlinig
/// verbunden (für „Umhüllen und Prägen“).
+ (nullable PCKShape *)ruledSolidBetween:(NSArray<NSNumber *> *)first and:(NSArray<NSNumber *> *)second
    NS_SWIFT_NAME(ruledSolid(between:and:));

/// Kante abdrücken (Imprint): teilt die Körperflächen entlang der Werkzeugform (z. B. einer Skizzenfläche auf
/// der Körperfläche); der Körper bleibt ganz, bekommt aber neue Kanten und Teilflächen.
- (nullable PCKShape *)imprinting:(PCKShape *)tool NS_SWIFT_NAME(imprinting(_:));

/// Schale: entfernt die Fläche (Nummer aus faceIndexData) und höhlt den Körper mit der Wandstärke aus.
- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness
    NS_SWIFT_NAME(shelling(removingFace:thickness:));
/// Schale mit mehreren offenen Flächen; ohne Flächen entsteht ein geschlossener Hohlkörper.
- (nullable PCKShape *)shellingRemovingFaces:(NSArray<NSNumber *> *)faces thickness:(double)thickness
    NS_SWIFT_NAME(shelling(removingFaces:thickness:));

/// Lageänderungen; liefern jeweils einen neuen Körper.
- (nullable PCKShape *)translatedBy:(simd_double3)offset NS_SWIFT_NAME(translated(by:));
- (nullable PCKShape *)rotatedAroundOrigin:(simd_double3)origin axis:(simd_double3)axis angle:(double)radians
    NS_SWIFT_NAME(rotated(origin:axis:angle:));
- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal
    NS_SWIFT_NAME(mirrored(planeOrigin:normal:));

/// Skalieren um center, je Achse ein Faktor (gleiche Faktoren = gleichmäßig).
- (nullable PCKShape *)scaledAboutPoint:(simd_double3)center factors:(simd_double3)factors
    NS_SWIFT_NAME(scaled(center:factors:));

/// Teilt den Körper an einer Ebene in zwei Körper; nil, wenn die Ebene ihn nicht schneidet.
- (nullable NSArray<PCKShape *> *)splitAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal
    NS_SWIFT_NAME(split(planeOrigin:normal:));
/// Teilt den Körper mit einem Werkzeug (anderer Körper, Prisma aus Skizzenbereichen …) in alle entstehenden
/// Teilkörper; nil, wenn weniger als zwei Teile entstehen.
- (nullable NSArray<PCKShape *> *)splitByTool:(PCKShape *)tool NS_SWIFT_NAME(split(by:));

/// Messwerte (mm, mm², mm³); 0 ohne Kernel.
@property (nonatomic, readonly) double volume;
/// Schwerpunkt [x, y, z] (gleichmäßige Dichte); nil ohne Kernel.
@property (nonatomic, readonly, nullable) NSArray<NSNumber *> *centerOfMass;
/// Kürzester Abstand zu einem anderen Körper: [Abstand, x1, y1, z1, x2, y2, z2]; nil bei Fehler.
- (nullable NSArray<NSNumber *> *)minimumDistanceTo:(PCKShape *)other NS_SWIFT_NAME(minimumDistance(to:));
- (double)lengthOfEdge:(NSInteger)edge NS_SWIFT_NAME(length(ofEdge:));
- (double)areaOfFace:(NSInteger)face NS_SWIFT_NAME(area(ofFace:));
/// Kantennummern einer Fläche (ohne Nahtkanten).
- (NSArray<NSNumber *> *)edgeNumbersOfFace:(NSInteger)face NS_SWIFT_NAME(edgeNumbers(ofFace:));

/// Rundet bzw. fast alle Kanten einer Fläche (Nummer aus faceIndexData). nil bei Fehler.
- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius
    NS_SWIFT_NAME(filletingEdges(ofFace:radius:));
- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance
    NS_SWIFT_NAME(chamferingEdges(ofFace:distance:));

/// Rundet bzw. fast einzelne Kanten (Nummern aus edgeIndexData). nil bei Fehler.
- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius
    NS_SWIFT_NAME(filleting(edges:radius:));
- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance
    NS_SWIFT_NAME(chamfering(edges:distance:));
/// Fase mit zwei Abständen (distance auf der einen, distance2 auf der anderen Nachbarfläche).
- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance
                             distance2:(double)distance2 NS_SWIFT_NAME(chamfering(edges:distance:distance2:));

/// Größter Radius bzw. größte Fasenbreite bis limit, die für diese Kanten noch geht (Halbierungssuche,
/// auf 1 % genau). 0, wenn gar nichts geht.
- (double)maximumBlendForEdges:(NSArray<NSNumber *> *)edges upTo:(double)limit chamfer:(BOOL)chamfer
    NS_SWIFT_NAME(maximumBlend(edges:upTo:chamfer:));

/// Ziehpfeil für eine Kante als [px, py, pz, dx, dy, dz]: Kantenmitte und Richtung ins Material
/// (Winkelhalbierende der beiden Flächen). nil ohne Kernel oder bei ungültiger Kante.
- (nullable NSArray<NSNumber *> *)handleOfEdge:(NSInteger)edge NS_SWIFT_NAME(handle(ofEdge:));

/// Vorhandene Rundung bzw. Fase einer Fläche als [Art, Wert]: Art 1 = Rundung (Radius der Zylinder- bzw.
/// Torusfläche), Art 2 = Fase (Schenkellänge einer schmalen, schräg anschließenden ebenen Fläche).
/// nil bei anderen Flächen oder ohne Kernel.
- (nullable NSArray<NSNumber *> *)blendOfFace:(NSInteger)face NS_SWIFT_NAME(blend(ofFace:));

/// Ebene einer planaren Fläche als [ox, oy, oz, nx, ny, nz], Normale zeigt aus dem Körper heraus.
/// nil bei gekrümmten Flächen.
- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)face NS_SWIFT_NAME(plane(ofFace:));

/// Trianguliert den Körper. deflection = maximale Sehnenabweichung in mm.
- (PCKMesh *)triangulateWithDeflection:(double)deflection NS_SWIFT_NAME(triangulate(deflection:));

/// STEP (AP214, Einheit mm). nil bzw. NO bei Fehler oder ohne STEP-Unterstützung.
+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path NS_SWIFT_NAME(readSTEP(path:));
+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path
    NS_SWIFT_NAME(writeSTEP(_:path:));

@end

NS_ASSUME_NONNULL_END
