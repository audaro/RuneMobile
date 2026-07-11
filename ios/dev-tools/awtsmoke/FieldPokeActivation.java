// FieldPokeActivation — the DEVICE-RELEVANT activation recipe for W1 Phase 3 §6.0.
//
// Activates CACIO's CTC toolkit + graphicsenv via **pure reflection static-field
// injection** — NO byte-buddy, NO attach API (`jdk.attach`), NO JVMTI
// RedefineClasses. Those are exactly the capabilities a stripped mobile JRE may
// lack; this path needs none of them, so it should port to the iOS jre21.
//
// Mechanism: set four cached singletons BEFORE anything triggers AWT init, then the
// stock `Toolkit.getDefaultToolkit()` / `GraphicsEnvironment.getLocalGraphicsEnvironment()`
// accessors return our CTC instances:
//   sun.java2d.SurfaceManagerFactory.instance = new CTCSurfaceManagerFactory()
//   java.awt.Toolkit.toolkit                  = new CTCToolkit()
//   java.awt.GraphicsEnvironment.localEnv     = CTCGraphicsEnvironment.getInstance()
//   java.awt.GraphicsEnvironment.headless     = Boolean.FALSE
//
// RESULT (desktop OpenJDK 21.0.5 aarch64, 2026-05-29): exit 0, AWT-ACTIVATION = CTC ACTIVE.
// (This is what actually carries CacioExtension's activation too — its JVMTI redefine
// is belt-and-suspenders that is allowed to throw; the field set is the real switch.)
//
// Requires the JPMS set (we control these in the device JNI_CreateJavaVM args):
//   --add-exports java.desktop/sun.awt, sun.java2d, ...   (CacioToolkit extends sun.awt.SunToolkit)
//   --add-opens   java.desktop/java.awt, sun.java2d; java.base/java.lang.reflect, java.util
//
// DEVICE CAVEAT (verify, do NOT assume): the field names `Toolkit.toolkit`,
// `GraphicsEnvironment.localEnv`, `GraphicsEnvironment.headless`,
// `SurfaceManagerFactory.instance` must exist on the iOS jre21 (standard java.desktop,
// same 21.0.x — almost certainly identical, but confirm on device). And this MUST run
// before any AWT call; in our app we run it as the first Java step via the launcher.

import java.lang.reflect.Field;

public class FieldPokeActivation {

    static void setStatic(Class<?> c, String f, Object v) throws Exception {
        Field fld = c.getDeclaredField(f);
        fld.setAccessible(true);
        fld.set(null, v);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("==== FieldPokeActivation (pure reflection — no byte-buddy/attach/JVMTI) ====");

        Class<?> ctcToolkit = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCToolkit");
        Class<?> ctcGE      = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment");
        Class<?> ctcSMF     = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCSurfaceManagerFactory");

        // Order matters: SurfaceManagerFactory before any SurfaceManager use.
        try {
            setStatic(Class.forName("sun.java2d.SurfaceManagerFactory"), "instance",
                      ctcSMF.getDeclaredConstructor().newInstance());
            System.out.println("set SurfaceManagerFactory.instance OK");
        } catch (Throwable t) { System.out.println("SMF set FAILED: " + t); }

        try {
            setStatic(java.awt.Toolkit.class, "toolkit", ctcToolkit.getDeclaredConstructor().newInstance());
            System.out.println("set Toolkit.toolkit OK");
        } catch (Throwable t) { System.out.println("Toolkit.toolkit set FAILED: " + t); }

        try {
            setStatic(java.awt.GraphicsEnvironment.class, "localEnv", ctcGE.getMethod("getInstance").invoke(null));
            System.out.println("set GraphicsEnvironment.localEnv OK");
        } catch (Throwable t) { System.out.println("localEnv set FAILED: " + t); }

        try {
            setStatic(java.awt.GraphicsEnvironment.class, "headless", Boolean.FALSE);
            System.out.println("set GraphicsEnvironment.headless=false OK");
        } catch (Throwable t) { System.out.println("headless set FAILED: " + t); }

        AwtActivation.main(args); // the no-pixel gate + greppable AWT-ACTIVATION verdict
    }
}
