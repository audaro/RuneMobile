/* fake libawt_xawt for the iOS jre21 — W1 P3 §6.1 (surfaced at §6.0).
 *
 * WHY: on the device the §6.0 activation probe threw, on the very first touch of a Toolkit
 * class, with:
 *   java.lang.UnsatisfiedLinkError: Can't load library: .../jre/lib/libawt_xawt.dylib
 *     at java.desktop/java.awt.Toolkit.loadLibraries
 *     at java.desktop/java.awt.Toolkit.initStatic
 *     at java.desktop/java.awt.Toolkit.<clinit>
 * This jre21 is an xawt-style (non-headless) build: java.awt.Toolkit.<clinit> ->
 * loadLibraries() does System.loadLibrary("awt_xawt"), and that dylib is absent from the
 * image (we only ship libawt + libawt_headless). The load fails before CTC can be installed.
 *
 * CTC provides pure-Java peers, so the real X11/xawt native methods are never invoked — the
 * file only needs to LOAD so Toolkit init proceeds. This is the minimal stand-in: a loadable
 * dylib whose JNI_OnLoad returns a valid version. If AWT later calls a specific native from
 * here, the next UnsatisfiedLinkError will name the symbol and we add a no-op for it.
 *
 * Build: ./build-libawt_xawt.sh  (-> libawt_xawt.dylib, arm64 iphoneos). Place in jre/lib/;
 * the Xcode resign-jre build phase signs it with the app cert.
 */
#include <stdint.h>

int32_t JNI_OnLoad(void *vm, void *reserved) {
    return 0x00010008; /* JNI_VERSION_1_8 */
}
