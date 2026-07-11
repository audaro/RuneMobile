/*
 * GPU B1 — shader assembler.
 *
 * Uses RuneLite's OWN net.runelite.client.plugins.gpu.template.Template to expand the base `gpu` plugin's
 * shader sources EXACTLY as GpuPlugin.initProgram() would (same #include resolution, same token substitutions:
 * TEXTURE_COUNT=256, SAMPLING_MODE=0 (NEAREST), COLORBLIND_MODE=0). The output is the verbatim desktop-GLSL
 * (#version 330) string the plugin hands to glShaderSource — the byte-authentic input to the iOS GLSL ES 3.00
 * downport. We deliberately do the include expansion with the real Template (not a reimplementation) so the
 * Simulator probe tests the ACTUAL shaders, not an approximation.
 *
 * Note: Template.process() resolves every `#include` line unconditionally (it does not understand `#if`), so the
 * assembled UI sources still contain the inlined scale/* and colorblind fragments — wrapped in `#if` blocks that
 * the GLSL preprocessor discards at SAMPLING_MODE=0 / COLORBLIND_MODE=0. This matches the live plugin exactly.
 */
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import net.runelite.client.plugins.gpu.template.Template;

public class ShaderAssemble
{
	static final int TEXTURE_COUNT = 256; // TextureManager.TEXTURE_COUNT
	static final String BASE = "/net/runelite/client/plugins/gpu/";

	public static void main(String[] args) throws Exception
	{
		String outDir = args.length > 0 ? args[0] : "assembled";
		Files.createDirectories(Paths.get(outDir));

		// PROGRAM = vert+frag (scene), UI_PROGRAM = vertui+fragui (GpuPlugin.java:143-149)
		String[] files = {"vert.glsl", "frag.glsl", "vertui.glsl", "fragui.glsl"};

		for (String f : files)
		{
			Template t = new Template();
			// mirrors GpuPlugin.createTemplate() token map
			t.add(key ->
			{
				switch (key)
				{
					case "texture_config":  return "#define TEXTURE_COUNT " + TEXTURE_COUNT + "\n";
					case "sampling_mode":   return "#define SAMPLING_MODE 0\n";   // SAMPLING_NEAREST
					case "colorblind_mode": return "#define COLORBLIND_MODE 0\n"; // off
				}
				return null;
			});
			// mirrors template.addInclude(GpuPlugin.class) — resolve file resources from the gpu package
			t.add(name ->
			{
				try (InputStream is = ShaderAssemble.class.getResourceAsStream(BASE + name))
				{
					if (is == null)
					{
						return null;
					}
					ByteArrayOutputStream bo = new ByteArrayOutputStream();
					byte[] buf = new byte[4096];
					int n;
					while ((n = is.read(buf)) > 0)
					{
						bo.write(buf, 0, n);
					}
					return new String(bo.toByteArray(), StandardCharsets.UTF_8);
				}
				catch (IOException e)
				{
					return null;
				}
			});

			String src = t.load(f);
			if (src == null || src.isEmpty())
			{
				throw new IllegalStateException("empty assembly for " + f + " (resource missing on classpath?)");
			}
			String out = f.replace(".glsl", ".assembled.glsl");
			Files.write(Paths.get(outDir, out), src.getBytes(StandardCharsets.UTF_8));
			System.out.println("assembled " + f + " -> " + out + " (" + src.length() + " chars, "
				+ src.split("\n").length + " lines)");
		}
		System.out.println("OK");
	}
}
