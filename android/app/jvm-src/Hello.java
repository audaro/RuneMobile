// Milestone A smoke: prove the embedded HotSpot VM is up and JIT-compiling on Android.
// Compiled to hello.jar and bundled in assets/jvm/. Run via JvmLauncher.startJvm(mainClass="Hello").
public class Hello {
    public static void main(String[] args) {
        System.out.println("==== Hello from embedded HotSpot on Android ====");
        System.out.println("java.version  = " + System.getProperty("java.version"));
        System.out.println("java.vm.name  = " + System.getProperty("java.vm.name"));
        System.out.println("os.arch       = " + System.getProperty("os.arch"));

        java.lang.management.CompilationMXBean c =
            java.lang.management.ManagementFactory.getCompilationMXBean();
        System.out.println("JIT compiler  = " + (c == null ? "NONE" : c.getName()));

        // Warm a hot loop so C1/C2 tier up (watch -XX:+PrintCompilation in logcat).
        long sum = 0;
        for (int r = 0; r < 200; r++) {
            for (int i = 0; i < 1_000_000; i++) {
                sum += (i * 31L) ^ (i >>> 3);
            }
        }
        long ms = c == null ? -1 : c.getTotalCompilationTime();
        System.out.println("warm loop sum = " + sum);
        System.out.println("compile time  = " + ms + " ms");
        System.out.println("VERDICT       = " + (ms > 0 ? "JIT ACTIVE" : "JIT NOT CONFIRMED"));
    }
}
