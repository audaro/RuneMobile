/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#version 330

//#define FRAG_UVS
//#define ZBUF_DEBUG

#define COLORBLIND_MODE 0

uniform sampler2DArray textures;
uniform float brightness;
uniform float smoothBanding;
uniform vec4 fogColor;
uniform float textureLightMode;

in vec4 fColor;
noperspective centroid in float fHsl;
flat in int fTextureId;
in vec2 fUv;
in float fFogAmount;
#ifdef ZBUF_DEBUG
in float fDepth;
#endif

out vec4 FragColor;

/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

vec3 hslToRgb(vec3 hsl) {
  float hue = hsl.x / 64.0f + 0.0078125f;
  float sat = hsl.y / 8.0f + 0.0625f;
  float lum = hsl.z;

  float var11 = lum / 128.0f;
  float r = var11;
  float g = var11;
  float b = var11;

  float var19;
  if (var11 < 0.5f) {
    var19 = var11 * (1.0f + sat);
  } else {
    var19 = var11 + sat - var11 * sat;
  }

  float var21 = 2.0f * var11 - var19;
  float var23 = hue + 0.3333333333333333f;
  if (var23 > 1.0f) {
    var23 -= 1.f;
  }

  float var27 = hue - 0.3333333333333333f;
  if (var27 < 0.0f) {
    var27 += 1.f;
  }

  if (6.0f * var23 < 1.0f) {
    r = var21 + (var19 - var21) * 6.0f * var23;
  } else if (2.0f * var23 < 1.0f) {
    r = var19;
  } else if (3.0f * var23 < 2.0f) {
    r = var21 + (var19 - var21) * (0.6666666666666666f - var23) * 6.0f;
  } else {
    r = var21;
  }

  if (6.0f * hue < 1.0f) {
    g = var21 + (var19 - var21) * 6.0f * hue;
  } else if (2.0f * hue < 1.0f) {
    g = var19;
  } else if (3.0f * hue < 2.0f) {
    g = var21 + (var19 - var21) * (0.6666666666666666f - hue) * 6.0f;
  } else {
    g = var21;
  }

  if (6.0f * var27 < 1.0f) {
    b = var21 + (var19 - var21) * 6.0f * var27;
  } else if (2.0f * var27 < 1.0f) {
    b = var19;
  } else if (3.0f * var27 < 2.0f) {
    b = var21 + (var19 - var21) * (0.6666666666666666f - var27) * 6.0f;
  } else {
    b = var21;
  }

  return vec3(pow(r, brightness), pow(g, brightness), pow(b, brightness));
}

#if COLORBLIND_MODE > 0
//
// Algorithm from "Analysis of Color Blindness" by Onur Fidaner, Poliang Lin and Nevran Ozguven.
// https://web.archive.org/web/20090731011248/http://scien.stanford.edu/class/psych221/projects/05/ofidaner/project_report.pdf
//

#define PROTAN 1
#define DEUTERAN 2
#define TRITAN 3

// Blends between the original color (0.0) and the fully corrected color (1.0)
uniform float colorblindIntensity;

const mat3 rgb2lms = mat3(vec3(17.8824, 43.5161, 4.11935), vec3(3.45565, 27.1554, 3.86714), vec3(0.0299566, 0.184309, 1.46709));

const mat3 lms2lmsp = mat3(vec3(0.0, 2.02344, -2.52581), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));

const mat3 lms2lmsd = mat3(vec3(1.0, 0.0, 0.0), vec3(0.494207, 0.0, 1.24827), vec3(0.0, 0.0, 1.0));

const mat3 lms2lmst = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(-0.395913, 0.801109, 0.0));

const mat3 corrections = mat3(vec3(0.0, 0.0, 0.0), vec3(0.7, 1.0, 0.0), vec3(0.7, 0.0, 1.0));

vec3 colorblind(vec3 color) {
  vec3 LMS = color * rgb2lms;
  vec3 lms;

#if COLORBLIND_MODE == PROTAN
  lms = LMS * lms2lmsp;  // red deficiency
#elif COLORBLIND_MODE == DEUTERAN
  lms = LMS * lms2lmsd;  // green deficiency
#elif COLORBLIND_MODE == TRITAN
  lms = LMS * lms2lmst;  // blue deficiency
#else
#error 1
#endif

  // LMS to RGB matrix conversion
  mat3 lms2rgb = inverse(rgb2lms);
  vec3 error = lms * lms2rgb;

  // Isolate invisible colors to color vision deficiency (calculate error matrix)
  error = (color - error);

  // Shift colors towards visible spectrum (apply error modifications)
  vec3 correction = error * corrections;
  correction *= clamp(colorblindIntensity / 100.0, 0.0, 1.0);

  // Add compensation to original values
  correction = color + correction;

  return correction;
}
#endif

#ifdef ZBUF_DEBUG
float linear_depth(float depth) {
  // depth is computed as 100/z, solve for z
  float z = 100 / depth;
  return 1 - z / 10000;  // we don't have a far plane, but the client uses 10000
}
#endif

void main() {
  vec4 c;

  if (fTextureId > 0) {
    int textureIdx = fTextureId - 1;

    vec4 textureColor = texture(textures, vec3(fUv, float(textureIdx)));
    vec4 textureColor0 = textureLod(textures, vec3(fUv, float(textureIdx)), 0.f);

    if (textureColor0.a < 1.f)
      discard;

    textureColor = vec4(textureColor.rgb, 1.f);

    textureColor = pow(textureColor, vec4(brightness, brightness, brightness, 1.f));

    // textured triangles hsl is a 7 bit lightness 2-126
    float light = fHsl / 127.f;
    vec3 mul = (1.f - textureLightMode) * vec3(light) + textureLightMode * fColor.rgb;
    c = textureColor * vec4(mul, fColor.a);
  } else {
    // pick interpolated hsl or rgb depending on smooth banding setting
    vec3 hsl = vec3(int(fHsl) >> 10 & 63, int(fHsl) >> 7 & 7, int(fHsl) & 127);
    vec3 rgb = mix(fColor.rgb, hslToRgb(hsl), smoothBanding);
    c = vec4(rgb, fColor.a);
  }

#if COLORBLIND_MODE > 0
  c.rgb = colorblind(c.rgb);
#endif

  vec3 mixedColor = mix(c.rgb, fogColor.rgb, fFogAmount);
  FragColor = vec4(mixedColor, c.a);

#ifdef FRAG_UVS
  if (fTextureId > 0) {
    FragColor = vec4(fUv.x, 0, fUv.y, 1);
  }
#endif

#ifdef ZBUF_DEBUG
  float dc = linear_depth(fDepth);
  if (dc > 1.0) {
    FragColor = vec4(1, 0, 0, 1);
  } else if (dc < -1.0) {
    FragColor = vec4(0, 0, 1, 1);
  } else if (dc < 0.0) {
    FragColor = vec4(0, 1, 0, 1);
  } else {
    FragColor = vec4(dc, dc, dc, 1);
  }
#endif
}
