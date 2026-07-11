import com.github.caciocavallosilano.cacio.ctc.junit.CacioExtension;
import java.awt.GraphicsEnvironment;
import java.awt.Toolkit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * Gate 1b proper: runs the overlay scene under the CACIO CTC toolkit, which CacioExtension
 * installs (via byte-buddy) BEFORE AWT initializes. Confirms cacio-tta runs on JDK 21 and that
 * font registration + the overlay draw ops survive a swapped Toolkit/GraphicsEnvironment.
 */
@ExtendWith(CacioExtension.class)
public class OverlaySmokeTest
{
    @Test
    public void rendersUnderCacio() throws Exception
    {
        System.out.println("[cacio] toolkit=" + Toolkit.getDefaultToolkit().getClass().getName());
        System.out.println("[cacio] graphicsenv=" + GraphicsEnvironment.getLocalGraphicsEnvironment().getClass().getName());
        String fontDir = System.getProperty("smoke.fontDir");
        String out = System.getProperty("smoke.out", "out/overlay-cacio.png");
        OverlaySmoke.renderScene(fontDir, out);
    }
}
