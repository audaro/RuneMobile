// UnsafePokeActivation — the DEVICE-RELEVANT activation recipe for W1 Phase 3 §6.0.
//
// Activates CACIO's CTC toolkit + graphicsenv with NO instrumentation: no byte-buddy,
// no jdk.attach / attach-self, no JVMTI RedefineClasses. The embedded iOS jre21 lacks
// jdk.attach + libattach.dylib (offline-confirmed), so the desktop CacioExtension agent
// path is OUT for the device — this path needs none of those capabilities.
//
// WHY THE NAIVE FIELD-POKE FAILED (FieldPokeActivation.java, mode d): there is no
// `GraphicsEnvironment.localEnv` field. getLocalGraphicsEnvironment() returns
// `GraphicsEnvironment$LocalGE.INSTANCE` — a static-final singleton computed in the
// holder's <clinit> via the BUILD-TIME-hardcoded sun.awt.PlatformGraphicsInfo.createGE()
// (which is why -Djava.awt.graphicsenv is ignored on JDK 21). With no instrumentation we
// OVERWRITE that static-final field via Unsafe after the holder initializes; since the
// accessor re-reads INSTANCE every call, subsequent calls return our CTC GE.
//
// THE ONE-SHOT SurfaceManagerFactory CONTENTION (the bug that first shipped): both the
// platform CGraphicsEnvironment.<clinit> AND `new CTCToolkit()` call
// sun.java2d.SurfaceManagerFactory.setInstance(), which throws IllegalStateException if
// already set. Whichever runs second blows up (it took down LocalGE.<clinit> ->
// NoClassDefFoundError -> FAILED). Fix: reset SurfaceManagerFactory.instance = null
// (reflection) right BEFORE each constructor that calls setInstance, so each install
// succeeds. (This is exactly why CacioExtension nulls the SMF too.)
//
// Sequence (ORDER IS LOAD-BEARING):
//   1. GraphicsEnvironment.headless / .defaultHeadless = Boolean.TRUE   <-- headless-FIRST
//   2. SMF.instance=null, then force LocalGE.<clinit> (platform createGE builds the throwaway GE)
//   3. GraphicsEnvironment.headless / .defaultHeadless = Boolean.FALSE  (CTC operates non-headless)
//   4. SMF.instance=null, then new CTCToolkit() + Toolkit.toolkit = it
//   5. SMF.instance=null, then CTCGraphicsEnvironment.getInstance()
//   6. Unsafe-overwrite the static-final LocalGE.INSTANCE = that CTC GE
//   7. SMF.instance = new CTCSurfaceManagerFactory() (final state, direct field write)
//
// WHY HEADLESS-FIRST (the device fix, 2026-05-30): step 2's forced LocalGE.<clinit> runs the
// build-hardcoded PlatformGraphicsInfo.createGE(), which on this xawt-style iOS jre21 is
// `new X11GraphicsEnvironment()` (verified: jdk21u unix PlatformGraphicsInfo.createGE). That
// class's <clinit> -> initStatic() calls the native `initDisplay(boolean)` (open an X server)
// — but ONLY inside `if (!isHeadless())` (verified: jdk21u unix X11GraphicsEnvironment.initStatic).
// There is no X server on iOS and the backend lacks that native, so initDisplay is an
// UnsatisfiedLinkError. The original order set headless=FALSE BEFORE step 2, so initDisplay
// fired and LocalGE.<clinit> died (device round-3 FAILED). Initializing the holder while
// headless=TRUE makes X11GE.<clinit> SKIP initDisplay; the throwaway GE (wrapped in
// HeadlessGraphicsEnvironment) is discarded the instant we overwrite INSTANCE in step 6, and
// headless is flipped back to FALSE in step 3 so CTC runs headful. This mirrors Amethyst's
// CTCPreloadClassLoader, which force-inits LocalGE under headless=TRUE then flips it off — the
// proven on-device ordering. NO X11 native (initDisplay/X11GraphicsDevice/...) needs stubbing:
// the headless path never reaches them. The only loadLibrary X11GE.<clinit> does unconditionally
// is "awt" (present in the image). DEVICE-CONFIRM PENDING — this reorder is the hypothesis the
// round-3 trace points to, not yet a verified GREEN.
//
// Requires the JPMS set we control in the device JNI_CreateJavaVM args, including
// `--add-exports java.desktop/sun.awt.image=ALL-UNNAMED` (CTC's CTCVolatileSurfaceManager
// extends sun.awt.image.VolatileSurfaceManager) plus the sun.awt/sun.java2d exports and the
// java.awt / sun.java2d / java.lang.reflect opens.
//
// Unsafe is reached purely via reflection (no `sun.misc.*` import) so this still compiles
// `javac --release 8` and bundles into the device probe jar, same as the other probes.

import java.lang.reflect.Field;
import java.lang.reflect.Method;

public class UnsafePokeActivation {

    static void setStatic(String cls, String field, Object v) throws Exception {
        setStatic(Class.forName(cls), field, v);
    }
    static void setStatic(Class<?> c, String field, Object v) throws Exception {
        Field f = c.getDeclaredField(field);
        f.setAccessible(true);
        f.set(null, v);
    }
    // Reset the one-shot SurfaceManagerFactory so the next setInstance() call succeeds.
    static void nullSMF() {
        try { setStatic("sun.java2d.SurfaceManagerFactory", "instance", null); }
        catch (Throwable t) { System.out.println("nullSMF FAILED: " + t); }
    }

    // Install CTC (toolkit + graphicsenv + SMF) on a pristine AWT state, no instrumentation.
    // Extracted so non-probe callers (e.g. the device RuneLite boot) can activate without the
    // AwtActivation verdict. main() = activate() + verdict, so §6.0/§6.1 behavior is unchanged.
    public static void activate() throws Exception {
        System.out.println("==== UnsafePokeActivation (no byte-buddy / no attach / no JVMTI) ====");

        Class<?> ctcToolkit = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCToolkit");
        Class<?> ctcGE      = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment");
        Class<?> ctcSMF     = Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCSurfaceManagerFactory");

        // --- reflective Unsafe handle (release-8-safe; no sun.misc.* import) ---
        Class<?> unsafeCls = Class.forName("sun.misc.Unsafe");
        Field theUnsafe = unsafeCls.getDeclaredField("theUnsafe");
        theUnsafe.setAccessible(true);
        Object U = theUnsafe.get(null);
        Method mBase   = unsafeCls.getMethod("staticFieldBase", Field.class);
        Method mOffset = unsafeCls.getMethod("staticFieldOffset", Field.class);
        Method mPutObj = unsafeCls.getMethod("putObject", Object.class, long.class, Object.class);

        // 1. HEADLESS-FIRST: set headless=TRUE so the forced X11GraphicsEnvironment.<clinit> in
        //    step 2 SKIPS the native initDisplay() (it is gated on `if (!isHeadless())`). This is
        //    the device fix — see the header note. Flipped back to FALSE in step 3.
        try {
            setStatic(java.awt.GraphicsEnvironment.class, "headless", Boolean.TRUE);
            setStatic(java.awt.GraphicsEnvironment.class, "defaultHeadless", Boolean.TRUE);
            System.out.println("set GraphicsEnvironment.headless/defaultHeadless = true OK (headless-first)");
        } catch (Throwable t) { System.out.println("headless(true) set FAILED: " + t); }

        // 2. Force the holder to init FIRST (SMF virgin -> platform setInstance succeeds).
        //    Under headless=TRUE the throwaway X11GE.<clinit> skips initDisplay; createGE() then
        //    wraps it in HeadlessGraphicsEnvironment. Both are discarded when step 6 overwrites INSTANCE.
        try {
            nullSMF();
            Class.forName("java.awt.GraphicsEnvironment$LocalGE"); // initialize=true -> <clinit>
            System.out.println("forced LocalGE.<clinit> (platform GE built, headless) OK");
        } catch (Throwable t) {
            System.out.println("LocalGE.<clinit> FAILED: " + t);
            t.printStackTrace(System.out);
        }

        // 3. Flip headless back to FALSE so CTC runs headful (isHeadless()==false for CTC ops).
        try {
            setStatic(java.awt.GraphicsEnvironment.class, "headless", Boolean.FALSE);
            setStatic(java.awt.GraphicsEnvironment.class, "defaultHeadless", Boolean.FALSE);
            System.out.println("set GraphicsEnvironment.headless/defaultHeadless = false OK");
        } catch (Throwable t) { System.out.println("headless(false) set FAILED: " + t); }

        // 4. CTC Toolkit (its construction calls SMF.setInstance -> reset first).
        try {
            nullSMF();
            setStatic(java.awt.Toolkit.class, "toolkit", ctcToolkit.getDeclaredConstructor().newInstance());
            System.out.println("set Toolkit.toolkit = CTCToolkit OK");
        } catch (Throwable t) { System.out.println("Toolkit.toolkit set FAILED: " + t); }

        // 5. Build the CTC GE (reset SMF first in case its init also installs one).
        Object ctcGEInstance = null;
        try {
            nullSMF();
            ctcGEInstance = ctcGE.getMethod("getInstance").invoke(null);
            System.out.println("built CTCGraphicsEnvironment.getInstance() OK");
        } catch (Throwable t) {
            System.out.println("CTC GE build FAILED: " + t);
            t.printStackTrace(System.out);
        }

        // 6. Unsafe-overwrite the static-final LocalGE.INSTANCE with the CTC GE.
        try {
            Class<?> localGE = Class.forName("java.awt.GraphicsEnvironment$LocalGE");
            Field instance = localGE.getDeclaredField("INSTANCE");
            Object base = mBase.invoke(U, instance);
            long off = (Long) mOffset.invoke(U, instance);
            mPutObj.invoke(U, base, off, ctcGEInstance);
            System.out.println("Unsafe-overwrote LocalGE.INSTANCE = CTCGraphicsEnvironment OK");
        } catch (Throwable t) {
            System.out.println("LocalGE.INSTANCE overwrite FAILED: " + t);
            t.printStackTrace(System.out);
        }

        // 7. Final SMF state = CTC factory (direct field write bypasses the setInstance guard).
        try {
            setStatic("sun.java2d.SurfaceManagerFactory", "instance",
                      ctcSMF.getDeclaredConstructor().newInstance());
            System.out.println("set SurfaceManagerFactory.instance = CTCSurfaceManagerFactory OK");
        } catch (Throwable t) { System.out.println("SMF set FAILED: " + t); }
    }

    public static void main(String[] args) throws Exception {
        activate();
        AwtActivation.main(args); // the no-pixel gate + greppable AWT-ACTIVATION verdict
    }
}
