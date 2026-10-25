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
#include <TopoDS_Shape.hxx>
#include <gp_Ax1.hxx>
#include <gp_Circ.hxx>
#include <gp_Ax2.hxx>
#include <gp_Elips.hxx>
#include <gp_Trsf.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt2d.hxx>
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
            const size_t n = size_t(code[i++]);
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
            edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(c, gp_Dir(n.X(), n.Y(), n.Z())), r)).Edge();
            break;
        }
        case 4: {
            if (!has(11)) return TopoDS_Wire();
            const gp_Pnt c = point(), n = point(), x = point();
            double rx = code[i++], ry = code[i++];
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

- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    const TopoDS_Face face = TopoDS::Face(_faces(int(index)));
    BRepAdaptor_Surface surface(face);
    if (surface.GetType() != GeomAbs_Plane) return nil;
    const gp_Pln plane = surface.Plane();
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

        for (int i = 1; i <= triangulation->NbNodes(); ++i) {
            const gp_Pnt p = triangulation->Node(i).Transformed(transform);
            gp_Dir n = triangulation->Normal(i);
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
        const TopoDS_Edge edge = TopoDS::Edge(edgeFaces.FindKey(i));
        if (BRep_Tool::Degenerated(edge)) continue;
        bool seam = false;
        for (TopTools_ListIteratorOfListOfShape it(edgeFaces(i)); it.More(); it.Next()) {
            if (BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) seam = true;
        }
        if (seam) continue;
        try {
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

- (nullable PCKShape *)scaledAboutPoint:(simd_double3)center factors:(simd_double3)factors {
    return nil;
}

- (nullable NSArray<PCKShape *> *)splitAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    return nil;
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

- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness {
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

#endif

@end
