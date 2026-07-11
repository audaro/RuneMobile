#version 330

uniform sampler2D shadowMap;

in vec2 fUv;

out vec4 FragColor;

void main() {
    // GLSL-ES fix (COMPAT-01): int literals 0/1 in a float vec4 constructor are rejected by strict GLSL ES
    // ('const int' -> 'float'); upstream #version 330 accepts them. Use float literals.
    FragColor = vec4(fUv, 0.0, 1.0);
}
