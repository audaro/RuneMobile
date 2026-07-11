import com.github.caciocavallosilano.cacio.ctc.junit.CacioExtension;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * Phase-6 (W3) STEP-0 desktop harness for {@link net.runelite.client.headless.MobileUiSmokeRunner}.
 *
 * <p>This is now a THIN wrapper: it only activates CACIO CTC (the desktop way — the byte-buddy
 * {@code CacioExtension}, which the device cannot use) and boots {@code RuneLiteHeadless.main}. The actual
 * facade checks run inside {@code MobileUiSmokeRunner}'s daemon (armed by {@code RuneLiteHeadless.main} when
 * {@code -Drunelite.mobileui.smoke=true}) — the SAME code that runs on device under {@code DeviceHeadlessBoot}
 * /{@code UnsafePokeActivation}. So a desktop GREEN here re-proves the exact bytes the device runs; the only
 * difference is the CTC activation path.
 *
 * <p>The daemon prints {@code MUI_*} markers to stdout; the runner ({@code run-mobileui-smoke.sh}) greps them
 * and computes the md5-gated verdict in bash ({@code mobileui-verdict.sh}).
 */
@ExtendWith(CacioExtension.class)
public class MobileUiSmoke
{
	@Test
	public void smoke() throws Exception
	{
		System.out.println("[smoke] toolkit=" + java.awt.Toolkit.getDefaultToolkit().getClass().getName());
		// Drop safe-mode for the plugin-hub probe so ExternalPluginManager can load hub plugins (mirrors the
		// device boot's -Drunelite.hub gate). Default keeps safe-mode, matching the device's normal boot.
		final String[] rlArgs = Boolean.getBoolean("runelite.hub") ? new String[0] : new String[]{"--safe-mode"};
		net.runelite.client.headless.RuneLiteHeadless.main(rlArgs);

		// Hold the run open long enough for the daemon to finish its checks (it prints MUI_DONE=1).
		final long runSeconds = Long.getLong("headless.runSeconds", 60L);
		Thread.sleep(runSeconds * 1000L);
	}
}
