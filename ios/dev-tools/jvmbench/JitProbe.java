// Phase-1 device JIT probe: the smallest decisive "is HotSpot actually JIT-ing,
// or silently interpreting?" check. Pairs with Bench.java (the Rung-1 perf A/B);
// JitProbe answers the binary platform question, Bench quantifies the win.
//
// Three independent signals, no log parsing required:
//   1. java.vm.name  -> "OpenJDK 64-Bit Server VM" = HotSpot (NOT a Zero port).
//   2. java.vm.info  -> "mixed mode..." = JIT enabled; "interpreted mode" = -Xint.
//   3. CompilationMXBean.getTotalCompilationTime() climbs > 0 during a hot loop
//      = C1/C2 compiler threads actually ran (null bean / flat 0 = no JIT).
// A self-timed hot loop gives a coarse throughput number so the attach-vs-Xint
// A/B is visible even without -XX:+PrintCompilation.
//
// Compile (Java-8 bytecode, no invokedynamic, runs on any 8+ incl. the device 21):
//     javac --release 8 -d out JitProbe.java
// Run the A/B on device (StikDebug attached) and read the verdict line each time:
//     java -cp out JitProbe                 # expect: HotSpot + mixed mode + compileMs>0
//     java -Xint -cp out JitProbe           # expect: interpreted mode + compileMs==0
//     java -Xbatch -XX:+PrintCompilation -XX:CompileThreshold=100 -cp out JitProbe
// Unattached (no StikDebug) is the negative control: HotSpot may crash on first
// codegen (AMFI kill on RWX) or fall back; capture whatever happens.
import java.lang.management.CompilationMXBean;
import java.lang.management.ManagementFactory;

public class JitProbe {

    public static void main(String[] args) {
        System.out.println("== JitProbe ==");
        System.out.println("java.vm.name      = " + System.getProperty("java.vm.name"));
        System.out.println("java.vm.info      = " + System.getProperty("java.vm.info"));
        System.out.println("java.vm.version   = " + System.getProperty("java.vm.version"));
        System.out.println("java.runtime.ver  = " + System.getProperty("java.runtime.version"));
        System.out.println("os.arch / os.name = " + System.getProperty("os.arch")
                + " / " + System.getProperty("os.name"));

        CompilationMXBean comp = ManagementFactory.getCompilationMXBean();
        boolean beanPresent = comp != null;
        boolean timeSupported = beanPresent && comp.isCompilationTimeMonitoringSupported();
        System.out.println("CompilationMXBean = "
                + (beanPresent ? comp.getName() : "<absent — no JIT compiler in this VM>"));

        long compBefore = timeSupported ? comp.getTotalCompilationTime() : -1L;

        // Hot loop: a floatbits + arithmetic dependency chain (the workload the iOS
        // profiler proved dominates the OSRS renderer). Big enough to blow past
        // CompileThreshold so C1/C2 must engage if JIT is live. Data-dependent so
        // the result can't be dead-code-eliminated.
        long iters = 200L * 1000L * 1000L;
        long t0 = System.nanoTime();
        double acc = hotLoop(iters);
        long t1 = System.nanoTime();

        long compAfter = timeSupported ? comp.getTotalCompilationTime() : -1L;
        long compDelta = (compBefore >= 0 && compAfter >= 0) ? (compAfter - compBefore) : -1L;

        double secs = (t1 - t0) / 1e9;
        double opsPerSec = iters / secs;
        System.out.println("checksum          = " + Double.doubleToLongBits(acc));
        System.out.println("hotLoop           = " + iters + " iters in "
                + String.format("%.3f", secs) + "s  (" + (long) opsPerSec + " ops/s)");
        System.out.println("compileMs(delta)  = "
                + (compDelta >= 0 ? Long.toString(compDelta) : "<unmonitored>"));

        String vmInfo = String.valueOf(System.getProperty("java.vm.info"));
        boolean mixed = vmInfo.contains("mixed mode");
        boolean compiled = compDelta > 0;
        String verdict;
        if (mixed && compiled) {
            verdict = "JIT ACTIVE (mixed mode + compiler ran)";
        } else if (!mixed && vmInfo.contains("interpreted mode")) {
            verdict = "INTERPRETER ONLY (-Xint or JIT denied)";
        } else {
            verdict = "AMBIGUOUS — inspect signals above (vm.info='" + vmInfo
                    + "', compileMs=" + compDelta + ")";
        }
        System.out.println("VERDICT           = " + verdict);
    }

    // Kept simple and self-contained so C1/C2 inline it; returns a value that
    // depends on every iteration.
    private static double hotLoop(long iters) {
        double acc = 1.0;
        for (long i = 0; i < iters; i++) {
            int bits = Float.floatToIntBits((float) acc + i);
            float f = Float.intBitsToFloat((bits * 2654435761L != 0 ? bits ^ (int) i : bits) | 1);
            acc = acc * 1.0000001 + (f - (float) Math.floor(f));
            if (acc > 1e6) {
                acc = acc - Math.floor(acc) + 1.0; // keep it bounded, stay data-dependent
            }
        }
        return acc;
    }
}
