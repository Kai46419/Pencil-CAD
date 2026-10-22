#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float3 normal;
};

struct Uniforms {
    float4x4 viewProjection;
    float4x4 model;
    float3 lightDirection;
    float3 baseColor;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
};

vertex VertexOut vertex_main(const device Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]]) {
    Vertex v = vertices[vid];
    VertexOut out;
    out.position = uniforms.viewProjection * uniforms.model * float4(v.position, 1.0);
    out.normal = (uniforms.model * float4(v.normal, 0.0)).xyz;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float diffuse = abs(dot(n, normalize(uniforms.lightDirection)));
    float3 color = uniforms.baseColor * (0.3 + 0.7 * diffuse);
    return float4(color, 1.0);
}
