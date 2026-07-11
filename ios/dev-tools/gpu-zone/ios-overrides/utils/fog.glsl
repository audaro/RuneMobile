/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone Z0). Verbatim copy of rs117/hd/utils/fog.glsl @ RLHD 7dded59 EXCEPT every
 * int-in-float-context is made explicit (blueprint #13): TILE_SIZE (a `#define 128`) is cast to float at each
 * float use, the FOG_SCENE_EDGE_* macros are made float, the integer `useFog` uniform is cast, and int literal
 * args to clamp/max/fogFactorLinear are floats. Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
#include <uniforms/global.glsl>

#define TILE_SIZE 128
#define FOG_SCENE_EDGE_MIN (float((    - expandedMapLoadingChunks * 8 + 1) * TILE_SIZE))
#define FOG_SCENE_EDGE_MAX (float((104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE))
#define FOG_CORNER_ROUNDING 1.5
#define FOG_CORNER_ROUNDING_SQUARED FOG_CORNER_ROUNDING * FOG_CORNER_ROUNDING

float fogFactorLinear(const float dist, const float start, const float end) {
    return 1.0 - clamp((dist - start) / (end - start), 0.0, 1.0);
}

float calculateFogAmount(vec3 position) {
    if (fogDepth == 0.0)
        return 0.f;

    float drawDistance2 = drawDistance * float(TILE_SIZE);

    // the client draws one less tile to the north and east than it does to the south
    // and west, so subtract a tile's width from the north and east edges.
    float fogWest = max(FOG_SCENE_EDGE_MIN, cameraPos.x - drawDistance2);
    float fogEast = min(FOG_SCENE_EDGE_MAX, cameraPos.x + drawDistance2 - float(TILE_SIZE));
    float fogSouth = max(FOG_SCENE_EDGE_MIN, cameraPos.z - drawDistance2);
    float fogNorth = min(FOG_SCENE_EDGE_MAX, cameraPos.z + drawDistance2 - float(TILE_SIZE));

    // Calculate distance from the scene edge
    float xDist = min(position.x - fogWest, fogEast - position.x);
    float zDist = min(position.z - fogSouth, fogNorth - position.z);
    float nearestEdgeDistance = min(xDist, zDist);
    float secondNearestEdgeDistance = max(xDist, zDist);
    float fogDistance = nearestEdgeDistance
        - FOG_CORNER_ROUNDING * float(TILE_SIZE) * max(0.0,
            (nearestEdgeDistance + FOG_CORNER_ROUNDING_SQUARED)
            / (secondNearestEdgeDistance + FOG_CORNER_ROUNDING_SQUARED)
        );

    // This is different from the GPU plugin, and seems to have worked this way from the start
    float edgeFogAmount = fogFactorLinear(fogDistance, 0.0, 5.0 * float(TILE_SIZE)) * float(useFog);

    // Use a combination of two different methods of calculating distance fog.
    // The is super arbitrary and is only eyeballed to provide a similar overall
    // appearance between equal fog depths at different draw distances.

    float fogStart1 = drawDistance2 * 0.85;
    float distance1 = length(cameraPos.xz - position.xz);
    float distanceFogAmount1 = clamp((distance1 - fogStart1) / (drawDistance2 * .15), 0.0, 1.0);

    float minFogStart = 0.0;
    float maxFogStart = 0.3;
    drawDistance2 = min(drawDistance, 90.0) * float(TILE_SIZE);
    float fogDepthMultiplier = clamp(fogDepth, 0.0, 1000.0) / 1000.0;
    float fogStart2 = (maxFogStart - (fogDepthMultiplier * (maxFogStart - minFogStart))) * drawDistance2;
    float camToVertex = length(cameraPos - vec3(position.x, (position.y + cameraPos.y) / 2.0, position.z));
    float distance2 = max(camToVertex - fogStart2, 0.0) / max(drawDistance2 - fogStart2, 1.0);
    float density = fogDepth / 100.0;
    float distanceFogAmount2 = 1.0 - clamp(exp(-distance2 * density), 0.0, 1.0);

    // Combine distance fogs
    float distanceFogAmount = max(distanceFogAmount1, distanceFogAmount2);

    // Combine distance fog with edge fog
    return max(distanceFogAmount, edgeFogAmount);
}
