// Track G AG2.5-b — the 117HD (RLHD) class-load + loader-data probe. Runs on the embedded HotSpot VM with
// [client-<ver>-gpu.jar (the facade-backed client) + client-<ver>-rlhd.jar] on the classpath, mainClass=RLHDProbe
// (boot mode -Drunelite.rlhdprobe=true; the host does CACIO activation first because RLHD touches java.awt at
// class-init, but skips the bridge/render — this is a headless class-load test, no GL context, no login).
//
// It proves the AG2.5-b gate WITHOUT the full Zone render (that is AG3):
//   1. EVERY rs117.* class in the staged RLHD jar load+links+verifies against our org.lwjgl facade — i.e. no
//      NoClassDefFound / NoSuchMethodError / VerifyError from a missing GL/CL/system symbol. (Loaded with
//      initialize=false so a render-class <clinit> that legitimately needs a live GL context doesn't false-fail
//      the link proof.)
//   2. The OpenCL class-load graph runs its static initializers: OpenCLManager.<clinit> executes
//      Configuration.OPENCL_EXPLICIT_INIT.set(true) (the only thing that runs at class-init on the Zone path),
//      and SharedGLBuffer/UBOCompute/UniformBuffer initialize — the "OpenCL class-load resolved" headline.
//   3. The 9 bundled loader data files (areas/tile_overrides/model_overrides/ground_materials/water_types/
//      lights/environments/gamevals/materials .json) are present on the classpath and parse as well-formed JSON
//      on-device — i.e. the file-I/O loaders' inputs init clean.
//
// Verdict line MEGAVERDICT=ANDROID_RLHD_PROBE_GREEN|NOT_GREEN is grepped from logcat by the gate script.
import com.google.gson.Gson;
import com.google.gson.JsonElement;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

public class RLHDProbe {
	private static final String TAG = "ANDROID_RLHD_PROBE";

	public static void main(String[] args) {
		boolean ok = true;
		ClassLoader cl = ClassLoader.getSystemClassLoader();

		// 1) Full link/verify sweep of every rs117.* class in the staged RLHD jar.
		String rlhdJar = null;
		for (String e : System.getProperty("java.class.path", "").split(File.pathSeparator))
			if (e.endsWith("-rlhd.jar")) { rlhdJar = e; break; }
		int total = 0, linked = 0;
		List<String> failures = new ArrayList<>();
		if (rlhdJar == null) {
			System.out.println(TAG + " FATAL no -rlhd.jar on classpath");
			ok = false;
		} else {
			try (JarFile jf = new JarFile(rlhdJar)) {
				Enumeration<JarEntry> en = jf.entries();
				while (en.hasMoreElements()) {
					JarEntry je = en.nextElement();
					String n = je.getName();
					if (!n.startsWith("rs117/") || !n.endsWith(".class")) continue;
					String cn = n.substring(0, n.length() - 6).replace('/', '.');
					total++;
					try {
						Class.forName(cn, false, cl);   // load + link + verify, no <clinit>
						linked++;
					} catch (Throwable t) {
						failures.add(cn + " -> " + t);
					}
				}
			} catch (Throwable t) {
				System.out.println(TAG + " FATAL reading " + rlhdJar + ": " + t);
				ok = false;
			}
		}
		System.out.println(TAG + " linkSweep linked=" + linked + "/" + total + " failures=" + failures.size());
		for (int i = 0; i < Math.min(failures.size(), 12); i++)
			System.out.println(TAG + "   LINK_FAIL " + failures.get(i));
		if (total == 0 || !failures.isEmpty()) ok = false;

		// 2) OpenCL class-load graph: run the static initializers + confirm OPENCL_EXPLICIT_INIT was set.
		String[] oclGraph = {
			"rs117.hd.utils.buffer.GLBuffer",
			"rs117.hd.utils.buffer.SharedGLBuffer",
			"rs117.hd.opengl.uniforms.UniformBuffer",
			"rs117.hd.opengl.uniforms.UBOCompute",
			"rs117.hd.opengl.compute.OpenCLManager",
		};
		boolean oclOk = true;
		for (String cn : oclGraph) {
			try {
				Class.forName(cn, true, cl);   // force <clinit>
			} catch (Throwable t) {
				System.out.println(TAG + "   OCL_INIT_FAIL " + cn + " -> " + t);
				oclOk = false;
			}
		}
		boolean explicitInit = Boolean.TRUE.equals(org.lwjgl.system.Configuration.OPENCL_EXPLICIT_INIT.get());
		System.out.println(TAG + " openclGraph init=" + oclOk + " OPENCL_EXPLICIT_INIT=" + explicitInit);
		if (!oclOk || !explicitInit) ok = false;

		// 3) Loader data files present + well-formed JSON on-device.
		String[] jsons = {
			"rs117/hd/scene/areas.json",
			"rs117/hd/scene/tile_overrides.json",
			"rs117/hd/scene/model_overrides.json",
			"rs117/hd/scene/ground_materials.json",
			"rs117/hd/scene/water_types.json",
			"rs117/hd/scene/lights.json",
			"rs117/hd/scene/environments.json",
			"rs117/hd/scene/gamevals.json",
			"rs117/hd/scene/materials.json",
		};
		Gson gson = new Gson();
		int jsonOk = 0;
		for (String r : jsons) {
			try (InputStream is = cl.getResourceAsStream(r)) {
				if (is == null) { System.out.println(TAG + "   JSON_MISSING " + r); continue; }
				JsonElement el = gson.fromJson(new InputStreamReader(is, StandardCharsets.UTF_8), JsonElement.class);
				if (el == null || el.isJsonNull()) { System.out.println(TAG + "   JSON_EMPTY " + r); continue; }
				jsonOk++;
			} catch (Throwable t) {
				System.out.println(TAG + "   JSON_FAIL " + r + " -> " + t);
			}
		}
		System.out.println(TAG + " loaderJson parsed=" + jsonOk + "/" + jsons.length);
		if (jsonOk != jsons.length) ok = false;

		System.out.println("MEGAVERDICT = " + (ok ? "ANDROID_RLHD_PROBE_GREEN" : "ANDROID_RLHD_PROBE_NOT_GREEN"));
	}
}
