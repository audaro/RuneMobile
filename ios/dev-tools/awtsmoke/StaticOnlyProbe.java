// StaticOnlyProbe — corrects the mode (c) misread (2026-05-30).
//
// CLAIM BEING TESTED: does the byte-buddy redefine in CacioExtension actually THROW yet
// still activate CTC (the old note), or does it SUCCEED the first time and carry the GE
// swap? This loads CacioExtension to run its static{} block ONCE and does NOT call
// inject() a second time (unlike AwtActivationAgent.main, which did).
//
// OBSERVED (OpenJDK 21.0.x aarch64): NO stack trace, and AWT-ACTIVATION = CTC ACTIVE
// (toolkit AND GE both CTC). So:
//   - CacioExtension.static{} alone activates CTC; the redefine of
//     getLocalGraphicsEnvironment / PlatformGraphicsInfo.createGE SUCCEEDS the first time
//     and IS load-bearing for the GE swap.
//   - The "UnsupportedOperationException: change the schema" seen in mode (c) came only
//     because AwtActivationAgent.main called injectCTCGraphicsEnvironment() a SECOND time,
//     re-redefining an already-redefined method. Harmless, and NOT evidence that field
//     injection carries activation.
//
// Consequence: the agent path genuinely needs instrumentation (redefine), which the iOS
// jre21 cannot do (no jdk.attach / libattach.dylib). The no-instrumentation device path
// is UnsafePokeActivation (mode e), not this.
public class StaticOnlyProbe {
    public static void main(String[] args) throws Exception {
        System.out.println("==== StaticOnlyProbe (force CacioExtension <clinit> only; no 2nd inject) ====");
        Class.forName("com.github.caciocavallosilano.cacio.ctc.junit.CacioExtension"); // runs static{}
        AwtActivation.main(args);
    }
}
