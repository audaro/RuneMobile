import java.lang.management.CompilationMXBean;
import java.lang.management.ManagementFactory;

/**
 * W1 minimal-shell payload. Proves HotSpot booted AND (via the compile-time
 * delta + vm.info) whether JIT engaged on-device. Java-8 bytecode so it loads
 * on the iOS jre21 and on desktop OpenJDK alike.
 */
public final class Hello {
    public static void main(String[] args) {
        out("=== RuneMobile: HotSpot reached main() on device ===");
        out("java.version = " + System.getProperty("java.version"));
        out("java.vm.name = " + System.getProperty("java.vm.name"));
        out("java.vm.info = " + System.getProperty("java.vm.info"));
        out("os.arch      = " + System.getProperty("os.arch"));
        out("java.home    = " + System.getProperty("java.home"));

        CompilationMXBean c = ManagementFactory.getCompilationMXBean();
        boolean mon = c != null && c.isCompilationTimeMonitoringSupported();
        long t0 = mon ? c.getTotalCompilationTime() : -1;

        long sum = 0;
        for (long i = 0; i < 200_000_000L; i++) sum += (i ^ (i << 1)) + (i >> 1);

        long t1 = mon ? c.getTotalCompilationTime() : -1;
        out("checksum     = " + sum);
        out("compileMs    = " + t0 + " -> " + t1 + (mon ? "" : " (monitoring unsupported)"));

        String info = System.getProperty("java.vm.info", "");
        boolean jit = info.contains("mixed mode") || (mon && t1 > 0);
        out("VERDICT      = " + (jit ? "JIT ACTIVE" : "INTERPRETER ONLY"));
        out("=== RuneMobile: main() returned cleanly ===");
    }

    private static void out(String s) { System.out.println(s); System.out.flush(); }
}
