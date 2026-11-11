#import "PCKShape.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <exception>
#include <utility>
#include <vector>

// Hinweise aus den OpenCASCADE-Headern (Doku-Kommentare, sprintf) ausblenden – sie betreffen nicht unseren Code
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-html"
#pragma clang diagnostic ignored "-Wdocumentation-unknown-command"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#if __has_include(<BRepPrimAPI_MakeBox.hxx>)
#define PCK_HAS_OCCT 1
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Splitter.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepOffset_MakeOffset.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepGProp.hxx>
#include <BRepTools.hxx>
#include <sstream>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeHalfSpace.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <GProp_GProps.hxx>
#include <gp_GTrsf.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBndLib.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <Bnd_Box.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
// Rundungsoptionen (Build 42): Setback-Füllfläche, G2-Profil-Sweep
#include <BRepFill_Filling.hxx>
#include <BRepTools_ReShape.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_BezierCurve.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_Ellipse.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <Geom_Surface.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_ShapeTolerance.hxx>
#include <ShapeFix_Solid.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <Geom2d_Curve.hxx>
#include <Poly_Triangulation.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Iterator.hxx>
#include <TopoDS_Solid.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax1.hxx>
#include <gp_Circ.hxx>
#include <gp_Ax2.hxx>
#include <gp_Elips.hxx>
#include <gp_Trsf.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Cone.hxx>
#include <gp_Sphere.hxx>
#include <gp_Lin.hxx>
#include <gp_Pln.hxx>
#include <gp_Torus.hxx>
#include <gp_Pnt2d.hxx>
// Dünn extrudieren, Schraubenlinien, Sweep entlang Kanten (TKOffset, TKTopAlgo, TKG2d/TKG3d)
#include <BRepLib.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepOffsetAPI_MakePipeShell.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_CylindricalSurface.hxx>
#include <Geom_ConicalSurface.hxx>
#include <ShapeFix_Shape.hxx>
#include <gp.hxx>
#include <gp_Ax3.hxx>
#include <gp_Dir2d.hxx>
#else
#define PCK_HAS_OCCT 0
#endif

#if PCK_HAS_OCCT && __has_include(<STEPControl_Writer.hxx>)
#define PCK_HAS_STEP 1
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <chrono>
#include <mutex>
// STEP-Lesen/-Schreiben nutzt globale Zustände von OCCT (Interface_Static, Steuerung der Schnittstelle) und ist nicht
// threadsicher. Der Vordergrund (Speichern, Import, Verlauf) und die Warteschlange des Blechmoduls (SheetWorker; nach
// einem Zeitlimit läuft deren Rechnung weiter) dürfen deshalb nie gleichzeitig STEP lesen oder schreiben.
// B11: zeitlich begrenzte Sperre – hängt eine STEP-Rechnung im Hintergrund, darf save() nicht unbegrenzt warten.
// Nach kPCKSTEPLockSeconds ohne Sperre liefert die Funktion nil bzw. NO (Speichern meldet dann einen Fehler).
static std::recursive_timed_mutex &pckSTEPMutex() {
    static std::recursive_timed_mutex mutex;
    return mutex;
}
static const int kPCKSTEPLockSeconds = 30;
#else
#define PCK_HAS_STEP 0
#endif

// Verdeckte Kanten für technische Zeichnungen (TKHLR gehört zum Modul ModelingAlgorithms)
#if PCK_HAS_OCCT && __has_include(<HLRBRep_Algo.hxx>)
#define PCK_HAS_HLR 1
#include <BRepLib.hxx>
#include <HLRAlgo_Projector.hxx>
#include <HLRBRep_Algo.hxx>
#include <HLRBRep_HLRToShape.hxx>
#else
#define PCK_HAS_HLR 0
#endif

// Netze (STL/3MF) als Körper (MeshImport.swift)
#if PCK_HAS_OCCT
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <Geom_Plane.hxx>
#include <Precision.hxx>
#include <TopoDS_Shell.hxx>
#endif
#pragma clang diagnostic pop

namespace {

struct MeshBuffers {
    std::vector<float> vertices; // x y z nx ny nz
    std::vector<uint32_t> indices;
    std::vector<uint32_t> triangleFaces;
    std::vector<float> edges; // Punktpaare
    std::vector<uint32_t> edgeNumbers; // je Punktpaar

    uint32_t addVertex(simd_double3 p, simd_double3 n) {
        const uint32_t index = static_cast<uint32_t>(vertices.size() / 6);
        vertices.insert(vertices.end(), {float(p.x), float(p.y), float(p.z), float(n.x), float(n.y), float(n.z)});
        return index;
    }

    void addTriangle(uint32_t a, uint32_t b, uint32_t c, uint32_t face) {
        indices.insert(indices.end(), {a, b, c});
        triangleFaces.push_back(face);
    }

    void addEdge(simd_double3 a, simd_double3 b, uint32_t number = 0) {
        edges.insert(edges.end(), {float(a.x), float(a.y), float(a.z), float(b.x), float(b.y), float(b.z)});
        edgeNumbers.push_back(number);
    }
};

std::vector<double> toVector(NSArray<NSNumber *> *values) {
    std::vector<double> result;
    result.reserve(values.count);
    for (NSNumber *number in values) {
        result.push_back(number.doubleValue);
    }
    return result;
}

std::vector<simd_double3> toPoints(NSArray<NSNumber *> *xyz) {
    const std::vector<double> v = toVector(xyz);
    std::vector<simd_double3> points;
    for (size_t i = 0; i + 2 < v.size(); i += 3) {
        points.push_back(simd_make_double3(v[i], v[i + 1], v[i + 2]));
    }
    return points;
}

#if !PCK_HAS_OCCT
/// Orthonormale Basis senkrecht zu axis.
std::pair<simd_double3, simd_double3> basisFor(simd_double3 axis) {
    const simd_double3 n = simd_normalize(axis);
    const simd_double3 ref = std::fabs(n.z) < 0.9 ? simd_make_double3(0, 0, 1) : simd_make_double3(1, 0, 0);
    const simd_double3 u = simd_normalize(simd_cross(ref, n));
    return {u, simd_cross(n, u)};
}

// Fallback ohne Kernel: einfache Netze, damit Viewer, Skizze und UI ohne OpenCASCADE testbar sind.
struct FallbackBody {
    MeshBuffers mesh;
    std::vector<std::array<double, 6>> planes; // je Fläche (Index = Nummer - 1)
    std::vector<bool> planar;
};

/// Prisma aus Polygon. smoothSides: Seiten bilden eine gekrümmte Fläche (für Zylinder).
/// Deckel werden als Fächer trianguliert, das ist nur für konvexe Profile korrekt.
FallbackBody fallbackPrism(const std::vector<simd_double3> &points, simd_double3 direction, bool smoothSides) {
    FallbackBody body;
    const size_t n = points.size();
    if (n < 3 || simd_length(direction) == 0) return body;

    // Polygonnormale nach Newell, passt zur Umlaufrichtung
    simd_double3 pn = simd_make_double3(0, 0, 0);
    for (size_t i = 0; i < n; ++i) {
        pn += simd_cross(points[i], points[(i + 1) % n]);
    }
    pn = simd_normalize(pn);
    const simd_double3 dir = simd_normalize(direction);
    const bool flipped = simd_dot(pn, dir) < 0;
    MeshBuffers &m = body.mesh;

    auto addPlane = [&](simd_double3 origin, simd_double3 normal) {
        body.planes.push_back({origin.x, origin.y, origin.z, normal.x, normal.y, normal.z});
        body.planar.push_back(true);
    };

    // Seiten
    if (smoothSides) {
        body.planes.push_back({0, 0, 0, 0, 0, 0});
        body.planar.push_back(false);
    }
    const simd_double3 center = [&] {
        simd_double3 c = simd_make_double3(0, 0, 0);
        for (const auto &p : points) c += p;
        return c / double(n);
    }();
    for (size_t i = 0; i < n; ++i) {
        const simd_double3 a = points[i], b = points[(i + 1) % n];
        simd_double3 outward = simd_normalize(simd_cross(b - a, pn));
        if (flipped) outward = -outward;
        uint32_t face;
        simd_double3 na = outward, nb = outward;
        if (smoothSides) {
            face = 1;
            na = simd_normalize(a - center);
            nb = simd_normalize(b - center);
        } else {
            addPlane(a, outward);
            face = uint32_t(body.planes.size());
        }
        const uint32_t v0 = m.addVertex(a, na), v1 = m.addVertex(b, nb);
        const uint32_t v2 = m.addVertex(b + direction, nb), v3 = m.addVertex(a + direction, na);
        m.addTriangle(v0, v1, v2, face);
        m.addTriangle(v0, v2, v3, face);
        m.addEdge(a, b);
        m.addEdge(a + direction, b + direction);
        if (!smoothSides) m.addEdge(a, a + direction);
    }

    // Deckel
    for (int cap = 0; cap < 2; ++cap) {
        const simd_double3 offset = cap == 0 ? simd_make_double3(0, 0, 0) : direction;
        const simd_double3 normal = cap == 0 ? -dir : dir;
        addPlane(points[0] + offset, normal);
        const uint32_t face = uint32_t(body.planes.size());
        const uint32_t base = static_cast<uint32_t>(m.vertices.size() / 6);
        for (const auto &p : points) m.addVertex(p + offset, normal);
        for (size_t i = 1; i + 1 < n; ++i) {
            m.addTriangle(base, base + uint32_t(i), base + uint32_t(i + 1), face);
        }
    }
    return body;
}

std::vector<simd_double3> circlePoints(simd_double3 base, simd_double3 axis, double radius, int segments) {
    const auto [u, v] = basisFor(axis);
    std::vector<simd_double3> points;
    for (int i = 0; i < segments; ++i) {
        const double a = 2 * M_PI * i / segments;
        points.push_back(base + radius * (std::cos(a) * u + std::sin(a) * v));
    }
    return points;
}
#endif

} // namespace

/// Brauchbare Richtung bzw. Achse (B9): alle Komponenten endlich und Länge > 1e-9. Der frühere Test
/// `simd_length(d) == 0` ließ NaN durch (NaN == 0 ist falsch) – gp_Dir wirft dann bzw. rechnet mit NaN weiter.
static bool validDir(simd_double3 d) {
    if (!std::isfinite(d.x) || !std::isfinite(d.y) || !std::isfinite(d.z)) return false;
    const double length = simd_length(d);
    return std::isfinite(length) && length > 1e-9;
}

@implementation PCKMesh

- (instancetype)initWithBuffers:(const MeshBuffers &)buffers {
    if ((self = [super init])) {
        _vertexData = [NSData dataWithBytes:buffers.vertices.data() length:buffers.vertices.size() * sizeof(float)];
        _indexData = [NSData dataWithBytes:buffers.indices.data() length:buffers.indices.size() * sizeof(uint32_t)];
        _faceIndexData = [NSData dataWithBytes:buffers.triangleFaces.data()
                                        length:buffers.triangleFaces.size() * sizeof(uint32_t)];
        _edgeData = [NSData dataWithBytes:buffers.edges.data() length:buffers.edges.size() * sizeof(float)];
        _edgeIndexData = [NSData dataWithBytes:buffers.edgeNumbers.data()
                                        length:buffers.edgeNumbers.size() * sizeof(uint32_t)];
    }
    return self;
}

@end

@implementation PCKBlendOptions

+ (instancetype)standardOptions { return [[PCKBlendOptions alloc] init]; }

- (instancetype)init {
    if ((self = [super init])) {
        _corner = PCKBlendCornerRollingBall;
        _setback = 0;
        _continuity = PCKBlendContinuityG1;
        _profile = PCKBlendProfileCircle;
        _rho = 0.5;
        _overflow = PCKBlendOverflowAutomatic;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    PCKBlendOptions *copy = [[PCKBlendOptions allocWithZone:zone] init];
    copy.corner = _corner;
    copy.setback = _setback;
    copy.continuity = _continuity;
    copy.profile = _profile;
    copy.rho = _rho;
    copy.overflow = _overflow;
    return copy;
}

- (BOOL)isStandard {
    return _corner == PCKBlendCornerRollingBall && _continuity == PCKBlendContinuityG1
        && _profile == PCKBlendProfileCircle && _overflow == PCKBlendOverflowAutomatic;
}

- (BOOL)isValid {
    if (_corner == PCKBlendCornerSetback && !(std::isfinite(_setback) && _setback > 0)) return NO;
    if (_profile == PCKBlendProfileConic) {
        if (_continuity != PCKBlendContinuityG2) return NO;
        if (!(std::isfinite(_rho) && _rho >= 0.1 && _rho <= 0.9)) return NO;
    }
    return YES;
}

@end

@implementation PCKShape {
#if PCK_HAS_OCCT
    TopoDS_Shape _shape;
    TopTools_IndexedMapOfShape _faces;
    TopTools_IndexedMapOfShape _edges;
    /// Zuletzt berechnetes Netz (der Körper ändert sich nie): große Netzkörper nicht bei jeder Änderung neu zerlegen
    PCKMesh *_cachedMesh;
    double _cachedDeflection;
#else
    FallbackBody _fallback;
#endif
}

+ (BOOL)kernelAvailable {
    return PCK_HAS_OCCT;
}

+ (BOOL)stepAvailable {
    return PCK_HAS_STEP;
}

#if PCK_HAS_OCCT

- (instancetype)initWithShape:(const TopoDS_Shape &)shape {
    if ((self = [super init])) {
        _shape = shape;
        TopExp::MapShapes(_shape, TopAbs_FACE, _faces);
        TopExp::MapShapes(_shape, TopAbs_EDGE, _edges);
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    BRepPrimAPI_MakeBox maker(gp_Pnt(-width / 2, -depth / 2, 0), width, depth, height);
    return [[PCKShape alloc] initWithShape:maker.Shape()];
}

+ (nullable PCKShape *)cylinderWithBase:(simd_double3)base axis:(simd_double3)axis
                                 radius:(double)radius height:(double)height {
    if (radius <= 0 || height <= 0 || !validDir(axis)) return nil;
    try {
        BRepPrimAPI_MakeCylinder maker(gp_Ax2(gp_Pnt(base.x, base.y, base.z), gp_Dir(axis.x, axis.y, axis.z)),
                                       radius, height);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (...) {
        return nil;
    }
}

static gp_Pnt toPnt(simd_double3 p) {
    return gp_Pnt(p.x, p.y, p.z);
}

static gp_Dir toDir(simd_double3 d) {
    return gp_Dir(d.x, d.y, d.z);
}

// Weiter unten definiert (Prüfung der Ergebnisse, B3–B7)
static TopoDS_Shape validSolid(const TopoDS_Shape &shape);
static TopoDS_Shape checkedResult(const TopoDS_Shape &shape);

/// Geschlossene Einzelkurve (Ellipse, geschlossener Spline) als zwei Hälften: die erste kommt sofort in den
/// Draht, die zweite zurück. Ohne Naht mitten auf der Seitenfläche lassen sich die Kanten extrudierter
/// Ellipsen und Splines verrunden und fasen (BRepFilletAPI scheitert sonst an der geschlossenen Kante).
static bool addHalves(BRepBuilderAPI_MakeWire &wire, const Handle(Geom_Curve) &curve, TopoDS_Edge &second) {
    const double u0 = curve->FirstParameter(), u1 = curve->LastParameter(), um = 0.5 * (u0 + u1);
    BRepBuilderAPI_MakeEdge first(curve, u0, um);
    BRepBuilderAPI_MakeEdge last(curve, um, u1);
    if (!first.IsDone() || !last.IsDone()) return false;
    wire.Add(first.Edge());
    if (!wire.IsDone()) return false;
    second = last.Edge();
    return true;
}

+ (nullable PCKShape *)sphereWithCenter:(simd_double3)center radius:(double)radius {
    if (radius <= 0) return nil;
    try {
        BRepPrimAPI_MakeSphere maker(toPnt(center), radius);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)coneWithBase:(simd_double3)base axis:(simd_double3)axis
                       bottomRadius:(double)bottomRadius topRadius:(double)topRadius height:(double)height {
    if (bottomRadius < 0 || topRadius < 0 || bottomRadius + topRadius <= 0 || height <= 0 ||
        !validDir(axis)) return nil;
    try {
        BRepPrimAPI_MakeCone maker(gp_Ax2(toPnt(base), toDir(axis)), bottomRadius, topRadius, height);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)ellipsePrismWithCenter:(simd_double3)center normal:(simd_double3)normal
                                        xAxis:(simd_double3)xAxis radiusX:(double)radiusX
                                      radiusY:(double)radiusY direction:(simd_double3)direction {
    if (radiusX <= 0 || radiusY <= 0 || !validDir(direction) || !validDir(normal)) return nil;
    try {
        // gp_Elips verlangt Hauptradius >= Nebenradius; sonst Hauptachse um 90° drehen.
        simd_double3 major = xAxis;
        double rMajor = radiusX, rMinor = radiusY;
        if (radiusY > radiusX) {
            major = simd_cross(simd_normalize(normal), xAxis);
            std::swap(rMajor, rMinor);
        }
        const gp_Elips ellipse(gp_Ax2(toPnt(center), toDir(normal), toDir(major)), rMajor, rMinor);
        // Zwei Hälften statt einer geschlossenen Kante: sonst lassen sich die Kanten nicht verrunden
        BRepBuilderAPI_MakeWire wire;
        TopoDS_Edge second;
        if (!addHalves(wire, new Geom_Ellipse(ellipse), second)) return nil;
        wire.Add(second);
        if (!wire.IsDone()) return nil;
        BRepBuilderAPI_MakeFace face(wire.Wire(), Standard_True);
        if (!face.IsDone()) return nil;
        BRepPrimAPI_MakePrism prism(face.Face(), gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction {
    const std::vector<simd_double3> points = toPoints(xyz);
    if (points.size() < 3 || !validDir(direction)) return nil;
    try {
        BRepBuilderAPI_MakePolygon polygon;
        for (const auto &p : points) {
            polygon.Add(gp_Pnt(p.x, p.y, p.z));
        }
        polygon.Close();
        if (!polygon.IsDone()) return nil;
        BRepBuilderAPI_MakeFace face(polygon.Wire(), Standard_True);
        if (!face.IsDone()) return nil;
        BRepPrimAPI_MakePrism prism(face.Face(), gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (...) {
        return nil;
    }
}

/// B-Spline aus Polen. clamped: Enden liegen auf dem ersten und letzten Pol (gleichmäßige innere Knoten),
/// sonst periodisch und kubisch. bezierChain: Pole bilden eine Kette kubischer Bézierkurven (3k + 1 Pole).
static Handle(Geom_BSplineCurve) makeBSpline(const std::vector<gp_Pnt> &poles, bool periodic, bool bezierChain) {
    const int n = int(poles.size());
    TColgp_Array1OfPnt array(1, n);
    for (int i = 0; i < n; ++i) array.SetValue(i + 1, poles[size_t(i)]);
    if (bezierChain) {
        const int segments = (n - 1) / 3;
        if (segments < 1 || segments * 3 + 1 != n) return nullptr;
        TColStd_Array1OfReal knots(1, segments + 1);
        TColStd_Array1OfInteger mults(1, segments + 1);
        for (int i = 0; i <= segments; ++i) {
            knots.SetValue(i + 1, double(i));
            mults.SetValue(i + 1, (i == 0 || i == segments) ? 4 : 3);
        }
        return new Geom_BSplineCurve(array, knots, mults, 3);
    }
    if (periodic) {
        if (n < 3) return nullptr;
        TColStd_Array1OfReal knots(1, n + 1);
        TColStd_Array1OfInteger mults(1, n + 1);
        for (int i = 0; i <= n; ++i) {
            knots.SetValue(i + 1, double(i));
            mults.SetValue(i + 1, 1);
        }
        return new Geom_BSplineCurve(array, knots, mults, std::min(3, n - 1), Standard_True);
    }
    if (n < 2) return nullptr;
    const int degree = std::min(3, n - 1);
    const int count = n - degree + 1;
    TColStd_Array1OfReal knots(1, count);
    TColStd_Array1OfInteger mults(1, count);
    for (int i = 0; i < count; ++i) {
        knots.SetValue(i + 1, double(i));
        mults.SetValue(i + 1, (i == 0 || i == count - 1) ? degree + 1 : 1);
    }
    return new Geom_BSplineCurve(array, knots, mults, degree);
}

/// Baut eine Kontur aus der Segment-Kodierung (siehe PCKShape.h). Liefert einen leeren Draht bei Fehlern.
static TopoDS_Wire wireFromCode(const std::vector<double> &code) {
    // Ungültige Zahlen (NaN, unendlich) führen im Kernel zu Speicherfehlern, die kein catch abfängt
    for (const double value : code) {
        if (!std::isfinite(value)) return TopoDS_Wire();
    }
    BRepBuilderAPI_MakeWire wire;
    size_t i = 0;
    auto point = [&]() {
        const gp_Pnt p(code[i], code[i + 1], code[i + 2]);
        i += 3;
        return p;
    };
    auto has = [&](size_t count) { return i + count <= code.size(); };
    while (i < code.size()) {
        const int type = int(code[i++]);
        TopoDS_Edge edge;
        switch (type) {
        case 0: {
            if (!has(6)) return TopoDS_Wire();
            const gp_Pnt a = point(), b = point();
            if (a.Distance(b) < 1e-7) continue;
            edge = BRepBuilderAPI_MakeEdge(a, b).Edge();
            break;
        }
        case 1: {
            if (!has(9)) return TopoDS_Wire();
            const gp_Pnt a = point(), m = point(), b = point();
            GC_MakeArcOfCircle arc(a, m, b);
            if (!arc.IsDone()) return TopoDS_Wire();
            edge = BRepBuilderAPI_MakeEdge(arc.Value()).Edge();
            break;
        }
        case 2:
        case 5:
        case 6: {
            if (!has(1)) return TopoDS_Wire();
            const double count = code[i++];
            if (count < 2 || count > double(code.size())) return TopoDS_Wire();
            const size_t n = size_t(count);
            if (!has(3 * n)) return TopoDS_Wire();
            std::vector<gp_Pnt> poles;
            for (size_t k = 0; k < n; ++k) poles.push_back(point());
            const Handle(Geom_BSplineCurve) curve = makeBSpline(poles, type == 6, type == 2);
            if (curve.IsNull()) return TopoDS_Wire();
            if (type == 6 || (poles.size() > 2 && poles.front().Distance(poles.back()) < 1e-7)) {
                if (!addHalves(wire, curve, edge)) return TopoDS_Wire();
            } else {
                edge = BRepBuilderAPI_MakeEdge(curve).Edge();
            }
            break;
        }
        case 3: {
            if (!has(7)) return TopoDS_Wire();
            const gp_Pnt c = point(), n = point();
            const double r = code[i++];
            // gp_Dir aus dem Nullvektor wird im Release-Kernel nicht geprüft
            if (r <= 1e-9 || gp_Vec(n.XYZ()).Magnitude() < 1e-12) return TopoDS_Wire();
            edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(c, gp_Dir(n.X(), n.Y(), n.Z())), r)).Edge();
            break;
        }
        case 4: {
            if (!has(11)) return TopoDS_Wire();
            const gp_Pnt c = point(), n = point(), x = point();
            double rx = code[i++], ry = code[i++];
            if (rx <= 1e-9 || ry <= 1e-9 || gp_Vec(n.XYZ()).Magnitude() < 1e-12 ||
                gp_Vec(x.XYZ()).Magnitude() < 1e-12 || gp_Vec(n.XYZ()).IsParallel(gp_Vec(x.XYZ()), 1e-9)) {
                return TopoDS_Wire();
            }
            gp_Dir normal(n.X(), n.Y(), n.Z());
            gp_Dir major(x.X(), x.Y(), x.Z());
            if (ry > rx) {
                major = normal.Crossed(major);
                std::swap(rx, ry);
            }
            const Handle(Geom_Curve) curve = new Geom_Ellipse(gp_Elips(gp_Ax2(c, normal, major), rx, ry));
            if (!addHalves(wire, curve, edge)) return TopoDS_Wire();
            break;
        }
        default:
            return TopoDS_Wire();
        }
        wire.Add(edge);
        if (!wire.IsDone()) return TopoDS_Wire();
    }
    return wire.IsDone() ? wire.Wire() : TopoDS_Wire();
}

/// Ebene Fläche aus Außenkontur und Löchern (Kodierung wie prismWithProfileWires:). Null bei Fehler.
static TopoDS_Face faceFromWires(NSArray<NSArray<NSNumber *> *> *wires) {
    if (wires.count == 0) return TopoDS_Face();
    const TopoDS_Wire outer = wireFromCode(toVector(wires[0]));
    if (outer.IsNull()) return TopoDS_Face();
    BRepBuilderAPI_MakeFace face(outer, Standard_True);
    if (!face.IsDone()) return TopoDS_Face();
    for (NSUInteger k = 1; k < wires.count; ++k) {
        const TopoDS_Wire hole = wireFromCode(toVector(wires[k]));
        if (!hole.IsNull()) face.Add(hole);
    }
    // Umlaufrichtung der Löcher passend zur Außenkontur
    ShapeFix_Face fix(face.Face());
    fix.Perform();
    return fix.Face();
}

+ (nullable PCKShape *)prismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires direction:(simd_double3)direction {
    if (!validDir(direction)) return nil;
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        BRepPrimAPI_MakePrism prism(face, gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)draftPrismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
                                        direction:(simd_double3)direction angle:(double)degrees {
    if (!validDir(direction)) return nil;
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        const gp_Vec vector(direction.x, direction.y, direction.z);
        BRepPrimAPI_MakePrism prism(face, vector);
        if (!prism.IsDone()) return nil;
        const TopoDS_Shape solid = prism.Shape();
        if (std::abs(degrees) < 1e-9) return [[PCKShape alloc] initWithShape:solid];
        const gp_Dir pull(vector);
        BRepAdaptor_Surface base(face);
        if (base.GetType() != GeomAbs_Plane) return nil;
        // Neutralebene = Profilebene: unten bleibt das Profil, nach oben wird es schmaler bzw. breiter
        const gp_Pln neutral(base.Plane().Location(), pull);
        BRepOffsetAPI_DraftAngle draft(solid);
        for (TopExp_Explorer it(solid, TopAbs_FACE); it.More(); it.Next()) {
            const TopoDS_Face side = TopoDS::Face(it.Current());
            BRepAdaptor_Surface surface(side);
            // Boden und Deckel bleiben
            if (surface.GetType() == GeomAbs_Plane && surface.Plane().Axis().Direction().IsParallel(pull, 1e-6)) continue;
            draft.Add(side, pull, degrees * M_PI / 180.0, neutral);
            if (!draft.AddDone()) return nil;
        }
        draft.Build();
        if (!draft.IsDone()) return nil;
        // B7: Verjüngung kann einen ungültigen Körper liefern (überschnittene Seitenflächen)
        const TopoDS_Shape checked = checkedResult(draft.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)faceWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires {
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        return [[PCKShape alloc] initWithShape:face];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)torusWithCenter:(simd_double3)center axis:(simd_double3)axis
                           majorRadius:(double)majorRadius minorRadius:(double)minorRadius {
    if (majorRadius <= 0 || minorRadius <= 0 || minorRadius >= majorRadius || !validDir(axis)) return nil;
    try {
        BRepPrimAPI_MakeTorus torus(gp_Ax2(toPnt(center), toDir(axis)), majorRadius, minorRadius);
        return [[PCKShape alloc] initWithShape:torus.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)revolveProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires axisOrigin:(simd_double3)origin
                             axisDirection:(simd_double3)direction angle:(double)radians {
    if (!validDir(direction) || radians == 0) return nil;
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        const double angle = std::min(std::abs(radians), 2 * M_PI);
        gp_Dir axis = toDir(direction);
        if (radians < 0) axis.Reverse();
        // B6: Schneidet die Drehachse das Profil (Profilpunkte auf beiden Seiten der Achse), durchdringt sich der
        // Drehkörper selbst. Vorab prüfen statt einen ungültigen Körper zu liefern; Punkte auf der Achse zählen nicht.
        BRepAdaptor_Surface profilePlane(face);
        if (profilePlane.GetType() == GeomAbs_Plane) {
            const gp_Dir planeNormal = profilePlane.Plane().Axis().Direction();
            const gp_Vec axisVector(axis);
            const gp_Pnt axisPoint = toPnt(origin);
            Bnd_Box bounds;
            BRepBndLib::Add(face, bounds);
            const double size = bounds.IsVoid() ? 1.0 : std::sqrt(bounds.SquareExtent());
            const double tolerance = std::max(1e-6, size * 1e-7);
            bool left = false, right = false;
            for (TopExp_Explorer it(face, TopAbs_EDGE); it.More() && !(left && right); it.Next()) {
                const TopoDS_Edge edge = TopoDS::Edge(it.Current());
                if (BRep_Tool::Degenerated(edge)) continue;
                BRepAdaptor_Curve curve(edge);
                const double first = curve.FirstParameter(), last = curve.LastParameter();
                if (!std::isfinite(first) || !std::isfinite(last)) continue;
                for (int k = 0; k <= 16; ++k) {
                    const gp_Pnt p = curve.Value(first + (last - first) * k / 16.0);
                    const double side = axisVector.Crossed(gp_Vec(axisPoint, p)).Dot(gp_Vec(planeNormal));
                    if (side > tolerance) left = true;
                    else if (side < -tolerance) right = true;
                }
            }
            if (left && right) return nil;
        }
        BRepPrimAPI_MakeRevol revol(face, gp_Ax1(toPnt(origin), axis), angle, Standard_True);
        if (!revol.IsDone()) return nil;
        const TopoDS_Shape checked = checkedResult(revol.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)sweepProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires path:(NSArray<NSNumber *> *)path {
    try {
        const TopoDS_Face face = faceFromWires(wires);
        const TopoDS_Wire spine = wireFromCode(toVector(path));
        if (face.IsNull() || spine.IsNull()) return nil;
        BRepOffsetAPI_MakePipe pipe(spine, face);
        pipe.Build();
        if (!pipe.IsDone()) return nil;
        // B7: Sweep entlang eines zu engen Pfads durchdringt sich selbst
        const TopoDS_Shape checked = checkedResult(pipe.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections {
    if (sections.count < 2) return nil;
    try {
        BRepOffsetAPI_ThruSections loft(Standard_True, Standard_False);
        for (NSArray<NSNumber *> *code in sections) {
            const TopoDS_Wire wire = wireFromCode(toVector(code));
            if (wire.IsNull()) return nil;
            loft.AddWire(wire);
        }
        loft.CheckCompatibility(Standard_True);
        loft.Build();
        if (!loft.IsDone()) return nil;
        // B7: verdrehte Querschnitte ergeben sonst einen ungültigen Loft
        const TopoDS_Shape checked = checkedResult(loft.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

/// Kopie eines Drahts, um vector verschoben. Leer bei Fehler.
static TopoDS_Wire shiftedWire(const TopoDS_Wire &wire, simd_double3 vector) {
    gp_Trsf move;
    move.SetTranslation(gp_Vec(vector.x, vector.y, vector.z));
    BRepBuilderAPI_Transform transform(wire, move, Standard_True);
    if (!transform.IsDone()) return TopoDS_Wire();
    const TopoDS_Shape shape = transform.Shape();
    if (shape.IsNull() || shape.ShapeType() != TopAbs_WIRE) return TopoDS_Wire();
    return TopoDS::Wire(shape);
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections
                            startOffset:(simd_double3)startOffset endOffset:(simd_double3)endOffset {
    if (sections.count < 2) return nil;
    try {
        std::vector<TopoDS_Wire> wires;
        for (NSArray<NSNumber *> *code in sections) {
            const TopoDS_Wire wire = wireFromCode(toVector(code));
            if (wire.IsNull()) return nil;
            wires.push_back(wire);
        }
        // Tangential: verschobene Kopie dicht hinter dem ersten bzw. vor dem letzten Querschnitt. Die Fläche
        // (Approximation durch alle Drähte) verlässt den Querschnitt dann in Richtung der Verschiebung.
        std::vector<TopoDS_Wire> all;
        all.push_back(wires.front());
        if (simd_length(startOffset) > 1e-9) {
            const TopoDS_Wire helper = shiftedWire(wires.front(), startOffset);
            if (!helper.IsNull()) all.push_back(helper);
        }
        for (size_t k = 1; k + 1 < wires.size(); ++k) all.push_back(wires[k]);
        if (simd_length(endOffset) > 1e-9) {
            const TopoDS_Wire helper = shiftedWire(wires.back(), endOffset);
            if (!helper.IsNull()) all.push_back(helper);
        }
        all.push_back(wires.back());
        BRepOffsetAPI_ThruSections loft(Standard_True, Standard_False);
        for (const auto &wire : all) loft.AddWire(wire);
        loft.CheckCompatibility(Standard_True);
        loft.Build();
        if (!loft.IsDone()) return nil;
        const TopoDS_Shape checked = checkedResult(loft.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections
                                 guides:(NSArray<NSArray<NSNumber *> *> *)guides {
    if (sections.count < 2 || guides.count == 0) return nil;
    try {
        const TopoDS_Wire spine = wireFromCode(toVector(guides[0]));
        if (spine.IsNull()) return nil;
        TopoDS_Wire auxiliary;
        if (guides.count >= 2) auxiliary = wireFromCode(toVector(guides[1]));
        std::vector<TopoDS_Wire> profiles;
        for (NSArray<NSNumber *> *code in sections) {
            const TopoDS_Wire wire = wireFromCode(toVector(code));
            if (wire.IsNull()) return nil;
            profiles.push_back(wire);
        }
        // Querschnitte bleiben, wo sie sind (ohne Kontakt/Korrektur); BRepFill macht sie untereinander
        // verträglich und blendet sie entlang der Leitkurve über
        auto sweep = [&](bool useAuxiliary) -> TopoDS_Shape {
            try {
                BRepOffsetAPI_MakePipeShell pipe(spine);
                if (useAuxiliary) pipe.SetMode(auxiliary, Standard_True, BRepFill_NoContact);
                for (const auto &profile : profiles) pipe.Add(profile, Standard_False, Standard_False);
                pipe.Build();
                if (pipe.IsDone() && pipe.MakeSolid() && !pipe.Shape().IsNull()) return pipe.Shape();
            } catch (...) {
            }
            return TopoDS_Shape();
        };
        TopoDS_Shape result;
        if (!auxiliary.IsNull()) result = sweep(true);
        // Rückfall: nur die erste Führung (korrigiertes Frenet-Dreibein)
        if (result.IsNull()) result = sweep(false);
        if (result.IsNull()) return nil;
        const TopoDS_Shape checked = checkedResult(result);
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)compoundOfShapes:(NSArray<PCKShape *> *)shapes {
    if (shapes.count == 0) return nil;
    if (shapes.count == 1) return shapes[0];
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (PCKShape *shape in shapes) {
        builder.Add(compound, shape->_shape);
    }
    return [[PCKShape alloc] initWithShape:compound];
}

/// Fasst nach booleschen Operationen zerteilte Flächen und Kanten wieder zusammen.
static TopoDS_Shape unified(const TopoDS_Shape &shape) {
    try {
        ShapeUpgrade_UnifySameDomain unify(shape, Standard_True, Standard_True, Standard_False);
        unify.Build();
        const TopoDS_Shape result = unify.Shape();
        return result.IsNull() ? shape : result;
    } catch (...) {
        return shape;
    }
}

// MARK: Dünn extrudieren

/// Geschlossen: Anfangs- und Endpunkt fallen zusammen.
static bool isClosedWire(const TopoDS_Wire &wire) {
    if (wire.Closed()) return true;
    TopoDS_Vertex first, last;
    TopExp::Vertices(wire, first, last);
    if (first.IsNull() || last.IsNull()) return true;
    return first.IsSame(last) || BRep_Tool::Pnt(first).Distance(BRep_Tool::Pnt(last)) < 1e-6;
}

static double facesArea(const std::vector<TopoDS_Face> &faces) {
    double area = 0;
    for (const auto &face : faces) {
        GProp_GProps props;
        BRepGProp::SurfaceProperties(face, props);
        area += std::abs(props.Mass());
    }
    return area;
}

/// Ebene Fläche(n) einer geschlossenen Kontur, um distance versetzt (> 0 nach außen, < 0 nach innen; nach innen
/// kann die Kontur in mehrere Teile zerfallen). Bei 0 die Kontur selbst. Leer, wenn der Versatz verschwindet
/// (Wand dicker als das Profil) oder scheitert.
static std::vector<TopoDS_Face> offsetFaces(const TopoDS_Wire &wire, double distance) {
    std::vector<TopoDS_Face> result;
    BRepBuilderAPI_MakeFace base(wire, Standard_True);
    if (!base.IsDone()) return result;
    if (std::abs(distance) < 1e-9) {
        result.push_back(base.Face());
        return result;
    }
    const double baseArea = facesArea({base.Face()});
    // Welche Seite „außen“ ist, hängt an der Umlaufrichtung: an der Fläche prüfen und sonst umgekehrt versuchen
    for (double d : {distance, -distance}) {
        for (GeomAbs_JoinType join : {GeomAbs_Intersection, GeomAbs_Arc}) {
            std::vector<TopoDS_Face> faces;
            try {
                BRepOffsetAPI_MakeOffset offset(base.Face(), join, Standard_False);
                offset.Perform(d);
                if (!offset.IsDone() || offset.Shape().IsNull()) continue;
                for (TopExp_Explorer it(offset.Shape(), TopAbs_WIRE); it.More(); it.Next()) {
                    BRepBuilderAPI_MakeFace face(TopoDS::Wire(it.Current()), Standard_True);
                    if (face.IsDone()) faces.push_back(face.Face());
                }
            } catch (...) {
                continue;
            }
            if (faces.empty()) continue;
            if ((distance > 0) == (facesArea(faces) > baseArea)) return faces;
            break; // falsche Seite: anderes Vorzeichen
        }
    }
    return result;
}

/// Prismen der Flächen entlang vector; overshoot verlängert sie an beiden Enden (Werkzeug zum Abziehen).
static TopoDS_Shape prismsOf(const std::vector<TopoDS_Face> &faces, const gp_Vec &vector, double overshoot) {
    if (faces.empty() || vector.Magnitude() < 1e-12) return TopoDS_Shape();
    const gp_Vec unit = vector.Normalized();
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    TopoDS_Shape single;
    for (const auto &face : faces) {
        TopoDS_Shape base = face;
        if (overshoot > 0) {
            gp_Trsf shift;
            shift.SetTranslation(unit * -overshoot);
            base = face.Moved(TopLoc_Location(shift));
        }
        BRepPrimAPI_MakePrism prism(base, vector + unit * (2 * overshoot));
        if (!prism.IsDone()) return TopoDS_Shape();
        single = prism.Shape();
        builder.Add(compound, single);
    }
    return faces.size() == 1 ? single : TopoDS_Shape(compound);
}

/// Wand entlang einer geschlossenen Kontur: Bereich zwischen den Versätzen big (außen) und small (innen).
static TopoDS_Shape closedWall(const TopoDS_Wire &wire, double big, double small, const gp_Vec &vector) {
    const std::vector<TopoDS_Face> outer = offsetFaces(wire, big);
    if (outer.empty()) return TopoDS_Shape();
    const TopoDS_Shape solid = prismsOf(outer, vector, 0);
    if (solid.IsNull()) return solid;
    const std::vector<TopoDS_Face> inner = offsetFaces(wire, small);
    // Innen nichts mehr übrig (Wand dicker als das halbe Profil): voller Körper
    if (inner.empty()) return solid;
    const TopoDS_Shape tool = prismsOf(inner, vector, 0.5);
    if (tool.IsNull()) return TopoDS_Shape();
    BRepAlgoAPI_Cut cut(solid, tool);
    if (!cut.IsDone()) return TopoDS_Shape();
    return cut.Shape();
}

/// Offene Kontur um distance parallel versetzt (offenes Ergebnis). Die Seite ergibt sich aus Laufrichtung und
/// Ebenennormale; für die andere Seite wird der Draht umgedreht. 0 = die Kontur selbst.
static TopoDS_Wire openOffset(const TopoDS_Face &plane, const TopoDS_Wire &wire, double distance) {
    if (std::abs(distance) < 1e-9) return wire;
    const TopoDS_Wire spine = distance < 0 ? TopoDS::Wire(wire.Reversed()) : wire;
    for (GeomAbs_JoinType join : {GeomAbs_Intersection, GeomAbs_Arc}) {
        try {
            // Ebene vorgeben: ein einzelnes gerades Stück legt selbst keine Ebene fest
            BRepOffsetAPI_MakeOffset offset;
            offset.Init(plane, join, Standard_True);
            offset.AddWire(spine);
            offset.Perform(std::abs(distance));
            if (!offset.IsDone() || offset.Shape().IsNull()) continue;
            for (TopExp_Explorer it(offset.Shape(), TopAbs_WIRE); it.More(); it.Next()) {
                return TopoDS::Wire(it.Current());
            }
        } catch (...) {
        }
    }
    return TopoDS_Wire();
}

/// Ebene Fläche zwischen zwei offenen, etwa parallelen Drähten (Enden mit Geraden verbunden).
static TopoDS_Face bandBetween(const TopoDS_Wire &a, const TopoDS_Wire &b) {
    TopoDS_Vertex a0, a1, b0, b1;
    TopExp::Vertices(a, a0, a1);
    TopExp::Vertices(b, b0, b1);
    if (a0.IsNull() || a1.IsNull() || b0.IsNull() || b1.IsNull()) return TopoDS_Face();
    const gp_Pnt pa0 = BRep_Tool::Pnt(a0), pa1 = BRep_Tool::Pnt(a1);
    gp_Pnt pb0 = BRep_Tool::Pnt(b0), pb1 = BRep_Tool::Pnt(b1);
    if (pa0.Distance(pb0) + pa1.Distance(pb1) > pa0.Distance(pb1) + pa1.Distance(pb0)) std::swap(pb0, pb1);
    TopTools_ListOfShape edges;
    for (TopExp_Explorer it(a, TopAbs_EDGE); it.More(); it.Next()) edges.Append(it.Current());
    for (TopExp_Explorer it(b, TopAbs_EDGE); it.More(); it.Next()) edges.Append(it.Current());
    if (pa0.Distance(pb0) > 1e-7) edges.Append(BRepBuilderAPI_MakeEdge(pa0, pb0).Edge());
    if (pa1.Distance(pb1) > 1e-7) edges.Append(BRepBuilderAPI_MakeEdge(pa1, pb1).Edge());
    BRepBuilderAPI_MakeWire wire;
    wire.Add(edges);
    if (!wire.IsDone()) return TopoDS_Face();
    BRepBuilderAPI_MakeFace face(wire.Wire(), Standard_True);
    if (!face.IsDone()) return TopoDS_Face();
    ShapeFix_Face fix(face.Face());
    fix.Perform();
    return fix.Face();
}

+ (nullable PCKShape *)thinPrismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
                                     planeOrigin:(simd_double3)origin planeNormal:(simd_double3)normal
                                       thickness:(double)thickness side:(NSInteger)side
                                       direction:(simd_double3)direction {
    if (wires.count == 0 || thickness <= 0 || !validDir(direction) || !validDir(normal)) return nil;
    try {
        const gp_Vec vector(direction.x, direction.y, direction.z);
        const double t = thickness;
        std::vector<TopoDS_Shape> walls;
        TopoDS_Face plane;
        for (NSUInteger k = 0; k < wires.count; ++k) {
            const TopoDS_Wire wire = wireFromCode(toVector(wires[k]));
            if (wire.IsNull()) return nil;
            TopoDS_Shape wall;
            if (isClosedWire(wire)) {
                // Innen = ins Material des Bereichs: bei der Außenkontur nach innen, bei Löchern nach außen
                const bool hole = k > 0;
                double big = t / 2, small = -t / 2;
                if (side == 1) {
                    big = hole ? t : 0;
                    small = hole ? 0 : -t;
                } else if (side == 2) {
                    big = hole ? 0 : t;
                    small = hole ? -t : 0;
                }
                wall = closedWall(wire, big, small, vector);
            } else {
                if (plane.IsNull()) plane = BRepBuilderAPI_MakeFace(gp_Pln(toPnt(origin), toDir(normal))).Face();
                double a = -t / 2, b = t / 2;
                if (side == 1) {
                    a = 0;
                    b = t;
                } else if (side == 2) {
                    a = -t;
                    b = 0;
                }
                const TopoDS_Wire first = openOffset(plane, wire, a);
                const TopoDS_Wire second = openOffset(plane, wire, b);
                if (first.IsNull() || second.IsNull()) return nil;
                const TopoDS_Face band = bandBetween(first, second);
                if (band.IsNull()) return nil;
                BRepPrimAPI_MakePrism prism(band, vector);
                if (!prism.IsDone()) return nil;
                wall = prism.Shape();
            }
            if (wall.IsNull()) return nil;
            walls.push_back(wall);
        }
        TopoDS_Shape result = walls[0];
        for (size_t k = 1; k < walls.size(); ++k) {
            BRepAlgoAPI_Fuse op(result, walls[k]);
            if (!op.IsDone()) return nil;
            result = op.Shape();
        }
        return [[PCKShape alloc] initWithShape:walls.size() > 1 ? unified(result) : result];
    } catch (...) {
        return nil;
    }
}

// MARK: Schraubenlinie (Feder, Gewinde)

/// Schraubenlinie um die Z-Achse ab z = 0: Gerade auf der abgewickelten Zylinderfläche, 3D-Kurve angenähert.
static TopoDS_Wire helixWire(double radius, double pitch, double height, bool leftHanded) {
    const Handle(Geom_CylindricalSurface) surface = new Geom_CylindricalSurface(gp_Ax3(gp::XOY()), radius);
    const double turns = height / pitch;
    const gp_Dir2d direction(leftHanded ? -2 * M_PI : 2 * M_PI, pitch);
    const Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, 0), direction);
    const double length = turns * std::sqrt(4 * M_PI * M_PI + pitch * pitch);
    BRepBuilderAPI_MakeEdge edge(line, surface, 0, length);
    if (!edge.IsDone()) return TopoDS_Wire();
    const TopoDS_Edge result = edge.Edge();
    BRepLib::BuildCurves3d(result, 1e-6, GeomAbs_C1, 14, std::max(32, int(std::ceil(turns * 12))));
    BRepBuilderAPI_MakeWire wire(result);
    return wire.IsDone() ? wire.Wire() : TopoDS_Wire();
}

/// Profil entlang der Schraubenlinie ziehen und als Körper schließen. Nacheinander: feste Binormale (Achse),
/// Frenet, korrigiertes Frenet – je nach Profil klappt nicht jede Führung.
/// transformed: Übergänge zwischen den Kanten der Führung (Schraubenlinie je Umdrehung) als Transformation des
/// Profils statt mit Ecken (BRepBuilderAPI_Transformed).
static TopoDS_Shape helixPipe(const TopoDS_Wire &spine, const TopoDS_Wire &profile, bool transformed = false) {
    for (int mode = 0; mode < 3; ++mode) {
        try {
            BRepOffsetAPI_MakePipeShell pipe(spine);
            if (mode == 0) {
                pipe.SetMode(gp_Dir(0, 0, 1));
            } else {
                pipe.SetMode(mode == 1 ? Standard_True : Standard_False);
            }
            if (transformed) pipe.SetTransitionMode(BRepBuilderAPI_Transformed);
            pipe.Add(profile, Standard_False, Standard_False);
            pipe.Build();
            if (!pipe.IsDone()) continue;
            if (!pipe.MakeSolid()) continue;
            const TopoDS_Shape shape = pipe.Shape();
            if (!shape.IsNull()) return shape;
        } catch (...) {
        }
    }
    return TopoDS_Shape();
}

/// Körper aus dem Achssystem (Z-Achse im Ursprung) an base/axis versetzen.
static TopoDS_Shape placedOnAxis(const TopoDS_Shape &shape, simd_double3 base, simd_double3 axis) {
    gp_Trsf transform;
    transform.SetDisplacement(gp_Ax3(gp::XOY()), gp_Ax3(toPnt(base), toDir(axis)));
    BRepBuilderAPI_Transform op(shape, transform, Standard_True);
    return op.IsDone() ? op.Shape() : TopoDS_Shape();
}

+ (nullable PCKShape *)springWithBase:(simd_double3)base axis:(simd_double3)axis radius:(double)radius
                                pitch:(double)pitch height:(double)height leftHanded:(BOOL)leftHanded
                         wireDiameter:(double)wireDiameter {
    if (radius <= 0 || pitch <= 0 || height <= 0 || wireDiameter <= 0 || !validDir(axis)) return nil;
    if (wireDiameter >= 2 * radius || height / pitch > 400) return nil;
    try {
        const TopoDS_Wire spine = helixWire(radius, pitch, height, leftHanded);
        if (spine.IsNull()) return nil;
        // Drahtquerschnitt am Anfang der Schraubenlinie, senkrecht zu ihr
        const gp_Dir tangent(0, leftHanded ? -radius : radius, pitch / (2 * M_PI));
        const gp_Circ circle(gp_Ax2(gp_Pnt(radius, 0, 0), tangent), wireDiameter / 2);
        BRepBuilderAPI_MakeWire profile(BRepBuilderAPI_MakeEdge(circle).Edge());
        if (!profile.IsDone()) return nil;
        const TopoDS_Shape solid = helixPipe(spine, profile.Wire());
        if (solid.IsNull()) return nil;
        const TopoDS_Shape placed = placedOnAxis(solid, base, axis);
        return placed.IsNull() ? nil : [[PCKShape alloc] initWithShape:placed];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)helixSweepWithBase:(simd_double3)base axis:(simd_double3)axis radius:(double)radius
                                    pitch:(double)pitch height:(double)height leftHanded:(BOOL)leftHanded
                                profileRZ:(NSArray<NSNumber *> *)profileRZ {
    if (radius <= 0 || pitch <= 0 || height <= 0 || profileRZ.count < 6 || !validDir(axis)) return nil;
    if (height / pitch > 400) return nil;
    try {
        const TopoDS_Wire spine = helixWire(radius, pitch, height, leftHanded);
        if (spine.IsNull()) return nil;
        // Querschnitt in der Achsebene (XZ) am Anfang der Schraubenlinie
        BRepBuilderAPI_MakePolygon polygon;
        for (NSUInteger i = 0; i + 1 < profileRZ.count; i += 2) {
            polygon.Add(gp_Pnt(profileRZ[i].doubleValue, 0, profileRZ[i + 1].doubleValue));
        }
        polygon.Close();
        if (!polygon.IsDone()) return nil;
        const TopoDS_Shape solid = helixPipe(spine, polygon.Wire());
        if (solid.IsNull()) return nil;
        const TopoDS_Shape placed = placedOnAxis(solid, base, axis);
        return placed.IsNull() ? nil : [[PCKShape alloc] initWithShape:placed];
    } catch (...) {
        return nil;
    }
}

// MARK: Gewinde

/// Kleinste erlaubte Toleranz nach dem Zug bzw. beim zweiten Reparaturversuch: bewusst gröber als die
/// Standardtoleranz, sonst scheitern Boolesche Operationen an den angenäherten Schraubenflächen.
static const double kThreadTolerance = 1e-5;

/// Zweiter Reparaturversuch: jedes Solid mit ShapeFix_Solid (Schalen, Orientierung), danach die Toleranzen auf
/// mindestens kThreadTolerance (ShapeFix_ShapeTolerance).
static TopoDS_Shape repairedSolids(const TopoDS_Shape &shape) {
    try {
        BRep_Builder builder;
        TopoDS_Compound compound;
        builder.MakeCompound(compound);
        int count = 0;
        TopoDS_Shape single;
        for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) {
            ShapeFix_Solid fix(TopoDS::Solid(it.Current()));
            fix.Perform();
            const TopoDS_Shape fixed = fix.Solid();
            single = fixed.IsNull() ? it.Current() : fixed;
            builder.Add(compound, single);
            ++count;
        }
        if (count == 0) return TopoDS_Shape();
        TopoDS_Shape result = count == 1 ? single : TopoDS_Shape(compound);
        ShapeFix_ShapeTolerance tolerance;
        tolerance.LimitTolerance(result, kThreadTolerance);
        return result;
    } catch (...) {
        return TopoDS_Shape();
    }
}

/// Solids nach außen orientieren: liegt ein unendlich ferner Punkt INNEN, ist das Solid umgestülpt (kommt bei
/// Zügen entlang linksgängiger Schraubenlinien vor) und wird umgedreht.
static TopoDS_Shape outwardOriented(const TopoDS_Shape &shape) {
    try {
        BRep_Builder builder;
        TopoDS_Compound compound;
        builder.MakeCompound(compound);
        bool flipped = false;
        int count = 0;
        TopoDS_Shape single;
        for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) {
            TopoDS_Shape solid = it.Current();
            BRepClass3d_SolidClassifier classifier(solid);
            classifier.PerformInfinitePoint(1e-7);
            if (classifier.State() == TopAbs_IN) {
                solid.Reverse();
                flipped = true;
            }
            builder.Add(compound, solid);
            single = solid;
            ++count;
        }
        if (!flipped) return shape;
        return count == 1 ? single : TopoDS_Shape(compound);
    } catch (...) {
        return shape;
    }
}

/// Prüft einen Körper (BRepCheck_Analyzer) und repariert ihn bei Bedarf (ShapeFix_Shape, dann ShapeFix_Solid mit
/// gröberer Toleranz). Leer, wenn er ungültig bleibt, kein Solid enthält oder kein Volumen hat.
static TopoDS_Shape validSolid(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return TopoDS_Shape();
    try {
        TopoDS_Shape candidate = shape;
        if (!BRepCheck_Analyzer(candidate).IsValid()) {
            ShapeFix_Shape fix(candidate);
            fix.Perform();
            candidate = fix.Shape();
            if (candidate.IsNull()) return TopoDS_Shape();
            if (!BRepCheck_Analyzer(candidate).IsValid()) {
                // Zweiter Versuch: Solids einzeln reparieren, Toleranz gröber (nach Schraubenflächen oft nötig)
                candidate = repairedSolids(candidate);
                if (candidate.IsNull() || !BRepCheck_Analyzer(candidate).IsValid()) return TopoDS_Shape();
            }
        }
        TopExp_Explorer solids(candidate, TopAbs_SOLID);
        if (!solids.More()) return TopoDS_Shape();
        GProp_GProps props;
        BRepGProp::VolumeProperties(candidate, props);
        if (std::fabs(props.Mass()) < 1e-9) return TopoDS_Shape();
        return candidate;
    } catch (...) {
        return TopoDS_Shape();
    }
}

/// Wie validSolid, aber für Verbünde mehrerer Solids: validSolid prüft den Verbund als Ganzes und nur das
/// Gesamtvolumen; hier muss zusätzlich jedes einzelne Solid Volumen haben (kein entartetes Teilstück).
static TopoDS_Shape validShape(const TopoDS_Shape &shape) {
    const TopoDS_Shape candidate = validSolid(shape);
    if (candidate.IsNull()) return TopoDS_Shape();
    try {
        for (TopExp_Explorer it(candidate, TopAbs_SOLID); it.More(); it.Next()) {
            GProp_GProps props;
            BRepGProp::VolumeProperties(it.Current(), props);
            if (!std::isfinite(props.Mass()) || std::fabs(props.Mass()) < 1e-9) return TopoDS_Shape();
        }
        return candidate;
    } catch (...) {
        return TopoDS_Shape();
    }
}

/// Ergebnis einer Modellieroperation prüfen (B3–B7: Boolesche Operationen, Schale, Verjüngung, Sweep, Loft,
/// Formschräge). Enthält es Solids, muss es gültig sein (validShape, je Solid); sonst leer. Ohne Solid
/// (Flächen-/Schalenkörper, vollständig abgezogener Körper, leere Schnittmenge) bleibt es wie bisher unverändert –
/// Aufrufer prüfen dort selbst (z. B. Volumen der Schnittmenge).
static TopoDS_Shape checkedResult(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return TopoDS_Shape();
    try {
        if (!TopExp_Explorer(shape, TopAbs_SOLID).More()) return shape;
    } catch (...) {
        return TopoDS_Shape();
    }
    return validShape(shape);
}

/// Schraubenlinie für Gewinde um die Z-Achse: beginnt bei z = zStart im Winkel 0 (auf +X) und steigt um height.
/// radius gilt bei z = 0; taper ≠ 0 legt sie auf eine Kegelfläche (Radius ändert sich um taper je mm).
/// Zylindrisch wird sie je Umdrehung als eigene Kante gebaut (eine Gerade auf der abgewickelten Zylinderfläche,
/// je Kante eigene 3D-Kurve): eine einzige angenäherte Kurve über viele Umdrehungen wird in OpenCASCADE ungenau –
/// getestet: ab etwa 40 Umdrehungen fehlt Volumen bzw. die Boolesche Operation liefert Unsinn. Kegelig am Stück.
static TopoDS_Wire threadSpine(double radius, double lead, double zStart, double height, bool leftHanded,
                               double taper) {
    if (radius <= 0 || lead <= 0 || height <= 0) return TopoDS_Wire();
    Handle(Geom_Surface) surface;
    double scale = 1;
    const bool tapered = std::fabs(taper) > 1e-9;
    if (tapered) {
        // Kegel: Parameter v läuft entlang der Mantellinie, Höhe = v · cos(Winkel)
        const double angle = std::atan(taper);
        surface = new Geom_ConicalSurface(gp_Ax3(gp::XOY()), angle, radius);
        scale = 1 / std::cos(angle);
    } else {
        surface = new Geom_CylindricalSurface(gp_Ax3(gp::XOY()), radius);
    }
    const double v0 = zStart * scale;
    const double vTurn = lead * scale;
    const gp_Dir2d direction(leftHanded ? -2 * M_PI : 2 * M_PI, vTurn);
    const Handle(Geom2d_Line) line = new Geom2d_Line(gp_Pnt2d(0, v0), direction);
    const double turns = height / lead;
    const double perTurn = std::sqrt(4 * M_PI * M_PI + vTurn * vTurn);
    const double length = turns * perTurn;
    if (tapered) {
        BRepBuilderAPI_MakeEdge edge(line, surface, 0, length);
        if (!edge.IsDone()) return TopoDS_Wire();
        const TopoDS_Edge result = edge.Edge();
        BRepLib::BuildCurves3d(result, 1e-6, GeomAbs_C1, 14, std::max(32, int(std::ceil(turns * 16))));
        BRepBuilderAPI_MakeWire wire(result);
        return wire.IsDone() ? wire.Wire() : TopoDS_Wire();
    }
    // Grenzen der Kanten: je volle Umdrehung, ein sehr kurzer Rest kommt an die letzte Umdrehung
    std::vector<double> bounds;
    const int full = int(std::floor(turns + 1e-9));
    for (int k = 0; k <= full; ++k) bounds.push_back(double(k) * perTurn);
    const double rest = length - bounds.back();
    if (rest > 1e-6 * perTurn) {
        if (rest < 0.05 * perTurn && bounds.size() > 1) {
            bounds.back() = length;
        } else {
            bounds.push_back(length);
        }
    }
    if (bounds.size() < 2) return TopoDS_Wire();
    BRepBuilderAPI_MakeWire wire;
    for (size_t k = 0; k + 1 < bounds.size(); ++k) {
        BRepBuilderAPI_MakeEdge edge(line, surface, bounds[k], bounds[k + 1]);
        if (!edge.IsDone()) return TopoDS_Wire();
        const TopoDS_Edge piece = edge.Edge();
        BRepLib::BuildCurves3d(piece, 1e-6, GeomAbs_C1, 14, 32);
        wire.Add(piece);
        if (!wire.IsDone()) return TopoDS_Wire();
    }
    return wire.Wire();
}

+ (nullable PCKShape *)threadWithBase:(simd_double3)base axis:(simd_double3)axis length:(double)length
                                 lead:(double)lead starts:(NSInteger)starts taper:(double)taper
                           leftHanded:(BOOL)leftHanded profileRZ:(NSArray<NSNumber *> *)profileRZ
                           coreRadius:(double)coreRadius {
    if (length <= 0 || lead <= 0 || profileRZ.count < 6 || !validDir(axis)) return nil;
    if (starts < 1 || starts > 8) return nil;
    // Eine Umdrehung Vorlauf und Nachlauf, damit die Enden nach dem Abschneiden voll ausgebildet sind
    const double zStart = -lead;
    const double zEnd = length + lead;
    const double height = zEnd - zStart;
    if (height / lead > 400) return nil;
    try {
        std::vector<double> rz = toVector(profileRZ);
        const size_t count = rz.size() / 2;
        if (count < 3) return nil;
        double rMin = INFINITY, rMax = 0, rSum = 0, zMin = INFINITY, zMax = -INFINITY;
        for (size_t i = 0; i < count; ++i) {
            rMin = std::min(rMin, rz[2 * i]);
            rMax = std::max(rMax, rz[2 * i]);
            rSum += rz[2 * i];
            zMin = std::min(zMin, rz[2 * i + 1]);
            zMax = std::max(zMax, rz[2 * i + 1]);
        }
        // Kleinster Radius entlang des ganzen Zugs muss positiv bleiben
        const double lowest = rMin + std::min(taper * zStart, taper * zEnd);
        if (lowest <= 0) return nil;
        // Benachbarte Windungen (auch anderer Gänge) dürfen sich nie flächig berühren: das Profil ist axial
        // höchstens eine Teilung (Steigung / Gangzahl) minus 2 µm breit, sonst wird es um seine Mitte gestaucht
        const double period = lead / double(starts);
        const double room = period - 0.002;
        if (room <= 0) return nil;
        if (zMax - zMin > room) {
            const double center = 0.5 * (zMin + zMax);
            const double factor = room / (zMax - zMin);
            for (size_t i = 0; i < count; ++i) rz[2 * i + 1] = center + (rz[2 * i + 1] - center) * factor;
        }
        const double spineRadius = rSum / double(count);
        const TopoDS_Wire spine = threadSpine(spineRadius, lead, zStart, height, leftHanded, taper);
        if (spine.IsNull()) return nil;
        // Profil in der Achsebene (XZ) am Anfang der Schraubenlinie
        BRepBuilderAPI_MakePolygon polygon;
        const double shift = taper * zStart;
        for (size_t i = 0; i < count; ++i) {
            polygon.Add(gp_Pnt(rz[2 * i] + shift, 0, rz[2 * i + 1] + zStart));
        }
        polygon.Close();
        if (!polygon.IsDone()) return nil;
        TopoDS_Shape gang = helixPipe(spine, polygon.Wire(), true);
        if (gang.IsNull()) return nil;
        // Nach dem Zug absichern: nach außen orientieren, bei Fehlern reparieren (zweiter Versuch)
        gang = outwardOriented(gang);
        if (!BRepCheck_Analyzer(gang).IsValid()) {
            const TopoDS_Shape repaired = repairedSolids(gang);
            if (!repaired.IsNull()) gang = repaired;
        }

        // Ebene Enden: Schnitt mit einem Zylinder von z = 0 bis length, dessen Mantel weit außerhalb liegt
        const gp_Ax2 frame(gp::Origin(), gp::DZ());
        const double outer = rMax + std::fabs(taper) * height + 1;
        const TopoDS_Shape trim = BRepPrimAPI_MakeCylinder(frame, outer, length).Shape();

        // Ergebnis: Verbund [Kernzylinder (falls coreRadius > 0), Verbund aller Gänge]. Nicht vereinigt – das
        // Werkzeug wird in einem Schritt abgezogen (cutting(_:fuzzy:)): die Gänge berühren sich nicht und bleiben
        // ein Teil (werden nicht gegeneinander geschnitten), der Kern überlappt sie und ist ein eigenes Werkzeug.
        BRep_Builder builder;
        TopoDS_Compound ridges;
        builder.MakeCompound(ridges);
        for (NSInteger k = 0; k < starts; ++k) {
            TopoDS_Shape copy = gang;
            if (k > 0) {
                gp_Trsf rotation;
                rotation.SetRotation(gp::OZ(), 2 * M_PI * double(k) / double(starts));
                BRepBuilderAPI_Transform turn(gang, rotation, Standard_True);
                if (!turn.IsDone()) return nil;
                copy = turn.Shape();
            }
            BRepAlgoAPI_Common common(copy, trim);
            if (!common.IsDone() || common.Shape().IsNull()) return nil;
            const TopoDS_Shape piece = common.Shape();
            TopExp_Explorer solids(piece, TopAbs_SOLID);
            if (!solids.More()) return nil;
            builder.Add(ridges, piece);
        }
        TopoDS_Compound parts;
        builder.MakeCompound(parts);
        if (coreRadius > 0) {
            // Kern immer zylindrisch: Boolesche Operationen zwischen einem flachen Kegel und dem kegeligen Gang
            // scheitern in OpenCASCADE (getestet), mit einem Zylinder gelingen sie
            builder.Add(parts, BRepPrimAPI_MakeCylinder(frame, coreRadius, length).Shape());
        }
        builder.Add(parts, ridges);
        const TopoDS_Shape placed = placedOnAxis(parts, base, axis);
        return placed.IsNull() ? nil : [[PCKShape alloc] initWithShape:placed];
    } catch (...) {
        return nil;
    }
}

- (BOOL)containsPoint:(simd_double3)point {
    try {
        const gp_Pnt p = toPnt(point);
        for (TopExp_Explorer it(_shape, TopAbs_SOLID); it.More(); it.Next()) {
            BRepClass3d_SolidClassifier classifier(it.Current(), p, 1e-6);
            if (classifier.State() == TopAbs_IN) return YES;
        }
    } catch (...) {
    }
    return NO;
}

- (nullable PCKShape *)validatedSolid {
    const TopoDS_Shape valid = validSolid(_shape);
    if (valid.IsNull()) return nil;
    return valid.IsSame(_shape) ? self : [[PCKShape alloc] initWithShape:valid];
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Cut op(_shape, tool->_shape);
        if (!op.IsDone()) return nil;
        // B3: nicht nur IsDone – ein Ergebnis mit Solids muss gültig sein (checkedResult)
        const TopoDS_Shape checked = checkedResult(unified(op.Shape()));
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

/// Abziehen mit einer Liste von Werkzeugen (ein Schritt) und optionalem Fuzzy-Wert. Leer bei Fehler oder ohne Solid.
static TopoDS_Shape cutWithTools(const TopoDS_Shape &body, const TopTools_ListOfShape &tools, double fuzzy) {
    try {
        BRepAlgoAPI_Cut op;
        TopTools_ListOfShape arguments;
        arguments.Append(body);
        op.SetArguments(arguments);
        op.SetTools(tools);
        if (fuzzy > 0) op.SetFuzzyValue(fuzzy);
        op.Build();
        if (!op.IsDone() || op.HasErrors()) return TopoDS_Shape();
        const TopoDS_Shape result = op.Shape();
        if (result.IsNull()) return TopoDS_Shape();
        TopExp_Explorer solids(result, TopAbs_SOLID);
        return solids.More() ? result : TopoDS_Shape();
    } catch (...) {
        return TopoDS_Shape();
    }
}

- (nullable PCKShape *)cuttingTool:(PCKShape *)tool fuzzy:(double)fuzzy {
    try {
        // Oberste Ebene eines Verbunds = einzelne Werkzeuge (dürfen sich überlappen); tiefer verschachtelte
        // Verbünde bleiben ein Werkzeug (z. B. alle Gänge eines Gewindes, die sich nicht berühren)
        TopTools_ListOfShape tools;
        if (tool->_shape.ShapeType() == TopAbs_COMPOUND) {
            for (TopoDS_Iterator it(tool->_shape); it.More(); it.Next()) tools.Append(it.Value());
        } else {
            tools.Append(tool->_shape);
        }
        if (tools.IsEmpty()) return nil;
        const TopoDS_Shape first = cutWithTools(_shape, tools, fuzzy);
        // B4: auch bei nur einem Werkzeug das Ergebnis prüfen (validShape, je Solid); ein ungültiges first
        // wird nie mehr zurückgegeben. Mehrere Werkzeuge: ein nicht schon gültiges first geht wie bisher erst in den
        // Rückfall Werkzeug für Werkzeug (keine Reparatur vorab, die dort fehlende Gänge verdecken könnte).
        const bool firstUsable = !first.IsNull() && (tools.Extent() == 1 || BRepCheck_Analyzer(first).IsValid());
        const TopoDS_Shape firstChecked = firstUsable ? validShape(unified(first)) : TopoDS_Shape();
        if (!firstChecked.IsNull()) return [[PCKShape alloc] initWithShape:firstChecked];
        // Rückfall: Werkzeug für Werkzeug, jeweils erst mit, dann ohne Fuzzy-Wert. Verbünde (die Gänge) zuerst:
        // nach dem Kernloch abgezogen bleiben kegelige Gänge sonst stillschweigend stehen (getestet, NPT)
        TopTools_ListOfShape ordered;
        for (TopTools_ListOfShape::Iterator it(tools); it.More(); it.Next()) {
            if (it.Value().ShapeType() == TopAbs_COMPOUND) ordered.Append(it.Value());
        }
        for (TopTools_ListOfShape::Iterator it(tools); it.More(); it.Next()) {
            if (it.Value().ShapeType() != TopAbs_COMPOUND) ordered.Append(it.Value());
        }
        TopoDS_Shape current = _shape;
        bool done = tools.Extent() > 1;
        for (TopTools_ListOfShape::Iterator it(ordered); done && it.More(); it.Next()) {
            TopTools_ListOfShape single;
            single.Append(it.Value());
            TopoDS_Shape next = cutWithTools(current, single, fuzzy);
            if (next.IsNull() && fuzzy > 0) next = cutWithTools(current, single, 0);
            if (next.IsNull()) {
                done = false;
            } else {
                current = next;
            }
        }
        if (done) {
            const TopoDS_Shape stepwise = validShape(unified(current));
            if (!stepwise.IsNull()) return [[PCKShape alloc] initWithShape:stepwise];
        }
        // Früher kam hier das ungeprüfte first zurück (B4); jetzt nur noch, wenn es sich reparieren lässt
        if (!first.IsNull() && !firstUsable) {
            const TopoDS_Shape repaired = validShape(unified(first));
            if (!repaired.IsNull()) return [[PCKShape alloc] initWithShape:repaired];
        }
        // Letzter Versuch ohne Fuzzy-Wert in einem Schritt
        if (fuzzy > 0) {
            const TopoDS_Shape plain = cutWithTools(_shape, tools, 0);
            const TopoDS_Shape plainChecked = plain.IsNull() ? TopoDS_Shape() : validShape(unified(plain));
            if (!plainChecked.IsNull()) return [[PCKShape alloc] initWithShape:plainChecked];
        }
        return nil;
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    try {
        BRepAlgoAPI_Fuse op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        // B3: Ergebnis mit Solids prüfen
        const TopoDS_Shape checked = checkedResult(unified(op.Shape()));
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)intersecting:(PCKShape *)other {
    try {
        BRepAlgoAPI_Common op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        // B3: Ergebnis mit Solids prüfen; eine leere Schnittmenge bleibt leer (Aufrufer prüfen das Volumen)
        const TopoDS_Shape checked = checkedResult(unified(op.Shape()));
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

/// Führt eine innere Randschleife einer ebenen Fläche in eine Vertiefung (Bohrung, Senkung, Tasche: direkt unter
/// der Fläche ist innerhalb der Schleife Luft) – oder umrandet sie eine Insel (Zapfen), unter der das Material
/// weitergeht? Probe: an einer Kante der Schleife knapp links und rechts in der Ebene und knapp unter der Fläche;
/// liegt einer der beiden Punkte außerhalb des Körpers, ist es eine Vertiefung. normal zeigt aus dem Körper.
static bool loopOpensIntoPocket(const TopoDS_Shape &body, const TopoDS_Wire &wire, const gp_Dir &normal) {
    try {
        for (TopExp_Explorer it(wire, TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(it.Current());
            if (BRep_Tool::Degenerated(edge)) continue;
            BRepAdaptor_Curve curve(edge);
            const double u = 0.5 * (curve.FirstParameter() + curve.LastParameter());
            gp_Pnt point;
            gp_Vec tangent;
            curve.D1(u, point, tangent);
            gp_Vec side = gp_Vec(normal).Crossed(tangent);
            if (side.Magnitude() < 1e-9) continue;
            side.Normalize();
            // Flach in die Tiefe, damit auch sehr flache Kegelsenkungen (bis ~87° Wandneigung) erkannt werden
            const double delta = 0.05, depth = 0.002;
            for (double sign : {1.0, -1.0}) {
                const gp_Vec offset = side * (sign * delta) - gp_Vec(normal) * depth;
                BRepClass3d_SolidClassifier classifier(body, point.Translated(offset), 1e-7);
                if (classifier.State() == TopAbs_OUT) return true;
            }
            return false;
        }
    } catch (...) {
    }
    return false;
}

/// Werkzeuge zum Ziehen einer ebenen Fläche (Nummer index) um distance entlang ihrer Normale: das Prisma der Fläche,
/// beim Abtragen (distance < 0) zusätzlich je Bohrung/Tasche in der Fläche ein Prisma der gefüllten Öffnung.
/// Kai: Oberseite mit Senkbohrung nach innen gezogen – das Prisma der Fläche hat dort ein Loch, also blieb im
/// abgetragenen Bereich die Wand um die Bohrung als offene Röhre stehen. Inseln (Zapfen) bleiben ausgespart und
/// werden dadurch länger, wie beim Push/Pull anderer CAD-Programme. false, wenn die Fläche nicht eben ist.
static bool appendFaceExtrusionTools(const TopoDS_Shape &body, const TopoDS_Face &source, const gp_Vec &normal,
                                     double distance, TopTools_ListOfShape &tools) {
    // Das Werkzeug beginnt knapp auf der anderen Seite der Fläche: so überlappen Körper und Prisma sicher (keine
    // deckungsgleichen Flächen, an denen Vereinigen bzw. Abziehen bei schrägen Fasenflächen scheitert).
    const double overlap = 0.01;
    const double start = distance > 0 ? -overlap : overlap;
    gp_Trsf shift;
    shift.SetTranslation(normal * start);
    const TopLoc_Location moved(shift);
    const gp_Vec sweep = normal * (distance - start);
    BRepPrimAPI_MakePrism prism(source.Moved(moved), sweep);
    if (!prism.IsDone()) return false;
    tools.Append(prism.Shape());
    if (distance >= 0) return true;
    const TopoDS_Wire outer = BRepTools::OuterWire(source);
    const gp_Dir direction(normal);
    for (TopExp_Explorer it(source, TopAbs_WIRE); it.More(); it.Next()) {
        const TopoDS_Wire wire = TopoDS::Wire(it.Current());
        if (wire.IsSame(outer) || !loopOpensIntoPocket(body, wire, direction)) continue;
        BRepBuilderAPI_MakeFace fill(wire, Standard_True);
        if (!fill.IsDone()) return false;
        BRepPrimAPI_MakePrism plug(fill.Face().Moved(moved), sweep);
        if (!plug.IsDone()) return false;
        TopoDS_Shape shape = plug.Shape();
        // Umlaufsinn der Schleife (Loch = im Uhrzeigersinn) kann den Prismenkörper umstülpen
        GProp_GProps props;
        BRepGProp::VolumeProperties(shape, props);
        if (props.Mass() < 0) shape.Reverse();
        tools.Append(shape);
    }
    return true;
}

/// Körper mit allen Werkzeugen vereinigen (distance > 0) bzw. sie abziehen; nur ein gültiger, geschlossener Körper
/// wird übernommen (sonst nil statt eines Körpers mit offenen Flächen).
static TopoDS_Shape applyFaceExtrusionTools(const TopoDS_Shape &body, const TopTools_ListOfShape &tools,
                                            double distance) {
    TopTools_ListOfShape arguments;
    arguments.Append(body);
    TopoDS_Shape result;
    if (distance > 0) {
        BRepAlgoAPI_Fuse op;
        op.SetArguments(arguments);
        op.SetTools(tools);
        // Eingangskörper nicht verändern (Toleranzen): er wird im Verlauf und in der Anzeige weiter benutzt
        op.SetNonDestructive(Standard_True);
        op.Build();
        if (!op.IsDone() || op.HasErrors()) return TopoDS_Shape();
        result = op.Shape();
    } else {
        BRepAlgoAPI_Cut op;
        op.SetArguments(arguments);
        op.SetTools(tools);
        op.SetNonDestructive(Standard_True);
        op.Build();
        if (!op.IsDone() || op.HasErrors()) return TopoDS_Shape();
        result = op.Shape();
    }
    if (result.IsNull()) return TopoDS_Shape();
    const TopoDS_Shape merged = validSolid(unified(result));
    if (!merged.IsNull()) return merged;
    return validSolid(result);
}

- (nullable PCKShape *)extrudingFace:(NSInteger)index distance:(double)distance {
    if (distance == 0) return nil;
    return [self extrudingFaces:@[@(index)] distance:distance];
}

- (nullable PCKShape *)extrudingFaces:(NSArray<NSNumber *> *)indices distance:(double)distance {
    if (distance == 0 || indices.count == 0) return nil;
    try {
        // Alle Prismen entstehen aus dem Ausgangskörper, daher bleiben die Flächennummern gültig
        TopTools_ListOfShape tools;
        for (NSNumber *number in indices) {
            // Nummer außerhalb des Körpers (veraltete Auswahl): nicht ungeprüft in die Flächenliste greifen
            if (number.integerValue < 1 || number.integerValue > _faces.Extent()) return nil;
            NSArray<NSNumber *> *plane = [self planeOfFace:number.integerValue];
            if (plane == nil || plane.count < 6) return nil;
            const gp_Vec normal(plane[3].doubleValue, plane[4].doubleValue, plane[5].doubleValue);
            const TopoDS_Face face = TopoDS::Face(_faces(number.intValue));
            if (!appendFaceExtrusionTools(_shape, face, normal, distance, tools)) return nil;
        }
        if (tools.IsEmpty()) return nil;
        const TopoDS_Shape result = applyFaceExtrusionTools(_shape, tools, distance);
        if (result.IsNull()) return nil;
        // Ergebnis ohne Flächen nicht weitergeben (nichts zu vernetzen, Folgefehler)
        TopExp_Explorer anyFace(result, TopAbs_FACE);
        if (!anyFace.More()) return nil;
        return [[PCKShape alloc] initWithShape:result];
    } catch (const Standard_Failure &) {
        return nil;
    } catch (const std::exception &) {
        return nil;
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)offsettingFaces:(NSArray<NSNumber *> *)indices distance:(double)distance {
    if (distance == 0 || indices.count == 0) return nil;
    try {
        // Alle übrigen Flächen mit Versatz 0, nur die gewählten mit distance (Verlängern der Nachbarn per Schnitt)
        BRepOffset_MakeOffset offset;
        offset.Initialize(_shape, 0.0, 1e-6, BRepOffset_Skin, Standard_False, Standard_False, GeomAbs_Intersection,
                          Standard_False);
        for (NSNumber *number in indices) {
            if (number.integerValue < 1 || number.integerValue > _faces.Extent()) return nil;
            offset.SetOffsetOnFace(TopoDS::Face(_faces(number.intValue)), distance);
        }
        offset.MakeOffsetShape();
        if (offset.IsDone() && !offset.Shape().IsNull()) {
            // B10: alle Solids übernehmen (früher nur das erste – bei mehreren Teilkörpern ging der Rest verloren)
            BRep_Builder builder;
            TopoDS_Compound compound;
            builder.MakeCompound(compound);
            int count = 0;
            TopoDS_Shape single;
            for (TopExp_Explorer it(offset.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
                single = it.Current();
                builder.Add(compound, single);
                ++count;
            }
            const TopoDS_Shape solids = count == 1 ? single : count > 1 ? TopoDS_Shape(compound) : TopoDS_Shape();
            if (!solids.IsNull() && BRepCheck_Analyzer(solids).IsValid()) {
                const TopoDS_Shape checked = validShape(solids);
                if (!checked.IsNull()) return [[PCKShape alloc] initWithShape:unified(checked)];
            }
        }
    } catch (...) {
    }
    // Ebene Flächen: wie Extrudieren (ergibt bei senkrechten Nachbarflächen dasselbe)
    return [self extrudingFaces:indices distance:distance];
}

- (nullable PCKShape *)replacingFaces:(NSArray<NSNumber *> *)indices planeOrigin:(simd_double3)origin
                          planeNormal:(simd_double3)normalIn {
    if (indices.count == 0 || !validDir(normalIn)) return nil;
    try {
        Bnd_Box box;
        BRepBndLib::Add(_shape, box);
        const double diagonal = box.IsVoid() ? 1000 : std::sqrt(box.SquareExtent());
        const gp_Pnt p0 = toPnt(origin);
        const gp_Dir m = toDir(normalIn);
        TopoDS_Shape result = _shape;
        bool changed = false;
        for (NSNumber *number in indices) {
            NSArray<NSNumber *> *plane = [self planeOfFace:number.integerValue];
            if (plane == nil) return nil;
            const gp_Vec n(plane[3].doubleValue, plane[4].doubleValue, plane[5].doubleValue);
            const TopoDS_Face face = TopoDS::Face(_faces(number.intValue));
            GProp_GProps props;
            BRepGProp::SurfaceProperties(face, props);
            const gp_Pnt c = props.CentreOfMass();
            const double denominator = n.Dot(gp_Vec(m));
            if (std::abs(denominator) < 1e-6) return nil;
            const double t = gp_Vec(c, p0).Dot(gp_Vec(m)) / denominator;
            if (std::abs(t) < 1e-7) continue;
            // Bereich zwischen Fläche und Zielebene: Prisma der Fläche (nach vorn zum Verlängern, nach hinten zum
            // Kürzen) geschnitten mit dem Halbraum, in dem die Fläche liegt
            const double length = std::abs(t) + 2 * diagonal + 1;
            const gp_Vec along = t > 0 ? n : -n;
            gp_Trsf shift;
            shift.SetTranslation(along * -0.01);
            BRepPrimAPI_MakePrism prism(face.Moved(TopLoc_Location(shift)), along * length);
            if (!prism.IsDone()) return nil;
            BRepBuilderAPI_MakeFace target(gp_Pln(p0, m));
            if (!target.IsDone()) return nil;
            BRepPrimAPI_MakeHalfSpace half(target.Face(), c);
            BRepAlgoAPI_Common region(prism.Shape(), half.Solid());
            if (!region.IsDone()) return nil;
            if (t > 0) {
                BRepAlgoAPI_Fuse op(result, region.Shape());
                if (!op.IsDone()) return nil;
                result = op.Shape();
            } else {
                BRepAlgoAPI_Cut op(result, region.Shape());
                if (!op.IsDone()) return nil;
                result = op.Shape();
            }
            changed = true;
        }
        if (!changed) return nil;
        return [[PCKShape alloc] initWithShape:unified(result)];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)cylinderOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    try {
        BRepAdaptor_Surface surface(TopoDS::Face(_faces(int(index))));
        if (surface.GetType() != GeomAbs_Cylinder) return nil;
        const gp_Cylinder cylinder = surface.Cylinder();
        const gp_Pnt o = cylinder.Axis().Location();
        const gp_Dir d = cylinder.Axis().Direction();
        return @[@(o.X()), @(o.Y()), @(o.Z()), @(d.X()), @(d.Y()), @(d.Z()), @(cylinder.Radius())];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)ruledSolidBetween:(NSArray<NSNumber *> *)first and:(NSArray<NSNumber *> *)second {
    if (first.count != second.count || first.count < 9 || first.count % 3 != 0) return nil;
    try {
        BRepOffsetAPI_ThruSections loft(Standard_True, Standard_True);
        for (NSArray<NSNumber *> *points in @[first, second]) {
            BRepBuilderAPI_MakePolygon polygon;
            for (NSUInteger i = 0; i + 2 < points.count; i += 3) {
                polygon.Add(gp_Pnt(points[i].doubleValue, points[i + 1].doubleValue, points[i + 2].doubleValue));
            }
            polygon.Close();
            if (!polygon.IsDone()) return nil;
            loft.AddWire(polygon.Wire());
        }
        loft.CheckCompatibility(Standard_False);
        loft.Build();
        if (!loft.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:loft.Shape()];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)imprinting:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments, tools;
        arguments.Append(_shape);
        tools.Append(tool->_shape);
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.Build();
        if (!splitter.IsDone()) return nil;
        // Nicht zusammenfassen (unified würde die neuen Teilflächen wieder verschmelzen)
        std::vector<TopoDS_Shape> solids;
        for (TopExp_Explorer it(splitter.Shape(), TopAbs_SOLID); it.More(); it.Next()) solids.push_back(it.Current());
        if (solids.size() != 1) return nil;
        return [[PCKShape alloc] initWithShape:solids[0]];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness {
    if (face < 1 || face > _faces.Extent() || thickness <= 0) return nil;
    try {
        TopTools_ListOfShape removed;
        removed.Append(_faces(int(face)));
        BRepOffsetAPI_MakeThickSolid maker;
        maker.MakeThickSolidByJoin(_shape, removed, -thickness, 1e-3);
        maker.Build();
        if (!maker.IsDone()) return nil;
        // B5: Schale prüfen (zu große Wandstärke ergibt sonst einen ungültigen Körper)
        const TopoDS_Shape checked = validShape(maker.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)shellingRemovingFaces:(NSArray<NSNumber *> *)indices thickness:(double)thickness {
    if (thickness <= 0) return nil;
    try {
        if (indices.count == 0) {
            // Keine offene Fläche: Hohlkörper (Innenhaut um die Wandstärke versetzt, Kammer geschlossen).
            // B5: je Solid eine eigene Innenhaut (früher nur die erste Schale des ganzen Körpers – bei mehreren
            // Solids passten äußere und innere Schale nicht zusammen), danach Prüfung je Solid.
            BRep_Builder builder;
            TopoDS_Compound compound;
            builder.MakeCompound(compound);
            int count = 0;
            TopoDS_Shape single;
            for (TopExp_Explorer solids(_shape, TopAbs_SOLID); solids.More(); solids.Next()) {
                const TopoDS_Shape solid = solids.Current();
                BRepOffset_MakeOffset offset;
                offset.Initialize(solid, -thickness, 1e-6, BRepOffset_Skin, Standard_False, Standard_False,
                                  GeomAbs_Intersection, Standard_False);
                offset.MakeOffsetShape();
                if (!offset.IsDone() || offset.Shape().IsNull()) return nil;
                TopoDS_Shape inner;
                for (TopExp_Explorer it(offset.Shape(), TopAbs_SHELL); it.More(); it.Next()) {
                    inner = it.Current();
                    break;
                }
                TopoDS_Shape outer;
                for (TopExp_Explorer it(solid, TopAbs_SHELL); it.More(); it.Next()) {
                    outer = it.Current();
                    break;
                }
                if (inner.IsNull() || outer.IsNull()) return nil;
                TopoDS_Solid hollow;
                builder.MakeSolid(hollow);
                builder.Add(hollow, outer);
                builder.Add(hollow, inner.Reversed());
                if (!BRepCheck_Analyzer(hollow).IsValid()) return nil;
                builder.Add(compound, hollow);
                single = hollow;
                ++count;
            }
            if (count == 0) return nil;
            const TopoDS_Shape checked = validShape(count == 1 ? single : TopoDS_Shape(compound));
            return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
        }
        TopTools_ListOfShape removed;
        for (NSNumber *number in indices) {
            if (number.integerValue < 1 || number.integerValue > _faces.Extent()) return nil;
            removed.Append(_faces(number.intValue));
        }
        BRepOffsetAPI_MakeThickSolid maker;
        maker.MakeThickSolidByJoin(_shape, removed, -thickness, 1e-3);
        maker.Build();
        if (!maker.IsDone()) return nil;
        // B5: Schale prüfen
        const TopoDS_Shape checked = validShape(maker.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

/// Versetzt die geschlossene Hülle eines Solids um distance (BRepOffset_MakeOffset, Haut); leer bei Fehler oder
/// wenn das Volumen nicht in die erwartete Richtung wächst bzw. schrumpft.
static TopoDS_Shape offsetClosedSolid(const TopoDS_Shape &solid, double distance, GeomAbs_JoinType join,
                                     double tolerance) {
    try {
        BRepOffset_MakeOffset offset;
        offset.Initialize(solid, distance, tolerance, BRepOffset_Skin, Standard_False, Standard_False, join,
                          Standard_False);
        offset.MakeOffsetShape();
        if (!offset.IsDone() || offset.Shape().IsNull()) return TopoDS_Shape();
        TopoDS_Shape result;
        for (TopExp_Explorer it(offset.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
            result = it.Current();
            break;
        }
        if (result.IsNull()) {
            // Manche Versätze liefern nur die geschlossene Hülle: daraus ein Solid bauen
            TopExp_Explorer shells(offset.Shape(), TopAbs_SHELL);
            if (!shells.More()) return TopoDS_Shape();
            BRepBuilderAPI_MakeSolid maker(TopoDS::Shell(shells.Current()));
            if (!maker.IsDone()) return TopoDS_Shape();
            result = maker.Solid();
        }
        result = validSolid(outwardOriented(result));
        if (result.IsNull()) return TopoDS_Shape();
        GProp_GProps before;
        BRepGProp::VolumeProperties(solid, before);
        GProp_GProps after;
        BRepGProp::VolumeProperties(result, after);
        const double grown = std::fabs(after.Mass()) - std::fabs(before.Mass());
        if (distance > 0 ? grown <= 0 : grown >= 0) return TopoDS_Shape();
        return result;
    } catch (...) {
        return TopoDS_Shape();
    }
}

- (nullable PCKShape *)offsetSolidBy:(double)distance {
    if (distance == 0) return self;
    try {
        BRep_Builder builder;
        TopoDS_Compound compound;
        builder.MakeCompound(compound);
        int count = 0;
        TopoDS_Shape single;
        for (TopExp_Explorer it(_shape, TopAbs_SOLID); it.More(); it.Next()) {
            // Scharfe Kanten zuerst (Quader bleiben Quader), sonst gerundete Kanten, dann gröbere Toleranz
            TopoDS_Shape moved = offsetClosedSolid(it.Current(), distance, GeomAbs_Intersection, 1e-6);
            if (moved.IsNull()) moved = offsetClosedSolid(it.Current(), distance, GeomAbs_Arc, 1e-6);
            if (moved.IsNull()) moved = offsetClosedSolid(it.Current(), distance, GeomAbs_Arc, 1e-4);
            if (moved.IsNull()) return nil;
            builder.Add(compound, moved);
            single = moved;
            ++count;
        }
        if (count == 0) return nil;
        return [[PCKShape alloc] initWithShape:(count == 1 ? single : TopoDS_Shape(compound))];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)transformedBy:(const gp_Trsf &)transform {
    try {
        BRepBuilderAPI_Transform op(_shape, transform, Standard_True);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:op.Shape()];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)translatedBy:(simd_double3)offset {
    gp_Trsf transform;
    transform.SetTranslation(gp_Vec(offset.x, offset.y, offset.z));
    return [self transformedBy:transform];
}

- (nullable PCKShape *)rotatedAroundOrigin:(simd_double3)origin axis:(simd_double3)axis angle:(double)radians {
    if (!validDir(axis)) return nil;
    gp_Trsf transform;
    transform.SetRotation(gp_Ax1(toPnt(origin), toDir(axis)), radians);
    return [self transformedBy:transform];
}

- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    if (!validDir(normal)) return nil;
    gp_Trsf transform;
    transform.SetMirror(gp_Ax2(toPnt(origin), toDir(normal)));
    return [self transformedBy:transform];
}

- (nullable PCKShape *)scaledAboutPoint:(simd_double3)center factors:(simd_double3)factors {
    if (factors.x <= 0 || factors.y <= 0 || factors.z <= 0) return nil;
    if (factors.x == factors.y && factors.y == factors.z) {
        gp_Trsf transform;
        transform.SetScale(toPnt(center), factors.x);
        return [self transformedBy:transform];
    }
    try {
        // Ungleichmäßig: je Achse strecken, center bleibt fest
        gp_GTrsf stretch;
        stretch.SetValue(1, 1, factors.x);
        stretch.SetValue(2, 2, factors.y);
        stretch.SetValue(3, 3, factors.z);
        stretch.SetTranslationPart(gp_XYZ(center.x * (1 - factors.x), center.y * (1 - factors.y),
                                          center.z * (1 - factors.z)));
        BRepBuilderAPI_GTransform op(_shape, stretch, Standard_True);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:op.Shape()];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<PCKShape *> *)splitByTool:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Splitter splitter;
        TopTools_ListOfShape arguments, tools;
        arguments.Append(_shape);
        tools.Append(tool->_shape);
        splitter.SetArguments(arguments);
        splitter.SetTools(tools);
        splitter.Build();
        if (!splitter.IsDone()) return nil;
        NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
        for (TopExp_Explorer it(splitter.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
            GProp_GProps props;
            BRepGProp::VolumeProperties(it.Current(), props);
            if (std::abs(props.Mass()) > 1e-6) [parts addObject:[[PCKShape alloc] initWithShape:unified(it.Current())]];
        }
        return parts.count >= 2 ? parts : nil;
    } catch (...) {
        return nil;
    }
}

- (NSArray<PCKShape *> *)separatedSolids {
    try {
        std::vector<TopoDS_Shape> solids;
        for (TopExp_Explorer it(_shape, TopAbs_SOLID); it.More(); it.Next()) solids.push_back(it.Current());
        if (solids.size() <= 1) return @[self];
        // Schneller Weg (Vorschau beim Ziehen): berühren sich die Hüllquader nicht, sind die Solids schon getrennt
        std::vector<Bnd_Box> boxes(solids.size());
        for (size_t k = 0; k < solids.size(); k++) {
            BRepBndLib::Add(solids[k], boxes[k]);
            boxes[k].Enlarge(1e-4);
        }
        bool touching = false;
        for (size_t a = 0; a < solids.size() && !touching; a++) {
            for (size_t b = a + 1; b < solids.size(); b++) {
                if (!boxes[a].IsOut(boxes[b])) { touching = true; break; }
            }
        }
        if (!touching) {
            NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
            for (const TopoDS_Shape &solid : solids) [parts addObject:[[PCKShape alloc] initWithShape:solid]];
            return parts;
        }
        // Alle Solids miteinander vereinigen: Berührende verschmelzen, getrennte bleiben eigene Solids
        TopTools_ListOfShape arguments, tools;
        arguments.Append(solids[0]);
        for (size_t k = 1; k < solids.size(); k++) tools.Append(solids[k]);
        BRepAlgoAPI_Fuse fuse;
        fuse.SetArguments(arguments);
        fuse.SetTools(tools);
        fuse.Build();
        if (!fuse.IsDone()) return @[self];
        const TopoDS_Shape fused = unified(fuse.Shape());
        NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
        for (TopExp_Explorer it(fused, TopAbs_SOLID); it.More(); it.Next()) {
            [parts addObject:[[PCKShape alloc] initWithShape:it.Current()]];
        }
        return parts.count > 0 ? parts : @[self];
    } catch (...) {
        return @[self];
    }
}

- (NSArray<PCKShape *> *)separatedParts {
    try {
        if (_shape.IsNull() || _shape.ShapeType() != TopAbs_COMPOUND) return [self separatedSolids];
        std::vector<TopoDS_Shape> children;
        for (TopoDS_Iterator it(_shape); it.More(); it.Next()) children.push_back(it.Value());
        if (children.size() <= 1) return [self separatedSolids];
        // Je Teil (z. B. je Skizzenbereich ein Prisma) eigene Körper: nur innerhalb eines Teils wird verschmolzen
        NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
        for (const TopoDS_Shape &child : children) {
            TopExp_Explorer solids(child, TopAbs_SOLID);
            if (!solids.More()) continue;
            PCKShape *piece = [[PCKShape alloc] initWithShape:child];
            [parts addObjectsFromArray:[piece separatedSolids]];
        }
        return parts.count > 0 ? parts : [self separatedSolids];
    } catch (...) {
        return [self separatedSolids];
    }
}

- (NSArray<PCKShape *> *)solidParts {
    try {
        std::vector<TopoDS_Shape> solids;
        for (TopExp_Explorer it(_shape, TopAbs_SOLID); it.More(); it.Next()) solids.push_back(it.Current());
        if (solids.size() <= 1) return @[self];
        NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
        for (const TopoDS_Shape &solid : solids) [parts addObject:[[PCKShape alloc] initWithShape:solid]];
        return parts;
    } catch (...) {
        return @[self];
    }
}

- (nullable NSArray<PCKShape *> *)splitAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    if (!validDir(normal)) return nil;
    try {
        const gp_Pln plane(toPnt(origin), toDir(normal));
        const TopoDS_Face face = BRepBuilderAPI_MakeFace(plane, -1e5, 1e5, -1e5, 1e5).Face();
        const simd_double3 n = simd_normalize(normal);
        NSMutableArray<PCKShape *> *parts = [NSMutableArray array];
        for (double side : {1.0, -1.0}) {
            BRepPrimAPI_MakeHalfSpace half(face, toPnt(origin + n * side));
            BRepAlgoAPI_Common common(_shape, half.Solid());
            if (!common.IsDone()) return nil;
            GProp_GProps props;
            BRepGProp::VolumeProperties(common.Shape(), props);
            if (std::abs(props.Mass()) > 1e-6) {
                [parts addObject:[[PCKShape alloc] initWithShape:unified(common.Shape())]];
            }
        }
        return parts.count == 2 ? parts : nil;
    } catch (...) {
        return nil;
    }
}

- (NSInteger)faceCount {
    return _faces.Extent();
}

- (double)volume {
    try {
        GProp_GProps props;
        BRepGProp::VolumeProperties(_shape, props);
        return std::abs(props.Mass());
    } catch (...) {
        return 0;
    }
}

- (nullable NSArray<NSNumber *> *)centerOfMass {
    try {
        GProp_GProps props;
        BRepGProp::VolumeProperties(_shape, props);
        if (std::abs(props.Mass()) < 1e-9) return nil;
        const gp_Pnt c = props.CentreOfMass();
        return @[@(c.X()), @(c.Y()), @(c.Z())];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)boundingBox {
    try {
        Bnd_Box box;
        BRepBndLib::AddOptimal(_shape, box, Standard_False, Standard_False);
        if (box.IsVoid()) return nil;
        double x0 = 0, y0 = 0, z0 = 0, x1 = 0, y1 = 0, z1 = 0;
        box.Get(x0, y0, z0, x1, y1, z1);
        return @[@(x0), @(y0), @(z0), @(x1), @(y1), @(z1)];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)minimumDistanceTo:(PCKShape *)other {
    try {
        BRepExtrema_DistShapeShape distance(_shape, other->_shape);
        if (!distance.IsDone() || distance.NbSolution() < 1) return nil;
        const gp_Pnt a = distance.PointOnShape1(1);
        const gp_Pnt b = distance.PointOnShape2(1);
        return @[@(distance.Value()), @(a.X()), @(a.Y()), @(a.Z()), @(b.X()), @(b.Y()), @(b.Z())];
    } catch (...) {
        return nil;
    }
}

- (double)lengthOfEdge:(NSInteger)index {
    if (index < 1 || index > _edges.Extent()) return 0;
    try {
        GProp_GProps props;
        BRepGProp::LinearProperties(_edges(int(index)), props);
        return props.Mass();
    } catch (...) {
        return 0;
    }
}

- (double)areaOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return 0;
    try {
        GProp_GProps props;
        BRepGProp::SurfaceProperties(_faces(int(index)), props);
        return props.Mass();
    } catch (...) {
        return 0;
    }
}

// MARK: Messen

- (nullable NSArray<NSNumber *> *)geometryOfEdge:(NSInteger)index {
    if (index < 1 || index > _edges.Extent()) return nil;
    try {
        const TopoDS_Shape &shape = _edges(int(index));
        if (shape.IsNull() || shape.ShapeType() != TopAbs_EDGE) return nil;
        const TopoDS_Edge edge = TopoDS::Edge(shape);
        if (BRep_Tool::Degenerated(edge) || !BRep_Tool::IsGeometric(edge)) return nil;
        BRepAdaptor_Curve curve(edge);
        const double first = curve.FirstParameter(), last = curve.LastParameter();
        if (!std::isfinite(first) || !std::isfinite(last)) return nil;
        const gp_Pnt a = curve.Value(first), b = curve.Value(last);
        GProp_GProps props;
        BRepGProp::LinearProperties(edge, props);
        const double length = props.Mass();
        double kind = 3, radius = 0, radius2 = 0, sweep = 0;
        gp_Pnt center((a.X() + b.X()) / 2, (a.Y() + b.Y()) / 2, (a.Z() + b.Z()) / 2);
        gp_Dir axis(0, 0, 1);
        switch (curve.GetType()) {
        case GeomAbs_Line:
            kind = 0;
            break;
        case GeomAbs_Circle: {
            const gp_Circ circle = curve.Circle();
            kind = 1;
            radius = circle.Radius();
            center = circle.Location();
            axis = circle.Axis().Direction();
            sweep = std::abs(last - first);
            break;
        }
        case GeomAbs_Ellipse: {
            const gp_Elips ellipse = curve.Ellipse();
            kind = 2;
            radius = ellipse.MajorRadius();
            radius2 = ellipse.MinorRadius();
            center = ellipse.Location();
            axis = ellipse.Axis().Direction();
            sweep = std::abs(last - first);
            break;
        }
        default:
            break;
        }
        const double closed = a.Distance(b) < 1e-7 ? 1 : 0;
        return @[@(kind), @(length), @(a.X()), @(a.Y()), @(a.Z()), @(b.X()), @(b.Y()), @(b.Z()),
                 @(center.X()), @(center.Y()), @(center.Z()), @(axis.X()), @(axis.Y()), @(axis.Z()),
                 @(radius), @(radius2), @(sweep), @(closed)];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)surfaceOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    try {
        const TopoDS_Shape &shape = _faces(int(index));
        if (shape.IsNull() || shape.ShapeType() != TopAbs_FACE) return nil;
        const TopoDS_Face face = TopoDS::Face(shape);
        TopLoc_Location location;
        if (BRep_Tool::Surface(face, location).IsNull()) return nil;
        BRepAdaptor_Surface surface(face);
        switch (surface.GetType()) {
        case GeomAbs_Plane:
            return @[@0, @0, @0];
        case GeomAbs_Cylinder:
            return @[@1, @(surface.Cylinder().Radius()), @0];
        case GeomAbs_Cone: {
            const gp_Cone cone = surface.Cone();
            return @[@2, @(cone.SemiAngle()), @(cone.RefRadius())];
        }
        case GeomAbs_Sphere:
            return @[@3, @(surface.Sphere().Radius()), @0];
        case GeomAbs_Torus: {
            const gp_Torus torus = surface.Torus();
            return @[@4, @(torus.MajorRadius()), @(torus.MinorRadius())];
        }
        default:
            return @[@5, @0, @0];
        }
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)outlineOfFace:(NSInteger)index deflection:(double)deflection {
    if (index < 1 || index > _faces.Extent()) return nil;
    try {
        const TopoDS_Shape &shape = _faces(int(index));
        if (shape.IsNull() || shape.ShapeType() != TopAbs_FACE) return nil;
        const double tolerance = std::max(deflection, 1e-4);
        NSMutableArray<NSNumber *> *result = [NSMutableArray array];
        for (TopExp_Explorer it(shape, TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(it.Current());
            if (BRep_Tool::Degenerated(edge) || !BRep_Tool::IsGeometric(edge)) continue;
            try {
                BRepAdaptor_Curve curve(edge);
                // Kleiner Winkelschritt: Kreise liefern ihre Ausdehnung auf wenige Tausendstel genau
                GCPnts_TangentialDeflection points(curve, 0.01, tolerance);
                for (int k = 1; k <= points.NbPoints(); ++k) {
                    const gp_Pnt p = points.Value(k);
                    [result addObject:@(p.X())];
                    [result addObject:@(p.Y())];
                    [result addObject:@(p.Z())];
                }
            } catch (...) {
                continue;
            }
            if (result.count > 300000) break;
        }
        return result;
    } catch (...) {
        return nil;
    }
}

/// Punkt bei Anteil t (0…1) des Parameterbereichs einer Kante.
static gp_Pnt edgePoint(const TopoDS_Edge &edge, double t) {
    BRepAdaptor_Curve curve(edge);
    return curve.Value(curve.FirstParameter() + t * (curve.LastParameter() - curve.FirstParameter()));
}

/// Liegt p (bis auf tolerance) auf der Kante? Erst grob über den Hüllquader, dann genau.
static bool pointOnEdge(const gp_Pnt &p, const TopoDS_Edge &edge, double tolerance) {
    Bnd_Box box;
    BRepBndLib::Add(edge, box);
    box.Enlarge(tolerance);
    if (box.IsOut(p)) return false;
    BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(p).Vertex(), edge);
    return distance.IsDone() && distance.Value() < tolerance;
}

/// Die Kanten von shape, die aus den gegebenen (alten) Kanten hervorgegangen sind: zusammengefasst
/// (alte Mitte liegt auf der neuen Kante), gekürzt oder geteilt (neue Kante liegt ganz auf der alten).
static std::vector<TopoDS_Edge> matchEdges(const std::vector<TopoDS_Edge> &old, const TopoDS_Shape &shape,
                                           double tolerance = 1e-4) {
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(shape, TopAbs_EDGE, edges);
    std::vector<gp_Pnt> oldMids;
    for (const auto &edge : old) oldMids.push_back(edgePoint(edge, 0.5));
    std::vector<TopoDS_Edge> result;
    for (int i = 1; i <= edges.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(edges(i));
        if (BRep_Tool::Degenerated(edge)) continue;
        const gp_Pnt mid = edgePoint(edge, 0.5), quarter = edgePoint(edge, 0.25), last = edgePoint(edge, 0.75);
        for (size_t k = 0; k < old.size(); ++k) {
            const bool merged = pointOnEdge(oldMids[k], edge, tolerance);
            const bool piece = !merged && pointOnEdge(mid, old[k], tolerance) && pointOnEdge(quarter, old[k], tolerance)
                && pointOnEdge(last, old[k], tolerance);
            if (merged || piece) {
                result.push_back(edge);
                break;
            }
        }
    }
    return result;
}

/// Endprüfung (Schwacher Bugfix 1/2): Liegt eine der gewählten (ursprünglichen) Kanten unverändert bzw. als
/// Teilstück noch im Ergebnis, wurde sie nicht bearbeitet – das Ergebnis ist eine stille Teilrundung bzw.
/// Teilfase. Die Toleranz bleibt deutlich unter dem Wert, damit die neuen Randkanten einer kleinen Rundung
/// (Abstand ≈ Wert von der alten Kante) nicht als „übrig“ zählen.
static bool selectedEdgesRemain(const std::vector<TopoDS_Edge> &selected, const TopoDS_Shape &result, double value) {
    if (result.IsNull()) return true;
    const double tolerance = std::min(1e-4, std::max(1e-7, value * 0.25));
    try {
        for (const auto &edge : selected) {
            if (!matchEdges({edge}, result, tolerance).empty()) return true;
        }
        return false;
    } catch (...) {
        return true;
    }
}

/// Jede gewählte Kante muss im zusammengefassten Körper (unified) einen Treffer haben; sonst leer
/// (Schwacher Bugfix 1: über unified entfernte Kanten fielen still aus der Auswahl).
static std::vector<TopoDS_Edge> matchEveryEdge(const std::vector<TopoDS_Edge> &selected, const TopoDS_Shape &merged) {
    std::vector<TopoDS_Edge> result;
    for (const auto &edge : selected) {
        const std::vector<TopoDS_Edge> hits = matchEdges({edge}, merged);
        if (hits.empty()) return {};
        for (const auto &hit : hits) {
            bool known = false;
            for (const auto &other : result) {
                if (other.IsSame(hit)) { known = true; break; }
            }
            if (!known) result.push_back(hit);
        }
    }
    return result;
}

/// Ein Durchgang Abrunden bzw. Fasen; leere Form bei Fehler.
static TopoDS_Shape blendOnce(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges, double value,
                              bool chamfer) {
    if (shape.IsNull() || edges.empty() || !std::isfinite(value) || value <= 0) return TopoDS_Shape();
    try {
        if (chamfer) {
            BRepFilletAPI_MakeChamfer maker(shape);
            for (const auto &edge : edges) maker.Add(value, edge);
            for (const auto &edge : edges) {
                if (maker.Contour(edge) == 0) return TopoDS_Shape();
            }
            maker.Build();
            if (!maker.IsDone()) return TopoDS_Shape();
            // Fasen kennen kein NbFaultyContours: eine gültige Form, in der eine gewählte Kante noch
            // unverändert liegt, ist eine stille Teilfase (Schwacher Bugfix 2)
            const TopoDS_Shape checked = validSolid(maker.Shape());
            if (checked.IsNull() || selectedEdgesRemain(edges, checked, value)) return TopoDS_Shape();
            return checked;
        } else {
            BRepFilletAPI_MakeFillet maker(shape);
            for (const auto &edge : edges) maker.Add(value, edge);
            for (const auto &edge : edges) {
                if (maker.Contour(edge) == 0) return TopoDS_Shape();
            }
            maker.Build();
            if (maker.IsDone() && maker.NbFaultyContours() == 0) return validSolid(maker.Shape());
        }
    } catch (...) {
    }
    return TopoDS_Shape();
}

/// Abrunden/Fasen, das nicht an zerteilten Flächen hängen bleibt. Nach Skizzen mit Schnittpunkten oder
/// booleschen Operationen besteht eine Seite oft aus mehreren gleichen Flächen bzw. kurzen Kantenstücken –
/// dann ging nur ein winziger Radius. Darum: 1. direkt, 2. nach Zusammenfassen gleicher Flächen und Kanten,
/// 3. Kante für Kante nacheinander (benachbarte Rundungen blockieren sich nicht mehr gegenseitig).
static TopoDS_Shape blendEdges(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges, double value,
                               bool chamfer) {
    if (edges.empty() || !std::isfinite(value) || value <= 0) return TopoDS_Shape();
    // Alle drei Pfade enden mit derselben Endprüfung gegen die URSPRÜNGLICH gewählten Kanten (edges), nicht gegen
    // die im zusammengefassten Körper wiedergefundenen: keine gewählte Kante darf unverändert übrig bleiben.
    TopoDS_Shape result = blendOnce(shape, edges, value, chamfer);
    if (!result.IsNull() && !selectedEdgesRemain(edges, result, value)) return result;
    try {
        const TopoDS_Shape merged = unified(shape);
        // Jede gewählte Kante braucht einen Treffer im zusammengefassten Körper
        const std::vector<TopoDS_Edge> mergedEdges = matchEveryEdge(edges, merged);
        if (mergedEdges.empty()) return TopoDS_Shape();
        result = blendOnce(merged, mergedEdges, value, chamfer);
        if (!result.IsNull() && !selectedEdgesRemain(edges, result, value)) return result;
        if (edges.size() < 2) return TopoDS_Shape();
        TopoDS_Shape current = merged;
        for (const auto &edge : edges) {
            const std::vector<TopoDS_Edge> step = matchEdges({edge}, current);
            // Leer: schon von einer vorigen Rundung erfasst (tangentiale Kette); die Endprüfung unten
            // stellt sicher, dass sie wirklich bearbeitet wurde
            if (step.empty()) continue;
            current = blendOnce(current, step, value, chamfer);
            if (current.IsNull()) return TopoDS_Shape();
        }
        // Der sequenzielle Rückfall ist nur vollständig, wenn keine ursprünglich gewählte
        // Kante unbearbeitet übrig bleibt. Eine bloß gekürzte Nachbarkante zählt nicht.
        if (selectedEdgesRemain(edges, current, value)) return TopoDS_Shape();
        return current;
    } catch (...) {
        return TopoDS_Shape();
    }
}

/// Eine einzelne volle Quaderkante darf auch über die Breite einer Nachbarfläche hinaus verrundet werden.
/// OCCTs Standardfillet endet an dieser Fläche. Die Fortsetzung schneidet denselben Viertelkreis aus dem
/// Quader, solange noch ein geschlossener Restkörper übrig bleibt. Nur für sechs ebene Flächen und eine
/// durchgehende rechtwinklige Außenkante; bei anderen Formen bleibt der normale Fillet-Kernel zuständig.
static TopoDS_Shape extendedBoxFillet(const TopoDS_Shape &shape, const TopoDS_Edge &edge, double radius) {
    // N7: NaN besteht `radius <= 0 || radius > 1e6` (beide Vergleiche falsch) – ausdrücklich prüfen
    if (!std::isfinite(radius) || radius <= 0 || radius > 1e6) return TopoDS_Shape();
    try {
        int solids = 0, faces = 0;
        for (TopExp_Explorer it(shape, TopAbs_SOLID); it.More(); it.Next()) ++solids;
        for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
            if (BRepAdaptor_Surface(TopoDS::Face(it.Current()), Standard_False).GetType() != GeomAbs_Plane)
                return TopoDS_Shape();
            ++faces;
        }
        if (solids != 1 || faces != 6) return TopoDS_Shape();
        BRepAdaptor_Curve curve(edge);
        if (curve.GetType() != GeomAbs_Line) return TopoDS_Shape();
        TopTools_IndexedDataMapOfShapeListOfShape adjacent;
        TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, adjacent);
        const int index = adjacent.FindIndex(edge);
        if (index < 1 || adjacent(index).Extent() != 2) return TopoDS_Shape();
        gp_Vec inward[2];
        int side = 0;
        for (TopTools_ListOfShape::Iterator it(adjacent(index)); it.More(); it.Next()) {
            const TopoDS_Face face = TopoDS::Face(it.Value());
            gp_Dir normal = BRepAdaptor_Surface(face, Standard_False).Plane().Axis().Direction();
            if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
            inward[side++] = gp_Vec(normal.Reversed());
        }
        if (std::abs(inward[0].Dot(inward[1])) > 1e-5) return TopoDS_Shape();
        TopoDS_Vertex first, last;
        TopExp::Vertices(edge, first, last);
        if (first.IsNull() || last.IsNull()) return TopoDS_Shape();
        const gp_Pnt start = BRep_Tool::Pnt(first), end = BRep_Tool::Pnt(last);
        gp_Vec axis(start, end);
        const double length = axis.Magnitude();
        if (length < 1e-6) return TopoDS_Shape();
        axis.Normalize();
        // Die Kante muss den Körper in ihrer Achsrichtung vollständig durchlaufen.
        for (TopExp_Explorer it(shape, TopAbs_VERTEX); it.More(); it.Next()) {
            const double along = gp_Vec(start, BRep_Tool::Pnt(TopoDS::Vertex(it.Current()))).Dot(axis);
            if (along < -1e-4 || along > length + 1e-4) return TopoDS_Shape();
        }
        const gp_Pnt inside = start.Translated((inward[0] + inward[1]) * 0.01 + axis * (length * 0.5));
        BRepClass3d_SolidClassifier probe(shape, inside, 1e-7);
        if (probe.State() != TopAbs_IN) return TopoDS_Shape();

        const double overhang = std::max(0.1, length * 0.01);
        const gp_Pnt origin = start.Translated(axis * -overhang);
        const gp_Vec a = inward[0] * radius, b = inward[1] * radius;
        BRepBuilderAPI_MakePolygon perimeter;
        perimeter.Add(origin);
        perimeter.Add(origin.Translated(a));
        perimeter.Add(origin.Translated(a + b));
        perimeter.Add(origin.Translated(b));
        perimeter.Close();
        if (!perimeter.IsDone()) return TopoDS_Shape();
        BRepBuilderAPI_MakeFace section(perimeter.Wire());
        if (!section.IsDone()) return TopoDS_Shape();
        const gp_Vec sweep = axis * (length + 2 * overhang);
        BRepPrimAPI_MakePrism cornerPrism(section.Face(), sweep);
        const gp_Pnt center = origin.Translated(a + b);
        BRepPrimAPI_MakeCylinder roundVolume(gp_Ax2(center, gp_Dir(axis)), radius, sweep.Magnitude());
        BRepAlgoAPI_Cut outsideCircle(cornerPrism.Shape(), roundVolume.Shape());
        outsideCircle.Build();
        if (!outsideCircle.IsDone() || outsideCircle.Shape().IsNull()) return TopoDS_Shape();
        BRepAlgoAPI_Cut trimmed(shape, outsideCircle.Shape());
        trimmed.Build();
        if (!trimmed.IsDone() || trimmed.Shape().IsNull()) return TopoDS_Shape();
        const TopoDS_Shape result = trimmed.Shape();
        BRepCheck_Analyzer check(result);
        if (!check.IsValid()) return TopoDS_Shape();
        GProp_GProps before, after;
        BRepGProp::VolumeProperties(shape, before);
        BRepGProp::VolumeProperties(result, after);
        if (after.Mass() < 1e-8 || after.Mass() >= before.Mass() - 1e-8) return TopoDS_Shape();
        return result;
    } catch (...) {
        return TopoDS_Shape();
    }
}

/// Echte Kanten einer Fläche, ohne Nahtkanten (z. B. bei Zylindern) und entartete Kanten.
static TopTools_IndexedMapOfShape realEdgesOfFace(const TopTools_IndexedMapOfShape &faces, NSInteger index) {
    TopTools_IndexedMapOfShape result;
    if (index < 1 || index > faces.Extent()) return result;
    const TopoDS_Face face = TopoDS::Face(faces(int(index)));
    for (TopExp_Explorer explorer(face, TopAbs_EDGE); explorer.More(); explorer.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(explorer.Current());
        if (BRep_Tool::Degenerated(edge) || BRep_Tool::IsClosed(edge, face)) continue;
        result.Add(edge);
    }
    return result;
}

- (NSArray<NSNumber *> *)edgeNumbersOfFace:(NSInteger)face {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    const TopTools_IndexedMapOfShape edges = realEdgesOfFace(_faces, face);
    for (int i = 1; i <= edges.Extent(); ++i) {
        [numbers addObject:@(_edges.FindIndex(edges(i)))];
    }
    return numbers;
}

- (NSArray<NSNumber *> *)connectedEdgeNumbersOfFace:(NSInteger)face startingAtEdge:(NSInteger)edge {
    if (face < 1 || face > _faces.Extent() || edge < 1 || edge > _edges.Extent()) return @[];
    try {
        const TopTools_IndexedMapOfShape boundary = realEdgesOfFace(_faces, face);
        if (!boundary.Contains(_edges(int(edge)))) return @[];
        TopTools_IndexedDataMapOfShapeListOfShape incident;
        TopExp::MapShapesAndAncestors(_faces(int(face)), TopAbs_VERTEX, TopAbs_EDGE, incident);
        std::vector<int> pending {int(edge)};
        std::vector<bool> seen(size_t(_edges.Extent()) + 1, false);
        seen[size_t(edge)] = true;
        NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
        for (size_t index = 0; index < pending.size(); ++index) {
            const int current = pending[index];
            [numbers addObject:@(current)];
            TopoDS_Vertex first, last;
            TopExp::Vertices(TopoDS::Edge(_edges(current)), first, last);
            for (const TopoDS_Vertex &vertex : {first, last}) {
                if (vertex.IsNull() || !incident.Contains(vertex)) continue;
                for (TopTools_ListOfShape::Iterator it(incident.FindFromKey(vertex)); it.More(); it.Next()) {
                    const int neighbor = _edges.FindIndex(it.Value());
                    if (neighbor < 1 || seen[size_t(neighbor)] || !boundary.Contains(it.Value())) continue;
                    seen[size_t(neighbor)] = true;
                    pending.push_back(neighbor);
                }
            }
        }
        return numbers;
    } catch (...) {
        return @[];
    }
}

- (NSArray<NSNumber *> *)tangentEdgeNumbersStartingAtEdge:(NSInteger)edge {
    if (edge < 1 || edge > _edges.Extent() || _edges.Extent() > 10000) return @[];
    try {
        TopTools_IndexedDataMapOfShapeListOfShape incident, edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_VERTEX, TopAbs_EDGE, incident);
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        auto tangentAt = [](const TopoDS_Edge &candidate, const TopoDS_Vertex &vertex, gp_Vec &tangent) {
            if (BRep_Tool::Degenerated(candidate)) return false;
            TopoDS_Vertex first, last;
            TopExp::Vertices(candidate, first, last);
            if (first.IsNull() || last.IsNull()) return false;
            BRepAdaptor_Curve curve(candidate);
            if (!vertex.IsSame(first) && !vertex.IsSame(last)) return false;
            // Bei umgekehrt orientierten Kanten entspricht first nicht zwingend FirstParameter.
            const double parameter = BRep_Tool::Parameter(vertex, candidate);
            if (!std::isfinite(parameter)) return false;
            gp_Pnt point;
            curve.D1(parameter, point, tangent);
            if (tangent.Magnitude() < 1e-10) return false;
            tangent.Normalize();
            return true;
        };
        auto sharesFace = [&](const TopoDS_Edge &a, const TopoDS_Edge &b) {
            if (!edgeFaces.Contains(a) || !edgeFaces.Contains(b)) return false;
            for (TopTools_ListOfShape::Iterator left(edgeFaces.FindFromKey(a)); left.More(); left.Next()) {
                for (TopTools_ListOfShape::Iterator right(edgeFaces.FindFromKey(b)); right.More(); right.Next()) {
                    if (left.Value().IsSame(right.Value())) return true;
                }
            }
            return false;
        };
        std::vector<int> pending {int(edge)};
        std::vector<bool> seen(size_t(_edges.Extent()) + 1, false);
        seen[size_t(edge)] = true;
        NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
        constexpr double minDot = 0.9986295347545738; // cos(3°)
        for (size_t index = 0; index < pending.size(); ++index) {
            const int current = pending[index];
            [numbers addObject:@(current)];
            const TopoDS_Edge currentEdge = TopoDS::Edge(_edges(current));
            TopoDS_Vertex first, last;
            TopExp::Vertices(currentEdge, first, last);
            for (const TopoDS_Vertex &vertex : {first, last}) {
                if (vertex.IsNull() || !incident.Contains(vertex)) continue;
                gp_Vec currentTangent;
                if (!tangentAt(currentEdge, vertex, currentTangent)) continue;
                for (TopTools_ListOfShape::Iterator it(incident.FindFromKey(vertex)); it.More(); it.Next()) {
                    const TopoDS_Edge neighborEdge = TopoDS::Edge(it.Value());
                    const int neighbor = _edges.FindIndex(neighborEdge);
                    if (neighbor < 1 || seen[size_t(neighbor)] || !sharesFace(currentEdge, neighborEdge)) continue;
                    gp_Vec neighborTangent;
                    if (!tangentAt(neighborEdge, vertex, neighborTangent)
                        || std::abs(currentTangent.Dot(neighborTangent)) < minDot) continue;
                    seen[size_t(neighbor)] = true;
                    pending.push_back(neighbor);
                }
            }
        }
        return numbers;
    } catch (...) {
        return @[];
    }
}

/// Bei bestimmten gültigen OCCT-Rundungen bleibt eine beschnittene Fläche ohne Triangulation (Projekt 27:
/// obere Fläche vorhanden, aber im Viewport durchsichtig). STEP-Neuaufbau normalisiert ihre 2D-Kurven.
/// Nur im seltenen Fehlerfall verwenden; die normalen Rundungen behalten ihre ursprüngliche Topologie.
- (nullable PCKShape *)meshCompleteFillet {
    if (!self.isBRepValid || !self.isClosedSolid) return nil;
    PCKMesh *mesh = [self triangulateWithDeflection:0.05];
    std::vector<bool> present(size_t(_faces.Extent()) + 1, false);
    const uint32_t *faceNumbers = static_cast<const uint32_t *>(mesh.faceIndexData.bytes);
    for (NSUInteger i = 0; i < mesh.faceIndexData.length / sizeof(uint32_t); ++i) {
        if (faceNumbers[i] < present.size()) present[faceNumbers[i]] = true;
    }
    bool missing = false;
    for (int face = 1; face <= _faces.Extent(); ++face) {
        if (!present[size_t(face)] && [self areaOfFace:face] > 1e-6) { missing = true; break; }
    }
    if (!missing) return self;
#if PCK_HAS_STEP
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"pencilcad-fillet-%@.step", [NSUUID UUID].UUIDString]];
    PCKShape *repaired = nil;
    if ([PCKShape writeShapes:@[self] toSTEPFile:path]) {
        NSArray<PCKShape *> *loaded = [PCKShape shapesFromSTEPFile:path];
        if (loaded.count == 1) {
            PCKShape *candidate = loaded.firstObject;
            const double expected = self.volume;
            const double difference = std::abs(candidate.volume - expected);
            NSArray<NSNumber *> *beforeBox = self.boundingBox, *afterBox = candidate.boundingBox;
            bool sameBounds = beforeBox.count == 6 && afterBox.count == 6;
            for (NSUInteger k = 0; sameBounds && k < 6; ++k) {
                sameBounds = std::abs(beforeBox[k].doubleValue - afterBox[k].doubleValue) <= 0.01;
            }
            // STEP normalisiert hier die fehlerhaften 2D-Grenzkurven; nur nahezu identische Solids übernehmen.
            if (candidate.isBRepValid && candidate.isClosedSolid && candidate.faceCount == self.faceCount && sameBounds
                && difference <= std::max(1e-5, std::abs(expected) * 0.003)) {
                PCKMesh *check = [candidate triangulateWithDeflection:0.05];
                std::vector<bool> checkFaces(size_t(candidate->_faces.Extent()) + 1, false);
                const uint32_t *numbers = static_cast<const uint32_t *>(check.faceIndexData.bytes);
                for (NSUInteger i = 0; i < check.faceIndexData.length / sizeof(uint32_t); ++i) {
                    if (numbers[i] < checkFaces.size()) checkFaces[numbers[i]] = true;
                }
                bool complete = true;
                for (int face = 1; face <= candidate->_faces.Extent(); ++face) {
                    if (!checkFaces[size_t(face)] && [candidate areaOfFace:face] > 1e-6) {
                        complete = false; break;
                    }
                }
                if (complete) repaired = candidate;
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (repaired != nil) return repaired;
#endif
    return nil;
}

// N5: filletingEdgesOfFace:/chamferingEdgesOfFace: entfernt (Build 41) – ohne Aufrufer in App/ und Tests/ und
// am isolierten Worker (IsolatedBlend) vorbei. Flächenweise Auswahl läuft über edgeNumbersOfFace: + filletingEdges:.

/// Kanten aus Nummern (ab 1); eine veraltete Nummer macht die gesamte Auswahl ungültig.
static std::vector<TopoDS_Edge> edgesFromNumbers(const TopTools_IndexedMapOfShape &edges, NSArray<NSNumber *> *numbers) {
    std::vector<TopoDS_Edge> result;
    for (NSNumber *number in numbers) {
        const NSInteger index = number.integerValue;
        if (index < 1 || index > edges.Extent()) return {};
        result.push_back(TopoDS::Edge(edges(int(index))));
    }
    return result;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius {
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    TopoDS_Shape result = blendEdges(_shape, edges, radius, false);
    if (result.IsNull() && edges.size() == 1) result = extendedBoxFillet(_shape, edges.front(), radius);
    return result.IsNull() ? nil : [[[PCKShape alloc] initWithShape:result] meshCompleteFillet];
}

// MARK: Rundungsoptionen (Build 42) – Setback-Ecken (G1) und G2-Profil-Sweep
// Portiert aus dem Python-Prototyp (OCCT 8.0.1, setback-g2/skripte: setback.py, g2lib.py, g2.py, robust.py).
// Reiner C++-Block (kein Objective-C) zwischen BEGIN/END, damit er auf dem Rechner ohne Xcode gegen dieselben
// OCCT-8.0.1-Bibliotheken übersetzt und geprüft werden kann.
// BEGIN PCK_BLEND_OPTIONS_CORE
namespace pckblend {

/// Zeitbudget je Aufruf (Vertrag 1a Punkt 9: Ziel < 4 s, hartes Limit 8 s im Worker). Zwischen den Schritten
/// geprüft; ein überschrittenes Budget liefert nil statt eines Ergebnisses, das der Worker ohnehin verwirft.
struct Budget {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    double seconds = 6.0;
    bool exceeded() const {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() > seconds;
    }
};

/// Größte Normalenabweichung an Übergangskanten (Grad). Strenger als BRepCheck_Analyzer: der Prototyp hat
/// „gültige“ Ergebnisse mit 77°-Knick gefunden.
static const double kMaxBoundaryAngle = 2.0;
/// Obergrenze für Toleranzen nach dem Nähen (ShapeFix_ShapeTolerance::LimitTolerance). Exakte Sweeps (G2) bleiben
/// weit darunter; Füllflächen brauchen etwa 6e-4 · s (gemessen 0,0005 bei s = 3 bis 0,04 bei s = 75).
static const double kMaxTolerance = 1e-3;
static const double kSewingTolerance = 1e-4;

static double volumeOf(const TopoDS_Shape &shape) {
    GProp_GProps props;
    BRepGProp::VolumeProperties(shape, props);
    return props.Mass();
}

static bool containsSame(const std::vector<TopoDS_Shape> &list, const TopoDS_Shape &shape) {
    for (const auto &item : list) {
        if (item.IsSame(shape)) return true;
    }
    return false;
}

static gp_Pnt pointAt(const TopoDS_Edge &edge, double t) {
    BRepAdaptor_Curve curve(edge);
    return curve.Value(curve.FirstParameter() + t * (curve.LastParameter() - curve.FirstParameter()));
}

/// Einheitsnormale der Fläche am nächstgelegenen Flächenpunkt (Orientierung der Fläche berücksichtigt).
static bool normalAt(const TopoDS_Face &face, const gp_Pnt &point, gp_Vec &normal) {
    const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
    if (surface.IsNull()) return false;
    GeomAPI_ProjectPointOnSurf projection(point, surface);
    if (!projection.IsDone() || projection.NbPoints() < 1) return false;
    double u = 0, v = 0;
    projection.LowerDistanceParameters(u, v);
    gp_Pnt onSurface;
    BRepGProp_Face(face).Normal(u, v, onSurface, normal);
    if (normal.Magnitude() < 1e-12) return false;
    normal.Normalize();
    return true;
}

struct Boundary {
    TopoDS_Edge edge;
    TopoDS_Face support;
};

/// Randwinkel-Test: größter Winkel zwischen den Normalen von face und Nachbarfläche entlang der Übergänge.
static double maxBoundaryAngle(const TopoDS_Face &face, const std::vector<Boundary> &bounds, int samples = 9) {
    double worst = 0;
    for (const auto &bound : bounds) {
        for (int k = 0; k < samples; ++k) {
            const gp_Pnt p = pointAt(bound.edge, (k + 0.5) / samples);
            gp_Vec a, b;
            if (!normalAt(face, p, a) || !normalAt(bound.support, p, b)) return 180.0;
            const double cosine = std::min(1.0, std::abs(a.Dot(b)));
            worst = std::max(worst, std::acos(cosine) * 180.0 / M_PI);
        }
    }
    return worst;
}

/// Flächen nähen → eine geschlossene Schale → Solid → ShapeFix (wie sew_solid im Prototyp). Leer bei freien
/// oder mehrfachen Kanten bzw. mehr als einer Schale.
static TopoDS_Shape sewSolid(const std::vector<TopoDS_Shape> &faces) {
    BRepBuilderAPI_Sewing sewing(kSewingTolerance);
    for (const auto &face : faces) sewing.Add(face);
    sewing.Perform();
    if (sewing.NbFreeEdges() != 0 || sewing.NbMultipleEdges() != 0) return TopoDS_Shape();
    const TopoDS_Shape sewed = sewing.SewedShape();
    if (sewed.IsNull()) return TopoDS_Shape();
    TopoDS_Shell shell;
    int shells = 0;
    for (TopExp_Explorer it(sewed, TopAbs_SHELL); it.More(); it.Next()) {
        shell = TopoDS::Shell(it.Current());
        ++shells;
    }
    if (shells != 1 || !BRep_Tool::IsClosed(shell)) return TopoDS_Shape();
    BRepBuilderAPI_MakeSolid makeSolid(shell);
    if (!makeSolid.IsDone()) return TopoDS_Shape();
    ShapeFix_Solid fixSolid(makeSolid.Solid());
    fixSolid.Perform();
    TopoDS_Shape result = fixSolid.Solid();
    if (result.IsNull()) return TopoDS_Shape();
    ShapeFix_Shape fix(result);
    fix.Perform();
    result = fix.Shape();
    if (result.IsNull()) return TopoDS_Shape();
    if (volumeOf(result) < 0) result.Reverse();
    return result;
}

/// Gemeinsame Endbehandlung: validSolid, Toleranzen begrenzen (STEP, HLR), erneut prüfen.
static TopoDS_Shape finished(const TopoDS_Shape &shape, double maxTolerance) {
    TopoDS_Shape result = validSolid(shape);
    if (result.IsNull()) return TopoDS_Shape();
    ShapeFix_ShapeTolerance limiter;
    limiter.LimitTolerance(result, 1e-7, maxTolerance);
    if (!BRepCheck_Analyzer(result).IsValid()) return TopoDS_Shape();
    int solids = 0;
    for (TopExp_Explorer it(result, TopAbs_SOLID); it.More(); it.Next()) ++solids;
    if (solids != 1) return TopoDS_Shape();
    return result;
}

/// Rolling-Ball-Rundung mit einem Radius je Kante (Gerüst für beide Verfahren).
static bool addEdges(BRepFilletAPI_MakeFillet &maker, const std::vector<TopoDS_Edge> &edges,
                     const std::vector<double> &radii) {
    for (size_t k = 0; k < edges.size(); ++k) {
        const int contour = maker.Contour(edges[k]);
        if (contour > 0) maker.SetRadius(radii[k], contour, edges[k]);
        else maker.Add(radii[k], edges[k]);
        if (maker.Contour(edges[k]) == 0) return false;
    }
    maker.Build();
    return maker.IsDone() && maker.NbFaultyContours() == 0 && !maker.Shape().IsNull();
}

static double edgeLength(const TopoDS_Edge &edge) {
    GProp_GProps props;
    BRepGProp::LinearProperties(edge, props);
    return props.Mass();
}

// MARK: Setback-Ecke (G1)

struct Corner {
    gp_Pnt vertex;
    gp_Vec dirs[3];     // Einheitsrichtungen der drei Kanten vom Eckpunkt weg, rechtshändig
    size_t edges[3];    // Indizes in der Auswahl
    double rho = 0;     // Radius der gerundeten Innenkanten des Werkzeugwürfels
    TopoDS_Shape tool;
    std::vector<TopoDS_Shape> removed;
};

/// Setback-Ecken: Rolling-Ball-Rundung, an jeder Ecke mit drei gewählten Kanten einen Würfel [V − B, V + s]
/// (lokale Kantenachsen) mit gerundeten Innenkanten abziehen, die Lücke (12 Ränder: 3 × Gerade–Bogen–Gerade auf
/// den Ebenen, 3 Querschnitte der Rundungszylinder) mit BRepFill_Filling G1 schließen, nähen. Ecken mit
/// weniger als drei gewählten Kanten bleiben Rolling Ball; gibt es gar keine Setback-Ecke, ist die Option hier
/// wirkungslos → leer (kein stiller Rückfall). Leer bei jeder nicht abgedeckten Topologie.
static TopoDS_Shape setbackBlend(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges,
                                 const std::vector<double> &radii, double setback, const Budget &budget) {
    if (!std::isfinite(setback) || setback <= 0 || edges.empty() || edges.size() != radii.size())
        return TopoDS_Shape();
    try {
        TopTools_IndexedDataMapOfShapeListOfShape vertexEdges;
        TopExp::MapShapesAndAncestors(shape, TopAbs_VERTEX, TopAbs_EDGE, vertexEdges);
        std::vector<Corner> corners;
        std::vector<int> ends(edges.size(), 0);
        for (int iv = 1; iv <= vertexEdges.Extent(); ++iv) {
            const TopoDS_Vertex vertex = TopoDS::Vertex(vertexEdges.FindKey(iv));
            std::vector<TopoDS_Shape> incident;
            for (TopTools_ListOfShape::Iterator it(vertexEdges(iv)); it.More(); it.Next()) {
                if (BRep_Tool::Degenerated(TopoDS::Edge(it.Value())) || containsSame(incident, it.Value())) continue;
                incident.push_back(it.Value());
            }
            std::vector<size_t> selected;
            for (size_t k = 0; k < edges.size(); ++k) {
                if (containsSame(incident, edges[k])) selected.push_back(k);
            }
            if (selected.size() < 3) continue;
            // Nur konvexe 3-Kanten-Ecken (Würfel-Ansatz); 4 und mehr Kanten sind nicht abgedeckt
            if (selected.size() != 3 || incident.size() != 3) return TopoDS_Shape();
            Corner corner;
            corner.vertex = BRep_Tool::Pnt(vertex);
            for (int i = 0; i < 3; ++i) {
                const TopoDS_Edge &edge = edges[selected[size_t(i)]];
                if (BRepAdaptor_Curve(edge).GetType() != GeomAbs_Line || BRep_Tool::IsClosed(edge)) return TopoDS_Shape();
                TopoDS_Vertex first, last;
                TopExp::Vertices(edge, first, last);
                if (first.IsNull() || last.IsNull()) return TopoDS_Shape();
                const TopoDS_Vertex other = first.IsSame(vertex) ? last : first;
                gp_Vec direction(corner.vertex, BRep_Tool::Pnt(other));
                if (direction.Magnitude() < 1e-9) return TopoDS_Shape();
                corner.dirs[i] = direction.Normalized();
                corner.edges[i] = selected[size_t(i)];
                ends[selected[size_t(i)]] += 1;
            }
            for (int i = 0; i < 3; ++i) {
                for (int j = i + 1; j < 3; ++j) {
                    if (std::abs(corner.dirs[i].Dot(corner.dirs[j])) > 1e-6) return TopoDS_Shape();
                }
            }
            if (corner.dirs[0].Crossed(corner.dirs[1]).Dot(corner.dirs[2]) < 0) {
                std::swap(corner.dirs[0], corner.dirs[1]);
                std::swap(corner.edges[0], corner.edges[1]);
            }
            corners.push_back(corner);
        }
        if (corners.empty()) return TopoDS_Shape();
        // Setback kürzer als jede beteiligte Kante (zwei Setback-Enden: zusammen kürzer)
        for (size_t k = 0; k < edges.size(); ++k) {
            if (ends[k] > 0 && ends[k] * setback >= edgeLength(edges[k]) - 1e-6) return TopoDS_Shape();
        }
        for (auto &corner : corners) {
            double shortest = 1e100, largest = 0;
            for (int i = 0; i < 3; ++i) {
                shortest = std::min(shortest, edgeLength(edges[corner.edges[i]]));
                largest = std::max(largest, radii[corner.edges[i]]);
            }
            // Konvex: nur der Oktant der drei Kantenrichtungen liegt im Körper
            const double eps = std::min(0.05 * shortest, 0.25 * setback);
            for (int code = 0; code < 8; ++code) {
                const double sx = (code & 1) ? -1 : 1, sy = (code & 2) ? -1 : 1, sz = (code & 4) ? -1 : 1;
                const gp_Vec offset = corner.dirs[0] * sx + corner.dirs[1] * sy + corner.dirs[2] * sz;
                BRepClass3d_SolidClassifier classifier(shape, corner.vertex.Translated(offset * eps), 1e-7);
                const TopAbs_State expected = code == 0 ? TopAbs_IN : TopAbs_OUT;
                if (classifier.State() != expected) return TopoDS_Shape();
            }
            // Die Schnittebenen müssen die Rundungszylinder treffen, nicht das Kugel-Eckstück
            const double gap = setback - largest;
            if (gap <= std::max(0.02 * setback, 1e-3)) return TopoDS_Shape();
            // Halbe Lücke: kleinste Randwinkel über alle Maßstäbe (gemessen 0,5 · gap gegen 0,7 und 0,85 · gap)
            corner.rho = 0.5 * gap;
        }

        BRepFilletAPI_MakeFillet maker(shape);
        if (!addEdges(maker, edges, radii)) return TopoDS_Shape();
        TopoDS_Shape rolled = validSolid(maker.Shape());
        if (rolled.IsNull() || budget.exceeded()) return TopoDS_Shape();
        // Frische Kopie: das Nähen verändert sonst Toleranzen gemeinsamer Kanten (Prototyp: nicht-deterministische
        // Folgefehler)
        BRepBuilderAPI_Copy copier(rolled);
        rolled = copier.Shape();
        const double rolledVolume = volumeOf(rolled);
        if (!std::isfinite(rolledVolume) || rolledVolume <= 0) return TopoDS_Shape();

        TopTools_ListOfShape arguments, tools;
        arguments.Append(rolled);
        for (auto &corner : corners) {
            const double margin = std::max(1.0, 0.5 * setback);
            const gp_Vec diagonal = corner.dirs[0] + corner.dirs[1] + corner.dirs[2];
            const gp_Pnt origin = corner.vertex.Translated(diagonal * -margin);
            BRepPrimAPI_MakeBox box(gp_Ax2(origin, gp_Dir(corner.dirs[2]), gp_Dir(corner.dirs[0])),
                                    margin + setback, margin + setback, margin + setback);
            const TopoDS_Shape cube = box.Shape();
            const gp_Pnt inner = corner.vertex.Translated(diagonal * setback);
            BRepFilletAPI_MakeFillet rounding(cube);
            int count = 0;
            TopTools_IndexedMapOfShape cubeEdges;
            TopExp::MapShapes(cube, TopAbs_EDGE, cubeEdges);
            for (int i = 1; i <= cubeEdges.Extent(); ++i) {
                const TopoDS_Edge edge = TopoDS::Edge(cubeEdges(i));
                TopoDS_Vertex first, last;
                TopExp::Vertices(edge, first, last);
                if (BRep_Tool::Pnt(first).Distance(inner) < 1e-7 || BRep_Tool::Pnt(last).Distance(inner) < 1e-7) {
                    rounding.Add(corner.rho, edge);
                    ++count;
                }
            }
            if (count != 3) return TopoDS_Shape();
            rounding.Build();
            if (!rounding.IsDone() || rounding.Shape().IsNull()) return TopoDS_Shape();
            corner.tool = rounding.Shape();
            tools.Append(corner.tool);
        }
        BRepAlgoAPI_Cut cut;
        cut.SetArguments(arguments);
        cut.SetTools(tools);
        cut.Build();
        if (!cut.IsDone() || cut.HasErrors() || cut.Shape().IsNull() || budget.exceeded()) return TopoDS_Shape();
        const TopoDS_Shape cutShape = cut.Shape();
        TopTools_IndexedMapOfShape cutFaces;
        TopExp::MapShapes(cutShape, TopAbs_FACE, cutFaces);

        // Werkzeugflächen im Ergebnis (Verlauf der Booleschen Operation) = Flächen, die die Füllfläche ersetzt
        std::vector<TopoDS_Shape> removedAll;
        for (auto &corner : corners) {
            TopTools_IndexedMapOfShape toolFaces;
            TopExp::MapShapes(corner.tool, TopAbs_FACE, toolFaces);
            for (int i = 1; i <= toolFaces.Extent(); ++i) {
                const TopoDS_Shape &toolFace = toolFaces(i);
                const TopTools_ListOfShape &modified = cut.Modified(toolFace);
                if (!modified.IsEmpty()) {
                    for (TopTools_ListOfShape::Iterator it(modified); it.More(); it.Next()) {
                        if (cutFaces.Contains(it.Value()) && !containsSame(corner.removed, it.Value()))
                            corner.removed.push_back(it.Value());
                    }
                } else if (!cut.IsDeleted(toolFace) && cutFaces.Contains(toolFace)
                           && !containsSame(corner.removed, toolFace)) {
                    corner.removed.push_back(toolFace);
                }
            }
            if (corner.removed.empty()) return TopoDS_Shape();
            // Alle entfernten Flächen liegen im Eckwürfel [0, s]³ (sonst hat das Werkzeug anderes getroffen)
            for (const auto &face : corner.removed) {
                GProp_GProps props;
                BRepGProp::SurfaceProperties(face, props);
                const gp_Vec offset(corner.vertex, props.CentreOfMass());
                for (int i = 0; i < 3; ++i) {
                    const double along = offset.Dot(corner.dirs[i]);
                    if (along < -1e-6 || along > setback + 1e-6) return TopoDS_Shape();
                }
            }
            removedAll.insert(removedAll.end(), corner.removed.begin(), corner.removed.end());
        }

        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(cutShape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        std::vector<TopoDS_Shape> result;
        for (int i = 1; i <= cutFaces.Extent(); ++i) {
            if (!containsSame(removedAll, cutFaces(i))) result.push_back(cutFaces(i));
        }
        for (auto &corner : corners) {
            std::vector<Boundary> bounds;
            std::vector<TopoDS_Shape> seen;
            for (const auto &face : corner.removed) {
                for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
                    const TopoDS_Edge edge = TopoDS::Edge(it.Current());
                    if (BRep_Tool::Degenerated(edge) || containsSame(seen, edge)) continue;
                    seen.push_back(edge);
                    if (!edgeFaces.Contains(edge)) continue;
                    for (TopTools_ListOfShape::Iterator nb(edgeFaces.FindFromKey(edge)); nb.More(); nb.Next()) {
                        if (containsSame(removedAll, nb.Value())) continue;
                        bounds.push_back({edge, TopoDS::Face(nb.Value())});
                        break;
                    }
                }
            }
            if (bounds.size() != 12) return TopoDS_Shape();
            for (const auto &bound : bounds) {
                const GeomAbs_SurfaceType type = BRepAdaptor_Surface(bound.support, Standard_False).GetType();
                if (type != GeomAbs_Plane && type != GeomAbs_Cylinder) return TopoDS_Shape();
            }
            // Füllfläche G1 an allen 12 Rändern. Erst die schnellen OCCT-Standardwerte (Grad ≤ 8, 9 Segmente),
            // bei zu großem Randwinkel feiner (großes s/r, kleine Teile: gemessen 2,6° → 0,8° mit 10/20)
            static const int kFillingSteps[][2] = {{8, 9}, {10, 20}, {12, 30}};
            TopoDS_Face patch;
            for (const auto &step : kFillingSteps) {
                if (budget.exceeded()) return TopoDS_Shape();
                BRepFill_Filling filling(3, 15, 2, Standard_False, 1e-5, 1e-4, 1e-2, 0.1, step[0], step[1]);
                for (const auto &bound : bounds) filling.Add(bound.edge, bound.support, GeomAbs_G1, Standard_True);
                filling.Build();
                if (!filling.IsDone()) continue;
                const TopoDS_Face candidate = filling.Face();
                if (candidate.IsNull() || maxBoundaryAngle(candidate, bounds) > kMaxBoundaryAngle) continue;
                patch = candidate;
                break;
            }
            if (patch.IsNull()) return TopoDS_Shape();
            result.push_back(patch);
        }
        const TopoDS_Shape solid = finished(sewSolid(result), std::max(kMaxTolerance, 2e-3 * setback));
        if (solid.IsNull() || budget.exceeded()) return TopoDS_Shape();
        // Volumenplausibilität: ±2 % gegenüber Rolling Ball und höchstens s³ je Ecke Unterschied
        const double difference = std::abs(volumeOf(solid) - rolledVolume);
        if (!std::isfinite(difference) || difference > 0.02 * rolledVolume
            || difference > double(corners.size()) * setback * setback * setback) return TopoDS_Shape();
        return solid;
    } catch (const Standard_Failure &) {
        return TopoDS_Shape();
    } catch (...) {
        return TopoDS_Shape();
    }
}

// MARK: G2-Rundung (Profil-Sweep)

/// G2-Profil zwischen den Enden eines Querschnitts (Kreisbogen der G1-Rundung): tangential an beiden Enden,
/// Krümmung 0 an beiden Enden (je drei Pole auf der Tangente). rho < 0: Bezier Grad 4, P0, P0 + 0,3·(C − P0),
/// C, P1 + 0,3·(C − P1), P1 wie im Prototyp. rho in [0,1; 0,9]: Grad 5 mit Schulterpunkt
/// M = Q + rho·(C − Q) (Q = Sehnenmitte), Pole nie über C hinaus. C = Schnitt der Endtangenten.
/// triangle = Fläche des Dreiecks P0, C, P1 (Keil-Querschnitt), centroid = sein Schwerpunkt.
static bool g2Profile(const TopoDS_Edge &section, double rho, TopoDS_Edge &profile, double &triangle,
                      gp_Pnt &centroid, gp_Vec &planeNormal) {
    const TopoDS_Edge edge = TopoDS::Edge(section.Oriented(TopAbs_FORWARD));
    BRepAdaptor_Curve curve(edge);
    gp_Pnt p0, p1;
    gp_Vec t0, t1;
    curve.D1(curve.FirstParameter(), p0, t0);
    curve.D1(curve.LastParameter(), p1, t1);
    if (t0.Magnitude() < 1e-12 || t1.Magnitude() < 1e-12) return false;
    t0.Normalize();
    t1.Reverse();
    t1.Normalize();
    // Kleinste Quadrate: p0 + a·t0 ≈ p1 + b·t1
    const gp_Vec w(p0, p1);
    const double aa = t0.Dot(t0), ab = t0.Dot(t1), bb = t1.Dot(t1), dw = t0.Dot(w), ew = t1.Dot(w);
    const double den = aa * bb - ab * ab;
    if (std::abs(den) < 1e-12) return false;
    const double along0 = (dw * bb - ab * ew) / den, along1 = (ab * dw - aa * ew) / den;
    if (!(along0 > 0) || !(along1 > 0)) return false;
    const gp_Pnt a = p0.Translated(t0 * along0), b = p1.Translated(t1 * along1);
    if (a.Distance(b) > 1e-6 * std::max(1.0, along0)) return false;
    const gp_Pnt corner((a.XYZ() + b.XYZ()) * 0.5);
    const gp_Vec u0(p0, corner), u1(p1, corner);
    std::vector<gp_Pnt> poles;
    if (rho < 0) {
        poles = {p0, p0.Translated(u0 * 0.3), corner, p1.Translated(u1 * 0.3), p1};
    } else {
        // Schulter (t = 0,5) des Grad-5-Polygons: M = Q + (5·f1 + 10·f2)/16 · (C − Q)
        const double f2 = std::min(1.0, 1.28 * rho);
        const double f1 = f2 < 1.0 ? 0.5 * f2 : (16.0 * rho - 10.0) / 5.0;
        if (!(f1 > 0) || f1 > f2) return false;
        poles = {p0, p0.Translated(u0 * f1), p0.Translated(u0 * f2), p1.Translated(u1 * f2), p1.Translated(u1 * f1), p1};
    }
    TColgp_Array1OfPnt array(1, int(poles.size()));
    for (size_t i = 0; i < poles.size(); ++i) array.SetValue(int(i) + 1, poles[i]);
    const Handle(Geom_BezierCurve) bezier = new Geom_BezierCurve(array);
    TopoDS_Vertex first, last;
    TopExp::Vertices(edge, first, last);
    if (first.IsNull() || last.IsNull()) return false;
    BRepBuilderAPI_MakeEdge make(bezier, first, last);
    if (!make.IsDone()) return false;
    profile = make.Edge();
    const gp_Vec cross = u0.Crossed(u1);
    triangle = 0.5 * cross.Magnitude();
    if (triangle < 1e-12) return false;
    planeNormal = cross.Normalized();
    centroid = gp_Pnt((p0.XYZ() + p1.XYZ() + corner.XYZ()) / 3.0);
    return true;
}

/// Kanten einer Rundungsfläche: Tangentenkanten (zu Nachbarflächen tangential), Endkanten, Naht.
struct FilletFaceEdges {
    std::vector<Boundary> tangent, ends;
    TopoDS_Edge seam;
};

static bool classifyFilletFace(const TopoDS_Face &face, const TopTools_IndexedDataMapOfShapeListOfShape &edgeFaces,
                               FilletFaceEdges &out) {
    std::vector<TopoDS_Shape> seen;
    for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(it.Current());
        if (containsSame(seen, edge)) continue;
        seen.push_back(edge);
        if (BRep_Tool::Degenerated(edge)) continue;
        if (BRep_Tool::IsClosed(edge, face)) {
            if (!out.seam.IsNull()) return false;
            out.seam = edge;
            continue;
        }
        if (!edgeFaces.Contains(edge)) return false;
        std::vector<TopoDS_Face> neighbors;
        for (TopTools_ListOfShape::Iterator nb(edgeFaces.FindFromKey(edge)); nb.More(); nb.Next()) {
            if (!nb.Value().IsSame(face)) neighbors.push_back(TopoDS::Face(nb.Value()));
        }
        if (neighbors.size() != 1) return false;
        const gp_Pnt mid = pointAt(edge, 0.5);
        gp_Vec a, b;
        if (!normalAt(face, mid, a) || !normalAt(neighbors.front(), mid, b)) return false;
        if (std::abs(a.Dot(b)) > 0.9995) out.tangent.push_back({edge, neighbors.front()});
        else out.ends.push_back({edge, neighbors.front()});
    }
    return out.tangent.size() == 2;
}

enum class G2Kind { Line, Circle };

/// G2-Rundung: G1-Rundung als Gerüst (gleiche Ansatzlinien wie mit Radius r), jede Rundungsfläche durch einen
/// exakten Sweep des G2-Profils ersetzt: gerade Kante zwischen zwei Ebenen → Extrusion (Endkanten auf den
/// ebenen Endflächen per BRepTools_ReShape getauscht), geschlossene Kreiskante Ebene/koaxialer Zylinder → Rotation
/// des Nahtquerschnitts um 360°. Jede gewählte Kante muss isoliert sein (kein Eckpunkt mit einer anderen gewählten
/// Kante, keine tangentiale Fortsetzung). Alles andere → leer.
static TopoDS_Shape g2Blend(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges,
                            const std::vector<double> &radii, double rho, const Budget &budget) {
    if (edges.empty() || edges.size() != radii.size()) return TopoDS_Shape();
    if (rho >= 0 && !(rho >= 0.1 && rho <= 0.9)) return TopoDS_Shape();
    try {
        TopTools_IndexedDataMapOfShapeListOfShape vertexEdges, sourceEdgeFaces;
        TopExp::MapShapesAndAncestors(shape, TopAbs_VERTEX, TopAbs_EDGE, vertexEdges);
        TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, sourceEdgeFaces);
        std::vector<TopoDS_Shape> selected(edges.begin(), edges.end());
        std::vector<G2Kind> kinds;
        for (const auto &edge : edges) {
            if (BRep_Tool::Degenerated(edge) || !sourceEdgeFaces.Contains(edge)) return TopoDS_Shape();
            TopoDS_Vertex first, last;
            TopExp::Vertices(edge, first, last);
            for (const TopoDS_Vertex &vertex : {first, last}) {
                if (vertex.IsNull() || !vertexEdges.Contains(vertex)) return TopoDS_Shape();
                for (TopTools_ListOfShape::Iterator it(vertexEdges.FindFromKey(vertex)); it.More(); it.Next()) {
                    if (!it.Value().IsSame(edge) && containsSame(selected, it.Value())) return TopoDS_Shape();
                }
            }
            std::vector<TopoDS_Face> faces;
            for (TopTools_ListOfShape::Iterator it(sourceEdgeFaces.FindFromKey(edge)); it.More(); it.Next()) {
                bool known = false;
                for (const auto &face : faces) known = known || face.IsSame(it.Value());
                if (!known) faces.push_back(TopoDS::Face(it.Value()));
            }
            if (faces.size() != 2) return TopoDS_Shape();
            const GeomAbs_SurfaceType t0 = BRepAdaptor_Surface(faces[0], Standard_False).GetType();
            const GeomAbs_SurfaceType t1 = BRepAdaptor_Surface(faces[1], Standard_False).GetType();
            BRepAdaptor_Curve curve(edge);
            if (curve.GetType() == GeomAbs_Line && t0 == GeomAbs_Plane && t1 == GeomAbs_Plane) {
                kinds.push_back(G2Kind::Line);
            } else if (curve.GetType() == GeomAbs_Circle && BRep_Tool::IsClosed(edge)
                       && ((t0 == GeomAbs_Plane && t1 == GeomAbs_Cylinder) || (t0 == GeomAbs_Cylinder && t1 == GeomAbs_Plane))) {
                const TopoDS_Face &cylinder = t0 == GeomAbs_Cylinder ? faces[0] : faces[1];
                const gp_Ax1 cylinderAxis = BRepAdaptor_Surface(cylinder, Standard_False).Cylinder().Axis();
                if (!cylinderAxis.IsCoaxial(curve.Circle().Axis(), 1e-6, 1e-6)) return TopoDS_Shape();
                kinds.push_back(G2Kind::Circle);
            } else {
                return TopoDS_Shape();
            }
        }

        BRepFilletAPI_MakeFillet maker(shape);
        if (!addEdges(maker, edges, radii) || maker.NbContours() != int(edges.size())) return TopoDS_Shape();
        const TopoDS_Shape rolled = maker.Shape();
        TopTools_IndexedMapOfShape rolledFaces;
        TopExp::MapShapes(rolled, TopAbs_FACE, rolledFaces);
        std::vector<TopoDS_Face> filletFaces;
        for (const auto &edge : edges) {
            const int contour = maker.Contour(edge);
            if (contour < 1 || maker.NbEdges(contour) != 1) return TopoDS_Shape();
            // NewFaces(i) ist bei mehreren Konturen unzuverlässig (Prototyp: leer für Kontur 2) → Generated
            std::vector<TopoDS_Shape> generated;
            for (TopTools_ListOfShape::Iterator it(maker.Generated(edge)); it.More(); it.Next()) {
                if (it.Value().ShapeType() == TopAbs_FACE && rolledFaces.Contains(it.Value())
                    && !containsSame(generated, it.Value())) generated.push_back(it.Value());
            }
            if (generated.size() != 1) return TopoDS_Shape();
            filletFaces.push_back(TopoDS::Face(generated.front()));
        }
        const double sourceVolume = volumeOf(shape), rolledVolume = volumeOf(rolled);
        if (budget.exceeded()) return TopoDS_Shape();

        BRepBuilderAPI_Copy copier(rolled);
        const TopoDS_Shape copy = copier.Shape();
        for (auto &face : filletFaces) {
            const TopTools_ListOfShape &copied = copier.Modified(face);
            if (copied.Extent() != 1) return TopoDS_Shape();
            face = TopoDS::Face(copied.First());
        }
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(copy, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        const Handle(BRepTools_ReShape) reshape = new BRepTools_ReShape();
        std::vector<TopoDS_Shape> sweeps;
        double wedge = 0;
        for (size_t k = 0; k < filletFaces.size(); ++k) {
            const TopoDS_Face &face = filletFaces[k];
            const GeomAbs_SurfaceType type = BRepAdaptor_Surface(face, Standard_False).GetType();
            FilletFaceEdges parts;
            if (!classifyFilletFace(face, edgeFaces, parts)) return TopoDS_Shape();
            TopoDS_Shape sweep;
            if (kinds[k] == G2Kind::Line) {
                if (type != GeomAbs_Cylinder || parts.ends.size() != 2 || !parts.seam.IsNull()) return TopoDS_Shape();
                TopoDS_Edge profiles[2];
                double triangle = 0;
                gp_Pnt centroid;
                gp_Vec normal;
                for (int i = 0; i < 2; ++i) {
                    if (BRepAdaptor_Surface(parts.ends[size_t(i)].support, Standard_False).GetType() != GeomAbs_Plane)
                        return TopoDS_Shape();
                    double area = 0;
                    gp_Pnt c;
                    gp_Vec n;
                    if (!g2Profile(parts.ends[size_t(i)].edge, rho, profiles[i], area, c, n)) return TopoDS_Shape();
                    if (i == 0) { triangle = area; centroid = c; normal = n; }
                }
                BRepAdaptor_Curve a(profiles[0]), b(profiles[1]);
                const gp_Pnt a0 = a.Value(a.FirstParameter()), a1 = a.Value(a.LastParameter());
                const gp_Pnt b0 = b.Value(b.FirstParameter()), b1 = b.Value(b.LastParameter());
                const gp_Vec shift = a0.Distance(b0) + a1.Distance(b1) <= a0.Distance(b1) + a1.Distance(b0)
                    ? gp_Vec(a0, b0) : gp_Vec(a0, b1);
                if (shift.Magnitude() < 1e-6) return TopoDS_Shape();
                // Das verschobene Profil A muss auf Profil B liegen (parallele Endflächen)
                double first = 0, last = 0;
                const Handle(Geom_Curve) other = BRep_Tool::Curve(profiles[1], first, last);
                if (other.IsNull()) return TopoDS_Shape();
                for (int i = 0; i <= 6; ++i) {
                    const gp_Pnt q = a.Value(a.FirstParameter() + (a.LastParameter() - a.FirstParameter()) * i / 6.0)
                        .Translated(shift);
                    GeomAPI_ProjectPointOnCurve projection(q, other, first, last);
                    if (projection.NbPoints() < 1 || projection.LowerDistance() > 1e-5) return TopoDS_Shape();
                }
                for (int i = 0; i < 2; ++i) {
                    reshape->Replace(TopoDS::Edge(parts.ends[size_t(i)].edge.Oriented(TopAbs_FORWARD)), profiles[i]);
                }
                BRepPrimAPI_MakePrism prism(profiles[0], shift);
                if (!prism.IsDone()) return TopoDS_Shape();
                sweep = prism.Shape();
                wedge += triangle * std::abs(shift.Dot(normal));
                (void)centroid;
            } else {
                if (type != GeomAbs_Torus || parts.seam.IsNull() || !parts.ends.empty()) return TopoDS_Shape();
                TopoDS_Edge profile;
                double triangle = 0;
                gp_Pnt centroid;
                gp_Vec normal;
                if (!g2Profile(parts.seam, rho, profile, triangle, centroid, normal)) return TopoDS_Shape();
                const gp_Ax1 axis = BRepAdaptor_Surface(face, Standard_False).Torus().Axis();
                BRepPrimAPI_MakeRevol revol(profile, axis, 2 * M_PI);
                if (!revol.IsDone()) return TopoDS_Shape();
                sweep = revol.Shape();
                // Pappus: Keilring = Dreiecksfläche · Weg ihres Schwerpunkts
                const double distance = gp_Vec(axis.Location(), centroid).Crossed(gp_Vec(axis.Direction())).Magnitude();
                wedge += triangle * 2 * M_PI * distance;
            }
            if (sweep.IsNull() || sweep.ShapeType() != TopAbs_FACE) return TopoDS_Shape();
            if (maxBoundaryAngle(TopoDS::Face(sweep), parts.tangent) > kMaxBoundaryAngle) return TopoDS_Shape();
            sweeps.push_back(sweep);
        }
        const TopoDS_Shape reshaped = reshape->Apply(copy);
        if (reshaped.IsNull()) return TopoDS_Shape();
        std::vector<TopoDS_Shape> removed;
        for (const auto &face : filletFaces) removed.push_back(reshape->Value(face));
        TopTools_IndexedMapOfShape faces;
        TopExp::MapShapes(reshaped, TopAbs_FACE, faces);
        std::vector<TopoDS_Shape> result;
        for (int i = 1; i <= faces.Extent(); ++i) {
            if (!containsSame(removed, faces(i))) result.push_back(faces(i));
        }
        if (result.size() + filletFaces.size() != size_t(faces.Extent())) return TopoDS_Shape();
        result.insert(result.end(), sweeps.begin(), sweeps.end());
        const TopoDS_Shape solid = finished(sewSolid(result), kMaxTolerance);
        if (solid.IsNull() || budget.exceeded()) return TopoDS_Shape();
        // Volumenplausibilität: gleiche Richtung wie die Kreisrundung, höchstens der Keil (r²/2·L bei 90°),
        // aber messbar anders als die Kreisrundung
        const double circle = sourceVolume - rolledVolume, smooth = sourceVolume - volumeOf(solid);
        if (!std::isfinite(circle) || !std::isfinite(smooth) || circle == 0 || smooth * circle <= 0) return TopoDS_Shape();
        if (std::abs(smooth) > wedge * 1.02 + 1e-6) return TopoDS_Shape();
        if (std::abs(smooth - circle) < 1e-9 * std::abs(sourceVolume)) return TopoDS_Shape();
        return solid;
    } catch (const Standard_Failure &) {
        return TopoDS_Shape();
    } catch (...) {
        return TopoDS_Shape();
    }
}

} // namespace pckblend
// END PCK_BLEND_OPTIONS_CORE

/// Welche Optionskombinationen der Kernel rechnet (H-A2). Standard immer; Setback nur mit G1/Kreis; G2 (Kreis-G2-
/// oder Kegelschnitt-Profil mit Rho) nur mit Rolling-Ball-Ecken; Overflow „Kante behalten“ nie.
static bool pckBlendOptionsSupported(PCKBlendOptions *options) {
    if (options == nil || !options.isValid) return false;
    if (options.isStandard) return true;
    if (options.overflow != PCKBlendOverflowAutomatic) return false;
    if (options.corner == PCKBlendCornerSetback) {
        return options.continuity == PCKBlendContinuityG1 && options.profile == PCKBlendProfileCircle;
    }
    return options.continuity == PCKBlendContinuityG2;
}

/// Nicht-Standard-Rundung: Ergebnis oder nil (Vertrag 1a). Endprüfungen: validSolid, Toleranzgrenze, Randwinkel und
/// Volumen (im C++-Teil), dann keine Originalkante übrig, vollständiges Netz (meshCompleteFillet) und
/// isValidBlendPreview gegen den Ausgangskörper.
static PCKShape *pckBlendWithOptions(PCKShape *source, NSArray<NSNumber *> *numbers,
                                     const std::vector<double> &requested, PCKBlendOptions *options) {
    if (!pckBlendOptionsSupported(options) || options.isStandard) return nil;
    if (numbers.count == 0 || numbers.count != requested.size()) return nil;
    const std::vector<TopoDS_Edge> all = edgesFromNumbers(source->_edges, numbers);
    if (all.size() != requested.size()) return nil;
    // Doppelt genannte Kanten zusammenfassen; widersprüchliche Radien sind ungültig
    std::vector<TopoDS_Edge> edges;
    std::vector<double> radii;
    for (size_t k = 0; k < all.size(); ++k) {
        const double radius = requested[k];
        if (!std::isfinite(radius) || radius <= 0 || radius > 1e6) return nil;
        bool known = false;
        for (size_t i = 0; i < edges.size(); ++i) {
            if (!edges[i].IsSame(all[k])) continue;
            if (radii[i] != radius) return nil;
            known = true;
        }
        if (!known) {
            edges.push_back(all[k]);
            radii.push_back(radius);
        }
    }
    try {
        const pckblend::Budget budget;
        TopoDS_Shape result;
        if (options.corner == PCKBlendCornerSetback) {
            result = pckblend::setbackBlend(source->_shape, edges, radii, options.setback, budget);
        } else {
            const double rho = options.profile == PCKBlendProfileConic ? options.rho : -1.0;
            result = pckblend::g2Blend(source->_shape, edges, radii, rho, budget);
        }
        if (result.IsNull()) return nil;
        const double smallest = *std::min_element(radii.begin(), radii.end());
        if (selectedEdgesRemain(edges, result, smallest)) return nil;
        PCKShape *candidate = [[[PCKShape alloc] initWithShape:result] meshCompleteFillet];
        if (candidate == nil || ![candidate isValidBlendPreviewFromShape:source]) return nil;
        return candidate;
    } catch (const Standard_Failure &) {
        return nil;
    } catch (...) {
        return nil;
    }
}

+ (BOOL)supportsBlendOptions:(PCKBlendOptions *)options {
    return pckBlendOptionsSupported(options) ? YES : NO;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius
                              options:(PCKBlendOptions *)options {
    if (!options.isValid) return nil;
    if (options.isStandard) return [self filletingEdges:numbers radius:radius];
    return pckBlendWithOptions(self, numbers, std::vector<double>(numbers.count, radius), options);
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radii:(NSArray<NSNumber *> *)radii
                              options:(PCKBlendOptions *)options {
    if (!options.isValid) return nil;
    if (options.isStandard) return [self filletingEdges:numbers radii:radii];
    if (numbers.count != radii.count) return nil;
    std::vector<double> values;
    for (NSNumber *radius in radii) values.push_back(radius.doubleValue);
    return pckBlendWithOptions(self, numbers, values, options);
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radii:(NSArray<NSNumber *> *)radii {
    if (numbers.count == 0 || numbers.count != radii.count) return nil;
    try {
        BRepFilletAPI_MakeFillet maker(_shape);
        for (NSUInteger k = 0; k < numbers.count; ++k) {
            const NSInteger index = numbers[k].integerValue;
            const double radius = radii[k].doubleValue;
            if (index < 1 || index > _edges.Extent() || !std::isfinite(radius) || radius <= 0) return nil;
            const TopoDS_Edge edge = TopoDS::Edge(_edges(int(index)));
            const int contour = maker.Contour(edge);
            if (contour > 0) maker.SetRadius(radius, contour, edge);
            else maker.Add(radius, edge);
            if (maker.Contour(edge) == 0) return nil;
        }
        maker.Build();
        if (!maker.IsDone() || maker.NbFaultyContours() > 0 || maker.Shape().IsNull()) return nil;
        const TopoDS_Shape checked = validSolid(maker.Shape());
        return checked.IsNull() ? nil : [[[PCKShape alloc] initWithShape:checked] meshCompleteFillet];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)partiallyFilletingEdge:(NSInteger)number radius:(double)radius start:(double)start end:(double)end {
    if (number < 1 || number > _edges.Extent() || radius <= 0 || start < 0 || end > 1 || end - start < 0.05) return nil;
    try {
        const TopoDS_Edge edge = TopoDS::Edge(_edges(int(number)));
        BRepAdaptor_Curve curve(edge);
        if (curve.GetType() != GeomAbs_Line && curve.GetType() != GeomAbs_Circle) return nil;
        if (curve.GetType() == GeomAbs_Circle && curve.LastParameter() - curve.FirstParameter() > M_PI + 1e-4) return nil;
        TopoDS_Shape rounded = blendEdges(_shape, {edge}, radius, false);
        if (rounded.IsNull()) rounded = extendedBoxFillet(_shape, edge, radius);
        if (rounded.IsNull() || !BRepCheck_Analyzer(rounded).IsValid()) return nil;
        if (start <= 1e-6 && end >= 1 - 1e-6) return [[[PCKShape alloc] initWithShape:rounded] meshCompleteFillet];
        BRepAlgoAPI_Cut removed(_shape, rounded);
        removed.Build();
        if (!removed.IsDone() || removed.Shape().IsNull()) return nil;
        TopoDS_Shape local = removed.Shape();
        const double first = curve.FirstParameter(), span = curve.LastParameter() - first;
        const gp_Pnt interior = curve.Value(first + (start + end) * 0.5 * span);
        for (double t : {start, end}) {
            const double parameter = first + t * span;
            const gp_Pnt point = curve.Value(parameter);
            const gp_Dir tangent(curve.DN(parameter, 1));
            const TopoDS_Face plane = BRepBuilderAPI_MakeFace(gp_Pln(point, tangent), -1e5, 1e5, -1e5, 1e5).Face();
            BRepPrimAPI_MakeHalfSpace half(plane, interior);
            BRepAlgoAPI_Common clipped(local, half.Solid());
            clipped.Build();
            if (!clipped.IsDone() || clipped.Shape().IsNull()) return nil;
            local = clipped.Shape();
        }
        BRepAlgoAPI_Cut cut(_shape, local);
        cut.Build();
        if (!cut.IsDone() || cut.Shape().IsNull()) return nil;
        const TopoDS_Shape result = cut.Shape();
        if (!BRepCheck_Analyzer(result).IsValid()) return nil;
        int solids = 0;
        for (TopExp_Explorer it(result, TopAbs_SOLID); it.More(); it.Next()) ++solids;
        if (solids != 1) return nil;
        GProp_GProps originalProps, fullProps, partProps;
        BRepGProp::VolumeProperties(_shape, originalProps);
        BRepGProp::VolumeProperties(rounded, fullProps);
        BRepGProp::VolumeProperties(result, partProps);
        if (partProps.Mass() <= fullProps.Mass() + 1e-6 || partProps.Mass() >= originalProps.Mass() - 1e-6) return nil;
        PCKShape *candidate = [[PCKShape alloc] initWithShape:result];
        return candidate.isClosedSolid ? [candidate meshCompleteFillet] : nil;
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)numbers distance:(double)distance {
    const TopoDS_Shape result = blendEdges(_shape, edgesFromNumbers(_edges, numbers), distance, true);
    // N6: wie bei Rundungen eine fehlende Triangulation reparieren statt den Körper abzulehnen
    return result.IsNull() ? nil : [[[PCKShape alloc] initWithShape:result] meshCompleteFillet];
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)numbers distance:(double)distance
                             distance2:(double)distance2 {
    if (std::abs(distance - distance2) < 1e-9) return [self chamferingEdges:numbers distance:distance];
    if (!std::isfinite(distance) || !std::isfinite(distance2) || distance <= 0 || distance2 <= 0) return nil;
    try {
        // Zwei Abstände: distance auf der ersten Nachbarfläche der Kante, distance2 auf der anderen
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        BRepFilletAPI_MakeChamfer chamfer(_shape);
        int added = 0;
        const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
        if (edges.size() != numbers.count) return nil;
        for (const auto &edge : edges) {
            if (!edgeFaces.Contains(edge) || edgeFaces.FindFromKey(edge).IsEmpty()) return nil;
            chamfer.Add(distance, distance2, edge, TopoDS::Face(edgeFaces.FindFromKey(edge).First()));
            if (chamfer.Contour(edge) == 0) return nil;
            added += 1;
        }
        if (added == 0) return nil;
        chamfer.Build();
        if (!chamfer.IsDone() || chamfer.Shape().IsNull()) return nil;
        const TopoDS_Shape checked = validSolid(chamfer.Shape());
        // Schwacher Bugfix 2: keine gewählte Kante darf unverändert im Ergebnis liegen (kein NbFaultyContours)
        if (checked.IsNull() || selectedEdgesRemain(edges, checked, std::min(distance, distance2))) return nil;
        return [[[PCKShape alloc] initWithShape:checked] meshCompleteFillet];
    } catch (...) {
        return nil;
    }
}

- (NSArray<NSNumber *> *)unblendableEdges:(NSArray<NSNumber *> *)numbers value:(double)value chamfer:(BOOL)chamfer {
    // Diagnose, kein Filter: je Kante ein eigener Builder, nur Add (kein Build – das ist der teure, absturzgefährdete
    // Teil). Contour == 0 heißt: OCCT nimmt die Kante gar nicht an (Naht, tangentialer Übergang, freie Kante).
    NSMutableArray<NSNumber *> *bad = [NSMutableArray array];
    const double amount = std::isfinite(value) && value > 0 ? value : 1.0;
    for (NSNumber *number in numbers) {
        const NSInteger index = number.integerValue;
        if (index < 1 || index > _edges.Extent()) {
            [bad addObject:number];
            continue;
        }
        bool usable = false;
        try {
            const TopoDS_Edge edge = TopoDS::Edge(_edges(int(index)));
            if (chamfer) {
                BRepFilletAPI_MakeChamfer maker(_shape);
                maker.Add(amount, edge);
                usable = maker.Contour(edge) != 0;
            } else {
                BRepFilletAPI_MakeFillet maker(_shape);
                maker.Add(amount, edge);
                usable = maker.Contour(edge) != 0;
            }
        } catch (...) {
            usable = false;
        }
        if (!usable) [bad addObject:number];
    }
    return bad;
}

/// Ein Durchgang variable Rundung; leere Form bei Fehler.
static TopoDS_Shape variableFilletOnce(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges, double r1,
                                       double r2) {
    if (shape.IsNull() || edges.empty() || !std::isfinite(r1) || !std::isfinite(r2) || r1 <= 0 || r2 <= 0)
        return TopoDS_Shape();
    try {
        BRepFilletAPI_MakeFillet maker(shape);
        for (const auto &edge : edges) {
            maker.Add(r1, r2, edge);
            if (maker.Contour(edge) == 0) return TopoDS_Shape();
        }
        maker.Build();
        if (maker.IsDone() && maker.NbFaultyContours() == 0 && !maker.Shape().IsNull()) return validSolid(maker.Shape());
    } catch (...) {
    }
    return TopoDS_Shape();
}

- (nullable PCKShape *)independentCopy {
    return [self independentCopyWithMesh:NO];
}

- (nullable NSData *)brepData {
    try {
        std::ostringstream stream(std::ios::binary);
        BRepTools::Write(_shape, stream, false, false, TopTools_FormatVersion_CURRENT);
        const std::string bytes = stream.str();
        return bytes.empty() ? nil : [NSData dataWithBytes:bytes.data() length:bytes.size()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)shapeFromBRepData:(NSData *)data {
    if (data.length == 0 || data.length > 100 * 1024 * 1024) return nil;
    try {
        const std::string bytes(static_cast<const char *>(data.bytes), data.length);
        std::istringstream stream(bytes, std::ios::binary);
        BRep_Builder builder;
        TopoDS_Shape shape;
        BRepTools::Read(shape, stream, builder);
        return shape.IsNull() ? nil : [[PCKShape alloc] initWithShape:shape];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)independentCopyKeepingMesh {
    return [self independentCopyWithMesh:YES];
}

- (nullable PCKShape *)independentCopyWithMesh:(BOOL)withMesh {
    try {
        // Geometrie mitkopieren (auf Wunsch auch das Netz als eigene Kopie): die Kopie teilt nichts mehr mit diesem
        // Körper (Vernetzen im Vordergrund schreibt sonst gleichzeitig in dieselben Flächen und Kanten, während der
        // Hintergrund rechnet)
        BRepBuilderAPI_Copy copier(_shape, Standard_True, withMesh ? Standard_True : Standard_False);
        const TopoDS_Shape copied = copier.Shape();
        if (copied.IsNull()) return nil;
        PCKShape *copy = [[PCKShape alloc] initWithShape:copied];
        if (copy->_edges.Extent() != _edges.Extent() || copy->_faces.Extent() != _faces.Extent()) return nil;
        // Nummern müssen übereinstimmen (Kante i der Kopie = Kopie der Kante i)
        for (int i = 1; i <= _edges.Extent(); ++i) {
            if (!copier.ModifiedShape(_edges(i)).IsSame(copy->_edges(i))) return nil;
        }
        for (int i = 1; i <= _faces.Extent(); ++i) {
            if (!copier.ModifiedShape(_faces(i)).IsSame(copy->_faces(i))) return nil;
        }
        return copy;
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius endRadius:(double)endRadius {
    if (radius <= 0 || endRadius <= 0) return nil;
    if (std::abs(radius - endRadius) < 1e-9) return [self filletingEdges:numbers radius:radius];
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty()) return nil;
    const double smaller = std::min(radius, endRadius);
    TopoDS_Shape result = variableFilletOnce(_shape, edges, radius, endRadius);
    if (!result.IsNull() && selectedEdgesRemain(edges, result, smaller)) result = TopoDS_Shape();
    if (result.IsNull()) {
        // Wie blendEdges: zerteilte Flächen und Kanten erst zusammenfassen. Jede gewählte Kante braucht einen
        // Treffer, und die Endprüfung läuft gegen die ursprünglich gewählten Kanten (Schwacher Bugfix 1)
        try {
            const TopoDS_Shape merged = unified(_shape);
            const std::vector<TopoDS_Edge> mergedEdges = matchEveryEdge(edges, merged);
            if (!mergedEdges.empty()) result = variableFilletOnce(merged, mergedEdges, radius, endRadius);
            if (!result.IsNull() && selectedEdgesRemain(edges, result, smaller)) result = TopoDS_Shape();
        } catch (...) {
            result = TopoDS_Shape();
        }
    }
    // N6: fehlende Triangulation wie bei der konstanten Rundung reparieren
    return result.IsNull() ? nil : [[[PCKShape alloc] initWithShape:result] meshCompleteFillet];
}

- (nullable PCKShape *)sweepProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires alongEdges:(NSArray<NSNumber *> *)numbers {
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty() || wires.count == 0) return nil;
    try {
        // Kanten in beliebiger Reihenfolge zu einem Pfad verbinden (sie müssen zusammenhängen)
        TopTools_ListOfShape list;
        for (const auto &edge : edges) list.Append(edge);
        BRepBuilderAPI_MakeWire spineMaker;
        spineMaker.Add(list);
        if (!spineMaker.IsDone()) return nil;
        const TopoDS_Wire spine = spineMaker.Wire();
        const TopoDS_Wire outer = wireFromCode(toVector(wires[0]));
        if (outer.IsNull()) return nil;
        // Profil an der Pfadecke ansetzen, die ihm am nächsten liegt (wie SketchUp „Folge mir“)
        GProp_GProps props;
        BRepGProp::LinearProperties(outer, props);
        const gp_Pnt center = props.CentreOfMass();
        TopoDS_Vertex nearest;
        double best = 1e300;
        for (TopExp_Explorer it(spine, TopAbs_VERTEX); it.More(); it.Next()) {
            const TopoDS_Vertex vertex = TopoDS::Vertex(it.Current());
            const double d = BRep_Tool::Pnt(vertex).Distance(center);
            if (d < best) {
                best = d;
                nearest = vertex;
            }
        }
        auto sweepWire = [&](const TopoDS_Wire &profile) -> TopoDS_Shape {
            for (int attempt = 0; attempt < 2; ++attempt) {
                try {
                    BRepOffsetAPI_MakePipeShell pipe(spine);
                    // Ecken auf Gehrung statt verdreht
                    pipe.SetTransitionMode(BRepBuilderAPI_RightCorner);
                    if (attempt == 0 && !nearest.IsNull()) {
                        pipe.Add(profile, nearest, Standard_False, Standard_False);
                    } else {
                        pipe.Add(profile, Standard_False, Standard_False);
                    }
                    pipe.Build();
                    if (pipe.IsDone() && pipe.MakeSolid() && !pipe.Shape().IsNull()) return pipe.Shape();
                } catch (...) {
                }
            }
            return TopoDS_Shape();
        };
        TopoDS_Shape result = sweepWire(outer);
        if (result.IsNull()) {
            // Rückfall wie der Skizzen-Sweep (ganze Fläche, ohne Gehrung)
            const TopoDS_Face face = faceFromWires(wires);
            if (face.IsNull()) return nil;
            BRepOffsetAPI_MakePipe pipe(spine, face);
            pipe.Build();
            if (!pipe.IsDone()) return nil;
            const TopoDS_Shape checkedPipe = checkedResult(pipe.Shape());
            return checkedPipe.IsNull() ? nil : [[PCKShape alloc] initWithShape:checkedPipe];
        }
        for (NSUInteger k = 1; k < wires.count; ++k) {
            const TopoDS_Wire hole = wireFromCode(toVector(wires[k]));
            if (hole.IsNull()) continue;
            const TopoDS_Shape tool = sweepWire(hole);
            if (tool.IsNull()) return nil;
            BRepAlgoAPI_Cut cut(result, tool);
            if (!cut.IsDone()) return nil;
            result = cut.Shape();
        }
        // B7: Sweep entlang Körperkanten (Gehrung, Löcher abgezogen) prüfen
        const TopoDS_Shape checked = checkedResult(result);
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)draftingFaces:(NSArray<NSNumber *> *)faces pull:(simd_double3)pull
                       neutralOrigin:(simd_double3)neutralOrigin angle:(double)degrees {
    if (faces.count == 0 || !validDir(pull) || std::abs(degrees) < 1e-9 || std::abs(degrees) >= 89) return nil;
    try {
        const gp_Dir direction = toDir(pull);
        const gp_Pln neutral(toPnt(neutralOrigin), direction);
        BRepOffsetAPI_DraftAngle draft(_shape);
        for (NSNumber *number in faces) {
            if (number.integerValue < 1 || number.integerValue > _faces.Extent()) return nil;
            draft.Add(TopoDS::Face(_faces(number.intValue)), direction, degrees * M_PI / 180.0, neutral);
            if (!draft.AddDone()) return nil;
        }
        draft.Build();
        if (!draft.IsDone() || draft.Shape().IsNull()) return nil;
        // B7: Formschräge prüfen (geneigte Flächen können sich mit Nachbarn überschneiden)
        const TopoDS_Shape checked = checkedResult(draft.Shape());
        return checked.IsNull() ? nil : [[PCKShape alloc] initWithShape:checked];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)handleOfEdge:(NSInteger)index {
    if (index < 1 || index > _edges.Extent()) return nil;
    try {
        const TopoDS_Edge edge = TopoDS::Edge(_edges(int(index)));
        if (BRep_Tool::Degenerated(edge)) return nil;
        double first = 0, last = 0;
        BRep_Tool::Range(edge, first, last);
        const double mid = 0.5 * (first + last);
        const gp_Pnt point = BRepAdaptor_Curve(edge).Value(mid);

        // Summe der Flächennormalen an der Kantenmitte; die Gegenrichtung zeigt ins Material.
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        gp_Vec sum(0, 0, 0);
        const int key = edgeFaces.FindIndex(edge);
        if (key > 0) {
            TopTools_IndexedMapOfShape seen;
            for (TopTools_ListOfShape::Iterator it(edgeFaces(key)); it.More(); it.Next()) {
                const TopoDS_Face face = TopoDS::Face(it.Value());
                if (seen.Contains(face)) continue;
                seen.Add(face);
                double f = 0, l = 0;
                Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, f, l);
                if (pcurve.IsNull()) continue;
                const gp_Pnt2d uv = pcurve->Value(mid);
                BRepGProp_Face props(face);
                gp_Pnt onFace;
                gp_Vec normal;
                props.Normal(uv.X(), uv.Y(), onFace, normal);
                if (normal.Magnitude() > 1e-12) sum += normal.Normalized();
            }
        }
        gp_Vec direction = -sum;
        if (direction.Magnitude() < 1e-9) direction = gp_Vec(0, 0, -1);
        direction.Normalize();
        return @[@(point.X()), @(point.Y()), @(point.Z()), @(direction.X()), @(direction.Y()), @(direction.Z())];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)blendOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    try {
        const TopoDS_Face face = TopoDS::Face(_faces(int(index)));
        BRepAdaptor_Surface surface(face);
        switch (surface.GetType()) {
        case GeomAbs_Cylinder:
            return @[@1, @(surface.Cylinder().Radius())];
        case GeomAbs_Torus:
            return @[@1, @(surface.Torus().MinorRadius())];
        case GeomAbs_Plane:
            break;
        default:
            return nil;
        }
        // Fase: schmaler ebener Streifen zwischen zwei langen parallelen Geraden, an denen ebene Nachbarflächen
        // schräg (weder fluchtend noch senkrecht) anschließen
        const gp_Dir normal = surface.Plane().Axis().Direction();
        std::vector<std::pair<double, TopoDS_Edge>> lines;
        for (TopExp_Explorer it(face, TopAbs_EDGE); it.More(); it.Next()) {
            const TopoDS_Edge edge = TopoDS::Edge(it.Current());
            if (BRepAdaptor_Curve(edge).GetType() != GeomAbs_Line) continue;
            GProp_GProps props;
            BRepGProp::LinearProperties(edge, props);
            lines.push_back(std::make_pair(props.Mass(), edge));
        }
        if (lines.size() < 2) return nil;
        std::sort(lines.begin(), lines.end(),
                  [](const std::pair<double, TopoDS_Edge> &a, const std::pair<double, TopoDS_Edge> &b) {
                      return a.first > b.first;
                  });
        const TopoDS_Edge longEdges[2] = {lines[0].second, lines[1].second};
        const gp_Lin first = BRepAdaptor_Curve(longEdges[0]).Line();
        const gp_Lin second = BRepAdaptor_Curve(longEdges[1]).Line();
        if (std::abs(first.Direction().Dot(second.Direction())) < 0.999) return nil;
        const double width = first.Distance(second.Location());
        if (width < 1e-6 || width >= lines[1].first) return nil;

        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        double tilt[2] = {0, 0};
        for (int k = 0; k < 2; ++k) {
            const int key = edgeFaces.FindIndex(longEdges[k]);
            if (key < 1) return nil;
            bool found = false;
            for (TopTools_ListOfShape::Iterator it(edgeFaces(key)); it.More(); it.Next()) {
                const TopoDS_Face other = TopoDS::Face(it.Value());
                if (other.IsSame(face)) continue;
                BRepAdaptor_Surface neighbour(other);
                if (neighbour.GetType() != GeomAbs_Plane) return nil;
                const double cosine = std::min(1.0, std::abs(neighbour.Plane().Axis().Direction().Dot(normal)));
                tilt[k] = std::acos(cosine);
                found = true;
                break;
            }
            if (!found) return nil;
        }
        const double minimum = 5.0 * M_PI / 180, maximum = 85.0 * M_PI / 180;
        for (double angle : tilt) {
            if (angle < minimum || angle > maximum) return nil;
        }
        // Gleichschenklige Fase: Winkel der Nachbarflächen α = π − (Neigung 1 + Neigung 2), Breite = 2 d sin(α/2)
        const double alpha = M_PI - (tilt[0] + tilt[1]);
        if (alpha < 1e-3) return nil;
        return @[@2, @(width / (2 * std::sin(alpha / 2)))];
    } catch (...) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    const TopoDS_Face face = TopoDS::Face(_faces(int(index)));
    TopLoc_Location surfaceLocation;
    if (BRep_Tool::Surface(face, surfaceLocation).IsNull()) return nil;
    gp_Pln plane;
    try {
        BRepAdaptor_Surface surface(face);
        if (surface.GetType() != GeomAbs_Plane) return nil;
        plane = surface.Plane();
    } catch (...) {
        return nil;
    }
    gp_Dir normal = plane.Axis().Direction();
    if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
    // Nach Fase/Abrunden kann die gespeicherte Ausrichtung der Fläche umgedreht sein: prüfen, auf welcher
    // Seite der Körper liegt, damit die Normale sicher nach außen zeigt (Pfeil und Extrudieren nach außen).
    try {
        GProp_GProps props;
        BRepGProp::SurfaceProperties(face, props);
        const gp_Pnt center = props.CentreOfMass();
        const double eps = 0.02;
        const gp_Pnt outside(center.X() + normal.X() * eps, center.Y() + normal.Y() * eps, center.Z() + normal.Z() * eps);
        const gp_Pnt inside(center.X() - normal.X() * eps, center.Y() - normal.Y() * eps, center.Z() - normal.Z() * eps);
        BRepClass3d_SolidClassifier atOutside(_shape, outside, 1e-6);
        BRepClass3d_SolidClassifier atInside(_shape, inside, 1e-6);
        if (atOutside.State() == TopAbs_IN && atInside.State() == TopAbs_OUT) normal.Reverse();
    } catch (...) {
    }
    const gp_Pnt origin = plane.Location();
    return @[@(origin.X()), @(origin.Y()), @(origin.Z()), @(normal.X()), @(normal.Y()), @(normal.Z())];
}

- (nullable NSArray<NSNumber *> *)surfacePointOfFace:(NSInteger)index near:(simd_double3)point {
    if (index < 1 || index > _faces.Extent()) return nil;
    try {
        const TopoDS_Face face = TopoDS::Face(_faces(int(index)));
        const Handle(Geom_Surface) geometry = BRep_Tool::Surface(face);
        if (geometry.IsNull()) return nil;
        // UV des nächsten Flächenpunkts (Lage der Fläche ist in geometry schon enthalten)
        ShapeAnalysis_Surface analysis(geometry);
        const gp_Pnt2d uv = analysis.ValueOfUV(gp_Pnt(point.x, point.y, point.z), 1e-6);
        BRepAdaptor_Surface surface(face);
        double u = uv.X();
        double v = uv.Y();
        gp_Pnt p;
        gp_Vec du;
        gp_Vec dv;
        surface.D1(u, v, p, du, dv);
        gp_Vec n = du.Crossed(dv);
        if (n.Magnitude() < 1e-12) {
            // Entartete Stelle (Kugelpol, Kegelspitze): ein Stück zur Mitte des Parameterbereichs rücken
            const double um = 0.5 * (surface.FirstUParameter() + surface.LastUParameter());
            const double vm = 0.5 * (surface.FirstVParameter() + surface.LastVParameter());
            u += 1e-3 * (um - u);
            v += 1e-3 * (vm - v);
            surface.D1(u, v, p, du, dv);
            n = du.Crossed(dv);
            if (n.Magnitude() < 1e-12) return nil;
        }
        gp_Dir normal(n);
        if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
        // Wie planeOfFace: prüfen, auf welcher Seite der Körper liegt, damit die Normale sicher nach außen zeigt
        try {
            const double eps = 0.02;
            const gp_Pnt outside(p.X() + normal.X() * eps, p.Y() + normal.Y() * eps, p.Z() + normal.Z() * eps);
            const gp_Pnt inside(p.X() - normal.X() * eps, p.Y() - normal.Y() * eps, p.Z() - normal.Z() * eps);
            BRepClass3d_SolidClassifier atOutside(_shape, outside, 1e-6);
            BRepClass3d_SolidClassifier atInside(_shape, inside, 1e-6);
            if (atOutside.State() == TopAbs_IN && atInside.State() == TopAbs_OUT) normal.Reverse();
        } catch (...) {
        }
        return @[@(p.X()), @(p.Y()), @(p.Z()), @(normal.X()), @(normal.Y()), @(normal.Z())];
    } catch (const Standard_Failure &) {
        return nil;
    } catch (...) {
        return nil;
    }
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    @synchronized (self) {
        if (_cachedMesh != nil && _cachedDeflection == deflection) return _cachedMesh;
    }
    PCKMesh *mesh = [self computeMeshWithDeflection:deflection];
    @synchronized (self) {
        _cachedMesh = mesh;
        _cachedDeflection = deflection;
    }
    return mesh;
}

/// Kante zwischen zwei fast gleich geneigten ebenen Flächen, von denen mindestens eine ein Dreieck ist (Facetten
/// eines Netzkörpers aus STL/3MF): wird nicht als Linie gezeichnet, sonst erscheint das Netz als Drahtgitter.
static bool isSoftMeshEdge(const TopTools_ListOfShape &faces) {
    if (faces.Extent() != 2) return false;
    if (faces.First().ShapeType() != TopAbs_FACE || faces.Last().ShapeType() != TopAbs_FACE) return false;
    const TopoDS_Face both[2] = {TopoDS::Face(faces.First()), TopoDS::Face(faces.Last())};
    if (both[0].IsSame(both[1])) return false;
    gp_Dir normals[2];
    int triangles = 0;
    for (int k = 0; k < 2; ++k) {
        BRepAdaptor_Surface surface(both[k], Standard_False);
        if (surface.GetType() != GeomAbs_Plane) return false;
        gp_Dir normal = surface.Plane().Axis().Direction();
        if (both[k].Orientation() == TopAbs_REVERSED) normal.Reverse();
        normals[k] = normal;
        TopTools_IndexedMapOfShape edges;
        TopExp::MapShapes(both[k], TopAbs_EDGE, edges);
        if (edges.Extent() <= 3) ++triangles;
    }
    return triangles > 0 && normals[0].Angle(normals[1]) < 25.0 * M_PI / 180.0;
}

- (PCKMesh *)computeMeshWithDeflection:(double)deflection {
    MeshBuffers buffers;
    // Fehler im Vernetzer dürfen die App nicht beenden: dann eben ohne bzw. mit weniger Dreiecken
    try {
        // Engere Winkelabweichung: runde Flächen in der Vorschau sichtbar glatter.
        BRepTools::Clean(_shape);
        BRepMesh_IncrementalMesh mesher(_shape, deflection, Standard_False, 0.10, Standard_True);
    } catch (...) {
    }

    for (int f = 1; f <= _faces.Extent(); ++f) {
      // Stand vor der Fläche: schlägt sie mittendrin fehl, wird sie ganz zurückgenommen, damit Dreiecke,
      // Flächennummern und Punkte zusammenpassen (sonst greift die App über das Punktfeld hinaus)
      const size_t vertexMark = buffers.vertices.size(), indexMark = buffers.indices.size();
      const size_t faceMark = buffers.triangleFaces.size();
      try {
        const TopoDS_Face face = TopoDS::Face(_faces(f));
        TopLoc_Location location;
        Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
        if (triangulation.IsNull()) continue;

        BRepLib_ToolTriangulatedShape::ComputeNormals(face, triangulation);
        const gp_Trsf transform = location.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const uint32_t base = static_cast<uint32_t>(buffers.vertices.size() / 6);

        // Ohne Normalen liest Normal(i) außerhalb des Felds (im Release-Kernel ungeprüft): dann Flächennormale
        const bool hasNormals = triangulation->HasNormals();
        for (int i = 1; i <= triangulation->NbNodes(); ++i) {
            const gp_Pnt p = triangulation->Node(i).Transformed(transform);
            gp_Dir n = hasNormals ? triangulation->Normal(i) : gp_Dir(0, 0, 1);
            n.Transform(transform);
            if (reversed) n.Reverse();
            buffers.addVertex(simd_make_double3(p.X(), p.Y(), p.Z()), simd_make_double3(n.X(), n.Y(), n.Z()));
        }
        const int nodes = triangulation->NbNodes();
        for (int i = 1; i <= triangulation->NbTriangles(); ++i) {
            int a, b, c;
            triangulation->Triangle(i).Get(a, b, c);
            if (a < 1 || b < 1 || c < 1 || a > nodes || b > nodes || c > nodes) continue;
            if (reversed) std::swap(b, c);
            buffers.addTriangle(base + a - 1, base + b - 1, base + c - 1, uint32_t(f));
        }
      } catch (...) {
        buffers.vertices.resize(vertexMark);
        buffers.indices.resize(indexMark);
        buffers.triangleFaces.resize(faceMark);
        continue;
      }
    }

    // Kanten als Polylinien, Nahtkanten weglassen
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    try {
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    } catch (...) {
        return [[PCKMesh alloc] initWithBuffers:buffers];
    }
    for (int i = 1; i <= edgeFaces.Extent(); ++i) {
        try {
            const TopoDS_Shape &key = edgeFaces.FindKey(i);
            if (key.IsNull() || key.ShapeType() != TopAbs_EDGE) continue;
            const TopoDS_Edge edge = TopoDS::Edge(key);
            if (BRep_Tool::Degenerated(edge)) continue;
            bool seam = false;
            for (TopTools_ListOfShape::Iterator it(edgeFaces(i)); it.More(); it.Next()) {
                if (it.Value().ShapeType() == TopAbs_FACE && BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) seam = true;
            }
            if (seam) continue;
            if (isSoftMeshEdge(edgeFaces(i))) continue;
            // Kante ohne 3D-Kurve und ohne Kurve auf einer Fläche: BRepAdaptor_Curve griffe auf ein leeres Handle zu
            if (!BRep_Tool::IsGeometric(edge)) continue;
            BRepAdaptor_Curve curve(edge);
            // Sichtbare Kanten feiner abtasten, passend zum Oberflächennetz.
            GCPnts_TangentialDeflection points(curve, 0.08, deflection);
            const uint32_t number = uint32_t(_edges.FindIndex(edge));
            for (int k = 1; k < points.NbPoints(); ++k) {
                const gp_Pnt a = points.Value(k), b = points.Value(k + 1);
                buffers.addEdge(simd_make_double3(a.X(), a.Y(), a.Z()), simd_make_double3(b.X(), b.Y(), b.Z()),
                                number);
            }
        } catch (...) {
            continue;
        }
    }
    return [[PCKMesh alloc] initWithBuffers:buffers];
}

// MARK: Netze (STL/3MF) als Körper

- (BOOL)isClosedSolid {
    try {
        bool any = false;
        for (TopExp_Explorer solids(_shape, TopAbs_SOLID); solids.More(); solids.Next()) {
            for (TopExp_Explorer shells(solids.Current(), TopAbs_SHELL); shells.More(); shells.Next()) {
                if (!BRep_Tool::IsClosed(shells.Current())) return NO;
                any = true;
            }
        }
        return any;
    } catch (...) {
        return NO;
    }
}

- (BOOL)isBRepValid {
    try {
        return !_shape.IsNull() && BRepCheck_Analyzer(_shape).IsValid();
    } catch (...) {
        return NO;
    }
}

- (BOOL)isValidBlendPreviewFromShape:(PCKShape *)source {
    if (!self.isBRepValid || !self.isClosedSolid) return NO;
    NSArray<NSNumber *> *before = source.boundingBox, *after = self.boundingBox;
    if (before.count != 6 || after.count != 6) return NO;
    double extent = 0;
    for (int axis = 0; axis < 3; ++axis) {
        const double low = before[axis].doubleValue, high = before[axis + 3].doubleValue;
        if (!std::isfinite(low) || !std::isfinite(high) || high < low) return NO;
        extent = std::max(extent, high - low);
    }
    const double tolerance = std::max(0.05, extent * 1e-4);
    for (int axis = 0; axis < 3; ++axis) {
        const double low = after[axis].doubleValue, high = after[axis + 3].doubleValue;
        if (!std::isfinite(low) || !std::isfinite(high)
            || low < before[axis].doubleValue - tolerance
            || high > before[axis + 3].doubleValue + tolerance) return NO;
    }
    PCKMesh *mesh = [self triangulateWithDeflection:0.05];
    const NSUInteger vertexBytes = 6 * sizeof(float), triangleBytes = 3 * sizeof(uint32_t);
    if (mesh.vertexData.length == 0 || mesh.vertexData.length % vertexBytes != 0
        || mesh.indexData.length == 0 || mesh.indexData.length % triangleBytes != 0
        || mesh.faceIndexData.length != mesh.indexData.length / 3) return NO;
    const NSUInteger vertexCount = mesh.vertexData.length / vertexBytes;
    const float *vertices = static_cast<const float *>(mesh.vertexData.bytes);
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        for (int axis = 0; axis < 6; ++axis) {
            const double value = vertices[i * 6 + axis];
            if (!std::isfinite(value)) return NO;
            if (axis < 3 && (value < before[axis].doubleValue - tolerance
                             || value > before[axis + 3].doubleValue + tolerance)) return NO;
        }
    }
    const uint32_t *indices = static_cast<const uint32_t *>(mesh.indexData.bytes);
    for (NSUInteger i = 0; i < mesh.indexData.length / sizeof(uint32_t); ++i) {
        if (indices[i] >= vertexCount) return NO;
    }
    std::vector<bool> present(size_t(_faces.Extent()) + 1, false);
    const uint32_t *faces = static_cast<const uint32_t *>(mesh.faceIndexData.bytes);
    for (NSUInteger i = 0; i < mesh.faceIndexData.length / sizeof(uint32_t); ++i) {
        if (faces[i] == 0 || faces[i] >= present.size()) return NO;
        present[faces[i]] = true;
    }
    for (int face = 1; face <= _faces.Extent(); ++face) {
        if (!present[size_t(face)] && [self areaOfFace:face] > 1e-6) return NO;
    }
    return YES;
}

- (BOOL)hasPlausibleSingleEdgeFilletVolumeFromShape:(PCKShape *)source edge:(NSInteger)index radius:(double)radius {
    if (!source || !std::isfinite(radius) || radius <= 0 || index < 1 || index > source->_edges.Extent()) return NO;
    try {
        const TopoDS_Edge edge = TopoDS::Edge(source->_edges(int(index)));
        if (BRep_Tool::Degenerated(edge) || BRepAdaptor_Curve(edge).GetType() != GeomAbs_Line) return YES;
        TopTools_IndexedDataMapOfShapeListOfShape adjacent;
        TopExp::MapShapesAndAncestors(source->_shape, TopAbs_EDGE, TopAbs_FACE, adjacent);
        const int edgeIndex = adjacent.FindIndex(edge);
        if (edgeIndex < 1 || adjacent(edgeIndex).Extent() != 2) return YES;
        gp_Dir normals[2];
        int side = 0;
        for (TopTools_ListOfShape::Iterator it(adjacent(edgeIndex)); it.More(); it.Next()) {
            BRepAdaptor_Surface surface(TopoDS::Face(it.Value()), Standard_False);
            if (surface.GetType() != GeomAbs_Plane) return YES;
            normals[side++] = surface.Plane().Axis().Direction();
        }
        if (std::abs(normals[0].Dot(normals[1])) > 1e-5) return YES;
        // Eine tangential fortgesetzte Kante kann mehr Material ändern als dieser Einzelkantenkeil.
        if ([source tangentEdgeNumbersStartingAtEdge:index].count != 1) return YES;
        const double length = [source lengthOfEdge:index];
        if (!std::isfinite(length) || length < 1e-6) return YES;
        const double before = source.volume, after = self.volume;
        if (!std::isfinite(before) || !std::isfinite(after) || before <= 0 || after <= 0) return NO;
        // Rechtwinkliger Setback-Keil (r²/2) mit je einem Radius Reserve an beiden Enden.
        const double bound = 0.5 * radius * radius * (length + 2 * radius);
        if (!std::isfinite(bound)) return YES;
        return std::abs(before - after) <= bound * 1.02 + before * 1e-4 + 1e-6;
    } catch (...) {
        return YES; // Unklare Geometrie bleibt bei der bestehenden BRep-/Mesh-Prüfung.
    }
}

+ (nullable PCKShape *)solidFromMeshPoints:(NSData *)points triangles:(NSData *)triangles tolerance:(double)tolerance {
    const size_t pointCount = points.length / (3 * sizeof(double));
    const size_t triangleCount = triangles.length / (3 * sizeof(uint32_t));
    if (pointCount < 3 || triangleCount < 1) return nil;
    const double *xyz = static_cast<const double *>(points.bytes);
    const uint32_t *corners = static_cast<const uint32_t *>(triangles.bytes);
    const double tol = std::max(tolerance, Precision::Confusion());
    try {
        BRep_Builder builder;
        // Gemeinsame Punkte und Kanten: jede Netzkante wird genau eine Kante, die sich beide Dreiecke teilen.
        // So entsteht die Schale ohne langsames Vernähen (Sewing).
        std::vector<TopoDS_Vertex> vertices(pointCount);
        std::vector<std::vector<std::pair<uint32_t, size_t>>> edgesFrom(pointCount);
        std::vector<TopoDS_Edge> edges;
        auto point = [&](uint32_t i) { return gp_Pnt(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]); };
        auto vertexAt = [&](uint32_t i) -> TopoDS_Vertex {
            if (vertices[i].IsNull()) builder.MakeVertex(vertices[i], point(i), tol);
            return vertices[i];
        };
        auto edgeBetween = [&](uint32_t a, uint32_t b) -> TopoDS_Edge {
            const uint32_t low = std::min(a, b), high = std::max(a, b);
            for (const auto &entry : edgesFrom[low]) {
                if (entry.first == high) {
                    const TopoDS_Edge &edge = edges[entry.second];
                    return a == low ? edge : TopoDS::Edge(edge.Reversed());
                }
            }
            const TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(vertexAt(low), vertexAt(high)).Edge();
            edgesFrom[low].push_back(std::make_pair(high, edges.size()));
            edges.push_back(edge);
            return a == low ? edge : TopoDS::Edge(edge.Reversed());
        };

        TopoDS_Shell shell;
        builder.MakeShell(shell);
        size_t faceCount = 0;
        for (size_t t = 0; t < triangleCount; ++t) {
            const uint32_t a = corners[3 * t], b = corners[3 * t + 1], c = corners[3 * t + 2];
            if (a >= pointCount || b >= pointCount || c >= pointCount || a == b || b == c || a == c) continue;
            try {
                const gp_Pnt pa = point(a), pb = point(b), pc = point(c);
                const gp_Vec normal = gp_Vec(pa, pb).Crossed(gp_Vec(pa, pc));
                if (normal.Magnitude() < 1e-14) continue;
                TopoDS_Wire wire;
                builder.MakeWire(wire);
                builder.Add(wire, edgeBetween(a, b));
                builder.Add(wire, edgeBetween(b, c));
                builder.Add(wire, edgeBetween(c, a));
                wire.Closed(Standard_True);
                // Ebene mit der Dreiecksnormale: der Linienzug a → b → c läuft um sie gegen den Uhrzeigersinn
                Handle(Geom_Plane) plane = new Geom_Plane(gp_Pln(pa, gp_Dir(normal)));
                TopoDS_Face face;
                builder.MakeFace(face, plane, tol);
                builder.Add(face, wire);
                builder.Add(shell, face);
                ++faceCount;
            } catch (...) {
                continue;
            }
        }
        if (faceCount == 0) return nil;
        bool closed = BRep_Tool::IsClosed(shell);
        // Kleine Spalte (nicht verschweißte Punkte): bei kleineren Netzen doch noch vernähen
        if (!closed && faceCount <= 20000) {
            try {
                BRepBuilderAPI_Sewing sewing(std::max(tol * 10, 1e-3));
                sewing.Add(shell);
                sewing.Perform();
                const TopoDS_Shape sewed = sewing.SewedShape();
                int shells = 0;
                TopoDS_Shell candidate;
                for (TopExp_Explorer it(sewed, TopAbs_SHELL); it.More(); it.Next()) {
                    candidate = TopoDS::Shell(it.Current());
                    ++shells;
                }
                if (shells == 1 && BRep_Tool::IsClosed(candidate)) {
                    shell = candidate;
                    closed = true;
                }
            } catch (...) {
            }
        }
        shell.Closed(closed ? Standard_True : Standard_False);
        TopoDS_Shape result = shell;
        if (closed) {
            BRepBuilderAPI_MakeSolid makeSolid(shell);
            if (makeSolid.IsDone()) {
                TopoDS_Solid solid = makeSolid.Solid();
                // Normalen nach außen (falls das Netz innen-außen vertauscht war)
                BRepLib::OrientClosedSolid(solid);
                result = solid;
            }
        }
        // Gleich liegende Dreiecke zu großen ebenen Flächen verschmelzen: eine Würfelseite wird wieder EINE
        // Fläche, die sich antippen und extrudieren lässt; Kanten auf einer Geraden werden eine Kante
        try {
            ShapeUpgrade_UnifySameDomain unify(result, Standard_True, Standard_True, Standard_False);
            unify.SetLinearTolerance(std::max(tol, 1e-4));
            unify.SetAngularTolerance(1e-3);
            unify.Build();
            const TopoDS_Shape merged = unify.Shape();
            if (!merged.IsNull()) result = merged;
        } catch (...) {
        }
        return [[PCKShape alloc] initWithShape:result];
    } catch (...) {
        return nil;
    }
}

+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
    std::unique_lock<std::recursive_timed_mutex> stepLock(pckSTEPMutex(), std::defer_lock);
    if (!stepLock.try_lock_for(std::chrono::seconds(kPCKSTEPLockSeconds))) return nil;
    try {
        STEPControl_Reader reader;
        if (reader.ReadFile(path.fileSystemRepresentation) != IFSelect_RetDone) return nil;
        reader.TransferRoots();
        const TopoDS_Shape shape = reader.OneShape();
        if (shape.IsNull()) return nil;
        NSMutableArray<PCKShape *> *result = [NSMutableArray array];
        for (TopExp_Explorer explorer(shape, TopAbs_SOLID); explorer.More(); explorer.Next()) {
            [result addObject:[[PCKShape alloc] initWithShape:explorer.Current()]];
        }
        if (result.count == 0) {
            [result addObject:[[PCKShape alloc] initWithShape:shape]];
        }
        return result;
    } catch (...) {
        return nil;
    }
#else
    return nil;
#endif
}

+ (nullable NSArray<PCKShape *> *)bodyShapesFromSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
    std::unique_lock<std::recursive_timed_mutex> stepLock(pckSTEPMutex(), std::defer_lock);
    if (!stepLock.try_lock_for(std::chrono::seconds(kPCKSTEPLockSeconds))) return nil;
    try {
        STEPControl_Reader reader;
        if (reader.ReadFile(path.fileSystemRepresentation) != IFSelect_RetDone) return nil;
        reader.TransferRoots();
        NSMutableArray<PCKShape *> *result = [NSMutableArray array];
        for (int index = 1; index <= reader.NbShapes(); ++index) {
            const TopoDS_Shape shape = reader.Shape(index);
            if (!shape.IsNull()) [result addObject:[[PCKShape alloc] initWithShape:shape]];
        }
        return result.count > 0 ? result : nil;
    } catch (...) {
        return nil;
    }
#else
    return nil;
#endif
}

+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
    std::unique_lock<std::recursive_timed_mutex> stepLock(pckSTEPMutex(), std::defer_lock);
    if (!stepLock.try_lock_for(std::chrono::seconds(kPCKSTEPLockSeconds))) return NO;
    try {
        STEPControl_Writer writer;
        Interface_Static::SetCVal("write.step.unit", "MM");
        for (PCKShape *shape in shapes) {
            if (writer.Transfer(shape->_shape, STEPControl_AsIs) != IFSelect_RetDone) return NO;
        }
        return writer.Write(path.fileSystemRepresentation) == IFSelect_RetDone;
    } catch (...) {
        return NO;
    }
#else
    return NO;
#endif
}

+ (nullable NSArray<NSData *> *)hiddenLineViewOfShapes:(NSArray<PCKShape *> *)shapes toEye:(simd_double3)toEye
                                                 xAxis:(simd_double3)xAxis deflection:(double)deflection {
#if PCK_HAS_HLR
    if (shapes.count == 0 || simd_length(toEye) < 1e-12 || simd_length(xAxis) < 1e-12) return nil;
    try {
        Handle(HLRBRep_Algo) algo = new HLRBRep_Algo();
        for (PCKShape *shape in shapes) {
            if (!shape->_shape.IsNull()) algo->Add(shape->_shape);
        }
        // Hauptrichtung des Projektors zeigt zum Betrachter; die Ergebnisse liegen in dessen XY-Ebene
        const gp_Ax2 axes(gp_Pnt(0, 0, 0), gp_Dir(toEye.x, toEye.y, toEye.z), gp_Dir(xAxis.x, xAxis.y, xAxis.z));
        algo->Projector(HLRAlgo_Projector(axes));
        algo->Update();
        algo->Hide();
        HLRBRep_HLRToShape extractor(algo);
        // Punkte (x, y, z) je Linienstück; die Ergebnisse liegen im Koordinatensystem des Projektors (z = 0).
        // Falls nicht (andere OCCT-Version), wird unten selbst auf die Ansichtsebene projiziert.
        std::vector<double> visible, hidden;
        const double tolerance = deflection > 0 ? deflection : 0.05;
        double largestZ = 0;
        auto collect = [&](const TopoDS_Shape &compound, std::vector<double> &out) {
            if (compound.IsNull()) return;
            try {
                BRepLib::BuildCurves3d(compound);
            } catch (...) {
            }
            for (TopExp_Explorer it(compound, TopAbs_EDGE); it.More(); it.Next()) {
                try {
                    const TopoDS_Edge edge = TopoDS::Edge(it.Current());
                    if (BRep_Tool::Degenerated(edge)) continue;
                    BRepAdaptor_Curve curve(edge);
                    GCPnts_TangentialDeflection points(curve, 0.2, tolerance);
                    for (int k = 1; k < points.NbPoints(); ++k) {
                        const gp_Pnt a = points.Value(k), b = points.Value(k + 1);
                        out.insert(out.end(), {a.X(), a.Y(), a.Z(), b.X(), b.Y(), b.Z()});
                        largestZ = std::max(largestZ, std::max(std::fabs(a.Z()), std::fabs(b.Z())));
                    }
                } catch (...) {
                    continue;
                }
            }
        };
        // Scharfe Kanten, Übergangskanten (tangential, nur sichtbar) und Umrisse gekrümmter Flächen
        collect(extractor.VCompound(), visible);
        collect(extractor.Rg1LineVCompound(), visible);
        collect(extractor.OutLineVCompound(), visible);
        collect(extractor.HCompound(), hidden);
        collect(extractor.OutLineHCompound(), hidden);

        const bool local = largestZ < 1e-6;
        const gp_Dir xDir = axes.XDirection(), yDir = axes.YDirection();
        auto flatten = [&](const std::vector<double> &points) {
            std::vector<double> result;
            result.reserve(points.size() / 3 * 2);
            for (size_t i = 0; i + 2 < points.size(); i += 3) {
                if (local) {
                    result.insert(result.end(), {points[i], points[i + 1]});
                } else {
                    const gp_XYZ p(points[i], points[i + 1], points[i + 2]);
                    result.insert(result.end(), {p.Dot(xDir.XYZ()), p.Dot(yDir.XYZ())});
                }
            }
            return result;
        };
        const std::vector<double> visible2D = flatten(visible), hidden2D = flatten(hidden);
        return @[[NSData dataWithBytes:visible2D.data() length:visible2D.size() * sizeof(double)],
                 [NSData dataWithBytes:hidden2D.data() length:hidden2D.size() * sizeof(double)]];
    } catch (...) {
        return nil;
    }
#else
    return nil;
#endif
}

#else

- (instancetype)initWithFallback:(FallbackBody)body {
    if ((self = [super init])) {
        _fallback = std::move(body);
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    const double x = width / 2, y = depth / 2;
    const std::vector<simd_double3> rect = {
        simd_make_double3(-x, -y, 0), simd_make_double3(x, -y, 0),
        simd_make_double3(x, y, 0), simd_make_double3(-x, y, 0)};
    return [[PCKShape alloc] initWithFallback:fallbackPrism(rect, simd_make_double3(0, 0, height), false)];
}

+ (nullable PCKShape *)cylinderWithBase:(simd_double3)base axis:(simd_double3)axis
                                 radius:(double)radius height:(double)height {
    if (radius <= 0 || height <= 0 || !validDir(axis)) return nil;
    const std::vector<simd_double3> circle = circlePoints(base, axis, radius, 64);
    return [[PCKShape alloc] initWithFallback:fallbackPrism(circle, simd_normalize(axis) * height, true)];
}

+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction {
    const std::vector<simd_double3> points = toPoints(xyz);
    if (points.size() < 3 || !validDir(direction)) return nil;
    return [[PCKShape alloc] initWithFallback:fallbackPrism(points, direction, false)];
}

+ (nullable PCKShape *)sphereWithCenter:(simd_double3)center radius:(double)radius {
    return nil;
}

+ (nullable PCKShape *)prismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires direction:(simd_double3)direction {
    return nil;
}

+ (nullable PCKShape *)draftPrismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
                                        direction:(simd_double3)direction angle:(double)degrees {
    return nil;
}

+ (nullable PCKShape *)faceWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires {
    return nil;
}

+ (nullable PCKShape *)torusWithCenter:(simd_double3)center axis:(simd_double3)axis
                           majorRadius:(double)majorRadius minorRadius:(double)minorRadius {
    return nil;
}

+ (nullable PCKShape *)revolveProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires axisOrigin:(simd_double3)origin
                             axisDirection:(simd_double3)direction angle:(double)radians {
    return nil;
}

+ (nullable PCKShape *)sweepProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires path:(NSArray<NSNumber *> *)path {
    return nil;
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections {
    return nil;
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections
                            startOffset:(simd_double3)startOffset endOffset:(simd_double3)endOffset {
    return nil;
}

+ (nullable PCKShape *)loftThroughWires:(NSArray<NSArray<NSNumber *> *> *)sections
                                 guides:(NSArray<NSArray<NSNumber *> *> *)guides {
    return nil;
}

+ (nullable PCKShape *)thinPrismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires
                                     planeOrigin:(simd_double3)origin planeNormal:(simd_double3)normal
                                       thickness:(double)thickness side:(NSInteger)side
                                       direction:(simd_double3)direction {
    return nil;
}

+ (nullable PCKShape *)springWithBase:(simd_double3)base axis:(simd_double3)axis radius:(double)radius
                                pitch:(double)pitch height:(double)height leftHanded:(BOOL)leftHanded
                         wireDiameter:(double)wireDiameter {
    return nil;
}

+ (nullable PCKShape *)helixSweepWithBase:(simd_double3)base axis:(simd_double3)axis radius:(double)radius
                                    pitch:(double)pitch height:(double)height leftHanded:(BOOL)leftHanded
                                profileRZ:(NSArray<NSNumber *> *)profileRZ {
    return nil;
}

+ (nullable PCKShape *)threadWithBase:(simd_double3)base axis:(simd_double3)axis length:(double)length
                                 lead:(double)lead starts:(NSInteger)starts taper:(double)taper
                           leftHanded:(BOOL)leftHanded profileRZ:(NSArray<NSNumber *> *)profileRZ
                           coreRadius:(double)coreRadius {
    return nil;
}

- (nullable PCKShape *)cuttingTool:(PCKShape *)tool fuzzy:(double)fuzzy {
    return nil;
}

- (BOOL)containsPoint:(simd_double3)point {
    return NO;
}

- (nullable PCKShape *)validatedSolid {
    return self;
}

- (nullable PCKShape *)independentCopy {
    return self;
}

- (nullable NSData *)brepData {
    return nil;
}

+ (nullable PCKShape *)shapeFromBRepData:(NSData *)data {
    return nil;
}

- (nullable PCKShape *)independentCopyKeepingMesh {
    return self;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius endRadius:(double)endRadius {
    return nil;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radii:(NSArray<NSNumber *> *)radii {
    return nil;
}

- (nullable PCKShape *)partiallyFilletingEdge:(NSInteger)edge radius:(double)radius start:(double)start end:(double)end {
    return nil;
}

- (nullable PCKShape *)sweepProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires alongEdges:(NSArray<NSNumber *> *)edges {
    return nil;
}

- (nullable PCKShape *)draftingFaces:(NSArray<NSNumber *> *)faces pull:(simd_double3)pull
                       neutralOrigin:(simd_double3)neutralOrigin angle:(double)degrees {
    return nil;
}

- (nullable PCKShape *)scaledAboutPoint:(simd_double3)center factors:(simd_double3)factors {
    return nil;
}

- (nullable NSArray<PCKShape *> *)splitAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    return nil;
}

- (nullable NSArray<PCKShape *> *)splitByTool:(PCKShape *)tool {
    return nil;
}

- (NSArray<PCKShape *> *)separatedSolids {
    return @[self];
}

- (NSArray<PCKShape *> *)separatedParts {
    return @[self];
}

- (NSArray<PCKShape *> *)solidParts {
    return @[self];
}

- (double)volume {
    return 0;
}

- (NSInteger)faceCount {
    return 0;
}

- (double)lengthOfEdge:(NSInteger)index {
    return 0;
}

- (double)areaOfFace:(NSInteger)index {
    return 0;
}

- (nullable NSArray<NSNumber *> *)geometryOfEdge:(NSInteger)index {
    return nil;
}

- (nullable NSArray<NSNumber *> *)surfaceOfFace:(NSInteger)index {
    return nil;
}

- (nullable NSArray<NSNumber *> *)outlineOfFace:(NSInteger)index deflection:(double)deflection {
    return nil;
}

- (NSArray<NSNumber *> *)edgeNumbersOfFace:(NSInteger)face {
    return @[];
}

- (NSArray<NSNumber *> *)connectedEdgeNumbersOfFace:(NSInteger)face startingAtEdge:(NSInteger)edge {
    return @[];
}

- (NSArray<NSNumber *> *)tangentEdgeNumbersStartingAtEdge:(NSInteger)edge {
    return @[];
}

+ (nullable PCKShape *)compoundOfShapes:(NSArray<PCKShape *> *)shapes {
    return shapes.firstObject;
}

+ (nullable PCKShape *)coneWithBase:(simd_double3)base axis:(simd_double3)axis
                       bottomRadius:(double)bottomRadius topRadius:(double)topRadius height:(double)height {
    return nil;
}

+ (nullable PCKShape *)ellipsePrismWithCenter:(simd_double3)center normal:(simd_double3)normal
                                        xAxis:(simd_double3)xAxis radiusX:(double)radiusX
                                      radiusY:(double)radiusY direction:(simd_double3)direction {
    if (radiusX <= 0 || radiusY <= 0 || !validDir(direction) || !validDir(normal)) return nil;
    const simd_double3 x = simd_normalize(xAxis);
    const simd_double3 y = simd_cross(simd_normalize(normal), x);
    std::vector<simd_double3> points;
    for (int i = 0; i < 72; ++i) {
        const double a = 2 * M_PI * i / 72;
        points.push_back(center + radiusX * std::cos(a) * x + radiusY * std::sin(a) * y);
    }
    return [[PCKShape alloc] initWithFallback:fallbackPrism(points, direction, true)];
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    return nil;
}

- (nullable PCKShape *)intersecting:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)extrudingFace:(NSInteger)face distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)extrudingFaces:(NSArray<NSNumber *> *)faces distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)offsettingFaces:(NSArray<NSNumber *> *)faces distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)replacingFaces:(NSArray<NSNumber *> *)faces planeOrigin:(simd_double3)origin
                          planeNormal:(simd_double3)normal {
    return nil;
}

- (nullable NSArray<NSNumber *> *)cylinderOfFace:(NSInteger)face {
    return nil;
}

+ (nullable PCKShape *)ruledSolidBetween:(NSArray<NSNumber *> *)first and:(NSArray<NSNumber *> *)second {
    return nil;
}

- (nullable PCKShape *)imprinting:(PCKShape *)tool {
    return nil;
}

- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness {
    return nil;
}

- (nullable PCKShape *)shellingRemovingFaces:(NSArray<NSNumber *> *)faces thickness:(double)thickness {
    return nil;
}

- (nullable NSArray<NSNumber *> *)centerOfMass {
    return nil;
}

- (nullable PCKShape *)offsetSolidBy:(double)distance {
    return nil;
}

- (nullable NSArray<NSNumber *> *)boundingBox {
    return nil;
}

- (nullable NSArray<NSNumber *> *)minimumDistanceTo:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance
                             distance2:(double)distance2 {
    return nil;
}

- (nullable PCKShape *)translatedBy:(simd_double3)offset {
    FallbackBody body = _fallback;
    for (size_t i = 0; i + 5 < body.mesh.vertices.size(); i += 6) {
        body.mesh.vertices[i] += float(offset.x);
        body.mesh.vertices[i + 1] += float(offset.y);
        body.mesh.vertices[i + 2] += float(offset.z);
    }
    for (size_t i = 0; i + 5 < body.mesh.edges.size(); i += 3) {
        body.mesh.edges[i] += float(offset.x);
        body.mesh.edges[i + 1] += float(offset.y);
        body.mesh.edges[i + 2] += float(offset.z);
    }
    for (auto &plane : body.planes) {
        plane[0] += offset.x;
        plane[1] += offset.y;
        plane[2] += offset.z;
    }
    return [[PCKShape alloc] initWithFallback:std::move(body)];
}

- (nullable PCKShape *)rotatedAroundOrigin:(simd_double3)origin axis:(simd_double3)axis angle:(double)radians {
    return nil;
}

- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    return nil;
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius {
    return nil;
}

+ (BOOL)supportsBlendOptions:(PCKBlendOptions *)options {
    return options.isValid && options.isStandard;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius
                              options:(PCKBlendOptions *)options {
    return nil;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radii:(NSArray<NSNumber *> *)radii
                              options:(PCKBlendOptions *)options {
    return nil;
}

- (NSArray<NSNumber *> *)unblendableEdges:(NSArray<NSNumber *> *)edges value:(double)value chamfer:(BOOL)chamfer {
    // Ohne Kernel ist keine Kante abrundbar
    return edges;
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance {
    return nil;
}

- (nullable NSArray<NSNumber *> *)handleOfEdge:(NSInteger)edge {
    return nil;
}

- (nullable NSArray<NSNumber *> *)blendOfFace:(NSInteger)face {
    return nil;
}

- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)face {
    if (face < 1 || size_t(face) > _fallback.planes.size() || !_fallback.planar[face - 1]) return nil;
    const auto &p = _fallback.planes[face - 1];
    return @[@(p[0]), @(p[1]), @(p[2]), @(p[3]), @(p[4]), @(p[5])];
}

- (nullable NSArray<NSNumber *> *)surfacePointOfFace:(NSInteger)face near:(simd_double3)point {
    // Ohne Kernel nur ebene Flächen: Punkt in die Ebene legen
    NSArray<NSNumber *> *plane = [self planeOfFace:face];
    if (plane == nil) return nil;
    const double nx = plane[3].doubleValue, ny = plane[4].doubleValue, nz = plane[5].doubleValue;
    const double d = (point.x - plane[0].doubleValue) * nx + (point.y - plane[1].doubleValue) * ny
        + (point.z - plane[2].doubleValue) * nz;
    return @[@(point.x - d * nx), @(point.y - d * ny), @(point.z - d * nz), @(nx), @(ny), @(nz)];
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    return [[PCKMesh alloc] initWithBuffers:_fallback.mesh];
}

- (BOOL)isClosedSolid {
    return YES;
}

- (BOOL)isBRepValid {
    return NO;
}

- (BOOL)isValidBlendPreviewFromShape:(PCKShape *)source {
    return NO;
}

- (BOOL)hasPlausibleSingleEdgeFilletVolumeFromShape:(PCKShape *)source edge:(NSInteger)edge radius:(double)radius {
    return YES;
}


+ (nullable PCKShape *)solidFromMeshPoints:(NSData *)points triangles:(NSData *)triangles tolerance:(double)tolerance {
    return nil;
}

+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path {
    return nil;
}

+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path {
    return NO;
}

+ (nullable NSArray<NSData *> *)hiddenLineViewOfShapes:(NSArray<PCKShape *> *)shapes toEye:(simd_double3)toEye
                                                 xAxis:(simd_double3)xAxis deflection:(double)deflection {
    return nil;
}

#endif

@end
