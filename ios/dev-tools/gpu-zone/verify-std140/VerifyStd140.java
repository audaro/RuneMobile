// B0.5 materials subsystem — host-side proof that the texelFetch decode map in
// ios-overrides/uniforms/materials.glsl matches the REAL UniformBuffer std140 layout engine byte-for-byte.
// Runs the actual staged RLHD classes (stage-zone-work/rlhd_out) on the desktop JVM: builds a MaterialStruct
// through UniformBuffer.addStruct (no GL calls happen before initialize(), which we never call), reflects the
// computed byte positions, and asserts the 6-RGBA32I-texels-per-material mapping the shader override decodes.
// Run via ./check-std140.sh — verdict STD140_DECODE_MAP_MATCHES / STD140_DECODE_MAP_MISMATCH.

import java.lang.reflect.Field;
import java.util.List;

import rs117.hd.opengl.uniforms.UBOMaterials;
import rs117.hd.opengl.uniforms.UniformBuffer;
import rs117.hd.utils.buffer.GLBuffer;

public class VerifyStd140 {
	static class Probe extends UniformBuffer<GLBuffer> {
		Probe() {
			super(0x88E4 /* GL_STATIC_DRAW */);
		}

		void addMaterial() {
			addStruct(new UBOMaterials.MaterialStruct());
		}
	}

	// field name -> expected std140 byte offset within the 96-byte material stride, per the shader decode:
	// texel = offset/16, component xyzw = (offset%16)/4
	static final String[][] EXPECTED = {
		{ "colorMap", "0" },              // t0.x
		{ "normalMap", "4" },             // t0.y
		{ "displacementMap", "8" },       // t0.z
		{ "roughnessMap", "12" },         // t0.w
		{ "ambientOcclusionMap", "16" },  // t1.x
		{ "flowMap", "20" },              // t1.y
		{ "shadowAlphaMap", "24" },       // t1.z
		{ "flags", "28" },                // t1.w
		{ "brightness", "32" },           // t2.x
		{ "displacementScale", "36" },    // t2.y
		{ "specularStrength", "40" },     // t2.z
		{ "specularGloss", "44" },        // t2.w
		{ "flowMapStrength", "48" },      // t3.x (t3.y = pad)
		{ "flowMapDuration", "56" },      // t3.zw
		{ "scrollDuration", "64" },       // t4.xy (t4.zw = pad)
		{ "textureScale", "80" },         // t5.xyz (t5.w = pad)
	};

	public static void main(String[] args) throws Exception {
		var probe = new Probe();
		probe.addMaterial();
		probe.addMaterial(); // second struct proves the 96-byte array stride (16-byte struct padding)

		Field propsField = UniformBuffer.class.getDeclaredField("properties");
		propsField.setAccessible(true);
		Field sizeField = UniformBuffer.class.getDeclaredField("size");
		sizeField.setAccessible(true);

		var propClass = Class.forName("rs117.hd.opengl.uniforms.UniformBuffer$Property");
		Field nameField = propClass.getDeclaredField("name");
		nameField.setAccessible(true);
		Field posField = propClass.getDeclaredField("position");
		posField.setAccessible(true);

		List<?> props = (List<?>) propsField.get(probe);
		int size = sizeField.getInt(probe);

		boolean ok = true;
		if (props.size() != 2 * EXPECTED.length) {
			System.out.println("!! property count " + props.size() + " != " + 2 * EXPECTED.length);
			ok = false;
		}
		if (size != 192) {
			System.out.println("!! two-struct size " + size + " != 192 (stride must be 96)");
			ok = false;
		}

		for (int s = 0; s < 2 && ok; s++) {
			int base = s * 96;
			for (int i = 0; i < EXPECTED.length; i++) {
				Object prop = props.get(s * EXPECTED.length + i);
				String name = (String) nameField.get(prop);
				int pos = posField.getInt(prop);
				int expected = base + Integer.parseInt(EXPECTED[i][1]);
				String decode = "t" + (pos - base) / 16 + "." + "xyzw".charAt((pos - base) % 16 / 4);
				System.out.printf("struct[%d] %-20s @ %3d  (%s)%n", s, name, pos, decode);
				if (!name.equals(EXPECTED[i][0]) || pos != expected) {
					System.out.println("!! expected " + EXPECTED[i][0] + " @ " + expected);
					ok = false;
				}
			}
		}

		System.out.println("VERDICT = " + (ok ? "STD140_DECODE_MAP_MATCHES" : "STD140_DECODE_MAP_MISMATCH"));
		System.exit(ok ? 0 : 1);
	}
}
