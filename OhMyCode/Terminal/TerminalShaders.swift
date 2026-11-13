/// Metal source for the terminal renderer, compiled at runtime (once per launch, ~ms), so
/// building the app doesn't need Xcode's separately downloaded Metal toolchain.
enum TerminalShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Terminal renderer: solid rectangles (cell backgrounds, cursor, underlines) and glyphs from
// an atlas, each drawn as instanced quads. Coordinates are in pixels, origin top-left.

struct Uniforms {
    float2 viewport;
};

struct RectInstance {
    float2 origin;
    float2 size;
    float4 color; // straight alpha
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin; // atlas pixels
    float2 uvSize;
    float4 color;    // straight alpha; ignored for color glyphs (emoji)
    uint isColor;
};

struct RectOut {
    float4 position [[position]];
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint isColor [[flat]];
};

static float4 toClip(float2 pixel, float2 viewport) {
    return float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);
}

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

vertex RectOut rectVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device RectInstance *rects [[buffer(0)]],
                          constant Uniforms &uniforms [[buffer(1)]]) {
    RectInstance r = rects[iid];
    RectOut out;
    out.position = toClip(r.origin + corners[vid] * r.size, uniforms.viewport);
    out.color = float4(r.color.rgb * r.color.a, r.color.a);
    return out;
}

fragment float4 rectFragment(RectOut in [[stage_in]]) {
    return in.color;
}

vertex GlyphOut glyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device GlyphInstance *glyphs [[buffer(0)]],
                            constant Uniforms &uniforms [[buffer(1)]]) {
    GlyphInstance g = glyphs[iid];
    GlyphOut out;
    float2 corner = corners[vid];
    out.position = toClip(g.origin + corner * g.size, uniforms.viewport);
    out.uv = g.uvOrigin + corner * g.uvSize;
    out.color = g.color;
    out.isColor = g.isColor;
    return out;
}

fragment float4 glyphFragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler nearest(coord::pixel, filter::nearest);
    float4 texel = atlas.sample(nearest, in.uv);
    if (in.isColor != 0) {
        return texel; // premultiplied color glyph
    }
    float coverage = texel.a; // mono glyphs are rasterized in white; alpha is the coverage
    return float4(in.color.rgb * in.color.a * coverage, in.color.a * coverage);
}
"""#
}
