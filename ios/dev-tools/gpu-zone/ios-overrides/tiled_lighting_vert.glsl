/*
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, tiled lighting). Copy of rs117/hd/tiled_lighting_vert.glsl @ RLHD 7dded59
 * with the int literals in the gl_Position vec4 made explicit float (ES is strict in constructors that mix types
 * across the conversion). Fullscreen-triangle passthrough; logic identical. RE-MERGE on RLHD rev bumps.
 */
#version 330

#include <uniforms/global.glsl>

layout (location = 0) in vec2 vPos;
layout (location = 1) in vec2 vUv;

out vec2 fUv;

void main() {
    gl_Position = vec4(vPos, 0.0, 1.0);
    fUv = vUv;
}
