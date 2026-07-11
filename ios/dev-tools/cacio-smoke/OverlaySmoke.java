/*
 * CACIO overlay smoke test (Gate 1a/1b of the desktop feasibility ladder).
 *
 * Renders a representative slice of RuneLite's Java2D overlay drawing surface to a PNG,
 * with NO display window. Mirrors the real overlay ops the audit flagged as the soft spot:
 *   - FontManager-style TTF load + GraphicsEnvironment.registerFont
 *   - TextComponent-style drawString (shadow + outline + <col=..> colour tags) via FontMetrics
 *   - OverlayUtil-style Polygon draw/fill, BasicStroke, alpha fill colour, fillOval
 *   - drawImage (sprite blit), setClip (clipping), AlphaComposite, AffineTransform rotate
 *   - antialiasing RenderingHints like RuneLite uses
 *
 * Modes:
 *   render  <fontDir> <out.png>      render the scene to out.png; print pixel stats
 *   compare <a.png> <b.png>          diff two PNGs; print differing-pixel count + max channel delta
 *
 * Run plain-headless (1a, reference) vs under the CACIO CTC toolkit (1b) and compare.
 */
import java.awt.*;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.InputStream;
import java.nio.file.Files;
import javax.imageio.ImageIO;
import javax.swing.text.StyleContext;

public class OverlaySmoke
{
    static final int W = 765, H = 503;                 // RuneLite's fixed-mode canvas size
    static final Color BG = new Color(0x22, 0x22, 0x22); // non-black bg so "did text shadow draw" is visible

    public static void main(String[] args) throws Exception
    {
        if (args.length >= 1 && args[0].equals("compare"))
        {
            compare(args[1], args[2]);
            return;
        }
        if (args.length < 3 || !args[0].equals("render"))
        {
            System.err.println("usage: OverlaySmoke render <fontDir> <out.png>  |  compare <a.png> <b.png>");
            System.exit(2);
        }
        renderScene(args[1], args[2]);
    }

    /** Render the representative overlay scene to a PNG and print env + pixel stats. Callable standalone or from a CACIO JUnit test. */
    public static void renderScene(String fontDir, String out) throws Exception
    {
        System.out.println("[env] java.awt.headless=" + System.getProperty("java.awt.headless"));
        System.out.println("[env] toolkit=" + Toolkit.getDefaultToolkit().getClass().getName());
        GraphicsEnvironment ge = GraphicsEnvironment.getLocalGraphicsEnvironment();
        System.out.println("[env] graphicsenv=" + ge.getClass().getName());
        System.out.println("[env] isHeadless=" + GraphicsEnvironment.isHeadless());

        // --- FontManager mirror: load + register the three RuneScape TTFs ---
        Font rsFont = loadAndRegister(ge, fontDir + "/runescape.ttf", Font.PLAIN, 16);
        Font rsBold = loadAndRegister(ge, fontDir + "/runescape_bold.ttf", Font.BOLD, 16);
        Font rsSmall = loadAndRegister(ge, fontDir + "/runescape_small.ttf", Font.PLAIN, 16);
        System.out.println("[font] runescape family=" + rsFont.getFamily() + " loaded ok");

        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        g.setColor(BG);
        g.fillRect(0, 0, W, H);

        // --- 1) FontMetrics + drawString: TextComponent-style with shadow, outline, colour tags ---
        g.setFont(rsFont);
        FontMetrics fm = g.getFontMetrics();
        System.out.println("[fontmetrics] ascent=" + fm.getAscent() + " height=" + fm.getHeight()
            + " stringWidth('Prayer')=" + fm.stringWidth("Prayer"));
        drawTextComponent(g, fm, "Prayer: <col=00ff00>72<col=ffffff>/99", 20, 40, Color.YELLOW, false);
        drawTextComponent(g, fm, "Outlined overlay text", 20, 70, Color.CYAN, true);
        g.setFont(rsSmall);
        drawTextComponent(g, g.getFontMetrics(), "small font 12345", 20, 95, Color.WHITE, false);
        g.setFont(rsBold);
        drawTextComponent(g, g.getFontMetrics(), "BOLD font", 20, 120, Color.ORANGE, true);

        // --- 2) OverlayUtil.renderPolygon: draw (BasicStroke 2) + alpha fill ---
        Polygon poly = new Polygon(
            new int[]{300, 360, 340, 280, 260},
            new int[]{160, 180, 240, 240, 200}, 5);
        g.setColor(Color.GREEN);
        Stroke os = g.getStroke();
        g.setStroke(new BasicStroke(2));
        g.draw(poly);
        g.setColor(new Color(0, 0, 0, 50));   // OverlayUtil's default alpha fill
        g.fill(poly);
        g.setStroke(os);

        // --- 3) fillOval (minimap dot) + drawRect + rotate transform ---
        g.setColor(Color.BLACK);
        g.fillOval(500, 160, 8, 8);
        g.setColor(Color.RED);
        g.fillOval(501, 161, 6, 6);
        g.setColor(Color.WHITE);
        double angle = Math.toRadians(20);
        g.rotate(angle, 560, 200);
        g.drawRect(540, 180, 60, 40);
        g.rotate(-angle, 560, 200);

        // --- 4) drawImage: blit a generated sprite (gradient w/ alpha) ---
        BufferedImage sprite = makeSprite(48, 48);
        g.drawImage(sprite, 300, 300, null);

        // --- 5) setClip: clipped fill (only part should show) ---
        Shape oldClip = g.getClip();
        g.setClip(420, 300, 60, 30);
        g.setColor(Color.MAGENTA);
        g.fillRect(400, 290, 200, 200);  // big rect, clipped to the small window
        g.setClip(oldClip);

        // --- 6) AlphaComposite: 50% translucent overlay panel (OverlayPanel style) ---
        Composite oc = g.getComposite();
        g.setComposite(AlphaComposite.getInstance(AlphaComposite.SRC_OVER, 0.5f));
        g.setColor(new Color(60, 80, 120));
        g.fillRect(540, 300, 180, 120);
        g.setComposite(oc);
        g.setColor(Color.WHITE);
        g.setFont(rsFont);
        g.drawString("panel @50% alpha", 550, 330);

        g.dispose();

        ImageIO.write(img, "png", new File(out));
        printStats(img, out);
    }

    /** FontManager.getFallbackFont + createFont + registerFont, mirrored. */
    static Font loadAndRegister(GraphicsEnvironment ge, String path, int style, int size) throws Exception
    {
        try (InputStream in = Files.newInputStream(new File(path).toPath()))
        {
            Font f = Font.createFont(Font.TRUETYPE_FONT, in);
            ge.registerFont(f);
            return StyleContext.getDefaultStyleContext().getFont(f.getFamily(), style, size);
        }
    }

    /** TextComponent.render mirror: <col=..> tags, shadow or 4-way outline, then coloured text. */
    static void drawTextComponent(Graphics2D g, FontMetrics fm, String text, int x, int y, Color color, boolean outline)
    {
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("<col=([0-9a-fA-F]{2,6})>").matcher(text);
        Color textColor = color;
        int idx = 0, width = 0;
        while (m.find())
        {
            String s = text.substring(idx, m.start());
            idx = m.end();
            renderText(g, textColor, x + width, y, s, outline);
            width += fm.stringWidth(s);
            textColor = Color.decode("#" + m.group(1));
        }
        String s = text.substring(idx);
        renderText(g, textColor, x + width, y, s, outline);
    }

    static void renderText(Graphics2D g, Color color, int x, int y, String text, boolean outline)
    {
        if (text.isEmpty()) return;
        g.setColor(Color.BLACK);
        if (outline)
        {
            g.drawString(text, x, y + 1);
            g.drawString(text, x, y - 1);
            g.drawString(text, x + 1, y);
            g.drawString(text, x - 1, y);
        }
        else
        {
            g.drawString(text, x + 1, y + 1); // shadow
        }
        g.setColor(color);
        g.drawString(text, x, y);
    }

    static BufferedImage makeSprite(int w, int h)
    {
        BufferedImage s = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
        for (int yy = 0; yy < h; yy++)
            for (int xx = 0; xx < w; xx++)
            {
                int a = 255 * xx / w;
                s.setRGB(xx, yy, (a << 24) | (0xFF << 16) | (yy * 5 << 8) | 0x40);
            }
        return s;
    }

    static void printStats(BufferedImage img, String label)
    {
        int bg = BG.getRGB();
        long nonBg = 0, hash = 1469598103934665603L; // FNV-1a 64
        int minX = W, minY = H, maxX = -1, maxY = -1;
        java.util.HashSet<Integer> colors = new java.util.HashSet<>();
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
            {
                int p = img.getRGB(x, y);
                hash ^= (p & 0xFFFFFFFFL); hash *= 1099511628211L;
                if ((p | 0xFF000000) != (bg | 0xFF000000))
                {
                    nonBg++;
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                    if (colors.size() < 100000) colors.add(p);
                }
            }
        System.out.println("[stats] " + label);
        System.out.println("[stats]   nonBackgroundPixels=" + nonBg + " distinctColors=" + colors.size());
        System.out.println("[stats]   bbox=[" + minX + "," + minY + " -> " + maxX + "," + maxY + "]");
        System.out.printf("[stats]   pixelHash=%016x%n", hash);
        if (nonBg < 1000)
        {
            System.out.println("[FAIL] almost nothing drew — overlay surface is broken under this toolkit");
            System.exit(1);
        }
        System.out.println("[OK] overlay surface rendered content");
    }

    static void compare(String a, String b) throws Exception
    {
        BufferedImage ia = ImageIO.read(new File(a));
        BufferedImage ib = ImageIO.read(new File(b));
        if (ia.getWidth() != ib.getWidth() || ia.getHeight() != ib.getHeight())
        {
            System.out.println("[FAIL] size mismatch " + ia.getWidth() + "x" + ia.getHeight()
                + " vs " + ib.getWidth() + "x" + ib.getHeight());
            System.exit(1);
        }
        long differing = 0, sumAbs = 0;
        int maxDelta = 0;
        for (int y = 0; y < ia.getHeight(); y++)
            for (int x = 0; x < ia.getWidth(); x++)
            {
                int pa = ia.getRGB(x, y), pb = ib.getRGB(x, y);
                if (pa == pb) continue;
                int da = Math.abs(((pa >>> 24) & 0xFF) - ((pb >>> 24) & 0xFF));
                int dr = Math.abs(((pa >> 16) & 0xFF) - ((pb >> 16) & 0xFF));
                int dg = Math.abs(((pa >> 8) & 0xFF) - ((pb >> 8) & 0xFF));
                int db = Math.abs((pa & 0xFF) - (pb & 0xFF));
                int d = Math.max(Math.max(da, dr), Math.max(dg, db));
                if (d > 0) { differing++; sumAbs += d; maxDelta = Math.max(maxDelta, d); }
            }
        long total = (long) ia.getWidth() * ia.getHeight();
        System.out.println("[compare] " + a + "  vs  " + b);
        System.out.printf("[compare]   differingPixels=%d / %d (%.3f%%)  maxChannelDelta=%d  meanDeltaOverDiff=%.2f%n",
            differing, total, 100.0 * differing / total, maxDelta, differing == 0 ? 0 : (double) sumAbs / differing);
        if (differing == 0)
            System.out.println("[OK] CACIO output is pixel-identical to plain headless");
        else if (maxDelta <= 24 && differing < total / 20)
            System.out.println("[OK] CACIO matches within antialiasing tolerance (minor subpixel font/AA diffs)");
        else
            System.out.println("[WARN] CACIO output diverges materially — inspect both PNGs");
    }
}
