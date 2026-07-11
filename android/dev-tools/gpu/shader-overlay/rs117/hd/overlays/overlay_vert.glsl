#version 330

uniform vec4 transform;

layout (location = 0) in vec2 vPos;
layout (location = 1) in vec2 vUv;

out vec2 fUv;

void main() {
    vec2 translation = transform.xy;
    vec2 scale = transform.zw;
    // GLSL-ES fix (COMPAT-01): strict GLSL ES rejects the int literals 0/1 in this float vec4 constructor
    // ('const int' -> 'float'); upstream's #version 330 accepts them. Use float literals. The rc_downport pass
    // handles version/precision but not int->float typing, so the fix lives here in the shader-overlay.
    gl_Position = vec4(vPos * scale + translation, 0.0, 1.0);
    fUv = vUv;
}
