// Why a session ended, told at the start of the next one.
//
// CS_DEBUGGED is per-process and sticky, so a process that never dies never needs re-attaching --
// which makes process DEATH, not the attach, the thing that costs the user the whole JIT dance
// (LocalDevVPN plus the StikDebug attach). The app already
// fights hard to stay resident: the `audio` background mode, a silent AVAudioEngine holding the
// session, the PiP pump, a background task. What has never existed is any record of whether that
// works, or of what ends a session when it doesn't.
//
// Nothing here changes residency. It measures it, because the alternative is tuning a keepalive
// against a guess -- and the plausible causes (jetsam under the JVM's footprint, a stolen audio
// session, a plain crash, the user swiping away) call for opposite fixes and are indistinguishable
// without data. A verdict line at launch turns "it seems to die sometimes" into a duration and a
// cause.
//
// Durable across a kill that gives no notice: the record is a file rewritten atomically on each
// beat, following the 117HD crash-cookie pattern already in ViewController.m rather than
// NSUserDefaults, whose last write can be lost exactly when it matters most.
//
// Each ended session also lands as one line in Documents/residency-history.log, because a single
// verdict answers nothing. The three plausible causes call for opposite fixes -- a smaller heap, a
// steadier audio session, a longer idle gate -- and what tells them apart is their PROPORTIONS
// over a week of ordinary use, which only exist if the lines accumulate. Read them with
// ios/dev-tools/residency.py.
//
// SUSPECTED, NOT CONFIRMED. Only a clean exit is evidence -- iOS tells us about that one. Every
// other verdict is inferred from a sample taken up to the beat interval before the process died,
// and the inference has real holes: a memory warning does not establish jetsam, jetsam can arrive
// between samples with no warning at all, and an unexpected foreground exit is not necessarily a
// crash. The DURATION has a hole of its own, and a wider one: it is measured to the last beat, and
// a suspended process fires no timer while remaining perfectly resident, so any session iOS put to
// sleep -- every session the idle gate released, by design -- lived longer than it reports. Hence
// "ran for at least" on everything but a clean exit. The lines this emits are phrased as "consistent with" rather than as causes on purpose,
// because its output is what gets read months from now with nobody around to re-add the caveat.
// When a verdict actually matters, read ground truth instead: the JetsamEvent-*.ips and crash
// reports under Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data, and
// Documents/jvm-stdio.log, which is dup2'd UNBUFFERED precisely so it survives a silent jetsam
// (the crash-safe stderr fd in JVMLauncher.m). This record is for spotting the pattern; those are
// for proving it.
#import <Foundation/Foundation.h>

@interface RMResidency : NSObject

// Call once, early in launch. Reads the previous session's record, appends it to the history,
// returns a line describing how it ended (nil on the very first run), and starts a fresh record.
// Safe before anything else is set up.
+ (NSString *)noteLaunchAndVerdict;

// The periodic sample: timestamp, state and jetsam headroom. Driven by a timer in ViewController;
// the resolution of the final verdict is this interval.
+ (void)beat;

+ (void)noteForeground;
+ (void)noteBackground;
+ (void)noteMemoryWarning;

// This session reached CS_DEBUGGED, so its death costs a re-attach. Recorded to separate the deaths
// that actually cost the user something from the ones that do not.
+ (void)noteJitAttached;

// The KEEPALIVE-1 background idle gate released the keepalive on purpose, so that iOS COULD
// suspend us (ViewController.m, bgIdleGate). Recorded because a death after that point is the
// design working, not residency failing -- without this the next launch would report a deliberate
// release as an unexplained kill and send someone chasing a feature.
+ (void)noteIdleGateReleased;

// The keepalive engine was found stopped by something other than the idle gate and restarted.
// Worth counting: a process that stopped being resident did so for a reason that is not memory
// pressure and does not have memory pressure's fix.
//
// The REASON is recorded too, as a short tag, because the count alone does not say what happened.
// Four different events end here -- an interruption, a route change, a media-services reset, and
// the watchdog finding the engine stopped with nobody having said why -- and they do not share a
// fix. Calling every one of them a dropped audio session would be a diagnosis the record cannot
// support.
+ (void)noteKeepaliveRearmed:(NSString *)reason;

// A new keepalive window began (a fresh background trip), so any earlier idle-gate release is no
// longer in force. Without this the release would excuse every later death in the session.
+ (void)noteKeepaliveWindowBegan;

// The only clean ending: iOS told us it was terminating. Anything else is a kill we never saw.
+ (void)noteCleanExit;

// How the last `count` ended sessions went, oldest first: one line each, for Share logs. One verdict can't say whether
// a death is a habit.
+ (NSString *)recentSessions:(NSUInteger)count;

@end
