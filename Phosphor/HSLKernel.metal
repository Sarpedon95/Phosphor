#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Per-channel HSL adjustment kernel.
//
// `params` carries 24 floats — 8 colour ranges × (hue, sat, lum). They are
// delivered as 6 float4s packed by the Swift wrapper:
//   params0 = (redH, redS, redL, orangeH)
//   params1 = (orangeS, orangeL, yellowH, yellowS)
//   params2 = (yellowL, greenH, greenS, greenL)
//   params3 = (aquaH, aquaS, aquaL, blueH)
//   params4 = (blueS, blueL, purpleH, purpleS)
//   params5 = (purpleL, magentaH, magentaS, magentaL)
//
// Each range gets a Gaussian weight by hue proximity (sigma ≈ 0.08, ~30°
// half-width) so adjacent colours blend smoothly rather than banding.

static float3 rgb2hsl(float3 c) {
    float maxc = max(c.r, max(c.g, c.b));
    float minc = min(c.r, min(c.g, c.b));
    float l = (maxc + minc) * 0.5;
    float h = 0.0;
    float s = 0.0;
    float d = maxc - minc;
    if (d > 1e-5) {
        s = l > 0.5 ? d / (2.0 - maxc - minc) : d / (maxc + minc);
        if (maxc == c.r) {
            h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        } else if (maxc == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
        h /= 6.0;
    }
    return float3(h, s, l);
}

static float hue2rgb(float p, float q, float t) {
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
    if (t < 1.0/2.0) return q;
    if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
    return p;
}

static float3 hsl2rgb(float3 hsl) {
    float h = hsl.x, s = hsl.y, l = hsl.z;
    if (s < 1e-5) {
        return float3(l, l, l);
    }
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(
        hue2rgb(p, q, h + 1.0/3.0),
        hue2rgb(p, q, h),
        hue2rgb(p, q, h - 1.0/3.0)
    );
}

static float hueWeight(float hue, float center) {
    // Wrap-around distance on the hue circle.
    float d = fabs(hue - center);
    d = min(d, 1.0 - d);
    float sigma = 0.08;
    return exp(-0.5 * (d * d) / (sigma * sigma));
}

extern "C" {
    float4 hslAdjust(coreimage::sample_t s,
                     float4 params0, float4 params1, float4 params2,
                     float4 params3, float4 params4, float4 params5) {
        float3 rgb = float3(s.r, s.g, s.b);
        float3 hsl = rgb2hsl(rgb);

        // Centre hues, normalized 0–1.
        const float centers[8] = {
            0.0,    // red
            0.083,  // orange
            0.167,  // yellow
            0.333,  // green
            0.5,    // aqua
            0.667,  // blue
            0.75,   // purple
            0.875   // magenta
        };

        float hueAdj[8] = {
            params0.x, params0.w, params1.z, params2.y,
            params3.x, params3.w, params4.z, params5.y
        };
        float satAdj[8] = {
            params0.y, params1.x, params1.w, params2.z,
            params3.y, params4.x, params4.w, params5.z
        };
        float lumAdj[8] = {
            params0.z, params1.y, params2.x, params2.w,
            params3.z, params4.y, params5.x, params5.w
        };

        float dH = 0.0, dS = 0.0, dL = 0.0;
        for (int i = 0; i < 8; i++) {
            float w = hueWeight(hsl.x, centers[i]);
            dH += w * hueAdj[i];
            dS += w * satAdj[i];
            dL += w * lumAdj[i];
        }

        hsl.x = fract(hsl.x + dH);
        hsl.y = clamp(hsl.y + dS, 0.0, 1.0);
        hsl.z = clamp(hsl.z + dL, 0.0, 1.0);

        float3 outRGB = hsl2rgb(hsl);
        return float4(outRGB, s.a);
    }
}
