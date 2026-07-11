/*
 * ===========================================================================================================
 * iOS OVERRIDE (gpu-zone B0.5, materials subsystem). Verbatim copy of ShadowShaderProgram.java @ RLHD 7dded59
 * EXCEPT the materialStore sampler wiring: shadow_vert calls getMaterial() unconditionally in the zone path,
 * so both zone shadow programs need the RGBA32I material-store texture that replaces the UBOMaterials block
 * on iOS (Apple's 16 KB uniform-block cap). See java-overrides MaterialManager + ios-overrides/uniforms/
 * materials.glsl. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
package rs117.hd.opengl.shader;

import java.io.IOException;
import rs117.hd.config.ShadowMode;

import static org.lwjgl.opengl.GL33C.*;
import static rs117.hd.HdPlugin.TEXTURE_UNIT_GAME;
import static rs117.hd.renderer.zone.ZoneRenderer.TEXTURE_UNIT_TEXTURED_FACES;
import static rs117.hd.scene.MaterialManager.TEXTURE_UNIT_MATERIAL_STORE;

public abstract class ShadowShaderProgram extends ShaderProgram {
	protected final UniformTexture uniTextureArray = addUniformTexture("textureArray");
	protected final UniformTexture uniTextureFaces = addUniformTexture("textureFaces");
	protected final UniformTexture uniMaterialStore = addUniformTexture("materialStore");

	protected ShadowMode mode;

	ShadowShaderProgram() {
		super(t -> t
			.add(GL_VERTEX_SHADER, "shadow_vert.glsl")
			.add(GL_FRAGMENT_SHADER, "shadow_frag.glsl"));
	}

	@Override
	protected void initialize() {
		uniTextureArray.set(TEXTURE_UNIT_GAME);
		uniTextureFaces.set(TEXTURE_UNIT_TEXTURED_FACES);
		uniMaterialStore.set(TEXTURE_UNIT_MATERIAL_STORE);
	}

	@Override
	public void compile(ShaderIncludes includes) throws ShaderException, IOException {
		super.compile(includes.copy().define("SHADOW_MODE", mode));
	}

	public static class Fast extends ShadowShaderProgram {
		public Fast() {
			mode = ShadowMode.FAST;
			uniTextureArray.ignoreMissing = true;
		}
	}

	public static class Detailed extends ShadowShaderProgram {
		public Detailed() {
			mode = ShadowMode.DETAILED;
		}
	}

	public static class Legacy extends ShadowShaderProgram {
		public Legacy setMode(ShadowMode mode) {
			this.mode = mode;
			uniTextureArray.ignoreMissing = mode != ShadowMode.DETAILED;
			return this;
		}

		@Override
		public void compile(ShaderIncludes includes) throws ShaderException, IOException {
			if (mode == ShadowMode.DETAILED) {
				shaderTemplate.add(GL_GEOMETRY_SHADER, "shadow_geom.glsl");
			} else {
				shaderTemplate.remove(GL_GEOMETRY_SHADER);
			}
			super.compile(includes);
		}
	}
}
