// Rung-0 feasibility microbench: miniJVM vs OpenJDK on the workload the iOS
// profiler proved dominates the OSRS software renderer (project_ios_perf_pivot).
// SYNTHETIC PROXY, not the gamepack render loop — its job is a quick, bounded,
// same-bytecode throughput ratio before any iOS work. Real FPS comes on-device.
//
// Compile Java-8 bytecode (NO lambda / invokedynamic / StringConcatFactory, so
// miniJVM and OpenJDK run byte-identical, simple bytecode):
//     javac --release 8 -d out Bench.java
// Run:
//     <openjdk>/java            -cp out Bench
//     mini_jvm -bootclasspath <abs>/lib/minijvm_rt.jar -cp <abs>/out Bench
//
// Each component self-calibrates: it doubles its iteration count until one run
// crosses TARGET_NS wall-time, so the SLOW VM stays bounded (worst case ~2x
// TARGET per component) and we read ops/sec directly. Ratio = openjdk_ops /
// minijvm_ops (unit-independent). A checksum is printed to defeat dead-code
// elimination, and each component is a real data-dependency chain.
public class Bench {

    static final long TARGET_NS = 1000L * 1000L * 1000L; // ~1s per timed run
    static long SINK = 0;

    // ---- Component A: Float bit-ops dispatch (miniJVM's proven #1 cost) ----
    // On OpenJDK these are intrinsics (~free reinterpret); on miniJVM each is a
    // full native-method invocation with a per-call Runtime alloc.
    static long benchFloatBits(long iters) {
        long acc = 0;
        float f = 1.0001f;
        for (long i = 0; i < iters; i++) {
            int bits = Float.floatToIntBits(f);
            bits ^= (int) (i * 2654435761L);
            float g = Float.intBitsToFloat((bits & 0x007fffff) | 0x3f000000); // ~[0.5,1)
            int rb = Float.floatToRawIntBits(g * 1.5f + 0.5f);
            acc += rb;
            f = g + 1.0001f;
            if (f > 1.0e7f) f = 1.0001f;
        }
        return acc;
    }

    // ---- Component B: software rasterizer-style gouraud fill into int[] ----
    static long benchRaster(int[] fb, int w, int h, long passes) {
        long acc = 0;
        for (long p = 0; p < passes; p++) {
            int c0 = (int) ((p * 7) & 0xff);
            int c1 = (int) ((p * 13) & 0xff);
            int dcol = ((c1 - c0) << 16) / w;
            for (int y = 0; y < h; y++) {
                int rowBase = y * w;
                int col = c0 << 16;
                for (int x = 0; x < w; x++) {
                    int shade = (col >> 16) & 0xff;
                    fb[rowBase + x] = 0xff000000 | (shade << 16) | (shade << 8) | shade;
                    col += dcol;
                }
            }
            acc += fb[(int) ((p % h)) * w + (int) (p % w)];
        }
        return acc;
    }

    // ---- Component C: mixed interpreter overhead (calls/alloc/array/math) ----
    static int mixStep(int a, int b) { return (a * 31 + b) ^ (a >>> 3); }
    static long benchMixed(long iters) {
        long acc = 0;
        for (long i = 0; i < iters; i++) {
            int[] tmp = new int[16];          // small alloc per iter (GC/alloc path)
            int v = (int) i;
            for (int k = 0; k < 16; k++) { v = mixStep(v, k); tmp[k] = v; }
            for (int k = 0; k < 16; k++) acc += tmp[k];
        }
        return acc;
    }

    // Grow iters until a run crosses TARGET_NS, then report that run's throughput.
    static void calibrateFloatBits(String name) {
        long iters = 1L << 16;
        while (true) {
            long t0 = System.nanoTime();
            long chk = benchFloatBits(iters);
            long dt = System.nanoTime() - t0;
            SINK += chk;
            if (dt >= TARGET_NS) { report(name, iters, dt, chk); return; }
            iters <<= 1;
        }
    }
    static void calibrateRaster(String name) {
        int w = 256, h = 256;
        int[] fb = new int[w * h];
        long passes = 4;
        while (true) {
            long t0 = System.nanoTime();
            long chk = benchRaster(fb, w, h, passes);
            long dt = System.nanoTime() - t0;
            SINK += chk;
            if (dt >= TARGET_NS) { report(name, passes * (long) w * (long) h, dt, chk); return; }
            passes <<= 1;
        }
    }
    static void calibrateMixed(String name) {
        long iters = 1L << 14;
        while (true) {
            long t0 = System.nanoTime();
            long chk = benchMixed(iters);
            long dt = System.nanoTime() - t0;
            SINK += chk;
            if (dt >= TARGET_NS) { report(name, iters, dt, chk); return; }
            iters <<= 1;
        }
    }

    static void report(String name, long ops, long dt, long chk) {
        // ops/sec via integer math to avoid relying on double formatting.
        long opsPerSec = (dt > 0) ? (ops * 1000000000L / dt) : -1;
        System.out.println("RESULT " + name + " ops=" + ops + " ns=" + dt
                + " opsPerSec=" + opsPerSec + " chk=" + chk);
    }

    public static void main(String[] args) {
        System.out.println("BENCH-START target_ns=" + TARGET_NS);
        // Warmup: small runs to trigger JIT compilation on either VM.
        for (int w = 0; w < 3; w++) {
            SINK += benchFloatBits(1L << 18);
            int[] fb = new int[256 * 256];
            SINK += benchRaster(fb, 256, 256, 4);
            SINK += benchMixed(1L << 15);
        }
        System.out.println("WARMUP-DONE sink=" + SINK);
        // Timed, self-calibrating. Run each twice; take the better (steady state).
        calibrateFloatBits("floatbits.A");
        calibrateFloatBits("floatbits.B");
        calibrateRaster("raster.A");
        calibrateRaster("raster.B");
        calibrateMixed("mixed.A");
        calibrateMixed("mixed.B");
        System.out.println("BENCH-END sink=" + SINK);
    }
}
