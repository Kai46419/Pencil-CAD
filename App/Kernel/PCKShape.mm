#import "PCKShape.h"

#include <algorithm>
#include <array>
#include <cmath>
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
#include <BRepGProp.hxx>
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
#include <ShapeFix_Face.hxx>
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
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
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

@implementation PCKShape {
#if PCK_HAS_OCCT
    TopoDS_Shape _shape;
    TopTools_IndexedMapOfShape _faces;
    TopTools_IndexedMapOfShape _edges;
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
    if (radius <= 0 || height <= 0 || simd_length(axis) == 0) return nil;
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
        simd_length(axis) == 0) return nil;
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
    if (radiusX <= 0 || radiusY <= 0 || simd_length(direction) == 0 || simd_length(normal) == 0) return nil;
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
    if (points.size() < 3 || simd_length(direction) == 0) return nil;
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
    if (simd_length(direction) == 0) return nil;
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
    if (simd_length(direction) == 0) return nil;
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
        return [[PCKShape alloc] initWithShape:draft.Shape()];
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
    if (majorRadius <= 0 || minorRadius <= 0 || minorRadius >= majorRadius || simd_length(axis) == 0) return nil;
    try {
        BRepPrimAPI_MakeTorus torus(gp_Ax2(toPnt(center), toDir(axis)), majorRadius, minorRadius);
        return [[PCKShape alloc] initWithShape:torus.Shape()];
    } catch (...) {
        return nil;
    }
}

+ (nullable PCKShape *)revolveProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires axisOrigin:(simd_double3)origin
                             axisDirection:(simd_double3)direction angle:(double)radians {
    if (simd_length(direction) == 0 || radians == 0) return nil;
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        const double angle = std::min(std::abs(radians), 2 * M_PI);
        gp_Dir axis = toDir(direction);
        if (radians < 0) axis.Reverse();
        BRepPrimAPI_MakeRevol revol(face, gp_Ax1(toPnt(origin), axis), angle, Standard_True);
        if (!revol.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:revol.Shape()];
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
        return [[PCKShape alloc] initWithShape:pipe.Shape()];
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
        return [[PCKShape alloc] initWithShape:loft.Shape()];
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
        return [[PCKShape alloc] initWithShape:loft.Shape()];
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
        return [[PCKShape alloc] initWithShape:result];
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
    if (wires.count == 0 || thickness <= 0 || simd_length(direction) == 0 || simd_length(normal) == 0) return nil;
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
static TopoDS_Shape helixPipe(const TopoDS_Wire &spine, const TopoDS_Wire &profile) {
    for (int mode = 0; mode < 3; ++mode) {
        try {
            BRepOffsetAPI_MakePipeShell pipe(spine);
            if (mode == 0) {
                pipe.SetMode(gp_Dir(0, 0, 1));
            } else {
                pipe.SetMode(mode == 1 ? Standard_True : Standard_False);
            }
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
    if (radius <= 0 || pitch <= 0 || height <= 0 || wireDiameter <= 0 || simd_length(axis) == 0) return nil;
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
    if (radius <= 0 || pitch <= 0 || height <= 0 || profileRZ.count < 6 || simd_length(axis) == 0) return nil;
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

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Cut op(_shape, tool->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    try {
        BRepAlgoAPI_Fuse op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)intersecting:(PCKShape *)other {
    try {
        BRepAlgoAPI_Common op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)extrudingFace:(NSInteger)index distance:(double)distance {
    if (distance == 0) return nil;
    NSArray<NSNumber *> *plane = [self planeOfFace:index];
    if (plane == nil) return nil;
    const gp_Vec normal(plane[3].doubleValue, plane[4].doubleValue, plane[5].doubleValue);
    try {
        // Das Werkzeug beginnt knapp auf der anderen Seite der Fläche: so überlappen Körper und Prisma
        // sicher (keine deckungsgleichen Flächen, an denen Vereinigen bzw. Abziehen bei schrägen
        // Fasenflächen scheitert).
        const double overlap = 0.01;
        const double start = distance > 0 ? -overlap : overlap;
        gp_Trsf shift;
        shift.SetTranslation(normal * start);
        const TopoDS_Shape face = _faces(int(index)).Moved(TopLoc_Location(shift));
        BRepPrimAPI_MakePrism prism(face, normal * (distance - start));
        if (!prism.IsDone()) return nil;
        TopoDS_Shape result;
        if (distance > 0) {
            BRepAlgoAPI_Fuse op(_shape, prism.Shape());
            if (!op.IsDone()) return nil;
            result = op.Shape();
        } else {
            BRepAlgoAPI_Cut op(_shape, prism.Shape());
            if (!op.IsDone()) return nil;
            result = op.Shape();
        }
        try {
            return [[PCKShape alloc] initWithShape:unified(result)];
        } catch (...) {
            return [[PCKShape alloc] initWithShape:result];
        }
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)extrudingFaces:(NSArray<NSNumber *> *)indices distance:(double)distance {
    if (distance == 0 || indices.count == 0) return nil;
    if (indices.count == 1) return [self extrudingFace:indices[0].integerValue distance:distance];
    try {
        const double overlap = 0.01;
        const double start = distance > 0 ? -overlap : overlap;
        BRep_Builder builder;
        TopoDS_Compound tools;
        builder.MakeCompound(tools);
        for (NSNumber *number in indices) {
            NSArray<NSNumber *> *plane = [self planeOfFace:number.integerValue];
            if (plane == nil) return nil;
            const gp_Vec normal(plane[3].doubleValue, plane[4].doubleValue, plane[5].doubleValue);
            gp_Trsf shift;
            shift.SetTranslation(normal * start);
            const TopoDS_Shape face = _faces(number.intValue).Moved(TopLoc_Location(shift));
            BRepPrimAPI_MakePrism prism(face, normal * (distance - start));
            if (!prism.IsDone()) return nil;
            builder.Add(tools, prism.Shape());
        }
        TopoDS_Shape result;
        if (distance > 0) {
            BRepAlgoAPI_Fuse op(_shape, tools);
            if (!op.IsDone()) return nil;
            result = op.Shape();
        } else {
            BRepAlgoAPI_Cut op(_shape, tools);
            if (!op.IsDone()) return nil;
            result = op.Shape();
        }
        return [[PCKShape alloc] initWithShape:unified(result)];
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
            TopoDS_Shape solid;
            for (TopExp_Explorer it(offset.Shape(), TopAbs_SOLID); it.More(); it.Next()) {
                solid = it.Current();
                break;
            }
            if (!solid.IsNull() && BRepCheck_Analyzer(solid).IsValid()) {
                return [[PCKShape alloc] initWithShape:unified(solid)];
            }
        }
    } catch (...) {
    }
    // Ebene Flächen: wie Extrudieren (ergibt bei senkrechten Nachbarflächen dasselbe)
    return [self extrudingFaces:indices distance:distance];
}

- (nullable PCKShape *)replacingFaces:(NSArray<NSNumber *> *)indices planeOrigin:(simd_double3)origin
                          planeNormal:(simd_double3)normalIn {
    if (indices.count == 0 || simd_length(normalIn) == 0) return nil;
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
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)shellingRemovingFaces:(NSArray<NSNumber *> *)indices thickness:(double)thickness {
    if (thickness <= 0) return nil;
    try {
        if (indices.count == 0) {
            // Keine offene Fläche: Hohlkörper (Innenhaut um die Wandstärke versetzt, Kammer geschlossen)
            BRepOffset_MakeOffset offset;
            offset.Initialize(_shape, -thickness, 1e-6, BRepOffset_Skin, Standard_False, Standard_False,
                              GeomAbs_Intersection, Standard_False);
            offset.MakeOffsetShape();
            if (!offset.IsDone() || offset.Shape().IsNull()) return nil;
            TopoDS_Shape inner;
            for (TopExp_Explorer it(offset.Shape(), TopAbs_SHELL); it.More(); it.Next()) {
                inner = it.Current();
                break;
            }
            TopoDS_Shape outer;
            for (TopExp_Explorer it(_shape, TopAbs_SHELL); it.More(); it.Next()) {
                outer = it.Current();
                break;
            }
            if (inner.IsNull() || outer.IsNull()) return nil;
            BRep_Builder builder;
            TopoDS_Solid hollow;
            builder.MakeSolid(hollow);
            builder.Add(hollow, outer);
            builder.Add(hollow, inner.Reversed());
            if (!BRepCheck_Analyzer(hollow).IsValid()) return nil;
            return [[PCKShape alloc] initWithShape:hollow];
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
        return [[PCKShape alloc] initWithShape:maker.Shape()];
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
    if (simd_length(axis) == 0) return nil;
    gp_Trsf transform;
    transform.SetRotation(gp_Ax1(toPnt(origin), toDir(axis)), radians);
    return [self transformedBy:transform];
}

- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    if (simd_length(normal) == 0) return nil;
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

- (nullable NSArray<PCKShape *> *)splitAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    if (simd_length(normal) == 0) return nil;
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
static std::vector<TopoDS_Edge> matchEdges(const std::vector<TopoDS_Edge> &old, const TopoDS_Shape &shape) {
    const double tolerance = 1e-4;
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

/// Ein Durchgang Abrunden bzw. Fasen; leere Form bei Fehler.
static TopoDS_Shape blendOnce(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges, double value,
                              bool chamfer) {
    try {
        if (chamfer) {
            BRepFilletAPI_MakeChamfer maker(shape);
            for (const auto &edge : edges) maker.Add(value, edge);
            maker.Build();
            if (maker.IsDone()) return maker.Shape();
        } else {
            BRepFilletAPI_MakeFillet maker(shape);
            for (const auto &edge : edges) maker.Add(value, edge);
            maker.Build();
            if (maker.IsDone()) return maker.Shape();
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
    if (edges.empty() || value <= 0) return TopoDS_Shape();
    TopoDS_Shape result = blendOnce(shape, edges, value, chamfer);
    if (!result.IsNull()) return result;
    try {
        const TopoDS_Shape merged = unified(shape);
        const std::vector<TopoDS_Edge> mergedEdges = matchEdges(edges, merged);
        if (mergedEdges.empty()) return TopoDS_Shape();
        result = blendOnce(merged, mergedEdges, value, chamfer);
        if (!result.IsNull() || edges.size() < 2) return result;
        TopoDS_Shape current = merged;
        for (const auto &edge : edges) {
            const std::vector<TopoDS_Edge> step = matchEdges({edge}, current);
            // Leer: schon von einer vorigen Rundung erfasst (tangentiale Kette)
            if (step.empty()) continue;
            current = blendOnce(current, step, value, chamfer);
            if (current.IsNull()) return TopoDS_Shape();
        }
        return current;
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

static std::vector<TopoDS_Edge> edgeVector(const TopTools_IndexedMapOfShape &map) {
    std::vector<TopoDS_Edge> result;
    for (int i = 1; i <= map.Extent(); ++i) result.push_back(TopoDS::Edge(map(i)));
    return result;
}

- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius {
    const TopoDS_Shape result = blendEdges(_shape, edgeVector(realEdgesOfFace(_faces, face)), radius, false);
    return result.IsNull() ? nil : [[PCKShape alloc] initWithShape:result];
}

- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance {
    const TopoDS_Shape result = blendEdges(_shape, edgeVector(realEdgesOfFace(_faces, face)), distance, true);
    return result.IsNull() ? nil : [[PCKShape alloc] initWithShape:result];
}

/// Kanten aus Nummern (ab 1); ungültige Nummern werden übersprungen.
static std::vector<TopoDS_Edge> edgesFromNumbers(const TopTools_IndexedMapOfShape &edges, NSArray<NSNumber *> *numbers) {
    std::vector<TopoDS_Edge> result;
    for (NSNumber *number in numbers) {
        const NSInteger index = number.integerValue;
        if (index < 1 || index > edges.Extent()) continue;
        result.push_back(TopoDS::Edge(edges(int(index))));
    }
    return result;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius {
    const TopoDS_Shape result = blendEdges(_shape, edgesFromNumbers(_edges, numbers), radius, false);
    return result.IsNull() ? nil : [[PCKShape alloc] initWithShape:result];
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)numbers distance:(double)distance {
    const TopoDS_Shape result = blendEdges(_shape, edgesFromNumbers(_edges, numbers), distance, true);
    return result.IsNull() ? nil : [[PCKShape alloc] initWithShape:result];
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)numbers distance:(double)distance
                             distance2:(double)distance2 {
    if (std::abs(distance - distance2) < 1e-9) return [self chamferingEdges:numbers distance:distance];
    if (distance <= 0 || distance2 <= 0) return nil;
    try {
        // Zwei Abstände: distance auf der ersten Nachbarfläche der Kante, distance2 auf der anderen
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        BRepFilletAPI_MakeChamfer chamfer(_shape);
        int added = 0;
        for (const auto &edge : edgesFromNumbers(_edges, numbers)) {
            if (!edgeFaces.Contains(edge) || edgeFaces.FindFromKey(edge).IsEmpty()) continue;
            chamfer.Add(distance, distance2, edge, TopoDS::Face(edgeFaces.FindFromKey(edge).First()));
            added += 1;
        }
        if (added == 0) return nil;
        chamfer.Build();
        if (!chamfer.IsDone() || chamfer.Shape().IsNull()) return nil;
        return [[PCKShape alloc] initWithShape:chamfer.Shape()];
    } catch (...) {
        return nil;
    }
}

/// Ein Durchgang variable Rundung; leere Form bei Fehler.
static TopoDS_Shape variableFilletOnce(const TopoDS_Shape &shape, const std::vector<TopoDS_Edge> &edges, double r1,
                                       double r2) {
    try {
        BRepFilletAPI_MakeFillet maker(shape);
        for (const auto &edge : edges) maker.Add(r1, r2, edge);
        maker.Build();
        if (maker.IsDone() && !maker.Shape().IsNull()) return maker.Shape();
    } catch (...) {
    }
    return TopoDS_Shape();
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius endRadius:(double)endRadius {
    if (radius <= 0 || endRadius <= 0) return nil;
    if (std::abs(radius - endRadius) < 1e-9) return [self filletingEdges:numbers radius:radius];
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty()) return nil;
    TopoDS_Shape result = variableFilletOnce(_shape, edges, radius, endRadius);
    if (result.IsNull()) {
        // Wie blendEdges: zerteilte Flächen und Kanten erst zusammenfassen
        try {
            const TopoDS_Shape merged = unified(_shape);
            const std::vector<TopoDS_Edge> mergedEdges = matchEdges(edges, merged);
            if (!mergedEdges.empty()) result = variableFilletOnce(merged, mergedEdges, radius, endRadius);
        } catch (...) {
        }
    }
    return result.IsNull() ? nil : [[PCKShape alloc] initWithShape:result];
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
            return [[PCKShape alloc] initWithShape:pipe.Shape()];
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
        return [[PCKShape alloc] initWithShape:result];
    } catch (...) {
        return nil;
    }
}

- (nullable PCKShape *)draftingFaces:(NSArray<NSNumber *> *)faces pull:(simd_double3)pull
                       neutralOrigin:(simd_double3)neutralOrigin angle:(double)degrees {
    if (faces.count == 0 || simd_length(pull) == 0 || std::abs(degrees) < 1e-9 || std::abs(degrees) >= 89) return nil;
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
        return [[PCKShape alloc] initWithShape:draft.Shape()];
    } catch (...) {
        return nil;
    }
}

- (double)maximumBlendForEdges:(NSArray<NSNumber *> *)numbers upTo:(double)limit chamfer:(BOOL)chamfer {
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty() || limit <= 0) return 0;
    try {
        // Zusammengefasste Form (wie im Rückfall von blendEdges): zerteilte Seiten begrenzen sonst den Radius
        const TopoDS_Shape merged = unified(_shape);
        const std::vector<TopoDS_Edge> mergedEdges = matchEdges(edges, merged);
        const bool useMerged = !mergedEdges.empty();
        double lo = 0, hi = limit;
        for (int i = 0; i < 9 && hi - lo > limit * 0.01; ++i) {
            const double mid = 0.5 * (lo + hi);
            const bool ok = !blendOnce(_shape, edges, mid, chamfer).IsNull()
                || (useMerged && !blendOnce(merged, mergedEdges, mid, chamfer).IsNull());
            if (ok) lo = mid; else hi = mid;
        }
        return lo;
    } catch (...) {
        return 0;
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
            for (TopTools_ListIteratorOfListOfShape it(edgeFaces(key)); it.More(); it.Next()) {
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
            for (TopTools_ListIteratorOfListOfShape it(edgeFaces(key)); it.More(); it.Next()) {
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

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    MeshBuffers buffers;
    // Fehler im Vernetzer dürfen die App nicht beenden: dann eben ohne bzw. mit weniger Dreiecken
    try {
        BRepMesh_IncrementalMesh mesher(_shape, deflection, Standard_False, 0.35, Standard_True);
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
            for (TopTools_ListIteratorOfListOfShape it(edgeFaces(i)); it.More(); it.Next()) {
                if (it.Value().ShapeType() == TopAbs_FACE && BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) seam = true;
            }
            if (seam) continue;
            // Kante ohne 3D-Kurve und ohne Kurve auf einer Fläche: BRepAdaptor_Curve griffe auf ein leeres Handle zu
            if (!BRep_Tool::IsGeometric(edge)) continue;
            BRepAdaptor_Curve curve(edge);
            GCPnts_TangentialDeflection points(curve, 0.2, deflection);
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

+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
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

+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
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
    if (radius <= 0 || height <= 0 || simd_length(axis) == 0) return nil;
    const std::vector<simd_double3> circle = circlePoints(base, axis, radius, 64);
    return [[PCKShape alloc] initWithFallback:fallbackPrism(circle, simd_normalize(axis) * height, true)];
}

+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction {
    const std::vector<simd_double3> points = toPoints(xyz);
    if (points.size() < 3 || simd_length(direction) == 0) return nil;
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

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius endRadius:(double)endRadius {
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

- (double)volume {
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
    if (radiusX <= 0 || radiusY <= 0 || simd_length(direction) == 0 || simd_length(normal) == 0) return nil;
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

- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius {
    return nil;
}

- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius {
    return nil;
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance {
    return nil;
}

- (double)maximumBlendForEdges:(NSArray<NSNumber *> *)edges upTo:(double)limit chamfer:(BOOL)chamfer {
    return 0;
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

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    return [[PCKMesh alloc] initWithBuffers:_fallback.mesh];
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
