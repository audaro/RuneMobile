// Phase-1 thin Phase-3 rasterizer smoke: does the *iOS JRE's* native 2D/font
// rasterizer actually render? The desktop CACIO gate (FINDINGS "Desktop CACIO
// overlay gate") could NOT settle this — desktop BufferedImage/Graphics2D/font
// scaler are platform natives independent of the CACIO toolkit, so they never
// exercised arm64-iOS code. This runs the real font + 2D path on device, cheap,
// and writes a PNG we can pull off and eyeball.
//
// Exercises the ops RuneLite's overlays use: text (font metrics + glyph raster),
// antialiased fill, BasicStroke, drawLine, fillOval, an AffineTransform, alpha.
//
// Compile (Java-8 bytecode; runs on the device JDK 21):
//     javac --release 8 -d out GlyphSmoke.java
// Run on device under JIT (output path optional; defaults to glyph-smoke.png in cwd):
//     java -cp out GlyphSmoke [/path/to/out.png]
// PASS: process exits 0, prints "OK wrote <path> (<w>x<h>, nonBlankPixels=N)" with
//       N well above 0, and the PNG shows legible text + shapes when pulled off.
// FAIL: HeadlessException / UnsatisfiedLinkError / NPE from the font or 2D natives,
//       or an all-blank image (rasterizer present but not drawing).
import java.awt.AlphaComposite;
import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.FontMetrics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.geom.AffineTransform;
import java.awt.image.BufferedImage;
import java.io.File;
import javax.imageio.ImageIO;

public class GlyphSmoke {

    public static void main(String[] args) throws Exception {
        System.out.println("java.awt.headless = " + System.getProperty("java.awt.headless"));
        System.out.println("java.vm.name      = " + System.getProperty("java.vm.name"));

        int w = 320, h = 160;
        BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING,
                RenderingHints.VALUE_TEXT_ANTIALIAS_ON);

        g.setColor(new Color(20, 24, 32));
        g.fillRect(0, 0, w, h);

        // Font path: metrics + glyph rasterization (the part desktop CACIO never proved on iOS).
        Font font = new Font(Font.SANS_SERIF, Font.BOLD, 28);
        g.setFont(font);
        FontMetrics fm = g.getFontMetrics();
        String text = "RuneLite iOS";
        int tw = fm.stringWidth(text);
        g.setColor(new Color(255, 200, 60));
        g.drawString(text, (w - tw) / 2, 50);
        System.out.println("font              = " + font.getFontName()
                + "  stringWidth(\"" + text + "\")=" + tw + "  ascent=" + fm.getAscent());

        // 2D ops RuneLite overlays use: stroke, line, antialiased oval, alpha fill, transform.
        g.setStroke(new BasicStroke(3f));
        g.setColor(new Color(80, 200, 255));
        g.drawLine(20, 90, 300, 90);
        g.setColor(new Color(120, 255, 140));
        g.fillOval(30, 100, 40, 40);
        g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER, 0.5f));
        g.setColor(new Color(255, 80, 80));
        AffineTransform at = AffineTransform.getRotateInstance(Math.toRadians(20), 220, 120);
        g.setTransform(at);
        g.fillRect(200, 100, 60, 40);
        g.dispose();

        // Count non-background pixels: proves the rasterizer actually wrote, not just allocated.
        long bg = new Color(20, 24, 32).getRGB() & 0xFFFFFFFFL;
        long nonBlank = 0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                if ((img.getRGB(x, y) & 0xFFFFFFFFL) != bg) {
                    nonBlank++;
                }
            }
        }

        String out = args.length > 0 ? args[0] : "glyph-smoke.png";
        File f = new File(out);
        if (!ImageIO.write(img, "png", f)) {
            throw new IllegalStateException("ImageIO found no PNG writer");
        }
        System.out.println("OK wrote " + f.getAbsolutePath()
                + " (" + w + "x" + h + ", nonBlankPixels=" + nonBlank + ")");
        if (nonBlank == 0) {
            throw new IllegalStateException("image is blank — rasterizer present but drew nothing");
        }
    }
}
