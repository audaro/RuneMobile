/*
 * ===========================================================================================================
 * iOS OVERRIDE (gpu-zone B0.5, materials subsystem). Verbatim copy of SceneShaderProgram.java @ RLHD 7dded59
 * EXCEPT the materialStore sampler wiring: on iOS the shaders read material data from an RGBA32I texture
 * instead of the UBOMaterials uniform block (Apple's 16 KB uniform-block cap). See java-overrides
 * MaterialManager + ios-overrides/uniforms/materials.glsl. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
package rs117.hd.opengl.shader;

import static org.lwjgl.opengl.GL33C.*;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_GAME;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_SHADOW_MAP;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_TILED_LIGHTING_MAP;
import static rs117.hd.renderer.zone.ZoneRenderer.TEXTURE_UNIT_TEXTURED_FACES;
import static rs117.hd.scene.MaterialManager.TEXTURE_UNIT_MATERIAL_STORE;

public class SceneShaderProgram extends ShaderProgram {
	protected final UniformTexture uniTextureArray = addUniformTexture("textureArray");
	protected final UniformTexture uniShadowMap = addUniformTexture("shadowMap");
	protected final UniformTexture uniTiledLightingTextureArray = addUniformTexture("tiledLightingArray");
	protected final UniformTexture uniTextureFaces = addUniformTexture("textureFaces");
	protected final UniformTexture uniMaterialStore = addUniformTexture("materialStore");

	public SceneShaderProgram() {
		super(t -> t
			.add(GL_VERTEX_SHADER, "scene_vert.glsl")
			.add(GL_FRAGMENT_SHADER, "scene_frag.glsl"));
		uniTiledLightingTextureArray.ignoreMissing = true;
	}

	@Override
	protected void initialize() {
		uniTextureArray.set(TEXTURE_UNIT_GAME);
		uniShadowMap.set(TEXTURE_UNIT_SHADOW_MAP);
		uniTiledLightingTextureArray.set(TEXTURE_UNIT_TILED_LIGHTING_MAP);
		uniTextureFaces.set(TEXTURE_UNIT_TEXTURED_FACES);
		uniMaterialStore.set(TEXTURE_UNIT_MATERIAL_STORE);
	}

	public static class Legacy extends SceneShaderProgram {
		Legacy() {
			shaderTemplate.add(GL_GEOMETRY_SHADER, "scene_geom.glsl");
			uniTextureFaces.ignoreMissing = true;
		}
	}
}
