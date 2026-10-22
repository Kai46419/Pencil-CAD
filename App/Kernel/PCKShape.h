// Objective-C-Schnittstelle zum Geometriekernel (OpenCASCADE).
// Swift sieht nur diese Klassen; alles C++ bleibt in PCKShape.mm.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Dreiecksnetz für den Renderer.
@interface PCKMesh : NSObject
/// Float32 je Vertex: x, y, z, nx, ny, nz
@property (nonatomic, readonly) NSData *vertexData;
/// UInt32, drei Indizes je Dreieck
@property (nonatomic, readonly) NSData *indexData;
@end

/// Unveränderlicher Volumenkörper (B-Rep). Jede Operation liefert einen neuen Körper.
@interface PCKShape : NSObject

/// YES, wenn die App mit OpenCASCADE gebaut wurde.
@property (class, nonatomic, readonly) BOOL kernelAvailable;

/// Quader, in X/Y zentriert, Unterseite auf Z = 0. Maße in mm.
+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height
    NS_SWIFT_NAME(box(width:depth:height:));

/// Zylinder entlang +Z, Grundfläche im Punkt (x, y, z).
+ (PCKShape *)cylinderAtX:(double)x y:(double)y z:(double)z radius:(double)radius height:(double)height
    NS_SWIFT_NAME(cylinder(x:y:z:radius:height:));

/// Gerades Prisma aus einem geschlossenen Polygon in der Ebene Z = z, extrudiert um height entlang Z
/// (negativ = nach unten). xy enthält die Eckpunkte abwechselnd als x, y. nil bei ungültigem Profil.
+ (nullable PCKShape *)prismFromPolygonXY:(NSArray<NSNumber *> *)xy z:(double)z height:(double)height
    NS_SWIFT_NAME(prism(polygonXY:z:height:));

/// Boolesche Operationen. nil, wenn die Operation fehlschlägt oder kein Kernel vorhanden ist.
- (nullable PCKShape *)cutting:(PCKShape *)tool NS_SWIFT_NAME(cutting(_:));
- (nullable PCKShape *)fusing:(PCKShape *)other NS_SWIFT_NAME(fusing(_:));

/// Rundet alle Kanten. nil bei Fehler (z. B. Radius zu groß).
- (nullable PCKShape *)filletingAllEdgesWithRadius:(double)radius NS_SWIFT_NAME(filletingAllEdges(radius:));

/// Trianguliert den Körper. deflection = maximale Sehnenabweichung in mm.
- (PCKMesh *)triangulateWithDeflection:(double)deflection NS_SWIFT_NAME(triangulate(deflection:));

@end

NS_ASSUME_NONNULL_END
