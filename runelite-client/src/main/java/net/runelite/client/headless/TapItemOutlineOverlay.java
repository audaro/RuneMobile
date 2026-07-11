/*
 * Tap-feedback item outline for the mobile shell.
 */
package net.runelite.client.headless;

import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.Rectangle;
import java.awt.image.BufferedImage;
import javax.inject.Inject;
import net.runelite.api.widgets.Widget;
import net.runelite.api.widgets.WidgetItem;
import net.runelite.client.game.ItemManager;
import net.runelite.client.ui.overlay.WidgetItemOverlay;

/**
 * Flash a tight CYAN silhouette on the just-tapped inventory / bank / equipment item — the engine's own item
 * outline ({@link ItemManager#getItemOutline}, the same trace the Inventory Tags plugin draws), so it hugs the
 * item sprite exactly instead of boxing it in a rectangle. Armed by {@link JavaBridge} on a widget-item tap and
 * matched here to the specific slot widget; the brief flash matches the scene model outline's beat. All access
 * is client-thread (the tap resolves under the EventBus, the render runs under the overlay pass).
 */
class TapItemOutlineOverlay extends WidgetItemOverlay
{
	// Cyan, identical to the scene NPC/object selection outline (JavaBridge.SEL_OUTLINE).
	private static final Color OUTLINE = new Color(60, 224, 255, 235);

	// The tapped item's slot widget + expiry (epoch ms). Matched by reference so duplicate item ids never
	// outline the wrong slot. volatile: armed from the tap path, read from the overlay pass.
	private static volatile Widget selWidget;
	private static volatile long selUntil;

	private final ItemManager itemManager;

	@Inject
	TapItemOutlineOverlay(ItemManager itemManager)
	{
		this.itemManager = itemManager;
		showOnInventory();
		showOnBank();
		showOnEquipment();
	}

	/** Arm the flash for the item {@code slotWidget}, held until {@code until} (epoch ms). */
	static void arm(Widget slotWidget, long until)
	{
		selWidget = slotWidget;
		selUntil = until;
	}

	@Override
	public void renderItemOverlay(Graphics2D graphics, int itemId, WidgetItem widgetItem)
	{
		if (itemId < 0 || widgetItem.getWidget() != selWidget || System.currentTimeMillis() >= selUntil)
		{
			return;
		}
		final Rectangle b = widgetItem.getCanvasBounds();
		if (b == null)
		{
			return;
		}
		final BufferedImage outline = itemManager.getItemOutline(itemId, widgetItem.getQuantity(), OUTLINE);
		if (outline != null)
		{
			graphics.drawImage(outline, b.x, b.y, null);
		}
	}
}
