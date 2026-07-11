/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
package net.runelite.client.headless;

import com.google.inject.Injector;
import java.awt.Canvas;
import java.awt.Color;
import java.awt.EventQueue;
import java.awt.Rectangle;
import java.awt.Toolkit;
import java.awt.event.FocusEvent;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.awt.event.MouseWheelEvent;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Actor;
import net.runelite.api.Client;
import net.runelite.api.Constants;
import net.runelite.api.DecorativeObject;
import net.runelite.api.GameObject;
import net.runelite.api.GameState;
import net.runelite.api.GroundObject;
import net.runelite.api.MainBufferProvider;
import net.runelite.api.Menu;
import net.runelite.api.MenuAction;
import net.runelite.api.MenuEntry;
import net.runelite.api.Scene;
import net.runelite.api.Tile;
import net.runelite.api.TileObject;
import net.runelite.api.VarClientInt;
import net.runelite.api.WallObject;
import net.runelite.api.WorldView;
import net.runelite.api.events.BeforeMenuRender;
import net.runelite.api.events.MenuOpened;
import net.runelite.api.events.MenuOptionClicked;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.widgets.Widget;
import net.runelite.client.RuneLite;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.ui.overlay.outline.ModelOutlineRenderer;

/**
 * Phase-4 (W3) sub-goal B: the native&lt;-&gt;Java facade for a <em>real interactive</em> client on iOS.
 *
 * <p>This is the one class the native shell calls into via reverse JNI. It exposes two seams:
 * <ul>
 *   <li><b>Live framebuffer blit</b> — {@link #getFrameWidth()}/{@link #getFrameHeight()}/
 *       {@link #getFramePixels()} hand the engine's composited {@code mainBufferProvider} pixels straight
 *       to the native side each screen refresh. This replaces the §6.2 PNG-capture-to-disk display path
 *       (which was choppy, disk-bound and budget-capped) with a direct, smooth blit.</li>
 *   <li><b>Touch ingress</b> — {@link #onTouch(int, int, int, int)} turns a UIKit touch (already mapped to
 *       game coordinates by the native side) into AWT {@link MouseEvent}s posted to the toolkit
 *       {@link EventQueue} with the gamepack {@link Canvas} as source. Sub-goal A proved the on-device CTC
 *       EventQueue accepts off-window posts, so this is the same proven path HeadlessLogin uses, now driven
 *       by real touches instead of a scripted click.</li>
 * </ul>
 *
 * <p>{@link #register(Client)} (top of {@code Hooks.draw}) keeps the bridge pointed at the live client,
 * and {@link #snapshot(MainBufferProvider)} (after the overlays composite) publishes each complete frame.
 * Entirely inert unless {@code -Drunelite.bridge=true}, so it adds nothing to the stock desktop client.
 *
 * <p>Thread model: {@code register} runs on the engine/AWT thread; the native side calls the getters,
 * {@link #onTouch} and {@link #onClick} from the UI thread (JNI-attached). {@code EventQueue.postEvent}
 * is thread-safe, and the pixel array is the buffer's live backing store — reading it off-thread can
 * momentarily tear, which is acceptable for a display.
 *
 * <p><b>Input contract (Phase 5).</b> The native side owns gesture <em>recognition</em> (UIKit gesture
 * recognizers: tap, long-press, pan, pinch) and this facade exposes only the raw AWT primitives:
 * <ul>
 *   <li>{@link #onClick(int, int, int)} — a discrete <em>tap</em>: the full focus-prime + move + press +
 *       release + click sequence at one point (the proven {@code HeadlessLogin} click shape). Button 1 =
 *       a left tap (walk/interact / menu-entry select); button 3 = a long-press (open the right-click
 *       menu).</li>
 *   <li>{@link #onTouch(int, int, int, int)} — a <em>drag</em> stream: press / drag / release with NO
 *       synthesized click on release. This is the camera / scroll primitive; a release here is just a
 *       {@code MOUSE_RELEASED}. Earlier (sub-goal B) this method auto-clicked on every UP, which produced
 *       a phantom click at the end of every drag and long-press — removed.</li>
 * </ul>
 */
@Slf4j
public final class JavaBridge
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.bridge");

	// Touch event types — kept in lockstep with the native side (the pan recognizer's began/changed/ended).
	public static final int TOUCH_DOWN = 0;
	public static final int TOUCH_MOVE = 1;
	public static final int TOUCH_UP = 2;

	private static volatile Client client;

	// Wired from HeadlessClientUI.init; in-game taps resolve through the engine ON THE CLIENT THREAD
	// (scene/menu reads are only safe there).
	private static volatile ClientThread clientThread;
	// Touch-targeting diagnostics (the full coordinate chain + per-tap settle/consume/park-verify trace).
	// OFF by default — the tap path is device-confirmed; flip on with -Drunelite.touch.diag=true to debug a
	// regression. All [touchdiag] sites are gated behind this, so when off they (incl. the park-verify read)
	// go fully inert. Matches the gpudiag/menupeek convention (dev flags default off on master).
	private static final boolean TOUCH_DIAG =
		Boolean.parseBoolean(System.getProperty("runelite.touch.diag", "false"));
	// Hide the vanilla OSRS click cross (the red/yellow animated X at the tap point). It became visible once the
	// engine UI composites in GPU mode and is redundant with our own native click ring. Blank the cross sprites
	// once (replace each with a 1x1 transparent sprite). Toggle with -Drunelite.touch.hideClickCross=false.
	private static final boolean HIDE_CLICK_CROSS =
		Boolean.parseBoolean(System.getProperty("runelite.touch.hideClickCross", "true"));
	private static volatile boolean clickCrossHidden;

	/** One-shot: blank the engine's click-cross sprites so no vanilla X draws at the tap (client thread). */
	private static void hideClickCross(Client c)
	{
		if (clickCrossHidden || !HIDE_CLICK_CROSS)
		{
			return;
		}
		try
		{
			final net.runelite.api.SpritePixels[] cross = c.getCrossSprites();
			if (cross == null)
			{
				return;   // not loaded yet — try again on the next tap
			}
			final net.runelite.api.SpritePixels blank = c.createSpritePixels(new int[]{0}, 1, 1);
			for (int i = 0; i < cross.length; i++)
			{
				cross[i] = blank;
			}
			clickCrossHidden = true;
			log.info("[touch] vanilla click cross hidden ({} sprites)", cross.length);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.hideClickCross", ex);
		}
	}

	/** Log the engine canvas + world-viewport geometry against an incoming tap (client thread; reads are safe here). */
	private static void diagGeometry(Client c, String tag, int x, int y)
	{
		if (!TOUCH_DIAG)
		{
			return;
		}
		try
		{
			log.info("[touchdiag] {} tap={},{} canvas={}x{} resized={} viewport=({},{} {}x{}) inVp={}",
				tag, x, y,
				c.getCanvasWidth(), c.getCanvasHeight(), c.isResized(),
				c.getViewportXOffset(), c.getViewportYOffset(), c.getViewportWidth(), c.getViewportHeight(),
				inWorldViewport(c, x, y));
		}
		catch (RuntimeException ex)
		{
			log.info("[touchdiag] {} tap={},{} (geometry read failed: {})", tag, x, y, ex.toString());
		}
	}

	// Selection feedback, drawn in Java straight into the game frame (so it's tight + tracks the entity, unlike
	// a native polygon of the loose convex hull). A left tap whose CONSUMED click (MenuOptionClicked) hit an
	// NPC/object flashes a tight MODEL OUTLINE on it for SEL_FLASH_MS. (Walk destination is left to RuneLite's
	// own Tile Indicators plugin — "Highlight destination tile" — rather than drawing our own marker.) Set +
	// consumed on the client thread (the click confirmation and {@link #drawSelection}).
	private static final long SEL_FLASH_MS = Long.getLong("runelite.touch.selFlashMs", 1500L);
	private static Actor selActor;            // selected NPC/player to outline (null = none)
	private static TileObject selObject;      // selected scene object to outline (null = none)
	private static long selUntil;             // outline fades after this timestamp
	private static ModelOutlineRenderer outliner;   // lazily resolved from the injector (tight model outline)
	// Bumped once each time an in-game left tap's CONSUMED click (MenuOptionClicked truth) was an actual
	// interaction, NOT a bare walk/cancel. The native shell polls getInteractTapSeq() and fires a light haptic
	// when it advances (the official Jagex Mobile "you grabbed something" buzz).
	private static volatile int interactTapSeq;

	// Tap-KIND truth for the native shell's tap feedback (Android): every resolved left tap publishes WHAT it
	// hit, from the consumed MenuOptionClicked entry, so the shell can ring ONLY for a real scene tap (walk /
	// scene interaction), draw a selection BORDER for a widget op (inventory item / prayer / spell / tab …),
	// and show nothing for a dead/cancel click. getTapKindSeq() bumps once per resolution; getLastTapKind()
	// holds the kind; getLastWidgetBounds() packs the widget's canvas-px bounds for the WIDGET kind. This is
	// additive — interactTapSeq (haptic + the iOS ring) keeps its exact old meaning.
	public static final int TAP_KIND_NONE = 0;    // walk-cancel / no action -> no feedback
	public static final int TAP_KIND_WALK = 1;    // a deliberate walk -> yellow ring
	public static final int TAP_KIND_SCENE = 2;   // NPC / object / player / ground item -> red ring
	public static final int TAP_KIND_WIDGET = 3;  // an interface op -> selection border, no ring
	private static volatile int tapKindSeq;
	private static volatile int lastTapKind;
	private static volatile int wbX, wbY, wbW, wbH;   // last WIDGET-kind bounds (canvas px)

	// ===== Engine-resolved tap state machine (TOUCH-TARGETING-PLAN.md Phase 1) =====
	// A left tap is never re-hit-tested by the engine: the press is consumed against the menu the engine
	// built from the cursor position earlier IN THE SAME CLIENT TICK. So we move the synthetic cursor to the
	// literal tap point, WAIT until the engine has demonstrably resolved it (cursor-position match AND a
	// stable left-click tail fingerprint — the MenuPeek settle observable), only then post the click, and
	// classify what actually fired from MenuOptionClicked. All state below is CLIENT-THREAD-ONLY (the tap
	// ingress runs under ClientThread.invoke, tapTick under Hooks.draw, the EventBus handlers under the
	// engine's click-detection step — all the same thread).
	private enum TapState
	{
		IDLE, AWAIT_ENGINE, CLICKED
	}

	private static TapState tapState = TapState.IDLE;
	private static int tapX;              // the pending tap point (canvas px) — also the click point
	private static int tapY;
	private static int settleFrames;      // frames spent in AWAIT_ENGINE since the move was posted
	private static int stableFrames;      // consecutive frames with position match + identical tail fp
	private static String lastTailFp;     // previous frame's tail fingerprint
	private static int posMatchFrame;     // first frame the engine cursor matched the tap (-1 = never; diag)
	private static String clickFp;        // tail fp at click-post time (diag: predicted vs consumed, the ⇔ check)
	private static int clickedFrames;     // frames spent in CLICKED waiting for the truth event
	private static boolean queuedTap;     // exactly one follow-up tap queued while CLICKED
	private static int queuedX;
	private static int queuedY;
	private static volatile int parkVerifyFrames;  // diag countdown: read the tail a few frames after a park
	// Settle gate tuning. MAX_SETTLE frames is the fail-open cap (never drop a tap); STABLE_NEEDED consecutive
	// identical reads accept. Desktop settles ≤2 frames (MenuPeek-proven); the cap covers a lagging device EDT.
	private static final int MAX_SETTLE = Integer.getInteger("runelite.touch.settleMax", 12);
	private static final int STABLE_NEEDED = Integer.getInteger("runelite.touch.settleStable", 2);
	private static final int CLICKED_TIMEOUT = Integer.getInteger("runelite.touch.clickTimeout", 10);
	private static boolean truthSubscribed;  // EventBus registration is one-shot (client thread)

	// Published complete frames for the live blit. The native side reads at the display refresh (up to
	// 120 Hz) but the engine composites at ~50 fps, so reading mainBufferProvider directly catches it
	// mid-clear/mid-draw -> fast flashing. Instead we snapshot ONLY at the post-overlay-composite hook
	// (when the frame is whole) into a double buffer, and publish via the volatile `frame` ref so the
	// native reader always copies out a complete, stable frame. `frameSeq` lets the native side skip the
	// (costly) CGImage rebuild when the engine hasn't composited a new frame since the last display tick.
	private static volatile int[] frame;
	private static volatile int frameW;
	private static volatile int frameH;
	private static volatile int frameSeq;
	private static int[] bufA;
	private static int[] bufB;
	private static boolean useA = true;

	// iOS load-in flash guard (GPU mode). The published GPU frame is the composited 3D+UI. When transitioning
	// from the login/loading screen into the world, RLHD clears the scene to the region's SKY/fog colour (a
	// daytime light blue) and renders it for the frames before the zone geometry finishes uploading — and since
	// the OSRS loading screen doesn't cover the 3D viewport in this composite (unlike desktop), that bare sky
	// flashes through. Device timing (gpudiag) showed the FIRST drawScene fires once the world is already
	// LOGGED_IN + viewport-sized, but geometry is still uploading for a few frames after that, so releasing on the
	// very first scene draw still publishes a sky frame. So we COUNT scene draws and hold the previous frame (the
	// loading screen) until SCENE_WARMUP of them have rendered — by then the zones are uploaded and the world has
	// geometry. The counter is re-armed to 0 whenever the game leaves the in-world states (login screen / hopping
	// / connection lost — but NOT plain LOADING, so seamless in-play region streaming while running isn't held).
	private static volatile int sceneDrawCount;
	private static final int SCENE_WARMUP = 6;

	/** Hooks.drawScene -> count a rendered 3D frame. */
	public static void noteSceneDraw() { sceneDrawCount++; }
	/** Hooks.draw on a non-world game state -> re-arm the load-in hold. */
	public static void armSceneHold() { sceneDrawCount = 0; }
	/** Direct-present (no gpuPublish gate): the native shell polls this to know when the world is warmed up
	 * (geometry uploaded), so it can reveal the GPU layer over the CPU loading-screen blit without a sky flash. */
	public static boolean presentReady() { return sceneDrawCount >= SCENE_WARMUP; }

	// GPU Route C white-flash diagnostic (one-shot): dump a handful of in-world composited GPU frames to PNG so
	// the render bug can be seen off-device (the live frame can't be pulled). Gated -Drunelite.gpuframedump=true.
	private static final boolean FRAME_DUMP = Boolean.getBoolean("runelite.gpuframedump");
	private static int frameDumpCount;
	private static int lastFrameDumpSeq;

	// Input bookkeeping (only ever touched from the single native UI thread that drives onTouch/onClick).
	private static boolean focused;       // FocusEvent gained — keyboard/mouse accepted
	private static volatile boolean entered;  // MOUSE_ENTERED posted — pointer currently "present" (volatile:
	                                      // parkPointer runs from the client thread after a consumed tap)
	private static boolean pressed;
	private static int pressButton = MouseEvent.BUTTON1;
	private static boolean shiftHeld;     // sticky-Shift: a held VK_SHIFT KEY_PRESSED with no release (see setShiftHeld)
	private static boolean ctrlHeld;      // sticky-Ctrl: same latch for VK_CONTROL (see setCtrlHeld)
	private static boolean altHeld;       // sticky-Alt:  same latch for VK_ALT (Ground-Items Alt-highlight; see setAltHeld)

	// Camera (two-finger pan -> direct yaw/pitch target). Sub-pixel remainders so a slow drag still turns
	// (a small per-event pixel delta would otherwise truncate to 0 yaw units).
	// rev239 widened the camera angle from 11-bit (JAU, 0-2047) to 14-bit (JAU14, 0-16383) — an 8x larger
	// unit space — so the per-pixel sensitivity and the pitch clamp both scale up 8x (and yaw now wraps mod 2^14).
	private static final float YAW_UNITS_PER_PX = 12.0f;   // ~a screen-width drag ≈ half a turn (1.5 * 8)
	private static final float PITCH_UNITS_PER_PX = 9.6f;  // 1.2 * 8
	private static final int PITCH_MIN = 1024;             // RS camera-pitch clamp (normal range, JAU14: 128 * 8)
	private static final int PITCH_MAX = 3064;             // 383 * 8
	private static float yawRemainder;
	private static float pitchRemainder;
	// Two-finger camera pan: native posts raw pixel deltas from the main thread (onCameraDrag); they accumulate
	// here and are applied on the client thread in tapTick. RuneLite's camera state is client-thread-only — the
	// old in-place read-modify-write off the JNI thread lost updates against the engine's per-tick interpolation
	// (yaw jitter under load). yawRemainder/pitchRemainder are now touched only on the client thread.
	private static final java.util.concurrent.atomic.AtomicInteger camDragDx = new java.util.concurrent.atomic.AtomicInteger();
	private static final java.util.concurrent.atomic.AtomicInteger camDragDy = new java.util.concurrent.atomic.AtomicInteger();
	// INPUT_TYPE snapshot taken on the client thread in tapTick; isTextInputOpen() reads this volatile instead of
	// the live varc array off-thread (which the engine can reallocate under the reader).
	private static volatile boolean textInputOpen;

	// Idle-logout keepalive. Native-UI touches (chat-tab/grid op-script replays, config/notes/world/overlay
	// writes, Swing-panel dispatch, plugin enable/pin/hub) post NO canvas MouseEvent, so the gamepack's
	// mouse-idle counter climbs to the ~5-min AFK logout while the user is actively using the native UI. A
	// native touch bumps lastNativeUiActivityMs (lock-free, any thread); the client thread drains it in
	// tapTickImpl and posts ONE MOUSE_MOVED(-1,-1) — parkPointer's proven "picks nothing" point — which resets
	// the gamepack mouse-idle WITHOUT moving any real hover or open-menu highlight. Same accumulate-then-drain
	// shape as the camera pan above. Kill-switch: -Drunelite.idleKeepalive=false.
	private static final boolean IDLE_KEEPALIVE = Boolean.parseBoolean(System.getProperty("runelite.idleKeepalive", "true"));
	private static final long IDLE_KEEPALIVE_THROTTLE_MS = 2000L;
	private static volatile long lastNativeUiActivityMs;   // bumped by keepAlive() from the native-UI thread
	private static volatile long lastKeepalivePostMs;      // last MOUSE_MOVED(-1,-1) we emitted (client thread)

	private JavaBridge()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Called at the top of {@code Hooks.draw} each frame to keep the bridge pointed at the live client. */
	public static void register(Client c)
	{
		client = c;
	}

	/**
	 * Wire the {@link ClientThread} used to resolve in-game taps on the game thread. Called once from
	 * {@code HeadlessClientUI.init}. Without it, taps fall back to the plain one-batch click.
	 */
	public static void setClientThread(ClientThread ct)
	{
		clientThread = ct;
	}

	/**
	 * Called from {@code Hooks.draw} AFTER the overlays composite (the same point {@code HeadlessCapture}
	 * dumps PNGs) — i.e. when {@code mainBufferProvider} holds a <em>complete</em> frame. Copies it into a
	 * double buffer and publishes it for the live blit. Snapshotting here (not at the native read) is what
	 * eliminates the mid-composite flashing.
	 */
	public static void snapshot(MainBufferProvider b)
	{
		if (!ENABLED || b == null)
		{
			return;
		}
		final int[] px = b.getPixels();
		final int w = b.getWidth();
		final int h = b.getHeight();
		if (px == null || w <= 0 || h <= 0)
		{
			return;
		}
		final int n = w * h;
		if (px.length < n)
		{
			return;
		}
		int[] dst = useA ? bufA : bufB;
		if (dst == null || dst.length != n)
		{
			dst = new int[n];
			if (useA)
			{
				bufA = dst;
			}
			else
			{
				bufB = dst;
			}
		}
		System.arraycopy(px, 0, dst, 0, n);
		frameW = w;
		frameH = h;
		frame = dst;        // publish (volatile)
		frameSeq++;         // bump LAST so a native reader that sees the new seq also sees this frame
		useA = !useA;       // next snapshot fills the OTHER buffer, so this one stays stable a full cycle
	}

	// ---- GPU (Route C) publish seam ---------------------------------------------------------------------
	// In GPU mode the composited frame lives in the EAGL FBO, not mainBufferProvider. The native swapBuffers
	// shim glReadPixels-es the FBO straight into one of the SAME double buffers and publishes it, becoming the
	// SOLE frameSeq publisher (Hooks gates the CPU snapshot off when isGpu). The two calls run back-to-back on
	// the client thread (no useA flip between them), so the buffer gpuFrameBackBuffer hands out is exactly the
	// one gpuPublish then publishes.

	/** The next back buffer (w*h ints), allocated/resized as needed, for the native shim to write into. */
	public static int[] gpuFrameBackBuffer(int w, int h)
	{
		final int n = w * h;
		int[] dst = useA ? bufA : bufB;
		if (dst == null || dst.length != n)
		{
			dst = new int[n];
			if (useA)
			{
				bufA = dst;
			}
			else
			{
				bufB = dst;
			}
		}
		return dst;
	}

	/** Publish the back buffer the native shim just filled (vertical-flipped, R/B-swizzled 0x00RRGGBB). */
	public static void gpuPublish(int w, int h)
	{
		// Hold the last good frame through the load-in warmup (the sky-flash guard, above). Not bumping frameSeq
		// keeps the native reader on the previous frame; useA doesn't flip, so the back buffer the shim just
		// filled is simply overwritten next frame and the double buffering stays consistent.
		if (sceneDrawCount < SCENE_WARMUP)
			return;
		frameW = w;
		frameH = h;
		frame = useA ? bufA : bufB;
		frameSeq++;
		useA = !useA;
		if (FRAME_DUMP)
		{
			maybeDumpFrame(w, h);
		}
	}

	// One-shot: save ~8 in-world GPU frames (spaced ~50 seq apart) under -Drunelite.gpuframedump.dir (default
	// java.io.tmpdir, so it is adb-pullable). The published int[] is 0x00RRGGBB (the native readback already
	// flipped + swizzled). Runs on the client thread — a few PNG encodes is fine for a temporary diagnostic.
	private static void maybeDumpFrame(int w, int h)
	{
		if (frameDumpCount >= 8 || frameSeq < 150)   // warmup: skip startup/welcome frames so we catch in-world
		{
			return;
		}
		if (lastFrameDumpSeq != 0 && frameSeq - lastFrameDumpSeq < 50)
		{
			return;
		}
		final int[] src = frame;
		if (src == null || src.length < w * h)
		{
			return;
		}
		lastFrameDumpSeq = frameSeq;
		try
		{
			final int[] copy = java.util.Arrays.copyOf(src, w * h);
			final java.awt.image.BufferedImage img =
				new java.awt.image.BufferedImage(w, h, java.awt.image.BufferedImage.TYPE_INT_RGB);
			img.setRGB(0, 0, w, h, copy, 0, w);
			final String base = System.getProperty("runelite.gpuframedump.dir",
				System.getProperty("java.io.tmpdir", "."));
			final java.io.File dir = new java.io.File(base, "routec-frames");
			dir.mkdirs();
			final java.io.File out = new java.io.File(dir,
				String.format("gpuframe-%02d-seq%d-%dx%d.png", frameDumpCount, frameSeq, w, h));
			javax.imageio.ImageIO.write(img, "png", out);
			frameDumpCount++;
			log.info("[gpuframedump] wrote {} ({}x{})", out.getName(), w, h);
		}
		catch (Throwable t)
		{
			log.warn("[gpuframedump] frame dump failed", t);
		}
	}

	/** Canvas dimensions for sizing the EAGL FBO (queried by the native createGLContext). 0 if no client yet. */
	public static int canvasWidth()
	{
		final Client c = client;
		return c == null ? 0 : c.getCanvasWidth();
	}

	public static int canvasHeight()
	{
		final Client c = client;
		return c == null ? 0 : c.getCanvasHeight();
	}

	// ---- Live framebuffer blit (native pulls these each screen refresh) --------------------------------

	public static int getFrameWidth()
	{
		return frameW;
	}

	public static int getFrameHeight()
	{
		return frameH;
	}

	/**
	 * Monotonically increasing counter bumped once per published frame. The native side caches the last
	 * value it rendered and skips the {@code CGImage} rebuild when it is unchanged (the display refreshes
	 * faster than the engine composites), so an idle login screen costs almost nothing per tick.
	 */
	public static int getFrameSeq()
	{
		return frameSeq;
	}

	/**
	 * The latest <em>complete</em> composited frame as packed {@code 0xAARRGGBB} ints (a stable snapshot,
	 * not the live back buffer). Returns {@code null} before the first frame.
	 */
	public static int[] getFramePixels()
	{
		return frame;
	}

	// ---- Input ingress (native recognizes the gesture, then calls these with game coords) --------------

	/** Resolve the live gamepack canvas, or {@code null} if the bridge is off / the client isn't ready. */
	private static Canvas liveCanvas()
	{
		if (!ENABLED)
		{
			return null;
		}
		final Client c = client;
		return c == null ? null : c.getCanvas();
	}

	/**
	 * Assert canvas focus once. There is no native focus owner headless, so the gamepack ignores mouse
	 * <em>and</em> keyboard input until it believes the canvas has focus.
	 */
	private static void ensureFocus(EventQueue q, Canvas canvas)
	{
		if (!focused)
		{
			q.postEvent(new FocusEvent(canvas, FocusEvent.FOCUS_GAINED, false, null));
			focused = true;
		}
	}

	/**
	 * Assert focus + pointer <em>presence</em> for an interaction: focus once, then a {@code MOUSE_ENTERED}
	 * if the pointer is currently "absent" (we park it after taps / on camera drags so nothing stays
	 * highlighted — see {@link #parkPointer()}). Mirrors what {@code HeadlessLogin} primes before a click.
	 */
	private static void primeFocus(EventQueue q, Canvas canvas, long t, int x, int y)
	{
		ensureFocus(q, canvas);
		if (!entered)
		{
			q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_ENTERED, t, 0, x, y, 0, false));
			entered = true;
		}
	}

	/**
	 * Native-facing alias for {@link #parkPointer()} (the JNI side resolves this name; keep it stable).
	 * Called when a camera/pinch gesture begins so nothing stays hovered/highlighted under a frozen cursor.
	 */
	public static void clearHover()
	{
		parkPointer();
	}

	/**
	 * Park the synthetic cursor at a neutral point: {@code MOUSE_MOVED} to (−1,−1), then {@code MOUSE_EXITED}.
	 * The engine does NOT clear its tracked mouse position on EXITED (bug 3: park-by-exit left the cursor at
	 * the last tap, the engine kept picking there each tick, and a zoom re-projected a model under it — the
	 * stuck hover label). Hover ends only by MOVING to a point that picks nothing; the EXITED is just AWT
	 * hygiene. On a touch device there is no persistent cursor — a finger is only "on" the screen during a
	 * tap — so this runs after every consumed tap / menu select and when a camera/pinch gesture begins.
	 * (Fallback if the engine ever clamps negative coords: park off-canvas at canvas+50 — device-verify #1.)
	 */
	public static void parkPointer()
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t, 0, -1, -1, 0, false));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_EXITED, t + 1, 0, -1, -1, 0, false));
		entered = false;
		if (TOUCH_DIAG)
		{
			parkVerifyFrames = 3;   // few frames out: the EDT folds the move, then a tick rebuilds the menu
		}
		log.debug("[touch] parkPointer -> MOVED(-1,-1) + EXITED");
	}

	/**
	 * Reset the engine's idle-logout timer from a native-UI touch that posts no canvas {@code MouseEvent}
	 * (chat-tab/grid op-replay, config/notes/world/overlay writes, Swing-panel dispatch, plugin enable/pin/hub).
	 * <b>Lock-free</b>: records the touch time only — safe to call from any thread (JNI / native-UI). The client
	 * thread drains it in {@link #tapTickImpl} and posts ONE {@code MOUSE_MOVED(-1,-1)} (parkPointer's neutral
	 * "picks nothing" point) iff it's safe, which advances the gamepack's mouse-idle counter — that counter is
	 * driven by the move <em>event</em>, not by the coordinate landing on anything — without moving any real
	 * hover or open-menu highlight. No-op when disabled ({@code -Drunelite.idleKeepalive=false}); the LOGGED_IN
	 * gate lives in the drain. Mirrors {@link #onCameraDrag}'s bump-then-drain split so there is no engine
	 * access off the client thread.
	 */
	public static void keepAlive()
	{
		if (!ENABLED || !IDLE_KEEPALIVE)
		{
			return;
		}
		lastNativeUiActivityMs = System.currentTimeMillis();
	}

	/**
	 * A discrete tap at {@code (x,y)} (gamepack-canvas pixels): the full focus-prime + move + press +
	 * release + click sequence — the proven {@code HeadlessLogin.synthesizeClick} shape. {@code button} is
	 * 1 (left tap: walk / interact / select a menu entry) or 3 (long-press: open the right-click menu).
	 *
	 * <p>This is the ONLY path that synthesizes {@code MOUSE_CLICKED}; the native side calls it solely for
	 * a recognized tap or long-press, so a drag (which streams through {@link #onTouch}) never produces a
	 * spurious click.
	 *
	 * <p><b>Engine-resolved tap.</b> A left tap in-game always clicks the <em>literal tap point</em> — same
	 * as the official OSRS mobile client (no aim assist; the model silhouette is the clickbox, with the
	 * engine's own built-in pick slop). The engine makes every decision: we move the synthetic cursor to the
	 * tap, let the per-tick menu pipeline resolve it, then post the click there. What the click actually did
	 * is read back from {@code MenuOptionClicked} (the consumed entry) — feedback comes from that truth, not
	 * from a pre-click geometric guess.
	 */
	public static void onClick(int x, int y, int button)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final ClientThread ct = clientThread;
		final Client c = client;
		final boolean inGame = ct != null && c != null && c.getGameState() == GameState.LOGGED_IN;
		if (button == MouseEvent.BUTTON1 && inGame)
		{
			// In-game left tap, resolved on the client thread (scene/menu reads are only safe there).
			ct.invoke(() -> startLeftTap(canvas, ct, c, x, y));
			return;
		}
		if (button == MouseEvent.BUTTON3 && inGame)
		{
			// In-game right tap (long-press menu): snap to the same interactable a left tap would, so the menu
			// opens FOR that entity (its options on top) instead of "Walk here" when you press near but not on it.
			ct.invoke(() -> startRightClick(canvas, ct, c, x, y));
			return;
		}
		synthesizeClick(canvas, x, y, button);
	}

	/**
	 * In-game right-tap (client thread): open the engine menu at the literal press point — move a cycle
	 * before the right-press so the engine builds the menu FOR that point (a same-batch move+press would use
	 * the previous cursor position). No aim assist, same as the official mobile client; the open menu already
	 * has slide-to-select forgiveness.
	 */
	private static void startRightClick(Canvas canvas, ClientThread ct, Client c, int x, int y)
	{
		diagGeometry(c, "R", x, y);
		hideClickCross(c);
		postMove(canvas, x, y);
		ct.invokeLater(() -> postClickButtons(canvas, x, y, MouseEvent.BUTTON3));
	}

	/**
	 * In-game left-tap ingress (client thread). Always targets the LITERAL tap point — no centroid/snap
	 * redirection; the engine's own pick (model silhouette + built-in slop) decides what the tap hit.
	 * With the engine menu open the tap selects the row under it directly (the engine consumes it against
	 * the OPEN menu, no settle needed). Otherwise the tap enters the state machine: post the move, wait for
	 * the engine to demonstrably resolve the point ({@link #tapTick}), click, and classify the consumed
	 * entry ({@link #onMenuOptionClicked}) — outline/haptic feedback comes from that truth.
	 */
	private static void startLeftTap(Canvas canvas, ClientThread ct, Client c, int x, int y)
	{
		diagGeometry(c, "L", x, y);
		hideClickCross(c);
		ensureTruthSubscribed();
		if (c.isMenuOpen())
		{
			postMove(canvas, x, y);
			ct.invokeLater(() ->
			{
				postClickButtons(canvas, x, y, MouseEvent.BUTTON1);
				ct.invokeLater(JavaBridge::parkPointer);
			});
			return;
		}
		if (tapState == TapState.CLICKED)
		{
			// Mid-confirmation: queue exactly ONE follow-up tap; it starts on the truth/timeout transition.
			queuedTap = true;
			queuedX = x;
			queuedY = y;
			return;
		}
		// IDLE starts fresh; a new tap during AWAIT_ENGINE REPLACES the pending tap (re-move, reset counters).
		beginAwait(canvas, x, y);
	}

	/** Record the pending tap, post the cursor move to it, and enter {@code AWAIT_ENGINE} (client thread). */
	private static void beginAwait(Canvas canvas, int x, int y)
	{
		tapX = x;
		tapY = y;
		settleFrames = 0;
		stableFrames = 0;
		lastTailFp = null;
		posMatchFrame = -1;
		tapState = TapState.AWAIT_ENGINE;
		postMove(canvas, x, y);
	}

	/**
	 * Per-frame settle gate + click watchdog — called once per frame from {@code Hooks.draw} (client thread,
	 * after the engine tick rebuilt the menu). In {@code AWAIT_ENGINE}: accept once the engine's tracked
	 * cursor equals the tap point (proves the EDT folded our move) AND the left-click tail fingerprint is
	 * identical for {@link #STABLE_NEEDED} consecutive frames (proves the engine rebuilt the menu from it) —
	 * then post the real click at the tap point. {@link #MAX_SETTLE} frames caps the wait (fail-open: click
	 * anyway, never drop a tap). In {@code CLICKED}: time out back to IDLE if no truth event arrives
	 * (shouldn't happen — MenuOptionClicked fires for every left click incl. walk/Cancel).
	 */
	public static void tapTick(Client c)
	{
		if (!ENABLED || c == null)
		{
			return;
		}
		try
		{
			tapTickImpl(c);
		}
		catch (Throwable t)
		{
			// QA-P1-07: a throw here would escape into Hooks.draw and kill the engine frame thread. Drop any
			// in-flight tap so a poisoned state isn't retried (and re-thrown) every frame, and surface it
			// rate-limited rather than silently. tapTickImpl's leaf reads self-guard; this is the top-level
			// backstop (the HeadlessSeams seam guard would also catch it, but resetting the state machine here
			// is the cleaner recovery).
			tapState = TapState.IDLE;
			queuedTap = false;
			BridgeFaults.note("JavaBridge.tapTick", t);
		}
	}

	/**
	 * Body of {@link #tapTick(Client)} — see that method's Javadoc for the settle-gate/click-watchdog
	 * contract. Split out so the wrapper can keep a throw from escaping into the engine frame loop.
	 */
	private static void tapTickImpl(Client c)
	{
		applyCameraDrag(c);        // drain accumulated two-finger-pan deltas (camera writes are client-thread-only)
		maybePostIdleKeepalive(c); // drain native-UI activity -> MOUSE_MOVED(-1,-1) if gated + throttled (idle reset)
		snapshotTextInputOpen(c);  // publish INPUT_TYPE for isTextInputOpen() to read off the client thread
		snapshotInventoryBounds(c); // DRAG-1: publish the inventory item-grid bounds for the native item-drag branch
		snapshotReorderPaneBounds(c); // DRAG-1b: publish Prayer/Spellbook/Bank pane bounds for native reorder-drag routing
		// Deterministic early registration (boolean-gated, retries until the injector is live): the
		// BeforeMenuRender suppression below must be in place before the FIRST menu ever opens, not
		// lazily on the first tap.
		ensureTruthSubscribed();
		if (parkVerifyFrames > 0 && tapState == TapState.IDLE)
		{
			if (--parkVerifyFrames == 0)
			{
				final net.runelite.api.Point mp = c.getMouseCanvasPosition();
				log.info("[touchdiag] park-verify: mouse={},{} tail={} (expect off-canvas + Cancel-only)",
					mp == null ? "?" : mp.getX(), mp == null ? "?" : mp.getY(), tailFingerprint(c));
			}
			return;
		}
		if (tapState == TapState.IDLE)
		{
			return;
		}
		final Canvas canvas = liveCanvas();
		if (c.getGameState() != GameState.LOGGED_IN || canvas == null)
		{
			tapState = TapState.IDLE;   // world went away mid-tap: drop it (nothing sensible to click)
			queuedTap = false;
			return;
		}
		if (tapState == TapState.AWAIT_ENGINE)
		{
			if (c.isMenuOpen())
			{
				// A menu opened while this tap was settling (a long-press superseded it). The tap predates
				// the menu — clicking now would select an arbitrary row. Drop it; the menu flow owns input.
				// (While a menu is open the engine also stops rebuilding entries, so the gate would falsely
				// "stabilize" against the frozen tail.)
				tapState = TapState.IDLE;
				queuedTap = false;
				return;
			}
			settleFrames++;
			final net.runelite.api.Point mp = c.getMouseCanvasPosition();
			final boolean posMatch = mp != null && mp.getX() == tapX && mp.getY() == tapY;
			if (posMatch && posMatchFrame < 0)
			{
				posMatchFrame = settleFrames;
			}
			final String fp = tailFingerprint(c);
			if (posMatch && fp.equals(lastTailFp))
			{
				stableFrames++;
			}
			else
			{
				stableFrames = 0;
				lastTailFp = fp;
			}
			if (stableFrames >= STABLE_NEEDED || settleFrames >= MAX_SETTLE)
			{
				if (TOUCH_DIAG)
				{
					log.info("[touchdiag] L settle: {} frames (posMatch@{}) {} tail={}",
						settleFrames, posMatchFrame,
						stableFrames >= STABLE_NEEDED ? "stable" : "TIMEOUT-failopen", fp);
				}
				clickFp = fp;
				clickedFrames = 0;
				tapState = TapState.CLICKED;
				postClickButtons(canvas, tapX, tapY, MouseEvent.BUTTON1);
			}
		}
		else if (tapState == TapState.CLICKED)
		{
			clickedFrames++;
			if (clickedFrames >= CLICKED_TIMEOUT)
			{
				log.info("[touchdiag] L CLICKED timeout after {} frames — no MenuOptionClicked/MenuOpened (unexpected)",
					clickedFrames);
				finishTap();
			}
		}
	}

	/**
	 * One-shot EventBus registration for the truth events (client thread, lazy — the injector is live by the
	 * first in-game tap). Typed-consumer registration (no annotation scan); priority 0 is fine — we read the
	 * consumed entry, which is final by the time the event posts.
	 */
	private static void ensureTruthSubscribed()
	{
		if (truthSubscribed)
		{
			return;
		}
		try
		{
			final Injector inj = RuneLite.getInjector();
			if (inj == null)
			{
				return;
			}
			final EventBus eb = inj.getInstance(EventBus.class);
			eb.register(MenuOptionClicked.class, JavaBridge::onMenuOptionClicked, 0f);
			eb.register(MenuOpened.class, JavaBridge::onMenuOpened, 0f);
			eb.register(BeforeMenuRender.class, JavaBridge::onBeforeMenuRender, 0f);
			truthSubscribed = true;
			log.info("[touch] truth events subscribed (MenuOptionClicked/MenuOpened/BeforeMenuRender)");
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.ensureTruthSubscribed", ex);
		}
	}

	/**
	 * The truth: the engine consumed a left click (fires for EVERY left click, incl. walk and Cancel; carries
	 * the consumed {@link MenuEntry}). Only acts while a tap of ours is in flight ({@code CLICKED}). Classify
	 * the entry: an interaction bumps {@link #interactTapSeq} (native red ring + haptic) and arms the tight
	 * model outline FROM THE ENTRY (actor ref, or object via scene coords) — so "outline shown ⇔ interaction
	 * happened" holds by construction. A walk leaves feedback to the native yellow ring + the Tile Indicators
	 * plugin. Then park the cursor and start any queued follow-up tap.
	 */
	private static void onMenuOptionClicked(MenuOptionClicked ev)
	{
		if (tapState != TapState.CLICKED)
		{
			return;
		}
		final Client c = client;
		final ClientThread ct = clientThread;
		final MenuEntry entry = ev.getMenuEntry();
		final MenuAction type = entry == null ? null : entry.getType();
		if (TOUCH_DIAG)
		{
			final String consumedFp = fingerprint(entry);
			log.info("[touchdiag] L consumed: type={} fp={} predicted={} ({})",
				type, consumedFp, clickFp, consumedFp.equals(clickFp) ? "MATCH" : "MISMATCH");
		}
		if (type == MenuAction.WALK)
		{
			// A deliberate walk: clear any lingering outline (the destination tile is RuneLite's Tile
			// Indicators plugin); the native ring stays yellow because interactTapSeq does not advance.
			selActor = null;
			selObject = null;
			selUntil = 0;
			publishTapKind(TAP_KIND_WALK, (MenuEntry) null);
			if (TOUCH_DIAG && c != null && ct != null)
			{
				final int cx = tapX, cy = tapY;
				ct.invokeLater(() -> ct.invokeLater(() -> diagWalkDest(c, cx, cy)));
			}
		}
		else if (type == null || type == MenuAction.CANCEL)
		{
			// The click did nothing (dead UI chrome / cancel) — no feedback at all.
			publishTapKind(TAP_KIND_NONE, (MenuEntry) null);
		}
		else
		{
			interactTapSeq++;   // the click DID interact -> haptic (+ iOS red ring), meaning unchanged
			if (entry.getWidget() != null)
			{
				// An interface op (inventory item / prayer / spell / tab / …): no ring, plus a tight cyan
				// silhouette — the item outline for an item, the icon-sprite trace for any other widget.
				publishTapKind(TAP_KIND_WIDGET, entry);
				armWidgetOutline(entry);
			}
			else
			{
				// A scene interaction (NPC / object / player / ground item): the red ring + model outline.
				armOutlineFromEntry(c, entry, type);
				publishTapKind(TAP_KIND_SCENE, (MenuEntry) null);
			}
		}
		finishTap();
	}

	/**
	 * Publish the resolved tap kind for the native shell (client thread). For a WIDGET kind, snapshot the
	 * widget's canvas-px bounds (packed by {@link #getLastWidgetBounds}) so the shell can draw the border; a
	 * bounds-less widget degrades to NONE (nothing to outline). The seq bumps last, after the kind/bounds are
	 * set, so a native reader that sees the new seq also sees consistent kind/bounds.
	 */
	private static void publishTapKind(int kind, MenuEntry entry)
	{
		if (kind == TAP_KIND_WIDGET)
		{
			final java.awt.Rectangle b = tightWidgetBounds(entry);
			if (b != null && b.width > 0 && b.height > 0)
			{
				wbX = b.x;
				wbY = b.y;
				wbW = b.width;
				wbH = b.height;
			}
			else
			{
				kind = TAP_KIND_NONE;
			}
		}
		lastTapKind = kind;
		tapKindSeq++;
	}

	/**
	 * The tightest canvas bounds to outline for a widget op. {@code entry.getWidget()} is the op's widget —
	 * but for an item grid (inventory / bank / equipment) that's the whole CONTAINER, so the entry's slot
	 * ({@code param0}) child hugs the actual item. Only ever tightens: a slot child is taken only when it's
	 * strictly smaller than the container, so a non-grid entry (prayer / spell / tab) keeps its own bounds.
	 */
	private static java.awt.Rectangle tightWidgetBounds(MenuEntry entry)
	{
		final Widget w = entry == null ? null : entry.getWidget();
		if (w == null)
		{
			return null;
		}
		java.awt.Rectangle best = null;
		try
		{
			best = w.getBounds();
			final int slot = entry.getParam0();
			if (slot >= 0)
			{
				final Widget child = w.getChild(slot);
				final java.awt.Rectangle cb = child == null ? null : child.getBounds();
				if (cb != null && cb.width > 0 && cb.height > 0
					&& (best == null || (long) cb.width * cb.height < (long) best.width * best.height))
				{
					best = cb;
				}
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.tightWidgetBounds", ex);
		}
		return best;
	}

	// Lazily-registered overlays that flash a silhouette on the just-tapped item / sprite widget.
	private static volatile boolean tapItemOverlayAdded;
	private static volatile boolean tapWidgetOverlayAdded;
	// Sprite-outline cache (keyed by sprite id; the colour is fixed) — the trace never changes.
	private static final java.util.Map<Integer, java.awt.image.BufferedImage> spriteOutlines =
		new java.util.concurrent.ConcurrentHashMap<>();

	/**
	 * Flash a tight cyan silhouette on the tapped interface widget. An item op (inventory / bank / equipment)
	 * gets the engine's ITEM outline (the op's widget is the container, so resolve the slot child {@code
	 * param0}). Any other icon-bearing widget — prayer / spell / tab / toggle — gets its SPRITE traced instead.
	 */
	private static void armWidgetOutline(MenuEntry entry)
	{
		try
		{
			final Widget w = entry == null ? null : entry.getWidget();
			if (w == null)
			{
				return;
			}
			final long until = System.currentTimeMillis() + SEL_FLASH_MS;

			// Item op: outline the actual item slot.
			Widget itemW = w;
			final int slot = entry.getParam0();
			if (w.getItemId() < 0 && slot >= 0)
			{
				final Widget child = w.getChild(slot);
				if (child != null)
				{
					itemW = child;
				}
			}
			if (itemW != null && itemW.getItemId() >= 0)
			{
				ensureTapItemOverlay();
				TapItemOutlineOverlay.arm(itemW, until);
				return;
			}

			// Sprite widget (prayer / spell / tab / …): trace the icon sprite.
			armSpriteOutline(w, until);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.armWidgetOutline", ex);
		}
	}

	/** Trace the tapped widget's icon sprite (or a sprite-bearing child) and arm the sprite-outline overlay. */
	private static void armSpriteOutline(Widget w, long until)
	{
		final Client c = client;
		if (c == null)
		{
			return;
		}
		// Prefer the TOPMOST sprite child — the icon is drawn over any background. A prayer button's child 1
		// is the symbol, child 0 the round active-highlight; tracing the topmost gives the symbol, not the
		// ring. A simple sprite widget (tab / toggle) has no sprite child, so fall back to its own sprite.
		Widget sw = topSpriteChild(w);
		if (sw == null && w.getSpriteId() > 0)
		{
			sw = w;
		}
		final int spriteId = sw == null ? 0 : sw.getSpriteId();
		if (spriteId <= 0)
		{
			return;   // no sprite to trace (text / model widget) — graceful no-op
		}
		final java.awt.Rectangle b = sw.getBounds();
		if (b == null || b.width <= 0 || b.height <= 0)
		{
			return;
		}
		final java.awt.image.BufferedImage outline = spriteOutline(c, spriteId);
		if (outline == null)
		{
			return;
		}
		ensureTapWidgetOverlay();
		// Centre the silhouette in the icon's cell (it can be a touch larger than the sprite).
		final int x = b.x + (b.width - outline.getWidth()) / 2;
		final int y = b.y + (b.height - outline.getHeight()) / 2;
		TapWidgetOutlineOverlay.arm(outline, x, y, until);
	}

	/** The TOPMOST child (last drawn, across child lists) carrying a sprite — the icon over any background. */
	private static Widget topSpriteChild(Widget w)
	{
		Widget top = null;
		final Widget[][] groups = {w.getChildren(), w.getDynamicChildren(), w.getStaticChildren(), w.getNestedChildren()};
		for (final Widget[] kids : groups)
		{
			if (kids == null)
			{
				continue;
			}
			for (final Widget k : kids)
			{
				if (k != null && k.getSpriteId() > 0)
				{
					top = k;
				}
			}
		}
		return top;
	}

	/** The cyan silhouette of sprite {@code spriteId} (cached) — {@code SpritePixels.toBufferedOutline}. */
	private static java.awt.image.BufferedImage spriteOutline(Client c, int spriteId)
	{
		final java.awt.image.BufferedImage cached = spriteOutlines.get(spriteId);
		if (cached != null)
		{
			return cached;
		}
		try
		{
			final net.runelite.api.SpritePixels[] sp = c.getSprites(c.getIndexSprites(), spriteId, 0);
			if (sp == null || sp.length == 0 || sp[0] == null)
			{
				return null;
			}
			final java.awt.image.BufferedImage out = sp[0].toBufferedOutline(SEL_OUTLINE);
			if (out != null)
			{
				spriteOutlines.put(spriteId, out);
			}
			return out;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.spriteOutline", ex);
			return null;
		}
	}

	/** Register the item-outline overlay with the OverlayManager once (lazily — the injector isn't up early). */
	private static void ensureTapItemOverlay()
	{
		if (tapItemOverlayAdded)
		{
			return;
		}
		try
		{
			final Injector inj = RuneLite.getInjector();
			if (inj == null)
			{
				return;
			}
			inj.getInstance(net.runelite.client.ui.overlay.OverlayManager.class)
				.add(inj.getInstance(TapItemOutlineOverlay.class));
			tapItemOverlayAdded = true;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.ensureTapItemOverlay", ex);
		}
	}

	/** Register the sprite-widget-outline overlay with the OverlayManager once (lazily). */
	private static void ensureTapWidgetOverlay()
	{
		if (tapWidgetOverlayAdded)
		{
			return;
		}
		try
		{
			final Injector inj = RuneLite.getInjector();
			if (inj == null)
			{
				return;
			}
			inj.getInstance(net.runelite.client.ui.overlay.OverlayManager.class)
				.add(inj.getInstance(TapWidgetOutlineOverlay.class));
			tapWidgetOverlayAdded = true;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.ensureTapWidgetOverlay", ex);
		}
	}

	/** Native: bumps once per resolved left tap (pair with {@link #getLastTapKind}). */
	public static int getTapKindSeq()
	{
		return tapKindSeq;
	}

	/** Native: the kind of the most recently resolved tap ({@code TAP_KIND_*}). */
	public static int getLastTapKind()
	{
		return lastTapKind;
	}

	/** Native: the last WIDGET-kind tap's canvas-px bounds packed as {@code x<<48 | y<<32 | w<<16 | h} (each a
	 *  16-bit field; canvas coords never exceed that). Read after {@link #getTapKindSeq} advances. */
	public static long getLastWidgetBounds()
	{
		return ((long) (wbX & 0xFFFF) << 48) | ((long) (wbY & 0xFFFF) << 32)
			| ((long) (wbW & 0xFFFF) << 16) | (long) (wbH & 0xFFFF);
	}

	/**
	 * The click force-opened the engine menu instead of executing (deprioritized top entry — rare). Hand off
	 * to the existing native menu flow (the long-press path already polls {@code menuBuilding}/
	 * {@code menuPeekSnapshot} and shows the native rows). NO park — the menu anchors to the cursor point.
	 */
	private static void onMenuOpened(MenuOpened ev)
	{
		if (tapState != TapState.CLICKED)
		{
			return;
		}
		if (TOUCH_DIAG)
		{
			log.info("[touchdiag] L click force-opened the engine menu -> native menu flow");
		}
		queuedTap = false;
		tapState = TapState.IDLE;
	}

	/**
	 * Suppress the engine's own right-click-menu RASTER (not its logic). The menu stays fully live —
	 * geometry, entries, click-to-select, MenuPeekBridge — but the gamepack never paints it: on this build
	 * every menu the user sees is the native big-row overlay, and the engine's tiny "Choose Option" box only
	 * ever showed as artifacts (the 1-2 frame flash when a tap force-opens a deprioritized menu, and the
	 * peek under the native overlay while a committed menu closes). Default ON; the shell flips it OFF for
	 * the rare native-menu build-timeout fallback (drag-select on the engine menu would otherwise be blind)
	 * and back ON at menu teardown.
	 */
	private static volatile boolean menuRenderSuppressed = true;

	/** Native control for the engine-menu raster gate (reverse JNI; see {@link #menuRenderSuppressed}). */
	public static void setMenuRenderSuppressed(boolean suppressed)
	{
		menuRenderSuppressed = suppressed;
	}

	private static void onBeforeMenuRender(BeforeMenuRender ev)
	{
		if (menuRenderSuppressed)
		{
			ev.consume();   // consumed -> the engine skips drawing its menu this frame (logic untouched)
		}
	}

	/**
	 * Consume the {@code CLICKED} state: start the queued follow-up tap if there is one (its cursor move
	 * supersedes any park), else park the cursor at the neutral point one cycle later and go {@code IDLE}.
	 */
	private static void finishTap()
	{
		final Canvas canvas = liveCanvas();
		if (queuedTap && canvas != null)
		{
			queuedTap = false;
			beginAwait(canvas, queuedX, queuedY);
			return;
		}
		queuedTap = false;
		tapState = TapState.IDLE;
		final ClientThread ct = clientThread;
		if (ct != null)
		{
			ct.invokeLater(JavaBridge::parkPointer);
		}
		else
		{
			parkPointer();
		}
	}

	/**
	 * Arm the tight model outline from the CONSUMED menu entry: actors straight off the entry; objects looked
	 * up by the entry's scene coords + id (the InteractHighlightPlugin.findTileObject pattern). Widget /
	 * ground-item / runelite ops get the haptic but no model outline.
	 */
	private static void armOutlineFromEntry(Client c, MenuEntry entry, MenuAction type)
	{
		try
		{
			final Actor actor = entry.getActor();   // set for NPC_* / PLAYER_* ops
			if (actor != null)
			{
				armEntityOutline(actor, null);
				return;
			}
			switch (type)
			{
				case GAME_OBJECT_FIRST_OPTION:
				case GAME_OBJECT_SECOND_OPTION:
				case GAME_OBJECT_THIRD_OPTION:
				case GAME_OBJECT_FOURTH_OPTION:
				case GAME_OBJECT_FIFTH_OPTION:
				case WIDGET_TARGET_ON_GAME_OBJECT:
					final TileObject o = findTileObject(c, entry.getWorldViewId(),
						entry.getParam0(), entry.getParam1(), entry.getIdentifier());
					if (o != null)
					{
						armEntityOutline(null, o);
					}
					break;
				default:
					break;
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.armOutlineFromEntry", ex);
		}
	}

	/**
	 * Find the {@link TileObject} a consumed object op referenced: {@code param0/param1} are scene coords in
	 * the entry's world view ({@code +40} extended-tiles offset for the top-level view), {@code id} matches
	 * the object on that tile. The InteractHighlightPlugin pattern, null-hardened (client thread).
	 */
	private static TileObject findTileObject(Client c, int worldId, int x, int y, int id)
	{
		if (c == null)
		{
			return null;
		}
		final WorldView wv = c.getWorldView(worldId);
		if (wv == null)
		{
			return null;
		}
		final int offset = worldId == WorldView.TOPLEVEL ? (Constants.EXTENDED_SCENE_SIZE - Constants.SCENE_SIZE) / 2 : 0;
		final int sx = x + offset;
		final int sy = y + offset;
		final Scene scene = wv.getScene();
		final Tile[][][] tiles = scene == null ? null : scene.getExtendedTiles();
		final int plane = wv.getPlane();
		if (tiles == null || plane < 0 || plane >= tiles.length
			|| sx < 0 || sx >= tiles[plane].length || sy < 0 || sy >= tiles[plane][sx].length)
		{
			return null;
		}
		final Tile tile = tiles[plane][sx][sy];
		if (tile == null)
		{
			return null;
		}
		for (GameObject gameObject : tile.getGameObjects())
		{
			if (gameObject != null && gameObject.getId() == id)
			{
				return gameObject;
			}
		}
		final WallObject wallObject = tile.getWallObject();
		if (wallObject != null && wallObject.getId() == id)
		{
			return wallObject;
		}
		final DecorativeObject decorativeObject = tile.getDecorativeObject();
		if (decorativeObject != null && decorativeObject.getId() == id)
		{
			return decorativeObject;
		}
		final GroundObject groundObject = tile.getGroundObject();
		if (groundObject != null && groundObject.getId() == id)
		{
			return groundObject;
		}
		return null;
	}

	/** Fingerprint of one menu entry (the MenuPeek shape: option|target|type|id|p0|p1|itemId). */
	private static String fingerprint(MenuEntry e)
	{
		if (e == null)
		{
			return "EMPTY";
		}
		return e.getOption() + "|" + e.getTarget() + "|" + e.getType()
			+ "|" + e.getIdentifier() + "|" + e.getParam0() + "|" + e.getParam1() + "|" + e.getItemId();
	}

	/** Fingerprint of the current left-click default = the TAIL of getMenuEntries() (ascending priority). */
	private static String tailFingerprint(Client c)
	{
		try
		{
			final MenuEntry[] e = c.getMenu().getMenuEntries();
			return (e == null || e.length == 0) ? "EMPTY" : fingerprint(e[e.length - 1]);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.tailFingerprint", ex);
			return "ERR";
		}
	}

	/** Arm a tight outline flash on the selected entity. */
	private static void armEntityOutline(Actor actor, TileObject object)
	{
		selActor = actor;
		selObject = object;
		selUntil = System.currentTimeMillis() + SEL_FLASH_MS;
	}

	/** Log the resolved walk destination (scene coords) against the clicked viewport point and the player tile. */
	private static void diagWalkDest(Client c, int clickX, int clickY)
	{
		try
		{
			final net.runelite.api.coords.LocalPoint dst = c.getLocalDestinationLocation();
			final net.runelite.api.Player me = c.getLocalPlayer();
			final net.runelite.api.coords.LocalPoint mine = me == null ? null : me.getLocalLocation();
			log.info("[touchdiag] walkDest click={},{} dest={} player={}",
				clickX, clickY,
				dst == null ? "null" : (dst.getSceneX() + "," + dst.getSceneY()),
				mine == null ? "null" : (mine.getSceneX() + "," + mine.getSceneY()));
		}
		catch (RuntimeException ignored) { }
	}

	/** Lazily resolve the model-outline renderer (the tight silhouette RuneLite's NPC outline mode uses). */
	private static ModelOutlineRenderer outliner()
	{
		if (outliner == null)
		{
			final Injector inj = RuneLite.getInjector();
			if (inj != null)
			{
				try
				{
					outliner = inj.getInstance(ModelOutlineRenderer.class);
				}
				catch (RuntimeException ex)
				{
					BridgeFaults.note("JavaBridge.outliner", ex);
				}
			}
		}
		return outliner;
	}

	// Tight entity outline colour (yellow), matching the OSRS-Mobile selection feel.
	// Cyan selection outline, matching the official Jagex Mobile "tap-target" highlight (was yellow).
	private static final Color SEL_OUTLINE = new Color(60, 224, 255, 235);

	/**
	 * Draw the selection feedback INTO the game frame (client thread, from {@code Hooks.draw} after the overlays
	 * composite, before the blit snapshot): a tight model outline on the just-selected entity for a beat.
	 * Tighter than a native polygon of the convex hull and it tracks the moving entity, since it's the engine's
	 * own model silhouette. (The walk destination tile is left to RuneLite's Tile Indicators plugin.)
	 */
	public static void drawSelection(Client c)
	{
		if (!ENABLED || c == null)
		{
			return;
		}
		try
		{
			if (System.currentTimeMillis() < selUntil)
			{
				final ModelOutlineRenderer o = outliner();
				if (o != null)
				{
					if (selActor != null)
					{
						o.drawOutline(selActor, 2, SEL_OUTLINE, 4);
					}
					else if (selObject != null)
					{
						o.drawOutline(selObject, 2, SEL_OUTLINE, 4);
					}
				}
			}
			else
			{
				selActor = null;
				selObject = null;
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.drawSelection", ex);
		}
	}

	/**
	 * A <em>precise</em> left/right click at exactly {@code (x,y)} — same proven move+click shape as
	 * {@link #onClick}, but with <b>no snap-to-entity resolution</b>. This is for deliberate UI proxies (the
	 * native chrome tapping a tab stone / orb / widget), where the coordinate is already the exact target and
	 * touch-forgiveness must NOT redirect it: with a full-screen world viewport, snap would otherwise pull a
	 * tab-stone click onto a nearby world entity. Keeps the two-cycle move→click (so the engine re-targets the
	 * widget before the click) but feeds the literal point.
	 */
	public static void onClickPrecise(int x, int y, int button)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final ClientThread ct = clientThread;
		final Client c = client;
		if (button == MouseEvent.BUTTON1 && ct != null
			&& c != null && c.getGameState() == GameState.LOGGED_IN)
		{
			ct.invoke(() ->
			{
				postMove(canvas, x, y);
				ct.invokeLater(() -> postClickButtons(canvas, x, y, MouseEvent.BUTTON1));
			});
			return;
		}
		synthesizeClick(canvas, x, y, button);
	}

	/**
	 * Select an open right-click menu row by left-clicking its canvas point, then PARK the pointer one cycle
	 * AFTER the click so the engine doesn't leave the cursor sitting on that target. On a touchscreen there is
	 * no persistent cursor, so a stranded synthetic cursor would keep showing the selected object's action
	 * label and make the next tap re-resolve to it (the "stuck on the stairs" bug). The ordered
	 * invoke→invokeLater chain guarantees the park lands after the press/release/click, never before (which
	 * would cancel the selection). Used by the native menu's commit and cancel.
	 */
	public static void selectMenuPoint(int x, int y)
	{
		final Canvas canvas = liveCanvas();
		final ClientThread ct = clientThread;
		if (canvas == null || ct == null)
		{
			return;
		}
		ct.invoke(() ->
		{
			postMove(canvas, x, y);
			ct.invokeLater(() ->
			{
				postClickButtons(canvas, x, y, MouseEvent.BUTTON1);
				ct.invokeLater(JavaBridge::parkPointer);   // un-strand the cursor after the select
			});
		});
	}

	/**
	 * MENU-1: commit a right-click SUBMENU child the native menu drilled into. The engine renders submenu
	 * children in a flyout, not as rows of the main menu, so the {@link #selectMenuPoint} click-through (which
	 * targets a main-menu row's canvas geometry) can't reach them. Instead we resolve the child in the live —
	 * and, while the right-click menu is open, <em>frozen</em> — menu tree by the same (parent display index,
	 * child index) the {@link MenuPeekBridge} snapshot published, then run its action directly: a
	 * RuneLite-registered {@code onClick} consumer (how Menu-Entry-Swapper / Ground-Items / NPC-tag submenu
	 * items are built) is invoked as the engine would, else fall back to {@code menuAction}. Runs on the client
	 * thread (menu reads + onClick are client-thread-only). The native side closes the now-stale engine menu
	 * separately (a title-strip click), exactly like a cancel.
	 *
	 * @param parentDisplayIndex parent row index in display order (0 = top = the menu-entries array tail),
	 *                           matching the snapshot's {@code entries[]} order
	 * @param childIndex         index into the parent's submenu entries (snapshot {@code sub[]} order); a value
	 *                           {@code < 0} invokes the top-level entry itself (the scrollable-menu flat-row path)
	 */
	public static void invokeMenuEntry(int parentDisplayIndex, int childIndex)
	{
		final ClientThread ct = clientThread;
		final Client c = client;
		if (ct == null || c == null)
		{
			return;
		}
		ct.invokeLater(() ->
		{
			try
			{
				// The (parent display index, child index) the native side captured are only valid against the
				// SAME open menu it snapshotted; the engine freezes getMenuEntries() while the menu is open. If
				// it has since closed (so the array would rebuild from the live pointer), abort rather than
				// invoke a stale/wrong entry.
				if (!c.isMenuOpen())
				{
					return;
				}
				final MenuEntry[] e = c.getMenuEntries();
				final int count = e == null ? 0 : e.length;
				final int pIdx = count - 1 - parentDisplayIndex;   // display top = array tail
				if (pIdx < 0 || pIdx >= count)
				{
					return;
				}
				final MenuEntry target;
				if (childIndex < 0)
				{
					// childIndex < 0 = invoke the top-level entry itself. Used by the tap-mode flat-row commit
					// when the engine menu is scrollable, where the row's fixed canvas geometry (and thus the
					// click-through path) is unreliable.
					target = e[pIdx];
				}
				else
				{
					final Menu sub = e[pIdx].getSubMenu();
					if (sub == null)
					{
						return;
					}
					final MenuEntry[] kids = sub.getMenuEntries();
					if (kids == null || childIndex >= kids.length)
					{
						return;
					}
					target = kids[childIndex];
				}
				final java.util.function.Consumer<MenuEntry> cb = target.onClick();
				if (cb != null)
				{
					cb.accept(target);
				}
				else
				{
					c.menuAction(target.getParam0(), target.getParam1(), target.getType(),
						target.getIdentifier(), target.getItemId(), target.getOption(), target.getTarget());
				}
			}
			catch (RuntimeException ex)
			{
				BridgeFaults.note("JavaBridge.invokeMenuEntry", ex);
			}
		});
	}

	/** Post the focus-prime + move + press + release + click sequence at {@code (x,y)} in one batch. */
	private static void synthesizeClick(Canvas canvas, int x, int y, int awtButton)
	{
		postMove(canvas, x, y);
		postClickButtons(canvas, x, y, awtButton);
	}

	/** Prime focus/presence and move the pointer to {@code (x,y)} (no buttons) — lets the engine re-target. */
	private static void postMove(Canvas canvas, int x, int y)
	{
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		primeFocus(q, canvas, t, x, y);
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));
	}

	/** Post press + release + click at {@code (x,y)} for {@code awtButton} (no preceding move). */
	private static void postClickButtons(Canvas canvas, int x, int y, int awtButton)
	{
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		final int downMask = awtButton == MouseEvent.BUTTON3 ? InputEvent.BUTTON3_DOWN_MASK
			: awtButton == MouseEvent.BUTTON2 ? InputEvent.BUTTON2_DOWN_MASK
			: InputEvent.BUTTON1_DOWN_MASK;
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_PRESSED, t,
			downMask, x, y, 1, false, awtButton));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_RELEASED, t + 1,
			0, x, y, 1, false, awtButton));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_CLICKED, t + 2,
			0, x, y, 1, false, awtButton));
	}

	/**
	 * Is {@code (x,y)} (gamepack-canvas pixels) inside the live 3D-scene viewport? The engine reports the
	 * viewport rect via {@code getViewportXOffset/YOffset/Width/Height}; a negative offset or non-positive
	 * extent means the viewport is not currently drawn (e.g. a full-screen interface is up). Read on the
	 * client thread (the caller already is). Diagnostic only ({@link #diagGeometry}).
	 */
	private static boolean inWorldViewport(Client c, int x, int y)
	{
		try
		{
			final int vx = c.getViewportXOffset();
			final int vy = c.getViewportYOffset();
			final int vw = c.getViewportWidth();
			final int vh = c.getViewportHeight();
			if (vx < 0 || vy < 0 || vw <= 0 || vh <= 0)
			{
				return false;
			}
			return x >= vx && x < vx + vw && y >= vy && y < vy + vh;
		}
		catch (RuntimeException ex)
		{
			return false;
		}
	}

	/** Monotonic counter bumped whenever a tap's CONSUMED click was an interaction (native haptic cue). */
	public static int getInteractTapSeq()
	{
		return interactTapSeq;
	}

	/**
	 * Move the pointer to {@code (x,y)} with no button held — a plain {@code MOUSE_MOVED}. This is the
	 * "hover" primitive: it updates the gamepack's recorded mouse position so the open right-click menu
	 * highlights the entry under the finger as it slides. Distinct from a drag (which holds a button and
	 * posts {@code MOUSE_DRAGGED} via {@link #onTouch}) so the menu-track gesture can't be confused for one.
	 */
	public static void onMove(int x, int y)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		primeFocus(q, canvas, t, x, y);
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));
	}

	/**
	 * Scroll the wheel by {@code rotation} notches at {@code (x,y)} — a {@link MouseWheelEvent}, which
	 * {@code Hooks.mouseWheelMoved} routes through {@code mouseManager} exactly like a {@link MouseEvent}.
	 * Pinch-zoom maps to this: negative {@code rotation} = wheel up = zoom in. {@code (x,y)} is the pinch
	 * centroid so the gamepack zooms about it.
	 */
	public static void onWheel(int x, int y, int rotation)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null || rotation == 0)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		primeFocus(q, canvas, t, x, y);
		q.postEvent(new MouseWheelEvent(canvas, MouseEvent.MOUSE_WHEEL, t + 1, 0, x, y, 0, false,
			MouseWheelEvent.WHEEL_UNIT_SCROLL, Math.abs(rotation), rotation));
	}

	/**
	 * Rotate the camera by a two-finger pan: apply the raw pixel delta {@code (dxPixels,dyPixels)} to the
	 * camera yaw/pitch <em>targets</em> directly via the client API (no synthesized middle-mouse, so it is
	 * independent of the "middle mouse moves camera" setting). Yaw wraps mod 16384 (JAU14); pitch clamps to the
	 * normal RS range. Only acts in-game. The native side sends raw pixel deltas; sensitivity + sub-pixel
	 * accumulation live here.
	 */
	public static void onCameraDrag(int dxPixels, int dyPixels)
	{
		if (!ENABLED || client == null)
		{
			return;
		}
		// Accumulate only; the camera writes happen on the client thread in tapTick -> applyCameraDrag.
		camDragDx.addAndGet(dxPixels);
		camDragDy.addAndGet(dyPixels);
	}

	/** Drain the accumulated two-finger-pan deltas and apply yaw/pitch — on the client thread (from tapTick). */
	private static void applyCameraDrag(Client c)
	{
		final int dxPixels = camDragDx.getAndSet(0);
		final int dyPixels = camDragDy.getAndSet(0);
		if ((dxPixels == 0 && dyPixels == 0) || c.getGameState() != GameState.LOGGED_IN)
		{
			return;
		}

		final float yawF = dxPixels * YAW_UNITS_PER_PX + yawRemainder;
		final int yawStep = (int) yawF;
		yawRemainder = yawF - yawStep;
		if (yawStep != 0)
		{
			c.setCameraYawTarget((c.getCameraYawTarget() + yawStep) & 16383);
		}

		final float pitchF = dyPixels * PITCH_UNITS_PER_PX + pitchRemainder;
		final int pitchStep = (int) pitchF;
		pitchRemainder = pitchF - pitchStep;
		if (pitchStep != 0)
		{
			// Drag down -> camera tilts down (pitch decreases toward the horizon).
			int p = c.getCameraPitchTarget() - pitchStep;
			p = Math.max(PITCH_MIN, Math.min(PITCH_MAX, p));
			c.setCameraPitchTarget(p);
		}
	}

	/**
	 * Client-thread drain for {@link #keepAlive()}: if a native-UI touch is pending and it's safe, post ONE
	 * {@code MOUSE_MOVED(-1,-1)} to the live canvas to reset the engine's idle-logout timer. Gated so it never
	 * perturbs an open right-click menu, an in-flight tap settle, or a focused text field, and throttled to at
	 * most one post per {@link #IDLE_KEEPALIVE_THROTTLE_MS} (so continuous native drags / floods collapse to one
	 * event). Only {@code MOUSE_MOVED} — no {@code MOUSE_EXITED} (would flip {@code entered}), no press/click
	 * (could walk/interact) — and {@code (-1,-1)} picks nothing, so hover/park/primeFocus bookkeeping is untouched.
	 */
	private static void maybePostIdleKeepalive(Client c)
	{
		if (!ENABLED || !IDLE_KEEPALIVE)
		{
			return;
		}
		final long activity = lastNativeUiActivityMs;
		if (activity <= lastKeepalivePostMs)
		{
			return;   // nothing new since our last post (real taps don't bump this, so active play is a no-op)
		}
		// Gate — all coherent on the client thread:
		if (c.getGameState() != GameState.LOGGED_IN   // pre-login / loading: nothing to keep alive
			|| c.isMenuOpen()                          // never perturb an open right-click menu
			|| tapState != TapState.IDLE               // never race an in-flight tap settle
			|| queuedTap
			|| textInputOpen)                          // never disturb a focused text field
		{
			return;   // not safe this tick; the pending timestamp survives for a later tick
		}
		final long now = System.currentTimeMillis();
		if (now - lastKeepalivePostMs < IDLE_KEEPALIVE_THROTTLE_MS)
		{
			return;   // throttled; retry next tick
		}
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, now, 0, -1, -1, 0, false));
		lastKeepalivePostMs = now;
		log.debug("[touch] idle keepAlive -> MOUSE_MOVED(-1,-1)");
	}

	/**
	 * Type committed text — for each character post {@code KEY_PRESSED} + {@code KEY_TYPED} +
	 * {@code KEY_RELEASED}. The gamepack's text fields (chat, search, username/password) consume the
	 * {@code KEY_TYPED} char, which carries the exact character (and case) the iOS keyboard committed.
	 * Called from the hidden {@code UITextField}'s change callback, so autocorrect/paste arrive as one
	 * coherent string.
	 */
	public static void onText(String s)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null || s == null || s.isEmpty())
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		long t = System.currentTimeMillis();
		ensureFocus(q, canvas);
		for (int i = 0; i < s.length(); i++)
		{
			final char c = s.charAt(i);
			final int vk = KeyEvent.getExtendedKeyCodeForChar(c);
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_PRESSED, t, 0, vk, c));
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_TYPED, t + 1, 0, KeyEvent.VK_UNDEFINED, c));
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_RELEASED, t + 2, 0, vk, c));
			t += 3;
		}
	}

	/**
	 * Whether the gamepack currently has a text field open and awaiting input — a search box (bank/GE/world
	 * map), a private-message recipient, an "enter amount/name" dialog, etc. ({@code VarClientInt.INPUT_TYPE}
	 * is non-zero). The native shell polls this to auto-raise the soft keyboard when the game asks for text
	 * and dismiss it when the field closes, so typing is summoned from inside the game, not a chrome button.
	 */
	public static boolean isTextInputOpen()
	{
		return ENABLED && textInputOpen;   // snapshotted on the client thread (snapshotTextInputOpen), read here off-thread
	}

	/** Snapshot INPUT_TYPE on the client thread (from tapTick) so isTextInputOpen() never reads the live varc off-thread. */
	private static void snapshotTextInputOpen(Client c)
	{
		try
		{
			boolean want = c.getVarcIntValue(VarClientInt.INPUT_TYPE) != 0;
			if (!want)
			{
				// Some engine inputs focus an input-field WIDGET without flipping INPUT_TYPE — notably the Grand
				// Exchange custom quantity/price entry. Auto-raise the soft keyboard for those too, so the user can
				// type a GE amount the same way they type a bank "Enter amount".
				try
				{
					want = c.getFocusedInputFieldWidget() != null;
				}
				catch (RuntimeException ignore)
				{
					BridgeFaults.note("JavaBridge.snapshotTextInputOpen", ignore);
				}
			}
			textInputOpen = want;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.snapshotTextInputOpen", ex);
			// keep the last snapshot
		}
	}

	// DRAG-1: the inventory item-grid widget bounds (canvas px), snapshotted on the client thread each frame so
	// the native shell can read them lock-free and decide whether a one-finger drag that STARTS over the
	// inventory should rearrange items (a synthesized engine mouse-drag) instead of rotating the camera. -1
	// width = not visible (inventory tab not open / hidden), so the native side leaves every drag as a camera pan.
	private static volatile int invX = -1, invY = -1, invW = 0, invH = 0;

	private static void snapshotInventoryBounds(Client c)
	{
		try
		{
			final Widget w = c.getWidget(InterfaceID.Inventory.ITEMS);
			if (w != null && !w.isHidden())
			{
				final Rectangle b = w.getBounds();
				// Only publish an ON-SCREEN rect. The shared item-grid widget (group 149) is universal across
				// layouts, but a side-panel slot that isn't the shown tab can report !isHidden() with the grid
				// PARKED off-canvas at negative coords (observed during a background/foreground layout transition
				// where the live top level is ToplevelDisplay 165 rather than the relocated PreEoc 164). Publishing
				// that would make the native drag hit-test claim the top-left corner; require x/y >= 0 so only the
				// real, relocated, on-screen inventory becomes a drag target.
				if (b != null && b.width > 0 && b.height > 0 && b.x >= 0 && b.y >= 0)
				{
					invX = b.x;
					invY = b.y;
					invW = b.width;
					invH = b.height;
					return;
				}
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.snapshotInventoryBounds", ex);
			// fall through to "not visible"
		}
		invX = -1;
		invW = 0;
	}

	/** DRAG-1: the live inventory item-grid bounds {x, y, w, h} in canvas px; w &lt;= 0 means not visible. */
	public static int[] getInventoryBounds()
	{
		return new int[]{invX, invY, invW, invH};
	}

	// DRAG-1b: bounds of the engine's drag-to-reorder panes (Prayer icon container / Spellbook spell layer / Bank
	// item grid), snapshotted on the client thread each frame so the native shell can hit-test a one-finger drag's
	// START point lock-free and route it through onTouch — the MOUSE_PRESSED->DRAGGED->RELEASED stream the reorder
	// plugins read via getDraggedWidget/getDraggedOnWidget — instead of rotating the camera. Packed as [x,y,w,h]
	// per visible pane; an empty array means no reorderable pane is on-screen. Inventory keeps its own
	// getInventoryBounds() + dedicated item-drag branch, so it is intentionally NOT duplicated here.
	private static final int[] REORDER_PANE_WIDGETS = {
		InterfaceID.Prayerbook.CONTAINER,
		InterfaceID.MagicSpellbook.SPELLLAYER,
		InterfaceID.Bankmain.ITEMS,
	};
	private static final int[] EMPTY_BOUNDS = new int[0];
	private static volatile int[] reorderPaneBounds = EMPTY_BOUNDS;

	private static void snapshotReorderPaneBounds(Client c)
	{
		try
		{
			int[] out = null;
			int n = 0;
			for (final int widgetId : REORDER_PANE_WIDGETS)
			{
				final Widget w = c.getWidget(widgetId);
				if (w == null || w.isHidden())
				{
					continue;
				}
				final Rectangle b = w.getBounds();
				// Same on-screen guard as snapshotInventoryBounds: a parked/off-canvas pane (negative coords during
				// a layout transition) must not become a phantom drag target at the top-left corner.
				if (b == null || b.width <= 0 || b.height <= 0 || b.x < 0 || b.y < 0)
				{
					continue;
				}
				if (out == null)
				{
					out = new int[REORDER_PANE_WIDGETS.length * 4];
				}
				out[n++] = b.x;
				out[n++] = b.y;
				out[n++] = b.width;
				out[n++] = b.height;
			}
			reorderPaneBounds = out == null ? EMPTY_BOUNDS : (n == out.length ? out : java.util.Arrays.copyOf(out, n));
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("JavaBridge.snapshotReorderPaneBounds", ex);
			reorderPaneBounds = EMPTY_BOUNDS;
		}
	}

	/**
	 * DRAG-1b: bounds of the visible drag-to-reorder panes, packed as {@code [x,y,w,h]} per pane in canvas px
	 * (Prayer / Spellbook / Bank, in that order, skipping any not on-screen). Empty = none visible. The native
	 * shell hit-tests a one-finger drag's start point against these to route it as an engine reorder drag
	 * ({@link #onTouch}) rather than a camera pan.
	 */
	public static int[] getReorderPaneBounds()
	{
		return reorderPaneBounds;
	}

	/**
	 * SCROLL-SPIKE: true if a scrollable engine interface widget is under the canvas point (x,y) — a visible widget
	 * whose scroll layer overflows ({@code getScrollHeight() > getHeight()}) and whose bounds contain the point.
	 * The native shell calls this at pan-begin to decide whether a one-finger drag should scroll an open interface
	 * (bank / GE / quest list / settings / collection log …) — emitted as wheel notches the engine routes to the
	 * hovered scrollable, exactly like the desktop mouse wheel — instead of rotating the camera. Returning false
	 * leaves the drag a camera pan, so a drag over the bare viewport never scroll-leaks into a zoom.
	 *
	 * <p>THREADING (spike caveat): this walks the live widget tree off the client thread (called straight from the
	 * JNI pan-begin), so a concurrent client-thread relayout can give a torn bounds read. It is a gating decision
	 * only (worst case: one mis-gated drag), is fully {@code try/catch(Throwable)}-guarded, fails safe to
	 * {@code false}, and the node budget caps the walk so a huge open interface can't stutter pan-begin. The
	 * production path would snapshot the scrollable rects on the client thread each frame (cf.
	 * {@link #snapshotInventoryBounds}) and hit-test them lock-free here.
	 */
	public static boolean isEngineScrollableAt(int x, int y)
	{
		final Client c = client;
		if (c == null)
		{
			return false;
		}
		try
		{
			final Widget[] roots = c.getWidgetRoots();
			if (roots != null)
			{
				final int[] budget = {6000};   // node cap for the off-thread walk
				for (final Widget root : roots)
				{
					if (scrollableUnder(root, x, y, 0, budget))
					{
						return true;
					}
				}
			}
		}
		catch (Throwable t)
		{
			BridgeFaults.note("JavaBridge.isEngineScrollableAt", t);
		}
		return false;
	}

	// SCROLL-SPIKE: bounded recursive search for a visible, overflowing scroll layer containing (x,y). Children can
	// render outside a parent's own bounds, so the walk doesn't prune on parent bounds — the node budget + depth cap
	// bound the cost instead.
	private static boolean scrollableUnder(Widget w, int x, int y, int depth, int[] budget)
	{
		if (w == null || depth > 24 || budget[0]-- <= 0 || w.isHidden())
		{
			return false;
		}
		final Rectangle b = w.getBounds();
		if (b != null && b.contains(x, y) && w.getHeight() > 0 && w.getScrollHeight() > w.getHeight())
		{
			return true;
		}
		return scrollableChild(w.getStaticChildren(), x, y, depth, budget)
			|| scrollableChild(w.getDynamicChildren(), x, y, depth, budget)
			|| scrollableChild(w.getNestedChildren(), x, y, depth, budget);
	}

	private static boolean scrollableChild(Widget[] kids, int x, int y, int depth, int[] budget)
	{
		if (kids != null)
		{
			for (final Widget k : kids)
			{
				if (scrollableUnder(k, x, y, depth + 1, budget))
				{
					return true;
				}
			}
		}
		return false;
	}

	/**
	 * Press + release one non-text key by its AWT virtual-keycode ({@code KeyEvent.VK_*}) — backspace,
	 * enter, escape, tab, arrows, etc. Backspace/enter/tab also emit the matching {@code KEY_TYPED} control
	 * char (a gamepack text field deletes/submits on those). Posted from the hidden field's delete/return
	 * callbacks and any on-screen key.
	 */
	public static void onKeyStroke(int vk)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		ensureFocus(q, canvas);
		char kc = KeyEvent.CHAR_UNDEFINED;
		if (vk == KeyEvent.VK_BACK_SPACE)
		{
			kc = '\b';
		}
		else if (vk == KeyEvent.VK_ENTER)
		{
			kc = '\n';
		}
		else if (vk == KeyEvent.VK_TAB)
		{
			kc = '\t';
		}
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_PRESSED, t, 0, vk, kc));
		if (kc != KeyEvent.CHAR_UNDEFINED)
		{
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_TYPED, t + 1, 0, KeyEvent.VK_UNDEFINED, kc));
		}
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_RELEASED, t + 2, 0, vk, kc));
	}

	/**
	 * KEY-1: fire a plugin's configured action-hotkey by synthesizing the exact key chord its
	 * {@code HotkeyListener} (or raw {@code KeyListener}, e.g. Bank search) listens for. {@code Keybind.matches}
	 * reads the event's extended key-code + extended modifiers, so a single matched {@code KEY_PRESSED} (with
	 * the modifier mask baked into the event — no separate modifier-key presses needed) triggers
	 * {@code hotkeyPressed}; the paired {@code KEY_RELEASED} clears the listener's pressed latch so it can fire
	 * again next time. Posted to the same AWT queue / focused canvas as our other key synthesis (RuneLite's
	 * {@code KeyManager} is a canvas {@code KeyListener}), so this routes through the engine exactly like a
	 * hardware chord. Modifier-only binds (no main key) are ignored — those are hold-to-modify, not fire-once.
	 *
	 * @param keyCode   the Keybind's (extended) key-code — {@code KeyEvent.VK_*}
	 * @param modifiers the Keybind's extended-modifier mask — {@code InputEvent.*_DOWN_MASK} bits
	 */
	public static void onKeybind(int keyCode, int modifiers)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null || keyCode == KeyEvent.VK_UNDEFINED)
		{
			return;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		ensureFocus(q, canvas);
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_PRESSED, t, modifiers, keyCode, KeyEvent.CHAR_UNDEFINED));
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_RELEASED, t + 2, modifiers, keyCode, KeyEvent.CHAR_UNDEFINED));
	}

	/**
	 * Sticky-Shift: hold (or release) the SHIFT modifier so the engine's {@code client.isKeyPressed(KC_SHIFT)}
	 * path reads true without a hardware key. On touch there is no physical shift, yet a large QoL surface gates
	 * on it — Menu Entry Swapper shift-to-customize, shift deposit/withdraw/shop-quantity swaps, Ground/Object/NPC
	 * "Shift + right-click to mark", overlay SHIFT+right-click "Configure". A native sticky-"Shift" toggle calls
	 * this; the gamepack's own {@code Canvas} KeyListener (which feeds its pressed-key array) receives the posted
	 * event, exactly as our text injection does. {@code held=true} posts ONE {@code KEY_PRESSED VK_SHIFT} (no
	 * release); {@code held=false} posts the matching {@code KEY_RELEASED}. Transition-gated so a held toggle
	 * isn't re-posted every frame. (Proven on the live engine by {@code ShiftFeedSpike}: a single held press
	 * flips {@code isKeyPressed(KC_SHIFT)} true and a release clears it; if a long hold is ever observed to clear
	 * — e.g. on a focus change — a per-frame re-assert from {@code register} is the fix.) No {@code KEY_TYPED}: a
	 * modifier produces none.
	 */
	public static void setShiftHeld(boolean held)
	{
		shiftHeld = postModifierHeld(held, shiftHeld, KeyEvent.VK_SHIFT, InputEvent.SHIFT_DOWN_MASK);
	}

	/**
	 * Sticky-Ctrl — same mechanism as {@link #setShiftHeld}, for the Ctrl-gated surface (e.g. middle-click-style
	 * Ctrl interactions, plugins that read {@code isKeyPressed(KC_CONTROL)}). A native modifier toggle calls this.
	 */
	public static void setCtrlHeld(boolean held)
	{
		ctrlHeld = postModifierHeld(held, ctrlHeld, KeyEvent.VK_CONTROL, InputEvent.CTRL_DOWN_MASK);
	}

	/**
	 * Sticky-Alt — same mechanism as {@link #setShiftHeld}. Notably drives Ground Items' "hold Alt to highlight"
	 * (the plugin shows item names / its highlight while Alt is held). A native modifier toggle calls this.
	 */
	public static void setAltHeld(boolean held)
	{
		altHeld = postModifierHeld(held, altHeld, KeyEvent.VK_ALT, InputEvent.ALT_DOWN_MASK);
	}

	/**
	 * Shared sticky-modifier latch (see {@link #setShiftHeld} for the full rationale): transition-gated so a held
	 * toggle isn't re-posted every frame. {@code held=true} posts ONE {@code KEY_PRESSED} (no release) with the
	 * modifier's down-mask; {@code held=false} posts the matching {@code KEY_RELEASED}. Returns the new held state
	 * (unchanged if there is no live canvas or nothing to do).
	 */
	private static boolean postModifierHeld(boolean held, boolean current, int vk, int downMask)
	{
		if (held == current)
		{
			return current;
		}
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return current;
		}
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		if (held)
		{
			ensureFocus(q, canvas);
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_PRESSED, t, downMask,
				vk, KeyEvent.CHAR_UNDEFINED, KeyEvent.KEY_LOCATION_LEFT));
		}
		else
		{
			q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_RELEASED, t, 0,
				vk, KeyEvent.CHAR_UNDEFINED, KeyEvent.KEY_LOCATION_LEFT));
		}
		return held;
	}

	/**
	 * Middle-button (BUTTON2) click at {@code (x,y)} — a discrete press+release+click, the touch equivalent of a
	 * mouse middle-click. Posts through the same canvas path as {@link #onClick}; the engine handles it per its
	 * own "middle mouse button" setting (opens-menu / camera). No client-thread aim-assist (unlike a left/right
	 * tap) — middle-click is a deliberate, literal-point action.
	 */
	public static void onMiddleClick(int x, int y)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}
		synthesizeClick(canvas, x, y, MouseEvent.BUTTON2);
	}

	/**
	 * One phase of a drag stream — {@link #TOUCH_DOWN}/{@link #TOUCH_MOVE}/{@link #TOUCH_UP} at
	 * {@code (x,y)}, {@code button} 1 or 3. DOWN presses, MOVE drags (or hovers when not pressed), UP
	 * releases — with NO synthesized click (unlike a tap, which goes through {@link #onClick}). Used by the
	 * camera / scroll gestures, where a release must not register as a walk-here click.
	 */
	public static void onTouch(int type, int x, int y, int button)
	{
		final Canvas canvas = liveCanvas();
		if (canvas == null)
		{
			return;
		}

		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		final int awtButton = button == 3 ? MouseEvent.BUTTON3 : MouseEvent.BUTTON1;
		final int downMask = awtButton == MouseEvent.BUTTON3
			? InputEvent.BUTTON3_DOWN_MASK : InputEvent.BUTTON1_DOWN_MASK;

		switch (type)
		{
			case TOUCH_DOWN:
				primeFocus(q, canvas, t, x, y);
				q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t, 0, x, y, 0, false));
				q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_PRESSED, t + 1,
					downMask, x, y, 1, false, awtButton));
				pressed = true;
				pressButton = awtButton;
				break;

			case TOUCH_MOVE:
				if (pressed)
				{
					q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_DRAGGED, t,
						pressButton == MouseEvent.BUTTON3 ? InputEvent.BUTTON3_DOWN_MASK : InputEvent.BUTTON1_DOWN_MASK,
						x, y, 0, false, MouseEvent.NOBUTTON));
				}
				else
				{
					q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t, 0, x, y, 0, false));
				}
				break;

			case TOUCH_UP:
				// Release only — a drag is NOT a click. (The pre-Phase-5 auto-MOUSE_CLICKED here was the
				// phantom-click bug: every camera/scroll drag ended with a stray walk-here click.)
				q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_RELEASED, t,
					0, x, y, 1, false, pressed ? pressButton : awtButton));
				pressed = false;
				break;

			default:
				log.warn("[bridge] onTouch unknown type {}", type);
				break;
		}
	}
}
