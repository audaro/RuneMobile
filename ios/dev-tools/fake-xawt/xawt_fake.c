/* fake libawt_xawt for the iOS jre21 — W1 P3 §6.1 (headful Canvas under CACIO CTC).
 *
 * WHY THIS EXISTS / WHAT CHANGED FROM THE HEADLESS COPY
 * §6.0 (activation) only needed libawt_xawt to LOAD + supply the headless natives, so we shipped
 * `libawt_xawt = copy of libawt_headless`. §6.1 instantiates real headful AWT components
 * (`new Frame`, `new Canvas`), and `java.awt.Component.<clinit>` calls the NATIVE
 * `java.awt.Component.initIDs()`. That symbol — and the rest of the HEADFUL component `initIDs`
 * family — lives in neither `libawt` nor `libawt_headless` on this image (verified with `nm`);
 * in a normal build it ships in the real `libawt_xawt`. Device round (2026-05-30) confirmed:
 *   UnsatisfiedLinkError: 'void java.awt.Component.initIDs()'  at Component.<clinit>
 *
 * THE FIX (matches Amethyst's xawt_fake.m, trimmed to OUR image's gaps):
 *   (a) RE-EXPORT libawt_headless  -> keeps its REAL Font/FontDescriptor/PlatformFont initIDs
 *       (the FreeType rasterizer reads the field IDs those cache; device §6.1 proved fonts render
 *       through them). Done via the linker (-reexport_library) in build-libawt_xawt.sh, NOT here.
 *   (b) NO-OP stubs (below) for the headful `initIDs` that are ABSENT from libawt + libawt_headless.
 *       Safe to no-op because CACIO installs PURE-JAVA peers (CTCComponentPeer/...), so the native
 *       X11 peer/drawing code that would consume these cached field IDs is NEVER invoked.
 *
 * DELIBERATELY NOT STUBBED (libawt already provides the REAL ones — stubbing would SHADOW them and
 * break real field-ID caching): Color, Dimension, Rectangle, FontMetrics, Toolkit, Label, Choice,
 * MenuBar, CheckboxMenuItem, ScrollPaneAdjustable, event/MouseEvent, and the java.awt.image.*
 * rasters. (Verified present in libawt via `nm -gU libawt.dylib`.)
 *
 * JNI calling convention is plain C on arm64, so we declare the entry points with (JNIEnv*, jclass)
 * = (void*, void*) and skip jni.h entirely. initIDs takes no Java args -> (env, clazz) only.
 *
 * Build: ./build-libawt_xawt.sh  (-> libawt_xawt.dylib, arm64 iphoneos, reexporting libawt_headless).
 * awtxawt_stub.c is kept as the historical record of the JNI-only round-1 stub.
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
