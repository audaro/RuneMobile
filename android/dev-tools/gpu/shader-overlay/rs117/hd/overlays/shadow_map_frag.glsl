#version 330

uniform sampler2D shadowMap;

in vec2 fUv;

out vec4 FragColor;

void main() {
    // GLSL-ES fix (COMPAT-01): the int literal 1 in this float vec4 constructor is rejected by strict GLSL ES
    // ('const int' -> 'float'); upstream's #version 330 accepts it. Use a float literal.
    FragColor = vec4(texture(shadowMap, fUv).rrr, 1.0);
}
