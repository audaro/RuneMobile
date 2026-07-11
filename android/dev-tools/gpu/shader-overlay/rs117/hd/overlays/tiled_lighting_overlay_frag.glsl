#version 330

// GLSL-ES fix (COMPAT-01): upstream's #version 330 accepts int literals in float contexts (e.g. fUv * 2,
// vec4(..., 1), float = 1, int/float division); strict GLSL ES rejects the implicit 'int' -> 'float'. Every
// such literal below is made an explicit float (2.0 / 1.0 / 0.0) and the int/float divide is wrapped in
// float(...). The rc_downport pass handles version/precision but not int->float typing, so the fix lives here.
// Also: tiledLightingResolution / sceneResolution are ivec2 uniforms (uniforms/global.glsl), so `fUv * <them>`
// is a vec2 x ivec2 arithmetic-type mismatch that strict ES rejects (the device matrix self-test surfaced this
// at 0:194 'vec2'/'ivec2'); each is wrapped in vec2(...). This bug was invisible until the overlay was forced
// to compile on a real driver — it never activates in a default run (tiled-lighting is feature-gated off).

//#define DEBUG_LIGHT_RADIUS_PADDING

#include <uniforms/global.glsl>
#include <uniforms/lights.glsl>

uniform usampler2DArray tiledLightingArray;

#include <utils/constants.glsl>

in vec2 fUv;

out vec4 FragColor;

void main() {
    vec2 texelCenter = (floor(fUv * vec2(tiledLightingResolution)) + .5) / vec2(tiledLightingResolution);

    const float eps = 1e-10;
    vec2 ndcUv = fUv * 2.0 - 1.0;
    vec4 farPos = invProjectionMatrix * vec4(ndcUv, eps, 1.0);
    vec3 viewDir = normalize(farPos.xyz / farPos.w);

    vec4 c = vec4(0.0);

    ivec2 tileXY = ivec2(floor(fUv * vec2(tiledLightingResolution)));
    int tiledLightCount = 0;
    for (int tileLayer = 0; tileLayer < TILED_LIGHTING_LAYER_COUNT; tileLayer++) {
        uvec4 tileLayerData = texelFetch(tiledLightingArray, ivec3(tileXY, tileLayer), 0);
        for (int c = 0; c < 4; c++) {
            if (tileLayerData[c] <= 0u)
                break;

            ivec2 unpacked = decodePackedLight(tileLayerData[c]);
            if (unpacked[0] >= 0) tiledLightCount++;
            if (unpacked[1] >= 0) tiledLightCount++;
        }
    }

    if (tiledLightCount > 0) {
        if (tiledLightCount < TILED_LIGHTING_MAX_TILE_LIGHT_COUNT) {
            float level = float(tiledLightCount) / float(TILED_LIGHTING_MAX_TILE_LIGHT_COUNT) * HALF_PI;
            c = vec4(sin(level), sin(level * 2.0), cos(level), 0.3);
        } else {
            c = vec4(1.0, 0.0, 1.0, 0.6);
        }
    }

    #ifdef DEBUG_LIGHT_RADIUS_PADDING
        // Render the light as a red sphere
        // When the light passes the central intersection test, the tile is colored green
        // When the light passes the padded intersection test, the tile is colored blue
        // When both tests fail to include the light, the unincluded portion is colored white

        // Draw texel centers
        if (all(equal(floor(fUv * vec2(sceneResolution)), floor(texelCenter * vec2(sceneResolution))))) {
            FragColor = vec4(1.0);
            return;
        }

        for (uint lightIdx = 0u; lightIdx < uint(pointLightsCount); lightIdx++) {
            PointLight light = PointLightArray[lightIdx];
            vec3 lightWorldPos = light.position.xyz;
            float lightRadiusSq = light.position.w;
            vec3 cameraToLight = lightWorldPos - cameraPos;

            // Calculate the distance from the camera to the point closest to the light along the view ray
            float t = dot(cameraToLight, viewDir);
            if (t < 0.0) {
                // If the closest point lies behind the camera, the light can only contribute to the visible
                // scene if the camera happens to be within the light's radius
                if (dot(cameraToLight, cameraToLight) > lightRadiusSq)
                    continue;
                c.g = 1.0;
            } else {
                // High resolution UVs
                vec3 accurateLightToClosestPoint = cameraToLight - t * viewDir;
                float accurateDistSq = dot(accurateLightToClosestPoint, accurateLightToClosestPoint);
                if (accurateDistSq < lightRadiusSq)
                    c.r = 1.0;
            }
        }

        if (length(c) > 0.0 && c.a == 0.0)
            c.a = 1.0;
    #endif

    FragColor = c;
}
