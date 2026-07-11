// GateCensus — Phase A-1b: runtime gate-flip census.
//
// The A-1a static census (android/dev-tools/bridge-census) proved every headless-bridge method RESOLVES in
// the shaded jar. A-1b proves the next thing: that each `-D` gate actually flips its bridge inert->active at
// RUNTIME under a booted, LOGGED_IN engine — i.e. with `-Drunelite.<gate>=true` set, the bridge reports
// isEnabled()==true AND a first read returns without throwing (the gate is what wires the bridge into
// Hooks.draw's per-frame tick, so the read returns the live, ticked snapshot rather than throwing/being inert).
//
// Reflection-based, exactly like the A-1a BridgeCensus: decoupled from bridge signatures, compiles against
// only the shaded jar, and reports whatever it finds. Gated behind -Drunelite.gatecensus=true and invoked
// once post-LOGGED_IN by DeviceHeadlessBoot; emits nothing otherwise. Default package (same as
// DeviceHeadlessBoot / UnsafePokeActivation), folded into probes.jar by ios/app/build-probes.sh.
//
// Sentinel line per gate (deterministic -> md5-gatable):  GATE_CENSUS <gate> enabled=<bool> live=<bool>
// followed by a tab + human-only detail (read-method + result) that the harness strips before hashing.

public class GateCensus {

    private static boolean done = false;

    // gate label | bridge fully-qualified class name | no-arg read method (null = isEnabled-only, e.g. autologin)
    private static final String[][] GATES = {
        {"mobileui",     "net.runelite.client.headless.MobileUiBridge",     "listPlugins"},
        {"menupeek",     "net.runelite.client.headless.MenuPeekBridge",     "getSnapshot"},
        {"mobilechrome", "net.runelite.client.headless.MobileChromeBridge", "getSnapshot"},
        {"huddata",      "net.runelite.client.headless.HudDataBridge",      "getSnapshot"},
        {"hudveneer",    "net.runelite.client.headless.HudVeneerBridge",    "getChatSnapshot"},
        {"autologin",    "net.runelite.client.headless.HeadlessLogin",      null},
    };

    /** Run the census once. loggedIn = the engine reached LOGGED_IN (the autologin gate's liveness proof). */
    public static synchronized void runOnce(boolean loggedIn) {
        if (done) {
            return;
        }
        done = true;

        System.out.println("==== GATE_CENSUS (A-1b runtime gate-flip) ====");
        int total = GATES.length;
        int active = 0;

        for (String[] g : GATES) {
            String gate = g[0];
            String fqcn = g[1];
            String readMethod = g[2];

            boolean enabled = false;
            boolean live = false;
            String detail;

            try {
                Class<?> c = Class.forName(fqcn);
                enabled = (Boolean) c.getMethod("isEnabled").invoke(null);

                if (readMethod == null) {
                    // No read surface (autologin) — liveness is "reached LOGGED_IN", which it drives.
                    live = loggedIn;
                    detail = "loggedIn=" + loggedIn;
                } else {
                    try {
                        Object r = c.getMethod(readMethod).invoke(null);
                        live = true; // returned without throwing => the gate wired the bridge in; it is live
                        detail = readMethod + "=" + (r == null ? "null"
                            : (r instanceof String ? ("len" + ((String) r).length()) : "ok"));
                    } catch (Throwable t) {
                        live = false;
                        detail = readMethod + " THREW " + t.getClass().getSimpleName();
                    }
                }
            } catch (Throwable t) {
                detail = "resolve THREW " + t.getClass().getSimpleName();
            }

            if (enabled && live) {
                active++;
            }
            // Deterministic sentinel (gate + enabled + live); detail is human-only, after the tab.
            System.out.println("GATE_CENSUS " + gate + " enabled=" + enabled + " live=" + live + "\t# " + detail);
        }

        String verdict = (active == total) ? "GREEN" : "RED";
        System.out.println("ANDROID_GATE_CENSUS verdict=" + verdict + " active=" + active + "/" + total);
    }
}
