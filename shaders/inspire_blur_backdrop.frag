#version 460 core
#include <flutter/runtime_effect.glsl>

// Maximum number of taps per blur side. Must be a compile-time constant to
// satisfy SkSL loop constraints.
//
// When the blur radius exceeds the tap budget, the sampling stride is
// stretched so the full radius is still covered at a bounded per-pixel cost.
#define MAX_TAPS 16
#define MAX_TAPS_F 16.0

// Minimum sigma below which blur is negligible and skipped.
#define MIN_SIGMA 1.0e-2

// Minimum weight used to avoid division by zero during normalization.
#define MIN_WEIGHT 1.0e-5

out vec4 frag_color;

uniform vec2 u_size;
uniform sampler2D u_texture;

// Gradient map where Red channel controls [0-1] blur strength factor at given pixel.
// Where: 0 — no blur, 1 — full blur.
uniform sampler2D u_blur_texture;

// Blur sigma.
uniform float u_blur_sigma;

// An already normalized (0,1) or (1,0) direction vector.
uniform vec2 u_blur_direction;

// --- Screen position correction ---
uniform vec2 u_area_origin;
uniform vec2 u_area_size;

// --- Transformation ---
uniform vec2 u_transform_scale;
uniform vec2 u_transform_offset;
uniform float u_transform_rotation;
uniform vec2 u_transform_origin;
uniform float u_transform_inversion;

// --- Color adjustment ---
uniform float u_brightness;
uniform float u_contrast;
uniform float u_exposure;
uniform float u_saturation;
uniform float u_vibrance;
uniform float u_color_adjustment_blur_strength;
uniform float u_color_adjustment_non_blur_strength;

vec2 transformUv(vec2 uv) {
  // Move to origin
  uv -= u_transform_origin;

  // Undo translation
  uv -= u_transform_offset;

  // Undo rotation
  float c = cos(-u_transform_rotation);
  float s = sin(-u_transform_rotation);

  uv = mat2(
    c, -s,
    s, c
  ) * uv;

  // Undo scale
  uv /= sign(u_transform_scale) * max(abs(u_transform_scale), vec2(0.0001));

  // Restore origin
  uv += u_transform_origin;

  return uv;
}

vec3 applyPositiveContrastCurve(vec3 x, float k) {
  vec3 s = 1.0 / (1.0 + exp(-k * (x - 0.5)));

  float lo = 1.0 / (1.0 + exp( k * 0.5));
  float hi = 1.0 / (1.0 + exp(-k * 0.5));

  return (s - vec3(lo)) / (hi - lo);
}

vec3 applyNegativeContrastCurve(vec3 x, float p) {
  // Add 0.01 to cut the lower and upper histogram slightly to prevent artifacts.
  vec3 lower = 0.5 * pow(2.0 * (x + 0.01), vec3(p));
  vec3 upper = 1.0 - 0.5 * pow(2.0 * (1.01 - x), vec3(p));

  return mix(lower, upper, step(vec3(0.5), x));
}

vec3 applySaturation(vec3 color, float saturation) {
  float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
  return mix(vec3(luminance), color, saturation);
}

vec3 applyVibrance(vec3 color, float vibrance) {
  float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));

  float maxChannel = max(color.r, max(color.g, color.b));
  float minChannel = min(color.r, min(color.g, color.b));

  float saturation = maxChannel > 1e-5
        ? (maxChannel - minChannel) / maxChannel
        : 0.0;

  float coef = vibrance * (1.0 - saturation);

  return mix(vec3(luminance), color, 1.0 + coef);
}

vec4 applyColorAdjustments(vec4 color, float blurFactor) {
  vec4 original = color;
  float alpha = color.a;

  // Undo premultiplied alpha
  if (alpha > 1e-5) {
    color.rgb /= alpha;
  }

  // 1. Exposure
  if (u_exposure != 0.0) {
    color.rgb *= exp2(u_exposure);
  }

  // 2. Brightness
  if (u_brightness != 0.0) {
    color.rgb += u_brightness * vec3(1.0);
  }

  // 3. Contrast
  if (u_contrast > 1.0) {
    color.rgb = applyPositiveContrastCurve(color.rgb, u_contrast);
  }
  if (u_contrast < 1.0) {
    color.rgb = applyNegativeContrastCurve(clamp(color.rgb, 0.0, 1.0), u_contrast);
  }

  // 4. Saturation
  if (u_saturation != 1.0) {
    color.rgb = applySaturation(color.rgb, u_saturation);
  }

  // 5. Vibrance
  if (u_vibrance != 0.0) {
    color.rgb = applyVibrance(color.rgb, u_vibrance);
  }

  // Premultiply alpha back
  if (alpha > 1e-5) {
    color.rgb *= alpha;
  }

  float nonBlurAreaFactor = (1.0 - blurFactor) * u_color_adjustment_non_blur_strength;
  float blurAreaFactor = blurFactor * u_color_adjustment_blur_strength;
  float adjustmentBlend = clamp(nonBlurAreaFactor + blurAreaFactor, 0.0, 1.0);

  return mix(original, color, adjustmentBlend);
}

void main() {
  vec2 xy = FlutterFragCoord().xy;
  vec2 uv = xy / u_size;
  vec2 texel = 1.0 / u_size;

  vec2 areaXY = xy - u_area_origin;
  vec2 areaTopLeftUV = u_area_origin / u_size;
  vec2 areaBottomRightUV = (u_area_origin + u_area_size) / u_size;

#ifdef IMPELLER_TARGET_OPENGLES
  // 1. Flip the sampling UV
  uv.y = 1.0 - uv.y;

  // 2. Flip and SWAP the bounds. 
  // In GL, the 'Top' of the screen is Y=1.0, and 'Bottom' is Y=0.0.
  float tempTop = 1.0 - areaBottomRightUV.y;
  float tempBottom = 1.0 - areaTopLeftUV.y;
  
  areaTopLeftUV.y = tempTop;
  areaBottomRightUV.y = tempBottom;
#endif

  vec2 areaUV = (uv - areaTopLeftUV) / (areaBottomRightUV - areaTopLeftUV);
  areaUV = clamp(areaUV, vec2(0.0), vec2(1.0));

#ifdef IMPELLER_TARGET_OPENGLES
  areaUV.y = 1.0 - areaUV.y;
#endif

  areaUV = transformUv(areaUV);

  vec4 bg = texture(u_texture, uv);
  float blurFactor = texture(u_blur_texture, areaUV).r;
  blurFactor = mix(
    blurFactor,
    1.0 - blurFactor,
    u_transform_inversion
  );
  blurFactor = clamp(blurFactor, 0.0, 1.0);

  float sigma = u_blur_sigma * blurFactor;

  if (sigma < MIN_SIGMA) {
    if (
      u_color_adjustment_non_blur_strength > 0.0 ||
      u_color_adjustment_blur_strength > 0.0
    ) {
      frag_color = applyColorAdjustments(bg, 0.0);
    } else {
      frag_color = bg;
    }
    return;
  }

  // Blur radius is approximated as 3 * sigma (~99% of Gaussian contribution).
  float radius = 3.0 * sigma;

  // Stretch the sampling stride when the radius exceeds the tap budget.
  // Fractional tap positions are smoothed for free by bilinear filtering.
  float stride = max(1.0, radius / MAX_TAPS_F);
  float taps = min(ceil(radius / stride), MAX_TAPS_F);

  // Incremental Gaussian weights (GPU Gems 3, ch. 40) — avoids evaluating
  // exp() for every tap.
  vec3 g;
  g.x = 1.0;
  g.y = exp(-0.5 * stride * stride / (sigma * sigma));
  g.z = g.y * g.y;

  vec2 texelStep = texel * u_blur_direction * stride;

  // Center tap (weight 1.0).
  float totalWeight = 1.0;
  vec4 totalColor = bg;

  for (int i = 1; i <= MAX_TAPS; i++) {
    if (float(i) > taps) break;

    g.xy *= g.yz;
    float weight = g.x;

    vec2 offset = texelStep * float(i);

    vec2 uvRaw1 = uv + offset;
    vec2 uvRaw2 = uv - offset;

    // Check if inside bounds
    float mask1 =
        step(areaTopLeftUV.x, uvRaw1.x) * step(uvRaw1.x, areaBottomRightUV.x) *
        step(areaTopLeftUV.y, uvRaw1.y) * step(uvRaw1.y, areaBottomRightUV.y);

    float mask2 =
        step(areaTopLeftUV.x, uvRaw2.x) * step(uvRaw2.x, areaBottomRightUV.x) *
        step(areaTopLeftUV.y, uvRaw2.y) * step(uvRaw2.y, areaBottomRightUV.y);

    // Clamp only for safe sampling
    vec2 uv1 = clamp(uvRaw1, areaTopLeftUV, areaBottomRightUV);
    vec2 uv2 = clamp(uvRaw2, areaTopLeftUV, areaBottomRightUV);

    vec4 c1 = texture(u_texture, uv1);
    vec4 c2 = texture(u_texture, uv2);

    float w1 = weight * mask1;
    float w2 = weight * mask2;

    totalColor += c1 * w1 + c2 * w2;
    totalWeight += w1 + w2;
  }

  frag_color = totalColor / max(totalWeight, MIN_WEIGHT);

  if (
    u_color_adjustment_non_blur_strength > 0.0 ||
    u_color_adjustment_blur_strength > 0.0
  ) {
    frag_color = applyColorAdjustments(frag_color, blurFactor);
  }
}
