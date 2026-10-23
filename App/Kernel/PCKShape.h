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

/// Gerades Prisma: geschlossenes ebenes Polygon (xyz abwechselnd), verschoben um direction.
/// nil bei ungültigem Profil.
+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction
    NS_SWIFT_NAME(prism(pointsXYZ:direction:));

/// Boolesche Operationen. nil, wenn die Operation fehlschlägt oder kein Kernel vorhanden ist.
- (nullable PCKShape *)cutting:(PCKShape *)tool NS_SWIFT_NAME(cutting(_:));
- (nullable PCKShape *)fusing:(PCKShape *)other NS_SWIFT_NAME(fusing(_:));

/// Rundet bzw. fast alle Kanten einer Fläche (Nummer aus faceIndexData). nil bei Fehler.
- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius
    NS_SWIFT_NAME(filletingEdges(ofFace:radius:));
- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance
    NS_SWIFT_NAME(chamferingEdges(ofFace:distance:));

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
