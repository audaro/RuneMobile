// Does the AGENT path activate CTC without JUnit? CacioExtension.injectCTCGraphicsEnvironment()
// is public static — call it directly, then run the same assertions as AwtActivation.
// This isolates the question: is the working desktop mechanism the ByteBuddy
// redefinition agent (not property selection)? If yes here, the device question
// becomes "can we run that agent on the iOS JRE" — a very different problem than the
// brief assumed.
import com.github.caciocavallosilano.cacio.ctc.junit.CacioExtension;

public class AwtActivationAgent {
    public static void main(String[] args) throws Exception {
        System.out.println("==== AwtActivationAgent (call injectCTCGraphicsEnvironment directly) ====");
        try {
            CacioExtension.injectCTCGraphicsEnvironment();
            System.out.println("injectCTCGraphicsEnvironment() returned OK");
        } catch (Throwable t) {
            System.out.println("injectCTCGraphicsEnvironment() THREW: " + t);
            t.printStackTrace(System.out);
        }
        AwtActivation.main(args); // reuse the assertions + greppable verdict
    }
}
