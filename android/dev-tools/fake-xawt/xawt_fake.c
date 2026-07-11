/* fake libawt_xawt.so for the Android (bionic) jre21 — Milestone B AWT backend under CACIO CTC.
 *
 * WHY THIS EXISTS
 * This PojavLauncher-derived jre21 is an xawt-style build: java.awt.Toolkit.<clinit> does
 * System.loadLibrary("awt_xawt"), and that .so is absent from the image (it ships libawt +
 * libawt_headless only). Worse, java.awt.Component.<clinit> calls the NATIVE
 * java.awt.Component.initIDs() — and the whole HEADFUL component initIDs family lives in neither
 * libawt nor libawt_headless on this image (verified with llvm-nm); in a normal desktop build it
 * ships in the real libawt_xawt. So a bare load-only stub gets past Toolkit but dies at:
 *   UnsatisfiedLinkError: 'void java.awt.Component.initIDs()'  at Component.<clinit>
 *
 * THE FIX (mirrors the proven iOS xawt_fake.c, trimmed to OUR image's gaps):
 *   (a) DT_NEEDED libawt_headless.so (recorded by the build script via -lawt_headless
 *       -Wl,--no-as-needed) -> keeps its REAL Font/PlatformFont initIDs reachable: bionic dlsym on
 *       this lib's handle searches its DT_NEEDED deps, so the JVM's native lookup finds
 *       Java_java_awt_Font_initIDs through us. (Font already resolved when we shipped a plain
 *       copy-of-headless; this preserves that while adding the headful stubs.)
 *   (b) NO-OP stubs (below) for the headful initIDs ABSENT from libawt + libawt_headless. Safe to
 *       no-op because CACIO installs PURE-JAVA peers (CTCComponentPeer/...), so the native X11
 *       peer/drawing code that would consume these cached field IDs is NEVER invoked.
 *
 * DELIBERATELY NOT STUBBED (libawt already provides the REAL ones — stubbing would SHADOW them and
 * break real field-ID caching): Color, Dimension, Rectangle, FontMetrics, Toolkit, event/MouseEvent.
 * (Verified present in libawt via llvm-nm -D on this image.)
 *
 * JNI calling convention is plain C on arm64, so we declare entry points with (JNIEnv*, jclass) =
 * (void*, void*) and skip jni.h entirely. initIDs takes no Java args -> (env, clazz) only.
 *
 * Build: ./build-libawt_xawt.sh  (-> libawt_xawt.so, arm64 android, DT_NEEDED libawt_headless.so).
 */
#include <stdint.h>

#define INITIDS(cls) void Java_java_awt_##cls##_initIDs(void *env, void *clazz) {}
#define EVTINITIDS(cls) void Java_java_awt_event_##cls##_initIDs(void *env, void *clazz) {}

/* --- headful java.awt component family (absent from libawt + libawt_headless) --- */
INITIDS(Component)
INITIDS(Container)
INITIDS(Window)
INITIDS(Frame)
INITIDS(Dialog)
INITIDS(Button)
INITIDS(Checkbox)
INITIDS(Scrollbar)
INITIDS(ScrollPane)
INITIDS(TextArea)
INITIDS(TextField)
INITIDS(Menu)
INITIDS(MenuItem)
INITIDS(MenuComponent)
INITIDS(FileDialog)
INITIDS(Cursor)
INITIDS(Event)
INITIDS(AWTEvent)
INITIDS(Insets)
INITIDS(KeyboardFocusManager)
INITIDS(TrayIcon)

/* --- headful java.awt.event family (MouseEvent is in libawt -> NOT stubbed here) --- */
EVTINITIDS(InputEvent)
EVTINITIDS(KeyEvent)

/* --- other headful natives reachable when realizing components / pumping the EDT --- */
void Java_java_awt_Cursor_finalizeImpl(void *env, void *clazz, long long pData) {}
void Java_java_awt_AWTEvent_nativeSetSource(void *env, void *self, void *peer) {}
void Java_sun_awt_SunToolkit_closeSplashScreen(void *env, void *clazz) {}

/* --- UNIXToolkit GTK probes (CACIO/Swing may query desktop props); return "no GTK" --- */
unsigned char Java_sun_awt_UNIXToolkit_check_1gtk(void *env, void *self, int v, unsigned char vb) { return 0; }
int           Java_sun_awt_UNIXToolkit_get_1gtk_1version(void *env, void *self) { return 1; }
unsigned char Java_sun_awt_UNIXToolkit_gtkCheckVersionImpl(void *env, void *self, int a, int b, int c) { return 0; }
unsigned char Java_sun_awt_UNIXToolkit_load_1gtk(void *env, void *self, int v, unsigned char vb) { return 0; }
unsigned char Java_sun_awt_UNIXToolkit_unload_1gtk(void *env, void *self) { return 0; }
void          Java_sun_awt_UNIXToolkit_nativeSync(void *env, void *self) {}

int32_t JNI_OnLoad(void *vm, void *reserved) {
    return 0x00010008; /* JNI_VERSION_1_8 */
}
