#import "PCKShape.h"

#include <cmath>
#include <utility>
#include <vector>

#if __has_include(<BRepPrimAPI_MakeBox.hxx>)
#define PCK_HAS_OCCT 1
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#else
#define PCK_HAS_OCCT 0
#endif

namespace {

struct MeshBuffers {
    std::vector<float> vertices; // x y z nx ny nz
    std::vector<uint32_t> indices;

    uint32_t addVertex(float x, float y, float z, float nx, float ny, float nz) {
        const uint32_t index = static_cast<uint32_t>(vertices.size() / 6);
        vertices.insert(vertices.end(), {x, y, z, nx, ny, nz});
        return index;
    }

    void addQuad(const float p[4][3], const float n[3]) {
        uint32_t i[4];
        for (int k = 0; k < 4; ++k) {
            i[k] = addVertex(p[k][0], p[k][1], p[k][2], n[0], n[1], n[2]);
        }
        indices.insert(indices.end(), {i[0], i[1], i[2], i[0], i[2], i[3]});
    }
};

#if !PCK_HAS_OCCT
// Fallback ohne Kernel: einfache Netze, damit Viewer und UI sofort testbar sind.
MeshBuffers fallbackBox(double w, double d, double h) {
    MeshBuffers m;
    const float x0 = -w / 2, x1 = w / 2, y0 = -d / 2, y1 = d / 2, z0 = 0, z1 = h;
    const float faces[6][4][3] = {
        {{x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}, {x1, y0, z0}},
        {{x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}},
        {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}},
        {{x1, y1, z0}, {x0, y1, z0}, {x0, y1, z1}, {x1, y1, z1}},
        {{x0, y1, z0}, {x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}},
        {{x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}, {x1, y0, z1}},
    };
    const float normals[6][3] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {0, 1, 0}, {-1, 0, 0}, {1, 0, 0}};
    for (int f = 0; f < 6; ++f) {
        m.addQuad(faces[f], normals[f]);
    }
    return m;
}

MeshBuffers fallbackCylinder(double cx, double cy, double cz, double r, double h) {
    MeshBuffers m;
    const int segments = 64;
    const float z0 = cz, z1 = cz + h;
    for (int s = 0; s < segments; ++s) {
        const double a0 = 2 * M_PI * s / segments, a1 = 2 * M_PI * (s + 1) / segments;
        const float c0 = std::cos(a0), s0 = std::sin(a0), c1 = std::cos(a1), s1 = std::sin(a1);
        const uint32_t v0 = m.addVertex(cx + r * c0, cy + r * s0, z0, c0, s0, 0);
        const uint32_t v1 = m.addVertex(cx + r * c1, cy + r * s1, z0, c1, s1, 0);
        const uint32_t v2 = m.addVertex(cx + r * c1, cy + r * s1, z1, c1, s1, 0);
        const uint32_t v3 = m.addVertex(cx + r * c0, cy + r * s0, z1, c0, s0, 0);
        m.indices.insert(m.indices.end(), {v0, v1, v2, v0, v2, v3});
        const uint32_t b = m.addVertex(cx, cy, z0, 0, 0, -1);
        const uint32_t b0 = m.addVertex(cx + r * c0, cy + r * s0, z0, 0, 0, -1);
        const uint32_t b1 = m.addVertex(cx + r * c1, cy + r * s1, z0, 0, 0, -1);
        m.indices.insert(m.indices.end(), {b, b1, b0});
        const uint32_t t = m.addVertex(cx, cy, z1, 0, 0, 1);
        const uint32_t t0 = m.addVertex(cx + r * c0, cy + r * s0, z1, 0, 0, 1);
        const uint32_t t1 = m.addVertex(cx + r * c1, cy + r * s1, z1, 0, 0, 1);
        m.indices.insert(m.indices.end(), {t, t0, t1});
    }
    return m;
}
#endif

} // namespace

@implementation PCKMesh

- (instancetype)initWithBuffers:(const MeshBuffers &)buffers {
    if ((self = [super init])) {
        _vertexData = [NSData dataWithBytes:buffers.vertices.data() length:buffers.vertices.size() * sizeof(float)];
        _indexData = [NSData dataWithBytes:buffers.indices.data() length:buffers.indices.size() * sizeof(uint32_t)];
    }
    return self;
}

@end

@implementation PCKShape {
#if PCK_HAS_OCCT
    TopoDS_Shape _shape;
#else
    MeshBuffers _fallbackMesh;
#endif
}

+ (BOOL)kernelAvailable {
    return PCK_HAS_OCCT;
}

#if PCK_HAS_OCCT

- (instancetype)initWithShape:(const TopoDS_Shape &)shape {
    if ((self = [super init])) {
        _shape = shape;
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    BRepPrimAPI_MakeBox maker(gp_Pnt(-width / 2, -depth / 2, 0), width, depth, height);
    return [[PCKShape alloc] initWithShape:maker.Shape()];
}

+ (PCKShape *)cylinderAtX:(double)x y:(double)y z:(double)z radius:(double)radius height:(double)height {
    BRepPrimAPI_MakeCylinder maker(gp_Ax2(gp_Pnt(x, y, z), gp::DZ()), radius, height);
    return [[PCKShape alloc] initWithShape:maker.Shape()];
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Cut op(_shape, tool->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:op.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    try {
        BRepAlgoAPI_Fuse op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:op.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)filletingAllEdgesWithRadius:(double)radius {
    try {
        BRepFilletAPI_MakeFillet fillet(_shape);
        TopTools_IndexedMapOfShape edges;
        TopExp::MapShapes(_shape, TopAbs_EDGE, edges);
        for (int i = 1; i <= edges.Extent(); ++i) {
            fillet.Add(radius, TopoDS::Edge(edges(i)));
        }
        fillet.Build();
        if (!fillet.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:fillet.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    MeshBuffers buffers;
    BRepMesh_IncrementalMesh mesher(_shape, deflection, Standard_False, 0.35, Standard_True);

    for (TopExp_Explorer explorer(_shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        const TopoDS_Face face = TopoDS::Face(explorer.Current());
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
            buffers.addVertex(p.X(), p.Y(), p.Z(), n.X(), n.Y(), n.Z());
        }
        for (int i = 1; i <= triangulation->NbTriangles(); ++i) {
            int a, b, c;
            triangulation->Triangle(i).Get(a, b, c);
            if (reversed) std::swap(b, c);
            buffers.indices.insert(buffers.indices.end(),
                                   {base + a - 1, base + b - 1, base + c - 1});
        }
    }
    return [[PCKMesh alloc] initWithBuffers:buffers];
}

#else

- (instancetype)initWithFallbackMesh:(MeshBuffers)mesh {
    if ((self = [super init])) {
        _fallbackMesh = std::move(mesh);
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    return [[PCKShape alloc] initWithFallbackMesh:fallbackBox(width, depth, height)];
}

+ (PCKShape *)cylinderAtX:(double)x y:(double)y z:(double)z radius:(double)radius height:(double)height {
    return [[PCKShape alloc] initWithFallbackMesh:fallbackCylinder(x, y, z, radius, height)];
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    return nil;
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)filletingAllEdgesWithRadius:(double)radius {
    return nil;
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    return [[PCKMesh alloc] initWithBuffers:_fallbackMesh];
}

#endif

@end
