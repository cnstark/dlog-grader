#include <metal_stdlib>
using namespace metal;

struct LUTParameters {
    float3 domainMin;
    float3 domainMax;
    uint size;
};

kernel void applyLUT(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> destination [[texture(1)]],
                     texture3d<float, access::sample> lut [[texture(2)]],
                     constant LUTParameters &parameters [[buffer(0)]],
                     uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= destination.get_width() || pixel.y >= destination.get_height()) return;
    float4 rgba = source.read(pixel);
    float3 normalized = clamp((rgba.rgb - parameters.domainMin) /
                              (parameters.domainMax - parameters.domainMin), 0.0f, 1.0f);
    float n = float(parameters.size);
    float3 coordinate = (normalized * (n - 1.0f) + 0.5f) / n;
    constexpr sampler trilinear(coord::normalized, address::clamp_to_edge, filter::linear);
    destination.write(float4(lut.sample(trilinear, coordinate).rgb, rgba.a), pixel);
}
