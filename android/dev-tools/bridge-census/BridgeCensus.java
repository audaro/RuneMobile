// Phase A-1 bridge census (static half).
//
// Verifies that every public-static bridge method the Android port's A0-A8 mainline depends on actually
// resolves in the shaded jar the port embeds — turning the plan's central "the shared Java is already there"
// claim into a captured, md5-gateable fact instead of a source-tree inference.
//
// Design: each bridge class is loaded with initialize=FALSE so we never run its <clinit> (which builds a
// java.awt.Color and would drag in the headless-AWT toolkit). We then enumerate its declared public-static
// methods and match them, by name + ordered parameter simple-type names, against the expected contract below.
// Loading a class (and its parameter types) links but does NOT initialize it, so this is safe to run on a
// stock desktop OpenJDK with no CACIO activation and no JPMS --add-exports (the jar is on the classpath =
// unnamed module). Output is sorted for a deterministic md5.
//
// The expected contract is the full public-static surface of the eight bridges as of this writing
// (net.runelite.client.headless.*). Run: see run-census-desktop.sh.

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

public final class BridgeCensus
{
	private static final String PKG = "net.runelite.client.headless.";

	// Expected contract: "SimpleClass#method(paramSimpleType,...)". Engine-side registration methods
	// (register/init/tick/snapshot/...) are included too — the census proves the whole seam is present, not
	// just the host-facing subset, which is strictly stronger.
	private static final String[] CONTRACT = {
		// --- JavaBridge: render + core/precise input ---
		"JavaBridge#isEnabled()",
		"JavaBridge#register(Client)",
		"JavaBridge#setClientThread(ClientThread)",
		"JavaBridge#snapshot(MainBufferProvider)",
		"JavaBridge#getFrameWidth()",
		"JavaBridge#getFrameHeight()",
		"JavaBridge#getFrameSeq()",
		"JavaBridge#getFramePixels()",
		"JavaBridge#clearHover()",
		"JavaBridge#onClick(int,int,int)",
		"JavaBridge#drawSelection(Client)",
		"JavaBridge#onClickPrecise(int,int,int)",
		"JavaBridge#selectMenuPoint(int,int)",
		// snapRadius() was deleted with the touch-Phase-0 snap machinery (ad41581f2f); Android dropped the
		// native poll in d3e34be70a (ships SNAP_RADIUS=0 = mobile parity), so it is intentionally not listed.
		"JavaBridge#getInteractTapSeq()",
		"JavaBridge#onMove(int,int)",
		"JavaBridge#onWheel(int,int,int)",
		"JavaBridge#onCameraDrag(int,int)",
		"JavaBridge#onText(String)",
		"JavaBridge#isTextInputOpen()",
		"JavaBridge#onKeyStroke(int)",
		"JavaBridge#onTouch(int,int,int,int)",
		// --- MobileUiBridge: plugin control plane + panels (A4/A5) ---
		"MobileUiBridge#isEnabled()",
		"MobileUiBridge#init(PluginManager,ConfigManager,ClientThread,Client,EventBus)",
		"MobileUiBridge#getMobileUiSeq()",
		"MobileUiBridge#pollMobileUiEvents(long)",
		"MobileUiBridge#getProcessedWriteId()",
		"MobileUiBridge#flushConfig()",
		"MobileUiBridge#registerNav(NavigationButton)",
		"MobileUiBridge#unregisterNav(NavigationButton)",
		"MobileUiBridge#listPanels()",
		"MobileUiBridge#openPanel(int)",
		"MobileUiBridge#closePanel()",
		"MobileUiBridge#getPanelWidth()",
		"MobileUiBridge#getPanelHeight()",
		"MobileUiBridge#getPanelFrameSeq()",
		"MobileUiBridge#getPanelPixels()",
		"MobileUiBridge#panelClick(int,int)",
		"MobileUiBridge#hubManifest()",
		"MobileUiBridge#hubInstall(String)",
		"MobileUiBridge#hubUninstall(String)",
		"MobileUiBridge#listPlugins()",
		"MobileUiBridge#getPluginConfig(String)",
		"MobileUiBridge#setPluginEnabled(String,boolean)",
		"MobileUiBridge#setConfig(String,String,String)",
		"MobileUiBridge#resetConfig(String,String)",
		"MobileUiBridge#tick(Client)",
		"MobileUiBridge#isChatInputVisible()",
		"MobileUiBridge#getChatInputBounds()",
		// --- MenuPeekBridge: press-and-peek native menu (A2) ---
		"MenuPeekBridge#isEnabled()",
		"MenuPeekBridge#tick(Client)",
		"MenuPeekBridge#getSnapshot()",
		"MenuPeekBridge#getTopFingerprint()",
		"MenuPeekBridge#getPublishSeq()",
		// --- MobileChromeBridge: tab rails (A6) ---
		"MobileChromeBridge#isEnabled()",
		"MobileChromeBridge#tick(Client)",
		"MobileChromeBridge#getSnapshot()",
		// --- HudDataBridge: native HUD veneer data (A7) ---
		"HudDataBridge#isEnabled()",
		"HudDataBridge#getSnapshot()",
		"HudDataBridge#getSeq()",
		"HudDataBridge#tick(Client)",
		// --- HudVeneerBridge: chat-at-top (A6/A7) ---
		"HudVeneerBridge#isEnabled()",
		"HudVeneerBridge#relocateChat(int,int,boolean)",
		"HudVeneerBridge#setChatHidden(boolean)",
		"HudVeneerBridge#tick(Client)",
		// --- QuestHelperBridge: curated native panel (A5) ---
		"QuestHelperBridge#init(PluginManager,ClientThread)",
		"QuestHelperBridge#isAvailable()",
		"QuestHelperBridge#setUiOpen(boolean)",
		"QuestHelperBridge#getQuestListJson()",
		"QuestHelperBridge#getQuestActiveJson()",
		"QuestHelperBridge#startQuest(String)",
		"QuestHelperBridge#stopQuest()",
		"QuestHelperBridge#tick(Client)",
		// --- WorldSwitcherBridge: curated native panel (A5) ---
		"WorldSwitcherBridge#init(Client,ClientThread,PluginManager)",
		"WorldSwitcherBridge#isAvailable()",
		"WorldSwitcherBridge#setUiOpen(boolean)",
		"WorldSwitcherBridge#getWorldListJson()",
		"WorldSwitcherBridge#hop(int)",
		"WorldSwitcherBridge#tick(Client)",
	};

	public static void main(String[] args)
	{
		// Per-class cache of the resolved public-static method signatures present in the jar.
		Map<String, Set<String>> haveByClass = new LinkedHashMap<>();
		Set<String> classesPresent = new TreeSet<>();
		Set<String> classesAbsent = new TreeSet<>();

		List<String> lines = new ArrayList<>();
		int resolved = 0;
		int missing = 0;

		for (String entry : CONTRACT)
		{
			int hash = entry.indexOf('#');
			String simpleClass = entry.substring(0, hash);
			String sig = entry.substring(hash + 1);
			Set<String> have = haveByClass.computeIfAbsent(simpleClass,
				sc -> signaturesOf(sc, classesPresent, classesAbsent));
			boolean ok = have.contains(sig);
			lines.add((ok ? "RESOLVED " : "MISSING  ") + simpleClass + "#" + sig);
			if (ok)
			{
				resolved++;
			}
			else
			{
				missing++;
			}
		}

		Collections.sort(lines);
		for (String l : lines)
		{
			System.out.println(l);
		}

		System.out.println("CLASSES_PRESENT " + classesPresent.size() + " " + String.join(",", classesPresent));
		if (!classesAbsent.isEmpty())
		{
			System.out.println("CLASSES_ABSENT " + classesAbsent.size() + " " + String.join(",", classesAbsent));
		}
		System.out.println("BRIDGE_CENSUS verdict=" + (missing == 0 ? "GREEN" : "RED")
			+ " resolved=" + resolved + " missing=" + missing + " total=" + CONTRACT.length);
	}

	/** All public-static method signatures of a bridge class, loaded WITHOUT running its static initializer. */
	private static Set<String> signaturesOf(String simpleClass, Set<String> present, Set<String> absent)
	{
		Set<String> out = new TreeSet<>();
		try
		{
			Class<?> c = Class.forName(PKG + simpleClass, false, BridgeCensus.class.getClassLoader());
			present.add(simpleClass);
			for (Method m : c.getDeclaredMethods())
			{
				int mod = m.getModifiers();
				if (!Modifier.isStatic(mod) || !Modifier.isPublic(mod))
				{
					continue;
				}
				StringBuilder sb = new StringBuilder(m.getName()).append('(');
				Class<?>[] ps = m.getParameterTypes();
				for (int i = 0; i < ps.length; i++)
				{
					if (i > 0)
					{
						sb.append(',');
					}
					sb.append(ps[i].getSimpleName());
				}
				sb.append(')');
				out.add(sb.toString());
			}
		}
		catch (Throwable t)
		{
			absent.add(simpleClass);
			System.err.println("WARN could not load " + simpleClass + ": " + t);
		}
		return out;
	}
}
