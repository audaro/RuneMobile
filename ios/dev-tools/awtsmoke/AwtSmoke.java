// AwtSmoke — W1 Phase 3 §6.1 probe. The step after §6.0 (CTC ACTIVE on device).
//
// §6.0 proved CACIO's CTC toolkit + graphicsenv install and report non-headless. §6.1 proves the
// thing RuneLite actually needs: a REALIZED java.awt.Canvas under CTC yields a non-null Graphics,
// and the CTC Java2D/font pipeline rasterizes shapes + antialiased text into a buffer we can read
// back. That is exactly the engine seam — Client.getCanvas() is a java.awt.Canvas, and the gamepack
// presents its BufferProvider pixels by drawing into the canvas's Graphics.
//
// This probe does NOT re-derive the activation; it calls UnsafePokeActivation.main(args) verbatim
// (the device-GREEN §6.0 recipe, which also prints AWT-ACTIVATION = CTC ACTIVE), then runs the smoke
// on top of the now-active CTC GE. Keeping activation untouched protects the proven path.
//
// Java-8 source level so it bundles into probes.jar / runs on the device JDK 21, same as the others.
// VERDICT line is machine-greppable: "AWT-SMOKE = CANVAS+CTC OK" on success, "AWT-SMOKE = FAILED"
// otherwise. If args[0] is given, a PNG of the rendered buffer is written there for an eyeball A/B.

import java.awt.Canvas;
import java.awt.Color;
import java.awt.Font;
import java.awt.Frame;
import java.awt.Graphics;
import java.awt.Graphics2D;
import java.awt.GraphicsConfiguration;
import java.awt.GraphicsEnvironment;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;

public class AwtSmoke {

    static final int W = 765, H = 503;      // RuneLite fixed-mode canvas size (the brief's target)
    static final int BG = new Color(64, 64, 64).getRGB() & 0xFFFFFF;   // DARK_GRAY background

    public static void main(String[] args) throws Exception {
        // 1. Activate CTC via the proven §6.0 recipe (prints "AWT-ACTIVATION = CTC ACTIVE").
        UnsafePokeActivation.main(args);

        System.out.println("==== AwtSmoke (W1 P3 §6.1 — realize Canvas + CTC pixels/fonts) ====");
        boolean ok = true;

        // 2. Realize a headful Frame + Canvas. CTC's peers are pure-Java (no real display), so
        //    addNotify()+setVisible() create them against CTC's managed screen.
        Frame f = null;
        Canvas c = null;
        try {
            f = new Frame("AwtSmoke");
            f.setLayout(null);
            f.setSize(W, H);
            c = new Canvas();
            c.setBounds(0, 0, W, H);
            f.add(c);
            f.addNotify();
            f.setVisible(true);     // makes the hierarchy showing -> Canvas peer can hand out Graphics
            f.validate();
            System.out.println("Frame.isDisplayable=" + f.isDisplayable()
                + " Canvas.isDisplayable=" + c.isDisplayable()
                + " Canvas.isShowing=" + c.isShowing());
            if (!c.isDisplayable()) { System.out.println("  !! FAIL: Canvas not displayable"); ok = false; }
        } catch (Throwable t) {
            System.out.println("  !! FAIL realizing Frame/Canvas: " + t);
            t.printStackTrace(System.out);
            ok = false;
        }

        // 3. THE headline §6.1 assertion: a realized Canvas yields a non-null Graphics under CTC.
        Graphics cg = null;
        try {
            cg = (c != null) ? c.getGraphics() : null;
            System.out.println("Canvas.getGraphics() = " + cg);
            if (cg == null) {
                System.out.println("  !! FAIL: Canvas.getGraphics() is null "
                    + "(peer not presenting; RuneLite needs this for blit — may require a BufferStrategy path)");
                ok = false;
            }
        } catch (Throwable t) {
            System.out.println("  !! FAIL Canvas.getGraphics(): " + t);
            t.printStackTrace(System.out);
            ok = false;
        }

        // 4. CTC pixels + fonts: build a compatible image from the CANVAS's CTC GraphicsConfiguration,
        //    draw AA shapes + text (the BufferProvider draw stack), read it back, count non-blank.
        BufferedImage img = null;
        int nonBlank = 0, textPx = 0;
        try {
            GraphicsConfiguration gc = (c != null) ? c.getGraphicsConfiguration() : null;
            if (gc == null) {
                gc = GraphicsEnvironment.getLocalGraphicsEnvironment()
                        .getDefaultScreenDevice().getDefaultConfiguration();
            }
            System.out.println("Canvas GraphicsConfiguration = "
                + (gc == null ? "null" : gc.getClass().getName()));
            img = gc.createCompatibleImage(W, H);
            System.out.println("createCompatibleImage = "
                + img.getWidth() + "x" + img.getHeight() + " type=" + img.getType());

            Graphics2D g2 = img.createGraphics();
            g2.setColor(new Color(64, 64, 64)); g2.fillRect(0, 0, W, H);
            g2.setColor(new Color(220, 40, 40)); g2.fillRect(20, 20, 220, 90);
            g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g2.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            g2.setColor(Color.WHITE);
            g2.setFont(new Font("SansSerif", Font.BOLD, 30));
            g2.drawString("RuneLite iOS CTC", 28, 170);
            g2.dispose();

            for (int y = 0; y < H; y++) {
                for (int x = 0; x < W; x++) {
                    int p = img.getRGB(x, y) & 0xFFFFFF;
                    if (p != BG) nonBlank++;
                    if (y >= 140 && y <= 180 && x >= 26 && x <= 460) {     // text band
                        int r = (p >> 16) & 0xFF, gg = (p >> 8) & 0xFF, b = p & 0xFF;
                        if (r > 180 && gg > 180 && b > 180) textPx++;       // near-white glyph px
                    }
                }
            }
            System.out.println("compatibleImage nonBlankPx=" + nonBlank + " textPx=" + textPx);
            if (nonBlank < 5000) { System.out.println("  !! FAIL: too few non-blank px (CTC raster dead)"); ok = false; }
            if (textPx  < 100)   { System.out.println("  !! FAIL: too few text px (font/AA not rendering under CTC)"); ok = false; }
        } catch (Throwable t) {
            System.out.println("  !! FAIL CTC pixel/font readback: " + t);
            t.printStackTrace(System.out);
            ok = false;
        }

        // 5. Present the buffer through the Canvas peer Graphics (the BufferProvider -> screen blit).
        //    Informational: failure here is logged but doesn't flip the verdict (gate 3 already covers
        //    "Graphics obtainable"; on-screen pixels aren't reliably read back under CTC).
        try {
            if (cg != null && img != null) {
                cg.drawImage(img, 0, 0, null);
                System.out.println("Canvas.getGraphics().drawImage(buffer) OK");
            }
        } catch (Throwable t) {
            System.out.println("  (note) Canvas blit threw (non-fatal): " + t);
        }

        // 6. Optional PNG dump for eyeball A/B (args[0] = output path).
        if (args.length > 0 && img != null) {
            try {
                java.io.File out = new java.io.File(args[0]);
                javax.imageio.ImageIO.write(img, "png", out);
                System.out.println("wrote PNG: " + out.getAbsolutePath() + " (" + out.length() + " bytes)");
            } catch (Throwable t) {
                System.out.println("  (note) PNG write failed (non-fatal): " + t);
            }
        }

        System.out.println(ok ? "AWT-SMOKE = CANVAS+CTC OK" : "AWT-SMOKE = FAILED");
        // No System.exit — the device launcher runs probes in one shared VM.
    }
}
