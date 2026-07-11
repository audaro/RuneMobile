package rs117.hd.opengl.uniforms;

import rs117.hd.utils.buffer.GLBuffer;

import static org.lwjgl.opengl.GL33C.*;

/*
 * ===========================================================================================================
 * iOS OVERRIDE (gpu-zone B1, tiled lighting). Verbatim copy of rs117/hd/opengl/uniforms/UBOLights.java @ RLHD
 * 7dded59 with ONE change: MAX_LIGHTS 1000 -> 480.
 *
 * WHY: with tiled lighting the scene shader's UBOLights block is sized at MAX_LIGHT_COUNT = UBOLights.MAX_LIGHTS
 * (HdPlugin.getShaderIncludes: `configTiledLighting ? UBOLights.MAX_LIGHTS : getMaxSceneLights()`). The struct is
 * 32 B (position vec4 + color vec4 std140 — the "64 Bytes" comment was stale), so 1000 lights = 32000 B, OVER
 * Apple's 16 KB uniform-block cap -> the scene program fails to link (same failure mode as the 57 KB UBOMaterials).
 * 480 lights = 15360 B, comfortably under the cap, so tiled lighting works WITHOUT a texture-backed light store
 * (UBOLightsCulling at 480 = 7680 B also fits). 480 scene-wide lights is ~10x the non-tiled cap (50) and covers
 * all but the most pathologically dense scenes. Reducing this Java constant also flows to the shader define, so
 * the Java light buffer and the shader array stay the same size (no out-of-bounds index from the tile data).
 *
 * RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
public class UBOLights extends UniformBuffer<GLBuffer> {

	public static final int MAX_LIGHTS = 480; // iOS: fits the 16 KB UBO cap (480 * 32 B = 15360 B); was 1000

	private final LightStruct[] lights;
	private final Property[] lightPositions;

	public UBOLights(boolean isCullingUBO) {
		super(GL_DYNAMIC_DRAW);
		lightPositions = isCullingUBO ? addPropertyArray(PropertyType.FVec4, "lightPositions", MAX_LIGHTS) : null;
		lights = !isCullingUBO ? addStructs(new LightStruct[MAX_LIGHTS], LightStruct::new) : null;
	}

	@Override
	public String getUniformBlockName() {
		return lights != null ? "UBOLights" : "UBOLightsCulling";
	}

	public void setLight(int lightIdx, float[] position, float[] color) {
		if (lightIdx >= 0 && lightIdx < MAX_LIGHTS) {
			if (lights != null) {
				var struct = lights[lightIdx];
				struct.position.set(position);
				struct.color.set(color);
			} else {
				lightPositions[lightIdx].set(position);
			}
		}
	}

	public static class LightStruct extends UniformBuffer.StructProperty {
		public Property position = addProperty(PropertyType.FVec4, "position");
		public Property color = addProperty(PropertyType.FVec4, "color");
	}
}
