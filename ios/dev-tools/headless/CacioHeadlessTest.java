import com.github.caciocavallosilano.cacio.ctc.junit.CacioExtension;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * Gate 1c experiment 2: boot real RuneLite with the window-less HeadlessClientUI under the CACIO CTC
 * toolkit — the offscreen virtual display, NO OS window — which is the honest iOS-shaped proxy. Uses
 * the same proven CACIO activation path as the Gate 1b overlay smoke (CacioExtension installs the CTC
 * toolkit/GraphicsEnvironment via byte-buddy BEFORE AWT init; bare programmatic inject from a plain
 * main fails with a class-redefinition schema error, so we go through the JUnit extension).
 *
 * RuneLite.main returns after start() (the engine runs on its own non-daemon threads); the sleep keeps
 * the run alive long enough for HeadlessCapture to dump frames. The launcher process is killed by the
 * wrapper script after headless.runSeconds.
 */
@ExtendWith(CacioExtension.class)
public class CacioHeadlessTest
{
	@Test
	public void bootHeadlessUnderCacio() throws Exception
	{
		System.out.println("[cacio] toolkit=" + java.awt.Toolkit.getDefaultToolkit().getClass().getName());
		System.out.println("[cacio] graphicsenv=" + java.awt.GraphicsEnvironment.getLocalGraphicsEnvironment().getClass().getName());
		System.out.println("[cacio] headless=" + java.awt.GraphicsEnvironment.isHeadless());

		net.runelite.client.headless.RuneLiteHeadless.main(new String[]{"--safe-mode"});

		final long runSeconds = Long.getLong("headless.runSeconds", 45L);
		Thread.sleep(runSeconds * 1000L);
	}
}
