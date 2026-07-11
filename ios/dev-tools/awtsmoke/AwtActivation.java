// AwtActivation — W1 Phase 3 §6.0 "activation gate" probe.
//
// Asserts (loudly) that the CACIO CTC toolkit + graphicsenv are installed and the
// JVM is NON-headless — WITHOUT drawing a single pixel. This is the gate the brief
// (ios/AUDIT-BRIEF-w1-phase3-awt.md, Claim A) calls out: the dangerous part of
// Phase 3 is activation/classloading before AWT init, not Java2D.
//
// The desktop CACIO path (CacioExtension) installs CTC via a ByteBuddy
// instrumentation agent that REDEFINES GraphicsEnvironment.getLocalGraphicsEnvironment()
// at runtime (confirmed by decompiling CacioExtension.injectCTCGraphicsEnvironment).
// That agent path is the JUnit-harness mechanism and is NOT what the device uses.
// Amethyst's device path is `-Xbootclasspath/a:<cacio jars>` + property selection
// (`-Dawt.toolkit` / `-Djava.awt.graphicsenv`) so the BOOT-loaded GraphicsEnvironment/
// Toolkit can instantiate CTC directly — no agent, no redefinition.
//
// This probe is the assertion half. The runners decide the activation MECHANISM:
//   run-activation-desktop.sh  -> tries the no-agent bootclasspath path on desktop JDK 21 (cheap pre-check)
//   (device)                   -> same flags via the RuneMobile JNI_CreateJavaVM launcher
//
// Java-8 source level so it bundles into probes.jar / runs on the device JDK 21,
// same as the Phase-1 probes.
//
// VERDICT line is machine-greppable: "AWT-ACTIVATION = CTC ACTIVE" on success.

import java.awt.GraphicsEnvironment;
import java.awt.Toolkit;

public class AwtActivation {

    private static final String EXPECT_TOOLKIT =
        "com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
    private static final String EXPECT_GE =
        "com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

    public static void main(String[] args) {
        System.out.println("==== AwtActivation (W1 P3 §6.0 activation gate) ====");

        // The properties we asked for (so a mismatch vs reality is obvious).
        System.out.println("prop java.awt.headless     = " + System.getProperty("java.awt.headless"));
        System.out.println("prop awt.toolkit           = " + System.getProperty("awt.toolkit"));
        System.out.println("prop java.awt.graphicsenv  = " + System.getProperty("java.awt.graphicsenv"));

        boolean ok = true;

        // 1. Headless state. Phase 3 needs NON-headless; the engine's Canvas can't
        //    realize a peer otherwise.
        boolean headless = GraphicsEnvironment.isHeadless();
        System.out.println("GraphicsEnvironment.isHeadless() = " + headless);
        if (headless) {
            System.out.println("  !! FAIL: headless — no Canvas peer possible. "
                + "(check -Djava.awt.headless=false AND that a non-headless GE installed)");
            ok = false;
        }

        // 2. The actual Toolkit class (the FINDINGS gotcha: a bare -Dawt.toolkit
        //    silently FALLS BACK to the native toolkit — so we check the real class,
        //    not the property).
        String tkClass = "<threw>";
        try {
            Toolkit tk = Toolkit.getDefaultToolkit();
            tkClass = tk.getClass().getName();
        } catch (Throwable t) {
            tkClass = t.getClass().getName() + ": " + t.getMessage();
            ok = false;
        }
        System.out.println("Toolkit.getDefaultToolkit() = " + tkClass);
        if (!EXPECT_TOOLKIT.equals(tkClass)) {
            System.out.println("  !! FAIL: toolkit is not CTC (silent native-toolkit fallback?)");
            ok = false;
        }

        // 3. The actual GraphicsEnvironment class.
        String geClass = "<threw>";
        try {
            GraphicsEnvironment ge = GraphicsEnvironment.getLocalGraphicsEnvironment();
            geClass = ge.getClass().getName();
        } catch (Throwable t) {
            geClass = t.getClass().getName() + ": " + t.getMessage();
            ok = false;
        }
        System.out.println("GraphicsEnvironment.getLocalGraphicsEnvironment() = " + geClass);
        if (!EXPECT_GE.equals(geClass)) {
            System.out.println("  !! FAIL: graphicsenv is not CTC");
            ok = false;
        }

        // 4. Prove the screen device is queryable (CTC reports a virtual screen).
        if (!headless) {
            try {
                GraphicsEnvironment ge = GraphicsEnvironment.getLocalGraphicsEnvironment();
                int nDevs = ge.getScreenDevices().length;
                java.awt.GraphicsConfiguration gc =
                    ge.getDefaultScreenDevice().getDefaultConfiguration();
                System.out.println("screenDevices=" + nDevs + " defaultBounds=" + gc.getBounds());
            } catch (Throwable t) {
                System.out.println("  !! FAIL querying screen device: " + t);
                ok = false;
            }
        }

        System.out.println(ok
            ? "AWT-ACTIVATION = CTC ACTIVE"
            : "AWT-ACTIVATION = FAILED");
        // Don't System.exit — the device launcher runs probes in one shared VM.
    }
}
