/*
 * Tap-feedback sprite-widget outline for the mobile shell.
 */
package net.runelite.client.headless;

import java.awt.Dimension;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import javax.inject.Inject;
import net.runelite.client.ui.overlay.Overlay;
import net.runelite.client.ui.overlay.OverlayLayer;
import net.runelite.client.ui.overlay.OverlayPosition;

/**
 * Flash a tight cyan silhouette on the just-tapped SPRITE widget (prayer / spell / tab / toggle / …) — the same
 * {@code SpritePixels.toBufferedOutline} trace the item outline uses, so any icon-bearing widget hugs its sprite
 * shape in the scene-outline colour. {@link JavaBridge} builds the outline image (off the widget's spriteId) and
 * arms this overlay with it + the widget's canvas position; the brief flash matches the item/NPC beat. Items
 * keep their own {@link TapItemOutlineOverlay}. All access is client-thread (tap resolves under the EventBus,
 * render runs under the overlay pass).
 */
class TapWidgetOutlineOverlay extends Overlay
{
	private static volatile BufferedImage outline;
	private static volatile int drawX, drawY;
	private static volatile long until;

	@Inject
	TapWidgetOutlineOverlay()
	{
		setPosition(OverlayPosition.DYNAMIC);
		setLayer(OverlayLayer.ABOVE_WIDGETS);
	}

	/** Arm the flash: draw {@code img} at canvas ({@code x}, {@code y}) until {@code expiry} (epoch ms). */
	static void arm(BufferedImage img, int x, int y, long expiry)
	{
		outline = img;
		drawX = x;
		drawY = y;
		until = expiry;
	}

	@Override
	public Dimension render(Graphics2D graphics)
	{
		final BufferedImage img = outline;
		if (img != null && System.currentTimeMillis() < until)
		{
			graphics.drawImage(img, drawX, drawY, null);
		}
		return null;
	}
}
