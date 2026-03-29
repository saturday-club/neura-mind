
#include <metal_stdlib>
using namespace metal;

struct GrainUniforms {
    float time;
    float intensity;
    float2 resolution;
};

kernel void grainKernel(
    texture2d<float, access::write> output [[texture(0)]],
    constant GrainUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uint(uniforms.resolution.x) || gid.y >= uint(uniforms.resolution.y)) {
        return;
    }

    // Monocle-style integer coordinate hash -- crisp per-pixel noise.
    // Uses the same int-to-float pattern found in Monocle's metallib.
    int2 p = int2(gid);
    int n = p.x * 73 + p.y * 137 + 5;
    n = (n << 13) ^ n;
    n = n * (n * n * 15731 + 789221) + 1376312589;
    float noise = float(n & 0x7fffffff) / float(0x7fffffff);

    // Output as gray: values > 0.5 will lighten, < 0.5 will darken
    // when composited with overlay blend mode on the CALayer.
    // Full opacity -- intensity is controlled by the layer's compositingFilter + opacity.
    output.write(float4(noise, noise, noise, 1.0), gid);
}
