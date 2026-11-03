#include <metal_stdlib>
using namespace metal;

// Coordinate system:
// - texture axes: continuous voxel coordinates normalized to [0,1]^3
// - world: ARKit meters, or the camera-free Studio's local meters
// - clip Z: Metal [0,1]; 3D texture contents are true CT/MRI scalar voxels.
// This is research visualization, NOT a medically segmented 3D anatomy.
struct VolumeUniforms {
    float4x4 inverseViewProjection;
    float4x4 worldToTexture;
    float4x4 worldToCamera;
    float4 depthAffineU; // a, c, tx, unused (viewport UV -> depth UV)
    float4 depthAffineV; // b, d, ty, unused
    float4 window;       // low, high, normalized threshold, opacity gain
    uint4 options;       // rendering mode, max samples, scene depth active, unused
};
struct FullscreenOutput {
    float4 position [[position]];
    float2 uv;
};
vertex FullscreenOutput neuroVolumeVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)
    };
    FullscreenOutput result;
    float2 p = positions[vertexID];
    result.position = float4(p, 0.0, 1.0);
    result.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return result;
}

float2 rayCubeInterval(float3 origin, float3 direction) {
    float3 nonzero = select(direction, float3(
        direction.x < 0 ? -1e-6 : 1e-6,
        direction.y < 0 ? -1e-6 : 1e-6,
        direction.z < 0 ? -1e-6 : 1e-6), abs(direction) < 1e-6);
    float3 a = (float3(0.0) - origin) / nonzero;
    float3 b = (float3(1.0) - origin) / nonzero;
    float3 low = min(a, b);
    float3 high = max(a, b);
    return float2(max(max(low.x, low.y), low.z),
                  min(min(high.x, high.y), high.z));
}

float3 volumeColor(float t, uint mode) {
    // Neutral clinical grayscale to highlight dense structures; subtle cyan
    // for the lower-valued translucent tissue. Not tissue classification.
    float3 cyan = float3(0.12, 0.69, 0.86);
    float3 pearl = float3(0.96, 0.93, 0.82);
    if (mode == 1) { return float3(t); }
    return mix(cyan, pearl, smoothstep(0.25, 0.88, t));
}

fragment float4 neuroVolumeFragment(FullscreenOutput input [[stage_in]],
                                   texture3d<float, access::sample> voxels [[texture(0)]],
                                   texture2d<float, access::sample> depthMeters [[texture(1)]],
                                   constant VolumeUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(coord::normalized, address::clamp_to_edge,
                                 filter::linear, mip_filter::none);
    constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge,
                                   filter::linear, mip_filter::none);
    float2 ndc = float2(2.0 * input.uv.x - 1.0, 1.0 - 2.0 * input.uv.y);
    float4 nearH = uniforms.inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 farH = uniforms.inverseViewProjection * float4(ndc, 1.0, 1.0);
    if (abs(nearH.w) < 1e-8 || abs(farH.w) < 1e-8) { return float4(0); }
    float3 worldNear = nearH.xyz / nearH.w;
    float3 worldFar = farH.xyz / farH.w;
    float3 origin = (uniforms.worldToTexture * float4(worldNear, 1.0)).xyz;
    float3 farTex = (uniforms.worldToTexture * float4(worldFar, 1.0)).xyz;
    float3 projectedRay = farTex - origin;
    float rayDistance = length(projectedRay);
    if (rayDistance < 1e-6) { return float4(0); }
    float3 direction = projectedRay / rayDistance;
    float2 interval = rayCubeInterval(origin, direction);
    float t0 = max(interval.x, 0.0);
    float t1 = min(interval.y, rayDistance);
    if (t1 <= t0) { return float4(0); }

    float sceneDepth = 0;
    if (uniforms.options.z != 0) {
        float u = dot(uniforms.depthAffineU.xyz, float3(input.uv, 1));
        float v = dot(uniforms.depthAffineV.xyz, float3(input.uv, 1));
        if (u >= 0 && u <= 1 && v >= 0 && v <= 1) {
            sceneDepth = depthMeters.sample(depthSampler, float2(u,v)).r;
        }
    }
    // ARKit scene depth reports camera-Z distance, not Euclidean range.
    float viewZ0 = -(uniforms.worldToCamera * float4(worldNear, 1)).z;
    float viewZ1 = -(uniforms.worldToCamera * float4(worldFar, 1)).z;

    const float invWindow = 1.0 / max(1e-5, uniforms.window.y - uniforms.window.x);
    float threshold = clamp(uniforms.window.z, 0.0, 0.99);
    float gain = clamp(uniforms.window.w, 0.05, 4.0);
    uint mode = uniforms.options.x;
    uint steps = clamp(uniforms.options.y, 24u, 256u);
    // Fixed bounded budget makes performance predictable on an iPhone.
    float stepSize = (t1 - t0) / float(steps);
    float4 acc = float4(0);
    float maximum = 0.0;
    float3 lastPos = origin + direction * t0;
    float previous = (voxels.sample(texSampler, lastPos).r - uniforms.window.x) * invWindow;

    for (uint index = 0; index < steps; index++) {
        float t = t0 + (float(index) + 0.5) * stepSize;
        float cameraDepth = mix(viewZ0, viewZ1, clamp(t / rayDistance, 0.0, 1.0));
        if (sceneDepth > 0.05 && cameraDepth > sceneDepth + 0.025) { break; }
        float3 pos = origin + direction * t;
        float rawValue = voxels.sample(texSampler, pos).r;
        float normalized = clamp((rawValue - uniforms.window.x) * invWindow, 0.0, 1.0);

        if (mode == 1) {
            maximum = max(maximum, normalized);
        } else if (mode == 2) {
            if (previous < threshold && normalized >= threshold) {
                float3 spacing = 1.0 / float3(max(voxels.get_width(), 2u),
                                              max(voxels.get_height(), 2u),
                                              max(voxels.get_depth(), 2u));
                float gx = voxels.sample(texSampler, pos + float3(spacing.x,0,0)).r -
                           voxels.sample(texSampler, pos - float3(spacing.x,0,0)).r;
                float gy = voxels.sample(texSampler, pos + float3(0,spacing.y,0)).r -
                           voxels.sample(texSampler, pos - float3(0,spacing.y,0)).r;
                float gz = voxels.sample(texSampler, pos + float3(0,0,spacing.z)).r -
                           voxels.sample(texSampler, pos - float3(0,0,spacing.z)).r;
                float3 normal = normalize(float3(gx,gy,gz) + float3(1e-6));
                float shading = 0.35 + 0.65 * abs(dot(normal, -direction));
                return float4(volumeColor(normalized, mode) * shading, 0.94);
            }
        } else {
            float density = smoothstep(threshold, min(1.0, threshold+0.32), normalized);
            float alpha = clamp(gain * density * 0.082, 0.0, 0.27);
            float3 color = volumeColor(normalized, mode);
            acc.rgb += color * alpha * (1.0 - acc.a);
            acc.a += alpha * (1.0 - acc.a);
            if (acc.a > 0.985) { break; }
        }
        previous = normalized;
        lastPos = pos;
    }
    if (mode == 1) {
        float opacity = smoothstep(threshold, min(1.0, threshold+0.24), maximum);
        return float4(volumeColor(maximum, mode), 0.91 * opacity);
    }
    if (mode == 2) { return float4(0); }
    return acc.a > 0.005 ? float4(acc.rgb / max(acc.a, 1e-5), acc.a) : float4(0);
}
