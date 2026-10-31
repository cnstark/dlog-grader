#include <metal_stdlib>
using namespace metal;

static float dlog2_to_lin(float input) {
    const float H = 475.0f, a = 16.285770761945304f;
    const float k1 = 0.059439938321493f, b1 = 0.304985337243402f;
    const float k2 = 2.960935245492250f, b2 = 0.148314799066323f;
    const float in_limit2 = 0.028961695254132f;
    if (input >= b1) return H / (exp2(a) - 1.0f) * (exp2(a * input) - 1.0f);
    if (input >= b2) return exp2((input - b1) / k1 + log2(0.18f));
    return (input - b2) / k2 + in_limit2;
}

static float soft_knee(float value) {
    // Identity through 0.8, then approaches 1 with continuous first derivative.
    if (value <= 0.8f) return value;
    float excess = value - 0.8f;
    return 0.8f + 0.2f * excess / (0.2f + excess);
}

static float hlg_oetf(float E) {
    const float a = 0.17883277f, b = 0.28466892f, c = 0.55991073f;
    return E <= 1.0f / 12.0f ? sqrt(3.0f * E) : a * log(12.0f * E - b) + c;
}

static uint hash32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    return x ^ (x >> 16);
}

kernel void applyHLG(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> destination [[texture(1)]],
                     uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= destination.get_width() || pixel.y >= destination.get_height()) return;
    float4 input = source.read(pixel);
    float3 linear = float3(dlog2_to_lin(input.r), dlog2_to_lin(input.g), dlog2_to_lin(input.b));

    // xy -> XYZ columns (x/y, 1, (1-x-y)/y), scaled so RGB=(1,1,1) is D65
    // (0.3127, 0.3290). Camera xy: R(.7346787,.2653213),
    // G(.15996793,.84003207), B(.08999182,-.07999273).
    // Multiply camera RGB->XYZ by inverse BT.2020 RGB->XYZ, whose primaries are
    // R(.708,.292), G(.170,.797), B(.131,.046), also normalized to D65.
    const float3 r = float3( 1.098802168139f, -0.057361131050f,  0.001517723000f);
    const float3 g = float3(-0.024111347891f,  1.248432299240f, -0.033032375409f);
    const float3 b = float3(-0.074690820248f, -0.191071168190f,  1.031514652408f);
    float3 E = (r * linear.r + g * linear.g + b * linear.b) * 0.265f;

    // Roll luminance toward HLG peak, then compress chroma diagonally toward
    // the BT.2020 luminance axis. Both knees begin before the gamut boundary.
    float Y = dot(E, float3(0.2627f, 0.6780f, 0.0593f));
    float targetY = soft_knee(max(Y, 0.0f));
    float3 chroma = E - Y;
    float upper = max(max(chroma.r, chroma.g), chroma.b) / max(1.0f - targetY, 1e-6f);
    float lower = -min(min(chroma.r, chroma.g), chroma.b) / max(targetY, 1e-6f);
    float reach = max(upper, lower);
    float scale = reach > 0.8f ? soft_knee(reach) / reach : 1.0f;
    E = clamp(targetY + chroma * scale, 0.0f, 1.0f);
    float3 encoded = float3(hlg_oetf(E.r), hlg_oetf(E.g), hlg_oetf(E.b));

    // Two independent uniforms form TPDF noise in [-1,1] output 10-bit LSB.
    uint seed = pixel.x * 0x9e3779b9u ^ pixel.y * 0x85ebca6bu;
    float3 noise;
    for (uint channel = 0; channel < 3; ++channel) {
        float u = float(hash32(seed ^ (channel * 2u + 1u))) * (1.0f / 4294967295.0f);
        float v = float(hash32(seed ^ (channel * 2u + 2u))) * (1.0f / 4294967295.0f);
        noise[channel] = (u - v) * (1.0f / 1023.0f);
    }
    destination.write(float4(clamp(encoded + noise, 0.0f, 1.0f), input.a), pixel);
}
