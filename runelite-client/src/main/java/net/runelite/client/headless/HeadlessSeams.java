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

import java.awt.Graphics;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.MainBufferProvider;

/**
 * Single dispatch point for the fork's per-frame headless seams, invoked from
 * {@link net.runelite.client.callback.Hooks}. The fork wires ~30 headless bridges + dev probes into the
 * engine's draw cycle; keeping the whole chain here (instead of woven through {@code Hooks.draw}/{@code
 * drawScene}) shrinks the upstream-merge conflict surface in {@code Hooks} to three one-line calls — the
 * central friction point for tracking unmodified upstream RuneLite.
 *
 * <p>This is a behaviour-preserving relocation: every call, its guard, and the call order are identical to
 * the previous inline form (including the deliberate twice-per-frame {@code RouteCGpuStarter}/{@code
 * RLHDStarter} ticks — once pre-composite to flip {@code isGpu} on, once post-composite). All methods run on
 * the client (engine) thread. Being in the {@code headless} package, the bridges/probes are referenced
 * unqualified. The HUD pre-render seam is NOT here — it is a last-priority {@code BeforeRender} EventBus
 * subscriber registered in {@link net.runelite.client.ui.HeadlessClientUI} (see
 * {@link HudVeneerBridge.BeforeRenderListener}), so {@code Hooks.frame()} needs no fork edit at all.
 *
 * <p>Both the iOS and Android ports embed this jar and call the same bridge facades; they depend on these
 * ticks running once per frame in this order before the frame is published, not on where the calls live.
 *
 * <p><b>Fault isolation (QA-P1-07).</b> Each bridge call below runs through {@link #guard} so a throw is
 * rate-limit-logged via {@link BridgeFaults} and contained to that one bridge, instead of escaping back into
 * {@code Hooks.draw}/{@code drawScene} and killing the engine frame thread. This is the seam-level backstop
 * for the per-frame bridges: a bridge {@code tick()} that self-guards internally never reaches it, but a
 * throw that escapes one (or an unguarded leaf like a starter/probe) lands here, and — crucially — the
 * remaining seam calls for the frame still run, so one faulting bridge can't cascade into a dead HUD or a
 * dropped tap (the exact failure mode QA-SYS-1 set out to make impossible).
 */
public final class HeadlessSeams
{
	private HeadlessSeams()
	{
	}

	/**
	 * Run one bridge seam call in isolation: a throw is recorded (rate-limited) via {@link BridgeFaults}
	 * instead of escaping into {@code Hooks.draw}/{@code drawScene} and killing the engine frame thread, and
	 * the remaining seam calls for this frame still run. {@code Throwable} is caught on purpose — the faults
	 * most worth surfacing at this seam are the {@code LinkageError}/{@code NoSuchMethodError}/{@code
	 * NoClassDefFoundError} kind an upstream merge can introduce (a removed/changed engine API behind a
	 * frozen HUD), not just {@code RuntimeException}. The per-call lambda is non-escaping and is
	 * scalar-replaced by C2 on the JITed client thread, so this adds no steady-state allocation.
	 */
	private static void guard(String site, Runnable body)
	{
		try
		{
			body.run();
		}
		catch (Throwable t)
		{
			// guard() is the SOLE fault barrier — the three HeadlessSeams calls in Hooks.draw/drawScene are
			// deliberately unguarded — so even the sink must not escape: a StackOverflowError thrown by a bridge
			// arrives here with the stack already at the limit, and SLF4J's stack-trace formatting inside note()
			// can re-trigger it; that re-throw would otherwise reach Hooks and kill the frame thread. Swallow it
			// so the barrier is truly terminal (a lost fault line beats a dead engine).
			try
			{
				BridgeFaults.note(site, t);
			}
			catch (Throwable ignored)
			{
				// nothing safe left to do — hold the barrier
			}
		}
	}

	/**
	 * Pre-composite seam: the very top of {@code Hooks.draw}, before the {@code graphics == null} guard and
	 * before overlays composite.
	 */
	public static void draw(Client client, Graphics graphics)
	{
		guard("seam.HeadlessCapture.onDraw", () ->
		{
			HeadlessCapture.onDraw(graphics);
			if (HeadlessCapture.isEnabled())
			{
				HeadlessCapture.observe(
					client.getGameState(), client.getLoginIndex(), client.getLauncherDisplayName());
			}
		});
		if (JavaBridge.isEnabled())
		{
			guard("seam.JavaBridge.register", () ->
			{
				// Keep the native shell's touch bridge pointed at the current client (the frame snapshot is
				// taken post-composite, below).
				JavaBridge.register(client);
				// iOS load-in flash guard: re-arm the publish hold whenever we're not in a continuously-rendered
				// world — the login screen, world hopping, connection lost, etc. We deliberately do NOT re-arm on
				// plain LOADING, since that also fires during seamless in-play region streaming while running (where
				// the scene keeps rendering and there's no sky flash to hide). drawScene() clears it back to true
				// once geometry is rendered. See JavaBridge.sceneDrawn.
				GameState gs = client.getGameState();
				if (gs != GameState.LOGGED_IN && gs != GameState.LOADING)
				{
					JavaBridge.armSceneHold();
				}
			});
		}
		if (MobileUiBridge.isEnabled())
		{
			// Snapshot UI-state the native chrome polls (chat-input bounds / soft-input) on the client thread.
			guard("seam.MobileUiBridge.tick", () -> MobileUiBridge.tick(client));
		}
		if (HeadlessLogin.isEnabled())
		{
			guard("seam.HeadlessLogin.tick",
				() -> HeadlessLogin.tick(client, client.getGameState(), client.getLoginIndex()));
		}
		if (WelcomePlayProbe.isEnabled())
		{
			// GPU Route C: dismiss the post-login "Welcome to Gielinor / Click here to play" screen so the engine
			// actually enters the world render (without this, headless parks on the welcome screen and no scene
			// renders — in CPU or GPU mode). Gated -Drunelite.headless.welcomeplay=true.
			guard("seam.WelcomePlayProbe.tick", () -> WelcomePlayProbe.tick(client, client.getGameState()));
		}
		if (HeadlessResize.isEnabled())
		{
			guard("seam.HeadlessResize.tick", () -> HeadlessResize.tick(client, client.getGameState()));
		}
		if (RouteCGpuStarter.isEnabled())
		{
			// GPU Route C: force-enable + start the gpu plugin once in-world (canvas valid), overriding a persisted
			// gpuplugin=false and the startUp-too-early canvas race so the plugin reliably creates its GL context
			// instead of silently falling back to the CPU renderer. Runs before the isGpu early-return.
			// Gated -Drunelite.routecgpu=true.
			guard("seam.RouteCGpuStarter.tick", () -> RouteCGpuStarter.tick(client));
		}
		if (RLHDStarter.isEnabled())
		{
			// W3 GPU Zone B0.5: load + start the EXTERNAL 117HD plugin (rs117.hd.HdPlugin, in the staged rlhd jar)
			// once there's a drawing canvas, then force the canvas valid until it activates. HdPlugin conflicts=GPU
			// so it auto-disables the base gpu plugin (do NOT also arm RouteCGpuStarter in this mode).
			// Gated -Drunelite.routecrlhd=true.
			guard("seam.RLHDStarter.tick", () -> RLHDStarter.tick(client));
		}
		if (MobileChromeBridge.isEnabled())
		{
			// W3 hybrid-chrome read surface: snapshot desktop tab/panel/minimap/orb/chat/viewport geometry +
			// active-tab varc on the client thread for the native chrome. Read-only — mutates nothing.
			guard("seam.MobileChromeBridge.tick", () -> MobileChromeBridge.tick(client));
		}
		if (HudDataBridge.isEnabled())
		{
			// W3 Feature-A phase A2: read-only HUD DATA snapshot (chat lines / orb values / minimap positions)
			// the native HUD veneers reproduce. Client thread; mutates nothing. Gated -Drunelite.huddata=true.
			guard("seam.HudDataBridge.tick", () -> HudDataBridge.tick(client));
		}
		if (HudVeneerBridge.isEnabled())
		{
			// W3 Feature-A phase A3: suppress the engine HUD elements the native veneers replace (chatbox),
			// re-applied each frame. State set from native via setChatHidden. Gated -Drunelite.hudveneer=true.
			guard("seam.HudVeneerBridge.tick", () -> HudVeneerBridge.tick(client));
		}
		if (ChatRelocateProbe.isEnabled())
		{
			// W3 Feature-A (A3): can the engine chatbox be RELOCATED to the top (exact OSRS skin) vs occluded?
			// Mutates widget position; gated -Drunelite.chatreloc=true. Desktop de-risk only.
			guard("seam.ChatRelocateProbe.tick", () -> ChatRelocateProbe.tick(client, client.getGameState()));
		}
		if (MenuPeekBridge.isEnabled())
		{
			// W3 touch-targeting: publish the read-only menu-peek snapshot the native press-and-peek UI polls
			// (the menu the engine computed for the finger the native side streamed via JavaBridge.onMove).
			// Read-only; gated -Drunelite.menupeek=true. Runs BEFORE the probe so the probe can cross-check it.
			guard("seam.MenuPeekBridge.tick", () -> MenuPeekBridge.tick(client));
		}
		if (JavaBridge.isEnabled())
		{
			// W3 touch-targeting: advance the engine-resolved tap state machine (settle gate -> click ->
			// truth classification). Client thread, after the engine tick rebuilt the menu — the same settle
			// seam MenuPeekBridge reads from. Gated -Drunelite.bridge=true (inert on desktop).
			guard("seam.JavaBridge.tapTick", () -> JavaBridge.tapTick(client));
		}
	}

	/**
	 * Post-composite seam: after the ALWAYS_ON_TOP overlay + clientUI overlays composite into
	 * {@code mainBufferProvider}, before the {@code client.isGpu()} early-return.
	 */
	public static void postComposite(Client client, MainBufferProvider mainBufferProvider)
	{
		// GPU Route C (AG2): force-enable + start the base gpu plugin once in-world, overriding a persisted
		// gpuplugin=false and forcing the canvas valid so startUp's createGLContext fires. Inert (no-op) unless
		// -Drunelite.routecgpu=true; runs before the isGpu early-return because it is what flips isGpu on.
		if (RouteCGpuStarter.isEnabled())
		{
			guard("seam.RouteCGpuStarter.tick.post", () -> RouteCGpuStarter.tick(client));
		}

		// Track G AG3-b: load + start the 117HD (RLHD) plugin (Zone) once in-world, overriding the base gpu plugin
		// (HdPlugin declares conflicts="GPU", so startPlugin disables it). Inert unless -Drunelite.routecrlhd=true.
		if (RLHDStarter.isEnabled())
		{
			guard("seam.RLHDStarter.tick.post", () -> RLHDStarter.tick(client));
		}

		// iOS "renderers as plugins": surface the GPU + 117HD plugins in the native panel (loaded, not started)
		// so they're selectable + configurable regardless of the active renderer. Inert unless
		// -Drunelite.rendererpanel=true; the active renderer is still started by the starters above.
		if (RendererPanelStarter.isEnabled())
		{
			guard("seam.RendererPanelStarter.tick", () -> RendererPanelStarter.tick(client));
		}

		// W3 touch-targeting: draw the tap selection feedback (tight entity model outline) into the frame, on
		// top of the scene/overlays, just before it's captured/blitted.
		if (JavaBridge.isEnabled())
		{
			guard("seam.JavaBridge.drawSelection", () -> JavaBridge.drawSelection(client));
		}

		// Headless capture seam: composited game + overlays now live in mainBufferProvider.getImage().
		// In GPU mode (Route C) mainBufferProvider is the UI-only layer (the game is on the GPU), so a CPU
		// capture here is both useless AND a per-frame ~1.5 MB BufferedImage allocation that OOMs the heap once
		// 117HD's ZoneRenderer is resident — gate it off, same as the JavaBridge snapshot below.
		if (!client.isGpu())
		{
			guard("seam.HeadlessCapture.capture", () -> HeadlessCapture.capture(mainBufferProvider));
		}
		// Live-blit seam: snapshot the now-complete frame for the native shell (avoids mid-composite tearing).
		// In GPU mode (Route C) mainBufferProvider holds only the UI layer; the authoritative composited frame
		// is published later by the gpu plugin's swapBuffers shim, which is then the SOLE frameSeq publisher.
		// Gating the CPU snapshot off here prevents the UI-only frame from flashing between GPU frames.
		if (JavaBridge.isEnabled() && !client.isGpu())
		{
			guard("seam.JavaBridge.snapshot", () -> JavaBridge.snapshot(mainBufferProvider));
		}
	}

	/**
	 * Scene seam: the top of {@code Hooks.drawScene}, before the ABOVE_SCENE overlay renders.
	 */
	public static void drawScene(Client client)
	{
		// iOS load-in flash guard: count this 3D scene render. The GPU publish stays held until a few of these
		// have accumulated (zones still upload for a few frames after the first draw, so the first frames are bare
		// sky) — re-armed to 0 on non-world game states in draw(). See JavaBridge.sceneDrawCount.
		if (JavaBridge.isEnabled())
		{
			guard("seam.JavaBridge.noteSceneDraw", JavaBridge::noteSceneDraw);
		}
	}
}
