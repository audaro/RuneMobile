// DeviceHeadlessBoot — W1 P3 §6.2 entrypoint: boot real RuneLite headless on the device JIT JVM
// under CACIO CTC, capturing the engine's mainBufferProvider buffer.
//
// This is the W1<->W2 join. The desktop headless harness (CacioHeadlessTest) activates CTC via the
// byte-buddy CacioExtension (a JUnit extension) — which is OUT for the device (no jdk.attach, no
// self-attach). Here we instead use the device-proven UnsafePokeActivation.activate() (no agent, no
// attach, no JVMTI; §6.0/§6.1 GREEN on device), then call RuneLiteHeadless.main verbatim.
//
// Desktop pre-check (the W2 "develop on desktop first" rule): compile against the shaded client jar +
// cacio, run with the headless capture props; it must boot to the live-OSRS login screen and dump a
// frame-*.png, proving the activation SWAP (UnsafePoke instead of CacioExtension) works with the real
// client before any device round. Then the same class is the device entrypoint (callMain'd by the
// JVMLauncher), with the shaded jar bundled and the capture dir = the app's Documents.
//
// RuneLiteHeadless.main returns after start() (the engine runs on its own non-daemon threads); the
// keep-alive sleep holds the run open long enough for HeadlessCapture to dump frames.

public class DeviceHeadlessBoot {

    public static void main(String[] args) throws Exception {
        System.out.println("==== DeviceHeadlessBoot (W1 P3 §6.2 — real RuneLite under UnsafePoke CTC) ====");

        // 1. Install CTC with no instrumentation (the device-proven §6.0 recipe).
        UnsafePokeActivation.activate();

        System.out.println("[boot] toolkit      = " + java.awt.Toolkit.getDefaultToolkit().getClass().getName());
        System.out.println("[boot] graphicsenv  = " + java.awt.GraphicsEnvironment.getLocalGraphicsEnvironment().getClass().getName());
        System.out.println("[boot] headless     = " + java.awt.GraphicsEnvironment.isHeadless());

        // 2. Boot the real client, window-less (HeadlessClientUI), GPU off. HeadlessCapture dumps
        //    mainBufferProvider to -Drunelite.headless.capture.dir when set.
        //    safe-mode disables external (plugin-hub) plugins AND the GPU plugin; the GPU plugin is
        //    irrelevant headless on the CPU path, so we keep safe-mode by default but drop it for the
        //    plugin-hub path (-Drunelite.hub=true) AND for GPU Route-C (-Drunelite.routecgpu=true), where the
        //    base gpu plugin IS the renderer (it is the one plugin in the tree with loadInSafeMode=false).
        // "Renderers as plugins" (iOS): safe-mode must be OFF in EVERY mode (incl. plain CPU) so the GPU + 117HD
        // plugins load + show in the panel as selectable plugins (GpuPlugin is loadInSafeMode=false). Drop it
        // whenever -Drunelite.nosafemode=true (the native launcher always sets it), in addition to the legacy
        // hub / routecgpu cases.
        final boolean hub = Boolean.getBoolean("runelite.hub");
        final boolean routecGpu = Boolean.getBoolean("runelite.routecgpu");
        final boolean noSafeMode = Boolean.getBoolean("runelite.nosafemode");
        final boolean safeModeOff = hub || routecGpu || noSafeMode;
        // Privacy (PRIVACY-LEGAL-01): this unofficial personal client does not phone RuneLite's telemetry.
        // --disable-telemetry makes RuneLiteModule bind a null TelemetryClient, so start() submits NO boot
        // telemetry and NO JVM-crash reports to api.runelite.net. The other default-on upstream senders are
        // handled downstream: the 10-min session ping is sunk to localhost (RuneLiteHeadless), Loot Tracker +
        // Chat Commands are seeded off (HeadlessClientUI), and GE offer uploads are gated off on mobile
        // (GrandExchangePlugin.submitToApi). Remaining outbound: Jagex (gameplay/auth), read-only GETs from
        // api.runelite.net/static.runelite.net (item prices, hub metadata), and RuneLite-account sync ONLY
        // if the user signs in. PRIVACY.md is the authoritative list. Always on, every renderer.
        final java.util.List<String> rl = new java.util.ArrayList<>();
        if (!safeModeOff) rl.add("--safe-mode");
        rl.add("--disable-telemetry");
        final String[] rlArgs = rl.toArray(new String[0]);
        System.out.println("[boot] launching RuneLiteHeadless" + (safeModeOff
            ? " (safe-mode OFF: " + (noSafeMode ? "nosafemode" : (routecGpu ? "routecgpu" : "hub")) + ")" : " --safe-mode")
            + " --disable-telemetry");
        net.runelite.client.headless.RuneLiteHeadless.main(rlArgs);

        long runSeconds = Long.getLong("headless.runSeconds", 60L);
        // Minimum login-screen frames to grab before exiting cleanly. The device process is killed by iOS
        // within seconds of boot, so we do NOT idle-wait — we POLL fast and bail the instant we have
        // proof-of-render frames. (Desktop: with capture.interval=2, frame #1 lands at the engine's draw
        // #2, i.e. the same instant rendering starts — so a short survival window suffices.)
        final int targetFrames = Integer.getInteger("headless.captureTargetFrames", 3);

        System.out.println("[boot] RuneLite.main returned; eager-capture poll (target=" + targetFrames
            + " frames, max " + runSeconds + "s)");

        // Poll every 250 ms: log draws/frames so the run is self-diagnosing, and EXIT as soon as we have
        // targetFrames PNGs (don't wait out the clock — minimise required survival time). If the log stops
        // with no "captured"/"timeout" line, iOS killed us before even this fired.
        final long pollMs = 250L;
        final long polls = Math.max(1, (runSeconds * 1000L) / pollMs);
        int lastDraws = -1, lastFrames = -1;
        for (long p = 1; p <= polls; p++)
        {
            Thread.sleep(pollMs);
            int draws = -1, frames = -1, nullG = -1;
            String state = "?";
            try
            {
                draws = net.runelite.client.headless.HeadlessCapture.getDrawCount();
                frames = net.runelite.client.headless.HeadlessCapture.getCapturedFrames()
                       + net.runelite.client.headless.HeadlessCapture.getLoggedInFrames();
                nullG = net.runelite.client.headless.HeadlessCapture.getNullGraphicsCount();
                java.lang.Object gs = net.runelite.client.headless.HeadlessCapture.getLastState();
                state = gs == null ? "null" : gs.toString();
            }
            catch (Throwable ignore) { /* capture class may be absent in non-§6.2 probe builds */ }

            // A-1b: once LOGGED_IN, run the runtime gate-flip census once (gated; no-op without -Drunelite.gatecensus).
            if (Boolean.getBoolean("runelite.gatecensus") && state.contains("LOGGED_IN"))
            {
                GateCensus.runOnce(true);
            }

            if (draws != lastDraws || frames != lastFrames || p % 4 == 0)
            {
                System.out.println("[boot] poll " + (p * pollMs) + "ms  draws=" + draws
                    + " nullGraphics=" + nullG + " frames=" + frames + " state=" + state);
                lastDraws = draws;
                lastFrames = frames;
            }
            if (frames >= targetFrames)
            {
                System.out.println("[boot] DeviceHeadlessBoot done: captured " + frames
                    + " frames at " + (p * pollMs) + "ms (target " + targetFrames + " met)");
                return;
            }
        }
        System.out.println("[boot] DeviceHeadlessBoot done: timeout after " + runSeconds
            + "s with " + lastFrames + " frames (engine drew " + lastDraws + ")");
    }
}
