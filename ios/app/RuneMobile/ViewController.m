#import "ViewController.h"
#import "JVMLauncher.h"
#import "AboutViewController.h"
#import "PluginConfigViewController.h"
#import "PluginHubViewController.h"
#import "PluginPanelsViewController.h"
#import "OverlayEditView.h"
#import "JagexLoginViewController.h"
#import "GLRecon.h"
#import "RMDiagnostics.h"
#import "RMKeyboardDismiss.h"
#import "RMResidency.h"
#import "RMGameSettings.h"
#import "RMHeat.h"
#import "RMHeatNotice.h"
#import "RouteCBridge.h"            // GPU Route C bridge (backend selected by RC_BACKEND_ANGLE in the build)
#import <QuartzCore/QuartzCore.h>
#if !defined(RC_BACKEND_ANGLE)
#import <OpenGLES/EAGLDrawable.h>   // kEAGLDrawableProperty* (EAGL direct present; not linked in the ANGLE build)
#endif
#import <WebKit/WebKit.h>
#import <CoreText/CoreText.h>
#import <SafariServices/SafariServices.h>
#import <UserNotifications/UserNotifications.h>
#import <Photos/Photos.h>
#import <AVKit/AVKit.h>             // Picture-in-Picture (AVPictureInPictureController + content source)
#import <AVFoundation/AVFoundation.h> // AVSampleBufferDisplayLayer + the background-keepalive audio session
#import <CoreMedia/CoreMedia.h>     // CMSampleBuffer plumbing for the PiP frame feed
#import <objc/runtime.h>            // objc_setAssociatedObject — attach a control's spec to its button
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>            // the Release perf-probe log's reader thread
#import <os/lock.h>            // os_unfair_lock — guards the JSON-fault rate-limiter (QA-SYS-1 sibling)
#import <time.h>               // clock_gettime_nsec_np — monotonic window for the rate-limiter
#import <mach/mach.h>          // task_info — resident memory for the developer-mode diagnostics readout
#import <sys/utsname.h>        // uname — device model identifier for the diagnostics report

// The chat tabs match the official mobile app's small size, which makes them fiddly to hit. This button expands its
// touch area vertically (the 7 tabs are contiguous, so a horizontal miss already lands on a neighbour) so near-miss
// taps above/below a tab still register on that column. Purely a hit-test grow — the visible sprite is unchanged.
static const CGFloat kChatTabTouchExpand = 15.0;     // screen pt added above each tab's touch rect
static const CGFloat kChatTabTouchExpandBelow = 4.0; // and below it, short of the chat's top line
// A new install's starting settings, and the flag that they are still to be set. See applyNewInstallDefaults.
static NSString *const kNewInstallDefaultsKey = @"newInstallDefaults";
static const int kNewInstallFpsCap = 30;
static NSString *const kNewInstallDrawDistance = @"30";    // base GPU's, down from the plugin's 50
static const unsigned long long kShellLogCap = 8ull << 20; // hello-shell.log bytes per launch (appendLine)
@interface ChatTabButton : UIButton
@end
@implementation ChatTabButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect r = self.bounds;
    r.origin.y -= kChatTabTouchExpand;
    r.size.height += kChatTabTouchExpand + kChatTabTouchExpandBelow;
    return CGRectContainsPoint(r, point);
}
@end

// TOUCH-1: the tab-grid stones tile flush in the ~230pt band under the minimap, which caps the visual cell
// well below the 44pt minimum (7 rows × 44 = 308pt simply doesn't fit next to the minimap). Interior edges
// can't grow (they'd overlap a neighbour), but every OUTER edge of the grid borders free space — so each
// button expands its hit rect outward only, per its position in the grid (left column into the scene, right
// column/bottom row into the screen margin, top row into the minimap gap). Visual sprite unchanged.
@interface TabGridButton : UIButton
@property (nonatomic, assign) UIEdgeInsets hitOutset;
@end
@implementation TabGridButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIEdgeInsets o = self.hitOutset;
    CGRect r = CGRectMake(self.bounds.origin.x - o.left,
                          self.bounds.origin.y - o.top,
                          self.bounds.size.width + o.left + o.right,
                          self.bounds.size.height + o.top + o.bottom);
    return CGRectContainsPoint(r, point);
}
@end

// The official click-marker colours, in one place: yellow = a plain walk, red = the tap grabbed an
// interactable. Three sites draw or repaint the ring (the lift, the interact answer, the walk fallback) and
// they have to agree.
static UIColor *RMWalkRingColor(void) {
    return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
}
static UIColor *RMInteractRingColor(void) {
    return [UIColor colorWithRed:1.0 green:0.2 blue:0.15 alpha:1.0];
}

// ONE number decides tap vs drag for every one-finger touch on the canvas, and both halves of the decision
// read it, so they cannot disagree: a touch that never strays further than this (and lifts in time) is a
// CLICK, and the camera refuses to start rotating until it is exceeded.
//
// It exists because UIKit's own numbers are wrong for this. A pan recognizer begins after ~10pt — well inside
// the roll of an ordinary finger-tap — and the moment it does, it takes the touch away from BOTH the tap and
// the long-press. So a tap with a little roll in it rotated the camera a few pixels and never clicked, and a
// press-and-hold with a little roll never opened the menu either: the touch had already been classified as a
// drag before the user had finished making it. The official app has no such gap, which is what "make sure the
// click is determined based on whether the person is actually clicking or rotating" is about.
//
// 18pt ≈ 3mm of travel: past a finger's roll, well short of a deliberate drag. The cost is that rotation now
// has an 18pt dead zone instead of 10pt before the camera starts moving.
static const CGFloat kSceneDragSlop = 18.0;
// A touch that stays inside that radius but sits there is a hold, not a tap. The long-press recognizer fires
// at the long-press time (Settings > Game settings) and takes the sequence, opening the menu, so this margin
// past it only decides touches it did not claim.
static const NSTimeInterval kSceneTapHoldMargin = 0.05;

// The game canvas, and the tap classifier. A UIImageView subclass because the decision above has to be made
// from the raw touch sequence: -touchesBegan: runs the instant the finger lands (a tap recognizer cannot fire
// before it LIFTS, which is too late to arm the engine), and -touchesEnded: runs only for a sequence that no
// recognizer claimed — which is exactly the signal we need, since a recognizer that claims a touch cancels it
// in the view. So the camera pan, the long-press and the pinch keep their recognizers, and a lift that
// reaches here is a tap by elimination: whatever strayed too far or stayed too long is already somebody
// else's gesture. Controls layered above the canvas hit-test first, so a touch on one never arrives here.
@interface RMSceneView : UIImageView
/// The landing point (in this view) of the first finger of a touch sequence.
@property (nonatomic, copy) void (^touchDown)(CGPoint point);
/// Every move sample of a one-finger sequence, as it happens. The bridge replays these as the real travel of
/// a tap's press (JavaBridge.onTapMove); it ignores them unless a press of its own is actually down, so this
/// fires for the whole sequence and does not need to know what the gesture turned out to be.
@property (nonatomic, copy) void (^touchMoved)(CGPoint point);
/// A one-finger sequence that no recognizer took: where it landed, the furthest it ever strayed from there,
/// and how long it lasted. The handler decides whether that is a click.
@property (nonatomic, copy) void (^touchUp)(CGPoint origin, CGFloat strayed, NSTimeInterval held);
/// The sequence ended without a lift of its own — a recognizer claimed it (the camera, the hold, the zoom) or
/// the system took it (a call arrives, the app leaves the foreground). Never a click, and the one callback
/// that cannot be reached by reasoning about which gesture won.
@property (nonatomic, copy) void (^touchGone)(void);
@end

@implementation RMSceneView {
    CGPoint _origin;
    NSTimeInterval _landed;
    CGFloat _strayed;
    BOOL _multi; // a second finger joined: this sequence belongs to the pinch, not to a tap
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (event.allTouches.count != 1) {
        _multi = YES; // stays set until a fresh single-finger sequence starts
        return;
    }
    _origin = [touches.anyObject locationInView:self];
    _landed = CACurrentMediaTime();
    _strayed = 0;
    _multi = NO;
    if (self.touchDown) {
        self.touchDown(_origin);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (_multi) {
        return;
    }
    // The FURTHEST it ever got, not where it ended up: a finger that swings out and comes back was a drag.
    CGPoint p = [touches.anyObject locationInView:self];
    CGFloat d = hypot(p.x - _origin.x, p.y - _origin.y);
    if (d > _strayed) {
        _strayed = d;
    }
    if (self.touchMoved) {
        self.touchMoved(p);
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (_multi || !self.touchUp) {
        return;
    }
    self.touchUp(_origin, _strayed, CACurrentMediaTime() - _landed);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    // Not gated on _multi: the first finger of a sequence that grew into a pinch may well have armed a point.
    if (self.touchGone) {
        self.touchGone();
    }
}
@end

// The camera drag, held back to kSceneDragSlop. UIPanGestureRecognizer has no threshold to set, and its own
// ~10pt is small enough to steal taps and long-presses (see kSceneDragSlop), so keep it in Possible until the
// finger has clearly left the tap it might have been — a recognizer that never begins never takes the touch
// from anyone. Translation is unaffected: the pan measures its own from the landing point, and the handler
// already recovers the true touch start from it (DRAG-1), so a wider slop just means a bigger first reading.
@interface RMCameraPanRecognizer : UIPanGestureRecognizer
/// Where the finger actually landed, in this recognizer's own view. The handler needs the landing point to
/// decide what a drag STARTED on (an inventory slot, the chat, the map) and must not reconstruct it from the
/// translation at the moment the pan begins: whether that translation spans the whole withheld slop or only
/// the move that crossed it is UIKit's business, and the difference is a whole inventory slot.
@property (nonatomic, readonly) CGPoint landing;
/// When the finger landed (CACurrentMediaTime), so the handler can tell a held drag from a quick swipe.
@property (nonatomic, readonly) CFTimeInterval landedAt;
@end

@implementation RMCameraPanRecognizer {
    BOOL _tracking;
}

- (void)reset {
    [super reset];
    _tracking = NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (!_tracking) {
        _landing = [touches.anyObject locationInView:self.view];
        _landedAt = CACurrentMediaTime();
        _tracking = YES;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible && _tracking) {
        CGPoint p = [touches.anyObject locationInView:self.view];
        if (hypot(p.x - _landing.x, p.y - _landing.y) <= kSceneDragSlop) {
            return; // still inside tap range — withhold the move, stay Possible, claim nothing
        }
    }
    [super touchesMoved:touches withEvent:event];
}
@end

// The keyboard bar's Paste button target. A UIPasteControl pastes without the system's paste prompt and hands its
// target the clipboard's item providers; this one forwards the text to a handler, which types it into the game.
@interface RMPasteTarget : UIResponder
@property (nonatomic, copy) void (^onText)(NSString *text);
@end

@implementation RMPasteTarget
- (instancetype)init {
    if ((self = [super init])) {
        self.pasteConfiguration = [[UIPasteConfiguration alloc]
            initWithAcceptableTypeIdentifiers:@[ @"public.utf8-plain-text", @"public.plain-text", @"public.text" ]];
    }
    return self;
}

- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    for (NSItemProvider *p in itemProviders) {
        if (![p canLoadObjectOfClass:[NSString class]])
            continue;
        __weak typeof(self) ws = self;
        [p loadObjectOfClass:[NSString class]
            completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
                if (![(NSObject *)obj isKindOfClass:[NSString class]])
                    return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ws.onText)
                        ws.onText((NSString *)obj);
                });
            }];
        return; // the first text item only
    }
}
@end

// What a paste types into the game: the first line, trimmed, at most a chat line's 80 characters.
static NSString *RMPasteLine(NSString *s) {
    NSRange nl = [s rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    if (nl.location != NSNotFound)
        s = [s substringToIndex:nl.location];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length > 80)
        s = [s substringToIndex:[s rangeOfComposedCharacterSequenceAtIndex:80].location];
    return s;
}

@interface ViewController () <RMHeatScaleStore, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, SFSafariViewControllerDelegate, UNUserNotificationCenterDelegate, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, UISearchBarDelegate, OverlayEditHudHost> {
    // Game-canvas centres of each tab stone (updated each chrome refresh), used to proxy a tap onto the live
    // desktop stone. A C array, so it lives as an ivar rather than a property.
    CGPoint _tabCentres[14];
    // Developer-mode FPS sampler: the engine's rendered-frame seq + timestamp of the last sample window, and
    // the last computed rate. Uses JavaBridge.getFrameSeq (real composited frames), NOT display-link ticks.
    int _lastFrameSeq;
    CFTimeInterval _fpsStamp;
    double _lastFps;
    long _lastPresentCount; // RouteCBridge presents at the last sample: the 117HD direct-present path's frame count
}
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, strong) UIButton *launchButton; // dev-boot the JVM (the Tap-to-Play cover is the normal path)
@property (nonatomic, strong) UIButton *canaryButton; // "Test JIT" — the RWX self-test proving JIT is live
@property (nonatomic, strong) UIButton *keyboardButton;
@property (nonatomic, strong) UIButton *settingsButton;  // persistent ⚙ entry point (bottom-left) — the only always-on control
@property (nonatomic, strong) UIButton *kbFab;           // always-on ⌨︎ keyboard toggle, pinned top-centre (keyboard-safe)
@property (nonatomic, assign) BOOL onLoginScreen;        // the snapshot's loginScreen flag; see updateLoginScreenControls
@property (nonatomic, strong) UIStackView *controlsBox;  // packs the player's pinned on-screen controls to the right of the gear
@property (nonatomic, strong) UIView *editOverlay;       // the "Edit controls" palette overlay (nil unless editing)
@property (nonatomic, assign) BOOL developerMode;        // gates the dev tools (debug panel)
@property (nonatomic, strong) UIButton *shiftButton;     // sticky-Shift toggle (holds VK_SHIFT for shift-click)
@property (nonatomic, assign) BOOL shiftHeld;
@property (nonatomic, strong) UIButton *ctrlButton; // PARITY-IOS-LATCH: sticky-Ctrl toggle (holds VK_CONTROL)
@property (nonatomic, assign) BOOL ctrlHeld;
@property (nonatomic, assign) BOOL notifAuthRequested;   // UNUserNotificationCenter authorization asked once
@property (nonatomic, assign) BOOL safariOpen;           // an SFSafariViewController is currently presented
@property (nonatomic, strong) UIButton *screenshotButton; // 📷 save the live frame to Photos
@property (nonatomic, strong) UILabel *toastLabel;        // transient pill confirmation (replace-not-stack)
// KEY-1: an optional on-screen action-hotkey strip. The ⚡ chip toggles a row of buttons, one per *pinned*
// plugin hotkey (Ground Items hide, quick-hop, screenshot, …); a tap fires that plugin's configured Keybind via
// the bridge. Long-press the ⚡ chip to pick which hotkeys are pinned. Pinned set persists in NSUserDefaults.
@property (nonatomic, strong) UIButton *hotkeyButton;     // ⚡ toggle + (long-press) picker for the hotkey strip
@property (nonatomic, strong) UIStackView *hotkeyStrip;   // horizontal row of pinned hotkey buttons
@property (nonatomic, strong) NSArray *hotkeyActions;     // cached [{group,key,label,keyCode,mods,bind}] from the bridge
@property (nonatomic, assign) BOOL hotkeyStripVisible;
// Set once the login WKWebView has been shown this session. WebKit then stays permanently resident in the
// process and breaks the JVM's JIT-mirror brk #0x69 (it crashes at code-cache init), so the JVM must be
// launched in a fresh process. Gates onLaunch → a one-tap restart.
@property (nonatomic, assign) BOOL webKitUsedThisSession;
// Collapsible developer overlay: a small always-on-top toggle shows/hides a panel holding the JIT status,
// a live diagnostics readout, the dev actions (boot / test JIT / copy-clear-share log) and the log console,
// so the game stays full-screen. Gated behind Settings → Developer mode (or a triple-tap on the play cover).
@property (nonatomic, strong) UIView *debugPanel;
@property (nonatomic, strong) UIButton *debugToggle;
@property (nonatomic, strong) UILabel *diagLabel;        // live JVM/renderer/FPS/memory/session/build readout
@property (nonatomic, strong) UIStackView *devActionRow; // Test JIT / Copy log / Clear / Share, in a row
@property (nonatomic, strong) UIButton *debugClose;      // ✕ in the panel corner — the only way to dismiss it once open
@property (nonatomic, strong) UIStackView *devActionRow2; // Snapshot / Perf HUD / Test reconnect, in a row
@property (nonatomic, strong) UILabel *perfOverlay;       // compact always-on fps·mem·thermal chip over the game
@property (nonatomic, strong) UIButton *perfHudButton;    // dev-panel toggle for the perf overlay (label reflects state)
// Hidden capture field: becomes first responder to raise the soft keyboard; its change/return callbacks
// are translated into AWT KeyEvents. It never actually holds text (a zero-width sentinel keeps backspace
// firing, and every change returns NO).
@property (nonatomic, strong) UITextField *kbField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *jitTimer;
@property (nonatomic, strong) NSFileHandle *logFile;
@property (nonatomic, assign) unsigned long long logBytes; // written to logFile this launch
@property (nonatomic, assign) int jvmFd;   // raw fd for crash-proof libjvm stdout/stderr
@property (nonatomic, assign) BOOL launched;
@property (nonatomic, assign) long jitAttachedMs;     // Phase 4 cold start: first poll that saw CS_DEBUGGED (0 = not yet)
@property (nonatomic, assign) BOOL jitScriptlessLogged; // the "attached without runelite-jit.js" line went to the log once
@property (nonatomic, assign) BOOL jitWasTracing;       // the last poll saw a debugger attached (a new attach starts the script check)
@property (nonatomic, assign) BOOL inWorldStamped;    // Phase 4 cold start: the first LOGGED_IN tick has been stamped
@property (nonatomic, assign) BOOL awakeInGame;       // keep-awake: the last snapshot was logged in
@property (nonatomic, assign) CFTimeInterval awakeLeftGameAt; // keep-awake: when loggedIn last fell (CACurrentMediaTime)
@property (nonatomic, strong) RMPasteTarget *pasteTarget;     // the keyboard bar's Paste button target
@property (nonatomic, assign) BOOL pendingRouteCL1;           // GPU Route C L1 kill-test: nothing sets it any more (always NO)
@property (nonatomic, assign) BOOL pendingRouteCGpu;          // full RuneLite on GPU: the renderer picked in the plugins panel
@property (nonatomic, assign) BOOL pendingRouteCZone;         // full RuneLite on 117HD: the renderer picked in the plugins panel
@property (nonatomic, assign) BOOL pendingRouteCGpuNoResize;  // GPU Route C bisection: skip headless.resize (fixed 765x503)
@property (nonatomic, assign) BOOL pendingRouteCZoneDirect;   // GPU Zone: resizable + DIRECT present (CAEAGLLayer, no readback)

// #1 "Tap to Play" front screen: a polished Jagex-Mobile-style cover shown at cold start INSTEAD of the
// W1 debug panel (which now starts hidden behind the ≡ toggle). The big play button waits on the StikDebug
// attach (isDebuggerAttached / CS_DEBUGGED) — the per-launch attach is immovable, so the screen only
// polishes the post-attach moment. Tap → onLaunch → dismiss. A login row reflects the saved session.
@property (nonatomic, strong) UIView *launchScreen;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UILabel *playStatusLabel;
@property (nonatomic, strong) UIButton *playLoginButton;

// W3 native shell: keep the process alive + show frames. The JVM ran fine on device but iOS
// jetsam'd the (idle-UI) process within ~250 ms — before the engine drew its first frame. Two
// protections: (1) a UIBackgroundTask assertion so the OS treats the JVM run as important work and
// won't suspend/kill it; (2) an ACTIVE CADisplayLink render loop that polls the capture dir and
// blits the newest frame-*.png to an on-screen image view — keeping the app in the foreground
// "actively rendering" jetsam band AND showing the live login screen (the start of the real UI).
@property (nonatomic, strong) UIImageView *screen;
@property (nonatomic, strong) PluginPanelsViewController *panelDock; // persistent always-on panel dock
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, copy)   NSString *lastFrameName;
@property (nonatomic, assign) int framesShown;
// Native mobile right-click menu: a long-press opens the engine menu (right-click), then once that menu is
// reflected in the MenuPeekBridge snapshot we build a big-row native OSRS-styled overlay over it and the
// user taps a row to pick (click-through to the engine row). menuOpen guards camera-pan while it's up.
@property (nonatomic, assign) BOOL menuOpen;
@property (nonatomic, assign) int  lastMenuX;
@property (nonatomic, assign) int  lastMenuY;
@property (nonatomic, assign) BOOL menuBuilding;          // right-clicked; polling for the engine menu snapshot
@property (nonatomic, assign) BOOL menuTouchActive;       // the long-press finger is still down (drag in progress)
@property (nonatomic, assign) NSTimeInterval menuOpenAt;  // when the right-click fired (build timeout)
@property (nonatomic, assign) BOOL menuClosing;           // committed/cancelled; native cover held up until the
                                                          // engine menu actually closes (else it peeks for a frame)
@property (nonatomic, assign) NSTimeInterval menuClosingAt; // when the close click fired (teardown timeout)
@property (nonatomic, strong) UIView *menuContainer;      // the native OSRS-styled menu box
@property (nonatomic, strong) NSMutableArray<UIView *> *menuRows; // the row views (index 0 = top = default)
@property (nonatomic, strong) NSArray *menuRowEntries;    // the entry dicts, for re-rendering a row on hover
@property (nonatomic, assign) int  menuHighlight;         // currently locked-on display row (-1 = none/header)
@property (nonatomic, assign) CGFloat menuHapticY;        // last finger Y a snap-haptic fired at (per-row tick)
@property (nonatomic, assign) CGPoint menuAnchor;         // press point in self.view coords (menu origin)
@property (nonatomic, assign) BOOL menuHandRight;         // pressed on the right half -> open the menu leftward
@property (nonatomic, assign) BOOL   menuGeomValid;       // engine menu rect (below) is live this drag
@property (nonatomic, assign) CGRect menuGeomGame;        // live engine menu bounds, gamepack (765x503) coords
@property (nonatomic, assign) int    menuSelX;            // where commit clicks on release (game coords)
@property (nonatomic, assign) int    menuSelY;
@property (nonatomic, assign) BOOL menuFingerOnMenu; // finger over the menu (with grace) -> select; else cancel
// MENU-1/2/3 tap-mode: when the right-click menu has a submenu (▸), overflows the safe area, or shift is
// latched, it becomes a PERSISTENT, tappable, scrollable list (drill into submenus, ⚙ Customize) instead of the
// drag-select box. Flat short menus keep the unchanged drag-select path, so the core tap/menu flow is untouched.
@property (nonatomic, assign) BOOL menuTapMode;          // this menu is the persistent tap-driven list
@property (nonatomic, assign) int  menuDrillParent;      // showing the submenu of this top-level display index (-1 = top)
@property (nonatomic, strong) NSArray *menuTopEntries;   // the top-level entries (kept so "‹ Back" can rebuild)
@property (nonatomic, strong) UIScrollView *menuScroll;  // tap-mode row container (scrolls when the list overflows)
@property (nonatomic, strong) UIView *menuDismissLayer;  // tap-mode full-screen tap-to-cancel layer behind the box
@property (nonatomic, assign) BOOL menuScrollable;       // engine menu self-scrolls (>~30 entries) -> commit by invoke, not geometry
@property (nonatomic, assign) BOOL customizeReopenPending; // a ⚙ Customize reopen is scheduled; a new menu cancels it
@property (nonatomic, assign) BOOL customizeAutoShift;     // Customize latched Shift itself; release it when the menu closes
// DRAG-1: a one-finger drag that BEGAN over the inventory grid rearranges items (synthesized engine mouse-drag)
// instead of rotating the camera. Only set when the drag starts inside the published inventory rect.
@property (nonatomic, assign) BOOL itemDragging;
@property (nonatomic, assign) BOOL paneSwiping; // a quick swipe from the inventory or a reorder pane: ignored
// Tracks the engine "dialogue open" state so the native chat veneer hides while a dialogue shows (logged once per transition).
@property (nonatomic, assign) BOOL chatDialogueActive;
// Canvas-px bounds of the open dialogue (from the snapshot); a tap inside it routes through the precise click so
// the engine resolves the dialogue's Continue/option instead of walking the world behind the (now natural-bottom) box.
@property (nonatomic, assign) CGRect dialogueChatCanvas;
@property (nonatomic, assign) int  itemDragLastX;   // last valid canvas point of the drag — the engine MUST get a
@property (nonatomic, assign) int  itemDragLastY;   // MOUSE_RELEASED to close WidgetDrag even if the lift maps off-canvas
// Interactable-tap feedback: a light haptic when a tap grabs a real interactable (polled via JavaBridge
// interactTapSeq), and a yellow fading click-ring drawn at every tap point (the Jagex-Mobile click marker).
@property (nonatomic, assign) int lastInteractTapSeq;
@property (nonatomic, strong) UIImpactFeedbackGenerator *tapHaptic; // shared by every trigger; see -hapticGenerator
@property (nonatomic, assign) NSInteger tapHapticStrength;          // the strength tapHaptic was built for
// The ring is drawn when the finger LANDS (onSceneTouchDown:) in the walk colour; the tap's resolved colour
// only arrives a beat after the click, so this state is what lets that late answer reach a ring already on
// screen: RED if it resolved to an interactable (the engine bumped interactTapSeq), left as drawn for a plain
// walk (no bump within the grace window).
@property (nonatomic, assign) BOOL pendingClick;
@property (nonatomic, assign) CGPoint pendingClickPoint;
@property (nonatomic, assign) NSTimeInterval pendingClickAt;
// The ring of the tap that is waiting for its kind, or nil when none is (it expired, or this tap's ring has
// already had the answer applied). The answer is 80-160 ms out and spam-tapping is how this game is played,
// so a second tap inside that window replaces it and the ring it replaced just finishes its fade.
@property (nonatomic, strong) CAShapeLayer *pendingRing;
@property (nonatomic, assign) int emX;                    // live engine-menu geometry (for click-through)
@property (nonatomic, assign) int emY;
@property (nonatomic, assign) int emW;
@property (nonatomic, assign) int emCount;
// Pinch-zoom: accumulate the scale change into whole wheel notches.
@property (nonatomic, assign) CGFloat pinchPrevScale;
@property (nonatomic, assign) CGFloat wheelAccum;
// Contextual keyboard: previous gamepack text-input state, for edge-triggered auto raise/dismiss.
@property (nonatomic, assign) BOOL prevInputOpen;
// W3 hybrid-chrome native tab rails (cover-in-place first pass): 14 opaque native buttons drawn over the live
// desktop tab stones (positions/active state from the MobileChromeBridge snapshot each tick); a tap proxies an
// onClick onto the stone centre. A ▦ toggle shows/hides them for instant A/B fallback.
@property (nonatomic, strong) NSMutableArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIView *tabRailBg;   // opaque rail behind the edge-split icon grid
// The 7th inner stone, which collapses the grid to its inner column and back (601's expand stone, script 7615).
// The choice is kept across launches.
@property (nonatomic, strong) TabGridButton *tabExpandButton;
@property (nonatomic, assign) BOOL tabGridCollapsed;
// The frame behind the grid (SIDE_RIGHT_TABS_BACKGROUND), and its art at each width, drawn at canvas px.
@property (nonatomic, strong) UIImageView *tabFrameView;
@property (nonatomic, strong) UIImage *tabFrameImg;
@property (nonatomic, strong) UIImage *tabFrameImgCollapsed;
@property (nonatomic, assign) CGFloat loggedTabGridTop; // last grid top logged by tabGridTopForHeight (log on change)

// W3 Feature-A (A3): chat-at-top = the engine's OWN chatbox relocated to the top + flipped transparent
// (ChatRelocateProbe proved it renders there, not occluded). Tabs/scrollback/colors/input stay live since it IS
// the real chat — no native reproduction needed.
@property (nonatomic, assign) BOOL engineChatRelocated;   // one-shot: asked the engine to relocate the HUD (A4)
@property (nonatomic, assign) CGFloat hudRightLaid;       // the hudRightInset that relocate used (TAB-1)
@property (nonatomic, assign) BOOL zoomSynced;            // syncOrientationZoom has run for this orientation
// Edge-to-edge (A1+A4): the scene fills the whole screen; the engine HUD (chat/minimap/orbs) is relocated INTO
// the safe area so nothing clips under the island/corners/home-indicator. renderW/H = the canvas the engine
// draws (set at launch); chatHitCanvas = the relocated chat tab-row rect in canvas px (onTap treats it as UI).
@property (nonatomic, assign) int renderW;
@property (nonatomic, assign) int renderH;
// The canvas rows on screen: renderH, less the hidden strip under them on a large-portrait canvas (kStripCanvasH).
@property (nonatomic, assign) int visibleH;
// The window band last sent with setEngineHudStrip, so it is sent again only when it moves.
@property (nonatomic, assign) BOOL stripSent;
@property (nonatomic, assign) int stripBandTop, stripBandBottom;
// Auto-rotate: the window changed size, so resizeCanvasToScreen runs each tick until its request lands.
@property (nonatomic, assign) BOOL canvasCheckDue;
// The canvas asked for, adopted once the game draws at it (adoptCanvasIfDrawn), or at canvasDeadline.
@property (nonatomic, assign) BOOL canvasPending;
@property (nonatomic, assign) int pendingW, pendingH, pendingVisibleH;
@property (nonatomic, assign) CFTimeInterval canvasDeadline;

// GPU Route C direct present: a CAEAGLLayer (EAGL) / CAMetalLayer (ANGLE) the engine renders straight into (no
// readback). nil in CPU/L1 mode. Kept strong so the layer outlives the EGL/EAGL surface that references it.
@property (nonatomic, strong) CAEAGLLayer *glLayer;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, assign) BOOL gpuPresent;        // direct-present active (skip the CPU-frame blit)
@property (nonatomic, assign) BOOL gpuPresentArmed;   // ANGLE: window surface ready; flip gpuPresent on first GPU frame
// 117HD crash cookie (the Android auto-GPU fallback, ported): a marker FILE armed once a 117HD boot is
// actually running (first engine frame published — NOT at Play-tap, so a force-quit while waiting for the
// JIT attach never counts) and cleared the moment the GL bridge presents its FIRST frame (survival proof:
// GL context + shader compile lived). Deliberately NOT gated on sceneWarmedUp — quitting at the login
// screen must not read as a renderer death. A cookie still on disk at the next Play tap = the last 117HD
// boot died before presenting -> demote the saved pref to the software renderer and say so.
@property (nonatomic, assign) BOOL hdBootCookieArmed;   // this session wrote the marker (awaiting first present)
@property (nonatomic, assign) BOOL hdBootCookieSettled; // this session already cleared it — don't re-arm
@property (nonatomic, assign) BOOL appBackgrounded;     // away: the cookie must not re-arm until we return
@property (nonatomic, assign) CGRect chatHitCanvas;
// Pre-composited tab images (stone background + centred icon) built once from the bundled OSRS sprite assets
// (stone-inactive/active + icon-0..13). Index = tab index; active/inactive variants. Authentic, crisp, no
// crop fragility.
@property (nonatomic, strong) NSMutableArray<UIImage *> *tabImgInactive;
@property (nonatomic, strong) NSMutableArray<UIImage *> *tabImgActive;
@property (nonatomic, strong) UIImage *tabImgShowLess; // the expand stone while both columns show
@property (nonatomic, strong) UIImage *tabImgShowMore; // and while the grid is collapsed
@property (nonatomic, strong) UIImage *doorImg;        // the logout door by the chat
@property (nonatomic, strong) UIImage *doorImgActive;  // the door while the logout tab is open
// The rest of the column under the door: the speech bubbles (on the lighter stone while the chat shows, on the
// door's stone while it is put away, flashing red while a message waits) and the keyboard.
@property (nonatomic, strong) TabGridButton *chatToggleButton;
@property (nonatomic, strong) TabGridButton *chatKeyboardButton;
@property (nonatomic, strong) UIImage *chatToggleOpenImg;
@property (nonatomic, strong) UIImage *chatToggleClosedImg;
@property (nonatomic, strong) UIImage *chatToggleFlashImg;
@property (nonatomic, strong) UIImage *chatKeyboardImg;
// The native chrome sprites (stones/icons/chat buttons) are rendered from the LIVE OSRS cache at runtime — like
// desktop RuneLite, which never ships interface art — NOT from bundled PNGs. The engine publishes them a few ticks
// post-login (JVMLauncher.tabSprites); we recomposite the grid + chat row, persist for instant boot, then stop
// polling once a COMPLETE set arrives. YES once captured this session.
@property (nonatomic, assign) BOOL tabSpritesComplete;
// Opaque covers over the desktop tab stones (the bottom double-UI). The stones stay clickable underneath (the
// proxy click reaches them), the cover just hides them — hiding the widget would kill the proxy target.
@property (nonatomic, strong) NSMutableArray<UIView *> *stoneCovers;
@property (nonatomic, strong) UIButton *chromeToggle;
@property (nonatomic, assign) BOOL chromeVisible;

// W3 A3: bare tap targets over the engine's 7 filter stones (All/Game/Public/Private/Channel/Clan/Trade), which
// the engine draws itself in the official layout. A tap switches the channel by replaying the stone's op-script;
// a long-press on a filterable one opens its filter menu. State comes from JVMLauncher.chatSnapshot each tick.
@property (nonatomic, strong) NSMutableArray<UIButton *> *chatTabButtons;
@property (nonatomic, strong) UILongPressGestureRecognizer *sceneLongPress; // the game view's hold -> menu
@property (nonatomic, assign) BOOL chatTabsBuilt;
// Finger-scroll the chat: a 1-finger drag that BEGINS inside the chat box scrolls the messages (via synthesized
// mouse-wheel notches to the engine) instead of rotating the camera — only while the chat is open (logged in +
// supported layout). chatScrollCanvas = the chat box rect in engine-canvas px; chatScrollable gates it.
@property (nonatomic, assign) CGRect chatScrollCanvas;
@property (nonatomic, assign) BOOL chatScrollable;
@property (nonatomic, assign) BOOL chatScrolling;       // the current pan gesture is scrolling the chat
@property (nonatomic, assign) CGFloat chatScrollAccum;  // accumulated drag (pt) toward the next wheel notch
// SCROLL-SPIKE: a 1-finger drag that BEGINS over an open, scrollable engine interface (bank / GE / quest list /
// settings / collection log …) scrolls THAT interface — wheel notches the engine routes to the hovered scrollable,
// exactly like the desktop mouse wheel — instead of rotating the camera. Gated by JavaBridge.isEngineScrollableAt
// (hit-tested in the engine) so a drag over the bare viewport still rotates (no wheel-to-camera-zoom leak).
@property (nonatomic, assign) BOOL ifaceScrolling;      // the current pan gesture scrolls an engine interface
@property (nonatomic, assign) CGPoint ifaceWheelPt;     // canvas px the wheel is parked over (the interface)
@property (nonatomic, assign) CGFloat ifaceScrollAcc;   // accumulated drag (pt) toward the next wheel notch
// World map (touch — WORLDMAP-MOBILE-PLAN.md Phase 1): while the fullscreen engine world map is open, a
// 1-finger drag pans the MAP (bridge panWorldMap, "grab the map"), taps are precise UI clicks with no
// walk-ring semantics, a tap in the search rect raises the keyboard (the map search doesn't flip INPUT_TYPE),
// the native chrome hides, and a native ✕ in the safe area proxies the bezel-clipped engine close button.
@property (nonatomic, assign) BOOL mapOpen;             // polled from the bridge map snapshot (~10 Hz)
@property (nonatomic, assign) BOOL mapWasSearching;     // FIX-14: engine WORLDMAP_SEARCHING edge (dismiss kbd on commit)
@property (nonatomic, assign) CGRect mapCloseCanvas;    // engine CLOSE rect (canvas px; zero = unknown)
@property (nonatomic, strong) UIButton *closeMapButton; // ✕ native world-map close, shown only while mapOpen (proxies the engine CLOSE rect)
@property (nonatomic, assign) CGRect mapSearchCanvas;   // engine SEARCH rect (canvas px)
@property (nonatomic, assign) CGRect mapWindowCanvas;   // the whole map window rect (canvas px)
@property (nonatomic, assign) CGRect mapKeyCanvas;      // the Key list rect — swipe there scrolls the list
@property (nonatomic, assign) CGRect mapListCanvas;     // the surface dropdown list rect (zero when closed)
@property (nonatomic, strong) NSArray<UIView *> *mapBands; // black bands above/below the scaled map window
@property (nonatomic, assign) BOOL mapListScrolling;    // the current pan gesture scrolls a map list (wheel)
@property (nonatomic, assign) CGPoint mapListWheelPt;   // game point the scroll wheel is parked over
@property (nonatomic, assign) CGFloat mapListScrollAcc; // accumulated drag pt toward the next wheel notch
@property (nonatomic, assign) BOOL mapPanning;          // the current pan gesture is panning the map
@property (nonatomic, assign) CGFloat mapPanAccX;       // sub-px accumulators (screen pt -> whole canvas px)
@property (nonatomic, assign) CGFloat mapPanAccY;
@property (nonatomic, assign) CGFloat cameraDragAccX; // sub-px accumulators (screen pt -> whole canvas px) for the 1-finger camera-rotate drag
@property (nonatomic, assign) CGFloat cameraDragAccY;
// Instant selected-highlight after a tap: the engine's tab GRAPHIC sprite (which the snapshot reads for the
// selected state) only updates on a redraw, so the highlight lagged until the next game interaction. Optimistically
// mark the tapped tab selected and hold it until the snapshot agrees (or a short timeout). -1 = none.
@property (nonatomic, assign) NSInteger optimisticChatTab;
@property (nonatomic, assign) CFTimeInterval optimisticChatAt;
// Chat collapse (mobile): the currently-active channel (-1 = unknown), and whether the chat message area is
// collapsed. Tapping the already-active tab toggles collapse; the channel stays selected either way.
@property (nonatomic, assign) NSInteger chatActiveTab;
@property (nonatomic, assign) BOOL chatCollapsed;
@property (nonatomic, assign) BOOL savedCollapsedForDialogue;   // we forced chat open for a dialogue -> restore after
// The speech bubbles put the whole chat away, filter row included (the official app's "Toggle Chatbox"); a dialogue
// brings it back for its duration, like a collapse. chatHasUnread = a filter stone shows new messages (the bubbles
// flash while the chat is away). chatColumnShown = the column is up, so its keyboard stands in for kbFab.
@property (nonatomic, assign) BOOL chatPutAway;
@property (nonatomic, assign) BOOL savedPutAwayForDialogue;
@property (nonatomic, assign) BOOL chatHasUnread;
@property (nonatomic, assign) BOOL chatColumnShown;
@property (nonatomic, strong) UITextView *chatMessagesView;  // native-rendered chat MESSAGE lines (engine can't raster relocated chat)
// Native dialogue: an OPAQUE parchment drawn over the whole chatbox region while a dialogue is open (occluding the
// engine's transparent dialogue + the chat tabs/messages), with a CUTOUT where the engine's real 3D head renders.
@property (nonatomic, strong) UIView *dialogueView;          // the parchment box (masked with a head cutout)
@property (nonatomic, strong) UIView *dialogueContentView;   // the text area (inset to clear the head column)
@property (nonatomic, strong) UIStackView *dialogueStack;    // name / text / continue, or option rows
@property (nonatomic, copy)   NSString *lastDialogueJson;    // rebuild the stack only when the content changes
@property (nonatomic, assign) CGPoint dialogueContinuePoint; // engine CONTINUE widget centre (canvas px), or (-1,-1)
@property (nonatomic, assign) BOOL dialogueIsOptions;        // the open dialogue is a "Select an Option" menu
@property (nonatomic, assign) BOOL dialogueIsPrompt;         // ... and it is a message-layer prompt (GE search)
@property (nonatomic, assign) CGRect dialoguePromptList;     // its results window, canvas px, while it scrolls
@property (nonatomic, assign) BOOL dialogueTargetsKnown;     // the bridge models this dialogue's clickables
@property (nonatomic, assign) long long dialogueTargetsSeq;  // the dialogue publish those clickables came from
@property (nonatomic, assign) long long dialogueViewSeq;     // the publish the PARCHMENT's rows were built from
@property (nonatomic, copy) NSString *lastTargetsJson;       // dialogue publish we last logged (log on change only)
@property (nonatomic, strong) NSArray<NSValue *> *dialogueOptionRects;   // per-option engine canvas bounds
@property (nonatomic, strong) NSArray<NSNumber *> *dialogueOptionDigits; // the matching option numbers
@property (nonatomic, assign) int chatLinesSeq;              // last rendered getChatLines seq (skip re-parse when unchanged)
@property (nonatomic, assign) int chatBaseX;                 // safe-area-anchored chat origin (canvas px), before the user offset
@property (nonatomic, assign) int chatBaseY;
@property (nonatomic, assign) int chatUserDX;               // persisted chat position offset from the base anchor (canvas px)
@property (nonatomic, assign) int chatUserDY;
@property (nonatomic, assign) int minimapBaseX; // safe-area-anchored minimap cluster origin (canvas px), before the user offset
@property (nonatomic, assign) int minimapBaseY;
@property (nonatomic, assign) int minimapUserDX; // persisted minimap offset from the base anchor (canvas px)
@property (nonatomic, assign) int minimapUserDY;
@property (nonatomic, assign) CGSize minimapCanvasSize; // the cluster's size from the chrome snapshot; zero until reported
// Phase-6 native plugin panel: a ⚙ button opens a full-screen modal sheet (scrim eats all touches so nothing
// falls through to the game) listing the plugins (MobileUiBridge.listPlugins) with an enable/disable switch
// and a running/stopped indicator. Refreshed when the bridge's event sequence advances (toggles, conflicts).
@property (nonatomic, strong) UIButton *pluginButton;
@property (nonatomic, strong) UIButton *overlaysCardButton;   // plugin card: enters overlay edit-mode
@property (nonatomic, strong) OverlayEditView *overlayEdit;   // active overlay edit-mode view (OVL-2/3/5)
@property (nonatomic, strong) NSData *sentKeepOut;            // the controls last sent to the engine (updateOverlayKeepOut)
// FIX-9 (iOS parity with Android ReconnectingOverlayView): a native "Reconnecting…" scrim shown over the live
// frame while the headless auto-reconnect recovers an in-session drop, driven off the chrome snapshot's
// "reconnecting" flag (HeadlessLogin.isReconnecting -> MobileChromeBridge). reconnectShown = last-applied state.
@property (nonatomic, strong) UIView *reconnectScrim;
@property (nonatomic, strong) UIActivityIndicatorView *reconnectSpinner;
@property (nonatomic, assign) BOOL reconnectShown;
// Boot-progress overlay (iOS parity with Android's SplashOverlayView): a "Starting up…" spinner card shown
// from the Play tap until the first engine frame paints, covering the JVM-boot gap. Dismissed on the tick
// renderedFrameWidth first reads > 0, a fatal-error card taking over, or a 60s failsafe (matches SPLASH_TIMEOUT_MS).
@property (nonatomic, strong) UIView *bootStatusScrim;
@property (nonatomic, strong) UIActivityIndicatorView *bootStatusSpinner;
@property (nonatomic, assign) CFTimeInterval bootStatusDeadline;
// PARITY-P0-3 (iOS parity with Android's HoppingOverlayView + MainActivity.armHopScrim): a native "Switching
// worlds…" scrim shown over the live frame during a world hop. Unlike the reconnect scrim it is NOT keyed off a
// bridge flag — WorldSwitcherBridge.hop() drives a logout→LOGIN_SCREEN→relogin sequence during which
// HeadlessLogin.isReconnecting() stays false, so there is no signal to poll. Instead it is armed client-side at
// the hop-trigger sites (the World Switcher's ◀/▶ and row taps, via the RMWorldHopArmed notification) and cleared
// on the next loggedIn edge after the hop or a bounded 12 s timeout (matching Android's HOP_TIMEOUT_MS).
@property (nonatomic, strong) UIView *hoppingScrim;
@property (nonatomic, strong) UIActivityIndicatorView *hoppingSpinner;
@property (nonatomic, strong) UILabel *hoppingLabel;
@property (nonatomic, assign) BOOL hoppingShown;
@property (nonatomic, assign) BOOL hopArmed;
@property (nonatomic, assign) BOOL hopSawLoggedOut;
@property (nonatomic, assign) CFAbsoluteTime hopDeadlineAt;
// UX-LOGIN-01 (iOS parity with Android's SessionExpiredOverlayView): a full-screen INTERACTIVE "Session
// expired" card shown when the headless login machine has GIVEN UP (autologin/reconnect exhausted — the
// snapshot's "sessionExpired" flag). Unlike the self-recovering reconnect scrim above, this is a hard stop:
// the engine is parked on the raw desktop login screen with no automated recovery, so the card consumes
// touches and offers a single "Sign in again" that re-runs the on-device Jagex login. The bridge orders the
// flags (an active reconnect wins; sessionExpired only on give-up) so the two overlays are never both shown.
@property (nonatomic, strong) UIView *sessionExpiredScrim;
@property (nonatomic, assign) BOOL sessionExpiredShown;
// FATAL-1: a native card for engine-fatal stops (the snapshot's "fatalError"/"fatalCode", noted from
// RSAppletStub.onError via the bridge). Desktop RuneLite shows a Swing FatalErrorDialog these headless
// boots can't render — without this, every weekly OSRS update ends in a silent black screen (stale client
// rev -> error_game_js5connect). Terminal state: the card stays up (the applet is dead, nothing recovers);
// the single button quits the app so the user can relaunch (and, for js5connect, install the rebuilt app).
@property (nonatomic, strong) UIView *fatalErrorScrim;
@property (nonatomic, strong) UILabel *fatalErrorTitle;
@property (nonatomic, strong) UILabel *fatalErrorBody;
@property (nonatomic, assign) BOOL fatalErrorShown;
@property (nonatomic, assign) BOOL layoutNoticeShown; // UX-ONBOARD-02: launch layout hint, once per process
@property (nonatomic, assign) BOOL jitStartupChecked; // the last launch's JIT-startup record was read (once per process)
// One-tap layout switch (updateLayoutSwitch): the pill, the start of the current run of unsupported-layout frames
// (0 = supported or logged out) and the outstanding switch (0 = none), both CACurrentMediaTime.
@property (nonatomic, strong) UIButton *layoutSwitchButton;
@property (nonatomic, assign) CFTimeInterval layoutUnsupportedSince;
@property (nonatomic, assign) CFTimeInterval layoutSwitchSentAt;
// PERF-MEMORY-THERMAL-01: ease off when the phone gets hot or Low Power Mode is on. heatTick looks at the phone every
// second or two from onDisplayTick, and every 5 s from the background pump, because the display link stops there.
// RMHeatPolicy picks the limits: a frame rate on every renderer, which is held in memory on the Java side and so has
// nothing to undo, and on 117HD a lower sceneResolutionScale, never above the player's own baseline, restored once the
// phone cools by RMHeatScaleKeeper. Polled (main thread, which the mobile* bridge selectors require) rather than driven by the thermal
// notification: the tick gives the scale's two correctness guards their retry loop for free: the baseline is captured
// ONLY from a real live sceneResolutionScale (config not readable yet -> defer, never guess), and a leaked
// NSUserDefaults marker from a session killed mid-throttle is restored before arming (the bridge write PERSISTS config,
// so a throttle must never become the next session's "baseline").
@property (nonatomic, strong) RMHeatPolicy *heatPolicy;
@property (nonatomic, strong) RMHeatScaleKeeper *heatScaleKeeper;
@property (nonatomic, assign) int heatFpsLimit;         // the frame-rate limit the game last accepted, 0 for none
@property (nonatomic, assign) long heatEngineFrames;    // the engine's frame counter at the last reading
@property (nonatomic, assign) long heatPresentedFrames; // the direct present's, likewise
@property (nonatomic, assign) long long heatGameCpuNanos; // the game thread's CPU, likewise
@property (nonatomic, assign) long heatGpuWaitNanos;      // its time waiting for the GPU, likewise
@property (nonatomic, assign) double heatAppCpuSeconds;   // the whole app's CPU, likewise
// The hot-phone notice (offerHeatNotice): offers Lower resolution when hot, at most once a launch, between fights.
@property (nonatomic, strong) RMHeatNoticeView *heatNotice;       // nil unless it's up
@property (nonatomic, assign) BOOL heatNoticeOffered;             // it has been up this launch
@property (nonatomic, assign) CFTimeInterval heatNoticeCalmSince; // logged in and out of combat since, 0 = not now
@property (nonatomic, assign) CFTimeInterval heatNoticeShownAt;
@property (nonatomic, assign) BOOL newInstallQueued;      // this launch has queued a new install's settings
@property (nonatomic, assign) long long newInstallSaveId; // the save behind them, 0 until it's queued
@property (nonatomic, strong) UIView *pluginPanel;
@property (nonatomic, strong) UITableView *pluginTable;
@property (nonatomic, strong) NSArray<NSDictionary *> *pluginList;  // the FILTERED view the table renders
@property (nonatomic, strong) NSArray<NSDictionary *> *pluginAll;   // the full sorted list (search filters this)
@property (nonatomic, strong) UISearchBar *pluginSearch;           // CFG-5 plugin-list search
@property (nonatomic, strong) UIView *accountBar;                  // RuneLite-account login/status row (config sync)
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, strong) NSLayoutConstraint *accountBarHeight;
// PARITY-P0-4: the in-game Jagex-session row (always present once launched — play can't start without tokens.json,
// unlike the collapsible RuneLite-account row above). Its "Log out" ends the session like Android's in-game logout.
@property (nonatomic, strong) UIView *jagexSessionBar;
@property (nonatomic, strong) UILabel *jagexSessionLabel;
@property (nonatomic, strong) UIButton *jagexLogoutButton;
@property (nonatomic, strong) NSTimer *accountTimer;
@property (nonatomic, copy) NSString *pluginFilter;                // current lowercase search text
@property (nonatomic, assign) long long pluginSeq;     // last MobileUiBridge event seq the panel has seen
@property (nonatomic, assign) BOOL pluginPanelOpen;
// className -> CFAbsoluteTime when we first saw it enabled-but-not-active, so a plugin that never reaches
// running (e.g. a native-lib/GPU plugin whose macOS .dylib can't load on iOS) flips from "enabling…" to
// "couldn't start" after a grace period instead of spinning forever.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pluginEnabledSince;
// Picture-in-Picture + background keepalive: the game keeps playing after a swipe-home. pipLayer is an
// AVSampleBufferDisplayLayer fed the SAME engine frames as the on-screen blit, and the visible presenter above it
// (see setupPictureInPicture); the system lifts it into the PiP window when the app backgrounds
// (canStartPictureInPictureAutomaticallyFromInline). A silent, mixable AVAudioEngine holds the `audio`
// background mode so the process — JVM, render loop, game socket — keeps running even with PiP dismissed;
// the in-game logout timer (RuneLite, up to 30 min) then decides how long the character stays in.
@property (nonatomic, strong) AVSampleBufferDisplayLayer *pipLayer;
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) dispatch_source_t pipBgPump;   // 15 Hz frame pump while backgrounded (the
                                                             // CADisplayLink stops firing there)
@property (nonatomic, strong) UIButton *pipButton;           // 📺 manual PiP start/stop (also the diagnostic
                                                             // for the auto-start gate)
@property (nonatomic, strong) AVAudioEngine *keepaliveEngine;   // renders silence; holds the audio session
@property (nonatomic, strong) AVAudioSourceNode *keepaliveSource;
// Set when the KEEPALIVE-1 idle gate stops the keepalive ON PURPOSE. Every recovery path below
// checks it first: re-arming here would fight a deliberate battery decision and keep the JVM
// running at full rate for a logged-out game nobody is looking at.
@property (nonatomic, assign) BOOL keepaliveIdleReleased;
@property (nonatomic, strong) NSTimer *keepaliveWatchdog;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgKeepTask; // per-background grace assertion
// KEEPALIVE-1: the background idle gate. The keepalive otherwise runs the JVM at full rate forever — including
// after an AFK-logout renders the login screen to nobody. Track how long the game has been continuously
// logged OUT while backgrounded; past the threshold, stop the pump + audio so iOS can suspend the JVM.
@property (nonatomic, assign) NSUInteger bgPumpTicks;          // pump ticks since backgrounding (15 Hz)
@property (nonatomic, assign) CFAbsoluteTime bgLoggedOutSince; // 0 = logged in (or not yet sampled)
@end

// Grace period before an enabled-but-not-active plugin is reported as failed to start.
static const NSTimeInterval kPluginStartGrace = 4.0;

// KVO context for the PiP controller's possible/active flags (diagnostics for the auto-engage gate).
static void * const kPipKvoContext = (void *)&kPipKvoContext;

// Chat veneer master switch. YES = the native chat veneer is ON: the engine chatbox is relocated to the top, with a
// STATIC row of 7 enlarged channel tabs (each tap-to-switch; long-press a filterable channel for its filter menu),
// native-rendered message lines below them, and the native opaque dialogue. NO = the engine renders its ORIGINAL
// bottom chatbox + tab row itself. (The veneer code stays in place behind this flag; flip to NO to disable it.)
static const BOOL kChatVeneerEnabled = YES;

// AWT virtual keycodes for the non-text keys we synthesize (java.awt.event.KeyEvent.VK_*).
static const int AWT_VK_BACK_SPACE = 8;
static const int AWT_VK_ENTER      = 10;
static const int AWT_VK_TAB = 9;
static const int AWT_VK_ESCAPE = 27;
static const int AWT_VK_SPACE = 32;
static const int AWT_VK_LEFT = 37;
static const int AWT_VK_UP = 38;
static const int AWT_VK_RIGHT = 39;
static const int AWT_VK_DOWN = 40;
static const int AWT_VK_0 = 48; // '0'..'9' == 48..57; F1..F12 == 112..123
static const int kTapKindWidget = 3; // JavaBridge.TAP_KIND_WIDGET — suppress the shell's red ring on these taps
// Zero-width sentinel so a backspace on an "empty" field still fires shouldChangeCharactersInRange.
static NSString * const kKbSentinel = @"​";

// W3 A3/A4: the relocated engine chat is laid out as the official mobile app lays it (HudVeneerBridge
// .layOfficialChat): kChatW wide right of the column, its filter row the top kChatTabRowCanvasH px. Its canvas origin
// moves with the safe-area relocate (self.chatHitCanvas, set in updateHudLayout); these are the fixed engine-px
// dimensions used to treat filter-row taps as UI (precise click, no walk ring).
static const int kChatW = 461;

// Whether the canvas the game draws is portrait: set at launch, then by each resize the shell adopts (auto-rotate).
static BOOL sCanvasPortrait = NO;

// The chat's and the minimap's dragged offsets (overlay edit), kept apart for each orientation (Settings > Game
// settings > Screen): an offset dragged on the wide landscape canvas can land the minimap on the chat in portrait.
static NSString *hudOffsetKey(NSString *key) {
    return sCanvasPortrait ? [key stringByAppendingString:@".portrait"] : key;
}
// The minimap+orbs cluster width (fixed engine px, from the de-risk), until the chrome snapshot reports its size.
static const int kMinimapClusterW = 211;

// TAB-1: canvas sizing past a phone (applied where the launch picks renderW x renderH). A screen at least
// kLargeScreenPt on its short side (an iPad) keeps the canvas pixels per point of the phone the HUD was tuned on, the
// iPhone 17 Pro Max at kPhoneShortPt tall in landscape. No canvas is narrower than kMinCanvasW, the narrowest layout
// the game is built for. The Android twins are LARGE_SCREEN_DP, PHONE_SHORT_DP and MIN_CANVAS_W in MainActivity.
static const CGFloat kLargeScreenPt = 600.0;
static const CGFloat kPhoneShortPt = 440.0;
static const int kMinCanvasW = 765;
// Large portrait (a phone in portrait): the canvas is kStripCanvasW wide, so the world, the inventory, the tab group
// and the windows show 1.28x bigger, and kStripCanvasH rows under the screen hold the chat and minimap at full size
// (HudVeneerBridge.setHudStrip), copied back over the world at kStripCanvasW/kMinCanvasW scale. sHudScale is that
// scale while the strip is on, else 1: the chat's and minimap's engine-px sizes below are multiplied by it on screen.
// The Android twins are STRIP_CANVAS_W and STRIP_CANVAS_H in MainActivity.
static const int kStripCanvasW = 600;
static const int kStripCanvasH = 400; // HudStrip.STRIP_H
static CGFloat sHudScale = 1.0;
static int hudPx(int enginePx) {
    return (int)lround(enginePx * sHudScale);
}
// A canvas the engine draws: w x h px, of which the top visibleH rows reach the screen (fewer than h only on a
// large-portrait canvas, whose strip runs on below the screen).
typedef struct {
    int w, h, visibleH;
} RMCanvas;

// W3 A3 (the chat's filter row, matching the official OSRS-mobile app): the ENGINE draws the 7 filter stones (no
// Report: the official app doesn't show it in the row), with each channel's name and live filter state, at the
// official app's geometry (HudVeneerBridge.OFFICIAL_*). The shell lays a bare tap target over each stone: kChatTabX
// in, kChatTabPitch apart, kChatTabW x kChatTabH, kChatTabY down.
// CHAT-3 (deliberate): the Report channel is intentionally omitted from this row to match the official mobile app
// — it is NOT a lost capability: reporting a player is reached the way mobile does it, via the player's
// right-click (long-press) menu "Report" entry, which surfaces through the native menu like any other entry.
static const int kChatTabCount = 7;
static const int kChatTabX = 7;
static const int kChatTabPitch = 65;
static const int kChatTabW = 58;
static const int kChatTabY = 2;
static const int kChatTabH = 28;
static const int kChatTabRowCanvasH = 30;   // the filter row's bottom (HudVeneerBridge.OFFICIAL_ROW_BOTTOM)
static const int kChatContentCanvasH = 115; // the message area below it: the chat is 145 px tall
// The native dialogue parchment keeps the box it had beside the old 40-px native row: the engine lays its dialogue in
// the 519-px chat container, and five options need the height.
static const int kDialogueCanvasW = 519;
static const int kDialogueCanvasH = 182;
// The column left of the chat, 601's SIDE_LEFT_CHAT: the logout door, the speech bubbles that put the chat away and
// bring it back, and the keyboard, 58x40 stones kColumnPitch apart from kColumnY down. The chat's base anchor steps
// right by its width, as the official chat sits right of it, and the chat is never moved so far left that the column
// would leave the canvas.
static const int kDoorCanvasW = 58;
static const int kColumnStoneH = 40;
static const int kColumnY = 4;
static const int kColumnPitch = 39;
static const int kTabLogout = 10;        // the engine tab index the door opens
static const int kTabSlotExpand = -1;    // TAB_GRID_ORDER's entry for the expand stone (not an engine tab)
static const int kTabSpritesVersion = 3; // HudVeneerBridge.TAB_SPRITES_VERSION this build draws
// The tab group (601's SIDE_RIGHT_TABS), in canvas px: a framed 2x7 grid of 40-px stones kTabPitch apart (they overlap
// by a pixel), kTabFrameInset inside the frame. Collapsed, the group narrows to kTabGroupCollapsedW and the outer
// column slides under the inner one, its edge showing at the right (TABS_GROUP_RIGHT stays right-aligned).
static const int kTabStone = 40;
static const int kTabPitch = 39;
static const int kTabFrameInset = 3;
static const int kTabGroupW = 85;
static const int kTabGroupCollapsedW = 58;
static const int kTabGroupH = 280;
static const int kSideContainerW = 204; // the engine's side container (the open panel), canvas px
// Portrait has no side safe area, so the group and the plugin rail keep this far (pt) off the right edge, clear of the
// screen's rounded corner.
static const CGFloat kPortraitRightEdge = 10.0;
// The tabs in grid-slot order, row-major (slot 0 = top-left, 1 = top-right, …), mapped to engine tab indexes, in the
// official app's order (interface 601): the inner column, next to the panel, is inventory, equipment, prayer, magic,
// combat, quests and the expand stone; the outer one is skills, emotes, music, clan, friends, account and settings.
// Logout is the door by the chat, not a stone. The Android twin is ChromeOverlayView.order.
static const int TAB_GRID_ORDER[14] = {3, 1, 4, 12, 5, 13, 6, 7, 0, 9, 2, 8, kTabSlotExpand, 11};
// Finger-scroll direction: -1 = drag-down scrolls toward OLDER messages (content follows the finger). The drag is
// converted to canvas px and applied to the chat's own scroll layer (no mouse wheel -> no camera zoom). Flip to +1
// if the direction feels inverted.
static const int kChatScrollDir = -1;
static NSString * const kChatTabNames[7] = { @"All", @"Game", @"Public", @"Private", @"Channel", @"Clan", @"Trade" };
// Filterable channels (a right-click filter menu exists): Public/Private/Channel/Clan/Trade. All + Game have
// none, so a long-press on them is a no-op (no filter menu). Indexes into the 7-tab arrays above.
static const BOOL kChatTabFilterable[7] = { NO, NO, YES, YES, YES, YES, YES };

// OSRS right-click menu geometry, straight from RuneLite's own hit-test (InteractHighlightOverlay
// .hoveredMenuEntry): the "Choose Option" title strip is 19px, each entry row is 15px. These are fixed
// pixel sizes in the gamepack render space (independent of canvas resolution), so a native row index k maps
// to the engine row centre at (menuX + menuW/2, menuY + 19 + k*15 + 7) for click-through. Display order
// matches MenuPeekBridge: row 0 (top) = the left-click default; the bottom row (index count-1) = "Cancel".
static const int kMenuHeaderPx = 19;
static const int kMenuRowPx    = 15;

// Press-and-hold drag tolerance (gamepack px). Dragging off the menu's SIDE still selects the row at the
// finger's height (generous horizontal grace); lifting clearly ABOVE/BELOW the menu reads as cancel (small
// vertical grace). The cursor is clamped strictly inside the rect regardless, so the menu never auto-closes.
static const CGFloat kMenuGraceX = 60.0;
static const CGFloat kMenuGraceY = 6.0;

// Native overlay sizing (compact — much smaller than the first pass): row height, header strip, box width.
static const CGFloat kMenuRowViewH = 44.0; // TOUCH-1: minimum touch-target height (was 32)
static const CGFloat kMenuHeaderViewH = 22.0;
static const CGFloat kMenuWidth       = 210.0;

// Minimap-orb touch veneer (mirrors Android ORB_KEYS / ORB_TAP_PAD): the orbs published by
// HudVeneerBridge.getOrbSnapshot, and the px each orb's raw sprite rect is enlarged by on every
// side so a fat-finger tap near a small orb (e.g. spec, tucked beside run/prayer) still activates it.
static NSArray<NSString *> *const kOrbKeys = @[ @"hp", @"prayer", @"run", @"spec", @"store", @"worldmap", @"wiki" ];
static const CGFloat kOrbTapPad = 10.0;

// QA-SYS-1 sibling: rate-limited JSON-parse-fault sink for the per-frame / per-poll bridge-snapshot reads.
// The native HUD/menu polls parse a bridge JSON snapshot every frame; with `error:nil` a malformed payload
// silently yields nil and that HUD element blanks with no trace. Every caller length-guards the snapshot
// BEFORE parsing, so a nil result on a NON-empty snapshot is a genuine malformation. parseBridgeJSON parses
// with a real NSError and, when that happens, emits ONE rate-limited "[json-fault]" line per site per 5s
// window (suppressed count reported on the next window) to stderr -> jvm-stdio.log, alongside the
// [bridge-fault] lines so all bridge diagnostics grep together. A nil/empty snapshot is the expected
// "no data this poll" case and stays silent. Drop-in for the old inline JSONObjectWithData:error:nil:
// returns the parsed object (NSDictionary*/NSArray*) or nil.
static id parseBridgeJSON(NSString *snap, const char *site) {
    if (snap.length == 0) {
        return nil;   // expected "no snapshot this poll" — silent
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[snap dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0 error:&err];
    if (obj != nil) {
        return obj;
    }

    // Parse failed on a non-empty snapshot — a real malformation. Rate-limit per site (5s window), mirroring
    // bridgeNoteClear / BridgeFaults. Pure-ObjC bookkeeping.
    static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *sites;   // site -> [lastLogNs, suppressed]
    static os_unfair_lock siteLock = OS_UNFAIR_LOCK_INIT;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sites = [NSMutableDictionary dictionary]; });

    const uint64_t windowNs = 5ull * NSEC_PER_SEC;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    NSString *key = @(site ? site : "?");
    BOOL shouldLog;
    unsigned long long suppressed = 0;
    os_unfair_lock_lock(&siteLock);
    NSArray<NSNumber *> *s = sites[key];
    if (s && now - s[0].unsignedLongLongValue < windowNs) {
        sites[key] = @[ s[0], @(s[1].unsignedLongLongValue + 1) ];   // within window: count, stay quiet
        shouldLog = NO;
    } else {
        suppressed = s ? s[1].unsignedLongLongValue : 0;
        sites[key] = @[ @(now), @0 ];                                // window rolled: log now, reset count
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&siteLock);

    if (shouldLog) {
        const char *msg = err.localizedDescription.UTF8String ?: "parse returned nil";
        if (suppressed > 0) {
            fprintf(stderr, "[json-fault] %s failed: %s (%llu more suppressed in the last 5000ms)\n",
                    site ? site : "?", msg, suppressed);
        } else {
            fprintf(stderr, "[json-fault] %s failed: %s\n", site ? site : "?", msg);
        }
    }
    return nil;
}

#pragma mark - RMSettingsViewController (the ⚙ sheet)

// A small grouped settings screen presented from the gear. It owns no state — every row is wired to a block
// the host supplies, so it stays decoupled from ViewController's private methods. Developer mode is a plain
// switch here; flipping it reveals/hides the dev rows (debug panel) in place.
@interface RMSettingsViewController : UITableViewController
@property (nonatomic, assign) BOOL railsOn;
@property (nonatomic, assign) BOOL pluginRailOn;
@property (nonatomic, assign) BOOL debugOn;
@property (nonatomic, assign) BOOL developerMode;
@property (nonatomic, assign) BOOL profilesAvailable; // gates the "Config profiles" row (bridge wired)
@property (nonatomic, assign) BOOL infoBoxAvailable;  // gates the "Infoboxes" row (bridge wired)
@property (nonatomic, copy) void (^onEditControls)(void);
@property (nonatomic, copy) void (^onOpenPlugins)(void);
@property (nonatomic, copy) void (^onOpenProfiles)(void);
@property (nonatomic, copy) void (^onOpenInfoboxes)(void);
@property (nonatomic, copy) void (^onToggleRails)(BOOL);
@property (nonatomic, copy) void (^onTogglePluginRail)(BOOL);
@property (nonatomic, copy) void (^onToggleDebug)(BOOL);
@property (nonatomic, copy) void (^onToggleDeveloper)(BOOL);
@end

@implementation RMSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.navigationController.navigationBar.barTintColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.navigationController.navigationBar.titleTextAttributes =
        @{NSForegroundColorAttributeName : [UIColor whiteColor]};
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(onDone)];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Extra PLUGINS rows appended after the base two, in fixed order, only when their bridge is wired (mirrors the
// old grid's synthetic tiles). Both cellForRow and didSelect index into this so the two stay consistent.
- (NSArray<NSString *> *)pluginExtraRows {
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    if (self.profilesAvailable)
        [rows addObject:@"profiles"];
    if (self.infoBoxAvailable)
        [rows addObject:@"infoboxes"];
    return rows;
}

// Sections: 0 Controls · 1 Game · 2 Plugins · 3 Developer (dev rows only when developerMode is on).
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0:
            return 1; // Edit controls
        case 1:
            return 2; // Game settings + Show tab rails
        case 2:
            return 2 + (NSInteger)[self pluginExtraRows].count; // Plugin panels + Show plugin rail (+ profiles/infoboxes)
        case 3:
            return self.developerMode ? 2 : 1; // Developer mode (+ debug panel)
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0:
            return @"ON-SCREEN CONTROLS";
        case 1:
            return @"GAME";
        case 2:
            return @"PLUGINS";
        case 3:
            return @"DEVELOPER";
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0)
        return @"Pick which keys and buttons sit on your screen. Start fresh, add only what you use.";
    if (s == 3)
        return self.developerMode
                   ? @"Diagnostic tools. Leave off for normal play."
                   : @"Turn on to reveal the debug panel.";
    return nil;
}

- (UISwitch *)switchOn:(BOOL)on action:(SEL)sel {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.onTintColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:1.0];
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (ip.section == 0) {
        cell.textLabel.text = @"Edit on-screen controls";
        cell.detailTextLabel.text = @"Add or remove keys and buttons";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1 && ip.row == 0) {
        cell.textLabel.text = @"Game settings";
        cell.detailTextLabel.text = @"Touch, camera, idle logout, frame rate, haptics";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        cell.textLabel.text = @"Show tab rails";
        cell.detailTextLabel.text = @"The row of game interface tabs";
        cell.accessoryView = [self switchOn:self.railsOn action:@selector(onRails:)];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 2) {
        if (ip.row == 0) {
            cell.textLabel.text = @"Plugin panels";
            cell.detailTextLabel.text = @"Configure your RuneLite plugins";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            cell.textLabel.text = @"Show plugin rail";
            cell.detailTextLabel.text = @"The plugin-icon strip on the right edge";
            cell.accessoryView = [self switchOn:self.pluginRailOn action:@selector(onPluginRail:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSString *extra = [self pluginExtraRows][ip.row - 2];
            if ([extra isEqualToString:@"profiles"]) {
                cell.textLabel.text = @"Config profiles";
                cell.detailTextLabel.text = @"Switch between your saved RuneLite profiles";
            } else {
                cell.textLabel.text = @"Infoboxes";
                cell.detailTextLabel.text = @"Manage the on-screen infobox overlays";
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else { // Developer
        if (ip.row == 0) {
            cell.textLabel.text = @"Developer mode";
            cell.accessoryView = [self switchOn:self.developerMode action:@selector(onDeveloper:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"Show debug panel";
            cell.accessoryView = [self switchOn:self.debugOn action:@selector(onDebug:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    void (^then)(void (^)(void)) = ^(void (^act)(void)) {
        [self dismissViewControllerAnimated:YES
                                 completion:^{
                                     if (act)
                                         act();
                                 }];
    };
    if (ip.section == 0)
        then(self.onEditControls);
    else if (ip.section == 1 && ip.row == 0)
        [self.navigationController pushViewController:[[RMGameSettingsViewController alloc] init] animated:YES];
    else if (ip.section == 2 && ip.row == 0)
        then(self.onOpenPlugins);
    else if (ip.section == 2 && ip.row >= 2) {
        NSString *extra = [self pluginExtraRows][ip.row - 2];
        then([extra isEqualToString:@"profiles"] ? self.onOpenProfiles : self.onOpenInfoboxes);
    }
}

- (void)onRails:(UISwitch *)sw {
    self.railsOn = sw.on;
    if (self.onToggleRails)
        self.onToggleRails(sw.on);
}
- (void)onPluginRail:(UISwitch *)sw {
    self.pluginRailOn = sw.on;
    if (self.onTogglePluginRail)
        self.onTogglePluginRail(sw.on);
}
- (void)onDebug:(UISwitch *)sw {
    self.debugOn = sw.on;
    if (self.onToggleDebug)
        self.onToggleDebug(sw.on);
}
- (void)onDeveloper:(UISwitch *)sw {
    self.developerMode = sw.on;
    // Disabling dev mode hides the debug panel host-side (applyDeveloperMode), so mirror that here — otherwise
    // re-enabling in the same sheet would show "Show debug panel" ON over an actually-hidden panel.
    if (!sw.on)
        self.debugOn = NO;
    if (self.onToggleDeveloper)
        self.onToggleDeveloper(sw.on);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.bgTask = UIBackgroundTaskInvalid;
    // The orientation the offsets below are kept for; onLaunch settles it from the canvas it picks.
    sCanvasPortrait = [RMGameSettings autoRotate] ? self.view.bounds.size.height > self.view.bounds.size.width
                                                  : [RMGameSettings portrait];
    // Persisted minimap position offset (set in overlay edit-mode; applied in updateHudLayout).
    self.minimapUserDX = (int)[[NSUserDefaults standardUserDefaults] integerForKey:hudOffsetKey(@"minimapUserDX")];
    self.minimapUserDY = (int)[[NSUserDefaults standardUserDefaults] integerForKey:hudOffsetKey(@"minimapUserDY")];
    [self buildUI];
    [self openLogFile];
    // First in the log because it describes the run BEFORE this one. Nil on a first run.
    NSString *residency = [RMResidency noteLaunchAndVerdict];
    if (residency)
        [self appendLine:residency];
    __weak ViewController *weakLog = self;
    RMGameSettings.screenLog = ^(NSString *line) {
        [weakLog appendLine:line];
    };
    self.bgKeepTask = UIBackgroundTaskInvalid;
    // Flush RuneLite config to disk when the app backgrounds (iOS skips RuneLite's own shutdown flush).
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
    // Coming back: stop the background PiP pump (the CADisplayLink takes over) and re-arm the keepalive
    // audio in case the session was interrupted while away.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    // The one ending iOS tells us about, for the residency record.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onWillTerminate)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    // PARITY-P0-3: the modally-presented World Switcher posts this when a hop starts so we can arm the hop scrim
    // over the game view (it has no direct reference back to this root VC). No removeObserver — like the
    // background/foreground observers above, this VC is the app's single long-lived root.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onHopScrimArmed:)
                                                 name:@"RMWorldHopArmed"
                                               object:nil];
    // Settings > Game settings: the long-press time applies to the recognizers live.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyLongPressTime)
                                                 name:RMGameSettingsDidChangeNotification
                                               object:nil];
    [self appendLine:@"RuneMobile — W1 minimal JVM shell"];
    [self appendLine:[NSString stringWithFormat:@"jre: %@",
                      [JVMLauncher javaHome] ?: @"(MISSING from bundle!)"]];
    [self appendLine:@"Waiting for StikDebug attach (CS_DEBUGGED)…"];
    [self appendLine:@"Assign the iOS-26 JIT script to this app in StikDebug, then attach."];
    [self startJitPolling];

    // W3 GPU track — B0 GL-tier recon (pure native, no JVM/JIT). Runs once on launch and logs the device's
    // GPU/GL capabilities to the console + hello-shell.log (the go/no-go gate for the GPU renderer effort).
    [GLRecon runWithLog:^(NSString *l) { [self appendLine:l]; }];

    // Persistent plugin-panel dock: an always-on icon rail (right) + icon strip (bottom) over the live game,
    // panels open inline without going through the settings menu. Passthrough overlay (game stays usable); it
    // self-populates once RuneLite registers its panels and tracks plugin toggles.
    self.panelDock = [[PluginPanelsViewController alloc] init];
    self.panelDock.docked = YES;
    [self addChildViewController:self.panelDock];
    self.panelDock.view.frame = self.view.bounds;
    self.panelDock.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.panelDock.view];
    [self.panelDock didMoveToParentViewController:self];

    // #1: the "Tap to Play" cover sits ABOVE everything (game, HUD veneers, panel dock, debug panel) so the
    // cold-start experience is the polished play screen, not the W1 scaffolding. Dismissed on launch.
    [self buildLaunchScreen];

    // Immersive fullscreen (parity with Android's sticky edge-to-edge, MainActivity enterImmersive): hide the
    // status bar + home indicator so the game fills the whole screen with no clock/battery/signal chrome,
    // matching the target Jagex OSRS Mobile look. Apply immediately rather than waiting for the next appearance
    // query. This VC is the window's rootViewController directly (AppDelegate), so the per-VC overrides below win.
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
}

// One-tap layout switch: the pill's label, and how long it waits into a run of unsupported-layout frames before it
// shows (a varbit that syncs late after login, or a one-frame blip, must not flash it over a Modern account), and
// how long the server gets to apply a switch before the pill gives up and says how to do it by hand.
static NSString *const kLayoutSwitchLabel = @"Switch to Resizable - Modern";
static const CFTimeInterval kLayoutSwitchSettle = 3.0;
static const CFTimeInterval kLayoutSwitchTimeout = 15.0;

// UX-ONBOARD-02: the whole native chrome -- the chat veneer, the tab row, the dialogue tap routing -- is laid out
// against the resizable-MODERN top level (interface 164; see updateChatTabs, which stands down for any other id),
// so in Fixed or Resizable-Classic the HUD simply doesn't line up with the game under it. Say so once per launch,
// over the Tap to Play cover, until the user asks not to see it again.
static NSString *const kLayoutNoticeOffKey = @"layoutNoticeSuppressed";
static NSString *const kLayoutNoticeTitle = @"Use Resizable - Modern layout";
static NSString *const kLayoutNoticeBody =
    @"RuneMobile's touch controls and overlays are built for the Resizable - Modern layout. "
    @"If your account uses another layout, tap \"Switch to Resizable - Modern\" at the top of the screen once "
    @"you're in the game.";

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self maybeShowJitStartupFailure];
    [self maybeShowLayoutNotice];
}

// The previous launch died or froze during a code-cache request (the cover's script check, or JNI_CreateJavaVM).
// The check names a wrong script before Tap to Play (startJitPolling); this covers what it can't: a script that
// never answers it, or one that answers it and then fails the JVM. Once per process; the record is consumed whether
// or not the alert can be shown.
- (void)maybeShowJitStartupFailure {
    if (self.jitStartupChecked)
        return;
    self.jitStartupChecked = YES;
    if (![JVMLauncher takeJitStartupFailure])
        return;
    [self appendLine:@"[shell] the last launch died or froze during a brk #0x69 code-cache request: StikDebug ran "
                     @"another script or an outdated runelite-jit.js"];
    if (self.fatalErrorShown || self.presentedViewController != nil)
        return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"The last start didn't finish"
                         message:@"RuneMobile closed while it was starting up. That usually means StikDebug ran the "
                                 @"wrong script, or an old copy of runelite-jit.js.\n\nIn StikDebug, long-press "
                                 @"RuneMobile → Reset Script, then Assign Script → the runelite-jit.js from the latest "
                                 @"release, and attach again.\n\nIf you closed the app yourself, ignore this."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)maybeShowLayoutNotice {
    // Once per process: viewDidAppear fires again after the login web view, a plugin panel, or a backgrounding.
    if (self.layoutNoticeShown)
        return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kLayoutNoticeOffKey])
        return;
    // Never stack: the fatal-error card owns the screen when a boot has failed, and an alert over an already
    // presented VC would be refused by UIKit (and the flag would latch as if it had been shown).
    if (self.fatalErrorShown || self.presentedViewController != nil)
        return;
    self.layoutNoticeShown = YES;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:kLayoutNoticeTitle
                                                                message:kLayoutNoticeBody
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Got it" style:UIAlertActionStyleDefault handler:nil]];
    __weak __typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Don't show again"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *action) {
                                             (void)action;
                                             [[NSUserDefaults standardUserDefaults] setBool:YES
                                                                                     forKey:kLayoutNoticeOffKey];
                                             [weakSelf appendLine:@"[shell] onboard: layout notice suppressed"];
                                         }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Immersive-chrome overrides (see the enterImmersive parity note in viewDidLoad). The status bar auto-reveals
// transiently on a top-edge swipe (UIKit default for prefersStatusBarHidden), matching Android's swipe-to-peek.
- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationSlide;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

#pragma mark - #1 Tap-to-Play front screen

- (void)buildLaunchScreen {
    UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.05 alpha:1.0]; // opaque OSRS-mobile tone
    cover.userInteractionEnabled = YES;   // swallow every touch so nothing reaches the game/HUD beneath
    self.launchScreen = cover;

    // The RuneMobile logo above the title. On a short screen it shrinks rather than run under the top edge.
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Logo"]];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [logo setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [cover addSubview:logo];
    NSLayoutConstraint *logoHeight = [logo.heightAnchor constraintEqualToConstant:96];
    logoHeight.priority = UILayoutPriorityDefaultHigh;

    // Title — the app identity, top-centred like the Jagex Mobile splash.
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"RuneLite";
    title.font = [UIFont systemFontOfSize:44 weight:UIFontWeightHeavy];
    title.textColor = [UIColor colorWithRed:0.93 green:0.78 blue:0.36 alpha:1.0]; // OSRS gold
    title.textAlignment = NSTextAlignmentCenter;
    [cover addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"Old School RuneScape";
    subtitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    subtitle.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [cover addSubview:subtitle];

    // Primary play button — disabled (dimmed) until the StikDebug attach flips CS_DEBUGGED. The JIT poller
    // (startJitPolling) enables it; the attach is per-launch and immovable, so this is the gate we polish around.
    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.translatesAutoresizingMaskIntoConstraints = NO;
    [play setTitle:@"Tap to Play" forState:UIControlStateNormal];
    play.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [play setTitleColor:[UIColor colorWithRed:0.10 green:0.09 blue:0.05 alpha:1.0] forState:UIControlStateNormal];
    [play setTitleColor:[UIColor colorWithWhite:0.45 alpha:1.0] forState:UIControlStateDisabled];
    play.backgroundColor = [UIColor colorWithRed:0.85 green:0.68 blue:0.26 alpha:1.0];
    play.layer.cornerRadius = 12;
    play.enabled = NO;
    play.alpha = 0.5;
    [play addTarget:self action:@selector(onPlayTapped) forControlEvents:UIControlEventTouchUpInside];
    [cover addSubview:play];
    self.playButton = play;

    // Gated status line under the button: "Attach StikDebug to play…" (amber) → "Ready to play" (green).
    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = @"Attach StikDebug to play…";
    status.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    status.textColor = [UIColor systemYellowColor];
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 3; // the script-check messages wrap to a third line on narrow phones
    [cover addSubview:status];
    self.playStatusLabel = status;

    // Login row — reflects the saved session (refreshLaunchLogin keeps the title current). Pure native, so
    // it works before any attach: log in here, then attach + play.
    UIButton *login = [UIButton buttonWithType:UIButtonTypeSystem];
    login.translatesAutoresizingMaskIntoConstraints = NO;
    login.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    login.titleLabel.numberOfLines = 2;
    login.titleLabel.textAlignment = NSTextAlignmentCenter;
    [login setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    [login addTarget:self action:@selector(onLaunchLoginTapped) forControlEvents:UIControlEventTouchUpInside];
    [cover addSubview:login];
    self.playLoginButton = login;

    // "Share logs", top right: a problem at this screen (no JIT, a crash right after Tap to Play, the last start
    // didn't finish) is the one a player most needs to report, and they can't reach About from here.
    UIButton *shareLogs = [UIButton buttonWithType:UIButtonTypeSystem];
    shareLogs.translatesAutoresizingMaskIntoConstraints = NO;
    [shareLogs setTitle:@"Share logs" forState:UIControlStateNormal];
    shareLogs.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    [shareLogs setTitleColor:[UIColor colorWithWhite:0.62 alpha:1.0] forState:UIControlStateNormal];
    [shareLogs addTarget:self action:@selector(onShareLogsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cover addSubview:shareLogs];

    // Hidden affordance: a triple-tap on the cover drops to the W1 debug panel (canary / AWT-activation /
    // logs) without launching — the dev escape hatch the audit asked to gate behind a hidden gesture.
    UITapGestureRecognizer *devTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onRevealDebug)];
    devTap.numberOfTapsRequired = 3;
    [cover addGestureRecognizer:devTap];

    [self.view addSubview:cover];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [title.bottomAnchor constraintEqualToAnchor:cover.centerYAnchor constant:-40],
        [subtitle.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],

        [play.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [play.topAnchor constraintEqualToAnchor:cover.centerYAnchor constant:24],
        [play.widthAnchor constraintEqualToConstant:240],
        [play.heightAnchor constraintEqualToConstant:56],

        [status.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [status.topAnchor constraintEqualToAnchor:play.bottomAnchor constant:14],
        [status.leadingAnchor constraintGreaterThanOrEqualToAnchor:cover.leadingAnchor constant:20],
        [status.trailingAnchor constraintLessThanOrEqualToAnchor:cover.trailingAnchor constant:-20],

        [login.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [login.bottomAnchor constraintEqualToAnchor:cover.safeAreaLayoutGuide.bottomAnchor constant:-24],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [shareLogs.topAnchor constraintEqualToAnchor:cover.safeAreaLayoutGuide.topAnchor
                                            constant:8],
        [shareLogs.trailingAnchor constraintEqualToAnchor:cover.safeAreaLayoutGuide.trailingAnchor
                                                 constant:-16],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [logo.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
        [logo.bottomAnchor constraintEqualToAnchor:title.topAnchor
                                          constant:-10],
        [logo.topAnchor constraintGreaterThanOrEqualToAnchor:cover.safeAreaLayoutGuide.topAnchor
                                                    constant:12],
        [logo.widthAnchor constraintEqualToAnchor:logo.heightAnchor],
        logoHeight,
    ]];

    [self refreshLaunchLogin];
}

- (void)onShareLogsTapped:(UIButton *)sender {
    [self appendLine:@"[shell] share logs: opened from the cover"];
    [RMDiagnostics shareFrom:self sourceView:sender];
}

// Mirror the saved tokens.json onto the launch-screen login button (same source as refreshLoginButton).
- (void)refreshLaunchLogin {
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *t = [o isKindOfClass:[NSDictionary class]] ? o : nil;
    NSString *sid  = [t[@"session_id"] isKindOfClass:[NSString class]] ? t[@"session_id"] : nil;
    NSString *name = [t[@"chosen_display_name"] isKindOfClass:[NSString class]] ? t[@"chosen_display_name"] : nil;
    NSString *title = sid.length
                          ? (name.length ? [NSString stringWithFormat:@"Logged in: %@  ·  switch or log out", name]
                                         : @"Logged in  ·  switch or log out")
                          : @"Log in with Jagex";
    [self.playLoginButton setTitle:title forState:UIControlStateNormal];
}

// Launch-screen account button: with no saved session, go straight to the web login; when logged in, offer an
// account menu (switch account / log out) so the user can sign out without digging into the dev debug panel.
- (void)onLaunchLoginTapped {
    if (self.presentedViewController)
        return;
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *t = [o isKindOfClass:[NSDictionary class]] ? o : nil;
    NSString *sid = [t[@"session_id"] isKindOfClass:[NSString class]] ? t[@"session_id"] : nil;
    if (sid.length == 0) {
        [self onLoginWithJagex]; // not signed in — go straight to the web login
        return;
    }
    NSString *name = [t[@"chosen_display_name"] isKindOfClass:[NSString class]] ? t[@"chosen_display_name"] : nil;
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:(name.length ? [NSString stringWithFormat:@"Logged in as %@", name] : @"Logged in")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Switch account (sign in again)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
                                                // Present the web login after the sheet finishes dismissing —
                                                // presenting a modal from inside the action handler races the
                                                // sheet's own dismissal (matches onSwitchCharacter).
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    [self onLoginWithJagex];
                                                });
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Log out"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) {
                                                [self onLogout];
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.playLoginButton;
    sheet.popoverPresentationController.sourceRect = self.playLoginButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Hidden dev affordance: dismiss the cover to expose the developer panel (does NOT launch the JVM). The cover
// is only HIDDEN (not removed) so the panel's ✕ can bring it back — otherwise closing pre-launch would strand
// the user on a not-yet-started game with no play button.
- (void)onRevealDebug {
    self.debugPanel.hidden = NO;
    self.launchScreen.hidden = YES;
}

// 117HD crash-cookie plumbing (see the property block for the arm/clear/consume contract). The marker
// lives in Application Support (same home as the auth tokens — not user-visible, backed up, no iCloud
// Documents exposure) and is written atomically so a hard kill right after arming can't half-write it.
- (NSString *)hdBootCookiePath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"hd-boot-armed"];
}

- (void)hdBootCookieArm {
    NSString *path = [self hdBootCookiePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSData data] writeToFile:path options:NSDataWritingAtomic error:nil];
}

- (void)hdBootCookieClear {
    [[NSFileManager defaultManager] removeItemAtPath:[self hdBootCookiePath] error:nil];
}

- (BOOL)hdBootCookiePresent {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self hdBootCookiePath]];
}

- (void)onPlayTapped {
    // Only a served script check has the JVM's code cache ready; without it the JVM's brk #0x69 can kill the app.
    // The poller can be a tick behind, so ignore the tap; the next tick turns the button off and says why.
    if ([JVMLauncher jitScriptCheck] != RMJitScriptCheckServed)
        return;
    // If the login web view ran this session, WebKit is resident and the JVM can't start cleanly — onLaunch
    // will prompt a restart instead. Keep the cover up in that case so the user lands back here post-restart.
    // Tap to Play boots the renderer the user SELECTED in the plugins panel, saved in NSUserDefaults
    // "rendererPref" (cpu | gpu | 117hd). With nothing saved, the first-run probe below picks one. The
    // GPU + 117HD plugins are loaded into the panel in every mode (RendererPanelStarter) so they're selectable;
    // flipping one there saves the preference (with a "restart to apply" message), and THIS reads it at launch.
    // base GPU uses the readback present (int[] frames like CPU); 117HD uses the CAEAGLLayer direct present.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *pref = [ud stringForKey:@"rendererPref"];
    if (pref == nil && ![ud boolForKey:@"autoGpuFailed"]) {
        // First run on a fresh install with no prior GPU failure: optimistically promote to base GPU if the hardware
        // can run it (GLRecon says why not 117HD). The boot crash-cookie (P1-21) self-heals a bad promotion;
        // autoGpuFailed latches re-promotion off once a promoted boot has failed.
        pref = [GLRecon recommendedRendererTier];
        [ud setObject:pref forKey:@"rendererPref"];
        [ud setBool:YES forKey:kNewInstallDefaultsKey];
        [self appendLine:[NSString stringWithFormat:@"[shell] auto-GPU: first-run caps probe -> default renderer %@", pref]];
    }
    if (pref == nil)
        pref = @"cpu";
    BOOL wantGpu = [pref isEqualToString:@"gpu"];
    BOOL wantHd = [pref isEqualToString:@"117hd"];
    if ((wantHd || wantGpu) && [self hdBootCookiePresent]) {
        // The last GPU boot (base GPU OR 117HD) armed the cookie and died before its first GL present (GL-init/
        // shader-compile crash or an OOM kill mid-warmup). Fall back to the always-works software renderer so the
        // user is never crash-looped out of the game, and tell them where to turn the GPU renderer back on.
        NSString *rname = wantHd ? @"117HD" : @"GPU";
        [self hdBootCookieClear];
        [ud setObject:@"cpu" forKey:@"rendererPref"];
        // Latch off the first-run auto-promote so the caps probe never re-promotes a device that already failed once
        // (parity with Android's !autoGpuFailed gate). A later explicit user pick in the panel clears this.
        [ud setBool:YES forKey:@"autoGpuFailed"];
        pref = @"cpu";
        wantHd = NO;
        wantGpu = NO;
        [self appendLine:[NSString stringWithFormat:@"[shell] %@ did not survive its last launch — reverted to the "
                                                    @"standard renderer",
                                                    rname]];
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"%@ renderer didn't start", rname]
                             message:[NSString stringWithFormat:@"%@ crashed while starting last time, so this "
                                                                @"launch uses the standard renderer. You can turn "
                                                                @"%@ back on in the plugins panel.",
                                                                rname, rname]
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
    self.pendingRouteCGpu = wantGpu;
    self.pendingRouteCZone = wantHd;
    self.pendingRouteCZoneDirect = wantHd;
    self.pendingRouteCGpuNoResize = NO;
    self.pendingRouteCL1 = NO;
    [self appendLine:[NSString stringWithFormat:@"[shell] renderer pref = %@", pref]];
    if (self.webKitUsedThisSession) { [self onLaunch]; return; }
    if (!self.launchScreen.hidden) {
        // Fade the cover out, then hand off to the existing JVM launch path.
        [UIView animateWithDuration:0.25 animations:^{ self.launchScreen.alpha = 0.0; }
                         completion:^(BOOL done) {
            self.launchScreen.hidden = YES;
            [self.launchScreen removeFromSuperview];
        }];
    }
    [self onLaunch];
}

- (void)buildUI {
    // (0) Game screen — the BOTTOM layer, filling the entire screen edge-to-edge (full-screen landscape).
    RMSceneView *sceneView = [[RMSceneView alloc] init];
    __weak ViewController *weakSelfForScene = self;
    sceneView.touchDown = ^(CGPoint point) {
        [weakSelfForScene onSceneTouchDown:point];
    };
    sceneView.touchMoved = ^(CGPoint point) {
        [weakSelfForScene onSceneTouchMoved:point];
    };
    sceneView.touchUp = ^(CGPoint origin, CGFloat strayed, NSTimeInterval held) {
        [weakSelfForScene onSceneTouchUp:origin strayed:strayed held:held];
    };
    // No self needed, and nothing to decide: a sequence that ends this way never clicks. The gesture handlers
    // drop the arm themselves when they begin (promptly, rather than at the lift of a long drag), but each of
    // them can also return early — onCameraPan: does, with a menu open — so this is the backstop that does not
    // depend on which recognizer won or on whether its handler got that far.
    sceneView.touchGone = ^{
        [JVMLauncher postCancelArmedTap];
    };
    self.screen = sceneView;
    self.screen.translatesAutoresizingMaskIntoConstraints = NO;
    self.screen.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    self.screen.contentMode = UIViewContentModeScaleAspectFit;   // render aspect == screen aspect -> fills
    self.screen.layer.magnificationFilter = kCAFilterLinear;     // smooth when scaled to native res
    self.screen.userInteractionEnabled = YES;                    // receive the game gestures
    [self.view addSubview:self.screen];

    // Phase 5 control scheme on the game view: tap = left click (walk/interact/menu-entry), long-press =
    // drag-to-select menu, one-finger drag = camera rotate, pinch = zoom. The hold, the drag and the zoom are
    // recognizers; the TAP is not (RMSceneView + kSceneDragSlop decides it from the touch sequence), because a
    // tap recognizer rejects any touch that rolled more than ~10pt and the pan used to claim those first — so
    // a tap with a little roll in it did nothing at all.
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLongPress:)];
    longPress.minimumPressDuration = [RMGameSettings longPressMs] / 1000.0; // Settings > Game settings
    self.sceneLongPress = longPress;
    // Same slop as the tap and the camera, so the three partition every one-finger touch with ONE number: a
    // hold that rolled 15pt is still a hold (UIKit's default 10pt failed it, and then nothing opened the menu
    // and nothing clicked either — the touch fell between all three gestures).
    longPress.allowableMovement = kSceneDragSlop;
    longPress.delegate = self;
    [self.screen addGestureRecognizer:longPress];
    UIPanGestureRecognizer *camPan = [[RMCameraPanRecognizer alloc]
        initWithTarget:self
                action:@selector(onCameraPan:)];
    camPan.minimumNumberOfTouches = 1;
    camPan.maximumNumberOfTouches = 1;
    [self.screen addGestureRecognizer:camPan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPinch:)];
    [self.screen addGestureRecognizer:pinch];

    // In-game keyboard control, bottom-left of the game's safe area (by the chat box). A button subview
    // consumes its own taps, so it never leaks a walk-here click to the gestures beneath.
    self.keyboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.keyboardButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.keyboardButton setTitle:@"⌨︎" forState:UIControlStateNormal];
    self.keyboardButton.accessibilityLabel = @"Keyboard";
    self.keyboardButton.accessibilityHint = @"Shows or hides the on-screen keyboard";
    self.keyboardButton.titleLabel.font = [UIFont systemFontOfSize:22];
    self.keyboardButton.tintColor = [UIColor whiteColor];
    self.keyboardButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.keyboardButton.layer.cornerRadius = 8;
    [self.keyboardButton addTarget:self action:@selector(onToggleKeyboard)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.keyboardButton];

    // Settings gear — the ONE always-on control (bottom-left corner). The screen starts fresh: no keyboard,
    // no modifiers, nothing. Tap the gear to open Settings, where the player pins whichever controls they want
    // (Edit controls), flips Developer mode, opens plugins, etc. Everything else is opt-in.
    self.settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.settingsButton setTitle:@"⚙" forState:UIControlStateNormal];
    self.settingsButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.settingsButton.accessibilityLabel = @"Settings";
    self.settingsButton.accessibilityHint = @"Pin on-screen controls, plugins, and developer options";
    self.settingsButton.tintColor = [UIColor whiteColor];
    self.settingsButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.settingsButton.layer.cornerRadius = 8;
    [self.settingsButton addTarget:self
                            action:@selector(onOpenSettings)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.settingsButton];

    // The pinned-controls stack packs the player's chosen buttons in a row to the right of the gear (no gaps —
    // hidden rows collapse; extra rows wrap upward). Rebuilt by rebuildPinnedControls from the persisted
    // "pinnedControls" list. The outer stack stays vertical so overflow rows grow up, away from the gear row.
    self.controlsBox = [[UIStackView alloc] init];
    self.controlsBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.controlsBox.axis = UILayoutConstraintAxisVertical;
    self.controlsBox.spacing = 8;
    self.controlsBox.alignment = UIStackViewAlignmentLeading;
    [self.screen addSubview:self.controlsBox];

    // Always-on keyboard toggle. Unlike the retired bottom-left ⌨︎ (hidden with the rest of the legacy cluster),
    // this one is pinned at the TOP of the safe area — clear of the soft keyboard, which rises from the bottom and
    // covered the old spot, so the toggle stays reachable even while the keyboard is up. Top-centre keeps it clear
    // of the relocated HUD (chat top-left, minimap/orbs top-right) and the bottom-corner native controls. It hides
    // with the other chrome whenever a full overlay (the world map) takes over, so it never floats over one.
    self.kbFab = [UIButton buttonWithType:UIButtonTypeSystem];
    self.kbFab.translatesAutoresizingMaskIntoConstraints = NO;
    [self.kbFab setTitle:@"⌨︎" forState:UIControlStateNormal];
    self.kbFab.accessibilityLabel = @"Keyboard";
    self.kbFab.accessibilityHint = @"Shows or hides the on-screen keyboard";
    self.kbFab.titleLabel.font = [UIFont systemFontOfSize:22];
    self.kbFab.tintColor = [UIColor whiteColor];
    self.kbFab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.kbFab.layer.cornerRadius = 8;
    [self.kbFab addTarget:self
                   action:@selector(onToggleKeyboard)
         forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.kbFab];

    // Sticky-Shift toggle, next to the keyboard button. Holds VK_SHIFT down via the bridge so the engine's
    // isKeyPressed(KC_SHIFT) path reads true — re-enabling shift-click menu swaps, Shift+right-click marking,
    // and overlay "Configure" on touch (no hardware key). Tap to latch on (highlighted), tap again to release.
    self.shiftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shiftButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shiftButton setTitle:@"⇧" forState:UIControlStateNormal];
    self.shiftButton.accessibilityLabel = @"Sticky Shift";
    self.shiftButton.accessibilityHint = @"Holds Shift down for shift-click actions; tap again to release";
    self.shiftButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.shiftButton.tintColor = [UIColor whiteColor];
    self.shiftButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.shiftButton.layer.cornerRadius = 8;
    [self.shiftButton addTarget:self action:@selector(onToggleShift)
               forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.shiftButton];

    // PARITY-IOS-LATCH: sticky-Ctrl toggle, mirroring sticky-Shift. Holds VK_CONTROL via the bridge so the
    // engine's isKeyPressed(KC_CONTROL) path reads true (e.g. Ctrl-click walk-here, Ctrl+F search fields).
    self.ctrlButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.ctrlButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.ctrlButton setTitle:@"⌃" forState:UIControlStateNormal];
    self.ctrlButton.accessibilityLabel = @"Sticky Control";
    self.ctrlButton.accessibilityHint = @"Holds Control down for ctrl-click actions; tap again to release";
    self.ctrlButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.ctrlButton.tintColor = [UIColor whiteColor];
    self.ctrlButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.ctrlButton.layer.cornerRadius = 8;
    [self.ctrlButton addTarget:self
                        action:@selector(onToggleCtrl)
              forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.ctrlButton];

    // NOTE: a sticky-Alt latch was removed — in RuneLite the drag-hotkey defaults to Alt, so holding Alt puts the
    // client into overlay-managing mode (yellow movable-overlay boxes that swallow taps), trapping the touch user.
    // Mobile repositions overlays via the native OverlayEditView instead, so Alt-drag isn't needed here.

    // Screenshot: save the live composited frame to Photos (the engine's auto-screenshots land in the sandbox
    // dir, unreachable; this is the manual, reachable path — native already has the frame via latestFrame).
    self.screenshotButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.screenshotButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.screenshotButton setTitle:@"📷" forState:UIControlStateNormal];
    self.screenshotButton.accessibilityLabel = @"Screenshot";
    self.screenshotButton.accessibilityHint = @"Saves the current frame to Photos; long press toggles auto-saving event screenshots";
    self.screenshotButton.titleLabel.font = [UIFont systemFontOfSize:20];
    self.screenshotButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.screenshotButton.layer.cornerRadius = 8;
    [self.screenshotButton addTarget:self action:@selector(onScreenshot)
                    forControlEvents:UIControlEventTouchUpInside];
    // SHOT-4: long-press the camera button toggles auto-saving the engine's event screenshots to Photos (SHOT-2).
    UILongPressGestureRecognizer *shotLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onScreenshotLongPress:)];
    [self.screenshotButton addGestureRecognizer:shotLp];
    [self.screen addSubview:self.screenshotButton];

    // A native ✕ close for the world map (iOS has no hardware/gesture Back to hang it off like Android). Shown
    // only while the map is open, pinned top-right of the safe area (a corner the map's chrome-hide leaves empty).
    // Tapping it proxies the engine's own CLOSE rect via a precise click, so the player needn't land the tiny X.
    self.closeMapButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeMapButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeMapButton setTitle:@"✕" forState:UIControlStateNormal];
    self.closeMapButton.accessibilityLabel = @"Close map";
    self.closeMapButton.accessibilityHint = @"Closes the world map";
    self.closeMapButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.closeMapButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.closeMapButton.layer.cornerRadius = 8;
    self.closeMapButton.hidden = YES;
    [self.closeMapButton addTarget:self
                            action:@selector(onCloseWorldMap)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.closeMapButton];

    // One-tap layout switch (updateLayoutSwitch), top-centre under the keyboard toggle, where neither Classic's
    // nor Fixed's engine HUD sits. Hidden until the player has been in one of those layouts for a moment.
    self.layoutSwitchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.layoutSwitchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.layoutSwitchButton setTitle:kLayoutSwitchLabel forState:UIControlStateNormal];
    self.layoutSwitchButton.accessibilityLabel = kLayoutSwitchLabel;
    self.layoutSwitchButton.accessibilityHint = @"Changes the game's layout setting for your account";
    self.layoutSwitchButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    self.layoutSwitchButton.tintColor = [UIColor whiteColor];
    [self.layoutSwitchButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.6]
                                  forState:UIControlStateDisabled];
    self.layoutSwitchButton.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.9];
    self.layoutSwitchButton.layer.cornerRadius = 20;
    self.layoutSwitchButton.layer.borderWidth = 1;
    self.layoutSwitchButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    self.layoutSwitchButton.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 18);
    self.layoutSwitchButton.hidden = YES;
    [self.layoutSwitchButton addTarget:self
                                action:@selector(onLayoutSwitch)
                      forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.layoutSwitchButton];

    // Manual Picture-in-Picture: pops the game into the floating window without leaving the app, and doubles
    // as the auto-start diagnostic (manual-works/auto-doesn't isolates the system's auto-engage gate). Hidden
    // until setupPictureInPicture arms the controller.
    self.pipButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.pipButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pipButton setTitle:@"📺" forState:UIControlStateNormal];
    self.pipButton.accessibilityLabel = @"Picture in picture";
    self.pipButton.accessibilityHint = @"Pops the game into a floating window";
    self.pipButton.titleLabel.font = [UIFont systemFontOfSize:20];
    self.pipButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.pipButton.layer.cornerRadius = 8;
    self.pipButton.hidden = YES;
    [self.pipButton addTarget:self action:@selector(onTogglePip)
             forControlEvents:UIControlEventTouchUpInside];
    [self.screen addSubview:self.pipButton];

    // KEY-1: the action-hotkey strip toggle (⚡), right of the PiP button. Tap shows/hides the pinned-hotkey
    // strip; long-press opens the picker. A UIControl, so the gesture-delegate filter keeps its taps off the game.
    self.hotkeyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.hotkeyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.hotkeyButton setTitle:@"⚡" forState:UIControlStateNormal];
    self.hotkeyButton.accessibilityLabel = @"Action hotkeys";
    self.hotkeyButton.accessibilityHint = @"Shows or hides the hotkey strip; long press to edit hotkeys";
    self.hotkeyButton.titleLabel.font = [UIFont systemFontOfSize:20];
    self.hotkeyButton.tintColor = [UIColor whiteColor];
    self.hotkeyButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.hotkeyButton.layer.cornerRadius = 8;
    [self.hotkeyButton addTarget:self action:@selector(onToggleHotkeyStrip)
                forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *hkLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onHotkeyPicker:)];
    [self.hotkeyButton addGestureRecognizer:hkLp];
    [self.screen addSubview:self.hotkeyButton];

    // The strip itself — a horizontal stack just above the ⇧/📷/📺 row, hidden until toggled.
    self.hotkeyStrip = [[UIStackView alloc] init];
    self.hotkeyStrip.translatesAutoresizingMaskIntoConstraints = NO;
    self.hotkeyStrip.axis = UILayoutConstraintAxisHorizontal;
    self.hotkeyStrip.spacing = 6;
    self.hotkeyStrip.alignment = UIStackViewAlignmentCenter;
    self.hotkeyStrip.hidden = YES;
    [self.screen addSubview:self.hotkeyStrip];

    // Native tab rails (edge-split, mobile arrangement): a 2-column icon grid pinned to the right edge of the
    // game view. The opaque rail background sits behind the icon buttons; each icon is blitted from the live
    // desktop stone's sprite region, and a tap proxies a click onto the real stone centre (so the native
    // position is decoupled from the proxy target — no widget is moved/hidden). Subviews of the game view
    // (keyboard-button pattern: each consumes its own tap, the rest drives the game gestures).
    self.tabRailBg = [[UIView alloc] init];
    self.tabRailBg.hidden = YES;
    self.tabRailBg.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.92];
    self.tabRailBg.layer.cornerRadius = 10;
    self.tabRailBg.userInteractionEnabled = NO;   // never eats taps; the buttons on top do
    [self.screen addSubview:self.tabRailBg];

    // The grid's frame, under every stone.
    self.tabFrameView = [[UIImageView alloc] init];
    self.tabFrameView.hidden = YES;
    self.tabFrameView.userInteractionEnabled = NO;
    self.tabFrameView.layer.magnificationFilter = kCAFilterNearest;
    [self.view addSubview:self.tabFrameView];

    self.tabButtons = [NSMutableArray arrayWithCapacity:14];
    for (int i = 0; i < 14; i++) {
        TabGridButton *tb = [TabGridButton buttonWithType:UIButtonTypeCustom];
        tb.tag = i;
        tb.hidden = YES;
        tb.imageView.contentMode = UIViewContentModeScaleAspectFit;
        tb.imageView.layer.magnificationFilter = kCAFilterNearest;   // crisp pixel-art upscale
        tb.contentEdgeInsets = UIEdgeInsetsZero;
        tb.clipsToBounds = NO;
        [tb addTarget:self action:@selector(onTabButton:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:tb];   // in the side strips, outside the (inset) game view
        [self.tabButtons addObject:tb];
    }
    // Logout's button is the door by the chat (updateChrome places it); it opens the tab like any other.
    self.tabButtons[kTabLogout].accessibilityLabel = @"Logout";
    TabGridButton *xb = [TabGridButton buttonWithType:UIButtonTypeCustom];
    xb.hidden = YES;
    xb.imageView.contentMode = UIViewContentModeScaleAspectFit;
    xb.imageView.layer.magnificationFilter = kCAFilterNearest;
    xb.contentEdgeInsets = UIEdgeInsetsZero;
    xb.clipsToBounds = NO;
    [xb addTarget:self action:@selector(onTabExpand) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:xb];
    self.tabExpandButton = xb;
    self.tabGridCollapsed = [[NSUserDefaults standardUserDefaults] boolForKey:@"tabGridCollapsed"];
    // The outer column sits under the inner one: collapsed, it slides beneath it and only its edge shows.
    for (int slot = 1; slot < 14; slot += 2) {
        int i = TAB_GRID_ORDER[slot];
        UIButton *outer = (i == kTabSlotExpand) ? self.tabExpandButton : self.tabButtons[i];
        [self.view insertSubview:outer aboveSubview:self.tabFrameView];
    }
    // The column under the door, each stone over the one above it (they overlap by a pixel, as the door's does).
    NSArray<NSString *> *columnLabels = @[ @"Chat", @"Keyboard" ];
    for (int c = 0; c < 2; c++) {
        TabGridButton *cb = [TabGridButton buttonWithType:UIButtonTypeCustom];
        cb.hidden = YES;
        cb.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cb.imageView.layer.magnificationFilter = kCAFilterNearest;
        cb.contentEdgeInsets = UIEdgeInsetsZero;
        cb.clipsToBounds = NO;
        cb.accessibilityLabel = columnLabels[c];
        [cb addTarget:self
                      action:(c == 0 ? @selector(onChatToggle) : @selector(onToggleKeyboard))
            forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:cb];
        if (c == 0)
            self.chatToggleButton = cb;
        else
            self.chatKeyboardButton = cb;
    }
    // Opaque covers over the desktop stones (subviews of the game view, above the blit; non-interactive so the
    // Java proxy click still reaches the real stone beneath).
    self.stoneCovers = [NSMutableArray arrayWithCapacity:14];
    for (int i = 0; i < 14; i++) {
        UIView *cv = [[UIView alloc] init];
        cv.hidden = YES;
        cv.userInteractionEnabled = NO;
        // OSRS dark-UI tone (not stark black) so the covered stones read as game chrome rather than a void.
        cv.backgroundColor = [UIColor colorWithRed:0.12 green:0.105 blue:0.085 alpha:1.0];
        [self.screen addSubview:cv];
        [self.stoneCovers addObject:cv];
    }
    [self buildTabAssets];
    [self registerChatFonts];
    [self buildChatTabs];
    self.chromeVisible = YES;

    // Hidden capture field — placed offscreen (not hidden, so it can still become first responder).
    self.kbField = [[UITextField alloc] initWithFrame:CGRectMake(-200, -200, 10, 10)];
    self.kbField.delegate = self;
    self.kbField.autocorrectionType = UITextAutocorrectionTypeNo;          // raw game input
    self.kbField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.kbField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.kbField.smartQuotesType = UITextSmartQuotesTypeNo;
    self.kbField.smartDashesType = UITextSmartDashesTypeNo;
    self.kbField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.kbField.keyboardType = UIKeyboardTypeASCIICapable;
    self.kbField.returnKeyType = UIReturnKeyDefault;
    // Accessory bar — sits ABOVE the soft keyboard (which covers the bottom-left ⌨ button), so there is
    // always a reachable way to send a chat line and to dismiss the keyboard.
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = YES;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *send = [[UIBarButtonItem alloc]
        initWithTitle:@"Send ⏎" style:UIBarButtonItemStylePlain target:self action:@selector(onKbSend)];
    UIBarButtonItem *hide = [[UIBarButtonItem alloc]
        initWithTitle:@"Hide ⌨︎" style:UIBarButtonItemStyleDone target:self action:@selector(onKbHide)];
    // Paste: types the clipboard's first line into the open field. A UIPasteControl, so no paste prompt.
    self.pasteTarget = [RMPasteTarget new];
    __weak typeof(self) wsPaste = self;
    self.pasteTarget.onText = ^(NSString *text) {
        NSString *line = RMPasteLine(text);
        if (line.length == 0)
            return;
        [JVMLauncher postText:line];
        // Length only - never the pasted content.
        [wsPaste appendLine:[NSString stringWithFormat:@"[shell] paste len=%lu", (unsigned long)line.length]];
    };
    UIPasteControlConfiguration *pasteCfg = [UIPasteControlConfiguration new];
    pasteCfg.displayMode = UIPasteControlDisplayModeIconAndLabel;
    pasteCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    pasteCfg.baseForegroundColor = [UIColor whiteColor];
    pasteCfg.baseBackgroundColor = [UIColor colorWithWhite:0.28 alpha:1.0];
    UIPasteControl *paste = [[UIPasteControl alloc] initWithConfiguration:pasteCfg];
    paste.target = self.pasteTarget;
    paste.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [paste.widthAnchor constraintEqualToConstant:104],
        [paste.heightAnchor constraintEqualToConstant:34],
    ]];
    UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc] initWithCustomView:paste];
    bar.items = @[ pasteItem, flex, send, hide ];
    [bar sizeToFit];
    self.kbField.inputAccessoryView = bar;
    [self.view addSubview:self.kbField];

    // (1) Debug panel — overlay ABOVE the game (so the launch button is tappable; the old bug was the
    // full-screen game view covering it), translucent so the game shows behind. Collapsed by the ≡ toggle.
    self.debugPanel = [[UIView alloc] init];
    self.debugPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.debugPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    self.debugPanel.layer.cornerRadius = 10;
    self.debugPanel.clipsToBounds = YES;
    self.debugPanel.hidden = YES;   // #1: hidden by default — the ≡ toggle reveals the W1 scaffolding on demand
    [self.view addSubview:self.debugPanel];

    // Row 1 — JIT status line (coloured: amber while waiting, green once CS_DEBUGGED). Driven by the JIT poller.
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [UIColor systemYellowColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    self.statusLabel.text = @"JIT: waiting…";
    [self.debugPanel addSubview:self.statusLabel];

    // Row 2 — live diagnostics readout (JVM / renderer / FPS / memory / session / bridge / build). Refreshed
    // by refreshDevDiagnostics from the JIT poller (pre-launch) and the display tick (in-game), only while shown.
    self.diagLabel = [[UILabel alloc] init];
    self.diagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.diagLabel.numberOfLines = 0;
    self.diagLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.diagLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.diagLabel.text = @"(diagnostics appear here)";
    self.diagLabel.userInteractionEnabled = YES; // tap the readout to copy a full report
    [self.diagLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(onCopyReport)]];
    [self.debugPanel addSubview:self.diagLabel];

    // Row 3 — primary boot. The Tap-to-Play cover is the normal entry point; this is the dev boot for when the
    // panel is revealed directly (triple-tap on the cover). Enabled once the StikDebug attach flips CS_DEBUGGED.
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"Start game" forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.launchButton.enabled = NO;
    [self.launchButton addTarget:self
                          action:@selector(onLaunch)
                forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.launchButton];

    // Row 4 — dev actions, in one horizontal row: JIT self-test + log tools (copy / clear / share the file).
    self.canaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.canaryButton setTitle:@"Test JIT" forState:UIControlStateNormal];
    self.canaryButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [self.canaryButton addTarget:self action:@selector(onCanary) forControlEvents:UIControlEventTouchUpInside];

    UIButton *copyLog = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyLog setTitle:@"Copy log" forState:UIControlStateNormal];
    copyLog.titleLabel.font = [UIFont systemFontOfSize:14];
    [copyLog addTarget:self action:@selector(onCopyLog) forControlEvents:UIControlEventTouchUpInside];

    UIButton *clearLog = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearLog setTitle:@"Clear" forState:UIControlStateNormal];
    clearLog.titleLabel.font = [UIFont systemFontOfSize:14];
    [clearLog addTarget:self action:@selector(onClearLog) forControlEvents:UIControlEventTouchUpInside];

    UIButton *shareLog = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareLog setTitle:@"Share" forState:UIControlStateNormal];
    shareLog.titleLabel.font = [UIFont systemFontOfSize:14];
    [shareLog addTarget:self action:@selector(onShareLog) forControlEvents:UIControlEventTouchUpInside];

    self.devActionRow = [[UIStackView alloc] initWithArrangedSubviews:@[ self.canaryButton, copyLog, clearLog, shareLog ]];
    self.devActionRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.devActionRow.axis = UILayoutConstraintAxisHorizontal;
    self.devActionRow.distribution = UIStackViewDistributionFillEqually;
    self.devActionRow.alignment = UIStackViewAlignmentCenter;
    self.devActionRow.spacing = 4;
    [self.debugPanel addSubview:self.devActionRow];

    // Row 4b — inspectors / tests: dump the HUD snapshot, toggle the perf overlay, exercise the reconnect UI.
    UIButton *snapBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [snapBtn setTitle:@"Snapshot" forState:UIControlStateNormal];
    snapBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [snapBtn addTarget:self action:@selector(onDumpSnapshot) forControlEvents:UIControlEventTouchUpInside];

    self.perfHudButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.perfHudButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [self.perfHudButton addTarget:self action:@selector(onTogglePerfOverlay) forControlEvents:UIControlEventTouchUpInside];

    UIButton *reconnBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [reconnBtn setTitle:@"Reconnect" forState:UIControlStateNormal];
    reconnBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [reconnBtn addTarget:self action:@selector(onReconnectTest) forControlEvents:UIControlEventTouchUpInside];

    // Parity with Android's DEBUG Shift long-press: publish a host-origin notification through the shared
    // bridge to exercise the whole delivery path (queue -> drain -> OS notification) without an in-game trigger.
    UIButton *notifBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [notifBtn setTitle:@"Test notif" forState:UIControlStateNormal];
    notifBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [notifBtn addTarget:self action:@selector(onTestNotification) forControlEvents:UIControlEventTouchUpInside];

    self.devActionRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[ snapBtn, self.perfHudButton, reconnBtn, notifBtn ]];
    self.devActionRow2.translatesAutoresizingMaskIntoConstraints = NO;
    self.devActionRow2.axis = UILayoutConstraintAxisHorizontal;
    self.devActionRow2.distribution = UIStackViewDistributionFillEqually;
    self.devActionRow2.alignment = UIStackViewAlignmentCenter;
    self.devActionRow2.spacing = 4;
    [self.debugPanel addSubview:self.devActionRow2];

    // The compact perf overlay — a small chip over the game (top-leading, safe-area). Hidden unless the player
    // turns it on (persisted). It updates from refreshDevDiagnostics even while the panel is closed.
    self.perfOverlay = [[UILabel alloc] init];
    self.perfOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.perfOverlay.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
    self.perfOverlay.textColor = [UIColor systemGreenColor];
    self.perfOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.perfOverlay.layer.cornerRadius = 5;
    self.perfOverlay.clipsToBounds = YES;
    self.perfOverlay.text = @" — fps ";
    self.perfOverlay.hidden = YES;
    [self.view addSubview:self.perfOverlay];
    [self applyPerfOverlayState]; // reflect the saved toggle onto the overlay + the button title

    // Row 5 — the live log console.
    self.console = [[UITextView alloc] init];
    self.console.translatesAutoresizingMaskIntoConstraints = NO;
    self.console.editable = NO;
    self.console.backgroundColor = [UIColor clearColor];
    self.console.textColor = [UIColor greenColor];
    self.console.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.debugPanel addSubview:self.console];

    // Close (✕) — the panel covers the ⚙ gear, so without this there's no way back to Settings to hide it.
    // Added last so it sits above the console; anchored to the panel's top-right corner.
    self.debugClose = [UIButton buttonWithType:UIButtonTypeSystem];
    self.debugClose.translatesAutoresizingMaskIntoConstraints = NO;
    [self.debugClose setTitle:@"✕" forState:UIControlStateNormal];
    self.debugClose.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.debugClose.tintColor = [UIColor whiteColor];
    self.debugClose.accessibilityLabel = @"Close developer panel";
    [self.debugClose addTarget:self action:@selector(onCloseDebug) forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.debugClose];

    // (2) Debug toggle — always on top (added last), top-right. Expands/collapses the debug panel so the
    // game can stay full-screen.
    self.debugToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    self.debugToggle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.debugToggle setTitle:@"≡" forState:UIControlStateNormal];
    self.debugToggle.accessibilityLabel = @"Debug panel";
    self.debugToggle.accessibilityHint = @"Shows or hides the developer log";
    self.debugToggle.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.debugToggle.tintColor = [UIColor whiteColor];
    self.debugToggle.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.debugToggle.layer.cornerRadius = 8;
    [self.debugToggle addTarget:self action:@selector(onToggleDebug)
               forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.debugToggle];

    // Chrome rails toggle — always on top, left of the ≡ toggle. Shows/hides the native tab rails (A/B).
    self.chromeToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    self.chromeToggle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chromeToggle setTitle:@"▦" forState:UIControlStateNormal];
    self.chromeToggle.accessibilityLabel = @"Game interface rails";
    self.chromeToggle.accessibilityHint = @"Shows or hides the tab rails";
    self.chromeToggle.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.chromeToggle.tintColor = [UIColor whiteColor];
    self.chromeToggle.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.chromeToggle.layer.cornerRadius = 8;
    [self.chromeToggle addTarget:self action:@selector(onToggleChrome)
                forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.chromeToggle];

    // Plugin/config panel opener — a ⚙ gear, left of the ▦ chrome toggle. Separate from the ≡ debug panel.
    self.pluginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.pluginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pluginButton setTitle:@"⚙" forState:UIControlStateNormal];
    self.pluginButton.accessibilityLabel = @"Plugin settings";
    self.pluginButton.accessibilityHint = @"Opens plugin configuration; long press to change interface size";
    self.pluginButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.pluginButton.tintColor = [UIColor whiteColor];
    self.pluginButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.pluginButton.layer.cornerRadius = 8;
    [self.pluginButton addTarget:self action:@selector(onOpenPluginPanel)
                forControlEvents:UIControlEventTouchUpInside];
    // DISP-1: long-press ⚙ to pick the interface size (Small/Default/Large).
    UILongPressGestureRecognizer *gearLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onInterfaceSizePicker:)];
    [self.pluginButton addGestureRecognizer:gearLp];
    [self.view addSubview:self.pluginButton];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    UILayoutGuide *sg = self.screen.safeAreaLayoutGuide;
    UILayoutGuide *p = self.debugPanel.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        // Game fills the WHOLE screen EDGE-TO-EDGE (A1). The OSRS corner HUD (chat/minimap/orbs) used to clip
        // under the island/corners/home-indicator here — that is now fixed by RELOCATING the engine HUD into the
        // safe area (updateHudLayout), so the scene can own every pixel. Render aspect is computed from the full
        // bounds (onLaunch) so there is no internal letterbox.
        [self.screen.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.screen.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.screen.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.screen.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        // Settings gear — bottom-left corner of the safe area. The ONLY always-on control; the pinned-controls
        // stack packs in a row directly to its right (first row aligned to the gear, extra rows wrap upward).
        [self.settingsButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor
                                                         constant:-8],
        [self.settingsButton.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                          constant:8],
        [self.settingsButton.widthAnchor constraintEqualToConstant:44],
        [self.settingsButton.heightAnchor constraintEqualToConstant:36],
        [self.controlsBox.bottomAnchor constraintEqualToAnchor:self.settingsButton.bottomAnchor],
        [self.controlsBox.leadingAnchor constraintEqualToAnchor:self.settingsButton.trailingAnchor
                                                       constant:8],

        // Always-on keyboard toggle — near the top-centre of the safe area (keyboard-safe: the soft keyboard
        // rises from the bottom and never reaches here), nudged 25px right of centre.
        [self.kbFab.topAnchor constraintEqualToAnchor:g.topAnchor
                                             constant:8],
        [self.kbFab.centerXAnchor constraintEqualToAnchor:g.centerXAnchor
                                                 constant:25],
        [self.kbFab.widthAnchor constraintEqualToConstant:44],
        [self.kbFab.heightAnchor constraintEqualToConstant:36],

        // World-map ✕ close: top-right of the safe area (empty while the map's chrome-hide clears the gear/
        // controls/kbFab/dock). Same icon-button metrics as the others.
        [self.closeMapButton.topAnchor constraintEqualToAnchor:g.topAnchor
                                                      constant:8],
        [self.closeMapButton.trailingAnchor constraintEqualToAnchor:g.trailingAnchor
                                                           constant:-8],
        [self.closeMapButton.widthAnchor constraintEqualToConstant:44],
        [self.closeMapButton.heightAnchor constraintEqualToConstant:36],

        // Layout switch: centred under the keyboard toggle (which sits 8 + 36 below the safe top).
        [self.layoutSwitchButton.topAnchor constraintEqualToAnchor:g.topAnchor
                                                          constant:52],
        [self.layoutSwitchButton.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [self.layoutSwitchButton.heightAnchor constraintEqualToConstant:40],

        // (Legacy cluster constraints below stay valid but the buttons are hidden — see hideLegacyCluster.)
        // In-game keyboard control — first row of the legacy cluster.
        [self.keyboardButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor
                                                         constant:-8],
        [self.keyboardButton.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                          constant:8],
        [self.keyboardButton.widthAnchor constraintEqualToConstant:44],
        [self.keyboardButton.heightAnchor constraintEqualToConstant:36],

        // Sticky-Shift toggle — same row, just right of the keyboard button.
        [self.shiftButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.bottomAnchor],
        [self.shiftButton.leadingAnchor constraintEqualToAnchor:self.keyboardButton.trailingAnchor
                                                       constant:8],
        [self.shiftButton.widthAnchor constraintEqualToConstant:44],
        [self.shiftButton.heightAnchor constraintEqualToConstant:36],

        // PARITY-IOS-LATCH: sticky-Ctrl toggle — same row, right of the shift button.
        [self.ctrlButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.bottomAnchor],
        [self.ctrlButton.leadingAnchor constraintEqualToAnchor:self.shiftButton.trailingAnchor
                                                      constant:8],
        [self.ctrlButton.widthAnchor constraintEqualToConstant:44],
        [self.ctrlButton.heightAnchor constraintEqualToConstant:36],

        // Screenshot button — same row, right of the ctrl button (the sticky-Alt latch was removed).
        [self.screenshotButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.bottomAnchor],
        [self.screenshotButton.leadingAnchor constraintEqualToAnchor:self.ctrlButton.trailingAnchor
                                                            constant:8],
        [self.screenshotButton.widthAnchor constraintEqualToConstant:44],
        [self.screenshotButton.heightAnchor constraintEqualToConstant:36],

        // Picture-in-Picture button — same row, right of the screenshot button.
        [self.pipButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.bottomAnchor],
        [self.pipButton.leadingAnchor constraintEqualToAnchor:self.screenshotButton.trailingAnchor
                                                     constant:8],
        [self.pipButton.widthAnchor constraintEqualToConstant:44],
        [self.pipButton.heightAnchor constraintEqualToConstant:36],

        // KEY-1: ⚡ hotkey-strip toggle — same bottom row, right of PiP.
        [self.hotkeyButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.bottomAnchor],
        [self.hotkeyButton.leadingAnchor constraintEqualToAnchor:self.pipButton.trailingAnchor
                                                        constant:8],
        [self.hotkeyButton.widthAnchor constraintEqualToConstant:44],
        [self.hotkeyButton.heightAnchor constraintEqualToConstant:36],
        // The pinned-hotkey strip sits one row up, starting at the ⇧ button (clear of the ⚙▦≡ stack on the left).
        [self.hotkeyStrip.bottomAnchor constraintEqualToAnchor:self.keyboardButton.topAnchor
                                                      constant:-8],
        [self.hotkeyStrip.leadingAnchor constraintEqualToAnchor:self.shiftButton.leadingAnchor],
        [self.hotkeyStrip.heightAnchor constraintEqualToConstant:36],

        // Utility trio (⚙ ▦ ≡) — moved OUT of the top-right, where it overlapped the engine XP counter + minimap
        // orbs (the XP button lives in the left part of the relocated MAP_CONTAINER cluster, and XP-drop numbers
        // expand left into the trio). Now a vertical stack in the BOTTOM-LEFT above the keyboard button, over the
        // scene and clear of every relocated HUD element (chat top-left, minimap/orbs/XP top-right, inventory
        // bottom-right). Bottom-up order: keyboard, then ⚙, ▦, ≡.
        [self.pluginButton.bottomAnchor constraintEqualToAnchor:self.keyboardButton.topAnchor
                                                       constant:-8],
        [self.pluginButton.leadingAnchor constraintEqualToAnchor:self.keyboardButton.leadingAnchor],
        [self.pluginButton.widthAnchor constraintEqualToConstant:44],
        [self.pluginButton.heightAnchor constraintEqualToConstant:36],

        [self.chromeToggle.bottomAnchor constraintEqualToAnchor:self.pluginButton.topAnchor
                                                       constant:-8],
        [self.chromeToggle.leadingAnchor constraintEqualToAnchor:self.keyboardButton.leadingAnchor],
        [self.chromeToggle.widthAnchor constraintEqualToConstant:44],
        [self.chromeToggle.heightAnchor constraintEqualToConstant:36],

        [self.debugToggle.bottomAnchor constraintEqualToAnchor:self.chromeToggle.topAnchor
                                                      constant:-8],
        [self.debugToggle.leadingAnchor constraintEqualToAnchor:self.keyboardButton.leadingAnchor],
        [self.debugToggle.widthAnchor constraintEqualToConstant:44],
        [self.debugToggle.heightAnchor constraintEqualToConstant:36],

        // Debug panel — left ~62% of the safe area, full height, below the toggle row.
        [self.debugPanel.topAnchor constraintEqualToAnchor:g.topAnchor
                                                  constant:8],
        [self.debugPanel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                      constant:8],
        [self.debugPanel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor
                                                     constant:-8],
        [self.debugPanel.widthAnchor constraintEqualToAnchor:g.widthAnchor
                                                  multiplier:0.62],

        // Close (✕) — top-right corner of the panel, level with the status line.
        [self.debugClose.topAnchor constraintEqualToAnchor:p.topAnchor],
        [self.debugClose.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.debugClose.widthAnchor constraintEqualToConstant:36],
        [self.debugClose.heightAnchor constraintEqualToConstant:32],

        // Panel contents — stacked top to bottom: JIT status, diagnostics, Start, the action row, then the log.
        [self.statusLabel.topAnchor constraintEqualToAnchor:p.topAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.debugClose.leadingAnchor
                                                        constant:-8],
        [self.diagLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor
                                                 constant:4],
        [self.diagLabel.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.diagLabel.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.launchButton.topAnchor constraintEqualToAnchor:self.diagLabel.bottomAnchor
                                                    constant:6],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.devActionRow.topAnchor constraintEqualToAnchor:self.launchButton.bottomAnchor
                                                    constant:6],
        [self.devActionRow.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.devActionRow.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.devActionRow2.topAnchor constraintEqualToAnchor:self.devActionRow.bottomAnchor
                                                     constant:2],
        [self.devActionRow2.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.devActionRow2.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.console.topAnchor constraintEqualToAnchor:self.devActionRow2.bottomAnchor
                                               constant:6],
        [self.console.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.console.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.console.bottomAnchor constraintEqualToAnchor:p.bottomAnchor],

        // Perf overlay chip — top-leading of the safe area, over the game (only visible when toggled on).
        [self.perfOverlay.topAnchor constraintEqualToAnchor:g.topAnchor
                                                   constant:6],
        [self.perfOverlay.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                       constant:6],
        [self.perfOverlay.heightAnchor constraintEqualToConstant:20],
    ]];

    [self refreshLoginButton]; // reflect any already-saved session on the launch-screen login row

    // Fresh screen: hide the entire legacy bottom-left cluster (it stays in the hierarchy, inert, so its
    // constraints and action methods keep working when a control is pinned). Then restore dev mode + build
    // whatever the player has pinned. Only the ⚙ gear shows until they pin something.
    [self hideLegacyCluster];
    self.developerMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"developerMode"];
    [self applyDeveloperMode];
    [self rebuildPinnedControls];
    // Keep the keyboard toggle above the (top-left, dev-only) debug panel so it never hides behind it.
    [self.screen bringSubviewToFront:self.kbFab];
}

// The legacy always-on cluster (keyboard/shift/ctrl/screenshot/PiP/hotkey + the ≡▦⚙ column + the handle).
// These stay in the view hierarchy — their action methods and latch styling still reference them — but they
// never show; the new system drives everything through the ⚙ gear and the pinned-controls stack.
- (void)hideLegacyCluster {
    NSArray<UIView *> *legacy = @[ self.keyboardButton, self.shiftButton, self.ctrlButton, self.screenshotButton,
                                   self.pipButton, self.hotkeyButton, self.pluginButton, self.chromeToggle,
                                   self.debugToggle ];
    for (UIView *v in legacy)
        v.hidden = YES;
}

#pragma mark - Pinned on-screen controls (player-customisable)

// Every control the player can sticky to the screen, in canonical order and grouped by section. `kind`:
//   latch  — sticky modifier held via the bridge (Shift/Ctrl), amber while held
//   key    — momentary AWT keystroke (F-keys, arrows, Esc/Enter/Space/Tab, digits)
//   util   — a native action button (keyboard, screenshot, PiP, hotkey strip)
- (NSArray<NSDictionary *> *)allControlSpecs {
    static NSArray *specs = nil;
    if (specs)
        return specs;
    NSMutableArray *m = [NSMutableArray array];
    void (^add)(NSString *, NSString *, NSString *, NSString *, int) =
        ^(NSString *sec, NSString *cid, NSString *glyph, NSString *kind, int vk) {
            [m addObject:@{@"section" : sec, @"id" : cid, @"glyph" : glyph, @"kind" : kind, @"vk" : @(vk)}];
        };
    add(@"Modifiers", @"shift", @"⇧", @"latch", 0);
    add(@"Modifiers", @"ctrl", @"⌃", @"latch", 0);
    // The ⌨︎ keyboard toggle is NOT pinnable — it's a permanent top-centre FAB (self.kbFab), so pinning a
    // second copy at the covered bottom-left would defeat the point. Its util handler below stays for any
    // stale pin already saved (it just no-ops out of the palette).
    add(@"Common", @"space", @"Space", @"key", AWT_VK_SPACE);
    add(@"Common", @"enter", @"Enter", @"key", AWT_VK_ENTER);
    add(@"Common", @"esc", @"Esc", @"key", AWT_VK_ESCAPE);
    add(@"Common", @"tab", @"Tab", @"key", AWT_VK_TAB);
    for (int i = 1; i <= 12; i++)
        add(@"Tabs (F-keys)", ([NSString stringWithFormat:@"f%d", i]),
            ([NSString stringWithFormat:@"F%d", i]), @"key", 111 + i); // VK_F1==112
    for (int i = 1; i <= 9; i++)
        add(@"Numbers", ([NSString stringWithFormat:@"num%d", i]),
            ([NSString stringWithFormat:@"%d", i]), @"key", AWT_VK_0 + i);
    add(@"Numbers", @"num0", @"0", @"key", AWT_VK_0);
    // Held camera controls, not key strokes: the engine does not act on a synthesized arrow, and a momentary
    // press could not turn a camera that moves while a key is DOWN. The vk is kept as the direction tag.
    add(@"Camera", @"left", @"←", @"cam", AWT_VK_LEFT);
    add(@"Camera", @"up", @"↑", @"cam", AWT_VK_UP);
    add(@"Camera", @"right", @"→", @"cam", AWT_VK_RIGHT);
    add(@"Camera", @"down", @"↓", @"cam", AWT_VK_DOWN);
    add(@"Utility", @"screenshot", @"📷", @"util", 0);
    add(@"Utility", @"pip", @"📺", @"util", 0);
    add(@"Utility", @"hotkeys", @"⚡", @"util", 0);
    add(@"Utility", @"worldmap", @"🗺", @"util", 0);
    specs = [m copy];
    return specs;
}

- (NSDictionary *)controlSpecForId:(NSString *)cid {
    for (NSDictionary *s in [self allControlSpecs])
        if ([s[@"id"] isEqualToString:cid])
            return s;
    return nil;
}

- (NSArray<NSString *> *)pinnedControlIds {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:@"pinnedControls"];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
- (void)setPinnedControlIds:(NSArray<NSString *> *)ids {
    [[NSUserDefaults standardUserDefaults] setObject:(ids ?: @[]) forKey:@"pinnedControls"];
    [self rebuildPinnedControls];
}
- (BOOL)isControlPinned:(NSString *)cid {
    return [[self pinnedControlIds] containsObject:cid];
}
- (void)setControl:(NSString *)cid pinned:(BOOL)pinned {
    // Unpinning a latched modifier would otherwise leave it held with no button to release it — the engine
    // would stay in shift/ctrl mode invisibly. Drop the bridge latch before the button disappears.
    if (!pinned) {
        if ([cid isEqualToString:@"shift"] && self.shiftHeld) {
            self.shiftHeld = NO;
            [JVMLauncher postShiftHeld:NO];
            [self appendLine:@"[shell] Shift released (unpinned)"];
        } else if ([cid isEqualToString:@"ctrl"] && self.ctrlHeld) {
            self.ctrlHeld = NO;
            [JVMLauncher postCtrlHeld:NO];
            [self appendLine:@"[shell] Control released (unpinned)"];
        } else if ([cid isEqualToString:@"hotkeys"] && self.hotkeyStripVisible) {
            // Unpinning ⚡ while its strip is open would strand the strip with no toggle — close it too.
            self.hotkeyStripVisible = NO;
            self.hotkeyStrip.hidden = YES;
        }
    }
    NSMutableArray *ids = [[self pinnedControlIds] mutableCopy];
    if (pinned) {
        if (![ids containsObject:cid])
            [ids addObject:cid];
    } else {
        [ids removeObject:cid];
    }
    [self setPinnedControlIds:ids];
}

// Build a single pinned control button from its spec, styled like the legacy cluster and wired to fire.
- (UIButton *)makePinnedButtonForSpec:(NSDictionary *)spec {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *cid = spec[@"id"];
    NSString *glyph = spec[@"glyph"];
    BOOL wide = (glyph.length > 2); // word labels (Space/Enter/Esc/Tab) get a wider pill
    b.titleLabel.font = wide ? [UIFont boldSystemFontOfSize:14] : [UIFont boldSystemFontOfSize:20];
    [b setTitle:glyph forState:UIControlStateNormal];
    b.accessibilityLabel = cid;
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    b.layer.cornerRadius = 8;
    [b.widthAnchor constraintEqualToConstant:(wide ? 60 : 44)].active = YES;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    // Rebind the stateful-control properties to THIS live button every rebuild — the old instances were just
    // removed from the stack, so leaving the pointers stale would make onToggleShift/Ctrl/HotkeyStrip style a
    // dead view. For the three that carry visible state, also paint the current state (amber = active) so a
    // rebuild while shift is latched / the hotkey strip is open keeps the on-screen button in sync.
    BOOL active = NO;
    if ([cid isEqualToString:@"shift"]) {
        self.shiftButton = b;
        active = self.shiftHeld;
    } else if ([cid isEqualToString:@"ctrl"]) {
        self.ctrlButton = b;
        active = self.ctrlHeld;
    } else if ([cid isEqualToString:@"hotkeys"]) {
        self.hotkeyButton = b;
        active = self.hotkeyStripVisible;
        // Match the legacy ⚡: long-press reopens the hotkey picker (tap only toggles the strip, so without
        // this a user who already has hotkeys pinned could never edit the set).
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(onHotkeyPicker:)];
        [b addGestureRecognizer:lp];
    } else if ([cid isEqualToString:@"screenshot"]) {
        // Preserve SHOT-4: long-press the pinned 📷 toggles auto-saving the engine's event screenshots.
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(onScreenshotLongPress:)];
        [b addGestureRecognizer:lp];
    }
    if (active) {
        b.backgroundColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.92];
        b.tintColor = [UIColor blackColor];
    }
    objc_setAssociatedObject(b, "rmSpec", spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([spec[@"kind"] isEqualToString:@"cam"]) {
        // A hold needs both edges, and EVERY way a touch can end has to release it -- a cancel (an incoming
        // call, the app going away mid-press) included, or the camera would keep turning with nothing held.
        [b addTarget:self action:@selector(onCameraHoldBegin:) forControlEvents:UIControlEventTouchDown];
        [b addTarget:self
                      action:@selector(onCameraHoldEnd:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                             UIControlEventTouchCancel | UIControlEventTouchDragExit];
        return b;
    }
    [b addTarget:self action:@selector(onPinnedControlTapped:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Fire the tapped pinned control by its spec: latch → toggle held; key → momentary keystroke; util → route to
// the existing native action (which owns the keyboard field / screenshot / PiP / hotkey strip).
// Turn rate for a held arrow, as the pixel-per-second rate the two-finger drag path already speaks: the
// bridge converts it per frame, so these are real rates and not per-frame steps that would track the frame
// rate. Signs follow a drag -- positive x turns as dragging right, positive y tilts down.
static const int kCamYawPxPerSec = 320;
static const int kCamPitchPxPerSec = 200;

- (void)onCameraHoldBegin:(UIButton *)b {
    NSDictionary *spec = objc_getAssociatedObject(b, "rmSpec");
    const int vk = [spec[@"vk"] intValue];
    int dx = 0, dy = 0;
    if (vk == AWT_VK_LEFT)
        dx = -kCamYawPxPerSec;
    else if (vk == AWT_VK_RIGHT)
        dx = kCamYawPxPerSec;
    else if (vk == AWT_VK_UP)
        dy = -kCamPitchPxPerSec;
    else if (vk == AWT_VK_DOWN)
        dy = kCamPitchPxPerSec;
    [JVMLauncher setCameraHoldDxPerSec:dx dyPerSec:dy];
    [self appendLine:[NSString stringWithFormat:@"[shell] camera hold %@ dx=%d dy=%d", spec[@"glyph"], dx, dy]];
}

- (void)onCameraHoldEnd:(UIButton *)b {
    [JVMLauncher setCameraHoldDxPerSec:0 dyPerSec:0];
}

// Route a key button to the dialogue action it is standing in for, returning YES if it was consumed.
//
// These buttons exist to do what their keys do in the game, and a dialogue does not answer to a key here: a
// synthesized one reaches the gamepack's listener and comes back consumed without moving the conversation
// (device-confirmed). The dialogue tap already drives the engine's own handler, so Space and the numbers are
// pointed at the same handler while a dialogue is open, and still send a keystroke for everything else.
//
// Text entry outranks both: while the game is asking for text, a digit is a digit and a space is a space.
- (BOOL)routeDialogueKey:(int)vk {
    if (!self.dialogueTargetsKnown || [JVMLauncher textInputOpen])
        return NO;
    if (self.dialogueIsOptions) {
        const int n = vk - AWT_VK_0;
        if (n < 1 || n > 9)
            return NO;
        // The pressed number is the option's POSITION as drawn, which is how the game labels the rows. It is
        // not the published digit: that is the engine's child index, and a blank padding row would shift it.
        if ((NSUInteger)n > self.dialogueOptionDigits.count) {
            [self appendLine:[NSString stringWithFormat:@"[shell] dialogue key %d (no such option)", n]];
            return YES; // an options menu with no such row: swallow rather than emit a stray keystroke
        }
        NSNumber *digit = self.dialogueOptionDigits[n - 1];
        [JVMLauncher selectEngineDialogueOption:digit.intValue seq:self.dialogueTargetsSeq];
        [self appendLine:[NSString stringWithFormat:@"[shell] dialogue option %@ key %d (op)", digit, n]];
        return YES;
    }
    if (vk != AWT_VK_SPACE)
        return NO;
    [JVMLauncher continueEngineDialogue];
    [self appendLine:@"[shell] dialogue continue key (continue)"];
    return YES;
}

- (void)onPinnedControlTapped:(UIButton *)b {
    NSDictionary *spec = objc_getAssociatedObject(b, "rmSpec");
    NSString *kind = spec[@"kind"];
    NSString *cid = spec[@"id"];
    if ([kind isEqualToString:@"latch"]) {
        if ([cid isEqualToString:@"shift"]) {
            self.shiftButton = b;
            [self onToggleShift];
        } else if ([cid isEqualToString:@"ctrl"]) {
            self.ctrlButton = b;
            [self onToggleCtrl];
        }
    } else if ([kind isEqualToString:@"key"]) {
        const int vk = [spec[@"vk"] intValue];
        if ([self routeDialogueKey:vk])
            return;
        [JVMLauncher postKeyStroke:vk];
        [self appendLine:[NSString stringWithFormat:@"[shell] key %@", spec[@"glyph"]]];
    } else if ([kind isEqualToString:@"util"]) {
        if ([cid isEqualToString:@"keyboard"])
            [self onToggleKeyboard];
        else if ([cid isEqualToString:@"screenshot"])
            [self onScreenshot];
        else if ([cid isEqualToString:@"pip"])
            [self onTogglePip];
        else if ([cid isEqualToString:@"hotkeys"]) {
            self.hotkeyButton = b;
            [self onToggleHotkeyStrip];
        } else if ([cid isEqualToString:@"worldmap"]) {
            [JVMLauncher openEngineWorldMap];
            [self appendLine:@"[shell] world map -> openWorldMap"];
        }
    }
}

// Rebuild the corner stack from the pinned list. Buttons wrap into rows (max 4 wide) so pinning many keys
// grows the stack upward without ever running off the right edge.
- (void)rebuildPinnedControls {
    for (UIView *row in self.controlsBox.arrangedSubviews) {
        [self.controlsBox removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    NSArray<NSString *> *pinned = [self pinnedControlIds];
    // Emit in canonical spec order (not pin order) so the layout is stable regardless of pin sequence.
    NSMutableArray<NSDictionary *> *live = [NSMutableArray array];
    for (NSDictionary *s in [self allControlSpecs])
        if ([pinned containsObject:s[@"id"]])
            [live addObject:s];
    // Bound the stack's HEIGHT, not its width: 4 per row normally, but once the player pins enough to exceed
    // maxRows we widen the rows instead of growing taller (the screen is landscape, so horizontal room is
    // plentiful and vertical room — between the gear and the safe-area top — is the scarce axis). Pinning all
    // ~36 controls yields 5 rows of 8 rather than 9 rows that would run off the top of the screen.
    const NSUInteger maxRows = 5;
    NSUInteger perRow = 4;
    if (live.count > maxRows * perRow)
        perRow = (live.count + maxRows - 1) / maxRows;
    UIStackView *row = nil;
    for (NSUInteger i = 0; i < live.count; i++) {
        if (i % perRow == 0) {
            row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.spacing = 8;
            row.alignment = UIStackViewAlignmentCenter;
            [self.controlsBox addArrangedSubview:row];
        }
        [row addArrangedSubview:[self makePinnedButtonForSpec:live[i]]];
    }
}

- (void)onToggleDebug {
    self.debugPanel.hidden = !self.debugPanel.hidden;
}

// ✕ in the panel corner. Hide the panel; if it was opened pre-launch via the triple-tap (the launch cover is
// still around), bring that cover back so the user isn't dropped onto a not-yet-started game with no way in.
- (void)onCloseDebug {
    self.debugPanel.hidden = YES;
    if (!self.launched && self.launchScreen) {
        self.launchScreen.hidden = NO;
        [self.view bringSubviewToFront:self.launchScreen];
    }
}

#pragma mark - Developer mode

// Developer mode gates the dev-only surfaces. When OFF (default) the debug panel is hidden and can't be
// summoned; when ON, Settings exposes "Show debug panel".
- (void)applyDeveloperMode {
    if (!self.developerMode)
        self.debugPanel.hidden = YES;
    [self applyPerfOverlayState]; // the perf overlay is a dev surface too — it must vanish when dev mode is off
}
- (void)setDeveloperModeEnabled:(BOOL)on {
    self.developerMode = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"developerMode"];
    [self applyDeveloperMode];
}

#pragma mark - Settings + Edit-controls entry points

- (void)onOpenSettings {
    RMSettingsViewController *vc = [[RMSettingsViewController alloc] init];
    __weak ViewController *ws = self;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    vc.railsOn = self.chromeVisible;
    vc.pluginRailOn = !([ud objectForKey:@"rightBarRailHidden"] != nil && [ud boolForKey:@"rightBarRailHidden"]);
    vc.debugOn = !self.debugPanel.hidden;
    vc.developerMode = self.developerMode;
    vc.profilesAvailable = [JVMLauncher profilesAvailable];
    vc.infoBoxAvailable = [JVMLauncher infoBoxAvailable];
    vc.onEditControls = ^{
        [ws onEditControls];
    };
    vc.onOpenPlugins = ^{
        [ws onOpenPluginPanel];
    };
    vc.onOpenProfiles = ^{
        [ws.panelDock presentConfigProfiles];
    };
    vc.onOpenInfoboxes = ^{
        [ws.panelDock presentInfoboxes];
    };
    vc.onToggleRails = ^(BOOL on) {
        if (on != ws.chromeVisible)
            [ws onToggleChrome];
    };
    vc.onTogglePluginRail = ^(BOOL on) {
        [[NSUserDefaults standardUserDefaults] setBool:!on forKey:@"rightBarRailHidden"];
        ws.panelDock.railHidden = !on;
    };
    vc.onToggleDebug = ^(BOOL on) {
        ws.debugPanel.hidden = !on;
    };
    vc.onToggleDeveloper = ^(BOOL on) {
        [ws setDeveloperModeEnabled:on];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

// Enter the visual "Edit controls" overlay: dim the scene and show the full palette; the pinned corner stack
// stays live above the dim so the player sees each pick land. Tap Done (or the backdrop) to finish.
- (void)onEditControls {
    if (self.editOverlay)
        return;
    UIView *ov = [[UIView alloc] initWithFrame:self.view.bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    self.editOverlay = ov;
    [self.view addSubview:ov];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"Tap a key to add it to your screen. Tap again to remove it.";
    hint.font = [UIFont systemFontOfSize:14];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    hint.numberOfLines = 0;
    [ov addSubview:hint];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    done.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [done addTarget:self action:@selector(onEditControlsDone) forControlEvents:UIControlEventTouchUpInside];
    [ov addSubview:done];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [ov addSubview:scroll];

    UIStackView *col = [[UIStackView alloc] init];
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;
    col.alignment = UIStackViewAlignmentLeading;
    [scroll addSubview:col];
    [self buildEditPaletteInto:col];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [done.topAnchor constraintEqualToAnchor:sg.topAnchor
                                       constant:8],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor
                                            constant:-16],
        [hint.centerYAnchor constraintEqualToAnchor:done.centerYAnchor],
        [hint.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor
                                           constant:16],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:done.leadingAnchor
                                                      constant:-12],
        [scroll.topAnchor constraintEqualToAnchor:done.bottomAnchor
                                         constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor
                                             constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor
                                              constant:-16],
        [scroll.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor
                                            constant:-12],
        [col.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [col.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [col.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [col.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    ]];
}

// Lay out the palette: one section label + a wrapped run of chips per group, in spec order.
- (void)buildEditPaletteInto:(UIStackView *)col {
    NSString *curSection = nil;
    UIStackView *row = nil;
    NSUInteger inRow = 0;
    const NSUInteger perRow = 7;
    for (NSDictionary *spec in [self allControlSpecs]) {
        if (![spec[@"section"] isEqualToString:curSection]) {
            curSection = spec[@"section"];
            UILabel *hdr = [[UILabel alloc] init];
            hdr.text = [curSection uppercaseString];
            hdr.font = [UIFont boldSystemFontOfSize:12];
            hdr.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
            [col addArrangedSubview:hdr];
            row = nil;
            inRow = 0;
        }
        if (!row || inRow == perRow) {
            row = [[UIStackView alloc] init];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.spacing = 8;
            row.alignment = UIStackViewAlignmentCenter;
            [col addArrangedSubview:row];
            inRow = 0;
        }
        [row addArrangedSubview:[self makePaletteChipForSpec:spec]];
        inRow++;
    }
}

- (UIButton *)makePaletteChipForSpec:(NSDictionary *)spec {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *glyph = spec[@"glyph"];
    BOOL wide = (glyph.length > 2);
    [chip setTitle:glyph forState:UIControlStateNormal];
    chip.titleLabel.font = wide ? [UIFont boldSystemFontOfSize:14] : [UIFont boldSystemFontOfSize:19];
    chip.layer.cornerRadius = 8;
    chip.layer.borderWidth = 1.0;
    [chip.widthAnchor constraintEqualToConstant:(wide ? 62 : 44)].active = YES;
    [chip.heightAnchor constraintEqualToConstant:40].active = YES;
    objc_setAssociatedObject(chip, "rmSpec", spec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self styleChip:chip pinned:[self isControlPinned:spec[@"id"]]];
    [chip addTarget:self action:@selector(onPaletteChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    return chip;
}

// Solid amber = pinned (on your screen); ghosted outline = available to add.
- (void)styleChip:(UIButton *)chip pinned:(BOOL)pinned {
    if (pinned) {
        chip.backgroundColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.95];
        chip.tintColor = [UIColor blackColor];
        chip.layer.borderColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.4 alpha:1.0].CGColor;
    } else {
        chip.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        chip.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        chip.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    }
}

- (void)onPaletteChipTapped:(UIButton *)chip {
    NSDictionary *spec = objc_getAssociatedObject(chip, "rmSpec");
    NSString *cid = spec[@"id"];
    BOOL nowPinned = ![self isControlPinned:cid];
    [self setControl:cid pinned:nowPinned]; // persists + rebuilds the live corner stack
    [self styleChip:chip pinned:nowPinned];
}

- (void)onEditControlsDone {
    [self.editOverlay removeFromSuperview];
    self.editOverlay = nil;
}

// On-device Jagex login: present the embedded OAuth login, and on success persist the chosen character to
// tokens.json — exactly the file loadJagexTokens (JVMLauncher) reads to arm autologin. Pure native (no
// JVM), so this works before any StikDebug attach: log in here, then attach + Tap to Play.
- (void)onLoginWithJagex {
    JagexLoginViewController *vc = [JagexLoginViewController new];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    self.webKitUsedThisSession = YES;   // the login web view loads WebKit, which can't be unloaded in-process
    __weak typeof(self) ws = self;
    vc.onLog = ^(NSString *line) { [ws appendLine:[@"[login] " stringByAppendingString:line]]; };
    vc.onComplete = ^(NSString *sessionId, NSString *accountId, NSString *displayName, NSArray *accounts) {
        [ws persistTokensSession:sessionId account:accountId display:displayName accounts:accounts];
        [ws refreshLoginButton];
        // WebKit is now resident → the JVM can't start cleanly in this process. Prompt a one-tap restart
        // into a fresh process; the saved tokens.json means the relaunch goes straight to play, no web view.
        [vc dismissViewControllerAnimated:YES completion:^{ [ws promptRestartToPlay]; }];
    };
    [self presentViewController:vc animated:YES completion:nil];
}

// Write tokens.json (Application Support — see +[JVMLauncher tokensPath]) in the shape loadJagexTokens
// reads. Stage A only → access/refresh empty
// (the gamepack mints its own play token from session_id + chosen_account_id). File-protected at rest;
// never bundled or committed (it's the per-device secret).
- (void)persistTokensSession:(NSString *)sessionId account:(NSString *)accountId
                     display:(NSString *)display accounts:(NSArray *)accounts {
    NSString *path = [JVMLauncher tokensPath];
    NSDictionary *t = @{
        @"session_id":          sessionId  ?: @"",
        @"chosen_account_id":   accountId  ?: @"",
        @"chosen_display_name": display    ?: @"",
        @"accounts":            accounts   ?: @[],
        @"access_token":  @"",
        @"refresh_token": @"",
        @"notes": @"Minted on-device by JagexLoginViewController (Stage A). access/refresh empty; the "
                  @"gamepack mints its own play token from session_id + chosen_account_id.",
    };
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:t options:NSJSONWritingPrettyPrinted error:&err];
    if (!data) {
        [self appendLine:[@"[login] tokens.json encode failed: " stringByAppendingString:err.localizedDescription ?: @"?"]];
        return;
    }
    BOOL ok = [data writeToFile:path
                        options:(NSDataWritingAtomic | NSDataWritingFileProtectionComplete)
                          error:&err];
    [self appendLine:ok
                         ? [NSString stringWithFormat:@"[login] tokens.json written - logged in as %@. Attach StikDebug, then Tap to Play.",
                                                      display.length ? display : @"(unnamed)"]
                         : [NSString stringWithFormat:@"[login] tokens.json write FAILED: %@", err.localizedDescription ?: @"?"]];
}

// Reflect the saved login on the button title so the user can see they're signed in (and re-login if needed).
// Account state now lives entirely on the Tap-to-Play cover (log in / switch / forget), so this just keeps
// that row current. Retained as the single call site the login/logout/switch flows already invoke.
- (void)refreshLoginButton {
    [self refreshLaunchLogin];   // #1: keep the Tap-to-Play login row in sync
}

// Log out: delete the saved game session (so autologin won't fire) and purge any persisted Jagex web
// cookies from older builds (the login webview itself is now ephemeral, so it leaves none going forward).
- (void)onLogout {
    [self onLogoutWithCompletion:nil];
}

// PARITY-P0-4: the logout body, with an optional completion that fires (on the main queue) only AFTER the async
// WKWebsiteDataStore cookie purge actually finishes — so an in-game logout can safely exit(0) once the cookies
// are really gone. The pre-launch caller passes nil (it keeps the process alive regardless, as before).
- (void)onLogoutWithCompletion:(void (^)(void))completion {
    NSString *path = [JVMLauncher tokensPath];
    BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (existed) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    [self refreshLoginButton];
    [self refreshLaunchLogin]; // keep the launch-screen account button in sync (logout can come from there now)
    [self appendLine:existed ? @"[login] account forgotten — tokens.json cleared; autologin disarmed."
                             : @"[login] no saved account (no tokens.json)."];

    NSSet *types = [NSSet setWithObjects:WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases, nil];
    WKWebsiteDataStore *ds = [WKWebsiteDataStore defaultDataStore];
    [ds fetchDataRecordsOfTypes:types completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
        NSMutableArray *kill = [NSMutableArray array];
        for (WKWebsiteDataRecord *r in records) {
            NSString *n = r.displayName.lowercaseString ?: @"";
            if ([n containsString:@"jagex"] || [n containsString:@"runescape"]) [kill addObject:r];
        }
        if (kill.count) {
            [ds removeDataOfTypes:types
                   forDataRecords:kill
                completionHandler:^{
                    if (completion)
                        dispatch_async(dispatch_get_main_queue(), completion);
                }];
        } else {
            if (completion)
                dispatch_async(dispatch_get_main_queue(), completion); // nothing to purge
        }
    }];
}

// PARITY-P0-4: the in-game Jagex logout confirm (parity with Android's confirmLogout()). Reachable any time the
// plugin panel is open during live play, unlike the pre-launch-only -onLogout path.
- (void)onInGameJagexLogout {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Log out"
                         message:@"Forget this Jagex session? Deletes the saved login and web cookies, then "
                                 @"restarts to the sign-in screen."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Log out"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
                                            [self performInGameJagexLogout];
                                        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.jagexLogoutButton;
    a.popoverPresentationController.sourceRect = self.jagexLogoutButton.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

// PARITY-P0-4: perform the logout, mirroring Android doLogout()'s ordering (accountLogout + flushConfig BEFORE
// the token/cookie purge and restart). Both iOS bridge calls are fire-and-forget (no completion signal), so give
// them a short grace period, then delete tokens.json + purge cookies (now safely awaited via the Step A
// completion) and exit(0) so the next launch reads an empty tokens.json and lands on the pre-launch login gate.
- (void)performInGameJagexLogout {
    if (self.launched && [JVMLauncher bridgeReady]) {
        [JVMLauncher accountLogout]; // end the RuneLite-account sync session too (parity with Android PROD-SECURITY-10)
        [JVMLauncher mobileFlushConfig];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self onLogoutWithCompletion:^{
            exit(0);
        }];
    });
}

// LOGIN-1: switch to another already-signed-in character without a fresh web OAuth. tokens.json keeps the whole
// account list from the original sign-in; we just rewrite chosen_account_id/display to the picked one and restart
// (the gamepack autologins from chosen_account_id at JVM launch, so a running session can't be re-pointed live).
// If the reused session has since expired, the next launch falls back to the login screen — handled by the
// existing login flow.
- (void)onSwitchCharacter {
    if (self.presentedViewController) return;
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *t = [o isKindOfClass:[NSDictionary class]] ? o : nil;
    NSString *sid = [t[@"session_id"] isKindOfClass:[NSString class]] ? t[@"session_id"] : nil;
    NSArray *accounts = [t[@"accounts"] isKindOfClass:[NSArray class]] ? t[@"accounts"] : nil;
    NSString *curId = [t[@"chosen_account_id"] isKindOfClass:[NSString class]] ? t[@"chosen_account_id"] : @"";
    if (sid.length == 0 || accounts.count < 2) return;   // button is hidden in this case; guard anyway

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Switch character"
        message:@"Reuses your saved login (no re-sign-in). RuneLite restarts to load the chosen character."
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *a in accounts) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *accId = [a[@"accountId"] isKindOfClass:[NSString class]] ? a[@"accountId"] : @"";
        NSString *name  = [a[@"displayName"] isKindOfClass:[NSString class]] ? a[@"displayName"] : @"";
        if (accId.length == 0) continue;
        NSString *label = name.length ? name : [NSString stringWithFormat:@"Unnamed (…%@)",
            accId.length > 4 ? [accId substringFromIndex:accId.length - 4] : accId];
        if ([accId isEqualToString:curId]) label = [@"✓ " stringByAppendingString:label];   // current
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) {
            if ([accId isEqualToString:curId]) return;   // already playing this character
            [self persistTokensSession:sid account:accId display:name accounts:accounts];
            [self appendLine:[NSString stringWithFormat:@"[login] switch character -> %@",
                              name.length ? name : @"(unnamed)"]];
            // Present the restart prompt after the sheet finishes dismissing (avoid present-while-dismissing).
            dispatch_async(dispatch_get_main_queue(), ^{ [self promptRestartToPlay]; });
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // Anchor to the bottom-centre of the view (this is reached from the Tap-to-Play account menu); on iPhone
    // the action sheet slides up regardless, but a valid anchor keeps it safe in any regular-width context.
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMaxY(self.view.bounds) - 40, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// After an on-device login the WKWebView leaves WebKit permanently resident in this process, which stops
// StikDebug from servicing HotSpot's JIT-mirror brk #0x69 → the JVM crashes at code-cache init. A fresh
// process has never loaded WebKit, so the reliable path is to restart. iOS can't relaunch an app itself, so
// quit cleanly here; the saved tokens.json means the next launch goes straight to play with no web view
// (no WebKit) and the brk is serviced normally. Only reached after an actual login (fresh login / switch).
- (void)promptRestartToPlay {
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *name = [o isKindOfClass:[NSDictionary class]] ? o[@"chosen_display_name"] : nil;
    NSString *who = name.length ? name : @"your account";
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Logged in ✓"
                         message:[NSString stringWithFormat:
                            @"Signed in as %@.\n\nRuneLite needs to restart once before you can play. Tap "
                            @"Restart, then reopen RuneLite from your Home Screen — you won't have to log in "
                            @"again.", who]
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Restart now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        exit(0);   // tokens.json is already written atomically; the relaunch reads it and goes straight to play
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Not now" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Plugin/config panel (Phase 6)

// Build the modal sheet once: a full-screen scrim (eats every touch so nothing reaches the game) holding a
// titled card with a close button and the plugin table. Added on top of all chrome.
- (void)buildPluginPanel {
    if (self.pluginPanel) return;

    self.pluginPanel = [[UIView alloc] initWithFrame:self.view.bounds];
    self.pluginPanel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.pluginPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55]; // scrim
    self.pluginPanel.userInteractionEnabled = YES;                              // consume all touches
    self.pluginPanel.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:0.98]; // dark OSRS tone
    card.layer.cornerRadius = 12;
    card.clipsToBounds = YES;
    [self.pluginPanel addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Plugins";
    // OSRS typeface for the panel (parity with Android's osrsTypography). The asset is already bundled and
    // proven to load elsewhere in this file; fall back silently to system-bold if it ever fails.
    title.font = [UIFont fontWithName:@"RuneScape" size:20] ?: [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Done" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [close addTarget:self action:@selector(onClosePluginPanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    // Plugin Hub opener — browse/install external plugins (presents PluginHubViewController over the panel).
    UIButton *hub = [UIButton buttonWithType:UIButtonTypeSystem];
    hub.translatesAutoresizingMaskIntoConstraints = NO;
    [hub setTitle:@"＋ Hub" forState:UIControlStateNormal];
    hub.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    hub.tintColor = [UIColor colorWithRed:0.55 green:0.80 blue:1.0 alpha:1.0];
    [hub addTarget:self action:@selector(onOpenHub) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:hub];

    // (§3.5: the legacy "▣ Panels" drawer/centered openers were removed — the plugin icon rail is the single
    // entry to the plugin side-panels now.)

    // Overlay edit-mode opener (OVL-2/3/5) — dismisses the card and shows draggable handles over the live game.
    UIButton *overlaysBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    overlaysBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [overlaysBtn setTitle:@"⛶ Overlays" forState:UIControlStateNormal];
    overlaysBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    overlaysBtn.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.40 alpha:1.0];
    [overlaysBtn addTarget:self action:@selector(onOpenOverlayEdit) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:overlaysBtn];
    self.overlaysCardButton = overlaysBtn;

    // About/disclosure opener (iOS parity with Android's "About" tile) — a compact ⓘ glyph so the title row
    // still fits Done/Hub/Overlays/About. Opens the full-screen unofficial-status/ban-risk/attribution modal.
    UIButton *aboutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    aboutBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [aboutBtn setTitle:@"ⓘ" forState:UIControlStateNormal];
    aboutBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    aboutBtn.tintColor = [UIColor colorWithRed:0.50 green:0.80 blue:0.77 alpha:1.0];
    [aboutBtn addTarget:self action:@selector(onOpenAbout) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:aboutBtn];

    self.pluginTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.pluginTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.pluginTable.backgroundColor = [UIColor clearColor];
    self.pluginTable.dataSource = self;
    self.pluginTable.delegate = self;
    self.pluginTable.rowHeight = 56;
    // Drive row interaction with our OWN gesture recognizers, not the table's selection — the table's built-in
    // tap-to-select arbitrates with the scroll view's pan and fired only intermittently. allowsSelection=NO so
    // nothing competes: a tap recognizer (forgiving slop) toggles, a long-press opens config, drags still
    // scroll. cancelsTouchesInView=NO so they never swallow a scroll/other touch.
    self.pluginTable.delaysContentTouches = NO;
    self.pluginTable.allowsSelection = NO;
    [card addSubview:self.pluginTable];

    UITapGestureRecognizer *rowTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPluginRowTap:)];
    rowTap.cancelsTouchesInView = NO;
    [self.pluginTable addGestureRecognizer:rowTap];

    UILongPressGestureRecognizer *cfgLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPluginRowLongPress:)];
    cfgLp.cancelsTouchesInView = NO;
    [self.pluginTable addGestureRecognizer:cfgLp];

    // CFG-5: a search bar over the (~130-row) list, filtering by name/description.
    self.pluginSearch = [[UISearchBar alloc] init];
    self.pluginSearch.translatesAutoresizingMaskIntoConstraints = NO;
    self.pluginSearch.delegate = self;
    self.pluginSearch.placeholder = @"Search plugins";
    self.pluginSearch.searchBarStyle = UISearchBarStyleMinimal;
    self.pluginSearch.barStyle = UIBarStyleBlack;
    self.pluginSearch.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [self.pluginSearch rm_installKeyboardDoneBar]; // always-available keyboard dismiss (empty Return is greyed out)
    [card addSubview:self.pluginSearch];

    // PARITY-P0-4: the Jagex-session row — the in-game logout control (parity with Android's always-reachable
    // "Log out" tile). Sits directly under the search, above the RuneLite-account row. Same visual model as the
    // accountBar below, but never collapses (a running session always has a Jagex login).
    self.jagexSessionBar = [[UIView alloc] init];
    self.jagexSessionBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.jagexSessionBar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.jagexSessionBar.layer.cornerRadius = 8;
    self.jagexSessionBar.clipsToBounds = YES;
    [card addSubview:self.jagexSessionBar];

    self.jagexSessionLabel = [[UILabel alloc] init];
    self.jagexSessionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jagexSessionLabel.numberOfLines = 2;
    self.jagexSessionLabel.font = [UIFont systemFontOfSize:12];
    self.jagexSessionLabel.textColor = [UIColor whiteColor];
    [self.jagexSessionBar addSubview:self.jagexSessionLabel];

    self.jagexLogoutButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.jagexLogoutButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.jagexLogoutButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.jagexLogoutButton setTitle:@"Log out" forState:UIControlStateNormal];
    [self.jagexLogoutButton setTitleColor:[UIColor colorWithRed:0.95 green:0.55 blue:0.50 alpha:1.0] forState:UIControlStateNormal];
    [self.jagexLogoutButton addTarget:self action:@selector(onInGameJagexLogout) forControlEvents:UIControlEventTouchUpInside];
    [self.jagexSessionBar addSubview:self.jagexLogoutButton];

    // RuneLite-account (config sync) row — distinct from the Jagex game login. Sits between the search and the
    // plugin list; collapses to 0pt height until the bridge reports the account is available (older jar / not wired).
    self.accountBar = [[UIView alloc] init];
    self.accountBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.accountBar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.accountBar.layer.cornerRadius = 8;
    self.accountBar.clipsToBounds = YES;
    [card addSubview:self.accountBar];

    self.accountLabel = [[UILabel alloc] init];
    self.accountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.accountLabel.numberOfLines = 2;
    self.accountLabel.font = [UIFont systemFontOfSize:12];
    self.accountLabel.textColor = [UIColor whiteColor];
    [self.accountBar addSubview:self.accountLabel];

    self.accountButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.accountButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.accountButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.accountButton addTarget:self action:@selector(accountButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.accountBar addSubview:self.accountButton];

    [self.view addSubview:self.pluginPanel];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:sg.topAnchor
                                       constant:10],
        [card.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor
                                          constant:-10],
        [card.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor
                                           constant:24],
        [card.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor
                                            constant:-24],

        [title.topAnchor constraintEqualToAnchor:card.topAnchor
                                        constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                            constant:16],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                             constant:-16],
        [hub.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [hub.trailingAnchor constraintEqualToAnchor:close.leadingAnchor
                                           constant:-18],
        [self.overlaysCardButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.overlaysCardButton.trailingAnchor constraintEqualToAnchor:hub.leadingAnchor
                                                               constant:-18],
        [aboutBtn.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [aboutBtn.trailingAnchor constraintEqualToAnchor:self.overlaysCardButton.leadingAnchor
                                                constant:-18],

        [self.pluginSearch.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                                    constant:6],
        [self.pluginSearch.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                        constant:6],
        [self.pluginSearch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                                         constant:-6],

        [self.jagexSessionBar.topAnchor constraintEqualToAnchor:self.pluginSearch.bottomAnchor
                                                       constant:4],
        [self.jagexSessionBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                           constant:8],
        [self.jagexSessionBar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                                            constant:-8],
        [self.jagexSessionBar.heightAnchor constraintEqualToConstant:44],
        [self.jagexSessionLabel.leadingAnchor constraintEqualToAnchor:self.jagexSessionBar.leadingAnchor
                                                             constant:12],
        [self.jagexSessionLabel.centerYAnchor constraintEqualToAnchor:self.jagexSessionBar.centerYAnchor],
        [self.jagexLogoutButton.trailingAnchor constraintEqualToAnchor:self.jagexSessionBar.trailingAnchor
                                                              constant:-12],
        [self.jagexLogoutButton.centerYAnchor constraintEqualToAnchor:self.jagexSessionBar.centerYAnchor],
        [self.jagexLogoutButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.jagexSessionLabel.trailingAnchor
                                                                          constant:8],

        [self.accountBar.topAnchor constraintEqualToAnchor:self.jagexSessionBar.bottomAnchor
                                                  constant:4],
        [self.accountBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                      constant:8],
        [self.accountBar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                                       constant:-8],
        [self.accountLabel.leadingAnchor constraintEqualToAnchor:self.accountBar.leadingAnchor
                                                        constant:12],
        [self.accountLabel.centerYAnchor constraintEqualToAnchor:self.accountBar.centerYAnchor],
        [self.accountButton.trailingAnchor constraintEqualToAnchor:self.accountBar.trailingAnchor
                                                          constant:-12],
        [self.accountButton.centerYAnchor constraintEqualToAnchor:self.accountBar.centerYAnchor],
        [self.accountButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.accountLabel.trailingAnchor
                                                                      constant:8],

        [self.pluginTable.topAnchor constraintEqualToAnchor:self.accountBar.bottomAnchor
                                                   constant:4],
        [self.pluginTable.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.pluginTable.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.pluginTable.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    // Collapsible height (0 until the account bridge is available); updated by refreshAccountRow.
    self.accountBarHeight = [self.accountBar.heightAnchor constraintEqualToConstant:0];
    self.accountBarHeight.active = YES;
    [self refreshAccountRow];
    [self refreshJagexSessionRow]; // PARITY-P0-4: populate the Jagex-session row from tokens.json
    self.accountTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
        selector:@selector(accountTimerTick) userInfo:nil repeats:YES];
}

// RuneLite-account row: poll only while the panel is on-screen (cheap bridge read); update the row state.
- (void)accountTimerTick {
    if (self.accountBar.window != nil) {
        [self refreshAccountRow];
    }
}

// Read the current RuneLite-account session and update the row (collapsed when the bridge isn't available).
- (void)refreshAccountRow {
    if (![JVMLauncher accountAvailable]) {
        if (self.accountBarHeight.constant != 0) { self.accountBarHeight.constant = 0; self.accountBar.hidden = YES; }
        return;
    }
    self.accountBar.hidden = NO;
    if (self.accountBarHeight.constant != 44) { self.accountBarHeight.constant = 44; }
    NSString *json = [JVMLauncher accountSessionJson] ?: @"{}";
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    BOOL loggedIn = [o[@"loggedIn"] boolValue];
    NSString *user = [o[@"username"] description];
    if (loggedIn) {
        NSString *who = (user.length ? user : @"Signed in");
        self.accountLabel.attributedText = [self accountTitle:@"RuneLite account" detail:who];
        [self.accountButton setTitle:@"Log out" forState:UIControlStateNormal];
        [self.accountButton setTitleColor:[UIColor colorWithRed:0.95 green:0.55 blue:0.50 alpha:1.0] forState:UIControlStateNormal];
    } else {
        self.accountLabel.attributedText = [self accountTitle:@"RuneLite account" detail:@"Sync your profiles + installed plugins"];
        [self.accountButton setTitle:@"Log in" forState:UIControlStateNormal];
        [self.accountButton setTitleColor:[UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0] forState:UIControlStateNormal];
    }
}

// PARITY-P0-4: refresh the Jagex-session row's label from tokens.json (the saved chosen_display_name). The row
// itself is always visible once launched; only the display name is dynamic.
- (void)refreshJagexSessionRow {
    if (!self.jagexSessionBar)
        return;
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *name = ([o isKindOfClass:[NSDictionary class]] && [o[@"chosen_display_name"] isKindOfClass:[NSString class]])
                         ? o[@"chosen_display_name"]
                         : nil;
    self.jagexSessionLabel.attributedText = [self accountTitle:@"Jagex account" detail:(name.length ? name : @"Signed in")];
}

- (NSAttributedString *)accountTitle:(NSString *)title detail:(NSString *)detail {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", title]
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:11],
                      NSForegroundColorAttributeName: [UIColor colorWithRed:0.50 green:0.80 blue:0.77 alpha:1.0] }];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:detail
        attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:13],
                      NSForegroundColorAttributeName: [UIColor whiteColor] }]];
    return s;
}

// Login (opens the runelite.net OAuth in SFSafariViewController via LinkBrowser) or logout. The session updates
// asynchronously (the localhost loopback redirect); the 2s timer reflects it once the user returns from Safari.
- (void)accountButtonTapped {
    NSString *json = [JVMLauncher accountSessionJson] ?: @"{}";
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *o = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([o[@"loggedIn"] boolValue]) {
        [JVMLauncher accountLogout];
    } else {
        [JVMLauncher accountLogin];
    }
    // Debounce: the login/logout runs async (worker thread → SFSafariViewController). Briefly disable the button so
    // a double-tap can't spawn a second OAuth flow if login() fails before Safari opens (Safari is otherwise modal
    // over the panel). The 2s poll reflects the real session state once it lands.
    self.accountButton.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.accountButton.enabled = YES;
    });
    [self refreshAccountRow];
}

// OVL-2/3/5: enter overlay edit-mode — dismiss the management card so the game (and its overlays) are visible,
// then float draggable handles over every movable overlay. Done writes the new positions back via OverlayBridge.
- (void)onOpenOverlayEdit {
    if (self.renderW <= 0) return;                 // the game canvas isn't up yet
    // Open edit-mode even if the overlay manager hasn't resolved: the native chatbox is always movable here, and
    // the RuneLite overlay handles populate once available. (Previously this returned early, leaving the plugins
    // panel up — which read as "the Overlays button does nothing".)
    if (![JVMLauncher overlayAvailable]) {
        [self appendLine:@"[overlay] edit-mode: overlay manager unresolved — chat-move only for now"];
    }
    [self onClosePluginPanel];                     // hide the card so the live overlays show through
    if (self.overlayEdit) { [self.overlayEdit dismiss]; self.overlayEdit = nil; }
    OverlayEditView *ov = [[OverlayEditView alloc] initWithFrame:self.view.bounds
                                                         canvasW:self.renderW
                                                         canvasH:self.visibleH
                                                       presenter:self];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.hudHost = self; // show the chatbox and minimap as draggable handles
    __weak typeof(self) ws = self;
    ov.onClose = ^{ ws.overlayEdit = nil; };   // clear the strong ref on teardown (no dangling removed view)
    [self.view addSubview:ov];
    self.overlayEdit = ov;
}

- (void)onOpenPluginPanel {
    [self buildPluginPanel];
    if (!self.pluginEnabledSince) self.pluginEnabledSince = [NSMutableDictionary dictionary];
    [self refreshPluginList];
    self.pluginSeq = [JVMLauncher mobileUiSeq];
    [self.view bringSubviewToFront:self.pluginPanel];
    self.pluginPanel.hidden = NO;
    self.pluginPanelOpen = YES;
    [self appendLine:[NSString stringWithFormat:@"[plugins] panel open (%lu plugins, seq=%lld)",
                      (unsigned long)self.pluginList.count, self.pluginSeq]];
}

- (void)onClosePluginPanel {
    self.pluginPanel.hidden = YES;
    self.pluginPanelOpen = NO;
    // Persist any plugin toggles now — iOS won't run RuneLite's shutdown/periodic flush on close.
    [JVMLauncher mobileFlushConfig];
}

- (void)onOpenHub {
    PluginHubViewController *hubVC = [[PluginHubViewController alloc] init];
    [self presentViewController:hubVC animated:YES completion:nil];
}

- (void)onOpenAbout {
    AboutViewController *vc = [[AboutViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

// App going to background (user swiped home / to the switcher, before any termination): flush config so
// every edit/toggle made this session survives a relaunch. The one lifecycle hook iOS reliably delivers.
// Then keep the session ALIVE back there: a fresh background-task grace covers the handover, the silent
// audio engine (audio background mode) blocks suspension so the JVM + game socket keep running, and a
// 15 Hz pump keeps feeding live frames to the (auto-started) Picture-in-Picture window.
- (void)onEnterBackground {
    [RMResidency noteBackground];
    [JVMLauncher setGameAudioForeground:NO];
    [JVMLauncher mobileFlushConfig];
    // Reaching the background IS survival, so stop treating the next launch as a crash.
    //
    // The cookie exists to catch a GPU boot that dies during GL init, shader compile or warmup --
    // all of which happen in the first seconds, in the foreground, long before anyone can send the
    // app to the background. But base GPU arms as soon as any frame shows and only clears on a real
    // GPU frame, which does not arrive until the world loads. Everything in between -- sitting at
    // the login screen, reading the plugins panel, switching apps -- left it armed, so a user who
    // quit and relaunched was told the renderer had crashed and was moved back to software.
    //
    // That is not hypothetical: switching renderers REQUIRES a relaunch, so the ordinary way to turn
    // the GPU renderer on ran into this every time. An OOM during world load is unaffected; it
    // happens in the foreground with the cookie still armed, and still demotes correctly.
    self.appBackgrounded = YES;
    [self hideHeatNotice:@"the app went to the background"];
    if (self.hdBootCookieArmed && !self.hdBootCookieSettled) {
        [self hdBootCookieClear];
        self.hdBootCookieArmed = NO;
        // NOT settled: reaching the background proves this boot survived, it does not prove the GPU works. The
        // app usually comes back, and the renderer can still die later -- during world load, in a shader it has
        // not compiled yet, or in an OOM -- so the session must stay able to re-arm. Marking it settled here
        // retired the cookie permanently on the first app switch and took the world-load OOM demotion with it,
        // which is the one the original comment claimed was unaffected. Re-arming is held off only while away.
        [self appendLine:@"[shell] backgrounded before the first GPU frame — crash cookie cleared "
                         @"(the boot survived; a relaunch from here is not a crash)"];
    }
    if (self.bgKeepTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgKeepTask];
    }
    self.bgKeepTask = [[UIApplication sharedApplication]
        beginBackgroundTaskWithName:@"bg-keepalive" expirationHandler:^{
            if (self.bgKeepTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:self.bgKeepTask];
                self.bgKeepTask = UIBackgroundTaskInvalid;
            }
        }];
    if (self.launched) {
        [self startKeepaliveEngine];   // defensive re-arm (a route change can stop a running engine)
        self.bgPumpTicks = 0;          // KEEPALIVE-1: fresh idle-gate window per background trip
        self.bgLoggedOutSince = 0;
        self.keepaliveIdleReleased = NO; // a fresh window means the release is no longer in force
        // Cleared in the record too, or a release from an EARLIER window keeps excusing deaths it
        // had nothing to do with: the flag would still be set hours and several foreground trips
        // later, and an unrelated background kill would be reported as the gate working.
        [RMResidency noteKeepaliveWindowBegan];
        [self startPipBgPump];
    }
    if (self.pipController) {
        // The auto-engage state at the exact moment it matters, for the device log.
        [self appendLine:[NSString stringWithFormat:
                                       @"[pip] bg snapshot: possible=%d active=%d layerStatus=%ld fedSeq=%d audioRunning=%d",
                                       (int)self.pipController.isPictureInPicturePossible,
                                       (int)self.pipController.isPictureInPictureActive,
                                       (long)self.pipLayer.sampleBufferRenderer.status, [JVMLauncher pipFeedSeq],
                                       (int)self.keepaliveEngine.isRunning]];
    }
    [self appendLine:@"[shell] backgrounded -> flushed config, keepalive armed"];
}

- (void)onWillTerminate {
    // The one ending we get told about. Everything else is a kill with no notice, which is what
    // the residency record exists to distinguish.
    [RMResidency noteCleanExit];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Counted, not acted on: a warning before a silent death is the strongest signal available
    // that the death was jetsam rather than a crash or a lost audio session.
    [RMResidency noteMemoryWarning];
}

- (void)onWillEnterForeground {
    [RMResidency noteForeground];
    [JVMLauncher setGameAudioForeground:YES];
    self.appBackgrounded = NO; // back in the foreground: an unproven GPU boot may arm its cookie again
    [self stopPipBgPump];
    if (self.bgKeepTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgKeepTask];
        self.bgKeepTask = UIBackgroundTaskInvalid;
    }
    if (self.launched) [self startKeepaliveEngine];
    // Re-assert immersive chrome (parity with Android's onWindowFocusChanged re-hide): a modal, interruption, or
    // the background round-trip can leave the status bar visible, so restore the hidden state on every resume.
    [self setNeedsStatusBarAppearanceUpdate];
    [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self appendLine:@"[shell] foregrounded -> background pump stopped"];
}

// Read listPlugins() once, parse the JSON array, sort by name, reload the table.
- (void)refreshPluginList {
    if (self.accountBar) { [self refreshAccountRow]; }   // keep the RuneLite-account row current when the panel opens
    if (self.jagexSessionBar) {
        [self refreshJagexSessionRow];
    } // PARITY-P0-4: keep the Jagex-session row current too
    NSString *json = [JVMLauncher mobilePlugins];
    NSArray *arr = nil;
    if (json.length) {
        id parsed = parseBridgeJSON(json, "ViewController.refreshPluginList");
        if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
    }
    if (arr) {
        self.pluginAll = [arr sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            BOOL pa = [a[@"pinned"] boolValue], pb = [b[@"pinned"] boolValue];
            if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;   // pinned float to the top
            NSString *na = [a[@"name"] description] ?: @"";
            NSString *nb = [b[@"name"] description] ?: @"";
            return [na caseInsensitiveCompare:nb];
        }];
    } else {
        self.pluginAll = @[];
    }
    // Maintain the enabled-but-not-active timers over the FULL list (so a row filtered out by search doesn't
    // reset its grace timer): start one when a plugin is first seen pending, clear it once running or disabled.
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (NSDictionary *p in self.pluginAll) {
        NSString *cls = [p[@"className"] description];
        if (!cls) continue;
        BOOL pending = [p[@"enabled"] boolValue] && ![p[@"active"] boolValue];
        if (pending) {
            if (!self.pluginEnabledSince[cls]) self.pluginEnabledSince[cls] = @(now);
        } else {
            [self.pluginEnabledSince removeObjectForKey:cls];
        }
    }
    [self applyPluginFilter];   // derive the filtered self.pluginList + reload (preserves the active search text)
}

// CFG-5: derive the rendered list from the full list + the current search text (name/description match).
- (void)applyPluginFilter {
    NSString *f = self.pluginFilter;
    if (f.length == 0) {
        self.pluginList = self.pluginAll;
    } else {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *p in self.pluginAll) {
            NSString *name = [[p[@"name"] description] lowercaseString] ?: @"";
            NSString *desc = [[p[@"description"] description] lowercaseString] ?: @"";
            NSString *tags = [[p[@"tags"] description] lowercaseString] ?: @"";
            if ([name containsString:f] || [desc containsString:f] || [tags containsString:f])
                [out addObject:p];
        }
        self.pluginList = out;
    }
    [self.pluginTable reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.pluginFilter = [searchText lowercaseString];
    [self applyPluginFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.pluginList.count;
}

// Tap a plugin row -> toggle it on/off (a forgiving tap recognizer, not the table's flaky selection).
- (void)onPluginRowTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGPoint pt = [g locationInView:self.pluginTable];
    // UX-GESTURE-1: the gear button shares the row with this recognizer (cancelsTouchesInView=NO fires
    // both) — if the tap landed on the gear, it owns the action; don't also toggle the plugin.
    for (UIView *v = [self.pluginTable hitTest:pt withEvent:nil]; v && v != self.pluginTable; v = v.superview) {
        if ([v isKindOfClass:[UIButton class]])
            return;
        // The leading star (an interactive UIImageView) owns its own tap — don't also toggle enabled.
        if ([v isKindOfClass:[UIImageView class]] && v.userInteractionEnabled)
            return;
    }
    NSIndexPath *ip = [self.pluginTable indexPathForRowAtPoint:pt];
    if (ip) [self togglePluginAtRow:ip.row];
}

// A direct tap on a row's leading star toggles that plugin's pinned state (Android parity — no long-press needed).
- (void)onPluginRowStarTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded)
        return;
    CGPoint pt = [g locationInView:self.pluginTable];
    NSIndexPath *ip = [self.pluginTable indexPathForRowAtPoint:pt];
    if (!ip || ip.row < 0 || ip.row >= (NSInteger)self.pluginList.count)
        return;
    NSDictionary *p = self.pluginList[(NSUInteger)ip.row];
    NSString *name = [p[@"name"] description];
    if (name.length == 0)
        return;
    BOOL pinned = [p[@"pinned"] boolValue];
    [JVMLauncher mobileSetPinned:name pinned:!pinned];
    [self refreshPluginList];
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"pluginCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.userInteractionEnabled = NO;   // pure indicator — the row tap toggles (reliable big target)
        cell.accessoryView = sw;
        // UX: the leading star is a direct pin toggle (parity with Android's tappable star). Make the icon
        // itself the tap target; onPluginRowStarTap: resolves the row and flips pinned. Added once (cells reuse).
        cell.imageView.userInteractionEnabled = YES;
        UITapGestureRecognizer *starTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(onPluginRowStarTap:)];
        [cell.imageView addGestureRecognizer:starTap];
    }
    NSDictionary *p = self.pluginList[(NSUInteger)indexPath.row];
    BOOL enabled = [p[@"enabled"] boolValue];
    BOOL active  = [p[@"active"] boolValue];
    BOOL hasConfig = [p[@"hasConfig"] boolValue]
        && [p[@"configGroup"] isKindOfClass:[NSString class]] && [p[@"configGroup"] length] > 0;
    cell.textLabel.text = [p[@"name"] description];
    // OSRS typeface on every row (name + status detail), matching the panel title / Android's osrsTypography.
    cell.textLabel.font = [UIFont fontWithName:@"RuneScape" size:17] ?: [UIFont systemFontOfSize:17];
    cell.detailTextLabel.font = [UIFont fontWithName:@"RuneScape" size:14] ?: [UIFont systemFontOfSize:13];
    BOOL pinned = [p[@"pinned"] boolValue];
    // Always show a star so it's a discoverable, always-tappable pin toggle (Android parity): filled amber when
    // pinned, dim outline when not. A direct tap on it flips pinned via onPluginRowStarTap:.
    cell.imageView.image = [UIImage systemImageNamed:(pinned ? @"star.fill" : @"star")];
    cell.imageView.tintColor = pinned ? [UIColor colorWithRed:0.95 green:0.78 blue:0.30 alpha:1.0]
                                      : [UIColor colorWithWhite:0.55 alpha:1.0];
    // CORE-1 fake-plugins ("RuneLite" / "Chat Color"): config-only, no enable concept — drop the toggle and show
    // a disclosure chevron; a tap opens their settings (handled in togglePluginAtRow).
    BOOL configOnly = [p[@"configOnly"] boolValue];
    if (configOnly) {
        cell.accessoryView = nil;   // free the accessory slot so the chevron renders
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.text = @"Client settings · tap to configure";
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    // Normal/renderer rows carry the toggle switch; rows with config ALSO get a tappable gear
    // (UX-GESTURE-1: config was long-press-only — invisible; the gear is the visible affordance, the
    // long-press still works). Rebuilt per bind — reuse cycles through three accessory shapes anyway.
    cell.accessoryType = UITableViewCellAccessoryNone;
    {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.userInteractionEnabled = NO; // pure indicator — the row tap toggles (reliable big target)
        if (hasConfig) {
            UIButton *gear = [UIButton buttonWithType:UIButtonTypeSystem];
            [gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
            gear.tintColor = [UIColor colorWithWhite:0.75 alpha:1.0];
            gear.tag = indexPath.row;
            [gear addTarget:self action:@selector(onPluginRowGear:) forControlEvents:UIControlEventTouchUpInside];
            gear.frame = CGRectMake(0, 0, 44, 44); // full 44pt touch target
            sw.frame = CGRectMake(48, (44 - 31) / 2.0, 51, 31);
            UIView *acc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48 + 51, 44)];
            [acc addSubview:gear];
            [acc addSubview:sw];
            cell.accessoryView = acc;
        } else {
            cell.accessoryView = sw;
        }
    }
    NSString *status;
    UIColor *statusColor;
    // Renderer plugins (GPU / 117HD): their switch reflects the SAVED launch preference (what will be active next
    // launch), not the live "is it running this session" state — they only activate after a restart.
    NSString *rk = [self rendererKeyForClass:[p[@"className"] description]];
    if (rk) {
        // The switch reports the SAVED preference (what the next launch will use); the status reports what this
        // session is actually running. They differ only until the next restart, and collapsing them into one
        // line is why the selected renderer read "restart to apply" permanently -- including while it was the
        // renderer drawing the screen. Base GPU proves itself with a real readback frame; 117HD direct-presents
        // and has no such counter, so for it, booting with it is the best evidence there is.
        enabled = [[self rendererPref] isEqualToString:rk];
        BOOL live = [[self sessionRendererKey] isEqualToString:rk];
        BOOL proven = live && (![rk isEqualToString:@"gpu"] || [JVMLauncher gpuFrameSeq] > 0);
        UIColor *rOn = [UIColor colorWithRed:0.45 green:0.85 blue:0.40 alpha:1.0];
        UIColor *rPending = [UIColor colorWithRed:0.95 green:0.80 blue:0.30 alpha:1.0];
        if (enabled && proven) {
            status = @"● running";
            statusColor = rOn;
        } else if (enabled && live) {
            status = @"○ starting…";
            statusColor = rPending;
        } else if (enabled) {
            status = @"● selected — restart to apply";
            statusColor = rPending;
        } else if (live) {
            status = @"● running — off after restart";
            statusColor = rPending;
        } else {
            status = @"○ off";
            statusColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        }
        cell.detailTextLabel.text = hasConfig ? [status stringByAppendingString:@"   ·  hold to configure"] : status;
        cell.detailTextLabel.textColor = statusColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UISwitch *rsw = [self pluginSwitchInCell:cell];
        rsw.tag = indexPath.row;
        [rsw setOn:enabled animated:NO];
        return cell;
    }
    if (enabled && active) {
        status = @"● running"; statusColor = [UIColor colorWithRed:0.45 green:0.85 blue:0.40 alpha:1.0];
    } else if (enabled && !active) {
        // Pending until the grace period elapses; after that, treat as failed to start (native-lib/GPU plugins
        // whose macOS .dylib can't load on iOS never reach running).
        NSNumber *since = self.pluginEnabledSince[[p[@"className"] description] ?: @""];
        BOOL graceElapsed = since && (CFAbsoluteTimeGetCurrent() - since.doubleValue) > kPluginStartGrace;
        if (graceElapsed) {
            status = @"✕ couldn't start (incompatible)";
            statusColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.40 alpha:1.0];
        } else {
            status = @"○ enabling…"; statusColor = [UIColor colorWithRed:0.95 green:0.80 blue:0.30 alpha:1.0];
        }
    } else {
        status = @"○ disabled"; statusColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    }
    cell.detailTextLabel.text = hasConfig ? [status stringByAppendingString:@"   ·  hold to configure"] : status;
    cell.detailTextLabel.textColor = statusColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;   // every row taps to toggle
    UISwitch *sw = [self pluginSwitchInCell:cell];
    sw.tag = indexPath.row;
    [sw setOn:enabled animated:NO];
    return cell;
}

// The toggle switch, whether the accessory is the bare switch or the gear+switch container (UX-GESTURE-1).
- (UISwitch *)pluginSwitchInCell:(UITableViewCell *)cell {
    if ([cell.accessoryView isKindOfClass:[UISwitch class]])
        return (UISwitch *)cell.accessoryView;
    for (UIView *v in cell.accessoryView.subviews) {
        if ([v isKindOfClass:[UISwitch class]])
            return (UISwitch *)v;
    }
    return nil;
}

// Gear tapped on a plugin row (UX-GESTURE-1): open that plugin's config editor directly.
- (void)onPluginRowGear:(UIButton *)btn {
    NSInteger row = btn.tag;
    if (row < 0 || row >= (NSInteger)self.pluginList.count)
        return;
    if (self.presentedViewController)
        return;
    [self presentConfigEditorForPlugin:self.pluginList[(NSUInteger)row]];
}

// Present the full config editor for a plugin row (gear tap + the long-press "Configure" action).
- (void)presentConfigEditorForPlugin:(NSDictionary *)p {
    NSString *name = [p[@"name"] description] ?: @"";
    NSString *group = [p[@"configGroup"] isKindOfClass:[NSString class]] ? p[@"configGroup"] : nil;
    if (group.length == 0)
        return;
    // 117HD (group "hd"): show ONLY the iOS-ported settings (each safe to setConfig from RLHDStarter).
    // Exposing the rest would recompile an unported shader and stop the plugin. Others show full config.
    // KEEP IN SYNC with Android ConfigScreen.kt HD_CONFIG_WHITELIST and RLHDStarter.java's SAFETY-CRITICAL block.
    NSArray<NSString *> *whitelist = [group isEqualToString:@"hd"] ? @[
        @"sceneResolutionScale",
        @"antiAliasingMode",
        @"shadowMode",
        @"shadowResolution",
        @"enableShadowTransparency",
        @"dynamicLights",
        @"tiledLighting",
        @"normalMapping",
        @"parallaxOcclusionMappingToggle",
        @"drawDistance",
    ]
                                                                   : nil;
    PluginConfigViewController *cfg = [[PluginConfigViewController alloc] initWithGroup:group
                                                                             pluginName:name
                                                                              whitelist:whitelist];
    [self presentViewController:cfg animated:YES completion:nil];
}

// The two renderer plugins are launch-time on iOS (the GL bridge + present layer are set up at JVM start), so
// they're not hot-swappable like a normal plugin. Their on/off + config live in the panel like any plugin, but
// toggling one saves a launch PREFERENCE (applied on the next launch) instead of a live start/stop.
static NSString * const kRendererGpuClass = @"net.runelite.client.plugins.gpu.GpuPlugin";
static NSString * const kRendererHdClass  = @"rs117.hd.HdPlugin";

// "gpu" / "117hd" for the renderer plugins, nil for any normal plugin.
- (NSString *)rendererKeyForClass:(NSString *)className {
    if ([className isEqualToString:kRendererGpuClass]) return @"gpu";
    if ([className isEqualToString:kRendererHdClass]) return @"117hd";
    return nil;
}

- (NSString *)rendererPref {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"rendererPref"] ?: @"cpu";
}

// The renderer this session actually BOOTED with -- which is not the saved preference: a preference picked
// after launch applies next time, and a GPU boot that failed its crash cookie was reverted to software before
// the JVM started. Both flags are assigned once, at the launch decision, and are what the JVM itself was given.
- (NSString *)sessionRendererKey {
    if (self.pendingRouteCZone)
        return @"117hd";
    if (self.pendingRouteCGpu)
        return @"gpu";
    return @"cpu";
}

// A renderer-plugin row was toggled: select it (or fall back to the software renderer), save the preference,
// and tell the user it applies on the next launch. No live setPluginEnabled.
- (void)toggleRenderer:(NSString *)rendererKey {
    BOOL turnOn = ![[self rendererPref] isEqualToString:rendererKey];   // tapping the selected one turns it off
    NSString *newPref = turnOn ? rendererKey : @"cpu";
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:newPref forKey:@"rendererPref"];
    // An explicit pick clears the auto-fail latch (parity with Android's setRendererPref) so a user-chosen GPU mode
    // still gets its one-shot crash protection and the caps probe respects the choice going forward.
    [ud setBool:NO forKey:@"autoGpuFailed"];
    NSString *label = [rendererKey isEqualToString:@"117hd"] ? @"117HD" : @"GPU";
    NSString *which = turnOn ? label : @"The software renderer";
    // iOS (unlike Android) cannot relaunch itself, but it can quit now so the user just re-taps the icon.
    // Quitting also means StikDebug must be re-attached on the next launch for JIT.
    NSString *msg = [NSString stringWithFormat:@"%@ will be your renderer the next time you launch.\n\nQuit now to apply, then relaunch (re-attach StikDebug for JIT). Or choose Later and quit yourself.", which];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart to apply"
                                                              message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Quit now"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *act) {
                                            [ud synchronize];                // force the rendererPref to disk before the hard exit bypasses teardown
                                            [JVMLauncher mobileFlushConfig]; // persist any pending RuneLite config edits too
                                            exit(0);
                                        }]];
    UIViewController *presenter = self.presentedViewController ?: self;
    [presenter presentViewController:a animated:YES completion:nil];
    [self appendLine:[NSString stringWithFormat:@"[renderer] pref -> %@ (restart to apply)", newPref]];
    [self refreshPluginList];   // the row now reflects the saved preference
}

// Toggle a plugin by row: drive MobileUiBridge.setPluginEnabled (EDT lane). The resulting PluginChanged bumps
// the event sequence, so onDisplayTick re-reads the list and the running/stopped indicator settles.
- (void)togglePluginAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.pluginList.count) return;
    NSDictionary *p = self.pluginList[(NSUInteger)row];
    if ([p[@"configOnly"] boolValue]) { [self openPluginConfigForRow:p]; return; }   // CORE-1 fake-plugins: tap = configure
    NSString *className = [p[@"className"] description];
    NSString *rk = [self rendererKeyForClass:className];
    if (rk) { [self toggleRenderer:rk]; return; }   // renderer plugins use the launch preference, not a live toggle
    BOOL newOn = ![p[@"enabled"] boolValue];
    NSString *ack = [JVMLauncher mobileSetPluginEnabled:className enabled:newOn];
    // Start/clear the grace timer from the user action (before the next refresh observes it).
    if (className) {
        if (newOn) self.pluginEnabledSince[className] = @(CFAbsoluteTimeGetCurrent());
        else [self.pluginEnabledSince removeObjectForKey:className];
    }
    // Optimistic visual: flip this row's switch now; the next refresh reconciles with the real state.
    UITableViewCell *cell = [self.pluginTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    [[self pluginSwitchInCell:cell] setOn:newOn animated:YES];
    [self appendLine:[NSString stringWithFormat:@"[plugins] %@ -> %@ : %@",
                      p[@"name"], newOn ? @"enable" : @"disable", ack ?: @"(nil)"]];
}

// Open a config-only row's settings (the CORE-1 fake-plugins, whose tap configures rather than toggles).
- (void)openPluginConfigForRow:(NSDictionary *)p {
    if (self.presentedViewController) return;
    NSString *name = [p[@"name"] description] ?: @"";
    NSString *group = [p[@"configGroup"] isKindOfClass:[NSString class]] ? p[@"configGroup"] : nil;
    if (group.length == 0) return;
    PluginConfigViewController *cfg = [[PluginConfigViewController alloc] initWithGroup:group pluginName:name];
    [self presentViewController:cfg animated:YES completion:nil];
}

// Long-press a plugin row -> open its config screen (if it has one). Tap toggles; hold configures.
- (void)onPluginRowLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [self.pluginTable indexPathForRowAtPoint:[g locationInView:self.pluginTable]];
    if (!ip || ip.row < 0 || ip.row >= (NSInteger)self.pluginList.count) return;
    if (self.presentedViewController) return;   // don't stack/re-present (also guards a re-fired gesture)
    NSDictionary *p = self.pluginList[(NSUInteger)ip.row];
    NSString *name = [p[@"name"] description] ?: @"";
    BOOL hasConfig = [p[@"hasConfig"] boolValue];
    NSString *group = [p[@"configGroup"] isKindOfClass:[NSString class]] ? p[@"configGroup"] : nil;
    BOOL pinned = [p[@"pinned"] boolValue];

    // Long-press menu: pin/unpin (always) + configure (if the plugin has config). Pin floats it to the top of
    // the list and persists via the shared pinnedPlugins CSV. Centered Alert (not an action sheet) so it stays
    // put — an action sheet anchors to the bottom safe-area inset, which the 60fps HUD tick churns landscape.
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:(pinned ? @"Unpin" : @"Pin to top")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [JVMLauncher mobileSetPinned:name pinned:!pinned];
        [self refreshPluginList];
    }]];
    if (hasConfig && group.length > 0) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Configure"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
                                                    [self presentConfigEditorForPlugin:p];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Logging

- (void)openLogFile {
    // Debug keeps both logs in the Files/USB-exposed Documents dir for off-device retrieval. Release keeps only
    // the app's own lines (hello-shell.log; no engine output, QA-P1-12) in the sandboxed App Support dir, where
    // "Share logs" (RMDiagnostics) reads them: without it a release build had nothing to send for a JIT or
    // start-up problem, which happens before RuneLite's client.log exists.
    NSString *dir = [JVMLauncher appLogDir];
    // CompleteUnlessOpen, NOT Complete: the keepalive keeps these files being written while the screen is
    // locked, and Complete makes a file unwritable once locked. The class is set at creation and persists;
    // opened here while unlocked, the fd/handle stays writable after the device locks.
    NSDictionary *prot = @{NSFileProtectionKey: NSFileProtectionCompleteUnlessOpen};
    // Keep the PREVIOUS launch's logs. Both sinks are recreated below, so without this the only
    // record of a launch that died is destroyed by the launch that comes to investigate it — and a
    // boot crash is precisely the thing you cannot reproduce on demand. The GPU renderer's crash
    // cookie is diagnosed entirely from the launch that armed it, which is always the one before.
    void (^rotate)(NSString *) = ^(NSString *current) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:current])
            return;
        NSString *previous = [current stringByAppendingPathExtension:@"prev"];
        [fm removeItemAtPath:previous error:NULL];
        [fm moveItemAtPath:current toPath:previous error:NULL];
    };
    NSString *path = [dir stringByAppendingPathComponent:@"hello-shell.log"];
    rotate(path);
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:prot];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:path];
#if DEBUG
    // Separate raw file for libjvm stdout/stderr, written synchronously (survives a
    // crash) so the [JIT26] mapping trace + the Hello verdict are always retrievable.
    NSString *jpath = [dir stringByAppendingPathComponent:@"jvm-stdio.log"];
    rotate(jpath);
    [[NSFileManager defaultManager] createFileAtPath:jpath contents:nil attributes:prot];  // protection persists across open()
    self.jvmFd = open(jpath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0600);
#else
    // QA-P1-12: no engine stdout/stderr sink in Release. Force jvmFd negative so captureStdio's `jvmFd >= 0`
    // guard skips the dup2 (the default int property is 0, which would alias fd 0/stdin).
    self.jvmFd = -1;
#endif
}

- (void)appendLine:(NSString *)line {
    NSString *out = [line stringByAppendingString:@"\n"];
    // Serialize ALL writes (console + file) on the main queue. The stdout-capture
    // reader runs on a background thread; writing self.logFile from two threads is a
    // data race that silently drops output after JLI_Launch. Funnel both here.
    dispatch_async(dispatch_get_main_queue(), ^{
        // File first (the retrievable hello-shell.log). No per-line synchronizeFile — that fsync was a 1–10ms
        // main-thread stall every line; jvm-stdio.log (dup2'd, unbuffered) is the crash-proof channel.
        // Capped so a line logged every frame can't fill the phone over a long session; the start of a launch
        // is the part a start-up problem needs, and a launch normally writes well under 100 KB.
        if (self.logFile && self.logBytes < kShellLogCap) {
            NSData *bytes = [out dataUsingEncoding:NSUTF8StringEncoding];
            self.logBytes += bytes.length;
            [self.logFile writeData:bytes];
            if (self.logBytes >= kShellLogCap)
                [self.logFile writeData:[@"(log stopped here: 8 MB written this launch)\n"
                                            dataUsingEncoding:NSUTF8StringEncoding]];
        }

#if DEBUG
        // Console: append via textStorage so each line is O(append), not the O(n) whole-string rebuild +
        // attribute re-fix that setText does (n grows unbounded → tens-of-ms stalls in a long session). Cap
        // the backlog, and only force layout/scroll when the debug panel (the console's superview) is visible.
        // QA-P1-12: the on-screen JVM console is a dev surface — compiled out of the Release daily-driver.
        NSTextStorage *ts = self.console.textStorage;
        NSDictionary *attrs = @{
            NSFontAttributeName: self.console.font,
            NSForegroundColorAttributeName: self.console.textColor,
        };
        [ts beginEditing];
        [ts appendAttributedString:[[NSAttributedString alloc] initWithString:out attributes:attrs]];
        const NSUInteger kConsoleCap = 64 * 1024;
        if (ts.length > kConsoleCap) {
            [ts deleteCharactersInRange:NSMakeRange(0, ts.length - kConsoleCap)];
        }
        [ts endEditing];
        if (!self.debugPanel.hidden) {
            [self.console scrollRangeToVisible:NSMakeRange(self.console.textStorage.length, 0)];
        }
#endif
    });
}

// A transient confirmation pill (parity with Android's screenshot Toast), centered above the bottom safe area.
// Player-visible in Release too, unlike appendLine (whose console is DEBUG-only). Replaces the current toast
// rather than stacking, never intercepts touches, and respects reduce-motion by skipping the fade animation.
- (void)showToast:(NSString *)text {
    if (text.length == 0)
        return;
    [self.toastLabel removeFromSuperview];

    UILabel *pill = [[UILabel alloc] init];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.text = text;
    pill.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    pill.textColor = [UIColor whiteColor];
    pill.textAlignment = NSTextAlignmentCenter;
    pill.numberOfLines = 0;
    pill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78]; // matches the app's scrim/card darkening
    pill.layer.cornerRadius = 14;
    pill.layer.masksToBounds = YES;
    pill.userInteractionEnabled = NO; // never steal a tap from the game/HUD
    [self.view addSubview:pill];
    self.toastLabel = pill;

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:g.bottomAnchor
                                          constant:-24],
        [pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:g.leadingAnchor
                                                        constant:24],
        [pill.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor
                                                      constant:-24],
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:34],
    ]];
    // A UILabel has no text inset, so pad horizontally with spaces (the height constraint gives vertical room).
    pill.text = [NSString stringWithFormat:@"  %@  ", text];

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    if (reduceMotion) {
        pill.alpha = 1.0;
    } else {
        pill.alpha = 0.0;
        [UIView animateWithDuration:0.2
                         animations:^{
                             pill.alpha = 1.0;
                         }];
    }
    // Hold ~1.6s, then fade out and remove — but only if this is still the current toast (a newer one replaces it).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.toastLabel != pill)
            return;
        void (^done)(BOOL) = ^(BOOL f) {
            if (self.toastLabel == pill)
                self.toastLabel = nil;
            [pill removeFromSuperview];
        };
        if (reduceMotion) {
            done(YES);
        } else {
            [UIView animateWithDuration:0.25
                             animations:^{
                                 pill.alpha = 0.0;
                             }
                             completion:done];
        }
    });
}

// Send HotSpot's + System.out's stdout/stderr STRAIGHT to the crash-proof file fd,
// UNBUFFERED. The earlier pipe approach lost everything on a hard crash: stdout to a
// pipe is fully buffered, so the [JIT26] trace stayed in libc's buffer and the async
// reader never drained before SIGBUS. Direct dup2 + _IONBF = every printf hits disk
// immediately, so jvm-stdio.log captures the [JIT26] mapping trace and the verdict
// even when the VM aborts. (On-screen no longer shows JVM output; it's in the file.)
- (void)captureStdio {
#if DEBUG
    if (self.jvmFd >= 0) {
        dup2(self.jvmFd, STDOUT_FILENO);
        dup2(self.jvmFd, STDERR_FILENO);
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    [self appendLine:@"(JVM stdout/stderr -> Documents/jvm-stdio.log)"];
#else
    // QA-P1-12: Release does not redirect the VM's stdout/stderr into a Documents sink (there is none); they
    // go to the system default. Nothing to capture, unless the perf probe is armed: then its timing lines alone.
    if ([JVMLauncher perfProbeArmed])
        [self startPerfProbeCapture];
#endif
}

#if !DEBUG
// Phase 4, Release with the perf probe armed: keep the probe's own lines from the VM's stdout/stderr, and nothing else
// (QA-P1-12: no engine output lands in Documents), in Documents/perf-probe.log, the previous launch's kept as .prev.
// The lines carry milliseconds, counts and a game state. Unlike Debug's direct dup2 this is a pipe, so a hard crash
// loses whatever is still in it: these lines measure a live session, they don't diagnose a crash.
static int sPerfProbeReadFd = -1;
static int sPerfProbeLogFd = -1;

// Matched by the whole line's shape rather than by a tag anywhere in it, so a message that only quotes a tag stays
// out (the same rules as Android's jvm_bootstrap.cpp isProbeLine):
//   - the native probe lines, which open the line: memwatch, [coldstart], [perfprobe], [presentprobe];
//   - headless.FrameStats via logback ("%d [%thread] %-5level %logger{36} - %msg"): the line's first " - " must
//     close a logger named *.FrameStats, and the message must open with a probe tag. Text in another logger's
//     message sits after that logger's own " - ", so it can't pose as one;
//   - -Xlog:gc,safepoint with time,uptime,tags decorations: "[<time>][<uptime>][gc] ..." or "...[safepoint] ...".
static BOOL perfProbeIsFrameStats(const char *line) {
    static const char kLogger[] = ".FrameStats";
    static const char *const kTags[] = {"[fpsprobe] ", "[frameprobe] ", "[framebins] ", "[framehist] "};
    const size_t n = sizeof kLogger - 1;
    const char *sep = strstr(line, " - ");
    if (line[0] < '0' || line[0] > '9' || !sep || (size_t)(sep - line) < n || memcmp(sep - n, kLogger, n) != 0)
        return NO;
    for (size_t i = 0; i < sizeof kTags / sizeof kTags[0]; i++) {
        if (strncmp(sep + 3, kTags[i], strlen(kTags[i])) == 0)
            return YES;
    }
    return NO;
}
static BOOL perfProbeIsXlog(const char *line) {
    const char *p = line;
    for (int group = 0; group < 2; group++) { // [time][uptime]
        if (*p != '[' || !(p = strchr(p, ']')))
            return NO;
        p++;
    }
    return strncmp(p, "[gc] ", 5) == 0 || strncmp(p, "[safepoint] ", 12) == 0;
}
static BOOL perfProbeKeeps(const char *line) {
    static const char *const kNative[] = {"[memwatch t=", "[coldstart] ", "[perfprobe] ", "[presentprobe] "};
    for (size_t i = 0; i < sizeof kNative / sizeof kNative[0]; i++) {
        if (strncmp(line, kNative[i], strlen(kNative[i])) == 0)
            return YES;
    }
    return perfProbeIsFrameStats(line) || perfProbeIsXlog(line);
}

// Whole lines only: a read can end mid-line, and -Xlog writes a line's decorations and message separately. A line
// longer than the buffer is dropped (no probe line comes close).
static void *perfProbePump(void *unused) {
    (void)unused;
    pthread_setname_np("perf-probe-log");
    static char buf[4096];
    size_t len = 0;
    BOOL overlong = NO;
    for (;;) {
        ssize_t n = read(sPerfProbeReadFd, buf + len, sizeof buf - 1 - len);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        len += (size_t)n;
        size_t start = 0;
        for (size_t i = 0; i < len; i++) {
            if (buf[i] != '\n')
                continue;
            buf[i] = '\0';
            if (!overlong && perfProbeKeeps(buf + start)) {
                buf[i] = '\n';
                (void)write(sPerfProbeLogFd, buf + start, i - start + 1);
            }
            overlong = NO;
            start = i + 1;
        }
        memmove(buf, buf + start, len - start);
        len -= start;
        if (len == sizeof buf - 1) {
            overlong = YES;
            len = 0;
        }
    }
    close(sPerfProbeReadFd);
    sPerfProbeReadFd = -1;
    return NULL;
}

- (void)startPerfProbeCapture {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"perf-probe.log"];
    NSString *previous = [path stringByAppendingPathExtension:@"prev"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        [fm removeItemAtPath:previous error:NULL];
        [fm moveItemAtPath:path toPath:previous error:NULL];
    }
    // CompleteUnlessOpen, as for the Debug sinks: the session keeps writing while the screen is locked.
    [fm createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey : NSFileProtectionCompleteUnlessOpen}];
    int logFd = open(path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    int p[2];
    if (logFd < 0 || pipe(p) != 0) {
        if (logFd >= 0)
            close(logFd);
        return;
    }
    sPerfProbeLogFd = logFd;
    sPerfProbeReadFd = p[0];
    pthread_t t;
    if (pthread_create(&t, NULL, perfProbePump, NULL) != 0) {
        // No reader, so no redirect: writers to a reader-less pipe would block once it fills.
        close(p[0]);
        close(p[1]);
        close(logFd);
        sPerfProbeReadFd = sPerfProbeLogFd = -1;
        return;
    }
    pthread_detach(t);
    dup2(p[1], STDOUT_FILENO);
    dup2(p[1], STDERR_FILENO);
    close(p[1]);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}
#endif

#pragma mark - JIT gate (the W1-audit Claim E)

- (void)startJitPolling {
    self.jitTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        BOOL attached = [JVMLauncher isDebuggerAttached];
        if (attached && self.jitAttachedMs == 0) {
            self.jitAttachedMs = [JVMLauncher msSinceProcessStart];
            // From here on, losing this process costs the user the whole attach again.
            [RMResidency noteJitAttached];
        }
        // CS_DEBUGGED says a debugger attached, not which script it ran, and the wrong one used to show only as a
        // crash half a second after Tap to Play. So when a debugger appears, the app asks it for the JVM's code
        // cache right away (JVMLauncher startJitScriptCheck): runelite-jit.js maps it and detaches, and any other
        // answer keeps Tap to Play off. A debugger that let go without answering (no script) shows the same way.
        BOOL tracing = [JVMLauncher isDebuggerTracing];
        RMJitScriptCheck check = [JVMLauncher jitScriptCheck];
        if (attached && tracing && !self.jitWasTracing && check != RMJitScriptCheckServed &&
            check != RMJitScriptCheckRunning) {
            [self appendLine:@"[shell] debugger attached: asking it for the code cache (brk #0x69) to check the script"];
            [JVMLauncher startJitScriptCheck:^(RMJitScriptCheck result, NSString *line) {
                [self appendLine:line];
            }];
            check = RMJitScriptCheckRunning;
        }
        self.jitWasTracing = tracing;
        BOOL ready = check == RMJitScriptCheckServed;
        BOOL checking = check == RMJitScriptCheckRunning;
        BOOL wrongScript = check == RMJitScriptCheckWrongAnswer;
        BOOL scriptless = attached && !ready && !checking && !wrongScript;
        if (scriptless && !self.jitScriptlessLogged) {
            self.jitScriptlessLogged = YES;
            [self appendLine:@"[shell] CS_DEBUGGED but no script answered the code-cache check: StikDebug ran without "
                             @"runelite-jit.js, so Tap to Play stays off"];
        }
        self.statusLabel.text = ready         ? @"JIT: CS_DEBUGGED ✓, code cache from runelite-jit.js (ready)"
                                : checking    ? @"JIT: CS_DEBUGGED, checking the script…"
                                : wrongScript ? @"JIT: CS_DEBUGGED, wrong script (no RX memory for brk #0x69)"
                                : scriptless  ? @"JIT: CS_DEBUGGED, no debugger (script not running)"
                                              : @"JIT: waiting…";
        self.statusLabel.textColor = ready                         ? [UIColor systemGreenColor]
                                     : (wrongScript || scriptless) ? [UIColor systemOrangeColor]
                                                                   : [UIColor systemYellowColor];
        // #1: drive the Tap-to-Play cover. The big play button is on only while a launch can work; reflect the gate
        // in its status.
        if (ready) {
            self.playStatusLabel.text = @"Ready to play";
            self.playStatusLabel.textColor = [UIColor systemGreenColor];
        } else if (checking) {
            // A script that never answers freezes the app on this frame, so it says what to do in that case too.
            self.playStatusLabel.text = @"Checking StikDebug's script…\nIf this stays, assign runelite-jit.js to RuneMobile.";
            self.playStatusLabel.textColor = [UIColor systemYellowColor];
        } else if (wrongScript) {
            self.playStatusLabel.text = @"StikDebug ran a different script.\nAssign runelite-jit.js to RuneMobile, close "
                                        @"RuneMobile, and attach again.";
            self.playStatusLabel.textColor = [UIColor systemOrangeColor];
        } else if (scriptless) {
            self.playStatusLabel.text = @"StikDebug isn't running runelite-jit.js.\nAssign it to RuneMobile, then attach again.";
            self.playStatusLabel.textColor = [UIColor systemOrangeColor];
        } else {
            self.playStatusLabel.text = @"Attach StikDebug to play…";
            self.playStatusLabel.textColor = [UIColor systemYellowColor];
        }
        if (self.playButton.enabled != ready) {
            self.playButton.enabled = ready;
            [UIView animateWithDuration:0.2
                             animations:^{
                                 self.playButton.alpha = ready ? 1.0 : 0.5;
                             }];
        }
        if (attached && !self.launchButton.enabled && !self.launched) {
            self.launchButton.enabled = YES;
            [self appendLine:@"StikDebug attached — CS_DEBUGGED set. Tap Start game."];
#if TARGET_OS_SIMULATOR
            // ios/dev-tools/run-sim.sh launches with `-RMAutoPlay YES` (the argument domain of NSUserDefaults) so
            // an unattended run boots the game without a click on the Play cover.
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"RMAutoPlay"])
                [self onPlayTapped];
#endif
        }
        [self refreshDevDiagnostics]; // keep the readout live pre-launch (no-op while the panel is hidden)
    }];
}

#pragma mark - Actions

- (void)onCanary {
    JVMLogSink log = ^(NSString *line) { [self appendLine:line]; };
    [self appendLine:@"--- RWX canary ---"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [JVMLauncher runRwxCanary:log];
    });
}

#pragma mark - W3 native tab rails (cover-in-place)

// Map a game-canvas rect to the screen image view's coordinate space, honouring the ScaleAspectFit letterbox
// (the inverse of mapPoint:). self.screen.image's size IS the game canvas, so this places a native rail
// exactly over the live desktop widget.
- (CGRect)viewRectForGameX:(int)gx y:(int)gy w:(int)gw h:(int)gh {
    UIImage *img = self.screen.image;
    CGFloat iw = img ? img.size.width : 0, ih = img ? img.size.height : 0;
    // GPU present: no UIImage
    if ((iw <= 0 || ih <= 0) && self.renderW > 0) {
        iw = self.renderW;
        ih = self.visibleH;
    }
    if (iw <= 0 || ih <= 0) return CGRectZero;
    CGRect b = self.screen.bounds;
    CGFloat scale = MIN(b.size.width / iw, b.size.height / ih);
    CGFloat ox = (b.size.width - iw * scale) * 0.5;
    CGFloat oy = (b.size.height - ih * scale) * 0.5;
    return CGRectMake(gx * scale + ox, gy * scale + oy, gw * scale, gh * scale);
}

// Load a bundled tab sprite asset at native (1x) scale.
// Decode one {"w":W,"h":H,"px":"<base64 big-endian ARGB>"} sprite object (from JVMLauncher.tabSprites) into a
// straight-alpha UIImage at native px (scale 1). The bytes are TYPE_INT_ARGB from BufferedImage.getRGB — alpha is
// non-premultiplied and first in each 32-bit big-endian word — so the CGImage is alpha-first / 32-big. nil if absent.
static UIImage *imageFromSpriteDict(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    int w = [d[@"w"] intValue], h = [d[@"h"] intValue];
    id b64 = d[@"px"];
    if (w <= 0 || h <= 0 || ![b64 isKindOfClass:[NSString class]]) return nil;
    NSData *bytes = [[NSData alloc] initWithBase64EncodedString:(NSString *)b64 options:0];
    if (bytes.length != (NSUInteger)w * (NSUInteger)h * 4u) return nil;
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    if (!prov) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs,
        (CGBitmapInfo)(kCGImageAlphaFirst | kCGBitmapByteOrder32Big),
        prov, NULL, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

// Composite stones and an icon into one image at native px (nearest-neighbour): each stone at the origin, then the
// icon the way the engine draws a sprite in a widget, at its offset inside a box placed at `box` (the widget's spot on
// the stone, from the official layout). A box of another size than the sprite's own scales it, as the engine does.
- (UIImage *)compositeStones:(NSArray<UIImage *> *)stones icon:(id)iconObj box:(CGRect)box {
    UIImage *base = stones.firstObject;
    if (base == nil)
        return nil;
    UIImage *icon = imageFromSpriteDict(iconObj);
    NSDictionary *d = [iconObj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)iconObj : nil;
    CGFloat bw = [d[@"bw"] intValue], bh = [d[@"bh"] intValue];
    CGFloat sx = bw > 0 ? box.size.width / bw : 1.0, sy = bh > 0 ? box.size.height / bh : 1.0;
    CGSize sz = base.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetInterpolationQuality(ctx.CGContext, kCGInterpolationNone);
        for (UIImage *stone in stones)
            [stone drawInRect:CGRectMake(0, 0, stone.size.width, stone.size.height)];
        if (icon) {
            [icon drawInRect:CGRectMake(box.origin.x + [d[@"ox"] intValue] * sx, box.origin.y + [d[@"oy"] intValue] * sy,
                                        icon.size.width * sx, icon.size.height * sy)];
        }
    }];
}

// The grid's frame at w x h canvas px from its nine pieces (corners, edges, middle, row by row): corners at their own
// size, edges and middle stretched between them, as the engine lays SIDE_RIGHT_TABS_BACKGROUND.
static UIImage *nineSliceImage(NSArray *pieces, CGFloat w, CGFloat h) {
    if (pieces.count != 9)
        return nil;
    NSMutableArray<UIImage *> *p = [NSMutableArray arrayWithCapacity:9];
    for (id obj in pieces) {
        UIImage *img = imageFromSpriteDict(obj);
        if (img == nil)
            return nil;
        [p addObject:img];
    }
    CGFloat l = p[0].size.width, t = p[0].size.height, rt = p[8].size.width, b = p[8].size.height;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetInterpolationQuality(ctx.CGContext, kCGInterpolationNone);
        const CGFloat xs[3] = {0, l, w - rt}, ws[3] = {l, w - l - rt, rt};
        const CGFloat ys[3] = {0, t, h - b}, hs[3] = {t, h - t - b, b};
        for (int row = 0; row < 3; row++)
            for (int col = 0; col < 3; col++)
                [p[row * 3 + col] drawInRect:CGRectMake(xs[col], ys[row], ws[col], hs[row])];
    }];
}

// Per-device disk cache of the last COMPLETE sprite payload (NOT committed — captured at runtime from the live
// cache). Lets the grid/chat render the real art instantly on boot instead of waiting for the post-login capture.
- (NSString *)tabSpriteCachePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!dir) return nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"tabsprites.json"];
}

// Decode a JVMLauncher.tabSprites payload into the live chrome images: the 14 grid stones (each glyph on the grey
// stone, and on the red one over it for the open tab), the expand stone both ways, the grid frame at both widths and
// the chat column (door, speech bubbles, keyboard). Each icon sits where the official layout puts it: the tab glyphs
// and arrows in a 33x36 box 3 px in (the arrows a pixel higher), the door and keyboard in one 12 px in, the bubbles in
// a 32x32 one at (13,4). updateChrome re-reads these every tick, so the next frame picks up the new art. Returns YES
// only for a COMPLETE engine-published set.
- (BOOL)applyTabSpriteJSON:(NSString *)json {
    if (json.length == 0) return NO;
    NSDictionary *d = parseBridgeJSON(json, "ViewController.applyTabSpriteJSON");
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    // A set cached by an older build has the desktop stones and no column, frame or offsets
    // (HudVeneerBridge.TAB_SPRITES_VERSION).
    if ([d[@"v"] intValue] < kTabSpritesVersion)
        return NO;
    UIImage *stoneI = imageFromSpriteDict(d[@"stoneInactive"]);
    UIImage *stoneA = imageFromSpriteDict(d[@"stoneActive"]);
    id iconsObj = d[@"icons"];
    NSArray *icons = [iconsObj isKindOfClass:[NSArray class]] ? (NSArray *)iconsObj : nil;
    const CGRect tabBox = CGRectMake(3, 2, 33, 36), arrowBox = CGRectMake(3, 1, 33, 36);
    BOOL gridOK = (stoneI && stoneA && icons.count == 14);
    if (gridOK) {
        NSMutableArray<UIImage *> *inact = [NSMutableArray arrayWithCapacity:14];
        NSMutableArray<UIImage *> *act = [NSMutableArray arrayWithCapacity:14];
        for (int i = 0; i < 14; i++) {
            inact[i] = [self compositeStones:@[ stoneI ] icon:icons[i] box:tabBox] ?: (UIImage *)[NSNull null];
            act[i] = [self compositeStones:@[ stoneI, stoneA ] icon:icons[i] box:tabBox] ?: (UIImage *)[NSNull null];
        }
        self.tabImgInactive = inact;
        self.tabImgActive = act;
    }
    UIImage *doorStone = imageFromSpriteDict(d[@"doorStone"]);
    UIImage *doorStoneA = imageFromSpriteDict(d[@"doorStoneActive"]);
    UIImage *chatStone = imageFromSpriteDict(d[@"chatStoneOpen"]);
    BOOL controlsOK = gridOK && doorStone && doorStoneA && chatStone && imageFromSpriteDict(d[@"showLess"]) && imageFromSpriteDict(d[@"showMore"]) && imageFromSpriteDict(icons[kTabLogout]) && imageFromSpriteDict(d[@"chatToggle"]) && imageFromSpriteDict(d[@"keyboard"]);
    if (controlsOK) {
        self.tabImgShowLess = [self compositeStones:@[ stoneI ] icon:d[@"showLess"] box:arrowBox];
        self.tabImgShowMore = [self compositeStones:@[ stoneI ] icon:d[@"showMore"] box:arrowBox];
        const CGRect doorBox = CGRectMake(12, 2, 33, 36), bubblesBox = CGRectMake(13, 4, 32, 32);
        self.doorImg = [self compositeStones:@[ doorStone ] icon:icons[kTabLogout] box:doorBox];
        self.doorImgActive = [self compositeStones:@[ doorStoneA ] icon:icons[kTabLogout] box:doorBox];
        self.chatToggleOpenImg = [self compositeStones:@[ chatStone ] icon:d[@"chatToggle"] box:bubblesBox];
        self.chatToggleClosedImg = [self compositeStones:@[ doorStone ] icon:d[@"chatToggle"] box:bubblesBox];
        self.chatToggleFlashImg = [self compositeStones:@[ doorStoneA ] icon:d[@"chatToggle"] box:bubblesBox];
        self.chatKeyboardImg = [self compositeStones:@[ chatStone ] icon:d[@"keyboard"] box:CGRectMake(12, 1, 33, 36)];
    }
    NSArray *frame = [d[@"frame"] isKindOfClass:[NSArray class]] ? d[@"frame"] : nil;
    UIImage *frameImg = nineSliceImage(frame, kTabGroupW, kTabGroupH);
    UIImage *frameImgCollapsed = nineSliceImage(frame, kTabGroupCollapsedW, kTabGroupH);
    if (frameImg && frameImgCollapsed) {
        self.tabFrameImg = frameImg;
        self.tabFrameImgCollapsed = frameImgCollapsed;
    }
    return [d[@"complete"] boolValue] && controlsOK && frameImg && frameImgCollapsed;
}

// Pull the real OSRS sprites from the live cache once the engine has them (a few ticks post-login), then persist
// for instant boot. One-shot: stops polling once a complete set lands. No-op until login / on an older jar.
- (void)refreshTabSpritesFromCache {
    NSString *json = [JVMLauncher tabSprites];
    if (json.length == 0) return;
    if (![self applyTabSpriteJSON:json]) return;   // partial set — keep polling
    self.tabSpritesComplete = YES;
    NSString *path = [self tabSpriteCachePath];
    if (path) [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self appendLine:@"[chrome] tab sprites rendered from live cache (no bundled art)"];
}

// Seed the 14 active + 14 inactive grid tiles. The sprites are rendered from the live OSRS cache (like desktop
// RuneLite) — no committed interface art. A disk-cached payload from a prior session fills the grid instantly;
// otherwise the tiles stay empty (updateChrome draws a stone-brown fallback) until refreshTabSpritesFromCache
// captures them post-login.
- (void)buildTabAssets {
    self.tabImgInactive = [NSMutableArray arrayWithCapacity:14];
    self.tabImgActive = [NSMutableArray arrayWithCapacity:14];
    for (int i = 0; i < 14; i++) { self.tabImgInactive[i] = [NSNull null]; self.tabImgActive[i] = [NSNull null]; }
    NSString *path = [self tabSpriteCachePath];
    NSString *cached = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    BOOL seeded = cached.length && [self applyTabSpriteJSON:cached];
    [self appendLine:[NSString stringWithFormat:@"[chrome] tab assets init (%@)",
                      seeded ? @"cached cache-sprites" : @"awaiting live cache"]];
}

#pragma mark - W3 A3: enlarged native chat tab buttons

// Register the bundled RuneScape TTFs (the same faithful in-game font RuneLite uses for overlays) so the native
// chat-tab labels render in the authentic OSRS font instead of the system font. Runtime registration — no
// Info.plist UIAppFonts entry needed. PostScript names: "RuneScape", "RuneScapeBold", "RuneScape-Small".
- (void)registerChatFonts {
    for (NSString *n in @[@"runescape", @"runescape_bold", @"runescape_small"]) {
        NSString *p = [[NSBundle mainBundle] pathForResource:n ofType:@"ttf"];
        if (!p) { [self appendLine:[NSString stringWithFormat:@"[chat] font %@ MISSING", n]]; continue; }
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d.length == 0) continue;
        CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
        if (!prov) continue;
        CGFontRef f = CGFontCreateWithDataProvider(prov);
        if (f) {
            CTFontManagerRegisterGraphicsFont(f, NULL);   // dup-register on relaunch is a harmless no-op
            CGFontRelease(f);
        }
        CGDataProviderRelease(prov);
    }
}

// Build the 7 filter-stone tap targets once, as subviews of the game view (above the blit). They draw nothing: the
// engine draws the stones under them. A tap switches to that channel (tapping the active one collapses the chat);
// a long-press on a filterable channel opens its filter menu (onChatTabLongPress). Hidden until the chat is
// relocated + logged in. updateChatTabs lays them out.
- (void)buildChatTabs {
    self.chatTabButtons = [NSMutableArray arrayWithCapacity:kChatTabCount];
    for (int i = 0; i < kChatTabCount; i++) {
        UIButton *b = [ChatTabButton buttonWithType:UIButtonTypeCustom];   // expanded touch area (kChatTabTouchExpand)
        b.tag = i;
        b.hidden = YES;
        b.accessibilityLabel = kChatTabNames[i];
        [b addTarget:self action:@selector(onChatTabButton:) forControlEvents:UIControlEventTouchUpInside];
        // Long-press a FILTERABLE channel's tab -> the engine's filter menu (On/Filter/Off/Hide …) via the native
        // big-row overlay (drag to a row, release to select). All/Game have no filter, so they get NO long-press
        // recognizer — otherwise it would recognize on a slow press and cancel the tap (a dead gesture).
        if (kChatTabFilterable[i]) {
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(onChatTabLongPress:)];
            lp.minimumPressDuration = [RMGameSettings longPressMs] / 1000.0; // Settings > Game settings
            [b addGestureRecognizer:lp];
        }
        [self.screen addSubview:b];
        [self.chatTabButtons addObject:b];
    }

    // Native chat MESSAGES view: the engine refuses to raster its chatbox once relocated, so we draw the message
    // lines ourselves from the live engine model (JVMLauncher.chatLines). Text-over-scene (clear bg, glyph shadow);
    // non-interactive (finger drags fall through to the existing engine-chat scroll); sits below the tab row.
    UITextView *msgs = [[UITextView alloc] initWithFrame:CGRectZero];
    msgs.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.22];   // subtle translucent box (readability over scene)
    msgs.layer.cornerRadius = 6.0;
    msgs.editable = NO;
    msgs.selectable = NO;
    msgs.scrollEnabled = YES;             // for programmatic bottom-anchor (setContentOffset); not finger-scrolled
    msgs.showsVerticalScrollIndicator = NO;
    msgs.userInteractionEnabled = NO;     // touches fall through to the engine-chat scroll handler
    msgs.clipsToBounds = YES;
    msgs.textContainerInset = UIEdgeInsetsZero;
    msgs.textContainer.lineFragmentPadding = 0;
    msgs.hidden = YES;
    // Below the tab buttons (the tabs sit on top and own their taps); their on-screen regions don't overlap.
    [self.screen insertSubview:msgs belowSubview:self.chatTabButtons[0]];
    self.chatMessagesView = msgs;
    self.chatLinesSeq = -1;

    // Persisted chat position offset (set in overlay edit-mode; applied in updateHudLayout).
    self.chatUserDX = (int)[[NSUserDefaults standardUserDefaults] integerForKey:hudOffsetKey(@"chatUserDX")];
    self.chatUserDY = (int)[[NSUserDefaults standardUserDefaults] integerForKey:hudOffsetKey(@"chatUserDY")];

    self.chatTabsBuilt = YES;
    self.optimisticChatTab = -1;
    self.chatActiveTab = -1;
    [self appendLine:@"[chat] filter-stone tap targets built"];
}

// Convert a packed 0xRRGGBB int (the engine widget text colour) to a UIColor; nil for < 0 (unknown).
static UIColor *rgbColor(int rgb) {
    if (rgb < 0) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// The filter row's height in ENGINE-CANVAS px (screen-scale independent): what a tap there treats as UI.
static int chatRowCanvasH(void) {
    return hudPx(kChatTabRowCanvasH);
}

// Lay the 7 filter-stone tap targets over the engine's stones from the chat snapshot each tick. Mirrors updateChrome:
// hides them when the native chrome is toggled off or the layout is unsupported (not Resizable - Modern/164). Tracks
// the active channel (the just-tapped one is held until the engine catches up) so a tap on it collapses the chat.
- (void)updateChatTabs {
    if (!self.chatTabsBuilt) return;
    if (!kChatVeneerEnabled) { [self hideChatTabs]; [self hideDialogue]; return; }   // veneer removed -> engine chatbox
    [self updateDialogueView];   // native opaque dialogue (self-contained: shows/hides off the snapshot + JSON)
    if (self.mapOpen) { [self hideChatTabs]; return; }   // fullscreen world map: the tab row would cover it
    if (!self.chromeVisible || self.renderW <= 0) { [self hideChatTabs]; return; }
    NSString *snap = [JVMLauncher chatSnapshot];
    if (snap.length == 0) { [self hideChatTabs]; return; }
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateChatTabs");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue]) { [self hideChatTabs]; return; }
    // LAYOUT GUARD (same as updateChrome): the native HUD only works in Resizable - Modern (164).
    if ([d[@"topLevelId"] intValue] != 164) { [self hideChatTabs]; return; }
    // Dialogue open: the engine renders its own dialogue (NPC/player/options/level-up/message/make-X) — an
    // OPAQUE parchment + head — into the relocated chatbox region at the top, exactly like desktop. Hide the
    // native chat veneer (lines + input) so it doesn't overlap the parchment; it auto-restores when the dialogue
    // closes (the snapshot's dialogueActive flips false).
    BOOL dlg = [d[@"dialogueActive"] boolValue];
    if (dlg != self.chatDialogueActive) {
        self.chatDialogueActive = dlg;
        // Auto-open/close: open a collapsed or put-away chat for the dialogue's duration and restore it when the
        // dialogue closes (mirrors Android; official-mobile behaviour). Native is the single owner of both states.
        if (dlg && self.chatCollapsed) {
            self.savedCollapsedForDialogue = YES;
            self.chatCollapsed = NO;
            [JVMLauncher setEngineChatCollapsed:NO];
        } else if (!dlg && self.savedCollapsedForDialogue) {
            self.savedCollapsedForDialogue = NO;
            self.chatCollapsed = YES;
            [JVMLauncher setEngineChatCollapsed:YES];
        }
        if (dlg && self.chatPutAway) {
            self.savedPutAwayForDialogue = YES;
            [self setChatPutAway:NO];
        } else if (!dlg && self.savedPutAwayForDialogue) {
            self.savedPutAwayForDialogue = NO;
            [self setChatPutAway:YES];
        }
        [self appendLine:dlg ? @"[chat] dialogue open -> native chat hidden, engine dialogue (opaque) shown"
                             : @"[chat] dialogue closed -> native chat veneer restored"];
    }
    [self updateDialogueTapTargetsActive:dlg];
    if (dlg) {
        // Capture the dialogue's canvas rect so onTap routes taps there precisely (resolving the dialogue's
        // Continue/option) instead of walking the world behind it. Disable the stale chat-scroll tap routing for
        // the duration (the dialogue owns the chatbox region while it is open).
        if (d[@"dlgW"]) {
            self.dialogueChatCanvas = CGRectMake([d[@"dlgX"] intValue], [d[@"dlgY"] intValue],
                                                 [d[@"dlgW"] intValue], [d[@"dlgH"] intValue]);
        } else {
            self.dialogueChatCanvas = CGRectZero;   // not laid out yet this frame
        }
        self.chatScrollable = NO;
        [self hideChatTabs];
        return;
    }
    self.dialogueChatCanvas = CGRectZero;
    NSArray *tabs = [d[@"tabs"] isKindOfClass:[NSArray class]] ? d[@"tabs"] : nil;
    if (tabs.count == 0) { [self hideChatTabs]; return; }
    BOOL unread = NO;
    for (int j = 0; j < (int)tabs.count && j < kChatTabCount; j++)
        if ([tabs[j] isKindOfClass:[NSDictionary class]] && [tabs[j][@"new"] boolValue])
            unread = YES;
    self.chatHasUnread = unread; // the bubbles flash on it while the chat is put away (updateChrome)
    // Chat open + supported -> finger-scroll (off while collapsed or put away).
    self.chatScrollable = !self.chatCollapsed && !self.chatPutAway;

    CGFloat W = self.view.bounds.size.width;
    CGFloat s = W / (CGFloat)self.renderW;           // canvas px -> screen pt (uniform: render aspect == screen)
    int chatX = [d[@"chatX"] intValue], chatY = [d[@"chatY"] intValue];
    [JVMLauncher setEngineChatAreaWidth:0]; // the official 461

    // The filter stones stay up while the chat is collapsed (tap the active one: only the messages go), and go
    // with the rest of it when it is put away. A forefront window (bank/GE/…) hides them too, so the chat sits
    // behind it (windowOpen in the snapshot).
    if (self.chatPutAway || [d[@"windowOpen"] boolValue]) {
        [self hideChatTabs];
        return;
    }

    // The ENGINE draws the chat itself (stones, messages, scrollbar); the native message view stays hidden.
    self.chatMessagesView.hidden = YES;

    // Which tab is active. Prefer the live channel VIEW (VarClientID.CHAT_VIEW: 0=All..6=Trade) — it is always
    // correct, unlike the tab GRAPHIC sprite (which only flips on a redraw, so it often reads "none selected" and
    // left chatActiveTab=-1, which made the FIRST tap "switch" instead of collapse => the two-tap-to-close bug).
    // Fall back to the sprite-selected tab if the view is out of range.
    int snapSel = -1;
    for (int j = 0; j < (int)tabs.count && j < kChatTabCount; j++) {
        NSDictionary *tj = [tabs[j] isKindOfClass:[NSDictionary class]] ? tabs[j] : nil;
        if ([tj[@"selected"] boolValue]) { snapSel = j; break; }
    }
    int view = [d[@"view"] intValue];
    if (view >= 0 && view < kChatTabCount) snapSel = view;   // the channel view is the authoritative active tab
    int effSel = snapSel;
    if (self.optimisticChatTab >= 0) {
        if (snapSel == self.optimisticChatTab) self.optimisticChatTab = -1;   // engine sprite caught up
        else effSel = (int)self.optimisticChatTab;                            // hold the instant highlight
    }
    // STICKY active tab: the engine's selected-sprite AND the CHAT_VIEW varc both flicker to -1 between redraws, so
    // assigning chatActiveTab = effSel every tick reset it to -1 mid-flicker — then the first tap on the (open)
    // active tab read as a SWITCH instead of a collapse (two taps to hide). Keep the LAST KNOWN active tab when the
    // snapshot momentarily reports none, so one tap on it collapses.
    if (effSel >= 0) self.chatActiveTab = effSel;

    // One bare target over each engine stone, with its channel and filter state for VoiceOver.
    for (int i = 0; i < kChatTabCount; i++) {
        UIButton *b = self.chatTabButtons[i];
        b.frame = CGRectMake((chatX + hudPx(kChatTabX + i * kChatTabPitch)) * s, (chatY + hudPx(kChatTabY)) * s,
                             hudPx(kChatTabW) * s, hudPx(kChatTabH) * s);
        NSDictionary *t = (i < (int)tabs.count && [tabs[i] isKindOfClass:[NSDictionary class]]) ? tabs[i] : nil;
        NSString *filter = [t[@"filter"] isKindOfClass:[NSString class]] ? t[@"filter"] : @"";
        b.accessibilityLabel = filter.length ? [NSString stringWithFormat:@"%@, %@", kChatTabNames[i], filter]
                                             : kChatTabNames[i];
        b.selected = (!self.chatCollapsed && i == self.chatActiveTab);
        b.hidden = NO;
    }
}

- (void)hideChatTabs {
    self.chatScrollable = NO;   // chat not open -> drags fall through to the camera
    self.chatMessagesView.hidden = YES;
    for (UIButton *b in self.chatTabButtons) b.hidden = YES;
}

// The speech bubbles by the door: put the whole chat away, filter stones and all, or bring it back (the official
// app's "Toggle Chatbox"). Its collapse state is kept for when it comes back.
- (void)onChatToggle {
    if (![JVMLauncher bridgeReady])
        return;
    self.savedPutAwayForDialogue = NO; // the player's own choice from here on
    [self setChatPutAway:!self.chatPutAway];
    [self updateChatTabs];
    [self updateChrome];
    [self appendLine:self.chatPutAway ? @"[chat] put away" : @"[chat] brought back"];
}

- (void)setChatPutAway:(BOOL)putAway {
    _chatPutAway = putAway;
    [JVMLauncher setEngineChatPutAway:putAway];
}

#pragma mark - Native dialogue (opaque parchment over the chatbox; real engine head shows through a cutout)

- (void)ensureDialogueView {
    if (self.dialogueView) return;
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithRed:0.84 green:0.78 blue:0.62 alpha:1.0];   // OSRS parchment tan (opaque)
    v.layer.cornerRadius = 4.0;
    v.layer.borderColor = [UIColor colorWithRed:0.36 green:0.27 blue:0.13 alpha:1.0].CGColor;
    v.layer.borderWidth = 2.0;
    v.hidden = YES;
    // A tap anywhere on the parchment advances a "click here to continue" dialogue (option rows are buttons on top).
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDialogueContinue)];
    [v addGestureRecognizer:tap];

    UIView *content = [[UIView alloc] init];   // the text area; its frame is set head-aware each tick
    content.backgroundColor = [UIColor clearColor];
    [v addSubview:content];

    UIStackView *st = [[UIStackView alloc] init];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentFill;
    st.spacing = 3.0;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    st.userInteractionEnabled = YES;
    [content addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [st.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [st.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [st.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor],
        [st.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor],
    ]];
    self.dialogueStack = st;
    self.dialogueContentView = content;
    self.dialogueView = v;
    [self.screen addSubview:v];
}

- (void)hideDialogue {
    if (self.dialogueView) self.dialogueView.hidden = YES;
    self.lastDialogueJson = nil;
}

// Poll each chat tick: when a dialogue is open, draw the opaque parchment over the WHOLE chatbox region (so the
// engine's transparent dialogue + the chat tabs/messages are occluded) with a cutout where the engine's real 3D
// head renders; otherwise hide it. The engine keeps rendering underneath, so the head still shows through.
- (void)updateDialogueView {
    if (!kChatVeneerEnabled) { [self hideDialogue]; return; }   // veneer removed -> engine draws the dialogue itself
    if (!self.chromeVisible || self.renderW <= 0 || self.mapOpen) { [self hideDialogue]; return; }
    NSString *snap = [JVMLauncher chatSnapshot];
    if (snap.length == 0) { [self hideDialogue]; return; }
    NSDictionary *cd = parseBridgeJSON(snap, "ViewController.updateDialogueView");
    if (![cd isKindOfClass:[NSDictionary class]] || ![cd[@"loggedIn"] boolValue]
        || [cd[@"topLevelId"] intValue] != 164 || ![cd[@"dialogueActive"] boolValue]
        // Path B: the engine now paints its OWN opaque dialogue + full head; suppress the native parchment so it
        // doesn't double-render over it (mirrors Android's engineDialogue gate).
        || [cd[@"engineDialogue"] boolValue]) { [self hideDialogue]; return; }
    // This is a SECOND read of the dialogue, independent of the one the tap targets are built from, so it needs
    // its own sequence: the two can observe different publishes, and a row this view is showing must be answered
    // against the dialogue IT was built from.
    //
    // Read the pair CONSISTENTLY, not merely sequence-first. getDialogueSeq bumps only on a CHANGED snapshot, so
    // a sequence that is identical either side of the json read is the one that json belongs to; a publish
    // landing mid-read is detected and the pair re-read. It is not airtight: publishDialogueJson stores the
    // payload BEFORE bumping the seq, so a read that catches that window sees an unchanged (older) seq beside
    // the newer json. That skew is the safe direction -- a pick is refused, never misapplied -- and the
    // unconditional re-tag below keeps it to that one pass. Sequence-before-payload alone is not enough here,
    // which the old comment missed: this view re-tags its rows only when the json TEXT changes, so a skewed
    // sequence LATCHES -- every option pick is refused until the text happens to move. That is a dialogue that
    // silently stops answering, not a pick that fails safe.
    long long viewSeq = 0;
    NSString *js = nil;
    for (int attempt = 0; attempt < 3; attempt++) {
        viewSeq = [JVMLauncher dialogueSeq];
        js = [JVMLauncher dialogueJson];
        if ([JVMLauncher dialogueSeq] == viewSeq)
            break; // nothing published across the json read
    }
    if (js.length == 0) { [self hideDialogue]; return; }
    NSDictionary *d = parseBridgeJSON(js, "ViewController.updateDialogueView");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"type"] isKindOfClass:[NSString class]]) { [self hideDialogue]; return; }

    [self ensureDialogueView];
    CGFloat s = self.view.bounds.size.width / (CGFloat)self.renderW;
    CGFloat boxX = floor([cd[@"chatX"] intValue] * s);
    CGFloat boxY = floor([cd[@"chatY"] intValue] * s);
    CGFloat boxW = ceil(kDialogueCanvasW * sHudScale * s);
    CGFloat boxH = ceil(kDialogueCanvasH * sHudScale * s);
    self.dialogueView.frame = CGRectMake(boxX, boxY, boxW, boxH);
    self.dialogueView.hidden = NO;
    if (self.chatMessagesView) self.chatMessagesView.hidden = YES;   // the dialogue replaces the chat lines
    [self.screen bringSubviewToFront:self.dialogueView];

    // Headless dialogue (user's choice): a FULLY opaque parchment, NO head cutout — clean and alignment-risk-free.
    // The engine's head (still rendered underneath) is simply occluded by the parchment. (Java still publishes the
    // head bounds for a possible future "real head" mode; they are intentionally ignored here.)
    CGRect headInView = CGRectZero;
    [self applyDialogueHeadCutout:headInView];
    self.dialogueContentView.frame = [self dialogueContentFrameForHead:headInView box:self.dialogueView.bounds];

    // The engine CONTINUE widget centre in canvas px (= game coords) so a continue tap precisely clicks the live
    // (occluded) widget — robust regardless of the "space bar to continue" setting. (-1,-1) when absent.
    NSDictionary *cont = [d[@"cont"] isKindOfClass:[NSDictionary class]] ? d[@"cont"] : nil;
    self.dialogueContinuePoint = cont
        ? CGPointMake([cont[@"x"] intValue] + [cont[@"w"] intValue] / 2, [cont[@"y"] intValue] + [cont[@"h"] intValue] / 2)
        : CGPointMake(-1, -1);

    // Re-tag on EVERY pass, not only when the text changes: the rows always belong to the json currently held
    // (a changed text rebuilds them immediately below), so this is simply that json's sequence -- and doing it
    // unconditionally means a sequence that was somehow stale cannot latch. It corrects on the next pass
    // instead of refusing every pick until the dialogue text moves.
    self.dialogueViewSeq = viewSeq;
    if (![js isEqualToString:self.lastDialogueJson]) {
        self.lastDialogueJson = js;
        [self rebuildDialogueContent:d scale:s * sHudScale];
        // One line per new dialogue so a misaligned head cutout / continue target is diagnosable from the log.
        [self appendLine:[NSString stringWithFormat:@"[dlg] type=%@ box=%@ head=%@ cont=(%.0f,%.0f)",
            d[@"type"], NSStringFromCGRect(self.dialogueView.frame), NSStringFromCGRect(headInView),
            self.dialogueContinuePoint.x, self.dialogueContinuePoint.y]];
    }
}

// The text area: the parchment inset by padding, minus the head's column (head on the left -> text to the right,
// and vice-versa). Falls back to the full inset box if the head math degenerates.
- (CGRect)dialogueContentFrameForHead:(CGRect)head box:(CGRect)box {
    CGFloat pad = 6.0;
    CGRect c = CGRectInset(box, pad, pad);
    if (!CGRectIsEmpty(head)) {
        if (CGRectGetMidX(head) < CGRectGetMidX(box)) {
            CGFloat left = CGRectGetMaxX(head) + pad;
            c = CGRectMake(left, CGRectGetMinY(c), CGRectGetMaxX(box) - pad - left, c.size.height);
        } else {
            CGFloat right = CGRectGetMinX(head) - pad;
            c = CGRectMake(pad, CGRectGetMinY(c), right - pad, c.size.height);
        }
        if (c.size.width < 60) c = CGRectInset(box, pad, pad);
    }
    return c;
}

// Mask out the head rectangle so the engine's 3D head (rendered underneath in the frame) shows through; the rest
// stays opaque parchment. Empty rect -> no mask (full parchment, e.g. a level-up / message box with no head).
- (void)applyDialogueHeadCutout:(CGRect)head {
    UIView *v = self.dialogueView;
    if (CGRectIsEmpty(head)) { v.layer.mask = nil; return; }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:v.bounds cornerRadius:4.0];
    [p appendPath:[UIBezierPath bezierPathWithRect:head]];
    p.usesEvenOddFillRule = YES;
    CAShapeLayer *mask = [v.layer.mask isKindOfClass:[CAShapeLayer class]] ? (CAShapeLayer *)v.layer.mask : nil;
    if (!mask) { mask = [CAShapeLayer layer]; mask.fillRule = kCAFillRuleEvenOdd; v.layer.mask = mask; }
    mask.path = p.CGPath;
    [CATransaction commit];
}

- (void)rebuildDialogueContent:(NSDictionary *)d scale:(CGFloat)s {
    for (UIView *v in [self.dialogueStack.arrangedSubviews copy]) {
        [self.dialogueStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    CGFloat fontSize = floor(16.0 * s); if (fontSize < 12) fontSize = 12;
    UIFont *font = [UIFont fontWithName:@"RuneScape" size:fontSize] ?: [UIFont systemFontOfSize:fontSize];
    BOOL isOptions = [d[@"type"] isEqualToString:@"options"];

    NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
    if (name.length) {
        UILabel *nl = [self dialogueLabel:[[NSAttributedString alloc] initWithString:name attributes:@{
            NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithRed:0.50 green:0.0 blue:0.0 alpha:1.0]}]];
        nl.textAlignment = NSTextAlignmentCenter;
        [self.dialogueStack addArrangedSubview:nl];
    }
    if (isOptions) {
        NSString *title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : nil;
        if (title.length) {
            UILabel *tl = [self dialogueLabel:[[NSAttributedString alloc] initWithString:title attributes:@{
                NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithWhite:0.12 alpha:1.0]}]];
            tl.textAlignment = NSTextAlignmentCenter;
            [self.dialogueStack addArrangedSubview:tl];
        }
        NSArray *opts = [d[@"options"] isKindOfClass:[NSArray class]] ? d[@"options"] : @[];
        for (NSDictionary *o in opts) {
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setAttributedTitle:[self dialogueAttrFromDict:o font:font defColor:[UIColor blackColor]] forState:UIControlStateNormal];
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            b.titleLabel.numberOfLines = 0;
            b.tag = [o[@"digit"] integerValue];
            [b setBackgroundImage:[self solidImage:[UIColor colorWithRed:0.55 green:0.42 blue:0.18 alpha:0.45]] forState:UIControlStateHighlighted];
            [b addTarget:self action:@selector(onDialogueOption:) forControlEvents:UIControlEventTouchUpInside];
            [self.dialogueStack addArrangedSubview:b];
        }
    } else {
        UILabel *tl = [self dialogueLabel:[self dialogueAttrFromDict:d font:font defColor:[UIColor blackColor]]];
        tl.textAlignment = NSTextAlignmentCenter;
        [self.dialogueStack addArrangedSubview:tl];
        if ([d[@"continue"] boolValue]) {
            UILabel *hint = [self dialogueLabel:[[NSAttributedString alloc] initWithString:@"Click here to continue"
                attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithRed:0.0 green:0.0 blue:0.55 alpha:1.0]}]];
            hint.textAlignment = NSTextAlignmentCenter;
            [self.dialogueStack addArrangedSubview:hint];
        }
    }
}

- (UILabel *)dialogueLabel:(NSAttributedString *)attr {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.attributedText = attr;
    return l;
}

- (NSAttributedString *)dialogueAttrFromDict:(NSDictionary *)o font:(UIFont *)font defColor:(UIColor *)def {
    NSString *text = [o[@"text"] isKindOfClass:[NSString class]] ? o[@"text"] : @"";
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByWordWrapping;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSForegroundColorAttributeName: def, NSParagraphStyleAttributeName: ps}];
    NSArray *runs = [o[@"runs"] isKindOfClass:[NSArray class]] ? o[@"runs"] : nil;
    NSUInteger tlen = text.length;
    for (NSDictionary *r in runs) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSInteger off = [r[@"o"] integerValue], l = [r[@"l"] integerValue];
        if (off < 0 || l <= 0 || (NSUInteger)(off + l) > tlen) continue;
        NSRange rng = NSMakeRange((NSUInteger)off, (NSUInteger)l);
        UIColor *col = rgbColor([r[@"c"] intValue]);
        if (col) [a addAttribute:NSForegroundColorAttributeName value:col range:rng];
        if ([r[@"u"] intValue] == 1) [a addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:rng];
    }
    return a;
}

- (void)clearDialogueTapTargets {
    self.dialogueContinuePoint = CGPointMake(-1, -1);
    self.dialogueIsOptions = NO;
    self.dialogueIsPrompt = NO;
    self.dialoguePromptList = CGRectZero;
    self.dialogueTargetsKnown = NO;
    self.dialogueOptionRects = nil;
    self.dialogueOptionDigits = nil;
}

// Keep the engine's clickable dialogue widgets (CONTINUE, option rows) current in canvas px for as long as a
// dialogue is open. updateDialogueView used to be the only thing reading them, so they went stale the moment the
// engine began drawing its own dialogue and the native parchment was suppressed -- which is exactly when onTap
// has to resolve a tap on its own.
- (void)updateDialogueTapTargetsActive:(BOOL)active {
    if (!active) {
        [self clearDialogueTapTargets];
        return;
    }
    // While a dialogue IS open, a missing or unparseable publish is a hiccup, not a change of target: KEEP the
    // last good bounds. Blanking them would drop the tap onto the raw-click fallback, which is the very thing
    // that walked the player instead of advancing the dialogue.
    // Read the sequence BEFORE the payload: if a publish lands between the two, the recorded seq is older than
    // the targets built from it, so a pick made against them is refused rather than applied to a dialogue that
    // has already moved on. The other order would accept exactly that stale pick.
    // (This path records the seq UNCONDITIONALLY below, which is what keeps a mid-read publish transient: it
    // corrects on the next poll. Gating that record on a text change would turn it into a latch -- see
    // updateDialogueView.)
    const long long seq = [JVMLauncher dialogueSeq];
    NSString *js = [JVMLauncher dialogueJson];
    if (js.length == 0)
        return;
    NSDictionary *d = parseBridgeJSON(js, "ViewController.updateDialogueTapTargets");
    if (![d isKindOfClass:[NSDictionary class]])
        return;
    NSString *type = [d[@"type"] isKindOfClass:[NSString class]] ? d[@"type"] : nil;
    if (type.length == 0) {
        // "{}" is a deliberate answer, not a hiccup: the bridge models chat/options/message/level-up only, and
        // leaves make-X + object-reward boxes to the engine. Those draw their OWN clickable widgets where the
        // finger lands, so clear the targets and let the raw precise click through for them.
        [self clearDialogueTapTargets];
        return;
    }
    [self clearDialogueTapTargets];
    self.dialogueTargetsKnown = YES;
    self.dialogueTargetsSeq = seq;
    // DIAGNOSTIC: the publish itself, once per change -- shows whether a tap ADVANCED the conversation (a new
    // text line) or ENDED it, which the open/closed lines alone cannot distinguish.
    if (![js isEqualToString:self.lastTargetsJson]) {
        self.lastTargetsJson = js;
        [self appendLine:[NSString stringWithFormat:@"[dlg] %@",
                                                    js.length > 200 ? [js substringToIndex:200] : js]];
    }
    NSDictionary *cont = [d[@"cont"] isKindOfClass:[NSDictionary class]] ? d[@"cont"] : nil;
    if (cont) {
        self.dialogueContinuePoint = CGPointMake([cont[@"x"] intValue] + [cont[@"w"] intValue] / 2,
                                                 [cont[@"y"] intValue] + [cont[@"h"] intValue] / 2);
    }
    if (![type isEqualToString:@"options"])
        return;
    self.dialogueIsOptions = YES;
    self.dialogueIsPrompt = [d[@"prompt"] boolValue];
    NSDictionary *list = [d[@"list"] isKindOfClass:[NSDictionary class]] ? d[@"list"] : nil;
    if (list) {
        self.dialoguePromptList = CGRectMake([list[@"x"] intValue], [list[@"y"] intValue], [list[@"w"] intValue],
                                             [list[@"h"] intValue]);
    }
    NSArray *opts = [d[@"options"] isKindOfClass:[NSArray class]] ? d[@"options"] : @[];
    NSMutableArray *rects = [NSMutableArray arrayWithCapacity:opts.count];
    NSMutableArray *digits = [NSMutableArray arrayWithCapacity:opts.count];
    for (NSDictionary *o in opts) {
        if (![o isKindOfClass:[NSDictionary class]])
            continue;
        NSDictionary *b = [o[@"b"] isKindOfClass:[NSDictionary class]] ? o[@"b"] : nil;
        if (!b)
            continue;
        [rects addObject:[NSValue valueWithCGRect:CGRectMake([b[@"x"] intValue], [b[@"y"] intValue],
                                                             [b[@"w"] intValue], [b[@"h"] intValue])]];
        [digits addObject:@([o[@"digit"] integerValue])];
    }
    self.dialogueOptionRects = rects;
    self.dialogueOptionDigits = digits;
}

// Continue tap -> SPACE (OSRS "space bar to continue"); option tap -> its number key. postText sends the full
// The native parchment's own buttons. Both go through the engine's continue handler, like a tap on the engine
// dialogue does: a precise click on the CONTINUE widget resolves against the SCENE behind the chatbox and walks
// the player instead (the widget is drawn there but reads hidden), and a synthesized key is consumed without
// moving the conversation. Neither was reachable while the parchment stays hidden, which is the only reason the
// walking never showed up here too.
- (void)onDialogueContinue {
    if (!self.dialogueView || self.dialogueView.hidden) return;
    NSString *js = self.lastDialogueJson;
    if (js && [js containsString:@"\"type\":\"options\""]) return;   // options need a choice, not a blind continue
    [JVMLauncher continueEngineDialogue];
    [self appendLine:@"[shell] dialogue continue (continue)"];
}

- (void)onDialogueOption:(UIButton *)b {
    if (self.dialogueIsPrompt) {
        // A prompt's rows are the engine's own search results, not numbered chat options, so there is no digit
        // to send: press the ROW, at the canvas bounds the bridge published for it. The engine never hit-tests
        // that point -- the bridge fires the row's own op -- which is the only thing that reaches a list drawn
        // underneath the Grand Exchange window.
        NSInteger idx = b.tag;
        if (idx < 0 || (NSUInteger)idx >= self.dialogueOptionRects.count)
            return;
        CGRect r = [self.dialogueOptionRects[idx] CGRectValue];
        [JVMLauncher tapEngineDialogueAtX:(int)CGRectGetMidX(r) y:(int)CGRectGetMidY(r)];
        [self appendLine:[NSString stringWithFormat:@"[shell] prompt row %ld (op)", (long)idx]];
        return;
    }
    NSInteger digit = b.tag; // the published child index, straight from the option's "digit"
    if (digit < 1 || digit > 9) return;
    [JVMLauncher selectEngineDialogueOption:(int)digit seq:self.dialogueViewSeq];
    [self appendLine:[NSString stringWithFormat:@"[shell] dialogue option %ld (op)", (long)digit]];
}

// Render the native chat MESSAGE lines (from JVMLauncher.chatLines — the live engine model) into chatMessagesView,
// positioned directly under the tab row. The engine refuses to raster a relocated chatbox, so this IS the chat
// display: colour-run attributed text over the scene, bottom-anchored (newest at the bottom like real OSRS chat).
- (void)updateChatMessagesAtX:(CGFloat)x y:(CGFloat)y width:(CGFloat)w height:(CGFloat)h scale:(CGFloat)s {
    UITextView *mv = self.chatMessagesView;
    if (!mv) return;
    if (self.chatCollapsed) { mv.hidden = YES; return; }   // collapsed -> tab row only, no messages

    NSString *js = [JVMLauncher chatLines];
    if (js.length == 0) { mv.hidden = YES; return; }
    NSDictionary *d = parseBridgeJSON(js, "ViewController.updateChatMessages");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue]) { mv.hidden = YES; return; }
    NSArray *lines = [d[@"lines"] isKindOfClass:[NSArray class]] ? d[@"lines"] : nil;

    mv.frame = CGRectMake(floor(x), floor(y), ceil(w), ceil(h));
    mv.hidden = NO;
    if (lines.count == 0) { mv.attributedText = [[NSAttributedString alloc] initWithString:@""]; return; }

    CGFloat fontSize = floor(14.0 * s);
    if (fontSize < 9) fontSize = 9;
    UIFont *font = [UIFont fontWithName:@"RuneScape" size:fontSize] ?: [UIFont systemFontOfSize:fontSize];

    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [UIColor blackColor];
    shadow.shadowOffset = CGSizeMake(1.0, 1.0);
    shadow.shadowBlurRadius = 0.0;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.alignment = NSTextAlignmentLeft;

    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    for (NSDictionary *ln in lines) {
        if (![ln isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = [ln[@"text"] isKindOfClass:[NSString class]] ? ln[@"text"] : @"";
        if (text.length == 0) continue;
        NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSShadowAttributeName: shadow,
            NSParagraphStyleAttributeName: ps,
        }];
        NSArray *runs = [ln[@"runs"] isKindOfClass:[NSArray class]] ? ln[@"runs"] : nil;
        NSUInteger tlen = text.length;
        for (NSDictionary *r in runs) {
            if (![r isKindOfClass:[NSDictionary class]]) continue;
            NSInteger o = [r[@"o"] integerValue];
            NSInteger l = [r[@"l"] integerValue];
            if (o < 0 || l <= 0 || (NSUInteger)(o + l) > tlen) continue;
            NSRange rng = NSMakeRange((NSUInteger)o, (NSUInteger)l);
            UIColor *col = rgbColor([r[@"c"] intValue]);
            if (col) [line addAttribute:NSForegroundColorAttributeName value:col range:rng];
            if ([r[@"u"] intValue] == 1) {
                [line addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:rng];
            }
        }
        if (out.length > 0) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [out appendAttributedString:line];
    }

    // The bottom input line "PlayerName: typed*" (the engine chat is invisible, so the user types blind otherwise).
    // Always shown while logged in so there's a visible prompt + live echo of what's being typed.
    NSDictionary *input = [d[@"input"] isKindOfClass:[NSDictionary class]] ? d[@"input"] : nil;
    NSString *pname = [input[@"name"] isKindOfClass:[NSString class]] ? input[@"name"] : @"";
    if (pname.length > 0) {
        NSString *typed = [input[@"text"] isKindOfClass:[NSString class]] ? input[@"text"] : @"";
        NSString *inputLine = [NSString stringWithFormat:@"%@: %@*", pname, typed];
        NSDictionary *attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: [UIColor whiteColor],
                                 NSShadowAttributeName: shadow,
                                 NSParagraphStyleAttributeName: ps };
        NSMutableAttributedString *il = [[NSMutableAttributedString alloc] initWithString:inputLine attributes:attrs];
        // Tint the cursor "*" yellow like OSRS.
        [il addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:1.0 green:0.86 blue:0.20 alpha:1.0]
                   range:NSMakeRange(inputLine.length - 1, 1)];
        if (out.length > 0) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [out appendAttributedString:il];
    }

    mv.attributedText = out;

    // Bottom-anchor: newest line flush to the bottom of the box (real OSRS chat grows upward). Short content gets a
    // top inset; overflowing content scrolls to the bottom. (scrollEnabled is on only for this programmatic offset.)
    mv.textContainerInset = UIEdgeInsetsZero;
    [mv layoutIfNeeded];
    CGFloat contentH = mv.contentSize.height;
    CGFloat boxH = mv.bounds.size.height;
    if (contentH < boxH) {
        mv.textContainerInset = UIEdgeInsetsMake(boxH - contentH, 0, 0, 0);
        [mv setContentOffset:CGPointZero animated:NO];
    } else {
        [mv setContentOffset:CGPointMake(0, contentH - boxH) animated:NO];
    }
}

// Resolve the live engine chat-button centre (canvas px) for native button tag i, from the chat snapshot bounds.
// Returns NO if the engine button isn't built/visible this frame.
- (BOOL)engineChatButtonCenterForTag:(NSInteger)i x:(int *)cx y:(int *)cy {
    NSString *snap = [JVMLauncher chatSnapshot];
    if (snap.length == 0) return NO;
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.engineChatButtonCenterForTag");
    NSArray *tabs = [d isKindOfClass:[NSDictionary class]] ? d[@"tabs"] : nil;
    if (![tabs isKindOfClass:[NSArray class]] || i < 0 || i >= (NSInteger)tabs.count) return NO;
    NSDictionary *t = [tabs[i] isKindOfClass:[NSDictionary class]] ? tabs[i] : nil;
    if (!t) return NO;
    int bx = [t[@"x"] intValue], by = [t[@"y"] intValue], bw = [t[@"w"] intValue], bh = [t[@"h"] intValue];
    if (bw <= 0 || bh <= 0 || bx < 0 || by < 0) return NO;   // engine button not built / not visible this frame
    if (self.visibleH > 0 && by >= self.visibleH)
        return NO; // shoved off-screen (e.g. while the chat is collapsed)
    *cx = bx + bw / 2; *cy = by + bh / 2;
    return YES;
}

// Tap a chat tab -> switch to that channel (reopening the box if it was collapsed). Tapping the ALREADY-active
// tab collapses the box (OSRS-mobile behaviour); the static tab row stays so a tap reopens it.
- (void)onChatTabButton:(UIButton *)b {
    if (![JVMLauncher bridgeReady]) return;
    if (!self.chatCollapsed && b.tag == self.chatActiveTab && b.tag < kChatTabCount) {
        // Tapping the active tab COLLAPSES the box — no op-replay (that would re-render the box the engine still
        // has shown); the native tab row stays visible so a tap reopens it.
        self.chatCollapsed = YES;
        [JVMLauncher setEngineChatCollapsed:YES];
        [self updateChatTabs];
        [self appendLine:[NSString stringWithFormat:@"[chat] tab %ld (%@) -> collapse", (long)b.tag, kChatTabNames[b.tag]]];
        return;
    }
    // Switch to the tapped tab (reopening the box if it was collapsed) by replaying its op-script.
    if (self.chatCollapsed) {
        self.chatCollapsed = NO;
        [JVMLauncher setEngineChatCollapsed:NO];
    }
    [JVMLauncher switchEngineChatTab:(int)b.tag];
    // Instant highlight: the tapped tab is now the active view; show it selected immediately (the engine's own tab
    // sprite, which the snapshot reads, only updates on a redraw).
    self.optimisticChatTab = b.tag;
    self.optimisticChatAt = CACurrentMediaTime();
    [self updateChatTabs];   // reflect the new selection this frame, don't wait for the next 10Hz tick
    [self appendLine:[NSString stringWithFormat:@"[chat] tab %ld (%@) -> op-replay switch",
                      (long)b.tag, kChatTabNames[b.tag]]];
}

// Long-press a filterable channel's tab -> open the engine's filter menu (On/Filter/Off/Hide …) at the live
// engine button centre, then drag-to-highlight / release-to-select via the native big-row menu overlay (the same
// path as the world-object long-press). All/Game have no filter, so a long-press there is a no-op.
- (void)onChatTabLongPress:(UILongPressGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady]) return;
    UIButton *b = (UIButton *)g.view;
    if (b.tag < 0 || b.tag >= kChatTabCount || !kChatTabFilterable[b.tag]) return;
    CGPoint loc = [g locationInView:self.view];
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            // A collapsed chat keeps its filter stones up, so the menu opens on the stone either way.
            int cx = 0, cy = 0;
            if (![self engineChatButtonCenterForTag:b.tag x:&cx y:&cy]) return;
            [self openEngineMenuAtGameX:cx gameY:cy anchor:loc];
            [self haptic:RMHapticMenuOpen];
            [self appendLine:[NSString stringWithFormat:@"[chat] tab %ld (%@) long-press -> filter menu @%d,%d",
                              (long)b.tag, kChatTabNames[b.tag], cx, cy]];
            break;
        }
        case UIGestureRecognizerStateChanged:
            [self updateMenuHighlightForPoint:[g locationInView:self.screen]];
            break;
        case UIGestureRecognizerStateEnded:
            [self commitMenuSelection];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self cancelMenu];
            break;
        default:
            break;
    }
}

// Lay out the native tab rails from the read-only chrome snapshot — EDGE-SPLIT (mobile) arrangement, matching
// the official OSRS-Mobile app: two SINGLE-column vertical rails, one on each screen edge (tab indices 0–6 on
// the left, 7–13 on the right — the desktop's own STONE grouping). Each cell is an individual semi-transparent
// rounded square with the icon blitted from the live desktop stone; the active tab (TOPLEVEL_PANEL) is
// accented. A tap proxies a click onto the REAL stone centre (stored in _tabCentres), so the native rail's
// position is independent of the desktop stone — no game widget is moved or hidden. Hides everything when not
// logged in / no tabs.
// FIX-9 (iOS parity): build the native "Reconnecting…" scrim once — a full-screen dim + a centered OSRS-styled
// card (dark brown, amber border) with a spinner and label, mirroring Android's ReconnectingOverlayView.
// Non-interactive (touches fall through, matching Android isClickable=false); hidden until the snapshot shows
// an active reconnect. Built with autoresizing + Auto Layout so it tracks rotation/size.
- (void)setupReconnectOverlay {
    if (self.reconnectScrim) return;
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.59];
    scrim.userInteractionEnabled = NO;   // touches fall through to the game (parity with Android)
    scrim.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:33/255.0 green:28/255.0 blue:23/255.0 alpha:0.93];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:140/255.0 green:128/255.0 blue:102/255.0 alpha:1.0].CGColor;
    [scrim addSubview:card];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.color = [UIColor colorWithRed:1.0 green:0.78 blue:0.35 alpha:1.0]; // OSRS amber
    spin.hidesWhenStopped = NO;
    [card addSubview:spin];
    self.reconnectSpinner = spin;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Reconnecting…";
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    [card addSubview:label];

    [self.view addSubview:scrim];
    self.reconnectScrim = scrim;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:240],
        [card.heightAnchor constraintEqualToConstant:140],
        [spin.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spin.topAnchor constraintEqualToAnchor:card.topAnchor constant:34],
        [label.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-28],
    ]];
}

// Boot-progress overlay: structurally identical to the reconnect scrim (same OSRS dark-brown/amber card), with
// two deltas - the label reads "Starting up…" and the scrim BLOCKS touches (unlike the reconnect scrim, there is
// no live game underneath yet during cold boot). Armed on the Play tap, cleared by updateBootStatusOverlay.
- (void)setupBootStatusOverlay {
    if (self.bootStatusScrim)
        return;
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.59];
    scrim.userInteractionEnabled = YES; // nothing runs underneath yet - swallow touches
    scrim.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:33 / 255.0 green:28 / 255.0 blue:23 / 255.0 alpha:0.93];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:140 / 255.0 green:128 / 255.0 blue:102 / 255.0 alpha:1.0].CGColor;
    [scrim addSubview:card];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.color = [UIColor colorWithRed:1.0 green:0.78 blue:0.35 alpha:1.0]; // OSRS amber
    spin.hidesWhenStopped = NO;
    [card addSubview:spin];
    self.bootStatusSpinner = spin;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Starting up…";
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    [card addSubview:label];

    [self.view addSubview:scrim];
    self.bootStatusScrim = scrim;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:240],
        [card.heightAnchor constraintEqualToConstant:140],
        [spin.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spin.topAnchor constraintEqualToAnchor:card.topAnchor
                                       constant:34],
        [label.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                           constant:-28],
    ]];
}

// Phase 4 cold start: a first-frame milestone, stamped with the time since the process started. On the shell log
// line, and as a [coldstart] line on stderr, which jvm-stdio.log (Debug) or perf-probe.log (Release, perf probe
// armed) keeps beside the frame lines.
- (void)stampColdStart:(NSString *)milestone line:(NSString *)line {
    long ms = [JVMLauncher msSinceProcessStart];
    [self appendLine:[NSString stringWithFormat:@"%@ sinceStartMs=%ld", line, ms]];
    fprintf(stderr, "[coldstart] %s sinceStartMs=%ld\n", milestone.UTF8String, ms);
}

// Phase 4 cold start: the first tick that finds the client LOGGED_IN (the baseline's "first in-world frame"). Reads
// the chrome snapshot ~10 Hz until then, and never again after.
- (void)stampFirstInWorld {
    if (self.inWorldStamped)
        return;
    NSDictionary *d = parseBridgeJSON([JVMLauncher chromeSnapshot], "ViewController.stampFirstInWorld");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue])
        return;
    self.inWorldStamped = YES;
    [self stampColdStart:@"inWorld" line:@"[shell] onboard: first logged-in tick"];
}

// Disable the idle timer while in game so the phone does not auto-lock mid-session. A loading/teleport blip reports
// loggedIn=false for a moment, so the timer is only re-enabled after kKeepAwakeGrace seconds out of game.
static const CFTimeInterval kKeepAwakeGrace = 10.0;
- (void)updateKeepAwake {
    NSDictionary *d = parseBridgeJSON([JVMLauncher chromeSnapshot], "ViewController.updateKeepAwake");
    BOOL loggedIn = [d isKindOfClass:[NSDictionary class]] && [d[@"loggedIn"] boolValue];
    CFTimeInterval now = CACurrentMediaTime();
    if (self.awakeInGame && !loggedIn)
        self.awakeLeftGameAt = now;
    self.awakeInGame = loggedIn;
    BOOL want = loggedIn || (self.awakeLeftGameAt > 0 && now - self.awakeLeftGameAt < kKeepAwakeGrace);
    UIApplication *app = [UIApplication sharedApplication];
    if (app.idleTimerDisabled != want) {
        app.idleTimerDisabled = want;
        [self appendLine:[NSString stringWithFormat:@"[shell] keep-awake -> %@", want ? @"YES" : @"NO"]];
    }
}

// Clear the boot overlay the moment real content is ready: the first painted frame (renderedFrameWidth > 0),
// a fatal-error card taking over (fatalErrorShown - hands off to that card so the two never stack), or the 60s
// failsafe (a boot that never produces a frame must not wedge the UI). One-way: once hidden it stays hidden.
- (void)updateBootStatusOverlay {
    if (!self.bootStatusScrim || self.bootStatusScrim.hidden)
        return;
    BOOL firstFrame = [JVMLauncher renderedFrameWidth] > 0;
    BOOL timedOut = CACurrentMediaTime() >= self.bootStatusDeadline;
    if (firstFrame || self.fatalErrorShown || timedOut) {
        self.bootStatusScrim.hidden = YES;
        [self.bootStatusSpinner stopAnimating];
        [self stampColdStart:firstFrame ? @"firstFrame" : (timedOut ? @"bootTimeout" : @"bootFatal")
                        line:[NSString stringWithFormat:@"[shell] onboard: boot overlay dismissed (frame=%@ timeout=%@)",
                                                        firstFrame ? @"YES" : @"NO", timedOut ? @"YES" : @"NO"]];
    }
}

// PARITY-P0-3: build the world-hop scrim once, structurally identical to the reconnect scrim (same OSRS-styled
// dark-brown/amber-border card, non-interactive so touches fall through). The label defaults to "Switching
// worlds…" and is overwritten per-hop by armHopScrim:.
- (void)setupHoppingOverlay {
    if (self.hoppingScrim)
        return;
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.59];
    scrim.userInteractionEnabled = NO; // touches fall through to the game (parity with Android)
    scrim.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:33 / 255.0 green:28 / 255.0 blue:23 / 255.0 alpha:0.93];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:140 / 255.0 green:128 / 255.0 blue:102 / 255.0 alpha:1.0].CGColor;
    [scrim addSubview:card];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    spin.color = [UIColor colorWithRed:1.0 green:0.78 blue:0.35 alpha:1.0]; // OSRS amber
    spin.hidesWhenStopped = NO;
    [card addSubview:spin];
    self.hoppingSpinner = spin;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Switching worlds…";
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    [card addSubview:label];
    self.hoppingLabel = label;

    [self.view addSubview:scrim];
    self.hoppingScrim = scrim;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:240],
        [card.heightAnchor constraintEqualToConstant:140],
        [spin.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spin.topAnchor constraintEqualToAnchor:card.topAnchor
                                       constant:34],
        [label.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                           constant:-28],
    ]];
}

// PARITY-P0-3: arm the hop scrim (mirrors Android's armHopScrim). Shown EAGERLY here — before the engine's
// logout chrome can flash through — so it is up the moment the user taps a hop control. Cleared later by
// updateHoppingOverlay on the loggedIn edge or the 12 s deadline.
- (void)armHopScrim:(NSString *)label {
    if (!self.hoppingScrim)
        return;
    self.hoppingLabel.text = label;
    self.hopArmed = YES;
    self.hopSawLoggedOut = NO;
    self.hopDeadlineAt = CFAbsoluteTimeGetCurrent() + 12.0; // matches Android HOP_TIMEOUT_MS = 12_000L
    self.hoppingShown = YES;
    self.hoppingScrim.hidden = NO;
    [self.view bringSubviewToFront:self.hoppingScrim];
    [self.hoppingSpinner startAnimating];
    [self appendLine:[NSString stringWithFormat:@"[shell] onboard: hop scrim armed (%@)", label]];
}

// PARITY-P0-3: clear the hop scrim once the client is logged back in after the relog (backInWorld edge) or the
// 12 s deadline lapses. Called ~10 Hz from onDisplayTick, UNGATED (the hop happens while NOT logged in, so it
// must not sit behind the chromeVisible/loggedIn-gated updaters). Mirrors MainActivity.updateChrome's clear block.
- (void)updateHoppingOverlay {
    if (!self.hoppingScrim)
        return;
    if (self.hopArmed) {
        NSDictionary *d = parseBridgeJSON([JVMLauncher chromeSnapshot], "ViewController.updateHoppingOverlay");
        BOOL loggedIn = [d isKindOfClass:[NSDictionary class]] && [d[@"loggedIn"] boolValue];
        if (!loggedIn)
            self.hopSawLoggedOut = YES;
        BOOL timedOut = CFAbsoluteTimeGetCurrent() >= self.hopDeadlineAt;
        BOOL backInWorld = loggedIn && self.hopSawLoggedOut;
        if (backInWorld || timedOut) {
            self.hopArmed = NO;
            [self appendLine:[NSString stringWithFormat:@"[shell] onboard: hop scrim clear (backInWorld=%@ timeout=%@)",
                                                        backInWorld ? @"YES" : @"NO", timedOut ? @"YES" : @"NO"]];
        }
    }
    if (self.hopArmed != self.hoppingShown) {
        self.hoppingShown = self.hopArmed;
        self.hoppingScrim.hidden = !self.hopArmed;
        if (self.hopArmed) {
            [self.view bringSubviewToFront:self.hoppingScrim];
            [self.hoppingSpinner startAnimating];
        } else {
            [self.hoppingSpinner stopAnimating];
        }
        [self appendLine:[NSString stringWithFormat:@"[shell] onboard: hop scrim -> %@", self.hopArmed ? @"YES" : @"NO"]];
    }
}

// PARITY-P0-3: the modally-presented WorldSwitcherViewController has no back-reference to this root VC, so it
// signals a hop start via NSNotificationCenter (mirroring Android's decoupled MainActivity.armHopScrimHook).
- (void)onHopScrimArmed:(NSNotification *)note {
    [self armHopScrim:note.userInfo[@"label"] ?: @"Switching worlds…"];
}

// FIX-9 (iOS parity): show the scrim while the headless auto-reconnect recovers a dropped session. The snapshot
// carries "reconnecting":true only during an active recovery (a normal login screen / deliberate logout omits
// it), so a plain login is never covered. Called ~10 Hz from onDisplayTick, UNGATED by login/chrome — the
// reconnect happens while NOT logged in, so it can't sit behind the chromeVisible/loggedIn early-returns.
- (void)updateReconnectOverlay {
    if (!self.reconnectScrim) return;
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateReconnectOverlay");
    BOOL show = [d isKindOfClass:[NSDictionary class]] && ![d[@"loggedIn"] boolValue] && [d[@"reconnecting"] boolValue];
    if (show == self.reconnectShown) return;
    self.reconnectShown = show;
    self.reconnectScrim.hidden = !show;
    if (show) { [self.view bringSubviewToFront:self.reconnectScrim]; [self.reconnectSpinner startAnimating]; }
    else { [self.reconnectSpinner stopAnimating]; }
    [self appendLine:[NSString stringWithFormat:@"[shell] fix9: reconnect overlay -> %@", show ? @"YES" : @"NO"]];
}

// UX-LOGIN-01: build the "Session expired" card once — same OSRS-styled dark-brown/amber-border card as the
// reconnect scrim, but INTERACTIVE (the scrim eats touches — the engine login screen underneath is dead) with
// a "Sign in again" button that re-runs the on-device Jagex login. Mirrors Android's SessionExpiredOverlayView.
- (void)setupSessionExpiredOverlay {
    if (self.sessionExpiredScrim)
        return;
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.74];
    scrim.userInteractionEnabled = YES; // consume touches while visible (parity with Android isClickable)
    scrim.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:33 / 255.0 green:28 / 255.0 blue:23 / 255.0 alpha:0.94];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:140 / 255.0 green:128 / 255.0 blue:102 / 255.0 alpha:1.0].CGColor;
    [scrim addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Session expired";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.text = @"Your session has ended.\nSign in again to keep playing.";
    body.numberOfLines = 2;
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor colorWithRed:210 / 255.0 green:198 / 255.0 blue:170 / 255.0 alpha:1.0];
    body.textAlignment = NSTextAlignmentCenter;
    [card addSubview:body];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:@"Sign in again" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [btn setTitleColor:[UIColor colorWithRed:255 / 255.0 green:230 / 255.0 blue:170 / 255.0 alpha:1.0]
              forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:92 / 255.0 green:72 / 255.0 blue:38 / 255.0 alpha:1.0];
    btn.layer.cornerRadius = 8;
    btn.layer.borderWidth = 1.5;
    btn.layer.borderColor = [UIColor colorWithRed:180 / 255.0 green:150 / 255.0 blue:96 / 255.0 alpha:1.0].CGColor;
    [btn addTarget:self action:@selector(onSessionExpiredSignIn) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:btn];

    [self.view addSubview:scrim];
    self.sessionExpiredScrim = scrim;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],
        [card.heightAnchor constraintEqualToConstant:196],
        [title.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor
                                        constant:26],
        [body.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                       constant:12],
        [btn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [btn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                         constant:-22],
        [btn.widthAnchor constraintEqualToConstant:252],
        [btn.heightAnchor constraintEqualToConstant:46],
    ]];
}

// The login screen's own buttons run along the bottom, under the pinned keys and the hotkey strip: the world switcher
// sat behind the camera arrows. No key acts on that screen, so they stand down until the player is back in the game.
- (void)updateLoginScreenControls {
    NSDictionary *d = parseBridgeJSON([JVMLauncher chromeSnapshot], "ViewController.updateLoginScreenControls");
    BOOL login = [d isKindOfClass:[NSDictionary class]] && [d[@"loginScreen"] boolValue];
    if (login == self.onLoginScreen)
        return;
    self.onLoginScreen = login;
    self.controlsBox.hidden = login || self.mapOpen;
    self.hotkeyStrip.hidden = login || !self.hotkeyStripVisible;
}

// UX-LOGIN-01: drive the card from the snapshot's give-up flag (~10 Hz from onDisplayTick, ungated by
// login/chrome for the same reason as the reconnect updater: it only ever shows while NOT logged in).
- (void)updateSessionExpiredOverlay {
    if (!self.sessionExpiredScrim)
        return;
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateSessionExpiredOverlay");
    BOOL show = [d isKindOfClass:[NSDictionary class]] && ![d[@"loggedIn"] boolValue] && [d[@"sessionExpired"] boolValue];
    if (show == self.sessionExpiredShown)
        return;
    self.sessionExpiredShown = show;
    self.sessionExpiredScrim.hidden = !show;
    if (show) {
        [self.view bringSubviewToFront:self.sessionExpiredScrim];
    }
    [self appendLine:[NSString stringWithFormat:@"[shell] ux-login: session-expired card -> %@", show ? @"YES" : @"NO"]];
}

// UX-LOGIN-01: "Sign in again" — re-run the on-device Jagex login over the parked client. Loading WebKit
// while the JVM runs re-raises the debugger-displacement hazard the boot-time bp-restore exists for (WebKit
// can steal the task EXC_BREAKPOINT port -> a JIT brk goes unserviced -> SIGTRAP), so after the web view is
// up we re-point BREAKPOINT back at the debugger. The login flow itself already handles the rest: tokens are
// persisted and the user is prompted into a fresh-process restart that goes straight to play.
- (void)onSessionExpiredSignIn {
    [self appendLine:@"[shell] ux-login: session expired — re-running the on-device Jagex login"];
    [self onLoginWithJagex];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [JVMLauncher restoreBreakpointPortNow:^(NSString *line) {
            [self appendLine:line];
        }];
    });
}

// FATAL-1: build the fatal-error card once — same OSRS-styled interactive card as the session-expired one,
// but with per-code title/body (set on show) and a single "Close app" action: the applet is dead, so the
// only path forward is a fresh process (and, after a weekly OSRS update, a rebuilt app).
- (void)setupFatalErrorOverlay {
    if (self.fatalErrorScrim)
        return;
    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.80];
    scrim.userInteractionEnabled = YES; // terminal state — nothing underneath is interactable anyway
    scrim.hidden = YES;

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:33 / 255.0 green:28 / 255.0 blue:23 / 255.0 alpha:0.96];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:140 / 255.0 green:128 / 255.0 blue:102 / 255.0 alpha:1.0].CGColor;
    [scrim addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];
    self.fatalErrorTitle = title;

    UILabel *body = [[UILabel alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.numberOfLines = 0;
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor colorWithRed:210 / 255.0 green:198 / 255.0 blue:170 / 255.0 alpha:1.0];
    body.textAlignment = NSTextAlignmentCenter;
    [card addSubview:body];
    self.fatalErrorBody = body;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:@"Close app" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [btn setTitleColor:[UIColor colorWithRed:255 / 255.0 green:230 / 255.0 blue:170 / 255.0 alpha:1.0]
              forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:92 / 255.0 green:72 / 255.0 blue:38 / 255.0 alpha:1.0];
    btn.layer.cornerRadius = 8;
    btn.layer.borderWidth = 1.5;
    btn.layer.borderColor = [UIColor colorWithRed:180 / 255.0 green:150 / 255.0 blue:96 / 255.0 alpha:1.0].CGColor;
    [btn addTarget:self action:@selector(onFatalErrorClose) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:btn];

    [self.view addSubview:scrim];
    self.fatalErrorScrim = scrim;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:320],
        [title.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor
                                        constant:24],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                           constant:20],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                            constant:-20],
        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                       constant:12],
        [btn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [btn.topAnchor constraintEqualToAnchor:body.bottomAnchor
                                      constant:18],
        [btn.widthAnchor constraintEqualToConstant:252],
        [btn.heightAnchor constraintEqualToConstant:46],
        [card.bottomAnchor constraintEqualToAnchor:btn.bottomAnchor
                                          constant:20],
    ]];
}

// FATAL-1: per-code copy. js5connect after the weekly OSRS update = stale client rev — the honest headline
// case (the fix is a rebuilt app, or you're offline); js5io = blocked/flaky connection; crash = engine died.
+ (NSArray<NSString *> *)fatalCopyForCode:(NSString *)code {
    if ([code isEqualToString:@"error_game_js5connect"]) {
        return @[
            @"Can't reach the game servers",
            @"Old School RuneScape may have just updated — after a weekly game update this app needs a "
            @"rebuilt release before it can connect. Install the newest build of the app, or if you're "
            @"offline, check your connection and reopen the app."
        ];
    }
    if ([code isEqualToString:@"error_game_js5io"]) {
        return @[
            @"Connection to the update server failed",
            @"The connection to the game's update server was interrupted or blocked. Check your network "
            @"(a firewall or captive portal can block it), then reopen the app."
        ];
    }
    if ([code isEqualToString:@"error_game_crash"]) {
        return @[
            @"The game crashed",
            @"Close and reopen the app to get back in. If this keeps happening, disable recently added "
            @"plugins before reconnecting."
        ];
    }
    return @[
        @"The game stopped",
        [NSString stringWithFormat:@"Close and reopen the app to get back in. (code: %@)", code ?: @"unknown"]
    ];
}

// PARITY-P0-6: map runProbesWithLog's documented negative boot-failure codes to a [title, body] pair, mirroring
// Android's bootJvm copy. -10 missing embedded JRE, -11 missing probes.jar/routec-l1.jar, -12 dlopen(libjvm),
// -13 dlsym, -14 JNI_CreateJavaVM. Same default-fallback shape as fatalCopyForCode:.
+ (NSArray<NSString *> *)bootFailureCopyForCode:(int)rc {
    switch (rc) {
        case -10:
            return @[
                @"Game runtime missing",
                @"The embedded Java runtime didn't install completely. Reopen the app to retry; if it keeps "
                @"failing, reinstall it."
            ];
        case -11:
            return @[
                @"Game files missing",
                @"Some of the game's files didn't install completely. Reopen the app to retry; if it keeps "
                @"failing, reinstall it."
            ];
        case -12:
        case -13:
        case -14:
            return @[
                @"Couldn't start the game",
                [NSString stringWithFormat:@"The game's Java runtime failed to start (code %d). Close and reopen "
                                           @"the app to retry; if it keeps failing, reinstall it.",
                                           rc]
            ];
        default:
            return @[
                @"Couldn't start the game",
                [NSString stringWithFormat:@"The game's Java runtime failed to start (code %d). Close and reopen "
                                           @"the app to retry; if it keeps failing, reinstall it.",
                                           rc]
            ];
    }
}

// FATAL-1: drive the card from the snapshot's fatal flag (~10 Hz slot, ungated — a fatal can land at any
// point of the session). The bridge makes fatal outrank reconnecting/sessionExpired, so the overlays never
// co-fire; latch-once (never hides) because a fatal is terminal for this process.
- (void)updateFatalErrorOverlay {
    if (!self.fatalErrorScrim || self.fatalErrorShown)
        return;
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateFatalErrorOverlay");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"fatalError"] boolValue])
        return;
    NSString *code = [d[@"fatalCode"] isKindOfClass:[NSString class]] ? d[@"fatalCode"] : @"unknown";
    NSArray<NSString *> *copy = [ViewController fatalCopyForCode:code];
    self.fatalErrorTitle.text = copy[0];
    self.fatalErrorBody.text = copy[1];
    self.fatalErrorShown = YES;
    self.fatalErrorScrim.hidden = NO;
    [self.view bringSubviewToFront:self.fatalErrorScrim];
    [self appendLine:[NSString stringWithFormat:@"[shell] fatal: engine-fatal card shown (code=%@)", code]];
}

// PARITY-P0-6: show the reused FATAL-1 card for a pre-boot JVM failure, PUSHED directly (unlike
// updateFatalErrorOverlay, which polls the live bridge — a failed boot has no bridge to poll yet). Uses the same
// scrim/title/body views, already built by setupFatalErrorOverlay (called on onLaunch before the JVM thread).
- (void)showBootFailureWithTitle:(NSString *)title lines:(NSArray<NSString *> *)lines {
    if (!self.fatalErrorScrim || self.fatalErrorShown)
        return;
    self.fatalErrorTitle.text = title;
    self.fatalErrorBody.text = [lines componentsJoinedByString:@"\n"];
    self.fatalErrorShown = YES;
    self.fatalErrorScrim.hidden = NO;
    [self.view bringSubviewToFront:self.fatalErrorScrim];
    [self appendLine:[NSString stringWithFormat:@"[shell] boot-failure card shown: %@", title]];
}

// PARITY-P0-6: map a boot rc to copy + show the card, hopping to the main queue (called from the jvm-main
// thread). Split out of the boot thread block so the failure path is a single call at the call site.
// PARITY-P0-6: run the JVM probes on the jvm-main thread and, on a negative rc, surface the boot-failure card.
// Split out of the NSThread block so the block body itself is untouched.
- (void)runVmProbesAndReport:(JVMLauncher *)launcher log:(JVMLogSink)log {
    int rc = [launcher runProbesWithLog:log];
    [self reportBootFailure:rc];
}

- (void)reportBootFailure:(int)rc {
    if (rc == 0)
        return; // successful boot (runProbesWithLog ran the VM); nothing to report
    NSArray<NSString *> *copy = [ViewController bootFailureCopyForCode:rc];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendLine:[NSString stringWithFormat:@"[shell] JVM boot FAILED rc=%d", rc]];
        [self showBootFailureWithTitle:copy[0] lines:@[ copy[1] ]];
    });
}

- (void)onFatalErrorClose {
    exit(0); // same as promptRestartToPlay's restart: the applet is dead; a fresh process is the only recovery
}

// PERF-MEMORY-THERMAL-01: read the LIVE 117HD sceneResolutionScale off the config bridge. Returns -1 while
// the config isn't readable (bridge not up / plugin config not loaded) so the caller defers instead of
// restoring a wrong default — the governor must never raise a user's deliberately lower scale.
- (int)heatReadScale {
    NSString *json = [JVMLauncher mobilePluginConfig:@"hd"];
    if (json.length == 0)
        return -1;
    NSDictionary *d = parseBridgeJSON(json, "ViewController.heatReadScale");
    if (![d isKindOfClass:[NSDictionary class]])
        return -1;
    for (NSDictionary *item in d[@"items"]) {
        if ([item isKindOfClass:[NSDictionary class]] && [item[@"key"] isEqual:@"sceneResolutionScale"]) {
            int v = [item[@"value"] intValue];
            return v > 0 ? v : -1;
        }
    }
    return -1;
}

#if TARGET_OS_SIMULATOR
// The simulator's phone is always cool and never in Low Power Mode. The "heat" driver command stands in for those
// readings, so ios/dev-tools/diagnostics/sim-heat-check.py can run the steps; negative means use the real reading.
static int simHeatThermal = -1;
static int simHeatLowPower = -1;
#endif

// One look at the phone: sets the limits its heat calls for, and leaves a reading for Share logs. See the property
// block for the contract. Cheap: counter reads and an enum compare, plus a bridge write on a change, and on 117HD a read
// of its config while a limit is in force.
- (void)heatTick {
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSInteger thermal = pi.thermalState;
    BOOL lowPower = pi.lowPowerModeEnabled;
#if TARGET_OS_SIMULATOR
    if (simHeatThermal >= 0)
        thermal = simHeatThermal;
    if (simHeatLowPower >= 0)
        lowPower = simHeatLowPower > 0;
#endif
    UIDevice *device = [UIDevice currentDevice];
    if (!self.heatPolicy) {
        self.heatPolicy = [[RMHeatPolicy alloc] init];
        self.heatScaleKeeper = [[RMHeatScaleKeeper alloc] initWithStore:self];
        device.batteryMonitoringEnabled = YES;
    }
    CFTimeInterval now = CACurrentMediaTime();
    RMHeatLimit limit = [self.heatPolicy limitForThermalState:thermal lowPower:lowPower at:now];
    if (limit.fps != self.heatFpsLimit && [JVMLauncher setHeatFpsCap:limit.fps]) {
        [self appendLine:[NSString stringWithFormat:@"[heat] thermal state=%ld lowPower=%d -> frame-rate limit %d->%d",
                                                    (long)thermal, (int)lowPower, self.heatFpsLimit, limit.fps]];
        self.heatFpsLimit = limit.fps;
    }
    // A backgrounded app may not touch the GPU, and 117HD does to change its scale. The step waits for the foreground.
    // The resolution comes down only if the player has said it may (Game settings > Lower resolution when hot).
    // Without that the keeper is given no limit, so it just puts back anything an earlier throttle took, and a phone
    // hot enough for a lower resolution offers the switch instead.
    BOOL lowerResolution = [RMGameSettings heatLowerResolution];
    BOOL onScreen = self.pendingRouteCZone && !self.appBackgrounded;
    if (onScreen)
        [self.heatScaleKeeper stepWithLimit:lowerResolution ? limit.scalePercent : 0 thermal:thermal];
    // The offer is for a phone that's hot now, not one the policy still holds a limit on while it cools.
    if (onScreen && !lowerResolution && thermal >= NSProcessInfoThermalStateSerious)
        [self offerHeatNotice];
    else
        self.heatNoticeCalmSince = 0; // a calm spell starts over once it's hot again

    // Whichever counter moved: the engine's, or the frames handed to the screen, because 117HD's direct present never
    // bumps the engine's, and before the world loads it is the engine that draws.
    long seq = MAX(self.heatEngineFrames, (long)[JVMLauncher renderedFrameSeq]); // -1 when the bridge can't say
    long presents = [RouteCBridge presentedFrameCount];
    long frames = MAX(seq - self.heatEngineFrames, presents - self.heatPresentedFrames);
    self.heatEngineFrames = seq;
    self.heatPresentedFrames = presents;
    long long gameCpu = [JVMLauncher gameThreadCpuNanos]; // -1 until the game can say
    long gpuWait = [RouteCBridge gpuWaitNanos];
    double appCpu = RMAppCpuSeconds();
    RMHeatReading reading = {
        .thermalState = thermal,
        .lowPower = lowPower,
        .background = self.appBackgrounded,
        .frames = (int)frames,
        .gameCpuSeconds = gameCpu >= 0 && self.heatGameCpuNanos >= 0 ? (gameCpu - self.heatGameCpuNanos) / 1e9 : -1,
        .gpuWaitSeconds = (gpuWait - self.heatGpuWaitNanos) / 1e9,
        .appCpuSeconds = MAX(appCpu - self.heatAppCpuSeconds, 0),
        .batteryState = (int)device.batteryState,
        .batteryLevel = device.batteryLevel,
        .fpsLimit = self.heatFpsLimit,
        .scalePercent = self.pendingRouteCZone ? self.heatScaleKeeper.appliedScale : 0,
        .baselineScale = self.pendingRouteCZone ? self.heatScaleKeeper.baselineScale : 0,
        .lowerResolution = lowerResolution,
    };
    self.heatGameCpuNanos = gameCpu;
    self.heatGpuWaitNanos = gpuWait;
    self.heatAppCpuSeconds = appCpu;
    [RMHeatLog.shared addReading:reading at:now];
    [self applyNewInstallDefaults];
}

// Out of combat this long before the hot-phone notice may appear, and it goes by itself after kHeatNoticeSeconds.
static const CFTimeInterval kHeatNoticeCalmSeconds = 10.0;
static const CFTimeInterval kHeatNoticeSeconds = 20.0;
static const CGFloat kHeatNoticeWideMin = 460; // narrower than this, the notice stacks its buttons under the text

// The phone is hot enough that 117HD's resolution would come down, but the player hasn't allowed it. Offers the
// switch once a launch, and never in a fight: it waits until the player has been logged in, out of combat and on the
// plain game screen for kHeatNoticeCalmSeconds. Even then it takes no touch but its own two buttons.
- (void)offerHeatNotice {
    if (self.heatNoticeOffered || self.heatNotice || [RMGameSettings heatNoticeOff])
        return;
    CFTimeInterval now = CACurrentMediaTime();
    if (![self heatNoticeCalm]) {
        self.heatNoticeCalmSince = 0;
        return;
    }
    if (self.heatNoticeCalmSince == 0)
        self.heatNoticeCalmSince = now;
    if (now - self.heatNoticeCalmSince >= kHeatNoticeCalmSeconds)
        [self showHeatNotice];
}

// Logged in, not fighting, and nothing else over the game. NO when the game can't say.
- (BOOL)heatNoticeCalm {
    if (self.appBackgrounded || self.mapOpen || self.presentedViewController || !self.layoutSwitchButton.hidden)
        return NO;
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.heatNoticeCalm") : nil;
    return [d isKindOfClass:[NSDictionary class]] && [d[@"loggedIn"] boolValue] && ![d[@"inCombat"] boolValue];
}

- (void)showHeatNotice {
    self.heatNoticeOffered = YES;
    __weak typeof(self) ws = self;
    RMHeatNoticeView *v = [[RMHeatNoticeView alloc]
        initWithTurnOn:^{
            [RMGameSettings setHeatLowerResolution:YES];
            [ws hideHeatNotice:@"turned on"];
            [ws showToast:@"Lower resolution when hot is on"];
        }
        neverAgain:^{
            [RMGameSettings setHeatNoticeOff:YES];
            [ws hideHeatNotice:@"don't show again"];
        }];
    [self.screen addSubview:v];
    // Over the world, never over the game's own HUD. On a wide screen with the chat in the top half (the landscape
    // layout) it goes just under the chat, lined up with it, which keeps it off the orbs and the minimap on the right.
    // A narrow screen (portrait) has no room beside them, so it stacks its buttons and goes centred under the lowest
    // of the chat, minimap and orbs at the top. With none of them at the top it sits top centre, under the keyboard
    // toggle, where the layout switch would; that's never up at the same time (heatNoticeCalm).
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [self.view layoutIfNeeded];
    CGFloat midY = CGRectGetMidY(self.screen.bounds);
    CGRect chat = [self heatNoticeHudRect:@"chat"];
    BOOL chatUp = !CGRectIsEmpty(chat) && CGRectGetMidY(chat) < midY;
    CGRect safe = g.layoutFrame;
    CGFloat room = chatUp ? CGRectGetMaxX(safe) - 8 - CGRectGetMinX([self.screen convertRect:chat toView:self.view])
                          : safe.size.width - 24;
    v.compact = room < kHeatNoticeWideMin;
    NSMutableArray<NSLayoutConstraint *> *place = [NSMutableArray arrayWithArray:@[
        [v.widthAnchor constraintLessThanOrEqualToAnchor:g.widthAnchor
                                                constant:-24],
        [v.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor
                                                   constant:-8],
    ]];
    if (chatUp && !v.compact) {
        [place addObject:[v.topAnchor constraintEqualToAnchor:self.screen.topAnchor constant:CGRectGetMaxY(chat) + 6]];
        [place addObject:[v.leadingAnchor constraintEqualToAnchor:self.screen.leadingAnchor constant:CGRectGetMinX(chat)]];
    } else {
        CGFloat below = 0;
        for (NSString *key in @[ @"chat", @"minimap", @"orbs" ]) {
            CGRect r = [self heatNoticeHudRect:key];
            if (!CGRectIsEmpty(r) && CGRectGetMidY(r) < midY)
                below = MAX(below, CGRectGetMaxY(r));
        }
        if (below > 0)
            [place addObject:[v.topAnchor constraintEqualToAnchor:self.screen.topAnchor constant:below + 6]];
        else
            [place addObject:[v.topAnchor constraintEqualToAnchor:g.topAnchor constant:52]];
        [place addObject:[v.centerXAnchor constraintEqualToAnchor:g.centerXAnchor]];
    }
    [NSLayoutConstraint activateConstraints:place];
    [v present];
    self.heatNotice = v;
    self.heatNoticeShownAt = CACurrentMediaTime();
    [self appendLine:@"[heat] hot-phone notice shown: offers Lower resolution when hot"];
}

// One of the game's HUD boxes on screen ("chat", "minimap", "orbs"), from the chrome snapshot, or CGRectZero when it
// isn't showing.
- (CGRect)heatNoticeHudRect:(NSString *)key {
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.heatNoticeHudRect") : nil;
    NSArray *b = [d isKindOfClass:[NSDictionary class]] ? d[key] : nil;
    if (![b isKindOfClass:[NSArray class]] || b.count != 4)
        return CGRectZero;
    return [self viewRectForGameX:[b[0] intValue] y:[b[1] intValue] w:[b[2] intValue] h:[b[3] intValue]];
}

// While it's up, a few times a second: it goes the moment a fight starts or anything else takes the screen, once the
// switch is on (from Game settings too), and after kHeatNoticeSeconds.
- (void)updateHeatNotice {
    if (!self.heatNotice)
        return;
    if ([RMGameSettings heatLowerResolution])
        [self hideHeatNotice:@"turned on in Game settings"];
    else if (CACurrentMediaTime() - self.heatNoticeShownAt >= kHeatNoticeSeconds)
        [self hideHeatNotice:@"timed out"];
    else if (![self heatNoticeCalm])
        [self hideHeatNotice:@"a fight started or the screen changed"];
}

- (void)hideHeatNotice:(NSString *)why {
    if (!self.heatNotice)
        return;
    [self.heatNotice dismiss];
    self.heatNotice = nil;
    [self appendLine:[NSString stringWithFormat:@"[heat] hot-phone notice gone: %@", why]];
}

// A new install starts light, on settings the player can raise: a frame-rate cap, set the way Game settings sets one so
// the screen shows it, and a shorter draw distance on base GPU, the renderer it starts on. They're set from here because
// only a first run raises the flag, so nobody already playing is moved. A sentinel in the profile can't promise that:
// RouteCGpuStarter stops at isGpu() before its seed, so an old profile can be missing one.
//
// The flag stays until they're on disk, so a kill partway through gets another go. FPS Control has to load first, which
// is well after the first ticks, so the writes keep trying. An ok only means queued, and the plugin turns on later, on
// the EDT, so the save waits for the cap to read back as in force, or it could land with the plugin still off.
- (void)applyNewInstallDefaults {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kNewInstallDefaultsKey])
        return;
    if (!self.newInstallQueued) {
        NSString *distance = [JVMLauncher mobileSetConfigGroup:@"gpu" key:@"drawDistance" value:kNewInstallDrawDistance];
        self.newInstallQueued = [distance hasPrefix:@"{\"ok\":true"] &&
                                [[JVMLauncher setFpsCap:kNewInstallFpsCap] hasPrefix:@"{\"ok\":true"];
    } else if (self.newInstallSaveId == 0) {
        NSData *data = [[JVMLauncher gameSettings] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([settings isKindOfClass:[NSDictionary class]] && [settings[@"fpsCap"] intValue] == kNewInstallFpsCap)
            self.newInstallSaveId = [JVMLauncher mobileFlushConfig];
    } else if ([JVMLauncher mobileProcessedWriteId] >= self.newInstallSaveId) {
        [ud removeObjectForKey:kNewInstallDefaultsKey];
        [self appendLine:[NSString stringWithFormat:@"[shell] new install: frame-rate cap %d, draw distance %@ saved",
                                                    kNewInstallFpsCap, kNewInstallDrawDistance]];
    }
}

// Queues sceneResolutionScale. NO if the bridge didn't take it.
- (BOOL)heatWriteScale:(int)scale {
    NSString *ack = [JVMLauncher mobileSetConfigGroup:@"hd"
                                                  key:@"sceneResolutionScale"
                                                value:[NSString stringWithFormat:@"%d", scale]];
    return [ack hasPrefix:@"{\"ok\":true"];
}

- (BOOL)heatWritesLanded {
    return [JVMLauncher mobileConfigWritesLanded];
}

- (long long)heatQueueSave {
    return [JVMLauncher mobileFlushConfig];
}

- (long long)heatProcessedWriteId {
    return [JVMLauncher mobileProcessedWriteId];
}

- (int)heatReadMarker {
    return (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"thermalBaselineScale"];
}

// setInteger already survives the app being killed straight after. synchronize is here for its result: nothing else
// says the write failed, and a throttle needs to know.
- (BOOL)heatWriteMarker:(int)baseline {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setInteger:baseline forKey:@"thermalBaselineScale"];
    return [ud synchronize];
}

- (void)heatClearMarker {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"thermalBaselineScale"];
}

- (void)updateChrome {
    NSString *snap = [JVMLauncher chromeSnapshot];
    if (snap.length == 0) return;
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateChrome");
    self.tabRailBg.hidden = YES;   // mobile cells are individually styled; no solid rail strip behind them
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue] || self.mapOpen) {
        // (mapOpen: the fullscreen world map owns the screen — the native grid would cover it + steal taps)
        [self hideTabGrid];
        return;
    }
    // LAYOUT GUARD: the native HUD overlay only works in Resizable - Modern (PRE_EOC = toplevel 164). In
    // Resizable - Classic (OSRS_STRETCH = 161) or Fixed (548) the grid can't stand in for the stones: in 161 they
    // share a container with the side panel, so HudVeneerBridge never hides them there. Rather than soft-lock the
    // user, hide the native overlay and un-hide the engine's OWN tab stones (the bridge gives back the rows it hid)
    // so the real game HUD renders + is tappable, and the user can open Settings > Display and switch to
    // Resizable - Modern. Re-engages automatically once back in toplevel 164.
    int topLevelId = [d[@"topLevelId"] intValue];
    if (topLevelId != 164) {
        [self hideTabGrid];
        [JVMLauncher setEngineStonesHidden:NO];
        if (self.framesShown % 120 == 0) {
            [self appendLine:[NSString stringWithFormat:@"[chrome] unsupported layout topLevel=%d (not 164/Resizable-Modern) -> native HUD off, engine HUD shown", topLevelId]];
        }
        return;
    }
    [JVMLauncher setEngineStonesHidden:YES]; // supported Modern layout: the native grid replaces the engine stones
    // The minimap cluster's real size, for the overlay editor's "Minimap" handle and its on-screen clamp. Re-clamp
    // when it changes: a saved offset was applied against the fallback size.
    NSArray *mc = d[@"mapContainer"];
    if ([mc isKindOfClass:[NSArray class]] && mc.count >= 4 && [mc[2] intValue] > 0 && [mc[3] intValue] > 0) {
        CGSize size = CGSizeMake([mc[2] intValue], [mc[3] intValue]);
        if (!CGSizeEqualToSize(size, self.minimapCanvasSize)) {
            self.minimapCanvasSize = size;
            [self applyMinimapRelocate];
        }
    }
    int active = [d[@"activeTab"] intValue];

    // The tabs in ONE framed 2-column group at the right, the official OSRS-mobile arrangement (601's
    // SIDE_RIGHT_TABS). The engine stones are HIDDEN (setEngineStonesHidden), so these native buttons ARE the tabs; a
    // tap replays the stone's op script to open the tab (onTabButton). TAB_GRID_ORDER maps grid slot -> engine tab.
    // Every size is the official layout's, in canvas px, drawn at k canvas px per point.
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    if (self.renderW <= 0 || W <= 0) {
        [self hideTabGrid];
        return;
    }
    CGFloat k = (CGFloat)self.renderW / W;
    // TAB-1: step left of the plugin rail (updateHudLayout moves the minimap when the rail comes or goes).
    CGFloat right = [self hudRightInset];
    if (H > W)
        right = MAX(right, kPortraitRightEdge);
    // Collapsed (the expand stone), the group narrows to the inner column, and the outer one slides under it.
    BOOL collapsed = self.tabGridCollapsed;
    int groupWc = collapsed ? kTabGroupCollapsedW : kTabGroupW;
    CGFloat groupW = groupWc / k, groupH = kTabGroupH / k;
    CGFloat gx0 = W - right - groupW; // flush with the safe edge, as the official group is
    NSArray *mmGlobe = [d[@"minimap"] isKindOfClass:[NSArray class]] ? d[@"minimap"] : nil;
    CGFloat gy0 = [self tabGridTopForHeight:groupH left:gx0 width:groupW margin:4.0 / k globe:mmGlobe];
    self.tabFrameView.image = collapsed ? self.tabFrameImgCollapsed : self.tabFrameImg;
    self.tabFrameView.frame = CGRectMake(gx0, gy0, groupW, groupH);
    self.tabFrameView.hidden = (self.tabFrameView.image == nil);
    // In portrait the plugin rail shares the right edge with the minimap and the group, so it keeps to the gap
    // between them (hudRightInset).
    CGRect mmRect = [self overlayEditMinimapCanvasRect];
    [self.panelDock setRailEdgeInset:H > W ? kPortraitRightEdge : 0];
    if (H > W && !CGRectIsNull(mmRect))
        [self.panelDock setRailBandTop:CGRectGetMaxY(mmRect) / k + 6.0 bottom:gy0 - 6.0];
    else
        [self.panelDock setRailBandTop:0 bottom:0];
    for (int slot = 0; slot < 14; slot++) {
        int i = TAB_GRID_ORDER[slot];
        int col = slot % 2, row = slot / 2;
        UIButton *btn = (i == kTabSlotExpand) ? self.tabExpandButton : self.tabButtons[i];
        // Each column keeps its own edge of the group: the outer one stays right-aligned when it narrows.
        int cx = (col == 0) ? kTabFrameInset : groupWc - kTabFrameInset - kTabStone;
        btn.frame = CGRectMake(gx0 + cx / k, gy0 + (kTabFrameInset + row * kTabPitch) / k, kTabStone / k, kTabStone / k);
        BOOL tucked = collapsed && col == 1;
        btn.userInteractionEnabled = !tucked;
        if ([btn isKindOfClass:[TabGridButton class]]) {
            // TOUCH-1: the stones are under 44 pt, so each outer edge of the group takes taps beyond it: the frame,
            // then the scene to the left, the gap under the minimap above, and the screen edges right and below.
            BOOL rightEdge = (col == 1 || collapsed);
            ((TabGridButton *)btn).hitOutset = UIEdgeInsetsMake(
                row == 0 ? CGRectGetMinY(btn.frame) - gy0 + 4.0 : 0.0,
                col == 0 ? CGRectGetMinX(btn.frame) - gx0 + 10.0 : 0.0,
                row == 6 ? H - CGRectGetMaxY(btn.frame) : 0.0,
                rightEdge ? W - CGRectGetMaxX(btn.frame) : 0.0);
        }
        if (i == kTabSlotExpand) {
            UIImage *img = collapsed ? self.tabImgShowMore : self.tabImgShowLess;
            [self paintTabButton:btn image:img active:NO];
            btn.accessibilityLabel = collapsed ? @"Show more tabs" : @"Show fewer tabs";
            continue;
        }
        BOOL isActive = (i == active);
        // Authentic composited tab image (live-cache OSRS stone + icon). Active = red stone, inactive = grey.
        NSArray<UIImage *> *imgs = isActive ? self.tabImgActive : self.tabImgInactive;
        UIImage *img = (i < (int)imgs.count && [imgs[i] isKindOfClass:[UIImage class]]) ? imgs[i] : nil;
        [self paintTabButton:btn image:img active:isActive];
        btn.accessibilityElementsHidden = tucked;
    }

    // The column left of the chat (601's SIDE_LEFT_CHAT), moving with it: the logout door, the speech bubbles that put
    // the chat away and bring it back, and the keyboard, which goes while the chat is away. Placed from the same chat
    // origin applyChatRelocate sends the engine.
    UIButton *door = self.tabButtons[kTabLogout];
    NSArray<UIButton *> *column = @[ door, self.chatToggleButton, self.chatKeyboardButton ];
    if (self.chatBaseX > 0) {
        int chatX = [self clampChatX:self.chatBaseX + self.chatUserDX];
        int chatY = [self clampChatY:self.chatBaseY + self.chatUserDY];
        CGFloat colX = (chatX - hudPx(kDoorCanvasW)) / k;
        // While the column sits by the screen's left edge each stone reaches out to it, and the door up to the top
        // edge; a chat dragged away from them keeps only a small slop, so the column never takes the world's taps.
        UIEdgeInsets safe = self.view.safeAreaInsets;
        const CGFloat slop = 10.0;
        CGFloat reachLeft = colX <= safe.left + slop ? colX : slop;
        for (int c = 0; c < 3; c++) {
            UIButton *b = column[c];
            b.frame = CGRectMake(colX, (chatY + hudPx(kColumnY + c * kColumnPitch)) / k, hudPx(kDoorCanvasW) / k,
                                 hudPx(kColumnStoneH) / k);
            CGFloat top = CGRectGetMinY(b.frame);
            CGFloat reachUp = c != 0 ? 0.0 : (top <= safe.top + hudPx(kColumnY) / k + slop ? top : slop);
            if ([b isKindOfClass:[TabGridButton class]])
                ((TabGridButton *)b).hitOutset = UIEdgeInsetsMake(reachUp, reachLeft, 0.0, 0.0);
        }
        [self paintTabButton:door
                       image:(active == kTabLogout ? self.doorImgActive : self.doorImg)
                      active:(active == kTabLogout)];
        // Put away, the bubbles sit on the door's stone, and flash to its red one twice a second while a message waits.
        BOOL flash = self.chatHasUnread && ((long)(CACurrentMediaTime() * 2.0)) % 2 == 1;
        UIImage *bubbles = !self.chatPutAway ? self.chatToggleOpenImg
                                             : (flash ? self.chatToggleFlashImg : self.chatToggleClosedImg);
        [self paintTabButton:self.chatToggleButton image:bubbles active:NO];
        self.chatToggleButton.accessibilityValue = self.chatPutAway ? @"Hidden" : @"Shown";
        if (self.chatPutAway)
            self.chatKeyboardButton.hidden = YES;
        else
            [self paintTabButton:self.chatKeyboardButton image:self.chatKeyboardImg active:NO];
        self.chatColumnShown = YES;
    } else {
        for (UIButton *b in column)
            b.hidden = YES; // the chat isn't placed yet
        self.chatColumnShown = NO;
    }
    [self applyKbFabVisibility];

    // The rest is in canvas px: wait for a pending canvas (auto-rotate) rather than place it on the old one.
    if (self.canvasPending)
        return;
    // Relocate the engine side panel (the open inventory/skills/etc. "menu") flush LEFT of the group's frame and
    // centred on it, as 601 puts both on the one anchor (tabGridTopForHeight). Convert the group's screen-point edges
    // to canvas px; the side panel's size comes from the chrome snapshot (fixed engine px).
    int sideW = 204, sideH = 275; // fallback until the panel is open and reports its real size
    NSArray *sc = [d[@"sideContainer"] isKindOfClass:[NSArray class]] ? d[@"sideContainer"] : nil;
    if (sc.count >= 4 && [sc[2] intValue] > 0)
        sideW = [sc[2] intValue];
    if (sc.count >= 4 && [sc[3] intValue] > 0)
        sideH = [sc[3] intValue];
    int sideX = (int)lround(gx0 * k) - sideW; // right edge flush against the frame's left edge
    int sideY = (int)lround((gy0 + groupH / 2.0) * k) - sideH / 2;
    if (sideX < 0)
        sideX = 0;
    if (sideY < 0)
        sideY = 0;
    [JVMLauncher relocateEngineSidePanelX:sideX y:sideY];

    // Large portrait: the game's windows keep to the band under the chat and the minimap and over the group and
    // the side panel, so neither covers a window's edge.
    if (self.visibleH < self.renderH && self.chatBaseX > 0 && self.engineChatRelocated) {
        int top = [self clampChatY:self.chatBaseY + self.chatUserDY] + chatRowCanvasH() + hudPx(kChatContentCanvasH);
        if (!CGRectIsNull(mmRect))
            top = MAX(top, (int)CGRectGetMaxY(mmRect));
        int bottom = MIN(sideY, (int)lround(gy0 * k));
        [self sendHudStripTop:top + 6 bottom:bottom - 6];
    }
}

// Large portrait: hand the engine the canvas rows on screen and the band its windows open in. Sent again only when
// the band moves (a dragged chat or minimap); the engine keeps it across a logout.
- (void)sendHudStripTop:(int)top bottom:(int)bottom {
    if (self.visibleH <= 0 || self.visibleH >= self.renderH)
        return;
    if (self.stripSent && top == self.stripBandTop && bottom == self.stripBandBottom)
        return;
    self.stripSent = YES;
    self.stripBandTop = top;
    self.stripBandBottom = bottom;
    [JVMLauncher setEngineHudStripRows:self.visibleH windowTop:top bottom:bottom];
    [self appendLine:[NSString stringWithFormat:@"[strip] shown %d of %d rows, windows %d..%d", self.visibleH,
                                                self.renderH, top, bottom]];
}

// The ⌨︎ FAB stands down while the column's keyboard stone is up (the official app has only the stone), and while the
// world map owns the screen.
- (void)applyKbFabVisibility {
    self.kbFab.hidden = self.mapOpen || self.chatColumnShown;
}

// The grid's top edge, in points, on the official app's anchor (interface 601, script 919): once the game area is
// at least 503 game px tall, the tab group and the side panel are both centred 87 px below its middle; below that
// they sit 4 px off its bottom. The official game area is the safe area, so that is what is measured here. It never
// goes past the bottom margin, nor down onto a bottom-left control under it or under the panel, nor up into the
// minimap globe ([x,y,w,h] canvas px, live, so a dragged minimap counts) when that sits above the grid. The globe,
// not the whole cluster: the cluster's box runs ~30 pt below anything it draws over the grid's columns, which would
// hold the grid at the bottom on every iPhone.
// In portrait the official app has no layout, so the group keeps to the bottom corner, in thumb reach, and the
// screen's middle stays the world's.
- (CGFloat)tabGridTopForHeight:(CGFloat)gridH left:(CGFloat)gx width:(CGFloat)gw margin:(CGFloat)margin
                         globe:(NSArray *)globe {
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat safeTop = ins.top, safeBottom = H - ins.bottom;
    CGFloat lowest = safeBottom - margin - gridH;
    if (self.renderW <= 0 || W <= 0)
        return lowest;
    CGFloat k = (CGFloat)self.renderW / W; // canvas px per point
    // The side panel opens flush left of the group. Upright, a full row of pinned controls or the hotkey strip reaches
    // under it, so the floor is 8 pt over the highest control that does.
    CGFloat panelLeft = gx - kSideContainerW / k;
    for (UIView *v in @[ self.settingsButton, self.controlsBox, self.hotkeyStrip ]) {
        if (v.hidden || v.bounds.size.width <= 0)
            continue;
        CGRect r = [v convertRect:v.bounds toView:self.view];
        if (CGRectGetMaxX(r) > panelLeft && CGRectGetMinX(r) < gx + gw)
            lowest = MIN(lowest, CGRectGetMinY(r) - 8.0 - gridH);
    }
    BOOL centred = H <= W && (safeBottom - safeTop) * k >= 503.0;
    CGFloat top = centred ? (safeTop + safeBottom) / 2.0 + 87.0 / k - gridH / 2.0 : safeBottom - 4.0 / k - gridH;
    CGFloat highest = safeTop + margin;
    if (globe.count >= 4 && [globe[2] intValue] > 0 && [globe[3] intValue] > 0) {
        // The globe widget's box already reaches past the wiki banner and world-map orb under the ring.
        CGFloat mapLeft = [globe[0] intValue] / k, mapRight = ([globe[0] intValue] + [globe[2] intValue]) / k;
        if (mapRight > gx && mapLeft < gx + gw)
            highest = MAX(highest, ([globe[1] intValue] + [globe[3] intValue]) / k + 4.0);
    }
    CGFloat gridTop = MIN(MAX(top, highest), lowest);
    if (fabs(gridTop - self.loggedTabGridTop) >= 1.0) {
        self.loggedTabGridTop = gridTop;
        [self appendLine:[NSString stringWithFormat:@"[chrome] tab grid top %.0fpt (anchor %.0f, globe floor %.0f, bottom %.0f, k%.2f)",
                                                    gridTop, top, highest, lowest, k]];
    }
    return gridTop;
}

// Paint one grid stone (or the door): the composited cache sprite, or an opaque stone-brown tile until the sprites
// are captured from the cache (first-ever login, pre-capture), so the grid reads as buttons rather than vanishing.
- (void)paintTabButton:(UIButton *)btn image:(UIImage *)img active:(BOOL)isActive {
    [btn setImage:img forState:UIControlStateNormal];
    if (img) {
        btn.backgroundColor = [UIColor clearColor];
        btn.layer.cornerRadius = 0.0;
    } else {
        btn.backgroundColor = isActive ? [UIColor colorWithRed:96.0 / 255.0 green:32.0 / 255.0 blue:24.0 / 255.0 alpha:1.0]
                                       : [UIColor colorWithRed:66.0 / 255.0 green:60.0 / 255.0 blue:51.0 / 255.0 alpha:1.0];
        btn.layer.cornerRadius = 3.0;
        btn.clipsToBounds = YES;
    }
    btn.layer.borderWidth = 0.0;
    btn.alpha = 1.0; // active vs inactive carried by the red/grey stone itself
    btn.hidden = NO;
}

- (void)hideTabGrid {
    for (UIButton *btn in self.tabButtons)
        btn.hidden = YES;
    self.tabExpandButton.hidden = YES;
    self.tabFrameView.hidden = YES;
    self.chatToggleButton.hidden = YES;
    self.chatKeyboardButton.hidden = YES;
    for (UIView *cv in self.stoneCovers)
        cv.hidden = YES;
    self.chatColumnShown = NO;
    [self applyKbFabVisibility];
}

// The expand stone: collapse the grid to its inner column, or bring the outer column back. The panel follows the
// column on the next updateChrome.
- (void)onTabExpand {
    self.tabGridCollapsed = !self.tabGridCollapsed;
    [[NSUserDefaults standardUserDefaults] setBool:self.tabGridCollapsed forKey:@"tabGridCollapsed"];
    [self appendLine:[NSString stringWithFormat:@"[chrome] tab grid %@", self.tabGridCollapsed ? @"collapsed" : @"expanded"]];
    [self updateChrome];
}

// Show, label or hide the one-tap layout-switch pill (~10 Hz). It is up while the player is logged in to a layout the
// native HUD can't drive (Resizable - Classic or Fixed) and presses Resizable - Modern in the game's own Settings >
// Display dropdown (HudVeneerBridge.switchToModernLayout). The setting is server-side, so the pill goes once the
// snapshot's rootKind (resizable + the layout varbit, unlike the toplevel id it never reads a transient 165) is
// PRE_EOC.
- (void)updateLayoutSwitch {
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.updateLayoutSwitch") : nil;
    NSString *rootKind = [d isKindOfClass:[NSDictionary class]] && [d[@"rootKind"] isKindOfClass:[NSString class]]
                             ? d[@"rootKind"]
                             : @"";
    CFTimeInterval now = CACurrentMediaTime();
    if ([rootKind isEqualToString:@"PRE_EOC"] && self.layoutSwitchSentAt > 0) {
        [self appendLine:[NSString stringWithFormat:@"[shell] layout: now Resizable - Modern, %.1f s after the switch",
                                                    now - self.layoutSwitchSentAt]];
        self.layoutSwitchSentAt = 0;
    }
    BOOL unsupported = [d isKindOfClass:[NSDictionary class]] && [d[@"loggedIn"] boolValue] && !self.mapOpen &&
                       ([rootKind isEqualToString:@"OSRS_STRETCH"] || [rootKind isEqualToString:@"FIXED"]) &&
                       [JVMLauncher canSwitchEngineLayout];
    if (!unsupported) {
        self.layoutUnsupportedSince = 0;
        self.layoutSwitchButton.hidden = YES;
        return;
    }
    if (self.layoutUnsupportedSince == 0)
        self.layoutUnsupportedSince = now;
    if (self.layoutSwitchSentAt > 0 && now - self.layoutSwitchSentAt > kLayoutSwitchTimeout) {
        self.layoutSwitchSentAt = 0;
        [self appendLine:[NSString stringWithFormat:@"[shell] layout: the switch did not take within %.0f s (rootKind=%@)",
                                                    kLayoutSwitchTimeout, rootKind]];
        [self showLayoutSwitchFailed];
    }
    BOOL sending = self.layoutSwitchSentAt > 0;
    NSString *label = sending ? @"Switching…" : kLayoutSwitchLabel;
    if (![[self.layoutSwitchButton titleForState:UIControlStateNormal] isEqualToString:label])
        [self.layoutSwitchButton setTitle:label forState:UIControlStateNormal];
    self.layoutSwitchButton.enabled = !sending;
    self.layoutSwitchButton.hidden = now - self.layoutUnsupportedSince < kLayoutSwitchSettle;
}

- (void)onLayoutSwitch {
    if (self.layoutSwitchSentAt > 0)
        return;
    self.layoutSwitchSentAt = CACurrentMediaTime();
    [self.layoutSwitchButton setTitle:@"Switching…" forState:UIControlStateNormal];
    self.layoutSwitchButton.enabled = NO;
    [JVMLauncher switchEngineToModernLayout];
    [self appendLine:@"[shell] layout: switch to Resizable - Modern sent"];
}

- (void)showLayoutSwitchFailed {
    // Never stack over another presented VC (UIKit refuses it); the pill is back, so the player can just retry.
    if (self.presentedViewController != nil)
        return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"The layout didn't change"
                         message:@"The game didn't switch to Resizable - Modern. You can switch it yourself: open the "
                                 @"Settings tab, then Display, and choose \"Resizable - Modern layout\" under Game "
                                 @"client layout."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// A native tab tap -> proxy a left click on the live desktop stone centre (the device-proven switch primitive,
// JavaBridge.onClick). The button consumed the tap, so it never leaks to the game gestures beneath.
- (void)onTabButton:(UIButton *)b {
    if (![JVMLauncher bridgeReady]) return;
    NSInteger i = b.tag;
    if (i < 0 || i >= 14) return;
    // Open the tab by replaying the engine stone's op script (works while the stones are hidden) — no proxy-click
    // on a live stone, so no cover patch / gray box is needed. The button tag is the engine tab index.
    [JVMLauncher openEngineTab:(int)i];
    [self appendLine:[NSString stringWithFormat:@"[chrome] tab %ld -> openTab", (long)i]];
}

- (void)onToggleChrome {
    self.chromeVisible = !self.chromeVisible;
    if (!self.chromeVisible) {
        [self hideTabGrid];                       // and the stone covers, revealing the real stones in the fallback view
        [JVMLauncher setEngineStonesHidden:NO];   // flip HudVeneerBridge.hideStones OFF so the engine's own tab
                                                  // stones reappear; without this the per-frame re-hide leaves
                                                  // NO tab access at all (native grid hidden + stones still hidden)
        self.tabRailBg.hidden = YES;
        [self hideChatTabs];
    }
    // (When toggled back ON, updateChrome and updateChatTabs lay everything out again on the next tick.)
    [self appendLine:[NSString stringWithFormat:@"[chrome] rails %@", self.chromeVisible ? @"ON" : @"OFF"]];
}

// Copy a full diagnostics report (environment + live metrics + log) to the clipboard, so a session can be
// pasted into a bug note without the device round-trip. Built on devReportText so it's never empty — even in
// a Release build where the on-screen console is compiled out, or before the JVM has produced any output.
- (void)onCopyLog {
    [UIPasteboard generalPasteboard].string = [self devReportText];
    [self appendLine:@"[dev] diagnostics report copied to clipboard"];
}

// Also copy the report when the diagnostics readout itself is tapped (a quick, discoverable grab).
- (void)onCopyReport {
    [self onCopyLog];
}

// Clear the on-screen console (the on-disk jvm-stdio.log is untouched — use Share to export the full file).
- (void)onClearLog {
    self.console.text = @"";
}

// Share via the system share sheet — AirDrop to a Mac, save to Files, etc. Prefers the raw JVM stdout/stderr
// log FILE (Documents/jvm-stdio.log) when it exists; otherwise shares the full diagnostics report text so the
// action is never a no-op (the file is only written in debug builds, and not before the JVM starts).
- (void)onShareLog {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logPath = [docs stringByAppendingPathComponent:@"jvm-stdio.log"];
    id item = [[NSFileManager defaultManager] fileExistsAtPath:logPath]
                  ? (id)[NSURL fileURLWithPath:logPath]
                  : (id)[self devReportText];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[ item ]
                                                                     applicationActivities:nil];
    av.popoverPresentationController.sourceView = self.devActionRow;
    av.popoverPresentationController.sourceRect = self.devActionRow.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

// ---- Row 4b: inspectors / tests -------------------------------------------------------------------

// Dump the live HUD/bridge snapshot (the JSON that drives the native chrome — logged-in, reconnecting, tab
// state, etc.) into the console, pretty-printed. A quick, side-effect-free peek at what the engine is telling
// the shell — the single most useful thing when the native veneers and the game disagree.
- (void)onDumpSnapshot {
    if (![JVMLauncher bridgeReady]) {
        [self appendLine:@"[snapshot] bridge not ready (start the game first)"];
        return;
    }
    NSString *snap = [JVMLauncher chromeSnapshot];
    NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.onDumpSnapshot") : nil;
    if (!d) {
        [self appendLine:@"[snapshot] (empty / unparseable)"];
        return;
    }
    NSData *pretty = [NSJSONSerialization dataWithJSONObject:d
                                                     options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                       error:nil];
    NSString *text = pretty ? [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding] : snap;
    [self appendLine:[NSString stringWithFormat:@"[snapshot]\n%@", text]];
}

// Reflect the saved perf-overlay toggle onto the overlay itself and the dev-panel button label. Called at
// panel-build (so the overlay honours the last choice across launches) and after every toggle.
- (void)applyPerfOverlayState {
    BOOL pref = [[NSUserDefaults standardUserDefaults] boolForKey:@"perfOverlayOn"];
    // The overlay is a developer surface: it only shows when dev mode is ON *and* the toggle is set. This keeps
    // it from lingering on-screen after a user turns developer mode back off (the panel is hidden, so is this).
    BOOL show = pref && self.developerMode;
    self.perfOverlay.hidden = !show;
    if (show)
        [self.view bringSubviewToFront:self.perfOverlay];
    // The button lives inside the dev panel (only reachable in dev mode), so its title just mirrors the toggle.
    [self.perfHudButton setTitle:(pref ? @"Perf ✓" : @"Perf") forState:UIControlStateNormal];
    if (show)
        [self refreshDevDiagnostics]; // populate it immediately rather than waiting for the next tick
}

// Toggle the compact always-on perf overlay (fps · resident MB · thermal), persisted so it survives relaunch.
- (void)onTogglePerfOverlay {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL on = ![ud boolForKey:@"perfOverlayOn"];
    [ud setBool:on forKey:@"perfOverlayOn"];
    [self applyPerfOverlayState];
    [self appendLine:[NSString stringWithFormat:@"[dev] perf overlay %@", on ? @"ON" : @"OFF"]];
}

// Exercise the native "Reconnecting…" UI without dropping the live socket: a transient flag (clamped 1–10s,
// here 4) is OR'd into HeadlessLogin.isReconnecting(), so the snapshot path + overlay light up exactly as they
// would on a real CONNECTION_LOST, then clear themselves. Safe to run mid-session — the game keeps playing.
- (void)onReconnectTest {
    if (![JVMLauncher bridgeReady]) {
        [self appendLine:@"[reconnect] bridge not ready (start the game first)"];
        return;
    }
    [JVMLauncher devSimulateReconnect:4];
    [self appendLine:@"[reconnect] simulating reconnect for 4s (UI only — socket untouched)"];
}

// Parity with Android's DEBUG Shift long-press: publish a host-origin notification so the full delivery path
// (bridge queue -> nextNotification drain -> UNUserNotificationCenter) can be verified without an in-game
// trigger. Dev-panel only — no Release user-facing surface.
- (void)onTestNotification {
    if (![JVMLauncher bridgeReady]) {
        [self appendLine:@"[notif] bridge not ready (start the game first)"];
        return;
    }
    [JVMLauncher devPublishTestNotification];
    [self appendLine:@"[notif] published test notification (drains through the normal path)"];
}

// Developer-mode diagnostics: refresh the live readout (JVM / renderer / FPS / memory / session / bridge /
// build). Cheap-guards on the panel being visible, so it's a no-op during normal play. Called from the JIT
// poller (pre-launch) and the display tick (in-game).
- (void)refreshDevDiagnostics {
    // Runs when EITHER dev surface is up: the full panel, or the compact always-on perf overlay (which must
    // keep updating while the panel is hidden — that's its whole point). No-op otherwise, so normal play is free.
    BOOL panelVisible = self.debugPanel && !self.debugPanel.hidden;
    BOOL overlayVisible = self.perfOverlay && !self.perfOverlay.hidden;
    if (!panelVisible && !overlayVisible)
        return;

    // Active renderer. Once launched, the pending flags ARE the effective renderer (locked at boot); the saved
    // preference can differ (the user may have picked another for next launch), so only trust it pre-launch.
    NSString *renderer;
    // Only the 117HD DIRECT-present path presents off-thread and never bumps getFrameSeq, so its FPS comes from
    // RouteCBridge's present count instead. Base GPU uses the readback present (gpuPublish bumps frameSeq like the
    // CPU snapshot), so it is measured like CPU - don't lump it in with 117HD.
    BOOL directPresent = NO;
    if (self.launched) {
        if (self.pendingRouteCZone) {
            renderer = @"117hd";
            directPresent = self.pendingRouteCZoneDirect;
        } else if (self.pendingRouteCGpu) {
            renderer = @"gpu";
        } else {
            renderer = @"cpu";
        }
    } else {
        NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:@"rendererPref"] ?: @"cpu";
        renderer = [pref stringByAppendingString:@" (next launch)"];
    }

    // FPS, sampled over a ~0.5s window from a real frame counter, NOT display-link ticks: the engine's rendered-frame
    // counter (getFrameSeq), or on the 117HD direct-present path (which never bumps it) the frames RouteCBridge
    // handed to the screen. The panel says which, since a present count is not the engine's own frame count.
    int seq = self.launched ? [JVMLauncher renderedFrameSeq] : -1;
    long presents = [RouteCBridge presentedFrameCount];
    CFTimeInterval now = CACurrentMediaTime();
    if (_fpsStamp <= 0) {
        _fpsStamp = now;
        _lastFrameSeq = seq;
        _lastPresentCount = presents;
    }
    CFTimeInterval dt = now - _fpsStamp;
    if (dt >= 0.5) {
        if (directPresent)
            _lastFps = presents >= _lastPresentCount ? (presents - _lastPresentCount) / dt : 0;
        else
            _lastFps = (seq >= 0 && _lastFrameSeq >= 0 && seq >= _lastFrameSeq) ? (seq - _lastFrameSeq) / dt : 0;
        _fpsStamp = now;
        _lastFrameSeq = seq;
        _lastPresentCount = presents;
    }
    NSString *fpsStr = !self.launched ? @"\u2014"
                                      : [NSString stringWithFormat:directPresent ? @"%.0f (presents)" : @"%.0f", _lastFps];

    // Resident memory of this process (the increased-memory-limit entitlement is what keeps the JVM heap alive).
    double residentMB = 0;
    mach_task_basic_info_data_t ti;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&ti, &count) == KERN_SUCCESS)
        residentMB = ti.resident_size / (1024.0 * 1024.0);

    NSString *thermal = [self thermalStateString];

    // Compact always-on perf overlay (if enabled): fps · resident MB · thermal. Cheap — no bridge JSON.
    if (overlayVisible) {
        NSString *fpsShort = !self.launched ? @"\u2014" : [NSString stringWithFormat:@"%.0f", _lastFps];
        self.perfOverlay.text = [NSString stringWithFormat:@" %@ fps · %.0f MB · %@ ", fpsShort, residentMB, thermal];
    }

    if (!panelVisible)
        return; // the overlay is done; skip the fuller (bridge-JSON) panel readout when the panel is hidden

    // Bridge + session state (nil before the VM/facade is up), plus the JVM heap (used/max MB, Java-side).
    BOOL bridge = [JVMLauncher bridgeReady];
    NSString *session = @"—";
    NSString *heap = @"—";
    if (bridge) {
        NSString *snap = [JVMLauncher chromeSnapshot];
        NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.refreshDevDiagnostics") : nil;
        if ([d[@"reconnecting"] boolValue])
            session = @"reconnecting";
        else if ([d[@"loggedIn"] boolValue])
            session = @"logged in";
        else
            session = @"at login";
        NSString *h = [JVMLauncher heapStats];
        if (h.length)
            heap = [h stringByAppendingString:@" MB"];
    }

    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *bld = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    NSString *jvm = self.launched ? (bridge ? @"running" : @"booting…") : @"not started";

    self.diagLabel.text = [NSString stringWithFormat:
                                        @"JVM       %@\n"
                                        @"Renderer  %@\n"
                                        @"FPS       %@\n"
                                        @"Memory    %.0f MB\n"
                                        @"Heap      %@\n"
                                        @"Thermal   %@\n"
                                        @"Session   %@\n"
                                        @"Bridge    %@\n"
                                        @"Build     %@ (%@)",
                                        jvm, renderer, fpsStr, residentMB, heap, thermal,
                                        session, bridge ? @"ready" : @"—", ver, bld];
}

// Human-readable thermal pressure — directly relevant to this app's throttling / perf work.
- (NSString *)thermalStateString {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal:
            return @"nominal";
        case NSProcessInfoThermalStateFair:
            return @"fair";
        case NSProcessInfoThermalStateSerious:
            return @"serious";
        case NSProcessInfoThermalStateCritical:
            return @"critical";
    }
    return @"unknown";
}

// A self-contained diagnostics report for pasting into a bug note: device/OS environment, the live readout,
// the JIT gate, then the on-screen log. Never empty (environment + metrics are always present), which is why
// Copy log and Share build on this rather than the raw console (Debug-only, and empty before boot).
// The diagnostics report's JIT line: CS_DEBUGGED, whether a debugger is attached now, and the script check.
- (NSString *)devJitStateText {
    if (![JVMLauncher isDebuggerAttached])
        return @"not attached";
    static NSString *const checks[] = {@"not checked", @"checking", @"script OK", @"no answer", @"wrong script"};
    RMJitScriptCheck check = [JVMLauncher jitScriptCheck];
    NSString *checkText = (check >= 0 && check < 5) ? checks[check] : @"?";
    return [NSString stringWithFormat:@"CS_DEBUGGED · %@ · %@",
                                      [JVMLauncher isDebuggerTracing] ? @"debugger attached" : @"detached", checkText];
}

- (NSString *)devReportText {
    [self refreshDevDiagnostics]; // ensure the readout reflects this instant
    struct utsname sys;
    uname(&sys);
    double ramGB = [NSProcessInfo processInfo].physicalMemory / (1024.0 * 1024.0 * 1024.0);
    NSString *env = [NSString stringWithFormat:@"Device    %s · iOS %@ · %.0f GB RAM\nJIT       %@",
                                               sys.machine, [UIDevice currentDevice].systemVersion, ramGB,
                                               [self devJitStateText]];
    NSString *log = self.console.text.length ? self.console.text : @"(log is captured only in debug builds)";
    return [NSString stringWithFormat:@"RuneMobile diagnostics\n%@\n%@\n\n--- log ---\n%@",
                                      env, self.diagLabel.text ?: @"", log];
}

// The canvas for a screen whose sides are `size` points, as the window stands.
- (RMCanvas)canvasForScreen:(CGSize)size {
    CGFloat sw = size.width, sh = size.height;
    BOOL portrait = sh > sw;
    CGFloat shortPt = MIN(sw, sh), longPt = MAX(sw, sh);
    // Render height is the sharpness<->FPS<->UI-SIZE dial: the engine SOFTWARE-renders at renderW×renderH every
    // frame (no GPU on iOS), so a LOWER renderH = bigger UI on screen. The minimap can't be enlarged on its own
    // (the engine pins its orbs + breaks the terrain raster if the globe is repositioned — see HudVeneerBridge),
    // so we scale the WHOLE HUD up via renderH to make the minimap bigger. 600 was the prior "official-sized"
    // value; 540 enlarges the HUD ~11% (bigger minimap/chat/orbs). Watch the right column (minimap top + native
    // tab grid bottom) for overlap as this drops (480 collided historically) — tune here.
    // DISP-1: user-selectable "Interface size" — a smaller canvas = a larger HUD. Persisted; applied at launch
    // (long-press the ⚙ button to change), so it is read once and a turn keeps this launch's size. Default + clamp
    // to the safe 480..600 band proven not to overlap.
    static int launchRenderH;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        launchRenderH = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"interfaceRenderH"];
        if (launchRenderH < 480 || launchRenderH > 600)
            launchRenderH = 540;
    });
    int renderH = launchRenderH;
    // TAB-1: on a large screen (an iPad) the canvas grows with the screen's height in points instead, so the HUD stays
    // the size it is on a phone and the extra screen shows more of the world (1267 tall on a 13" iPad at the default
    // size), capped at the screen's own pixels. The interface size setting scales it the same way. Phones keep the
    // setting as it is.
    int renderShort = renderH;
    if (shortPt >= kLargeScreenPt) {
        int screenPx = (int)lround(shortPt * self.traitCollection.displayScale);
        renderShort = MAX(renderShort, MIN(screenPx, (int)lround(shortPt * renderShort / kPhoneShortPt)));
    }
    // Never narrower than the game's narrowest layout: a 4:3 screen at a phone's 540 would be 720 wide. In portrait
    // the width is the short side itself, so every phone gets the 765-wide canvas there.
    if (shortPt > 0)
        renderShort = portrait ? MAX(renderShort, kMinCanvasW)
                               : MAX(renderShort, (int)ceil(kMinCanvasW * shortPt / longPt));
    int renderLong = shortPt > 0 ? (int)lround(renderShort * (longPt / shortPt)) : (int)lround(renderShort * 2.0);
    RMCanvas c = {portrait ? renderShort : renderLong, portrait ? renderLong : renderShort, 0};
    c.visibleH = c.h;
    // Large portrait on a phone: a kStripCanvasW-wide canvas whose screen ends visibleH rows down, with the strip
    // for the chat and minimap under it. The frame feeds keep only the visible rows.
    if (portrait && shortPt > 0 && shortPt < kLargeScreenPt && !self.pendingRouteCGpuNoResize) {
        c.w = kStripCanvasW;
        c.visibleH = (int)lround(kStripCanvasW * longPt / shortPt);
        c.h = c.visibleH + kStripCanvasH;
    }
    return c;
}

// Take `c` as the canvas the game draws: both frame feeds keep its shown rows, and the chat's and minimap's scale on
// screen follows its strip. YES when the canvas turned (portrait <-> landscape).
- (BOOL)setCanvas:(RMCanvas)c {
    self.renderW = c.w;
    self.renderH = c.h;
    self.visibleH = c.visibleH;
    BOOL strip = c.visibleH < c.h;
    sHudScale = strip ? (CGFloat)kStripCanvasW / kMinCanvasW : 1.0;
    [JVMLauncher setShownRows:strip ? c.visibleH : 0];
    [RouteCBridge setPipShownRows:strip ? c.visibleH : 0];
    BOOL portrait = c.h > c.w;
    BOOL turned = portrait != sCanvasPortrait;
    sCanvasPortrait = portrait;
    return turned;
}

// The chat's and the minimap's dragged offsets for the canvas's orientation (hudOffsetKey).
- (void)reloadHudOffsets {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    self.chatUserDX = (int)[ud integerForKey:hudOffsetKey(@"chatUserDX")];
    self.chatUserDY = (int)[ud integerForKey:hudOffsetKey(@"chatUserDY")];
    self.minimapUserDX = (int)[ud integerForKey:hudOffsetKey(@"minimapUserDX")];
    self.minimapUserDY = (int)[ud integerForKey:hudOffsetKey(@"minimapUserDY")];
}

// The window changed size. The PiP layer is a plain sublayer, so it is sized here; the canvas follows on the next
// tick (resizeCanvasToScreen).
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.pipLayer && !CGRectEqualToRect(self.pipLayer.frame, self.screen.bounds)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.pipLayer.frame = self.screen.bounds;
        [CATransaction commit];
    }
    if (self.launched)
        self.canvasCheckDue = YES;
}

// Auto-rotate (Settings > Game settings > Screen): the window turned, so ask the game for the canvas that suits it.
// Until a frame of that size is drawn the old one keeps showing, fitted to the turned screen, and the shell keeps the
// old canvas's mapping; adoptCanvasIfDrawn then switches over. A strip turning on crops from the first frame drawn at
// the new size (an older, shorter frame shows whole either way); one turning off waits for adoption, so the old
// frame's strip never shows. Before the bridge is up the request fails, and this runs again on the next tick.
- (void)resizeCanvasToScreen {
    CGSize size = self.view.bounds.size;
    // The gated-off ANGLE window present (metalLayer) sizes its drawable once, at launch, so it keeps that canvas.
    if (!self.launched || self.renderW <= 0 || self.pendingRouteCGpuNoResize || self.metalLayer || size.width <= 0 ||
        size.height <= 0) {
        self.canvasCheckDue = NO;
        return;
    }
    RMCanvas c = [self canvasForScreen:size];
    BOOL same = self.canvasPending ? (c.w == self.pendingW && c.h == self.pendingH && c.visibleH == self.pendingVisibleH)
                                   : (c.w == self.renderW && c.h == self.renderH && c.visibleH == self.visibleH);
    if (same) {
        self.canvasCheckDue = NO;
        return;
    }
    if (![JVMLauncher requestResizeWidth:c.w height:c.h])
        return;
    self.canvasCheckDue = NO;
    self.canvasPending = YES;
    self.pendingW = c.w;
    self.pendingH = c.h;
    self.pendingVisibleH = c.visibleH;
    self.canvasDeadline = CACurrentMediaTime() + 2.0;
    if (c.visibleH < c.h) {
        [JVMLauncher setShownRows:c.visibleH];
        [RouteCBridge setPipShownRows:c.visibleH];
        [JVMLauncher setEngineHudStripRows:c.visibleH windowTop:0 bottom:0];
    }
    [self appendLine:[NSString stringWithFormat:@"[screen] window %.0fx%.0f: canvas %dx%d -> %dx%d (shown %d rows) requested",
                                                size.width, size.height, self.renderW, self.renderH, c.w, c.h,
                                                c.visibleH]];
}

// Switch to the requested canvas once the game draws at it, or after canvasDeadline (before login the canvas stays
// at the login screen's size, and the resize at login goes straight to the newest request). The HUD is laid out
// again for it, and on a turn the chat and minimap take that orientation's offsets and zoom.
- (void)adoptCanvasIfDrawn {
    RMCanvas c = {self.pendingW, self.pendingH, self.pendingVisibleH};
    BOOL drawn = [JVMLauncher canvasWidth] == c.w && [JVMLauncher canvasHeight] == c.h;
    if (!drawn && CACurrentMediaTime() < self.canvasDeadline)
        return;
    self.canvasPending = NO;
    BOOL turned = [self setCanvas:c];
    if (c.visibleH >= c.h)
        [JVMLauncher setEngineHudStripRows:0 windowTop:0 bottom:0];
    self.stripSent = NO;
    self.engineChatRelocated = NO; // updateHudLayout places the chat and the minimap again, and resends the strip
    if (turned) {
        [self reloadHudOffsets];
        self.zoomSynced = NO;
    }
    if (self.overlayEdit) { // laid out for the old canvas
        [self.overlayEdit dismiss];
        self.overlayEdit = nil;
    }
    if (self.glLayer && c.visibleH > 0) {
        // The CAEAGLLayer's drawable is the canvas; the bridge rebuilds its framebuffer from the resized layer.
        CGSize b = self.view.bounds.size;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.glLayer.frame = CGRectMake(0, 0, b.width, b.height * c.h / c.visibleH);
        self.glLayer.contentsScale = b.height > 0 ? (CGFloat)c.visibleH / b.height : 1.0;
        [CATransaction commit];
        [RouteCBridge presentLayerResized];
    }
    [self appendLine:[NSString stringWithFormat:@"[screen] canvas %dx%d adopted (shown %d rows)%@", c.w, c.h, c.visibleH,
                                                drawn ? @"" : @", not drawn yet"]];
}

- (void)onLaunch {
    if (self.launched) return;
    // The debug panel's Start needs only CS_DEBUGGED. While the cover's script check is out, runelite-jit.js answers
    // one brk #0x69 and detaches, so a JVM started now would race the check for it and the loser dies of SIGTRAP.
    // (No check can start after this: the poller that starts them is stopped below.)
    if ([JVMLauncher jitScriptCheck] == RMJitScriptCheckRunning) {
        [self appendLine:@"[shell] launch refused: the StikDebug script check is still running; try again"];
        return;
    }
    // If the login web view ran this session, WebKit is resident and the JVM would crash at code-cache
    // init (the JIT brk can't be serviced). Require a fresh process first — restart instead of launching.
    if (self.webKitUsedThisSession) { [self promptRestartToPlay]; return; }
    self.launched = YES;
    self.launchButton.enabled = NO;
    [self.jitTimer invalidate];
    [self captureStdio];
    // Phase 4 cold start: the human part of a launch (the StikDebug attach, then the Play tap) is stamped too, so a
    // baseline can take it out. stderr reaches the log only from captureStdio on, so the attach time waited for it.
    if (self.jitAttachedMs != 0)
        fprintf(stderr, "[coldstart] jitAttached sinceStartMs=%ld\n", self.jitAttachedMs);
    [self stampColdStart:@"launch" line:@"[shell] launch: booting the JVM"];

    // Full-screen landscape: collapse the debug panel so the game owns the whole screen. The ≡ toggle
    // re-opens it (logs/canary), and logs still go to Documents/hello-shell.log; the ⌨ control stays.
    self.debugPanel.hidden = YES;

    // Boot-progress overlay: cover the JVM-boot gap with a spinner instead of a bare near-black screen.
    // 60.0s matches Android's SPLASH_TIMEOUT_MS failsafe so both platforms' bounds stay in lockstep. The
    // onLaunch `if (self.launched) return;` guard above makes this one-shot per process.
    [self setupBootStatusOverlay];
    self.bootStatusDeadline = CACurrentMediaTime() + 60.0;
    self.bootStatusScrim.hidden = NO;
    [self.view bringSubviewToFront:self.bootStatusScrim];
    [self.bootStatusSpinner startAnimating];

    // (1) Background-task assertion: tell iOS this is important in-progress work so it won't
    // suspend/kill the process while the JVM runs off-main. (The device jetsam'd the idle-UI
    // process within ~250 ms before; this is the primary longevity fix.)
    self.bgTask = [[UIApplication sharedApplication]
        beginBackgroundTaskWithName:@"jvm-run" expirationHandler:^{
            [self appendLine:@"[shell] background task expiring"];
            [self endBgTask];
        }];
    [self appendLine:[NSString stringWithFormat:@"[shell] bgTask=%lu", (unsigned long)self.bgTask]];

    // (2) Active render loop: blit the newest composited frame every screen refresh (straight from the engine
    // buffer via reverse JNI — JavaBridge.getFramePixels / [JVMLauncher latestFrame], see onDisplayTick; no PNG
    // round-trip). Keeps the app foreground-active+rendering (top jetsam band) AND shows the login screen live.
    self.framesShown = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayTick)];
    // ProMotion: drive the display at up to 120Hz so the GPU direct-present (synced to vsync) isn't capped at 60.
    // The GPU renders in ~3ms, so there's headroom for 120. (Needs CADisableMinimumFrameDurationOnPhone in Info.plist.)
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, 120.0f, 120.0f);
    }
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    JVMLogSink log = ^(NSString *line) { [self appendLine:line]; };
    [self appendLine:@"--- launching JVM on worker thread ---"];

    JVMLauncher *launcher = [[JVMLauncher alloc] init];
    launcher.routecL1Mode = self.pendingRouteCL1;     // GPU Route C L1 kill-test (always NO now)
    launcher.routecGpuMode = self.pendingRouteCGpu;   // GPU Route C full path (the plugins-panel renderer pick)
    launcher.routecZoneMode = self.pendingRouteCZone; // GPU Zone 117HD path (the plugins-panel renderer pick)
    if (self.pendingRouteCL1) {
        [self appendLine:@"[shell] *** GPU Route C L1 kill-test — booting RouteCL1Probe (not full RuneLite) ***"];
    } else if (self.pendingRouteCZone) {
        [self appendLine:@"[shell] *** GPU Zone (117HD) — booting full RuneLite with RLHD on the GL bridge (device GPU) ***"];
    } else if (self.pendingRouteCGpu) {
        [self appendLine:@"[shell] *** GPU Route C — booting full RuneLite with the GL bridge (device GPU) ***"];
    }
    // Edge-to-edge (A1): render aspect MATCHES THE FULL SCREEN (the game view fills the whole bounds), so the
    // blit fills it with no letterbox. The HUD no longer clips at the edges because it is relocated INTO the
    // safe area (updateHudLayout), not kept at the canvas corners.
    CGRect b = self.view.bounds;
    CGFloat sw = b.size.width;
    CGFloat sh = b.size.height;
    // The canvas follows the screen's sides (canvasForScreen:). The window can still be turning to the setting's
    // orientation, since Info.plist's list, which the launch screen uses, is landscape only, so a fixed setting says
    // which side is which. Under Auto the bounds decide, and resizeCanvasToScreen follows the window if it turns.
    BOOL portrait = [RMGameSettings autoRotate] ? sh > sw : [RMGameSettings portrait];
    if ((sh > sw) != portrait) {
        CGFloat t = sw;
        sw = sh;
        sh = t;
    }
    CGFloat aspect = (sh > 0 ? sw / sh : 2.0);
    RMCanvas canvas = [self canvasForScreen:CGSizeMake(sw, sh)];
    int renderW = canvas.w, renderH = canvas.h, visibleH = canvas.visibleH;
    if ([self setCanvas:canvas])
        [self reloadHudOffsets];
    if (self.pendingRouteCGpuNoResize) {
        // GPU Route C bisection: leave the canvas at the classic fixed 765x503 (no resizable switch) so we can
        // tell whether the scene render is suppressed by GPU mode itself or only by the resizable-layout path.
        launcher.resizeSpec = nil;
        [self appendLine:@"[shell] *** GPU Route C — FIXED mode (no headless.resize, 765x503 bisection) ***"];
    } else {
        launcher.resizeSpec = [NSString stringWithFormat:@"%dx%d", renderW, renderH];
        [self appendLine:[NSString stringWithFormat:@"[shell] full-screen %.0fx%.0f aspect %.3f -> render %@ shown %d rows",
                                                    sw, sh, aspect, launcher.resizeSpec, visibleH]];
    }

    // Background staying-power + Picture-in-Picture, armed BEFORE the present-layer wiring below: the 117HD
    // pip-present path hands the PiP layer itself to the GL bridge as its present target, so the layer must
    // exist first. The keepalive audio session (so iOS never suspends the JVM mid-session) covers EVERY
    // renderer; PiP covers every renderer that can feed it frames.
    [self setupBackgroundKeepalive];
    [self setupPictureInPicture];
    [self setupReconnectOverlay];   // FIX-9: native "Reconnecting…" scrim (hidden until a real reconnect)
    [self setupSessionExpiredOverlay]; // UX-LOGIN-01: "Session expired" card (hidden until a give-up)
    [self setupFatalErrorOverlay];     // FATAL-1: engine-fatal card (hidden until the bridge notes a fatal)
    [self setupHoppingOverlay];        // PARITY-P0-3: world-hop scrim (hidden until a hop is armed)

#if !defined(RC_BACKEND_ANGLE)
    // GPU Zone (117HD) PRESENT (EAGL). Two flavours, both no-glReadPixels (the measured ~16ms/frame bottleneck):
    //   - PIP-PRESENT (default, PiP supported): the plugin renders into the plain offscreen FBO and the bridge
    //     GPU-blits each frame into an IOSurface CVPixelBuffer enqueued on the SAME AVSampleBufferDisplayLayer
    //     the shell shows + the PiP controller sources. ONE visible presenter for the boot CPU frames AND the
    //     HD frames — so 117HD pops into Picture-in-Picture and keeps presenting in the background (GL under an
    //     active PiP session is device-proven allowed). Enqueue stays OFF until the warmup reveal in
    //     onDisplayTick, so the shell's CPU boot/login feed isn't raced by early sky frames.
    //   - CAEAGLLayer DIRECT (fallback, PiP unsupported): render straight into a drawable sublayer (the prior
    //     path; no PiP). Hidden until the warmup reveal.
    // Either way the target must be wired on main BEFORE the JVM thread starts (the bridge reads it from the
    // JVM thread in awtCreateGLContext). Fires for the Zone direct path ONLY: base GPU keeps the READBACK
    // present so it publishes int[] frames like the CPU rasterizer (runtime-toggleable renderer + PiP feed).
    if (self.pendingRouteCZoneDirect && !self.pendingRouteCGpuNoResize) {
        [self.view layoutIfNeeded];
        if (self.pipLayer) {
            [RouteCBridge setPipPresentLayer:self.pipLayer];
            self.gpuPresentArmed = YES;
            self.screen.backgroundColor = [UIColor blackColor];
            [self appendLine:[NSString stringWithFormat:@"[shell] GPU pip-present ARMED: 117HD -> AVSampleBufferDisplayLayer (blit %dx%d, no readback; PiP-capable)",
                              renderW, renderH]];
        } else {
            CAEAGLLayer *gl = [CAEAGLLayer layer];
            // From this launch's sides, not the bounds: the window can still be turning (see above). The strip's rows
            // run on below the screen.
            gl.frame = CGRectMake(0, 0, sw, sh * renderH / visibleH);
            gl.opaque = YES;
            gl.contentsScale = (sh > 0 ? (CGFloat)visibleH / sh : 1.0); // drawable = renderW x renderH (== engine canvas)
            gl.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking : @NO,
                                       kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };
            // Start HIDDEN + lazily reveal: the CAEAGLLayer is a sublayer of the UIImageView so it draws ABOVE the
            // CPU blit; keeping it hidden lets the CPU login/loading screen show during the ~10s boot, and the present
            // fires into the hidden layer meanwhile. onDisplayTick reveals it once the world has warmed up.
            gl.hidden = YES;
            [self.screen.layer insertSublayer:gl atIndex:0];
            self.glLayer = gl;
            self.gpuPresentArmed = YES;
            self.screen.backgroundColor = [UIColor blackColor];
            [RouteCBridge setPresentLayer:gl];
            [self appendLine:[NSString stringWithFormat:@"[shell] GPU direct-present ARMED (hidden): CAEAGLLayer %.0fx%.0f @%.3f -> drawable %dx%d (no readback)",
                              gl.bounds.size.width, gl.bounds.size.height, gl.contentsScale, renderW, renderH]];
        }
    }
#elif defined(RC_ANGLE_WINDOW_PRESENT)
    // Phase A1 (MetalANGLE) WINDOW-SURFACE DIRECT PRESENT (60fps, present=0.07ms). The GPU renders the scene with
    // ZERO GL errors and eglSwapBuffers presents at 62fps, but on device the CAMetalLayer did not scan out to the
    // display (black screen) — the window-surface present is NOT yet visually confirmed (the gpu-present probe
    // sealed on a glReadPixels self-check, not a screenshot). So this path is GATED OFF by default until the
    // present is debugged; the default ANGLE build uses the proven offscreen+readback path below.
    if (self.pendingRouteCGpu && !self.pendingRouteCGpuNoResize) {
        [self.view layoutIfNeeded];
        CAMetalLayer *ml = [CAMetalLayer layer];
        ml.frame = CGRectMake(0, 0, sw, sh * renderH / visibleH); // this launch's sides; the strip runs on below
        ml.opaque = YES;
        ml.framebufferOnly = NO;
        ml.drawableSize = CGSizeMake(renderW, renderH);
        ml.contentsScale = (sh > 0 ? (CGFloat)visibleH / sh : 1.0);
        [self.screen.layer insertSublayer:ml atIndex:0];
        self.metalLayer = ml;
        [RouteCBridge setPresentLayer:ml];
        if ([RouteCBridge prepareWindowSurfaceOnMain]) {
            self.gpuPresentArmed = YES;   // onDisplayTick flips to direct present once the first GPU frame presents
            [self appendLine:[NSString stringWithFormat:@"[shell] GPU (MetalANGLE) direct present ARMED: drawable %dx%d", renderW, renderH]];
        } else {
            [RouteCBridge setPresentLayer:nil];
            [ml removeFromSuperlayer];
            self.metalLayer = nil;
            [self appendLine:@"[shell] GPU (MetalANGLE) window surface FAILED -> offscreen FBO + readback present"];
        }
    } else if (self.pendingRouteCGpu) {
        [self appendLine:@"[shell] GPU (MetalANGLE) — offscreen FBO + readback present (no-resize bisection)"];
    }
#else
    // Phase A1 default: OFFSCREEN FBO + glReadPixels readback present — the PROVEN-DISPLAY path. The GPU-rendered
    // scene is published via JavaBridge.gpuPublish -> latestFrame -> onDisplayTick blit (the exact path that
    // displays the CPU frames), so it is guaranteed to scan out. The readback copy caps it at ~50fps; the 60fps
    // CAMetalLayer window present is gated behind RC_ANGLE_WINDOW_PRESENT until its display is confirmed. No present
    // layer is set -> the bridge runs offscreen + readback.
    if (self.pendingRouteCGpu) {
        [self appendLine:@"[shell] GPU (MetalANGLE) — offscreen FBO + readback present (proven-display path)"];
    }
#endif

    [self startVmThreadWithLauncher:launcher
                                log:log];
}

// The jvm-main worker thread: boot the VM (runProbesWithLog, which runs the engine and normally never returns),
// then on a real return tear the render loop + bridge down on main. Extracted from -onLaunch so PARITY-P0-6's
// boot-failure reporting can be added without disturbing the surrounding preprocessor-gated GPU-route block.
- (void)startVmThreadWithLauncher:(JVMLauncher *)launcher log:(JVMLogSink)log {
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        [self runVmProbesAndReport:launcher log:log]; // PARITY-P0-6: shows a boot-failure card on a negative rc
        // VM lifecycle done; tear the render loop + bridge down on main, then release the assertion. (Reached
        // only on a boot FAILURE - on success jvm-main parks forever inside runProbesWithLog, since the boot
        // entrypoint returns mid-session while the engine's non-daemon threads keep the session alive.)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLine:@"[shell] JVM thread returned - tearing down render loop + bridge"];
            [self.displayLink invalidate];
            self.displayLink = nil;
            [self teardownPictureInPicture];
            // The watchdog would otherwise restart the keepalive every 15 s for a session that is gone.
            [self.keepaliveWatchdog invalidate];
            self.keepaliveWatchdog = nil;
            [self.keepaliveEngine stop];
            [JVMLauncher bridgeInvalidate];
            [self endBgTask];
        });
    }];
    t.stackSize = 16 * 1024 * 1024;
    t.name = @"jvm-main";
    [t start];
}

// W3 Feature-A (A1+A3+A4): drive the edge-to-edge HUD. Rather than reproduce the HUD natively, we RELOCATE the
// engine's own pixel-perfect widgets into the safe area while the scene fills the screen edge-to-edge: the chatbox
// to the top-left (transparent OSRS-mobile mode), and the minimap+orbs cluster to the top-right. Both stay the
// real, live engine HUD (chat tabs/scrollback/input + minimap click-to-walk + orb clicks all keep working).
// One-shot once we're logged in; HudVeneerBridge re-applies each frame (survives TOPLEVEL_REDRAW).
// Safe-area insets changed (landscape-left<->right rotation, notch-side flip) — clear the one-shot relocate
// guard so the next updateHudLayout tick (~10Hz) re-anchors chat/minimap to the new safe rect instead of
// leaving them pinned to stale insets.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    self.engineChatRelocated = NO;
}

// TAB-1: the right-edge width the HUD keeps clear: the safe area, or the plugin rail's strip where that is wider. An
// iPhone's landscape safe area already holds the rail beside the tab grid and the minimap; an iPad (or an iPhone
// with a home button) has no side insets, so without this the rail covers the grid's right column.
- (CGFloat)hudRightInset {
    // In portrait the rail keeps to the gap between the minimap and the tab group instead (updateChrome): its 47 pt
    // strip, a ninth of the screen's width, would push the minimap over the chat.
    if (self.view.bounds.size.height > self.view.bounds.size.width)
        return self.view.safeAreaInsets.right;
    return MAX(self.view.safeAreaInsets.right, [self.panelDock railStripWidth]);
}

- (void)updateHudLayout {
    // TAB-1: re-anchor when the rail's strip changes; it comes and goes with the setting and the first panels
    // arriving after boot. Checked here, not in updateChrome, which the chrome toggle and the map can skip.
    if (self.engineChatRelocated && [self hudRightInset] != self.hudRightLaid)
        self.engineChatRelocated = NO;
    // A new canvas is on its way (auto-rotate): lay out for it once it's adopted, not for the old one in the new window.
    if (self.engineChatRelocated || self.canvasPending)
        return;
    NSString *snap = [JVMLauncher hudSnapshot];
    if (snap.length == 0) return;   // bridge / VM not up yet — retry next tick
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateHudLayout");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue]) return;
    if (self.renderW <= 0) return;
    self.engineChatRelocated = YES;

    // Safe-area insets are in screen points; convert to canvas px (the engine draws at renderW×renderH, blitted
    // full-screen, so canvasPx = points * renderW/screenW). Keep the relocated HUD inside the safe rect.
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat sw = self.view.bounds.size.width;
    CGFloat k = (sw > 0) ? (CGFloat)self.renderW / sw : 1.0;
    self.hudRightLaid = [self hudRightInset];
    int topC   = (int)lround(ins.top * k);
    int leftC  = (int)lround(ins.left * k);
    int rightC = (int)lround(self.hudRightLaid * k);
    const int m = hudPx(8); // canvas-px margin from the safe edge
    // Make the minimap BIGGER: enlarge the engine globe + reposition its chrome (HudVeneerBridge.setMinimapScale).
    // The globe is right-anchored, so it grows left+down within the cluster — the right edge stays at MM_W, so the
    // cluster still aligns to the right safe edge; only the orbs/compass spread further left/down (into the gap
    // between the top-left chat and the top-right minimap). 0/100 = natural size.
    const int kMinimapScalePct = 100;   // 100 = natural (the engine pins the orbs, so a bigger globe can't be wrapped cleanly)

    // The chat column takes the safe area's top-left corner, flush, as the official one does, and the chat sits right
    // of it (updateChrome lays the column).
    self.chatBaseX = leftC + hudPx(kDoorCanvasW);
    self.chatBaseY = topC;
    self.minimapBaseX = self.renderW - hudPx(kMinimapClusterW) - rightC - m;
    self.minimapBaseY = topC + m;

    // transparent:YES = OSRS-mobile translucent chat (text over the scene, no opaque box) — the official look.
    // Apply the persisted user drag offset to the base anchor (relocates the engine chat + sets the hit/scroll rects).
    [self applyChatRelocate];
    // W3 A3: the native veneer recreates the tab row BIGGER (engine push-down applied per-tick in updateChatTabs).
    [self applyMinimapRelocate];                            // base anchor + the persisted user offset, like the chat
    [JVMLauncher setEngineMinimapScale:kMinimapScalePct];   // enlarge the globe + reposition its chrome to hug it
    if (!self.stripSent)
        [self sendHudStripTop:0 bottom:0];     // large portrait on; updateChrome sends the window band
    [JVMLauncher setEngineStonesHidden:YES];   // the native 2-col grid replaces them (no cover patch / gray box)
    // Overlay snap-corner safe frame: plugin overlays snapped to a corner (Quest Helper's top-left guidance
    // panel etc.) clear the curved bezel/notch; the engine also drops the top-left corner below the chat.
    int botC = (int)lround(ins.bottom * k);
    [JVMLauncher setEngineOverlaySafeInsetsL:leftC t:topC r:rightC b:botC];
    // The whole enlarged tab row is UI: a stray tap in it (between native buttons) should be a precise click, not
    // a walk. The native buttons own their taps; this rect just keeps any leak from drawing a walk ring.
    [self appendLine:[NSString stringWithFormat:@"[hud] relocate chat->%d,%d(+%d,%d) minimap->%d,%d(+%d,%d) (insets L%d T%d R%d k%.2f)",
                                                self.chatBaseX, self.chatBaseY, self.chatUserDX, self.chatUserDY, self.minimapBaseX,
                                                self.minimapBaseY, self.minimapUserDX, self.minimapUserDY, leftC, topC, rightC, k]];
}

// The shell's own controls over the game, sent to the engine so plugin overlay boxes keep off them
// (HudVeneerBridge.setOverlayKeepOut): every enabled control a tap can reach and every view a tap gesture listens on,
// in canvas px. The engine adds its own HUD (the chat, the minimap, the side panel). Sent only when the list changes.
- (void)updateOverlayKeepOut {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    if (self.renderW <= 0 || W <= 0 || H <= 0)
        return;
    NSMutableData *rects = [NSMutableData data];
    [self collectKeepOut:self.view into:rects scale:(CGFloat)self.renderW / W screenArea:W * H];
    if ([rects isEqualToData:self.sentKeepOut])
        return;
    self.sentKeepOut = rects;
    int count = (int)(rects.length / sizeof(int));
    [JVMLauncher setEngineOverlayKeepOut:rects.bytes count:count];
    [self appendLine:[NSString stringWithFormat:@"[hud] overlay keep-out: %d control(s)", count / 4]];
}

// Walks `v`'s subviews for updateOverlayKeepOut. A control is taken whole. A view a quarter of the screen or bigger
// isn't a control: one with a solid background is a panel or a scrim, and nothing under it shows, so it is passed
// over; a clear one (the plugin dock, the game view) is looked inside. The hold menu and the overlay editor are passed
// over too: a box moving off either would chase it.
- (void)collectKeepOut:(UIView *)v into:(NSMutableData *)rects scale:(CGFloat)k screenArea:(CGFloat)area {
    for (UIView *s in v.subviews) {
        if (s.hidden || s.alpha < 0.01 || !s.userInteractionEnabled || s == self.menuContainer || s == self.overlayEdit)
            continue;
        CGRect f = [s convertRect:s.bounds toView:self.view];
        BOOL big = f.size.width * f.size.height >= area / 4;
        BOOL tappable = [s isKindOfClass:[UIControl class]] && ((UIControl *)s).enabled;
        for (UIGestureRecognizer *g in s.gestureRecognizers)
            tappable = tappable || g.enabled;
        if (!big && tappable) {
            if (f.size.width >= 4 && f.size.height >= 4) {
                int r[4] = {(int)floor(f.origin.x * k), (int)floor(f.origin.y * k), (int)ceil(f.size.width * k),
                            (int)ceil(f.size.height * k)};
                [rects appendBytes:r length:sizeof(r)];
            }
            continue;
        }
        if (big && s != self.screen && CGColorGetAlpha(s.backgroundColor.CGColor) > 0.5)
            continue;
        [self collectKeepOut:s into:rects scale:k screenArea:area];
    }
}

// A camera zoom for each orientation (Settings > Game settings > Screen). The 3D view scales with the canvas's height,
// so the zoom that suits a landscape canvas looks nearly three times closer on a portrait one, and the other way
// round. The game saves one zoom, so zoom.owner records which orientation that zoom is for: landscape until the first
// switch, since every launch before the setting was landscape. When the zoom is first known after login, and again
// after each turn (adoptCanvasIfDrawn): if the canvas's orientation isn't the owner, the game's zoom is kept for the
// owner and this orientation gets back the zoom it had when it was left, if it was ever left. Nothing is chosen for
// the player: an orientation keeps the game's zoom as it is until it has been left once (the Android port's screen
// classes do the same).
- (void)syncOrientationZoom {
    if (self.zoomSynced)
        return;
    int zoom = [JVMLauncher cameraZoom];
    if (zoom < 0)
        return; // logged out, or an older jar: try again on a later tick
    self.zoomSynced = YES;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *mine = sCanvasPortrait ? @"portrait" : @"landscape";
    NSString *owner = [ud stringForKey:@"zoom.owner"] ?: @"landscape";
    [ud setObject:mine forKey:@"zoom.owner"];
    if ([owner isEqualToString:mine])
        return;
    NSString *savedKey = [@"zoom." stringByAppendingString:mine];
    int saved = [ud objectForKey:savedKey] ? (int)[ud integerForKey:savedKey] : -1;
    [ud setInteger:zoom forKey:[@"zoom." stringByAppendingString:owner]];
    if (saved >= 0 && saved != zoom)
        [JVMLauncher setCameraZoom:saved];
    [self appendLine:[NSString stringWithFormat:@"[shell] zoom %d kept for %@; %@ %@", zoom, owner, mine,
                                                saved >= 0 ? [NSString stringWithFormat:@"gets %d back", saved]
                                                           : @"keeps it"]];
}

// Relocate the minimap+orbs cluster to (base anchor + persisted user offset), clamped on-screen. Called from
// updateHudLayout, when the chrome snapshot first reports the cluster's size, and live while it's moved in overlay
// edit-mode. Minimap clicks and the orb taps follow it: both use the engine's live widget bounds.
- (void)applyMinimapRelocate {
    if (self.renderW <= 0 || self.minimapBaseX <= 0)
        return; // not placed yet
    [JVMLauncher relocateEngineMinimapX:[self clampMinimapX:self.minimapBaseX + self.minimapUserDX]
                                      y:[self clampMinimapY:self.minimapBaseY + self.minimapUserDY]];
}

- (int)clampMinimapX:(int)x {
    int w = self.minimapCanvasSize.width > 0 ? (int)self.minimapCanvasSize.width : hudPx(kMinimapClusterW);
    int maxX = self.renderW - w;
    if (maxX < 0)
        maxX = 0;
    return x < 0 ? 0 : (x > maxX ? maxX : x);
}

- (int)clampMinimapY:(int)y {
    int maxY = self.visibleH - (int)self.minimapCanvasSize.height; // height unknown (0): keep the top on-screen
    if (maxY < 0)
        maxY = 0;
    return y < 0 ? 0 : (y > maxY ? maxY : y);
}

// Relocate the chat to (base anchor + persisted user offset), clamped on-screen, and sync the hit/scroll rects.
// Called from updateHudLayout (initial) and live while moving the chat in overlay edit-mode. The engine chat is
// invisible (native render), so this drives the snapshot chatX/chatY that positions the native tab row + messages.
- (void)applyChatRelocate {
    if (!kChatVeneerEnabled) {
        // Veneer removed: stop relocating so the engine renders its ORIGINAL bottom chatbox + tabs, and clear the
        // native tap rects so onTap routes to the world/engine normally (no stale top chat-region routing).
        [JVMLauncher relocateEngineChatX:-1 y:-1 transparent:NO];
        self.chatHitCanvas = CGRectZero;
        self.chatScrollCanvas = CGRectZero;
        self.dialogueChatCanvas = CGRectZero;
        self.chatScrollable = NO;
        self.chatDialogueActive = NO;
        return;
    }
    int chatX = [self clampChatX:self.chatBaseX + self.chatUserDX];
    int chatY = [self clampChatY:self.chatBaseY + self.chatUserDY];
    [JVMLauncher relocateEngineChatX:chatX y:chatY transparent:YES];
    self.chatHitCanvas = CGRectMake(chatX, chatY, hudPx(kChatW), chatRowCanvasH());
    self.chatScrollCanvas = CGRectMake(chatX, chatY, hudPx(kChatW), chatRowCanvasH() + hudPx(kChatContentCanvasH));
}

- (int)clampChatX:(int)x {
    int door = hudPx(kDoorCanvasW);
    int maxX = self.renderW - hudPx(kChatW);
    if (maxX < door)
        maxX = door;
    return x < door ? door : (x > maxX ? maxX : x); // room for the door on its left
}

- (int)clampChatY:(int)y {
    int boxH = chatRowCanvasH() + hudPx(kChatContentCanvasH);
    int maxY = self.visibleH - boxH;
    if (maxY < 0) maxY = 0;
    return y < 0 ? 0 : (y > maxY ? maxY : y);
}

// ---- OverlayEditHudHost: the chatbox and minimap are repositioned in overlay edit-mode (draggable handles) ----

- (CGRect)overlayEditChatCanvasRect {
    if (!kChatVeneerEnabled) return CGRectNull;   // veneer removed: no native chat to drag in overlay edit-mode
    if (self.renderW <= 0 || self.chatBaseX <= 0) return CGRectNull;   // not placed yet
    int chatX = [self clampChatX:self.chatBaseX + self.chatUserDX];
    int chatY = [self clampChatY:self.chatBaseY + self.chatUserDY];
    return CGRectMake(chatX, chatY, hudPx(kChatW), chatRowCanvasH() + hudPx(kChatContentCanvasH));
}

- (void)overlayEditMoveChatToCanvasX:(int)x y:(int)y {
    self.chatUserDX = [self clampChatX:x] - self.chatBaseX;
    self.chatUserDY = [self clampChatY:y] - self.chatBaseY;
    [self applyChatRelocate];   // tab row + messages follow via the snapshot next tick
}

- (void)overlayEditCommitChatMove {
    [[NSUserDefaults standardUserDefaults] setInteger:self.chatUserDX forKey:hudOffsetKey(@"chatUserDX")];
    [[NSUserDefaults standardUserDefaults] setInteger:self.chatUserDY forKey:hudOffsetKey(@"chatUserDY")];
    [self appendLine:[NSString stringWithFormat:@"[chat] moved -> offset %d,%d", self.chatUserDX, self.chatUserDY]];
}

- (CGRect)overlayEditMinimapCanvasRect {
    // Not placed yet, or its size not reported yet (the handle must cover the real cluster).
    if (self.renderW <= 0 || self.minimapBaseX <= 0 || self.minimapCanvasSize.height <= 0)
        return CGRectNull;
    return CGRectMake([self clampMinimapX:self.minimapBaseX + self.minimapUserDX],
                      [self clampMinimapY:self.minimapBaseY + self.minimapUserDY], self.minimapCanvasSize.width,
                      self.minimapCanvasSize.height);
}

- (void)overlayEditMoveMinimapToCanvasX:(int)x y:(int)y {
    self.minimapUserDX = [self clampMinimapX:x] - self.minimapBaseX;
    self.minimapUserDY = [self clampMinimapY:y] - self.minimapBaseY;
    [self applyMinimapRelocate];
}

- (void)overlayEditCommitMinimapMove {
    [[NSUserDefaults standardUserDefaults] setInteger:self.minimapUserDX forKey:hudOffsetKey(@"minimapUserDX")];
    [[NSUserDefaults standardUserDefaults] setInteger:self.minimapUserDY forKey:hudOffsetKey(@"minimapUserDY")];
    [self appendLine:[NSString stringWithFormat:@"[minimap] moved -> offset %d,%d", self.minimapUserDX,
                                                self.minimapUserDY]];
}

- (void)overlayEditResetMinimap {
    self.minimapUserDX = 0;
    self.minimapUserDY = 0;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:hudOffsetKey(@"minimapUserDX")];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:hudOffsetKey(@"minimapUserDY")];
    [self applyMinimapRelocate];
    [self appendLine:@"[minimap] reset -> automatic top-right"];
}

// World map (touch): poll the bridge map snapshot (~10 Hz). Edge-triggered chrome hide/restore: the engine
// map is FULLSCREEN at our canvas, so the native chrome (chat tab row, tab grid via the mapOpen gates in
// updateChatTabs/updateChrome, dock + corner buttons here) would cover it and steal taps. The ✕ proxies the
// engine CLOSE (its widget sits under the curved corner). Rects refresh every poll; visibility flips on edges.
static CGRect mapRectFromArr(NSArray *a) {
    if (![a isKindOfClass:[NSArray class]] || a.count != 4) return CGRectZero;
    return CGRectMake([a[0] doubleValue], [a[1] doubleValue], [a[2] doubleValue], [a[3] doubleValue]);
}

- (void)updateWorldMap {
    NSString *snap = [JVMLauncher mapSnapshot];
    BOOL open = NO, searching = NO;
    CGRect closeR = CGRectZero, searchR = CGRectZero, windowR = CGRectZero;
    if (snap.length) {
        NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateWorldMap");
        if ([d isKindOfClass:[NSDictionary class]] && [d[@"open"] boolValue]) {
            open = YES;
            searching = [d[@"searching"] intValue] == 1;
            closeR = mapRectFromArr(d[@"close"]);
            searchR = mapRectFromArr(d[@"search"]);
            windowR = mapRectFromArr(d[@"window"]);
            self.mapKeyCanvas = mapRectFromArr(d[@"key"]);
            self.mapListCanvas = mapRectFromArr(d[@"maplist"]);
        } else {
            self.mapKeyCanvas = CGRectZero;
            self.mapListCanvas = CGRectZero;
        }
    }
    // FIX-14: the map search never flips INPUT_TYPE, so the soft keyboard would otherwise linger over the
    // jumped-to map. On the engine WORLDMAP_SEARCHING 1->0 edge the search has committed (Enter) / cancelled
    // (Quit) — resign the capture field so the keyboard auto-hides.
    if (self.mapWasSearching && !searching && [self.kbField isFirstResponder]) {
        [self.kbField resignFirstResponder];
        [self appendLine:@"[map] search committed -> dismiss keyboard"];
    }
    self.mapWasSearching = searching;
    self.mapCloseCanvas = closeR;
    self.mapSearchCanvas = searchR;
    self.mapWindowCanvas = windowR;
    // Official-mobile look: scale the displayed frame so the engine's (size-capped) map window fills the
    // screen width, black bands above/below. Display-only — input is untouched (gesture locations are read
    // in self.screen's BOUNDS space, which UIKit maps back through the transform; mapPoint works on bounds).
    [self applyMapZoom:open windowCanvas:windowR];
    if (open == self.mapOpen) return;
    self.mapOpen = open;
    // Corner controls that overlap the (centred) map window (the chat/tab-grid veneers hide via their own
    // ticks). The window itself is positioned by the bridge (centred via the WORLDMAP_X/Y varcs) and the
    // scene stays visible around it, like the desktop window — no masks, and the engine's own close X is
    // fully on-screen and tappable. Only the live controls need hiding: the ⚙ gear, the pinned-controls
    // stack, and the plugin dock. (The legacy cluster stays permanently hidden via hideLegacyCluster, so we
    // must NOT toggle it here — setting .hidden=NO on close would resurrect the retired buttons.)
    self.settingsButton.hidden = open;
    self.controlsBox.hidden = open || self.onLoginScreen;
    self.kbFab.hidden = open || self.chatColumnShown;
    self.panelDock.view.hidden = open;
    self.closeMapButton.hidden = !open; // inverse of the rest: the ✕ shows only WHILE the map is open
    [self appendLine:open ? @"[map] world map OPEN -> map pan/taps, chrome hidden"
                          : @"[map] world map closed -> chrome restored"];
}

// The ✕ close handler (parity with Android's Back callback): proxy the engine's own CLOSE rect via a precise
// click when we know it, else fall back to Esc (rare: map just opened, close-rect snapshot not yet polled).
- (void)onCloseWorldMap {
    if (![JVMLauncher bridgeReady])
        return;
    CGRect cc = self.mapCloseCanvas;
    if (cc.size.width > 0 && cc.size.height > 0) {
        int gx = (int)lround(CGRectGetMidX(cc));
        int gy = (int)lround(CGRectGetMidY(cc));
        [JVMLauncher postClickPreciseX:gx y:gy button:1];
        [self appendLine:[NSString stringWithFormat:@"[map] close -> precise click @%d,%d", gx, gy]];
    } else {
        [JVMLauncher postKeyStroke:AWT_VK_ESCAPE];
        [self appendLine:@"[map] close -> Esc (no close rect yet)"];
    }
}

// Scale the game view so the map window fills the full screen width, centred vertically, with black bands
// covering the magnified scene above/below — the official-OSRS-Mobile fullscreen-map look. The engine caps
// the window's real size (probe-settled), so the fill is a DISPLAY transform only: hit-testing stays on the
// engine's true geometry, and touches are unaffected (read in bounds space). The bands sit over the game
// view, so they also swallow stray touches outside the scaled window.
- (void)applyMapZoom:(BOOL)open windowCanvas:(CGRect)wr {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    if (!open || wr.size.width <= 0 || self.renderW <= 0 || W <= 0) {
        if (!CGAffineTransformIsIdentity(self.screen.transform)) {
            self.screen.transform = CGAffineTransformIdentity;
            self.screen.layer.magnificationFilter = kCAFilterLinear;
            self.glLayer.magnificationFilter = kCAFilterLinear;
            self.pipLayer.magnificationFilter = kCAFilterLinear;
        }
        for (UIView *v in self.mapBands) v.hidden = YES;
        return;
    }
    // Pixel-art crispness: the scaled-up map reads SOFT under bilinear magnification — switch to
    // nearest-neighbour while the map fills the screen (the official app's map is crisp-pixelated too).
    self.screen.layer.magnificationFilter = kCAFilterNearest;
    self.glLayer.magnificationFilter = kCAFilterNearest;
    self.pipLayer.magnificationFilter = kCAFilterNearest;
    CGFloat s = W / (CGFloat)self.renderW;   // canvas px -> screen pt (untransformed)
    CGRect r = CGRectMake(wr.origin.x * s, wr.origin.y * s, wr.size.width * s, wr.size.height * s);
    CGFloat k = W / r.size.width;            // fill the full width
    CGAffineTransform t = CGAffineTransformMake(k, 0, 0, k,
                                                k * (W / 2 - CGRectGetMidX(r)),
                                                k * (H / 2 - CGRectGetMidY(r)));
    if (!CGAffineTransformEqualToTransform(self.screen.transform, t)) {
        self.screen.transform = t;
    }
    if (!self.mapBands) {
        NSMutableArray<UIView *> *m = [NSMutableArray arrayWithCapacity:2];
        for (int i = 0; i < 2; i++) {
            UIView *v = [[UIView alloc] initWithFrame:CGRectZero];
            v.backgroundColor = [UIColor blackColor];
            [self.view addSubview:v];
            [m addObject:v];
        }
        self.mapBands = m;
    }
    CGFloat hk = r.size.height * k;          // the scaled window's on-screen height
    CGFloat top = (H - hk) / 2;
    self.mapBands[0].frame = CGRectMake(0, 0, W, MAX(0, top));
    self.mapBands[1].frame = CGRectMake(0, top + hk, W, MAX(0, H - top - hk));
    for (UIView *v in self.mapBands) { v.hidden = NO; [self.view bringSubviewToFront:v]; }
}

// Called every screen refresh once the JVM is running. Pulls the engine's latest composited frame
// straight from the buffer via reverse JNI (JavaBridge.getFramePixels) and blits it — no PNG round-trip,
// no disk, no capture budget, so it's smooth and runs for the whole session. Also keeps the app
// foreground-active+rendering (the jetsam-protection that the §6.2 work established).
- (void)onDisplayTick {
#if TARGET_OS_SIMULATOR
    [self simScreenTick];
#endif
    // Boot-progress overlay: MUST run before the `if (!pipPresenting && img == nil) return;` early-out below,
    // which skips the rest of this method for the entire pre-first-frame window - exactly the window this overlay
    // covers. Downstream update* calls (reconnect/fatal) run after that return, so they can't clear this one.
    [self updateBootStatusOverlay];
    // GPU crash cookie (P1-21: now protects BOTH GPU tiers — the pref consumes it for base GPU and 117HD alike).
    // CLEAR on proof the GPU renderer produced a usable frame; ARM once its boot is underway but hasn't yet, so a
    // boot that dies in GL-init/shader-compile falls back to CPU next launch. The survival proof differs by tier:
    //   - 117HD (direct present): the first GL present (deliberately looser than the sceneWarmedUp reveal below;
    //     a user quitting at the login screen must not demote). Armed once the player is in the game, because 117HD
    //     starts there: a crash while they sit on the login screen says nothing about it.
    //   - base GPU (readback present): the first blitted frame (framesShown>0) — it never sets gpuPresentArmed nor
    //     presents off-thread, so hasPresentedFrame never fires for it; its readback frame IS the survival proof.
    //     Armed as soon as its boot is running and frameless (before that first readback frame).
    // Clear is checked first so a boot that produces its frame before the shell notices never stays armed.
    if (self.pendingRouteCZoneDirect && self.gpuPresentArmed && !self.hdBootCookieSettled) {
        if ([RouteCBridge hasPresentedFrame]) {
            [self hdBootCookieClear];
            self.hdBootCookieArmed = NO;
            self.hdBootCookieSettled = YES;
            [self stampColdStart:@"gpuFirstPresent" line:@"[shell] 117HD first GL present - crash cookie cleared"];
        } else if (!self.hdBootCookieArmed && !self.appBackgrounded && self.framesShown > 0 && self.awakeInGame) {
            [self hdBootCookieArm];
            self.hdBootCookieArmed = YES;
            [self appendLine:@"[shell] 117HD boot underway — crash cookie armed (clears on first GL present)"];
        }
    } else if (self.pendingRouteCGpu && self.launched && !self.hdBootCookieSettled) {
        // Base GPU: clear ONLY on true GPU provenance. framesShown is not it - the CPU snapshot publishes login
        // frames (bumping framesShown) before the engine flips into GPU mode, so clearing on framesShown would
        // fire during CPU login, before any GPU shader ran. gpuFrameSeq is bumped solely by the GPU readback
        // seam, so > 0 means the GPU renderer actually rendered + read back + presented a real frame.
        if ([JVMLauncher gpuFrameSeq] > 0) {
            [self hdBootCookieClear];
            self.hdBootCookieArmed = NO;
            self.hdBootCookieSettled = YES;
            [self stampColdStart:@"gpuFirstFrame" line:@"[shell] GPU first frame - crash cookie cleared"];
        } else if (!self.hdBootCookieArmed && !self.appBackgrounded && self.framesShown > 0) {
            [self hdBootCookieArm];
            self.hdBootCookieArmed = YES;
            [self appendLine:@"[shell] GPU boot underway — crash cookie armed (clears on first GPU frame)"];
        }
    }
    // Lazy switch to direct present: keep blitting CPU frames (boot/login/loading stay visible) until the GPU has
    // presented a frame AND the world has warmed up (geometry uploaded) — then reveal the GPU layer and stop the CPU
    // blit. The warmup gate (sceneWarmedUp) means the first frame the user sees is the world, not the boot sky.
    if (self.gpuPresentArmed && !self.gpuPresent && [RouteCBridge hasPresentedFrame] && [JVMLauncher sceneWarmedUp]) {
        self.gpuPresent = YES;
        self.screen.image = nil;                     // GL presents directly; UIImageView is just a gesture host
        self.screen.backgroundColor = [UIColor blackColor];
        if (self.glLayer) {
            // CAEAGLLayer fallback (PiP unsupported): reveal the drawable; PiP has no frame source here.
            self.glLayer.hidden = NO;
            [self teardownPictureInPicture];
            [self appendLine:@"[shell] GPU direct present LIVE (world warmed up — layer revealed)"];
        } else {
            // 117HD pip-present: the bridge takes over the PiP layer. The shell's feed lets go of it first and the
            // bridge starts only once the feed's pass in flight has ended, so no late CPU frame can follow the
            // bridge's first; the gpuPresent gates stop the kicks. First enqueued frame is the warmed-up world,
            // matching the old reveal UX. PiP torn down before then: stay off.
            __weak typeof(self) ws = self;
            [JVMLauncher pipFeedSetLayer:nil
                                 drained:^{
                                     if (!ws.pipLayer)
                                         return;
                                     [RouteCBridge setPipPresentEnabled:YES];
                                     [ws appendLine:@"[shell] GPU pip-present LIVE (world warmed up - bridge feeds the PiP layer)"];
                                 }];
        }
    }
    if (self.gpuPresent) {
        // GPU direct-present: the engine renders straight into the CAEAGLLayer and presents on its own thread, so
        // there is no per-tick blit here. Keep the tick alive for the heartbeat + native HUD/chrome refresh below.
        self.framesShown++;
    } else {
        // The PiP AVSampleBufferDisplayLayer (a sublayer of `screen` at index 0) is the visible presenter, fed
        // below by pipPumpFrame — so while it's actively rendering, blitting screen.image here is fully-occluded
        // work, and latestFrame costs a full-canvas copy + a CGImage per frame. Feed the UIImageView only
        // as a FALLBACK: when the PiP layer isn't presenting (not-yet / failed / torn down), plus a ~1 Hz refresh
        // so the occluded fallback stays current if the PiP layer ever drops out mid-session.
        BOOL pipPresenting = (self.pipLayer != nil && self.pipLayer.sampleBufferRenderer.status == AVQueuedSampleBufferRenderingStatusRendering);
        UIImage *img = (!pipPresenting || self.framesShown % 60 == 0) ? [JVMLauncher latestFrame] : nil;
        if (!pipPresenting && img == nil) return;   // no composited frame yet — skip the rest of the tick (as before)
        if (img != nil) self.screen.image = img;
        self.framesShown++;
        // Light heartbeat (~once/sec) so the log shows the loop running without flooding it.
        if (img != nil && (self.framesShown == 1 || self.framesShown % 60 == 0)) {
            [self appendLine:[NSString stringWithFormat:@"[shell] live blit frame #%d (%.0fx%.0f)",
                              self.framesShown, img.size.width, img.size.height]];
        }
    }

    // Auto-rotate: ask for the canvas that suits a turned window, then adopt it once the game draws at it.
    if (self.canvasCheckDue)
        [self resizeCanvasToScreen];
    if (self.canvasPending)
        [self adoptCanvasIfDrawn];

    // Feed the Picture-in-Picture layer every tick (the copy is skipped unless the engine composited a NEW
    // frame, so this is engine-rate ~50 fps, not display-rate, and it runs on the feed thread, not here). The
    // layer IS the visible presenter — it draws over the UIImageView's identical blit — because the system only
    // auto-lifts video it considers visibly playing inline; an occluded feed layer never engaged on device.
    if (self.pipController && !self.gpuPresent) {
        [self pipPumpFrame];
    }

    // Capture the real OSRS chrome sprites from the live cache once the engine has them (~2 Hz until a complete set
    // lands, then never again this session). Mirrors desktop RuneLite: render interface art from the cache, ship none.
    if (!self.tabSpritesComplete && self.framesShown % 15 == 0) {
        [self refreshTabSpritesFromCache];
    }

    // Refresh the native tab rails from the chrome snapshot (~10 Hz — positions/active state rarely change,
    // and the JSON read is cheap). Skipped entirely when the rails are toggled off.
    if (self.chromeVisible && self.framesShown % 6 == 0) {
        [self updateChrome];
    }

    // FIX-9: drive the "Reconnecting…" scrim ~10 Hz, UNGATED by chrome/login — the reconnect happens while NOT
    // logged in, so it can't sit behind updateChrome's chromeVisible gate or the other updaters' loggedIn returns.
    if (self.framesShown % 6 == 0) {
        [self updateLayoutSwitch]; // ungated by chromeVisible: the wrong layout strands the player either way
        [self updateReconnectOverlay];
        [self updateSessionExpiredOverlay]; // UX-LOGIN-01: same cadence/ungating as the reconnect scrim
        [self updateLoginScreenControls];
        [self updateFatalErrorOverlay];     // FATAL-1: latch-once fatal card, same cadence
        [self updateHoppingOverlay];        // PARITY-P0-3: world-hop scrim, same cadence/ungating
        [self stampFirstInWorld];           // Phase 4 cold start: once, then a no-op
    }

    // Keep the screen awake in game (~2 Hz is plenty; the idle timer runs in tens of seconds).
    if (self.framesShown % 30 == 0) {
        [self updateKeepAwake];
    }

    // W3 Feature-A (A2.5): refresh the crude native chat-at-top + HUD-status overlay from the HudDataBridge
    // snapshot (~10 Hz). Verifies the device data-flow before the full native chat veneer.
    if (self.framesShown % 6 == 0) {
        [self updateHudLayout];
        [self updateWorldMap];
        [self syncOrientationZoom];
        [self updateOverlayKeepOut];
    }

    // Drain the shared-core notification + outbound-link queues (~2 Hz). Both no-op until something is queued;
    // a fired plugin notification becomes a real OS notification, a plugin "open page" link opens in-app.
    if (self.framesShown % 30 == 0) {
        [self drainNotifications];
        [self drainLinks];
        [self drainScreenshots];   // SHOT-2: surface engine auto-screenshots to Photos (when enabled)
        [self refreshDevDiagnostics]; // developer-mode readout (~2 Hz; no-op while the panel is hidden)
    }

    // PERF-MEMORY-THERMAL-01: every second or two, on every renderer (see heatTick).
    if (self.framesShown % 120 == 0) {
        [self heatTick];
    }
    if (self.heatNotice && self.framesShown % 15 == 0)
        [self updateHeatNotice];

    // W3 A3: refresh the enlarged native chat tab buttons (~10 Hz). Self-gates on chrome toggle + layout; runs
    // every tick (not only when chromeVisible) so it hides itself promptly when the chrome is toggled off.
    if (self.framesShown % 6 == 0) {
        [self updateChatTabs];
    }

    // Plugin panel: while open, re-read the list when the bridge's event sequence advances (a toggle's
    // PluginChanged, or a conflict disabling another plugin) so enabled/active state stays truthful. Cheap:
    // a single long read + a string compare ~10 Hz, only while the modal is up.
    if (self.pluginPanelOpen && self.framesShown % 6 == 0) {
        long long seq = [JVMLauncher mobileUiSeq];
        if (seq != self.pluginSeq) {
            self.pluginSeq = seq;
            [self refreshPluginList];
        } else {
            // No event, but re-render so a pending plugin's "enabling…" flips to "couldn't start" once the
            // time-based grace elapses (the native-lib start failure is async and may emit no event).
            [self.pluginTable reloadData];
        }
    }

    // Contextual keyboard: when the gamepack opens a text field (search / PM / enter-amount), raise the
    // soft keyboard automatically; dismiss it when the field closes. Edge-triggered (only on a change) so
    // it never fights a keyboard the user opened manually for chat. Polled ~10 Hz to keep it cheap. Gated off
    // while a plugin-panel text field owns the keyboard, so a game textInputOpen flip can't steal it (PANEL-1).
    if (self.framesShown % 6 == 0 && ![self.panelDock panelKeyboardActive]) {
        int kind = [JVMLauncher textInputKind];
        BOOL wants = kind != 0;
        // Amount prompts get the number pad; everything else (and the manual chat keyboard) the text keyboard.
        // Set before the raise below so a new prompt opens on the right keyboard; a closing prompt drops the
        // keyboard below, so only swap a live one while a field is still open.
        UIKeyboardType type = kind == 2 ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable;
        if (self.kbField.keyboardType != type) {
            self.kbField.keyboardType = type;
            if (wants && [self.kbField isFirstResponder])
                [self.kbField reloadInputViews];
            [self appendLine:[NSString stringWithFormat:@"[shell] keyboard -> %@", kind == 2 ? @"number pad" : @"text"]];
        }
        if (wants != self.prevInputOpen) {
            self.prevInputOpen = wants;
            if (wants && ![self.kbField isFirstResponder]) {
                self.kbField.text = kKbSentinel;
                [self.kbField becomeFirstResponder];
                [self appendLine:@"[shell] game opened a text field -> keyboard up"];
            } else if (!wants && [self.kbField isFirstResponder]) {
                [self.kbField resignFirstResponder];
                [self appendLine:@"[shell] game closed the text field -> keyboard down"];
            }
        }
    }


    // #8: native big-row menu — once the long-press right-click lands in the MenuPeekBridge snapshot (a frame
    // or two later), build the OSRS-styled overlay over the engine's tiny menu. Times out to the engine-menu
    // clamp fallback if the snapshot never arrives.
    if (self.menuOpen && self.menuBuilding && self.menuContainer == nil) {
        if ([self tryBuildNativeMenu]) {
            self.menuBuilding = NO;
        } else if (CACurrentMediaTime() - self.menuOpenAt > 0.6) {
            self.menuBuilding = NO;   // give up; the engine menu + clamp path (updateMenuHighlight) still works
            // Fallback degrades to drag-selecting on the ENGINE menu — un-gate its raster (suppressed by
            // default; the user can't drag-select an invisible menu). Re-suppressed in teardownMenuViews.
            [JVMLauncher setEngineMenuRenderSuppressed:NO];
            NSString *snap = [JVMLauncher menuPeekSnapshot];
            [self appendLine:[NSString stringWithFormat:@"[menu-diag] build TIMEOUT @game %d,%d snap=%@",
                              self.lastMenuX, self.lastMenuY,
                              snap.length ? [snap substringToIndex:MIN((NSUInteger)200, snap.length)] : @"(empty)"]];
        }
    }

    // #8 close: after a commit/cancel, hold the native cover up until the engine menu has actually closed (the
    // snapshot's menuOpen flips false), so the briefly-still-open engine menu never peeks out from under it.
    // Timeout at 0.3s in case the snapshot lags, so the cover can't get stuck.
    if (self.menuClosing) {
        BOOL engineClosed = NO;
        NSString *snap = [JVMLauncher menuPeekSnapshot];
        if (snap.length) {
            NSDictionary *d = parseBridgeJSON(snap, "ViewController.onDisplayTick");
            if ([d isKindOfClass:[NSDictionary class]] && ![d[@"menuOpen"] boolValue]) engineClosed = YES;
        }
        if (engineClosed || CACurrentMediaTime() - self.menuClosingAt > 0.3) {
            [self teardownMenuViews];
        }
    }

    // Interactable-tap feedback: when a tap's CONSUMED click (MenuOptionClicked truth) was a real interaction
    // the bridge bumps the counter — give a light buzz (the "you grabbed something" feel) and draw a RED click
    // ring. A plain walk doesn't bump, so after a grace window we draw a YELLOW ring instead (and stay silent).
    // Matches the official app. The grace covers the engine-resolved tap pipeline: settle gate (a few frames)
    // + click consume next tick + poll latency ≈ 80-160 ms, so 0.25 s keeps walk rings prompt without
    // misclassifying slow interactions as walks.
    int its = [JVMLauncher interactTapSeq];
    if (its != self.lastInteractTapSeq) {
        self.lastInteractTapSeq = its;
        [self haptic:RMHapticOp]; // fires on EVERY real interaction, widget or scene
        if (self.pendingClick) {
            // Read the resolved tap KIND now: interactTapSeq bumps LAST (after the kind is published), so seeing
            // the new seq guarantees lastTapKind is the matching kind. A WIDGET tap (inventory item, prayer/spell
            // icon, equipment slot, tab-stone) draws no red ring - the engine draws its own cyan outline there,
            // so the ring is redundant (parity with Android's TAP_KIND_WIDGET branch). SCENE taps still ring; an
            // older jar returns 0 (TAP_KIND_NONE != kTapKindWidget), preserving ring-on-every-interaction.
            if ([JVMLauncher lastTapKind] == kTapKindWidget) {
                [self retirePendingRing]; // the engine cuffs the slot itself — take this tap's marker back
            } else if (![self promotePendingRingToInteract]) {
                [self flashClickRingAt:self.pendingClickPoint color:RMInteractRingColor()];
            }
            self.pendingClick = NO; // a widget tap still resolves the pending state, it just draws no ring
        }
    }
    if (self.pendingClick && CACurrentMediaTime() - self.pendingClickAt > 0.25) {
        // Nothing bumped: a plain walk, which is the colour the marker already has — so there is nothing to
        // draw unless this tap's ring is gone (it outlived the grace, or a later tap took the slot). Ends the
        // pending state either way, which also stops a late interact answer repainting a walk ring.
        if (!self.pendingRing) {
            [self flashClickRingAt:self.pendingClickPoint color:RMWalkRingColor()];
        }
        self.pendingRing = nil;
        self.pendingClick = NO;
    }
}

#pragma mark - Picture-in-Picture + background keepalive

// The background story, in one place. iOS suspends a backgrounded app within seconds — the JVM freezes,
// the game socket dies, the character is dumped at the login screen. Two cooperating mechanisms keep the
// session alive instead:
//   1. KEEPALIVE — the `audio` background mode (Info.plist) + a silent AVAudioEngine on a mixable playback
//      session. While the engine renders (silence), iOS never suspends the process: the JVM keeps ticking,
//      the connection stays up, and RuneLite's own logout timer (configurable up to 30 min) is what ends
//      the session, exactly like leaving the desktop client unattended.
//   2. PiP — an AVSampleBufferDisplayLayer fed the same engine frames as the on-screen blit. With
//      canStartPictureInPictureAutomaticallyFromInline the system pops it into a floating window on
//      swipe-home, so the game stays VISIBLE while backgrounded. Dismissing the PiP window does not end
//      the session (keepalive holds); reopening the app restores the full UI.
// Foreground feeding rides onDisplayTick; in background the display link stops, so a 15 Hz main-queue
// timer takes over (main-queue so the reverse-JNI calls stay on the thread the bridge env is bound to).

// Silent keepalive audio: a source node renders zeros into a muted mixer. MixWithOthers keeps it polite —
// it neither ducks nor pauses whatever the user is listening to, and (unlike music apps) it keeps playing
// when other audio starts. AVAudioEngine wiring throws ObjC exceptions on failure, so the whole setup is
// fenced; on failure the app just keeps today's suspend-on-background behaviour.
- (void)setupBackgroundKeepalive {
    if (self.keepaliveEngine) return;
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err]) {
        [self appendLine:[NSString stringWithFormat:@"[pip] audio session category FAILED: %@", err.localizedDescription]];
        return;
    }
    if (![session setActive:YES error:&err]) {
        [self appendLine:[NSString stringWithFormat:@"[pip] audio session activate FAILED: %@", err.localizedDescription]];
        return;
    }
    @try {
        AVAudioEngine *eng = [[AVAudioEngine alloc] init];
        AVAudioFormat *fmt = [eng.outputNode inputFormatForBus:0];
        AVAudioSourceNode *src = [[AVAudioSourceNode alloc] initWithFormat:fmt
            renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *ts,
                                  AVAudioFrameCount frameCount, AudioBufferList *outputData) {
                for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
                    if (outputData->mBuffers[i].mData) {
                        memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
                    }
                }
                return noErr;
            }];
        [eng attachNode:src];
        [eng connect:src to:eng.mainMixerNode format:fmt];
        eng.mainMixerNode.outputVolume = 0.0;
        self.keepaliveEngine = eng;
        self.keepaliveSource = src;
    } @catch (NSException *ex) {
        self.keepaliveEngine = nil;
        self.keepaliveSource = nil;
        [self appendLine:[NSString stringWithFormat:@"[pip] keepalive engine wiring FAILED: %@", ex.reason]];
        return;
    }
    // A phone call (or Siri) interrupts the session and stops the engine — restart when it ends, or the
    // next background would suspend the JVM mid-session.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAudioInterruption:)
                                                 name:AVAudioSessionInterruptionNotification object:session];
    // A ROUTE CHANGE also stops a running engine - the re-arm on backgrounding already said so in
    // its own comment, but that re-arm can only help on the NEXT background trip, and a route
    // change while already backgrounded (AirPods disconnecting, a car stereo dropping, headphones
    // unplugged) never gets one. Nothing restarted the engine in that window, and a stopped engine
    // means the `audio` background mode is justifying nothing and iOS suspends the process.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAudioRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:session];
    // mediaserverd restarting leaves the session AND the engine as dead objects, so no amount of
    // starting recovers them: Apple documents a full teardown and rebuild. Unhandled, the keepalive
    // is gone for the remaining life of the process and residency goes with it.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onMediaServicesReset:)
                                                 name:AVAudioSessionMediaServicesWereResetNotification
                                               object:session];
    [self startKeepaliveEngine];
    // The backstop for causes not enumerated above. Every specific handler exists because a known
    // event stops the engine; this catches the ones nobody has thought of yet, which matters
    // because the symptom of all of them is identical and invisible -- a process that quietly
    // stops being resident. Cheap: one BOOL check per tick.
    [self.keepaliveWatchdog invalidate];
    __weak typeof(self) wsKeep = self; // self retains the timer, so the block must not retain self
    self.keepaliveWatchdog = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                             repeats:YES
                                                               block:^(NSTimer *t) {
                                                                   [wsKeep keepaliveWatchdogTick];
                                                               }];
    [self appendLine:@"[pip] keepalive audio armed (silent, mixable — blocks background suspension)"];
}

// Shared by the route-change handler and the watchdog: restart the engine unless the idle gate
// stopped it deliberately, and count it so the next launch can say the session was flaky.
// `reason` is the prose for the log line; `tag` is the short, stable word the residency record
// counts by. Two arguments rather than one derived from the other, because the log sentence is
// free to be reworded and the tag is data.
- (void)rearmKeepaliveBecause:(NSString *)reason tagged:(NSString *)tag {
    if (self.keepaliveIdleReleased)
        return; // stopped on purpose - leave it stopped
    if (!self.keepaliveEngine) {
        // REBUILD, don't just start. A media services reset nils the engine and removes all three
        // observers, and when the idle gate was in force at that moment it skipped the rebuild --
        // so without this the keepalive is dead for the rest of the process: startKeepaliveEngine
        // no-ops on a nil engine, the notifications that would have recovered it are unsubscribed,
        // and nothing else ever calls setupBackgroundKeepalive again. The watchdog is the only
        // thing still ticking, which makes this the one place the rebuild can come from.
        //
        // Cannot double-add the observers: setupBackgroundKeepalive only adds them on the path
        // where it successfully assigns the engine, so a nil engine means they are not subscribed.
        [self setupBackgroundKeepalive];
        if (self.keepaliveEngine.isRunning) {
            [RMResidency noteKeepaliveRearmed:tag];
            [self appendLine:[NSString
                                 stringWithFormat:@"[pip] keepalive had been torn down (%@) - rebuilt",
                                                  reason]];
        }
        return;
    }
    if (self.keepaliveEngine.isRunning)
        return;
    [self startKeepaliveEngine];
    if (self.keepaliveEngine.isRunning) {
        [RMResidency noteKeepaliveRearmed:tag];
        [self appendLine:[NSString stringWithFormat:@"[pip] keepalive was stopped by %@ - restarted",
                                                    reason]];
    }
}

- (void)keepaliveWatchdogTick {
    [self rearmKeepaliveBecause:@"something other than the idle gate" tagged:@"watchdog"];
}

// AVAudioSession posts its notifications on its own queue, not the main one, and the re-arm path
// ends in appendLine touching a UITextView. Hopping is not optional.
- (void)onAudioRouteChange:(NSNotification *)note {
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ws rearmKeepaliveBecause:@"a route change" tagged:@"route-change"];
    });
}

- (void)onMediaServicesReset:(NSNotification *)note {
    if (![NSThread isMainThread]) { // see onAudioRouteChange: - same queue, same reason
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws onMediaServicesReset:note];
        });
        return;
    }
    [self appendLine:@"[pip] media services were reset - rebuilding the keepalive from scratch"];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // Removed before the rebuild, because setupBackgroundKeepalive adds all three again and a
    // duplicate observer would make every later interruption fire the handler twice.
    for (NSString *n in @[
             AVAudioSessionInterruptionNotification, AVAudioSessionRouteChangeNotification,
             AVAudioSessionMediaServicesWereResetNotification
         ])
        [[NSNotificationCenter defaultCenter] removeObserver:self name:n object:session];
    self.keepaliveEngine = nil;
    self.keepaliveSource = nil;
    if (self.keepaliveIdleReleased)
        return; // the gate wants us suspendable; rebuilding would undo that
    [self setupBackgroundKeepalive];
    if (self.keepaliveEngine.isRunning)
        [RMResidency noteKeepaliveRearmed:@"media-reset"];
}

- (void)startKeepaliveEngine {
    if (!self.keepaliveEngine || self.keepaliveEngine.isRunning) return;
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    NSError *err = nil;
    if (![self.keepaliveEngine startAndReturnError:&err]) {
        [self appendLine:[NSString stringWithFormat:@"[pip] keepalive audio start FAILED: %@", err.localizedDescription]];
    }
}

- (void)onAudioInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeEnded)
        return;
    // Through the shared path rather than starting the engine directly, which fixes three things
    // this handler got wrong: it restarted the engine even when the idle gate had stopped it on
    // purpose, it touched the log off the main thread (AVAudioSession's queue), and it announced
    // "restarted" whether or not the start actually worked.
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [ws rearmKeepaliveBecause:@"an audio interruption" tagged:@"interruption"];
    });
}

// PiP scaffolding. The sample-buffer layer is the VISIBLE presenter: a sublayer of the game view at index 0,
// so it draws ABOVE the UIImageView's blitted image (same frames, fed in the same tick) and BELOW the native
// chrome buttons. It must be visibly playing inline for the system's auto-engage to fire — the first cut
// parked it occluded behind the opaque game view and auto-PiP never engaged on device. The UIImageView keeps
// blitting underneath as the zero-risk fallback: the layer is non-opaque, so if it ever goes to the failed
// state and renders nothing, the image simply shows through.
- (void)setupPictureInPicture {
    if (self.pipController) return;
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        [self appendLine:@"[pip] not supported on this device"];
        return;
    }
    [self.view layoutIfNeeded];
    AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
    layer.frame = self.screen.bounds;
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    CMTimebaseRef tb = NULL;
    if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &tb) == noErr && tb) {
        CMTimebaseSetTime(tb, CMClockGetTime(CMClockGetHostTimeClock()));
        CMTimebaseSetRate(tb, 1.0);
        layer.controlTimebase = tb;
        CFRelease(tb);
    }
    [self.screen.layer insertSublayer:layer atIndex:0];
    self.pipLayer = layer;
    [JVMLauncher pipFeedSetLayer:layer];

    AVPictureInPictureControllerContentSource *src = [[AVPictureInPictureControllerContentSource alloc]
        initWithSampleBufferDisplayLayer:layer playbackDelegate:self];
    AVPictureInPictureController *pc = [[AVPictureInPictureController alloc] initWithContentSource:src];
    pc.delegate = self;
    pc.canStartPictureInPictureAutomaticallyFromInline = YES;   // swipe-home -> the game pops into PiP
    // The auto-engage gate, observable: the system flips pictureInPicturePossible once every precondition
    // (supported + background mode + window-attached visible layer + frames flowing) is met. Logged so a
    // device run shows exactly which side of the gate we're on.
    [pc addObserver:self forKeyPath:@"pictureInPicturePossible"
            options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:kPipKvoContext];
    [pc addObserver:self forKeyPath:@"pictureInPictureActive"
            options:NSKeyValueObservingOptionNew context:kPipKvoContext];
    self.pipController = pc;
    // (The legacy pipButton stays hidden — PiP is driven by the pinned 📺 control now; onTogglePip's
    // `if (!self.pipController) return;` guard makes a pre-arm tap a harmless no-op.)
    [self appendLine:@"[pip] armed — backgrounding pops the game into Picture-in-Picture"];
}

- (void)teardownPictureInPicture {
    if (!self.pipController && !self.pipLayer) return;
    [self stopPipBgPump];
    [RouteCBridge setPipPresentEnabled:NO];   // belt: never enqueue onto a torn-down layer
    if (self.pipController) {
        @try {
            [self.pipController removeObserver:self forKeyPath:@"pictureInPicturePossible" context:kPipKvoContext];
            [self.pipController removeObserver:self forKeyPath:@"pictureInPictureActive" context:kPipKvoContext];
        } @catch (NSException *ex) { /* never registered — fine */ }
    }
    self.pipController = nil;
    [JVMLauncher pipFeedSetLayer:nil]; // a frame in flight on the feed thread is dropped, not enqueued
    [self.pipLayer removeFromSuperlayer];
    self.pipLayer = nil;
    self.pipButton.hidden = YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kPipKvoContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self appendLine:[NSString stringWithFormat:@"[pip] %@ -> %@", keyPath, change[NSKeyValueChangeNewKey]]];
}

// Manual PiP toggle (📺): starts the floating window without leaving the app; tapping again (or the PiP ✕)
// brings it back. Also the cheapest auto-start diagnostic — manual-works/auto-doesn't = the system's
// auto-engage gate, manual-fails = failedToStartPictureInPictureWithError says why.
- (void)onTogglePip {
    if (!self.pipController) return;
    if (self.pipController.isPictureInPictureActive) {
        [self.pipController stopPictureInPicture];
    } else {
        [self appendLine:[NSString stringWithFormat:@"[pip] manual start (possible=%d layerStatus=%ld fedSeq=%d)",
                                                    (int)self.pipController.isPictureInPicturePossible,
                                                    (long)self.pipLayer.sampleBufferRenderer.status, [JVMLauncher pipFeedSeq]]];
        [self.pipController startPictureInPicture];
    }
}

// Ask the PiP feed for the newest engine frame (no-op when nothing new composited); JVMLauncher enqueues it on the
// layer from its own thread. Also the background tick: the idle gate and the drains below ride it.
- (void)pipPumpFrame {
    // KEEPALIVE-1 idle gate (runs for EVERY renderer, before the frame-feed early-returns): sample the
    // session ~every 5 s; once the game has been continuously logged OUT for the threshold — an AFK-logout
    // rendering the login screen to nobody — stop the pump and the keepalive audio so iOS can suspend the
    // JVM instead of burning battery at full rate indefinitely. Skipped while PiP is visibly active (the
    // user is watching the window, logged in or not). Foregrounding re-arms everything; the cost of a
    // suspension is a possible jetsam → relaunch + StikDebug re-attach, accepted for a dead session.
    static const CFTimeInterval kBgIdleStopSeconds = 600.0;
    self.bgPumpTicks++;
    // The display tick that drives heatTick stops with the app, and a phone in a pocket can still get hot.
    if (self.appBackgrounded && self.bgPumpTicks % 75 == 0) {
        [self heatTick];
    }
    if (self.bgPumpTicks % 75 == 0 && !self.pipController.isPictureInPictureActive) {
        NSString *snap = [JVMLauncher chromeSnapshot];
        NSDictionary *d = snap.length ? parseBridgeJSON(snap, "ViewController.bgIdleGate") : nil;
        BOOL loggedIn = [d isKindOfClass:[NSDictionary class]] && [d[@"loggedIn"] boolValue];
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (loggedIn) {
            self.bgLoggedOutSince = 0;
        } else if (self.bgLoggedOutSince == 0) {
            self.bgLoggedOutSince = now;
        } else if (now - self.bgLoggedOutSince > kBgIdleStopSeconds) {
            [self appendLine:[NSString stringWithFormat:
                                           @"[pip] background idle gate: logged out %.0fs -> stopping keepalive (iOS may now suspend the JVM)",
                                           now - self.bgLoggedOutSince]];
            [self stopPipBgPump];
            [self.keepaliveEngine stop];
            // Mark it deliberate, for the recovery paths and for the next launch's verdict: a kill
            // after this point is the gate working, not residency failing.
            self.keepaliveIdleReleased = YES;
            [RMResidency noteIdleGateReleased];
            return;
        }
    }
    // NOTIF-BG-1 (PARITY-P0-5): this is the ONLY tick alive while backgrounded (the CADisplayLink path in
    // onDisplayTick stops firing per iOS once backgrounded) — drain notifications/links here too, at the same
    // ~2 Hz cadence as the foreground path (framesShown % 30 at ~60fps), reusing the counter already ticked
    // above. Runs even when gpuPresent or pipLayer is nil since notifications/links are independent of the
    // video-feed path (matches Android's rl-drain daemon, which loops regardless of foreground state).
    if (self.bgPumpTicks % 8 == 0) {
        [self drainNotifications];
        [self drainLinks];
    }
    if (!self.pipLayer) return;
    if (self.gpuPresent) return;   // 117HD pip-present: the GL bridge feeds the layer from the render thread
    [JVMLauncher pipFeedKick];     // the fetch, copy and enqueue run on the feed thread (JVMLauncher)
}

// Background frame pump: the CADisplayLink stops firing once backgrounded, so a plain 15 Hz main-queue
// timer kicks the PiP feed instead (main queue = the thread the reverse-JNI bridge env is bound to, which the
// idle gate and drains in pipPumpFrame still use; the run loop keeps servicing it because the keepalive audio
// blocks suspension).
- (void)startPipBgPump {
    if (self.pipBgPump || !self.pipController) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 15, NSEC_PER_SEC / 100);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{ [weakSelf pipPumpFrame]; });
    dispatch_resume(t);
    self.pipBgPump = t;
}

- (void)stopPipBgPump {
    if (!self.pipBgPump) return;
    dispatch_source_cancel(self.pipBgPump);
    self.pipBgPump = nil;
}

// --- AVPictureInPictureSampleBufferPlaybackDelegate: a live game has no pause/seek/duration ------------

- (void)pictureInPictureController:(AVPictureInPictureController *)pc setPlaying:(BOOL)playing {
    // Live feed — the PiP pause button is a no-op (matching a live broadcast).
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pc {
    // An infinite range renders the PiP window with live-content chrome (no scrubber).
    return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pc {
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pc didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
    // The engine keeps compositing at renderW x renderH; the PiP window scales it. Nothing to do.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pc skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler {
    completionHandler();   // live feed — nothing to skip through
}

- (BOOL)pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:(AVPictureInPictureController *)pc {
    return NO;   // the keepalive session must keep running under PiP
}

// --- AVPictureInPictureControllerDelegate ---------------------------------------------------------------

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pc {
    [self appendLine:@"[pip] started"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pc {
    [self appendLine:@"[pip] stopped"];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pc failedToStartPictureInPictureWithError:(NSError *)error {
    [self appendLine:[NSString stringWithFormat:@"[pip] failed to start: %@", error.localizedDescription]];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pc
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(YES);   // the game UI never left — nothing to restore
}

#pragma mark - Touch -> AWT bridge (Phase 5 control scheme)

// Map a point (in the screen image view's coordinate space) to gamepack-canvas pixels, honouring the
// ScaleAspectFit letterbox. Returns NO if the point is in the letterbox margin (outside the game frame).
- (BOOL)mapPoint:(CGPoint)p toGameX:(int *)gx toGameY:(int *)gy {
    UIImage *img = self.screen.image;
    CGFloat iw = img ? img.size.width : 0, ih = img ? img.size.height : 0;
    // GPU present: no UIImage
    if ((iw <= 0 || ih <= 0) && self.renderW > 0) {
        iw = self.renderW;
        ih = self.visibleH;
    }
    if (iw <= 0 || ih <= 0) return NO;
    CGRect b = self.screen.bounds;
    CGFloat scale = MIN(b.size.width / iw, b.size.height / ih);   // ScaleAspectFit
    CGFloat dispW = iw * scale, dispH = ih * scale;
    CGFloat ox = (b.size.width - dispW) * 0.5, oy = (b.size.height - dispH) * 0.5;
    CGFloat fx = (p.x - ox) / scale, fy = (p.y - oy) / scale;
    if (fx < 0 || fy < 0 || fx >= iw || fy >= ih) return NO;   // tapped the letterbox, not the game
    *gx = (int)fx;
    *gy = (int)fy;
    return YES;
}

// Keep the game-tap / long-press recognizers from firing when the touch lands on a native control over the game
// (the enlarged chat tab buttons, the keyboard button, the side-tab grid). The control handles its own tap, so it
// must not ALSO register as a walk-here click underneath. Touches on the bare game view (self.screen) pass through.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    // The native dialogue parchment owns its own taps (continue / option rows) — keep world/camera gestures off it.
    if (self.dialogueView && !self.dialogueView.hidden && [touch.view isDescendantOfView:self.dialogueView]) return NO;
    return ![touch.view isKindOfClass:[UIControl class]];
}

// tap -> left click (walk / interact / select a menu entry).
// Minimap-orb touch veneer: does the game-canvas point (gx,gy) fall within any published orb's rect enlarged
// by kOrbTapPad on each side? If several match, pick the one whose true centre is nearest the tap. Returns YES
// and the winning orb's centre via the out-params (plus its key via outKey), NO if no orb was hit. Mirrors
// Android MainActivity.nearestOrb(). Silent (returns NO) whenever the snapshot is nil/logged-out/malformed.
- (BOOL)nearestOrbAtGameX:(int)gx gameY:(int)gy outX:(int *)ocx outY:(int *)ocy outKey:(NSString **)outKey {
    NSString *snap = [JVMLauncher orbSnapshot];
    if (snap.length == 0)
        return NO;
    id parsed = parseBridgeJSON(snap, "ViewController.nearestOrb");
    if (![parsed isKindOfClass:[NSDictionary class]])
        return NO;
    NSDictionary *d = parsed;
    if (![d[@"loggedIn"] boolValue])
        return NO;
    BOOL found = NO;
    long bestDist = 0;
    for (NSString *key in kOrbKeys) {
        id sub = d[key];
        if (![sub isKindOfClass:[NSDictionary class]])
            continue; // a hidden orb isn't published
        int x = [sub[@"x"] intValue];
        int y = [sub[@"y"] intValue];
        int w = [sub[@"w"] intValue];
        int h = [sub[@"h"] intValue];
        if (gx < x - kOrbTapPad || gx > x + w + kOrbTapPad)
            continue;
        if (gy < y - kOrbTapPad || gy > y + h + kOrbTapPad)
            continue;
        int cx = x + w / 2;
        int cy = y + h / 2;
        long dist = (long)(gx - cx) * (gx - cx) + (long)(gy - cy) * (gy - cy);
        if (!found || dist < bestDist) {
            found = YES;
            bestDist = dist;
            if (ocx)
                *ocx = cx;
            if (ocy)
                *ocy = cy;
            if (outKey)
                *outKey = key;
        }
    }
    return found;
}

// The finger lifted and no recognizer had claimed the sequence. Was it a click? Everything the decision needs
// is here: how far the finger strayed from where it landed and how long it was down. Nothing else is consulted
// — by the time this runs, a drag has already begun rotating and a hold has already opened the menu, and
// either of those cancels the sequence so it never reaches here at all.
//
// The click goes to where the finger LANDED, not where it left: that is the point the user aimed at, it is the
// point the engine has been resolving since contact (armTap), and committing to it is what makes the click
// land on the lift instead of a few frames after it.
- (void)onSceneTouchUp:(CGPoint)origin strayed:(CGFloat)strayed held:(NSTimeInterval)held {
    if (strayed <= kSceneDragSlop && held <= [RMGameSettings longPressMs] / 1000.0 + kSceneTapHoldMargin) {
        [self worldTapAtScreenPoint:origin];
    }
    // Whatever that did, this touch is finished with its arm — and only the plain world click consumes one.
    // Cancelling here rather than at each of the router's dozen exits is both shorter and safer: it cannot be
    // missed when a branch is added. It reads as a no-op when the click DID happen, because both calls hop
    // through ClientThread.invoke and so run in this order: the commit has already moved the state to CLICKED,
    // or the lift has already handed the still-running gate its pending click, and cancelArmedTap touches
    // neither. Every other exit — a routed precise click (orb, map, chat, dialogue), a dialogue that appeared
    // mid-touch, a bridge that went away, a stray this method rejected — would otherwise leave an arm nobody
    // commits, and a live arm refuses to arm the NEXT touch, which is the one thing it exists to do.
    [JVMLauncher postCancelArmedTap];
}

// A confirmed tap at a point on the game canvas: route it (native dialogue, world map, orb, chat, engine
// dialogue) or click the world. The one entry point for a confirmed tap: onSceneTouchUp: is its only caller
// today, and anything that wants to synthesise a tap should come through here rather than past the routing.
- (void)worldTapAtScreenPoint:(CGPoint)sp {
    if (![JVMLauncher bridgeReady]) return;
    // The native dialogue parchment owns its own taps (continue / option rows). Re-gate here too (belt-and-
    // suspenders with the view hit-test) so a tap on it can never ALSO route as a world/precise click.
    if (self.dialogueView && !self.dialogueView.hidden && CGRectContainsPoint(self.dialogueView.frame, sp))
        return;
    CGPoint vp = [self.screen convertPoint:sp toView:self.view];
    int gx = 0, gy = 0;
    if (![self mapPoint:sp toGameX:&gx toGameY:&gy])
        return;
    // [dlg-diag] one line per tap so a single "tap Continue" repro reveals the failure: dlgAct = did the bridge
    // report a dialogue open; inScroll/inDlg = does the tap fall in the chatbox / published-dialogue rect.
    [self appendLine:[NSString stringWithFormat:@"[dlg-diag] g=%d,%d dlgAct=%d inScroll=%d inDlg=%d scroll=%@ dlg=%@",
        gx, gy, self.chatDialogueActive ? 1 : 0,
        (self.chatScrollCanvas.size.width > 0 && CGRectContainsPoint(self.chatScrollCanvas, CGPointMake(gx, gy))) ? 1 : 0,
        (self.dialogueChatCanvas.size.width > 0 && CGRectContainsPoint(self.dialogueChatCanvas, CGPointMake(gx, gy))) ? 1 : 0,
        NSStringFromCGRect(self.chatScrollCanvas), NSStringFromCGRect(self.dialogueChatCanvas)]];
    // World map open: a tap INSIDE the (centred) map window is a UI click (icons/keys/buttons) — precise,
    // no world-snap, no walk-ring semantics. A tap in the search rect ALSO raises the soft keyboard: the map
    // search doesn't flip INPUT_TYPE (Phase-0 probe), so the auto-raise never fires; typed keys go to the
    // canvas and the focused search field consumes them. Taps OUTSIDE the window fall through to the normal
    // world tap (walk/interact + ring), like the desktop.
    if (self.mapOpen && (self.mapWindowCanvas.size.width <= 0
            || CGRectContainsPoint(self.mapWindowCanvas, CGPointMake(gx, gy)))) {
        if (CGRectGetWidth(self.mapSearchCanvas) > 0
                && CGRectContainsPoint(self.mapSearchCanvas, CGPointMake(gx, gy))
                && ![self.kbField isFirstResponder]) {
            self.kbField.text = kKbSentinel;
            [self.kbField becomeFirstResponder];
            [self appendLine:@"[map] search tap -> keyboard up"];
        }
        [JVMLauncher postClickPreciseX:gx y:gy button:1];
        [self appendLine:[NSString stringWithFormat:@"[map] tap %d,%d (precise)", gx, gy]];
        return;
    }
    // Minimap-orb touch veneer (only when the map is closed — matches Android's ordering, and wins over the
    // general minimap/world click below): a tap within kOrbTapPad of an orb's sprite snaps to the orb's true
    // centre and fires a PRECISE click there (no world-snap, no walk-ring — an orb toggle doesn't walk).
    {
        int ocx = 0, ocy = 0;
        NSString *orbKey = nil;
        if ([self nearestOrbAtGameX:gx gameY:gy outX:&ocx outY:&ocy outKey:&orbKey]) {
            [JVMLauncher postClickPreciseX:ocx y:ocy button:1];
            [self haptic:RMHapticOp];
            [self appendLine:[NSString stringWithFormat:@"[shell] orb-veneer tap %d,%d -> %@ @(%d,%d)", gx, gy, orbKey, ocx, ocy]];
            return;
        }
    }
    // W3 A3: the relocated chat tab-row is UI, not the world. Send a PRECISE click straight to the engine (no
    // world-snap pulling it to a tile/entity) and DON'T draw the walk ring — taps there toggle a chat filter, they
    // don't walk. The rect moves with the safe-area relocate (chatHitCanvas, set in updateHudLayout).
    // A dialogue outranks this too. hideChatTabs hides the buttons and sets the engine tab row to height 0, but
    // leaves chatHitCanvas at the band applyChatRelocate gave it -- so while a dialogue is open this rect is a
    // live tap target over a strip that no longer holds tabs, and the dialogue is what is drawn there. It is the
    // TOP BAND of chatScrollCanvas (same origin and width), not a region beside it, so without this the dialogue
    // handler below never sees a tap in it: the raw click goes to the scene behind the parchment.
    CGRect ch = self.chatHitCanvas;
    if (!self.chatDialogueActive && ch.size.width > 0 && gx >= ch.origin.x && gx <= ch.origin.x + ch.size.width && gy >= ch.origin.y && gy <= ch.origin.y + ch.size.height) {
        [JVMLauncher postClickPreciseX:gx y:gy button:1];
        [self appendLine:[NSString stringWithFormat:@"[shell] chat-tab tap %d,%d (precise, no ring)", gx, gy]];
        return;
    }
    // CHAT-2: a tap on the OPEN chat MESSAGE area is chat UI (continue dialogue, click a player name / chat link),
    // not the world behind the transparent chat — so click it PRECISELY (no world-snap, no walk-ring), like the
    // tab row above. The tab row is already handled+returned above, so this only catches the message area below it.
    // ...but never while a dialogue owns that region. chatScrollable is cleared when a dialogue is detected, so
    // this block was only ever reached with no dialogue open -- an invariant held in ANOTHER function, one chrome
    // snapshot away. Until that snapshot lands (or if it never does) a stale YES sends the tap to the precise
    // click below, which is the exact walk-the-player behaviour the dialogue block exists to prevent, and it
    // returns before that block can run. State the precedence here instead of depending on the ordering.
    if (self.chatScrollable && !self.chatDialogueActive && self.chatScrollCanvas.size.width > 0 && CGRectContainsPoint(self.chatScrollCanvas, CGPointMake(gx, gy))) {
        [JVMLauncher postClickPreciseX:gx y:gy button:1];
        [self appendLine:[NSString stringWithFormat:@"[shell] chat-msg tap %d,%d (precise, no ring)", gx, gy]];
        return;
    }
    // Dialogue open: the dialogue (NPC/options/level-up/continue) shows on the chatbox at the top. ANY tap over the
    // chatbox region must NOT fall through to the world underneath — route it to a PRECISE click (so the engine
    // resolves the dialogue's Continue/option) and CONSUME it (return) even if it hits nothing. Independent of
    // chatScrollable (which is off during a dialogue). Uses the chatbox rect (always valid) + the published
    // dialogue rect as a union, so the whole visible dialogue is covered.
    if (self.chatDialogueActive) {
        CGPoint cp = CGPointMake(gx, gy);
        if ((self.chatScrollCanvas.size.width > 0 && CGRectContainsPoint(self.chatScrollCanvas, cp))
                || (self.dialogueChatCanvas.size.width > 0 && CGRectContainsPoint(self.dialogueChatCanvas, cp))) {
            // Only the CONTINUE widget and the option rows are clickable -- the rest of the box is inert, and a
            // click on inert parchment resolves against the SCENE behind it, so the tap walked the player to the
            // tile under the dialogue (and walking away then closed it, which read as "the tap did nothing").
            // Click the engine's live widget at the canvas bounds the bridge publishes for it instead.
            // Drive a dialogue through the engine's own continue handler -- not a click, and not a key.
            //
            // Not a click: the engine resolves one against whatever IT believes is under that canvas point, and
            // for the relocated chatbox that is the SCENE, so the tap walked the player to the tile behind the
            // box and ended the conversation by walking away. The published bounds say where the box is DRAWN;
            // the continue component reads hidden, so there was never anything there to hit.
            //
            // Not a key either, though that took measuring: keys do now reach the gamepack's canvas listener
            // and come back consumed, yet space and the option digits leave a dialogue untouched -- device-
            // confirmed, with the continue working through the handler in the same session.
            //
            // Both halves of the engine's dispatch rule are in play below. A continue is a static component, so
            // param0 is -1. An option row is a dynamic child, so it is addressed by its index instead.
            for (NSUInteger i = 0; i < self.dialogueOptionRects.count; i++) {
                if (!CGRectContainsPoint([self.dialogueOptionRects[i] CGRectValue], cp))
                    continue;
                if (self.dialogueIsPrompt) {
                    // Same reason as the panel's buttons: a search row answers to its own op, not to a digit.
                    CGRect rr = [self.dialogueOptionRects[i] CGRectValue];
                    [JVMLauncher tapEngineDialogueAtX:(int)CGRectGetMidX(rr) y:(int)CGRectGetMidY(rr)];
                    [self appendLine:[NSString stringWithFormat:@"[shell] prompt row %lu tap %d,%d (op)",
                                                                (unsigned long)i, gx, gy]];
                    return;
                }
                NSNumber *digit = self.dialogueOptionDigits[i];
                [JVMLauncher selectEngineDialogueOption:digit.intValue seq:self.dialogueTargetsSeq];
                [self appendLine:[NSString stringWithFormat:@"[shell] dialogue option %@ tap %d,%d (op)",
                                                            digit, gx, gy]];
                return;
            }
            // An options menu needs a row, not a blind advance: consume a miss rather than picking for the user.
            // A continue cannot stand in here either -- it advances, it does not choose -- so a tap that matched
            // no row ends here whether or not the row bounds were published.
            if (self.dialogueIsOptions) {
                [self appendLine:[NSString stringWithFormat:@"[shell] dialogue tap %d,%d (options, no row)", gx, gy]];
                return;
            }
            if (self.dialogueTargetsKnown) {
                // Modelled dialogue (chat / message / level-up): continue it, and consume the tap whether or not
                // a CONTINUE widget was published -- the bridge resolves the live target itself and does nothing
                // when no dialogue is open. Never fall through to a click here.
                [JVMLauncher continueEngineDialogue];
                [self appendLine:[NSString stringWithFormat:@"[shell] dialogue continue tap %d,%d (continue)", gx, gy]];
                return;
            }
            // Unmodelled (a quest's own Yes/No, make-X, a reward box): no CONTINUE and no option rows to fire,
            // because the buttons are that box's OWN components. A raw click here is not the answer either --
            // it reads as engine-owned, but the engine resolves a click over the relocated chatbox against the
            // SCENE behind it, so the tap walked the player past the box instead of pressing anything (the same
            // dead end the modelled continue hit, and what "I cannot tap Yes / No" actually was). Hand the POINT
            // to the bridge: it matches the box's live widgets on the client thread and fires the op of the one
            // under the finger, the same menu-action path every other relocated control here uses.
            [JVMLauncher tapEngineDialogueAtX:gx y:gy];
            [self appendLine:[NSString stringWithFormat:@"[shell] dialogue tap %d,%d (engine-owned, op)", gx, gy]];
            return;
        }
    }
    // Mark the click NOW, in the walk colour — this is the one place that knows the tap is a world click
    // rather than one of the routed paths above, and the user is owed the marker on the lift, not whenever the
    // engine gets back to us. Hold the pending state so onDisplayTick can carry the resolved kind to the ring
    // already on screen: red if the engine says the tap hit an interactable, retired if it says WIDGET, left
    // exactly as drawn when nothing bumps within the grace window.
    // Pump the haptic generator so the buzz is low-latency if it turns out to be an interact.
    self.pendingClick = YES;
    self.pendingClickPoint = vp;
    self.pendingClickAt = CACurrentMediaTime();
    // A second tap inside that window takes the slot; the ring it replaces finishes its fade in the walk
    // colour, which is what it already shows.
    self.pendingRing = [self flashClickRingAt:vp color:RMWalkRingColor()];
    [[self hapticGenerator] prepare];
    [JVMLauncher postClickX:gx y:gy button:1];
    [self appendLine:[NSString stringWithFormat:@"[shell] tap -> click(L) game %d,%d", gx, gy]];
}

// Finger down on the game canvas. Nothing is drawn and nothing is clicked here — a touch is not yet a tap —
// but this is where the ENGINE's half of the wait can be spent, and it is most of why clicks felt delayed. A
// left tap is never re-hit-tested, so the bridge has to move the synthetic cursor to the point, wait until the
// engine demonstrably resolved it, and only then press; done after the lift, those frames are dead time the
// user is watching. armTap runs that gate now, while the finger is still on the glass, so the lift can post
// the click on the spot (commitArmedTap). It presses nothing: a touch that turns into a camera drag or a hold
// has still done nothing to the world, and each of those paths drops the arm.
- (void)onSceneTouchDown:(CGPoint)p {
    if (![JVMLauncher bridgeReady])
        return;
    int gx = 0, gy = 0;
    if (![self mapPoint:p toGameX:&gx toGameY:&gy])
        return; // letterbox
    if (![self isPlainWorldTapAtGameX:gx gameY:gy screenPoint:p])
        return;
    [[self hapticGenerator] prepare];
    [JVMLauncher postArmTapX:gx y:gy];
}

// The finger moved while still on the canvas. A tap is not one point -- it lands, rolls a few pixels and
// lifts -- and every one of those samples used to be dropped, so the engine saw a single move at contact and
// nothing more until the release. Hand them over; the bridge replays them as drags of the press it is holding
// and ignores them entirely when there is no such press (a camera drag, a hold, a touch over an interface),
// so there is nothing to classify here. No mapPoint: failure log: this runs at touch-sample rate.
- (void)onSceneTouchMoved:(CGPoint)p {
    if (![JVMLauncher bridgeReady])
        return;
    int gx = 0, gy = 0;
    if (![self mapPoint:p toGameX:&gx toGameY:&gy])
        return; // letterbox
    [JVMLauncher postTapMoveX:gx y:gy];
}

// Would a tap at this point take the plain world-click path — the only path that draws a click marker? Mirrors
// worldTapAtScreenPoint:'s early returns (the dialogue parchment, the open world map, the minimap orbs, the
// chat tab row, the chat message area, an open dialogue's box), all of which route through the precise click
// and ring nothing. Worth keeping in lockstep with those returns, but nothing depends on it being exact: this
// only decides whether to ARM, so a mismatch costs an arm nobody commits (dropped at the lift) or a fast path
// not taken. The marker and the click are decided later, by the routing itself.
- (BOOL)isPlainWorldTapAtGameX:(int)gx gameY:(int)gy screenPoint:(CGPoint)p {
    if (self.dialogueView && !self.dialogueView.hidden && CGRectContainsPoint(self.dialogueView.frame, p))
        return NO;
    CGPoint cp = CGPointMake(gx, gy);
    if (self.mapOpen && (self.mapWindowCanvas.size.width <= 0 || CGRectContainsPoint(self.mapWindowCanvas, cp)))
        return NO;
    int ocx = 0, ocy = 0;
    NSString *orbKey = nil;
    if ([self nearestOrbAtGameX:gx gameY:gy outX:&ocx outY:&ocy outKey:&orbKey])
        return NO;
    CGRect ch = self.chatHitCanvas;
    if (!self.chatDialogueActive && ch.size.width > 0 && gx >= ch.origin.x && gx <= ch.origin.x + ch.size.width && gy >= ch.origin.y && gy <= ch.origin.y + ch.size.height)
        return NO;
    if (self.chatScrollCanvas.size.width > 0 && CGRectContainsPoint(self.chatScrollCanvas, cp) && (self.chatScrollable || self.chatDialogueActive))
        return NO;
    if (self.chatDialogueActive && self.dialogueChatCanvas.size.width > 0 && CGRectContainsPoint(self.dialogueChatCanvas, cp))
        return NO;
    return YES;
}

// The engine answered WIDGET: it draws its own cuff on the slot, so that tap gets no ring after all (parity
// with Android's TAP_KIND_WIDGET branch).
- (void)retirePendingRing {
    CAShapeLayer *ring = self.pendingRing;
    self.pendingRing = nil;
    [self retireRing:ring];
}

// Freeze the size the ring had reached and fade what is left of it out quickly, rather than dropping the layer
// outright: it is mid-animation, and a hard removal reads as a flicker.
- (void)retireRing:(CAShapeLayer *)ring {
    if (!ring)
        return;
    CALayer *shown = (CALayer *)ring.presentationLayer;
    float opacity = shown ? shown.opacity : 1.0f;
    CATransform3D size = shown ? shown.transform : CATransform3DIdentity;
    [ring removeAllAnimations]; // the group also owned the scale, so restate both model values
    ring.transform = size;
    ring.opacity = opacity;
    CABasicAnimation *out = [CABasicAnimation animationWithKeyPath:@"opacity"];
    out.fromValue = @(opacity);
    out.toValue = @0.0;
    out.duration = 0.12;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [ring removeFromSuperlayer];
    }];
    ring.opacity = 0.0; // end state (the animation drives the visible fade)
    [ring addAnimation:out forKey:@"clickRingOut"];
    [CATransaction commit];
}

// The engine resolved the tap as a real interaction: the marker drawn at the lift is the right ring in the
// wrong colour, so repaint it in place — actions off, because an implicit cross-fade would smear the red over
// what is left of the ring's life. NO when that tap has no ring alive, i.e. the caller should draw one.
- (BOOL)promotePendingRingToInteract {
    CAShapeLayer *ring = self.pendingRing;
    if (!ring)
        return NO;
    self.pendingRing = nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ring.strokeColor = RMInteractRingColor().CGColor;
    [CATransaction commit];
    return YES;
}

// Draw the official-style click marker: a ring (red = interactable, yellow = walk) that expands and fades out
// over ~0.45s at the tap point, then removes itself. Pure native (CAShapeLayer) — no game involvement.
// Returns the layer, so the ring can still be repainted or retired while it is alive.
- (CAShapeLayer *)flashClickRingAt:(CGPoint)p color:(UIColor *)color {
    const CGFloat r0 = 9.0;   // starting radius
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = CGRectMake(p.x - r0, p.y - r0, r0 * 2, r0 * 2);
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, r0 * 2, r0 * 2)].CGPath;
    ring.fillColor = [UIColor clearColor].CGColor;
    ring.strokeColor = color.CGColor;
    ring.lineWidth = 2.5;
    [self.view.layer addSublayer:ring];

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @0.5; scale.toValue = @2.2;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0; fade.toValue = @0.0;
    CAAnimationGroup *grp = [CAAnimationGroup animation];
    grp.animations = @[scale, fade];
    grp.duration = 0.45;
    grp.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    grp.removedOnCompletion = YES;
    [CATransaction begin];
    __weak ViewController *weakSelf = self;
    [CATransaction setCompletionBlock:^{
        [ring removeFromSuperlayer];
        if (weakSelf.pendingRing == ring)
            weakSelf.pendingRing = nil; // never offer a dead layer the late answer
    }];
    [ring addAnimation:grp forKey:@"clickRing"];
    ring.opacity = 0.0;   // end state (the animation drives the visible fade)
    [CATransaction commit];
    return ring;
}

// The long-press time from Settings > Game settings, on the game view's hold and the chat tabs' holds.
- (void)applyLongPressTime {
    CFTimeInterval t = [RMGameSettings longPressMs] / 1000.0;
    self.sceneLongPress.minimumPressDuration = t;
    for (UIButton *b in self.chatTabButtons) {
        for (UIGestureRecognizer *g in b.gestureRecognizers) {
            if ([g isKindOfClass:[UILongPressGestureRecognizer class]])
                ((UILongPressGestureRecognizer *)g).minimumPressDuration = t;
        }
    }
}

// The one impact generator every haptic trigger shares, rebuilt when the strength setting changes.
- (UIImpactFeedbackGenerator *)hapticGenerator {
    NSInteger s = [RMGameSettings hapticStrength];
    if (!self.tapHaptic || self.tapHapticStrength != s) {
        static const UIImpactFeedbackStyle styles[3] = {UIImpactFeedbackStyleLight, UIImpactFeedbackStyleMedium,
                                                        UIImpactFeedbackStyleHeavy};
        self.tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:styles[s]];
        self.tapHapticStrength = s;
    }
    return self.tapHaptic;
}

// One buzz for a trigger, if the player has it on (Settings > Game settings), at the chosen strength.
- (void)haptic:(RMHaptic)h {
    if (![RMGameSettings hapticOn:h])
        return;
    UIImpactFeedbackGenerator *g = [self hapticGenerator];
    [g impactOccurred];
    [g prepare];
}

// long-press -> hold-drag-release native menu (the OSRS-mobile feel). One continuous gesture:
//   .began   -> right-click at the press point to open the engine menu; record the press point + which hand
//               (left/right half of the screen) so the native overlay opens to the side away from the hand.
//   .changed -> as the finger slides, lock the highlight onto the row under it (a light haptic tick each time
//               it moves to a new option).
//   .ended   -> release commits the locked-on row via click-through; releasing off the rows cancels.
// The native rows are non-interactive labels — selection is driven entirely by this drag, so there is no
// race with the rows' own touch handling. The overlay is built a frame or two after .began (it waits for the
// engine menu to land in the MenuPeekBridge snapshot), so updateMenuHighlight no-ops until it exists.
// Open the engine right-click menu at game (gx,gy) and arm the native big-row overlay anchored at the finger
// (loc, view coords). Shared by the world long-press (onLongPress) and the chat-tab long-press (filter menu).
- (void)openEngineMenuAtGameX:(int)gx gameY:(int)gy anchor:(CGPoint)loc {
    if (self.menuOpen || self.menuClosing) [self teardownMenuViews];   // re-press: drop a stale/closing menu, open fresh
    self.lastMenuX = gx; self.lastMenuY = gy;
    self.menuAnchor = loc;
    [JVMLauncher postClickX:gx y:gy button:3];      // open the engine's OWN right-click menu at the target
    self.menuOpen = YES;
    self.menuOpenAt = CACurrentMediaTime();
    self.menuGeomValid = NO;                        // no live rect yet; refreshed once the engine builds the menu
    self.menuFingerOnMenu = YES;                    // release-without-moving picks the row at the press point
    self.menuSelX = gx; self.menuSelY = gy;
    self.lastMenuX = gx; self.lastMenuY = gy;
    self.menuBuilding = YES;                         // #8: poll the snapshot in onDisplayTick, then build native rows
    self.menuHighlight = -1;
    self.menuTapMode = NO;                            // re-decided (drag vs tap) when the snapshot builds the rows
    self.menuDrillParent = -1;
    self.customizeReopenPending = NO;                 // any fresh menu cancels a pending ⚙ Customize reopen
    CGPoint locInView = [self.screen convertPoint:loc toView:self.view];    // differs only over the stretched map
    self.menuHandRight = (locInView.x > self.view.bounds.size.width * 0.5); // pressed on the right -> open leftward
    self.menuHapticY = loc.y;
    [[self hapticGenerator] prepare];
}

#pragma mark - #8 Native big-row menu (over the engine menu; commits via the engine row)

// Poll the MenuPeekBridge snapshot; once the engine menu exists, capture its game-space rect + entries and
// build the native overlay. Returns YES when built (caller clears menuBuilding).
- (BOOL)tryBuildNativeMenu {
    NSString *snap = [JVMLauncher menuPeekSnapshot];
    if (snap.length == 0) return NO;
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.tryBuildNativeMenu");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"menuOpen"] boolValue]) return NO;
    NSArray *entries = d[@"entries"];
    if (![entries isKindOfClass:[NSArray class]] || entries.count == 0) return NO;
    int mw = [d[@"menuW"] intValue], mh = [d[@"menuH"] intValue];
    if (mw <= 0 || mh <= 0) return NO;
    self.menuGeomGame = CGRectMake([d[@"menuX"] intValue], [d[@"menuY"] intValue], mw, mh);
    self.menuGeomValid = YES;
    self.menuScrollable = [d[@"menuScrollable"] boolValue];   // engine self-scrolls -> flat-row commit by invoke
    [self buildNativeMenuWithEntries:entries];
    return YES;
}

// Decide how to present the engine menu the snapshot just delivered. A flat, short menu keeps the original
// drag-select box (drive selection by sliding the long-press finger — unchanged core path). A menu that carries
// a submenu (▸, e.g. Menu-Entry-Swapper "Swap left-click ▸" under a latched Shift), overflows the safe area, or
// arrives while Shift is latched becomes the persistent tap-mode list (MENU-1 drill-in / MENU-2 scroll / MENU-3
// ⚙ Customize) — those cases the drag-select box can't serve.
- (void)buildNativeMenuWithEntries:(NSArray *)entries {
    self.menuTopEntries = entries;
    self.menuDrillParent = -1;

    BOOL hasSub = NO;
    for (id obj in entries) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id sub = ((NSDictionary *)obj)[@"sub"];
            if ([sub isKindOfClass:[NSArray class]] && [sub count] > 0) { hasSub = YES; break; }
        }
    }
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat availH = self.view.bounds.size.height - ins.top - ins.bottom - 24.0;
    CGFloat fullH  = kMenuHeaderViewH + entries.count * kMenuRowViewH;
    BOOL tooTall = fullH > availH;

    if (hasSub || tooTall || self.shiftHeld) {
        self.menuTapMode = YES;
        [self buildTapMenuWithEntries:entries drilledParent:-1];
    } else {
        self.menuTapMode = NO;
        [self buildDragMenuWithEntries:entries];
    }
}

// The live engine menu rect in self.view coords, where the native box is placed. viewRectForGameX answers in the
// game view's own untransformed space, which differs from self.view only while the open world map stretches the
// game view (applyMapZoom); unconverted, a menu held open on the map would open away from the finger.
- (CGRect)engineMenuRectInView {
    CGRect er = [self viewRectForGameX:(int)CGRectGetMinX(self.menuGeomGame)
                                     y:(int)CGRectGetMinY(self.menuGeomGame)
                                     w:(int)CGRectGetWidth(self.menuGeomGame)
                                     h:(int)CGRectGetHeight(self.menuGeomGame)];
    if (CGRectIsEmpty(er))
        return er;
    return [self.screen convertRect:er toView:self.view];
}

// Build the opaque OSRS-styled native menu: a "Choose Option" header + one 32pt row per entry (display order,
// index 0 = top = left-click default). The box is sized + positioned to fully COVER the engine's own tiny
// rendered menu so there's no double-menu. Selection is driven by the long-press drag (rows are inert).
- (void)buildDragMenuWithEntries:(NSArray *)entries {
    [self.menuContainer removeFromSuperview];
    self.menuRowEntries = entries;
    NSInteger count = entries.count;

    // The engine menu rect in view coords — what we must cover.
    CGRect er = [self engineMenuRectInView];

    CGFloat boxW = MAX(kMenuWidth, CGRectGetWidth(er) + 16.0);
    CGFloat boxH = kMenuHeaderViewH + count * kMenuRowViewH;

    // Anchor over the engine rect; hand-bias the box away from the pressing thumb, then clamp into the safe area.
    CGFloat ox = CGRectGetMinX(er) - 8.0;
    if (self.menuHandRight) ox = CGRectGetMaxX(er) + 8.0 - boxW;   // right thumb -> open leftward
    CGFloat oy = CGRectGetMinY(er) - 4.0;
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat minX = ins.left + 6.0;
    CGFloat maxX = self.view.bounds.size.width - ins.right - 6.0 - boxW;
    CGFloat minY = ins.top + 6.0;
    CGFloat maxY = self.view.bounds.size.height - ins.bottom - 6.0 - boxH;
    ox = fmin(fmax(ox, minX), fmax(minX, maxX));
    oy = fmin(fmax(oy, minY), fmax(minY, maxY));

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(ox, oy, boxW, boxH)];
    box.backgroundColor = [UIColor colorWithRed:0.36 green:0.33 blue:0.27 alpha:1.0]; // OSRS menu body (tan-grey)
    box.layer.borderColor = [UIColor blackColor].CGColor;
    box.layer.borderWidth = 1.0;
    box.userInteractionEnabled = NO;   // the drag drives selection; the rows never handle their own touches
    box.layer.shadowColor = [UIColor blackColor].CGColor;
    box.layer.shadowOpacity = 0.5;
    box.layer.shadowRadius = 6.0;
    box.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, boxW, kMenuHeaderViewH)];
    header.backgroundColor = [UIColor colorWithRed:0.24 green:0.21 blue:0.16 alpha:1.0]; // darker title strip
    header.text = @"  Choose Option";
    header.font = [UIFont boldSystemFontOfSize:14];
    header.textColor = [UIColor whiteColor];
    [box addSubview:header];

    self.menuRows = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger k = 0; k < count; k++) {
        NSDictionary *e = [entries[k] isKindOfClass:[NSDictionary class]] ? entries[k] : @{};
        UILabel *row = [[UILabel alloc] initWithFrame:
                        CGRectMake(0, kMenuHeaderViewH + k * kMenuRowViewH, boxW, kMenuRowViewH)];
        row.backgroundColor = [UIColor clearColor];
        row.attributedText = [self menuRowTextForOption:e[@"opt"] target:e[@"tgt"]];
        [box addSubview:row];
        self.menuRows[k] = row;
    }

    [self.view addSubview:box];
    self.menuContainer = box;
    [self appendLine:[NSString stringWithFormat:@"[menu-diag] native rows BUILT n=%ld box=%@ er=%@ viewIdx=%ld/%ld",
                      (long)count, NSStringFromCGRect(box.frame), NSStringFromCGRect(er),
                      (long)[self.view.subviews indexOfObject:box], (long)self.view.subviews.count]];
    self.menuHighlight = -1;
    // Seed the highlight + commit target from the press point so a lift-without-drag picks the row under it.
    [self updateNativeMenuHighlight:self.menuAnchor];
}

// "option target" — option white, target OSRS yellow (tags are already stripped in the snapshot).
- (NSAttributedString *)menuRowTextForOption:(NSString *)opt target:(NSString *)tgt {
    opt = [opt isKindOfClass:[NSString class]] ? opt : @"";
    tgt = [tgt isKindOfClass:[NSString class]] ? tgt : @"";
    UIFont *f = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[@"  " stringByAppendingString:opt]
        attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: [UIColor whiteColor]}];
    if (tgt.length) {
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:tgt]
            attributes:@{NSFontAttributeName: f,
                         NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.92 blue:0.35 alpha:1.0]}]];
    }
    return s;
}

#pragma mark - MENU-1/2/3 tap-mode menu (persistent, scrollable, submenu drill-in, ⚙ Customize)

// Build the persistent tap-driven menu. drilledParent>=0 means we're showing the submenu of that top-level
// display index (with a "‹ Back" row); -1 means the top level. Rows are UIButtons inside a UIScrollView, so a
// tap selects and a drag scrolls (no drag-select tracking — the long-press gesture is ignored in tap-mode).
- (void)buildTapMenuWithEntries:(NSArray *)entries drilledParent:(int)drilledParent {
    [self.menuContainer removeFromSuperview];
    [self.menuDismissLayer removeFromSuperview];
    self.menuRowEntries = entries;
    self.menuDrillParent = drilledParent;
    BOOL drilled = drilledParent >= 0;

    // Full-screen tap-to-cancel layer BEHIND the box (the box, added after, gets taps on its rows first).
    UIView *dismiss = [[UIView alloc] initWithFrame:self.view.bounds];
    dismiss.backgroundColor = [UIColor clearColor];
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(onTapMenuDismiss:)];
    [dismiss addGestureRecognizer:dt];
    [self.view addSubview:dismiss];
    self.menuDismissLayer = dismiss;

    // The engine menu rect in view coords (what the drag box covered); used to anchor the tap box near the press.
    CGRect er = [self engineMenuRectInView];

    NSInteger nRows = entries.count + (drilled ? 1 : 0);   // +1 for the back row
    CGFloat boxW = MAX(kMenuWidth, CGRectGetWidth(er) + 16.0);
    CGFloat headerH = kMenuHeaderViewH;

    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat availH = self.view.bounds.size.height - ins.top - ins.bottom - 16.0;
    CGFloat contentH = nRows * kMenuRowViewH;
    CGFloat scrollH = MIN(contentH, availH - headerH);
    CGFloat boxH = headerH + scrollH;

    // Anchor over the engine rect, hand-bias away from the thumb, clamp into the safe area (same as drag mode).
    CGFloat ox = CGRectGetMinX(er) - 8.0;
    if (self.menuHandRight) ox = CGRectGetMaxX(er) + 8.0 - boxW;
    CGFloat oy = CGRectGetMinY(er) - 4.0;
    CGFloat minX = ins.left + 6.0;
    CGFloat maxX = self.view.bounds.size.width - ins.right - 6.0 - boxW;
    CGFloat minY = ins.top + 6.0;
    CGFloat maxY = self.view.bounds.size.height - ins.bottom - 6.0 - boxH;
    ox = fmin(fmax(ox, minX), fmax(minX, maxX));
    oy = fmin(fmax(oy, minY), fmax(minY, maxY));

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(ox, oy, boxW, boxH)];
    box.backgroundColor = [UIColor colorWithRed:0.36 green:0.33 blue:0.27 alpha:1.0];
    box.layer.borderColor = [UIColor blackColor].CGColor;
    box.layer.borderWidth = 1.0;
    box.layer.shadowColor = [UIColor blackColor].CGColor;
    box.layer.shadowOpacity = 0.5;
    box.layer.shadowRadius = 6.0;
    box.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, boxW, headerH)];
    header.backgroundColor = [UIColor colorWithRed:0.24 green:0.21 blue:0.16 alpha:1.0];
    header.text = drilled ? @"  Submenu" : @"  Choose Option";
    header.font = [UIFont boldSystemFontOfSize:14];
    header.textColor = [UIColor whiteColor];
    [box addSubview:header];

    // MENU-3: a ⚙ Customize chip on the top-level header — taps latch Shift and reopen, so the swap-config
    // submenus appear without manually arming the corner ⇧ first. When Shift is already latched it shows a tick.
    if (!drilled) {
        UIButton *cog = [UIButton buttonWithType:UIButtonTypeSystem];
        cog.frame = CGRectMake(boxW - 44.0, 0, 44.0, headerH);
        [cog setTitle:(self.shiftHeld ? @"⚙✓" : @"⚙") forState:UIControlStateNormal];
        cog.accessibilityLabel = self.shiftHeld ? @"Customize, on" : @"Customize";
        cog.accessibilityHint = @"Latches Shift and reopens the menu to show swap-config options";
        cog.titleLabel.font = [UIFont systemFontOfSize:14];
        cog.tintColor = self.shiftHeld ? [UIColor colorWithRed:0.98 green:0.78 blue:0.25 alpha:1.0]
                                       : [UIColor colorWithWhite:0.85 alpha:1.0];
        [cog addTarget:self action:@selector(onTapMenuCustomize:) forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:cog];
    }

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, headerH, boxW, scrollH)];
    sc.contentSize = CGSizeMake(boxW, contentH);
    sc.showsVerticalScrollIndicator = (contentH > scrollH);
    sc.bounces = YES;
    [box addSubview:sc];
    self.menuScroll = sc;

    self.menuRows = [NSMutableArray arrayWithCapacity:nRows];
    CGFloat ry = 0;
    if (drilled) {
        UIButton *back = [self tapMenuRowButton:CGRectMake(0, ry, boxW, kMenuRowViewH)];
        [back setAttributedTitle:[self menuRowTextForOption:@"‹ Back" target:@""] forState:UIControlStateNormal];
        [back addTarget:self action:@selector(onTapMenuBack:) forControlEvents:UIControlEventTouchUpInside];
        [sc addSubview:back];
        ry += kMenuRowViewH;
    }
    for (NSInteger k = 0; k < (NSInteger)entries.count; k++) {
        NSDictionary *e = [entries[k] isKindOfClass:[NSDictionary class]] ? entries[k] : @{};
        BOOL isParent = (!drilled)
            && [e[@"sub"] isKindOfClass:[NSArray class]] && [(NSArray *)e[@"sub"] count] > 0;
        UIButton *row = [self tapMenuRowButton:CGRectMake(0, ry, boxW, kMenuRowViewH)];
        NSMutableAttributedString *txt = [[self menuRowTextForOption:e[@"opt"] target:e[@"tgt"]] mutableCopy];
        if (isParent) {
            [txt appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ▸"
                attributes:@{NSForegroundColorAttributeName: [UIColor whiteColor],
                             NSFontAttributeName: [UIFont systemFontOfSize:16 weight:UIFontWeightBold]}]];
        }
        [row setAttributedTitle:txt forState:UIControlStateNormal];
        row.tag = k;   // index into `entries`
        [row addTarget:self action:@selector(onTapMenuRow:) forControlEvents:UIControlEventTouchUpInside];
        [sc addSubview:row];
        [self.menuRows addObject:row];
        ry += kMenuRowViewH;
    }

    [self.view addSubview:box];
    self.menuContainer = box;
    [self appendLine:[NSString stringWithFormat:@"[menu-diag] tap-mode menu BUILT n=%ld drilled=%d",
                      (long)entries.count, drilled]];
}

// A left-aligned, highlight-on-press menu row button (OSRS-styled).
- (UIButton *)tapMenuRowButton:(CGRect)frame {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.backgroundColor = [UIColor clearColor];
    [b setBackgroundImage:[self solidImage:[UIColor colorWithWhite:1.0 alpha:0.22]] forState:UIControlStateHighlighted];
    return b;
}

// 1x1 stretchable solid-colour image (for a button's highlighted background).
- (UIImage *)solidImage:(UIColor *)color {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0);
    [color setFill];
    UIRectFill(CGRectMake(0, 0, 1, 1));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Tap a tap-mode row: at top level a ▸ parent drills into its submenu, a flat row commits via the engine row
// click-through; inside a submenu the row commits the child directly (its RuneLite onClick, via the bridge).
- (void)onTapMenuRow:(UIButton *)b {
    NSInteger k = b.tag;
    if (self.menuDrillParent >= 0) {
        [self haptic:RMHapticOp];
        [JVMLauncher invokeMenuEntryParent:self.menuDrillParent child:(int)k];
        [self appendLine:[NSString stringWithFormat:@"[shell] menu submenu select parent=%d child=%ld",
                          self.menuDrillParent, (long)k]];
        [self closeTapMenuAfterInvoke];
        return;
    }
    NSDictionary *e = (k >= 0 && k < (NSInteger)self.menuRowEntries.count)
        ? self.menuRowEntries[k] : nil;
    NSArray *sub = [e[@"sub"] isKindOfClass:[NSArray class]] ? e[@"sub"] : nil;
    if (sub.count > 0) {
        [self haptic:RMHapticMenuOpen];                            // a submenu opening
        [self buildTapMenuWithEntries:sub drilledParent:(int)k];   // drill in
        return;
    }
    // Flat row. When the engine renders the whole menu (not self-scrolling), click its fixed-geometry row — this
    // honours the entry's RuneLite onClick + worldViewId. When the engine menu is SCROLLABLE (>~30 entries) the
    // fixed per-row geometry is unreliable (off-screen rows clamp to the wrong place), so commit the entry
    // directly by index instead (childIndex<0 = the top-level entry itself).
    if (self.menuScrollable) {
        [self haptic:RMHapticOp];
        [JVMLauncher invokeMenuEntryParent:(int)k child:-1];
        [self appendLine:[NSString stringWithFormat:@"[shell] menu tap select row=%ld (invoke, scrollable)", (long)k]];
        [self closeTapMenuAfterInvoke];
        return;
    }
    CGRect r = self.menuGeomGame;
    int ex = (int)lround(CGRectGetMidX(r));
    int ey = (int)CGRectGetMinY(r) + kMenuHeaderPx + (int)k * kMenuRowPx + kMenuRowPx / 2;
    ey = (int)fmin(fmax((CGFloat)ey, CGRectGetMinY(r) + 1), CGRectGetMaxY(r) - 2);
    [self haptic:RMHapticOp];
    [JVMLauncher postMenuSelectX:ex y:ey];
    [self appendLine:[NSString stringWithFormat:@"[shell] menu tap select row=%ld @game %d,%d", (long)k, ex, ey]];
    self.menuOpen = NO;
    [self beginMenuClose];
}

// "‹ Back" — return to the top-level menu.
- (void)onTapMenuBack:(UIButton *)b {
    [self buildTapMenuWithEntries:self.menuTopEntries drilledParent:-1];
}

// ⚙ Customize — latch Shift (so Menu-Entry-Swapper's swap-config submenus appear) then reopen the engine menu at
// the same target. Closes the current menu first so the reopened one is rebuilt cleanly with Shift held.
- (void)onTapMenuCustomize:(UIButton *)b {
    // Configure/overlay entries only surface with Shift held, so latch it. Shift may not be pinned to the
    // screen now, so a latch here could strand an invisible held modifier — remember we set it and release it
    // when this Customize menu closes (teardownMenuViews), so it never outlives the interaction.
    BOOL autoLatched = !self.shiftHeld;
    if (autoLatched)
        [self onToggleShift]; // latch Shift + update the corner button state (if pinned)
    int gx = self.lastMenuX, gy = self.lastMenuY;
    CGPoint anchor = self.menuAnchor;
    // Close the open engine menu (title-strip click = no action), tear down native, then reopen shortly after.
    CGRect r = self.menuGeomGame;
    if (r.size.width > 0) [JVMLauncher postMenuSelectX:(int)lround(CGRectGetMidX(r)) y:(int)CGRectGetMinY(r) + 2];
    self.menuOpen = NO;
    [self teardownMenuViews];            // (arms nothing yet — set customizeAutoShift AFTER so this teardown doesn't release)
    self.customizeReopenPending = YES;   // a new long-press before the delay fires cancels this (openEngineMenuAtGameX)
    self.customizeAutoShift = autoLatched; // release the Shift WE latched once the reopened menu closes
    [self appendLine:@"[shell] menu Customize -> Shift latched, reopening"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.customizeReopenPending) return;   // superseded by a fresh menu in the meantime
        self.customizeReopenPending = NO;
        [self openEngineMenuAtGameX:gx gameY:gy anchor:anchor];
    });
}

// Tap outside the menu box -> cancel (close the engine menu with no action).
- (void)onTapMenuDismiss:(UITapGestureRecognizer *)g {
    [self cancelMenu];
}

// After invoking a submenu child directly (its action already ran on the client thread), close the now-stale
// open engine menu with a clean title-strip click, then tear the native cover down.
- (void)closeTapMenuAfterInvoke {
    CGRect r = self.menuGeomGame;
    if (r.size.width > 0) {
        [JVMLauncher postMenuSelectX:(int)lround(CGRectGetMidX(r)) y:(int)CGRectGetMinY(r) + 2];
    }
    self.menuOpen = NO;
    [self beginMenuClose];
}

// Drive the native menu from the drag: highlight the row under the finger, keep the (hidden) engine menu open
// by parking its clamped cursor on the matching engine row, and set the commit target to that row's engine
// centre. Off the rows -> cancel (commit clicks the title strip = close with no action).
- (void)updateNativeMenuHighlight:(CGPoint)pScreen {
    if (!self.menuContainer) return;
    CGPoint c = [self.screen convertPoint:pScreen toView:self.menuContainer];
    CGFloat graceX = 90.0, graceY = 12.0;
    BOOL inX = (c.x > -graceX && c.x < self.menuContainer.bounds.size.width + graceX);
    NSInteger hit = -1;
    for (NSInteger k = 0; k < (NSInteger)self.menuRows.count; k++) {
        CGRect rf = self.menuRows[k].frame;
        CGFloat top = rf.origin.y - (k == 0 ? graceY : 0);
        CGFloat bot = CGRectGetMaxY(rf) + (k == (NSInteger)self.menuRows.count - 1 ? graceY : 0);
        if (inX && c.y >= top && c.y < bot) { hit = k; break; }
    }

    if (hit != self.menuHighlight) {
        for (NSInteger k = 0; k < (NSInteger)self.menuRows.count; k++) {
            self.menuRows[k].backgroundColor = (k == hit)
                ? [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.22]   // hovered row highlight
                : [UIColor clearColor];
        }
        if (hit >= 0)
            [self haptic:RMHapticMenuHover];
        self.menuHighlight = (int)hit;
    }

    CGRect r = self.menuGeomGame;
    int ex = (int)lround(CGRectGetMidX(r));
    if (hit >= 0) {
        // engine row centre for display index `hit` (fixed gamepack geometry; clamp inside the rect)
        int ey = (int)CGRectGetMinY(r) + kMenuHeaderPx + (int)hit * kMenuRowPx + kMenuRowPx / 2;
        ey = (int)fmin(fmax((CGFloat)ey, CGRectGetMinY(r) + 1), CGRectGetMaxY(r) - 2);
        self.menuFingerOnMenu = YES;
        self.menuSelX = ex; self.menuSelY = ey;
        [JVMLauncher postMoveX:ex y:ey];   // keep the engine highlight in lock-step (menu stays open)
    } else {
        self.menuFingerOnMenu = NO;
        self.menuSelX = ex; self.menuSelY = (int)CGRectGetMinY(r) + 2;   // title strip = clean cancel
        [JVMLauncher postMoveX:self.menuSelX y:self.menuSelY];
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady]) return;
    CGPoint loc = [g locationInView:self.screen];

    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            int gx = 0, gy = 0;
            if (![self mapPoint:loc toGameX:&gx toGameY:&gy]) return; // letterbox
            [JVMLauncher postCancelArmedTap];                         // a hold opens the menu, it never walks
            [self openEngineMenuAtGameX:gx gameY:gy anchor:loc];
            [self haptic:RMHapticMenuOpen];
            [self appendLine:[NSString stringWithFormat:@"[shell] long-press -> engine menu @game %d,%d", gx, gy]];
            break;
        }
        case UIGestureRecognizerStateChanged:
            if (self.menuTapMode) break;              // tap-mode: the persistent list drives itself (buttons/dismiss)
            [self updateMenuHighlightForPoint:loc];   // move the engine pointer to the finger -> highlight
            break;

        case UIGestureRecognizerStateEnded:
            if (self.menuTapMode) break;              // tap-mode: a lift doesn't commit; the menu stays up to tap
            [self commitMenuSelection];               // click under the finger -> select (or close if off-menu)
            break;

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (self.menuTapMode) break;              // tap-mode: persistent; an interrupted hold doesn't close it
            [self cancelMenu];                        // any click closes the open engine menu (camera recovers)
            break;

        default:
            break;
    }
}

#pragma mark - Right-click menu (drives the engine's own menu)

// Pull the live engine right-click menu bounds from the MenuPeekBridge snapshot (gamepack 765x503 coords).
// Sets menuGeomValid + menuGeomGame while the engine reports an open menu; clears valid during the brief build
// window before the menu exists, so the caller falls back to the raw finger point.
- (void)refreshMenuGeometry {
    NSString *snap = [JVMLauncher menuPeekSnapshot];
    if (snap.length == 0) { self.menuGeomValid = NO; return; }
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.refreshMenuGeometry");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"menuOpen"] boolValue]) { self.menuGeomValid = NO; return; }
    int mw = [d[@"menuW"] intValue], mh = [d[@"menuH"] intValue];
    if (mw <= 0 || mh <= 0) { self.menuGeomValid = NO; return; }
    self.menuGeomGame = CGRectMake([d[@"menuX"] intValue], [d[@"menuY"] intValue], mw, mh);
    self.menuGeomValid = YES;
}

// Drive the ENGINE menu's highlight: move the engine pointer to the finger so the engine highlights whichever of
// its OWN rows is under it (exactly like a real mouse). CRUCIAL: the OSRS client auto-closes its right-click menu
// the instant the cursor leaves the menu bounds, so we CLAMP the reported cursor strictly inside the live menu
// rect — the engine never sees it leave, and the menu stays open until the finger lifts. We separately track the
// REAL finger spot so commit can tell select (over the menu) from cancel (dragged off). Haptic ticks per row.
- (void)updateMenuHighlightForPoint:(CGPoint)p {
    if (!self.menuOpen) return;
    if (self.menuTapMode) return;                                            // tap-mode list isn't drag-driven
    if (self.menuContainer) { [self updateNativeMenuHighlight:p]; return; }   // #8: native rows drive selection
    int gx = 0, gy = 0;
    if (![self mapPoint:p toGameX:&gx toGameY:&gy]) return;   // letterbox: keep the menu, ignore this move

    [self refreshMenuGeometry];

    int sx = gx, sy = gy;          // where we park the engine cursor (clamped inside the menu)
    BOOL onMenu = YES;             // does the finger want a row (select) or has it left the menu (cancel)?
    if (self.menuGeomValid) {
        CGRect r = self.menuGeomGame;
        sx = (int)lround(fmin(fmax((CGFloat)gx, CGRectGetMinX(r) + 1), CGRectGetMaxX(r) - 2));
        sy = (int)lround(fmin(fmax((CGFloat)gy, CGRectGetMinY(r) + 1), CGRectGetMaxY(r) - 2));
        onMenu = CGRectContainsPoint(CGRectInset(r, -kMenuGraceX, -kMenuGraceY), CGPointMake(gx, gy));
    }

    self.menuFingerOnMenu = onMenu;
    self.lastMenuX = sx; self.lastMenuY = sy;   // clamped click-through highlight target
    if (onMenu) {
        self.menuSelX = sx; self.menuSelY = sy;                       // release here -> select the row under the finger
    } else if (self.menuGeomValid) {
        CGRect r = self.menuGeomGame;                                 // dragged off -> release clicks the title strip:
        self.menuSelX = (int)lround(CGRectGetMidX(r));                // closes the menu with NO action (clean cancel,
        self.menuSelY = (int)lround(CGRectGetMinY(r)) + 2;            // never a stray world click)
    } else {
        self.menuSelX = gx; self.menuSelY = gy;                       // no geometry yet: fall back to the raw point
    }

    // Only drive the engine cursor once the live menu rect is known: the engine auto-closes its menu the
    // instant the cursor leaves it, and before the geometry lands the clamp can't protect it — a raw move
    // (finger still travelling, e.g. the chat pull-down) yanks the cursor out and silently kills the menu
    // during the build window (the intermittent "haptics but no filter menu" bug).
    if (self.menuGeomValid) [JVMLauncher postMoveX:sx y:sy];   // engine highlights the row under its (clamped) pointer
    if (fabs(p.y - self.menuHapticY) >= 14.0) {
        self.menuHapticY = p.y;
        [self haptic:RMHapticMenuHover];
    }
}

// Close the engine right-click menu with NO click when its live rect is unknown (menuGeomValid == NO). We can't
// target the title strip without the rect, and selectMenuPoint()/any press-point click would land as a stray
// world action. The engine auto-closes the menu the instant the cursor leaves the menu bounds (the behaviour
// updateMenuHighlightForPoint clamps AGAINST to keep it open), so move the cursor to a far corner — the menu is
// small and anchored at the press point, so the diagonally-opposite corner is always outside it — and clear the
// parked hover. A move never clicks, so nothing is selected/walked. QA-P1-02.
- (void)closeEngineMenuNoClick {
    const int farX = self.menuSelX > 200 ? 4 : 760;
    const int farY = self.menuSelY > 150 ? 4 : 499;
    [JVMLauncher postMoveX:farX y:farY];
    [JVMLauncher postClearHover];
}

// Release: click the resolved target. Over the menu -> the row under the finger (select); dragged off -> the menu's
// title strip (closes with no action = cancel). Either way the menu closes, so camera/world input frees up.
- (void)commitMenuSelection {
    if (!self.menuOpen) { [self teardownMenuViews]; return; }
    // QA-P1-02: the finger lifted before the engine menu registered (menuGeomValid never went YES — a long-press
    // released inside the ~1-2 frame build window, wider on a laggy device). menuSelX/Y is still the raw press
    // point, so postMenuSelect -> selectMenuPoint would LEFT-CLICK the world there = a walk / attack / pickup the
    // user never chose. Treat it as a clean cancel: close the (possibly just-opening) engine menu with no click.
    if (!self.menuGeomValid) {
        [self closeEngineMenuNoClick];
        [self appendLine:@"[shell] menu cancel (build aborted — no click)"];
        self.menuOpen = NO;
        [self beginMenuClose];
        return;
    }
    [JVMLauncher postMenuSelectX:self.menuSelX y:self.menuSelY];
    [self appendLine:[NSString stringWithFormat:@"[shell] menu %@ @game %d,%d",
                      self.menuFingerOnMenu ? @"select" : @"cancel", self.menuSelX, self.menuSelY]];
    self.menuOpen = NO;
    [self beginMenuClose];   // hold the native cover up until the engine menu actually closes (no peek-through)
}

// Gesture interrupted (system took the touch): close the menu with no action so nothing stays stuck — click the
// title strip if we know the menu rect, else fall back to the last clamped point.
- (void)cancelMenu {
    if (self.menuOpen) {
        if (self.menuGeomValid) {
            CGRect r = self.menuGeomGame;
            [JVMLauncher postMenuSelectX:(int)lround(CGRectGetMidX(r)) y:(int)lround(CGRectGetMinY(r)) + 2];
        } else {
            [self closeEngineMenuNoClick];   // QA-P1-02: no rect -> close via move-off, never a press-point click
        }
        [self appendLine:@"[shell] right-click menu closed"];
    }
    self.menuOpen = NO;
    [self beginMenuClose];   // keep the cover up through the engine-menu close latency
}

// Defer the native-overlay teardown: the engine right-click menu (now composited into the UI in GPU mode) takes a
// game cycle or two to actually close after the commit/cancel click. Removing the native cover immediately exposes
// the engine menu for that gap (the "native menu disappears, native engine menu flashes" artifact). Instead keep
// the cover up and let onDisplayTick tear it down once the MenuPeekBridge snapshot reports the engine menu closed
// (or a short timeout). The container is inert here (menuOpen=NO), so gestures/camera already recovered.
- (void)beginMenuClose {
    // The tap-mode dismiss layer must stop intercepting the moment we commit (don't block the game through the
    // close-latency window); the box stays as the cover until onDisplayTick tears it down.
    [self.menuDismissLayer removeFromSuperview];
    self.menuDismissLayer = nil;
    if (self.menuContainer == nil) { [self teardownMenuViews]; return; }
    self.menuClosing = YES;
    self.menuClosingAt = CACurrentMediaTime();
}

- (void)teardownMenuViews {
    [self.menuContainer removeFromSuperview];
    [self.menuDismissLayer removeFromSuperview];
    self.menuContainer = nil;
    self.menuDismissLayer = nil;
    self.menuScroll = nil;
    self.menuRows = nil;
    self.menuRowEntries = nil;
    self.menuTopEntries = nil;
    self.menuHighlight = -1;
    self.menuTapMode = NO;
    self.menuDrillParent = -1;
    self.menuBuilding = NO;
    self.menuClosing = NO;
    // Release the Shift that onTapMenuCustomize auto-latched (only if WE set it), now that its menu has closed —
    // this is what keeps an unpinned Shift from being stranded held after a Customize interaction.
    if (self.customizeAutoShift) {
        self.customizeAutoShift = NO;
        if (self.shiftHeld)
            [self onToggleShift];
    }
    // Restore the default engine-menu raster suppression (the build-timeout fallback un-gates it).
    [JVMLauncher setEngineMenuRenderSuppressed:YES];
}

// one-finger drag -> rotate the camera. Feed incremental pixel deltas (reset the recognizer's translation
// each step) to the bridge, which applies them to the camera yaw/pitch targets directly. The menuOpen
// guard is belt-and-suspenders: if a long-press already claimed the touch, never also rotate.
- (void)onCameraPan:(UIPanGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady] || self.menuOpen) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        [JVMLauncher postCancelArmedTap]; // this touch is a drag, not a tap: no click is coming
        // DRAG-1: the TRUE touch start, which several branches below classify the drag by. locationInView is
        // already kSceneDragSlop away from it by the time a pan begins, so the recognizer hands us the landing
        // point it recorded (see RMCameraPanRecognizer.landing) rather than us unwinding a translation.
        CGPoint landing = [g isKindOfClass:[RMCameraPanRecognizer class]]
                              ? ((RMCameraPanRecognizer *)g).landing
                              : [g locationInView:self.screen];
        // How long the finger rested before it moved off: an item lifts only after the drag hold.
        NSTimeInterval held = [g isKindOfClass:[RMCameraPanRecognizer class]]
                                  ? CACurrentMediaTime() - ((RMCameraPanRecognizer *)g).landedAt
                                  : 0;
        self.paneSwiping = NO;
        [g setTranslation:CGPointZero inView:self.screen];
        // World map open: a 1-finger drag that BEGINS inside the Key list or the open surface dropdown
        // SCROLLS that list (wheel events parked over it); inside the map window it pans the MAP (bridge ->
        // map centre). Outside the window it stays a camera drag, like the desktop.
        if (self.mapOpen) {
            int mgx = 0, mgy = 0;
            if ([self mapPoint:[g locationInView:self.screen] toGameX:&mgx toGameY:&mgy]) {
                CGPoint gp = CGPointMake(mgx, mgy);
                if ((self.mapListCanvas.size.width > 0 && CGRectContainsPoint(self.mapListCanvas, gp))
                        || (self.mapKeyCanvas.size.width > 0 && CGRectContainsPoint(self.mapKeyCanvas, gp))) {
                    self.mapListScrolling = YES;
                    self.mapListWheelPt = gp;
                    self.mapListScrollAcc = 0;
                    self.mapPanning = NO;
                    self.chatScrolling = NO;
                    [self appendLine:@"[map] list scroll begin"];
                    return;
                }
                if (self.mapWindowCanvas.size.width <= 0
                        || CGRectContainsPoint(self.mapWindowCanvas, gp)) {
                    self.mapPanning = YES;
                    self.mapListScrolling = NO;
                    self.mapPanAccX = self.mapPanAccY = 0;
                    self.chatScrolling = NO;
                    [self appendLine:@"[map] pan begin"];
                    return;
                }
            }
        }
        self.mapPanning = NO;
        self.mapListScrolling = NO;
        // A drag that starts on the item search's results scrolls that list; the bridge sends the chat scroll to
        // it while it is open. The list's window is only published while it holds more than fits.
        int lx = 0, ly = 0;
        if (self.chatDialogueActive && self.dialogueIsPrompt && self.dialoguePromptList.size.width > 0 && [self mapPoint:landing toGameX:&lx toGameY:&ly] && CGRectContainsPoint(self.dialoguePromptList, CGPointMake(lx, ly))) {
            self.chatScrolling = YES;
            self.chatScrollAccum = 0;
            [self appendLine:@"[shell] search results scroll begin"];
            return;
        }
        // A drag that STARTS inside the open chat box scrolls the chat (finger-scroll) instead of rotating the
        // camera. Only when the chat is open (chatScrollable); otherwise it's a normal camera drag.
        int gx = 0, gy = 0;
        if (self.chatScrollable && self.chatScrollCanvas.size.width > 0
                && [self mapPoint:[g locationInView:self.screen] toGameX:&gx toGameY:&gy]
                && CGRectContainsPoint(self.chatScrollCanvas, CGPointMake(gx, gy))) {
            self.chatScrolling = YES;
            self.chatScrollAccum = 0;
            [self appendLine:@"[shell] chat scroll begin"];
            return;
        }
        self.chatScrolling = NO;
        // DRAG-1/DRAG-1b: a drag that STARTS over the inventory grid OR a reorder pane (Prayer/Spellbook/Bank)
        // rearranges items (engine WidgetDrag) rather than rotating the camera. The press must land on the SOURCE
        // slot, so map the true touch start (loc - slop), not the already-moved current point. Only diverts
        // inventory-/reorder-origin drags — scene drags still rotate. Mirrors Android's combined-branch classification.
        // The drag only picks the item up once the finger has rested on it for the drag hold (Settings > Game
        // settings); a quicker swipe from the pane scrolls it if it scrolls and otherwise does nothing, so a
        // flick across the inventory can't move an item or swing the camera.
        CGRect inv = [JVMLauncher inventoryCanvasBounds];
        NSArray<NSValue *> *reorderPanes = [JVMLauncher reorderPaneCanvasBounds];
        BOOL haveInv = !CGRectIsNull(inv) && CGRectGetWidth(inv) > 0 && CGRectGetHeight(inv) > 0;
        BOOL quickPaneSwipe = NO;
        if (haveInv || reorderPanes.count > 0) {
            int sx = 0, sy = 0;
            if ([self mapPoint:landing toGameX:&sx toGameY:&sy]) {
                BOOL hit = haveInv && CGRectContainsPoint(inv, CGPointMake(sx, sy));
                for (NSValue *v in reorderPanes) {
                    if (hit)
                        break;
                    if (CGRectContainsPoint(v.CGRectValue, CGPointMake(sx, sy)))
                        hit = YES;
                }
                if (hit && held < [RMGameSettings dragHoldMs] / 1000.0) {
                    quickPaneSwipe = YES;
                } else if (hit) {
                    self.itemDragging = YES;
                    self.itemDragLastX = sx;
                    self.itemDragLastY = sy;                          // seed the release-fallback point
                    [JVMLauncher postTouchType:0 x:sx y:sy button:1]; // MOUSE_PRESSED on the source slot
                    [self haptic:RMHapticDrag];                       // once per drag, as it lifts off the slot
                    [self appendLine:[NSString stringWithFormat:@"[shell] item drag begin @canvas %d,%d", sx, sy]];
                    return;
                }
            }
        }
        self.itemDragging = NO;
        // SCROLL-SPIKE: a drag that STARTS over an open, scrollable engine interface scrolls THAT interface (wheel
        // notches the engine routes to the hovered scrollable) instead of rotating the camera. Hit-tested in the
        // engine, so only a genuinely-scrollable spot diverts the drag — over the bare viewport it stays a rotate.
        int isx = 0, isy = 0;
        if ([self mapPoint:[g locationInView:self.screen] toGameX:&isx toGameY:&isy]
                && [JVMLauncher engineScrollableAtX:isx y:isy]) {
            self.ifaceScrolling = YES;
            self.ifaceWheelPt = CGPointMake(isx, isy);
            self.ifaceScrollAcc = 0;
            [self appendLine:[NSString stringWithFormat:@"[shell] iface scroll begin @canvas %d,%d", isx, isy]];
            return;
        }
        self.ifaceScrolling = NO;
        if (quickPaneSwipe) {
            self.paneSwiping = YES; // swallowed until the lift
            [self appendLine:@"[shell] quick pane swipe ignored (nothing to scroll)"];
            return;
        }
        // A camera drag moves the world, not the pointer — so clear any frozen hover first, otherwise
        // scenery rotating under the stale cursor lights up and the next walk-tap mis-clicks it.
        [JVMLauncher postClearHover];
        self.cameraDragAccX = self.cameraDragAccY = 0; // reset like mapPanAccX/Y and chatScrollAccum at gesture-begin
        [self appendLine:@"[shell] camera pan begin (1-finger)"];
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.paneSwiping) {
            self.paneSwiping = NO;
            return;
        }
        if (self.itemDragging) {
            // ALWAYS release so the engine's WidgetDrag state machine closes — even if the finger lifted in the
            // letterbox (mapPoint fails); fall back to the last valid drag point. A stranded press would otherwise
            // leave the inventory stuck mid-drag.
            int dx = self.itemDragLastX, dy = self.itemDragLastY, mx = 0, my = 0;
            if ([self mapPoint:[g locationInView:self.screen] toGameX:&mx toGameY:&my]) { dx = mx; dy = my; }
            [JVMLauncher postTouchType:2 x:dx y:dy button:1];   // MOUSE_RELEASED on the destination slot
            self.itemDragging = NO;
            [self appendLine:[NSString stringWithFormat:@"[shell] item drag end @canvas %d,%d", dx, dy]];
            return;
        }
        if (self.mapPanning || self.mapListScrolling) {
            self.mapPanning = NO;
            self.mapListScrolling = NO;
            return;
        }
        if (self.chatScrolling) {
            self.chatScrolling = NO;
            [JVMLauncher postClearHover];   // drop the cursor the wheel parked over the chat
            return;
        }
        if (self.ifaceScrolling) {
            self.ifaceScrolling = NO;
            [JVMLauncher postClearHover];   // drop the cursor the wheel parked over the interface
            return;
        }
        [self appendLine:@"[shell] camera pan end"];
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;
    if (self.paneSwiping) {
        [g setTranslation:CGPointZero inView:self.screen];
        return;
    }
    // DRAG-1: stream the drag to the engine as MOUSE_DRAGGED at the finger's canvas point (one per frame is fine).
    // A frame whose point maps off-canvas is just skipped — the drag stays live and the cached last-valid point
    // (updated here) guarantees a clean release.
    if (self.itemDragging) {
        int dx = 0, dy = 0;
        if ([self mapPoint:[g locationInView:self.screen] toGameX:&dx toGameY:&dy]) {
            self.itemDragLastX = dx; self.itemDragLastY = dy;
            [JVMLauncher postTouchType:1 x:dx y:dy button:1];   // MOUSE_DRAGGED
        }
        [g setTranslation:CGPointZero inView:self.screen];
        return;
    }
    CGPoint d = [g translationInView:self.screen];
    [g setTranslation:CGPointZero inView:self.screen];   // make the next delta incremental
    if (d.x == 0 && d.y == 0) return;
    if (self.mapListScrolling) {
        // Swipe-scroll the Key list / surface dropdown via the engine's own UPDATE_SCROLLBAR script (the same
        // fix chat already uses) instead of a mouse wheel — a wheel over the map is the zoom trigger (onPinch),
        // so the old wheel path mis-fired as a zoom. Content follows the finger, no camera/zoom side-effect.
        [self scrollMapListByDragDeltaY:d.y];
        return;
    }
    if (self.mapPanning) {
        // Finger pt -> whole canvas px, sub-px accumulated so slow drags aren't quantised away. The bridge
        // converts px -> map tiles via the live zoom; kMapPanSpeed > 1 = the map travels faster than the
        // finger (user preference — covering Gielinor 1:1 takes too many swipes).
        const CGFloat kMapPanSpeed = 2.0;
        CGFloat W = self.view.bounds.size.width;
        CGFloat k = (self.renderW > 0 && W > 0) ? (CGFloat)self.renderW / W : 1.0;
        k *= kMapPanSpeed;
        self.mapPanAccX += d.x * k;
        self.mapPanAccY += d.y * k;
        int dx = (int)(self.mapPanAccX < 0 ? ceil(self.mapPanAccX) : floor(self.mapPanAccX));
        int dy = (int)(self.mapPanAccY < 0 ? ceil(self.mapPanAccY) : floor(self.mapPanAccY));
        if (dx != 0 || dy != 0) {
            self.mapPanAccX -= dx;
            self.mapPanAccY -= dy;
            [JVMLauncher panEngineMapDx:dx dy:dy];
        }
        return;
    }
    if (self.chatScrolling) {
        [self scrollChatByDragDeltaY:d.y];
        return;
    }
    if (self.ifaceScrolling) {
        // SCROLL-SPIKE: wheel notches parked over the interface; the engine scrolls the hovered scrollable
        // (and redraws its scrollbar). Content follows the finger (swipe up -> wheel down), matching the
        // map-list feel; the same 22pt/notch cadence.
        const CGFloat kIfaceScrollPtPerNotch = 22.0;
        self.ifaceScrollAcc += -d.y / kIfaceScrollPtPerNotch;
        int notches = (int)(self.ifaceScrollAcc > 0 ? floor(self.ifaceScrollAcc) : ceil(self.ifaceScrollAcc));
        if (notches != 0) {
            self.ifaceScrollAcc -= notches;
            [JVMLauncher postWheelX:(int)self.ifaceWheelPt.x y:(int)self.ifaceWheelPt.y rotation:notches];
        }
        return;
    }
    // Inverted both axes (user preference): swipe direction now drags the world the opposite way (like
    // grabbing the scene), matching the feel they want vs. the previous "push the camera" direction.
    // Scale screen-pt deltas to engine-canvas px (renderW / view width) with sub-px accumulation so yaw/pitch
    // matches the bridge's canvas-pixel-calibrated sensitivity (JavaBridge.onCameraDrag / YAW_UNITS_PER_PX /
    // PITCH_UNITS_PER_PX) and Android's canvas-scaled deltas — same conversion mapPanning / scrollChatByDragDeltaY use.
    CGFloat W = self.view.bounds.size.width;
    CGFloat k = (self.renderW > 0 && W > 0) ? (CGFloat)self.renderW / W : 1.0;
    k *= [RMGameSettings cameraGain]; // Settings > Game settings: camera sensitivity
    self.cameraDragAccX += -d.x * k;
    self.cameraDragAccY += -d.y * k;
    int cdx = (int)(self.cameraDragAccX < 0 ? ceil(self.cameraDragAccX) : floor(self.cameraDragAccX));
    int cdy = (int)(self.cameraDragAccY < 0 ? ceil(self.cameraDragAccY) : floor(self.cameraDragAccY));
    if (cdx != 0 || cdy != 0) {
        self.cameraDragAccX -= cdx;
        self.cameraDragAccY -= cdy;
        [JVMLauncher postCameraDx:cdx dy:cdy];
    }
}

// Convert a vertical drag delta (screen pt) into a chat scroll, applied to the chat's OWN scroll layer (not a
// mouse wheel — a wheel over the transparent chat also zooms the camera). The drag is scaled to engine-canvas px
// (1:1 with the finger) and accumulated so sub-pixel drags aren't lost; content follows the finger via kChatScrollDir.
- (void)scrollChatByDragDeltaY:(CGFloat)dy {
    CGFloat W = self.view.bounds.size.width;
    if (self.renderW <= 0 || W <= 0) return;
    CGFloat canvasPerPt = (CGFloat)self.renderW / W / sHudScale; // screen pt -> the chat's own engine px
    self.chatScrollAccum += dy * canvasPerPt;
    int whole = (int)(self.chatScrollAccum < 0 ? ceil(self.chatScrollAccum) : floor(self.chatScrollAccum));
    if (whole == 0) return;
    self.chatScrollAccum -= whole;
    [JVMLauncher scrollEngineChat:(whole * kChatScrollDir)];
}

// The world-map analogue of scrollChatByDragDeltaY: scroll the open map's Key/maplist via the engine's own
// UPDATE_SCROLLBAR script (scrollMapPanel), NOT a mouse wheel — a wheel over the map zooms it (onPinch). Drag
// is scaled 1:1 to engine-canvas px and accumulated. NEGATE dy: scrollMapPanel adds delta to scrollY (which
// grows downward), so content-follows-finger needs finger-up (UIKit dy<0) -> positive delta -> reveal lower
// entries. Same as chat (scrollEngineChat applies kChatScrollDir=-1 over identical cur+delta scrollbar
// semantics); Android's branch reads the opposite-signed distanceY, so it needs no negation and iOS does.
- (void)scrollMapListByDragDeltaY:(CGFloat)dy {
    CGFloat W = self.view.bounds.size.width;
    if (self.renderW <= 0 || W <= 0)
        return;
    CGFloat canvasPerPt = (CGFloat)self.renderW / W; // screen pt -> engine-canvas px
    self.mapListScrollAcc += -dy * canvasPerPt;
    int whole = (int)(self.mapListScrollAcc < 0 ? ceil(self.mapListScrollAcc) : floor(self.mapListScrollAcc));
    if (whole == 0)
        return;
    self.mapListScrollAcc -= whole;
    [JVMLauncher scrollEngineMapPanel:whole];
}

// pinch -> zoom via the mouse wheel. Accumulate the scale change into whole wheel notches; pinch out
// (scale grows) = zoom in = negative rotation. Centroid is the wheel point so the gamepack zooms about it.
- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady]) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        [JVMLauncher postCancelArmedTap]; // two fingers zoom, they never tap
        self.pinchPrevScale = g.scale;
        self.wheelAccum = 0;
        [JVMLauncher postClearHover];   // zoom moves the world too; don't leave a stale hover behind
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        // Each zoom step posts a wheel at the pinch centroid, which re-enters the synthetic cursor THERE (the
        // engine zooms about the live mouse point). Left as-is, the cursor stays parked on whatever is under
        // the fingers — so the engine (and any hover-highlight) keeps picking it after the zoom: the "chop
        // tree box stays up when I zoom in" report. Re-park on lift so hover ends with the gesture.
        [JVMLauncher postClearHover];
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;
    const CGFloat WHEEL_SENS = 12.0;   // notches per unit of scale change (tune by feel)
    CGFloat step = g.scale - self.pinchPrevScale;
    self.pinchPrevScale = g.scale;
    self.wheelAccum += -step * WHEEL_SENS;   // scale up -> zoom in -> negative rotation
    int notches = (int)(self.wheelAccum > 0 ? floor(self.wheelAccum) : ceil(self.wheelAccum));
    if (notches == 0) return;
    self.wheelAccum -= notches;
    int gx = 0, gy = 0;
    if (![self mapPoint:[g locationInView:self.screen] toGameX:&gx toGameY:&gy]) { gx = 382; gy = 251; }
    [JVMLauncher postWheelX:gx y:gy rotation:notches];
    [self appendLine:[NSString stringWithFormat:@"[shell] pinch -> wheel rot=%d at %d,%d", notches, gx, gy]];
}

#pragma mark - Keyboard -> KeyEvent bridge (Phase 5)

- (void)onKbSend {
    [JVMLauncher postKeyStroke:AWT_VK_ENTER];
    [self appendLine:@"[shell] key enter (bar)"];
}

- (void)onKbHide {
    [self.kbField resignFirstResponder];
    [self appendLine:@"[shell] keyboard hidden (bar)"];
}

- (void)onToggleKeyboard {
    if ([self.kbField isFirstResponder]) {
        [self.kbField resignFirstResponder];
        [self appendLine:@"[shell] keyboard hidden"];
    } else {
        self.kbField.text = kKbSentinel;   // reset the sentinel each time it opens
        [self.kbField becomeFirstResponder];
        [self appendLine:@"[shell] keyboard shown (type -> game)"];
    }
}

// Sticky-Shift: latch SHIFT down/up via the bridge so subsequent taps/long-presses are seen by the engine as
// shift-held (shift-click swaps, Shift+right-click marking, overlay "Configure"). Highlighted while latched.
- (void)onToggleShift {
    self.shiftHeld = !self.shiftHeld;
    [JVMLauncher postShiftHeld:self.shiftHeld];
    self.shiftButton.backgroundColor = self.shiftHeld
        ? [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.92]   // RuneLite amber = latched on
        : [UIColor colorWithWhite:0.0 alpha:0.45];
    self.shiftButton.tintColor = self.shiftHeld ? [UIColor blackColor] : [UIColor whiteColor];
    [self appendLine:self.shiftHeld ? @"[shell] Shift latched ON" : @"[shell] Shift released"];
}

// PARITY-IOS-LATCH: sticky-Ctrl toggle, mirroring onToggleShift.
- (void)onToggleCtrl {
    self.ctrlHeld = !self.ctrlHeld;
    [JVMLauncher postCtrlHeld:self.ctrlHeld];
    self.ctrlButton.backgroundColor = self.ctrlHeld
                                          ? [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.92] // RuneLite amber = latched on
                                          : [UIColor colorWithWhite:0.0 alpha:0.45];
    self.ctrlButton.tintColor = self.ctrlHeld ? [UIColor blackColor] : [UIColor whiteColor];
    [self appendLine:self.ctrlHeld ? @"[shell] Control latched ON" : @"[shell] Control released"];
}

#pragma mark - KEY-1 action-hotkey strip

// The user's pinned hotkey ids ("group|key"), persisted across launches.
- (NSArray<NSString *> *)hotkeyPinned {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:@"hotkeyPinnedKeys"];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}
- (void)setHotkeyPinned:(NSArray<NSString *> *)pinned {
    [[NSUserDefaults standardUserDefaults] setObject:pinned forKey:@"hotkeyPinnedKeys"];
}

// Refresh the cached action list from the bridge (current bindings) and return it.
- (NSArray *)refreshHotkeyActions {
    // KEY-1b: list EVERY currently-bound plugin keybind (parity with Android's Hotkeys screen), not just the
    // curated hotkeyActionsJson set. Same {group,key,label,keyCode,mods,bind} shape, so nothing downstream changes.
    NSString *json = [JVMLauncher mobileBoundKeybinds];
    NSArray *arr = nil;
    if (json.length) {
        arr = parseBridgeJSON(json, "ViewController.refreshHotkeyActions");
    }
    self.hotkeyActions = [arr isKindOfClass:[NSArray class]] ? arr : @[];
    return self.hotkeyActions;
}

// Tap the ⚡ chip: show/hide the strip (rebuilding it from the current pinned set + live bindings on show).
- (void)onToggleHotkeyStrip {
    self.hotkeyStripVisible = !self.hotkeyStripVisible;
    if (self.hotkeyStripVisible) {
        [self rebuildHotkeyStrip];
        if (self.hotkeyStrip.arrangedSubviews.count == 0) {
            // Nothing pinned yet — guide the user straight to the picker instead of showing an empty strip.
            self.hotkeyStripVisible = NO;
            [self presentHotkeyPicker];
            return;
        }
    }
    self.hotkeyStrip.hidden = !self.hotkeyStripVisible || self.onLoginScreen;
    self.hotkeyButton.backgroundColor = self.hotkeyStripVisible
        ? [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.92] : [UIColor colorWithWhite:0.0 alpha:0.45];
    self.hotkeyButton.tintColor = self.hotkeyStripVisible ? [UIColor blackColor] : [UIColor whiteColor];
}

// Rebuild the strip's buttons from the pinned set (one per pinned action that still exists).
- (void)rebuildHotkeyStrip {
    for (UIView *v in [self.hotkeyStrip.arrangedSubviews copy]) {
        [self.hotkeyStrip removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray *actions = [self refreshHotkeyActions];
    NSArray<NSString *> *pinned = [self hotkeyPinned];
    for (NSString *pid in pinned) {
        NSDictionary *act = [self hotkeyActionForId:pid inActions:actions];
        if (!act) continue;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *label = [act[@"label"] isKindOfClass:[NSString class]] ? act[@"label"] : pid;
        [b setTitle:label forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
        b.tintColor = [UIColor whiteColor];
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
        b.layer.cornerRadius = 8;
        // Unbound actions show dimmed (tap is a no-op until the user binds them in the plugin's config).
        BOOL unbound = [act[@"keyCode"] intValue] == 0;   // VK_UNDEFINED
        if (unbound) b.alpha = 0.45;
        b.accessibilityIdentifier = pid;   // "group|key" — read back in onHotkeyTap:
        [b addTarget:self action:@selector(onHotkeyTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.hotkeyStrip addArrangedSubview:b];
        [b.heightAnchor constraintEqualToConstant:34].active = YES;
    }
}

// Fire the pinned action's configured Keybind through the bridge ("group|key" is carried on the button).
- (void)onHotkeyTap:(UIButton *)b {
    NSArray<NSString *> *parts = [b.accessibilityIdentifier componentsSeparatedByString:@"|"];
    if (parts.count != 2) return;
    [self haptic:RMHapticOp];
    // Quick-hop prev/next is a ~8s relog under the hood, not a keypress: route it through the
    // world-hop bridge (same path the World Switcher's prev/next buttons use) instead of firing
    // the raw keybind, which does nothing when the hopper plugin isn't focused. Mirrors Android.
    BOOL isWorldHop = [parts[0] isEqualToString:@"worldhopper"] &&
                      ([parts[1] isEqualToString:@"nextKey"] || [parts[1] isEqualToString:@"previousKey"]);
    if (isWorldHop) {
        [JVMLauncher worldHopDirection:[parts[1] isEqualToString:@"previousKey"]];
    } else {
        [JVMLauncher mobileFireHotkeyGroup:parts[0] key:parts[1]];
    }
    [self appendLine:[NSString stringWithFormat:@"[shell] hotkey fire %@/%@", parts[0], parts[1]]];
}

// Long-press the ⚡ chip -> the picker.
- (void)onHotkeyPicker:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self presentHotkeyPicker];
}

// An action sheet of every fireable hotkey (with its current binding); tapping one toggles it pinned.
- (void)presentHotkeyPicker {
    NSArray *actions = [self refreshHotkeyActions];
    NSMutableArray<NSString *> *pinned = [[self hotkeyPinned] mutableCopy];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Action hotkeys"
        message:@"Pin which hotkeys appear in the ⚡ strip. Bind them in each plugin's config."
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *act in actions) {
        if (![act isKindOfClass:[NSDictionary class]]) continue;
        NSString *pid = [self hotkeyIdFor:act];
        BOOL isPinned = [pinned containsObject:pid];
        NSString *bind = [act[@"bind"] isKindOfClass:[NSString class]] ? act[@"bind"] : @"Not set";
        NSString *title = [NSString stringWithFormat:@"%@ %@  (%@)",
                           isPinned ? @"✓" : @"○", act[@"label"], bind];
        UIAlertAction *a = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * _Nonnull action) {
            NSMutableArray<NSString *> *p = [[self hotkeyPinned] mutableCopy];
            if ([p containsObject:pid]) [p removeObject:pid]; else [p addObject:pid];
            [self setHotkeyPinned:p];
            [self rebuildHotkeyStrip];
            if (!self.hotkeyStripVisible && self.hotkeyStrip.arrangedSubviews.count > 0) [self onToggleHotkeyStrip];
        }];
        [ac addAction:a];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.hotkeyButton;
    ac.popoverPresentationController.sourceRect = self.hotkeyButton.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSString *)hotkeyIdFor:(NSDictionary *)act {
    return [NSString stringWithFormat:@"%@|%@", act[@"group"], act[@"key"]];
}
- (NSDictionary *)hotkeyActionForId:(NSString *)pid inActions:(NSArray *)actions {
    for (NSDictionary *act in actions) {
        if ([act isKindOfClass:[NSDictionary class]] && [[self hotkeyIdFor:act] isEqualToString:pid]) return act;
    }
    return nil;
}

// Drain the shared-core notification queue -> real OS notifications. Idle/Chat notifications, random events, etc.
// fire here because the sandbox has no tray/taskbar/shell-out. Auth is requested lazily on the first one.
- (void)drainNotifications {
    NSString *n = [JVMLauncher mobileNextNotification];
    if (n.length == 0) return;
    if (!self.notifAuthRequested) {
        self.notifAuthRequested = YES;
        UNUserNotificationCenter *unc = [UNUserNotificationCenter currentNotificationCenter];
        unc.delegate = self;   // so banners show even while foregrounded (the JVM suspends in background)
        [unc requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
            completionHandler:^(BOOL granted, NSError *err) {}];
    }
    unichar sepCh = 1;   // the "titlebody" separator the bridge uses (control char, not a literal)
    NSString *sepStr = [NSString stringWithCharacters:&sepCh length:1];
    while (n.length > 0) {   // drain the whole backlog this tick so a burst doesn't trickle out
        // Record is "titlebodysoundvolume" (NOTIF-1). sound+volume are always the LAST two fields, so
        // parse from the end — that way a body that itself contains the separator is still reassembled whole.
        NSArray<NSString *> *parts = [n componentsSeparatedByString:sepStr];
        NSString *title, *body, *soundType = @"", *volumeStr = @"";
        if (parts.count >= 4) {
            title = parts[0];
            soundType = parts[parts.count - 2];
            volumeStr = parts[parts.count - 1];
            body = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 3)] componentsJoinedByString:sepStr];
        } else {   // legacy 2-field record: title␟body split on the first separator
            NSRange sep = [n rangeOfString:sepStr];
            title = sep.location == NSNotFound ? @"RuneLite" : [n substringToIndex:sep.location];
            body  = sep.location == NSNotFound ? n : [n substringFromIndex:sep.location + 1];
        }
        if (title.length == 0) title = @"RuneLite";
        UNMutableNotificationContent *c = [[UNMutableNotificationContent alloc] init];
        c.title = title;
        c.body = body;
        // NOTIF-1: honor the desktop notification-sound type AND the per-notification volume (parity with
        // Android's deliverNotification silent = soundType=="OFF" || volume==0). OFF or volume==0 → deliver
        // the banner silently; NATIVE/CUSTOM with volume>0 → the platform default sound (no sandbox source
        // for a user's custom .wav, so CUSTOM collapses to default); unspecified volume (-1, legacy 2-arg
        // path) never forces silence on its own.
        NSInteger volume = volumeStr.length ? [volumeStr integerValue] : -1;
        BOOL silent = [soundType isEqualToString:@"OFF"] || volume == 0;
        c.sound = silent ? nil : [UNNotificationSound defaultSound];
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                         content:c trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
        n = [JVMLauncher mobileNextNotification];
    }
}

// SHOT-2: whether the engine's auto-screenshots (level-up / pet / boss kill / clue / collection-log …) are copied
// into the Photos library. Off by default (those fire often); toggled via a long-press on the 📷 button.
- (BOOL)autoSaveScreenshots {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"autoSaveScreenshots"];
}

// SHOT-2: drain the auto-screenshot queue each frame. The engine already wrote each PNG to the sandbox; when the
// user has enabled auto-save we copy it into Photos (the only Photos-reachable path). Always drain so a backlog
// can't build when auto-save is off.
- (void)drainScreenshots {
    BOOL save = [self autoSaveScreenshots];
    int writes = 0;   // cap Photos writes per tick so a burst can't flood the main thread with async callbacks;
    NSString *path;   // leftover paths stay queued for the next drain. When auto-save is OFF we still fully drain.
    while ((path = [JVMLauncher mobileNextScreenshot]).length > 0) {
        if (!save) continue;   // discard (keeps the queue from backing up)
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img == nil) continue;
        [self saveImageToRuneLiteAlbum:img announce:NO]; // silent path — no toast for event auto-saves
        [self appendLine:[NSString stringWithFormat:@"[shell] auto-screenshot -> Photos: %@", path.lastPathComponent]];
        if (++writes >= 3) break;   // remaining paths stay queued for the next tick
    }
}

// SHOT-4: long-press the 📷 button to toggle auto-saving the engine's event screenshots into Photos.
- (void)onScreenshotLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.presentedViewController) return;   // don't toggle silently behind another modal (codebase convention)
    BOOL now = ![self autoSaveScreenshots];
    [[NSUserDefaults standardUserDefaults] setBool:now forKey:@"autoSaveScreenshots"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Auto-save screenshots"
        message:now ? @"Event screenshots (level-ups, drops, clues, kills…) will now be saved to Photos."
                    : @"Event screenshots will no longer be saved to Photos."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
    [self appendLine:now ? @"[shell] auto-save screenshots ON" : @"[shell] auto-save screenshots OFF"];
}

// DISP-1: pick the interface size (the engine canvas height — a smaller canvas scales the whole HUD up). Persisted
// and applied on the next launch (the canvas size is fixed at startup via HeadlessResize), like the renderer pick.
- (void)onInterfaceSizePicker:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.presentedViewController) return;
    int cur = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"interfaceRenderH"];
    if (cur < 480 || cur > 600) cur = 540;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Interface size"
        message:@"Bigger UI shows the HUD (chat, minimap, inventory) larger but less of the world. Applies on next launch."
        preferredStyle:UIAlertControllerStyleActionSheet];
    // label -> renderH (smaller canvas = larger UI)
    NSArray *opts = @[@[@"Small", @600], @[@"Default", @540], @[@"Large", @480]];
    for (NSArray *o in opts) {
        int h = [o[1] intValue];
        NSString *title = [NSString stringWithFormat:@"%@%@", (h == cur ? @"✓ " : @""), o[0]];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            // The sheet's message already tells the user it applies on next launch — no second (nested) alert.
            [[NSUserDefaults standardUserDefaults] setInteger:h forKey:@"interfaceRenderH"];
            [self appendLine:[NSString stringWithFormat:@"[shell] interface size -> %@ (renderH %d), applies next launch", o[0], h]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.pluginButton;
    ac.popoverPresentationController.sourceRect = self.pluginButton.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

// Drain the shared-core outbound-link queue -> in-app SFSafariViewController. Wiki/HiScore/"open page" links land
// here (the sandbox has no system browser). One at a time; only http(s) is opened.
- (void)drainLinks {
    if (self.safariOpen) return;   // present one; the rest stay queued until it closes
    NSString *urlStr = [JVMLauncher mobileNextLink];
    if (urlStr.length == 0) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil || !([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) {
        [self appendLine:[NSString stringWithFormat:@"[shell] skipped non-web link: %@", urlStr]];
        return;
    }
    SFSafariViewController *sf = [[SFSafariViewController alloc] initWithURL:url];
    sf.delegate = self;
    sf.modalPresentationStyle = UIModalPresentationPageSheet;
    self.safariOpen = YES;
    [self presentViewController:sf animated:YES completion:nil];
    [self appendLine:[NSString stringWithFormat:@"[shell] open link: %@", url.absoluteString]];
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    self.safariOpen = NO;
}

// Show notification banners even while the app is foregrounded — the JVM suspends in the background, so a
// fired notification almost always lands while the game is on screen.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound
                      | UNNotificationPresentationOptionList);
}

// Save the live composited frame to Photos. The engine's auto-screenshots write to the sandbox dir (unreachable
// on a phone); this is the manual reachable path — native already holds the frame via latestFrame.
- (void)onScreenshot {
    UIImage *img = [JVMLauncher latestFrame];
    if (img == nil) {
        [self appendLine:@"[shell] screenshot: no frame yet"];
        [self showToast:@"Screenshot failed — no frame yet"];
        return;
    }
    // PERF-1: latestFrame's CGImage borrows a rotating scratch slot that the pump rewrites within a few
    // frames — fine for the immediate screen blit, NOT for the async Photos encode / a deferred pasteboard
    // paste. Redraw into an independent bitmap NOW so the saved bytes can't be overwritten mid-encode.
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:img.size];
    UIImage *stable = [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawAtPoint:CGPointZero];
    }];
    [self saveImageToRuneLiteAlbum:stable announce:YES];
    // SHOT-5: also copy to the clipboard, so it can be pasted straight into Messages / a notes app.
    [UIPasteboard generalPasteboard].image = stable;
}

// SHOT-6: save an image into a dedicated "RuneLite" Photos album (parity with Android's Pictures/RuneLite),
// creating the album on first use and caching its localIdentifier so later saves reuse it (no duplicate albums).
// All screenshot paths (manual capture + event auto-save) funnel through here. announce=YES surfaces a
// success/failure toast (manual capture); the silent auto-save path passes NO. Read-write authorization is
// required so the album can be fetched/reused; .denied/.limited/.restricted fall back to the failure path.
- (void)saveImageToRuneLiteAlbum:(UIImage *)image announce:(BOOL)announce {
    if (image == nil)
        return;
    PHPhotoLibrary *lib = [PHPhotoLibrary sharedPhotoLibrary];
    PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (st == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus granted) {
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           if (granted == PHAuthorizationStatusAuthorized || granted == PHAuthorizationStatusLimited) {
                                                               [self saveImageToRuneLiteAlbum:image announce:announce];
                                                           } else {
                                                               [self reportScreenshotSaved:NO permissionShaped:YES announce:announce];
                                                           }
                                                       });
                                                   }];
        return;
    }
    if (st != PHAuthorizationStatusAuthorized && st != PHAuthorizationStatusLimited) {
        [self reportScreenshotSaved:NO permissionShaped:YES announce:announce];
        return;
    }
    (void)lib;
    [self resolveRuneLiteAlbum:^(PHAssetCollection *album) {
        if (album == nil) {
            [self reportScreenshotSaved:NO permissionShaped:NO announce:announce];
            return;
        }
        [self addImage:image toAlbum:album announce:announce];
    }];
}

// Fetch (or create on first use) the "RuneLite" album, caching its localIdentifier in NSUserDefaults so the
// steady-state cost is a single fetch-by-identifier. If the user deleted the album the cached id resolves to
// nil and we recreate it cleanly. Calls back on the main queue with the collection (nil on failure).
- (void)resolveRuneLiteAlbum:(void (^)(PHAssetCollection *album))done {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *cachedId = [ud stringForKey:@"runeLiteAlbumId"];
    if (cachedId.length) {
        PHFetchResult *r = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[ cachedId ] options:nil];
        if (r.firstObject) {
            done(r.firstObject);
            return;
        }
    }
    // Not cached / deleted: look up by title before creating, so we never orphan a duplicate album.
    PHFetchOptions *opt = [[PHFetchOptions alloc] init];
    opt.predicate = [NSPredicate predicateWithFormat:@"title = %@", @"RuneLite"];
    PHFetchResult *byTitle = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                                      subtype:PHAssetCollectionSubtypeAny
                                                                      options:opt];
    if (byTitle.firstObject) {
        [ud setObject:((PHAssetCollection *)byTitle.firstObject).localIdentifier forKey:@"runeLiteAlbumId"];
        done(byTitle.firstObject);
        return;
    }
    __block NSString *placeholderId = nil;
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
            PHAssetCollectionChangeRequest *cr = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:@"RuneLite"];
            placeholderId = cr.placeholderForCreatedAssetCollection.localIdentifier;
        }
        completionHandler:^(BOOL success, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!success || placeholderId == nil) {
                    done(nil);
                    return;
                }
                PHFetchResult *r = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[ placeholderId ] options:nil];
                PHAssetCollection *created = r.firstObject;
                if (created)
                    [ud setObject:created.localIdentifier forKey:@"runeLiteAlbumId"];
                done(created);
            });
        }];
}

// Add the image to the general library and place the new asset into the RuneLite album, then report.
- (void)addImage:(UIImage *)image toAlbum:(PHAssetCollection *)album announce:(BOOL)announce {
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
            PHAssetChangeRequest *ar = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            PHAssetCollectionChangeRequest *cc = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
            [cc addAssets:@[ ar.placeholderForCreatedAsset ]];
        }
        completionHandler:^(BOOL success, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reportScreenshotSaved:success permissionShaped:NO announce:announce];
            });
        }];
}

// Log always; toast only for the manual capture (announce). permissionShaped steers a denied user to Settings.
- (void)reportScreenshotSaved:(BOOL)ok permissionShaped:(BOOL)permissionShaped announce:(BOOL)announce {
    [self appendLine:ok ? @"[shell] screenshot saved to RuneLite album"
                        : @"[shell] screenshot save failed"];
    if (!announce)
        return;
    if (ok) {
        [self showToast:@"Screenshot saved to RuneLite album"];
    } else {
        [self showToast:permissionShaped ? @"Screenshot failed — allow Photos access in Settings"
                                         : @"Screenshot save failed"];
    }
}

// Every edit is intercepted and forwarded as KeyEvents; the field itself never changes (return NO), so it
// always holds just the sentinel.
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (string.length > 0) {
        [JVMLauncher postText:string];
        // Length only — never the typed content (chat / PMs / search / enter-amount go through here).
        [self appendLine:[NSString stringWithFormat:@"[shell] key text len=%lu", (unsigned long)string.length]];
    } else if (range.length > 0) {
        for (NSUInteger i = 0; i < range.length; i++) {
            [JVMLauncher postKeyStroke:AWT_VK_BACK_SPACE];
        }
        [self appendLine:@"[shell] key backspace"];
    }
    return NO;   // keep the field at the sentinel — we only capture, never store
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [JVMLauncher postKeyStroke:AWT_VK_ENTER];
    [self appendLine:@"[shell] key enter"];
    return NO;   // keep the keyboard up for the next line
}

- (void)endBgTask {
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

#if TARGET_OS_SIMULATOR
#pragma mark - Simulator screen driver (ios/dev-tools/sim-screens/)

// Golden screenshots of the native screens, driven by a script. With -RMScreenDriver YES the display tick reads
// Documents/screen-cmd ("<seq> <screen>"). When seq changes it closes the screen it opened last, opens <screen> the
// way its button does, and logs "[screen] ready <seq> <screen>" once the screen has settled, or
// "[screen] failed <seq> <screen>: <why>". The script screenshots after "ready", then writes the next command;
// "<seq> -" only closes. -RMBlankGame YES covers the game picture (not the native chrome on it), so a golden
// compares native UI only. Screens: see simOpenScreen (settings, plugins, plugins:<search>, panel:<tooltip>,
// config:<plugin>, ...).
//
// Just before "ready" it also logs "[screen] info <seq> <json>": what the screen shows (simScreenInfo), which the
// plugin sweep (sim-screens/plugin-sweep.py) uses to tell a blank screen from a full one without a golden per
// plugin. Three commands open nothing:
//   inventory  writes Documents/screen-inventory.json, the plugin list and the rail's panels, for the sweep to walk;
//   prepare    applies Documents/screen-prepare.json, {"enable": [plugin class names], "disable": [plugin class
//              names], "config": [[group, key, value]]}, so panels this config hides (a plugin switched off, a
//              button only shown in one place) get swept too, or a capture shows the game without a plugin. It
//              first saves what it changes to screen-restore.json;
//   restore    puts that back. The next simulator launch does too, if a sweep died before it got there;
//   report     writes the "Share logs" report (RMDiagnostics reportText) to Documents/screen-report.txt, for
//              ios/dev-tools/diagnostics/sim-report-check.py and sim-heat-check.py.
//   heat       stands in for the phone's thermal state and Low Power Mode, for sim-heat-check.py.
//   hd-scale   moves 117HD's resolution setting the way its slider does, likewise.
//   fps-cap    sets the frame-rate cap the way Game settings does, likewise.
//   config-flush saves the config now, likewise.

static NSString *simScreenSeq;    // the last command's seq
static NSString *simScreenOpened; // "<seq> <screen>" opened and not yet reported ready
static CFTimeInterval simScreenOpenedAt;
static CFTimeInterval simScreenNextPoll;
static UIView *simBlankView;
// A rendered side panel draws its first frame some time after it opens. Wait this long for it before reporting
// ready anyway, so a panel that never draws shows up as blank instead of as a hang.
static const CFTimeInterval kSimPanelFrameWait = 10.0;
// prepare and restore answer once the plugins they switched read back as started or stopped (on the EDT), their
// settings writes have run (on the client thread) and a config flush queued behind those has written the profile.
// They give up after this long and report what is still pending.
static const CFTimeInterval kSimConfirmTimeout = 15.0;

- (void)simScreenTick {
    static BOOL driver, blank;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        driver = [ud boolForKey:@"RMScreenDriver"];
        blank = [ud boolForKey:@"RMBlankGame"];
    });
    if (blank)
        [self simBlankGame];
    CFTimeInterval now = CACurrentMediaTime();
    [self simRestoreAtLaunch:now];
    if (!driver)
        return;
    if (simScreenOpened) {
        // Settled: past the open animations and nothing presenting or dismissing. A close ("-") animates nothing.
        UIViewController *p = self.presentedViewController;
        CFTimeInterval minSettle = [simScreenOpened hasSuffix:@" -"] ? 0.1 : 0.6;
        if (now - simScreenOpenedAt < minSettle || self.transitionCoordinator || p.isBeingPresented ||
            p.isBeingDismissed)
            return;
        if ([self.panelDock simPanelLoading] && now - simScreenOpenedAt < kSimPanelFrameWait)
            return;
        NSString *seq = [simScreenOpened componentsSeparatedByString:@" "].firstObject;
        NSData *info = [NSJSONSerialization dataWithJSONObject:[self simScreenInfo] options:0 error:NULL];
        if (info)
            [self appendLine:[NSString stringWithFormat:@"[screen] info %@ %@", seq,
                                                        [[NSString alloc] initWithData:info
                                                                              encoding:NSUTF8StringEncoding]]];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@", simScreenOpened]];
        simScreenOpened = nil;
        return;
    }
    if (now < simScreenNextPoll)
        return;
    simScreenNextPoll = now + 0.1;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *cmd = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"screen-cmd"]
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    cmd = [cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // No file yet: check before rangeOfString:, which on a nil string returns {0, 0}, not NSNotFound.
    if (!cmd.length)
        return;
    NSRange sp = [cmd rangeOfString:@" "];
    if (sp.location == NSNotFound)
        return;
    NSString *seq = [cmd substringToIndex:sp.location];
    if ([seq isEqualToString:simScreenSeq])
        return;
    simScreenSeq = seq;
    NSString *name = [cmd substringFromIndex:sp.location + 1];
    // "orient landscape|portrait|auto": set Settings > Game settings > Screen as its control does, so a run can turn
    // the window and watch the canvas follow. A script can't turn the simulated device itself.
    if ([name hasPrefix:@"orient "]) {
        NSString *to = [name substringFromIndex:7];
        if ([to isEqualToString:@"auto"]) {
            [RMGameSettings setAutoRotate:YES];
        } else {
            [RMGameSettings setPortrait:[to isEqualToString:@"portrait"]];
            [RMGameSettings setAutoRotate:NO];
        }
        [RMGameSettings applyOrientationToWindow:self.view.window];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "heat <thermal> [<lowPower>]": stand in for the phone's readings (see simHeatThermal): a thermal state from 0 to
    // 3 and 0 or 1 for Low Power Mode. -1, or leaving Low Power Mode off the line, uses the real reading.
    if ([name hasPrefix:@"heat "]) {
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@" "];
        simHeatThermal = parts[1].intValue;
        simHeatLowPower = parts.count > 2 ? parts[2].intValue : -1;
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "heat-notice": put the hot-phone notice up now, whatever the renderer and the phone's heat, so a capture can
    // show it over the game. It counts as this launch's notice, as a real one would. "heat-notice -" takes it down.
    if ([name isEqualToString:@"heat-notice"] || [name isEqualToString:@"heat-notice -"]) {
        if ([name hasSuffix:@"-"])
            [self hideHeatNotice:@"driver"];
        else if (!self.heatNotice)
            [self showHeatNotice];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "heat-lower <0|1>": Game settings > Lower resolution when hot, as its switch sets it.
    if ([name hasPrefix:@"heat-lower "]) {
        [RMGameSettings setHeatLowerResolution:[name substringFromIndex:11].intValue != 0];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "config-flush": save the config, as the app does on its way to the background.
    if ([name isEqualToString:@"config-flush"]) {
        [JVMLauncher mobileFlushConfig];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "hd-scale <percent>": move 117HD's resolution setting the way its slider does.
    if ([name hasPrefix:@"hd-scale "]) {
        [JVMLauncher mobileSetConfigGroup:@"hd" key:@"sceneResolutionScale" value:[name substringFromIndex:9]];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "fps-cap <fps>": set the frame-rate cap the way Game settings does, 0 for none.
    if ([name hasPrefix:@"fps-cap "]) {
        [JVMLauncher setFpsCap:[name substringFromIndex:8].intValue];
        [self appendLine:[NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    // "game <verb> ...": play through the same handlers a finger uses, so a script can set a scene up for a capture.
    // Points are the game view's, in pt.
    if ([name hasPrefix:@"game "]) {
        NSString *input = [name substringFromIndex:5];
        NSString *why = [self simGameInput:input];
        if (!why && [input hasPrefix:@"hold "]) {
            // The engine builds the menu on a later frame: answer once it is open, or a pick sent next finds none.
            [self simAnswerOnceMenuOpens:seq name:name tries:30];
            return;
        }
        [self appendLine:why ? [NSString stringWithFormat:@"[screen] failed %@ %@: %@", seq, name, why]
                             : [NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        return;
    }
    __weak typeof(self) ws = self;
    if ([name isEqualToString:@"inventory"] || [name isEqualToString:@"prepare"] ||
        [name isEqualToString:@"restore"] || [name isEqualToString:@"report"]) {
        void (^answer)(NSString *) = ^(NSString *why) {
            [ws appendLine:why ? [NSString stringWithFormat:@"[screen] failed %@ %@: %@", seq, name, why]
                               : [NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]];
        };
        if ([name isEqualToString:@"inventory"])
            answer([self simWriteInventory:[docs stringByAppendingPathComponent:@"screen-inventory.json"]]);
        else if ([name isEqualToString:@"prepare"])
            [self simPrepare:docs then:answer];
        else if ([name isEqualToString:@"report"]) {
            // Built off the main thread, as the Share logs button does: it waits for the engine.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *text = [RMDiagnostics reportText];
                BOOL ok = [text writeToFile:[docs stringByAppendingPathComponent:@"screen-report.txt"]
                                 atomically:YES
                                   encoding:NSUTF8StringEncoding
                                      error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    answer(ok ? nil : @"couldn't write screen-report.txt");
                });
            });
        } else
            [self simRestore:[docs stringByAppendingPathComponent:@"screen-restore.json"] then:answer];
        return;
    }
    [self simCloseScreenThen:^{
        NSString *why = [name isEqualToString:@"-"] ? nil : [ws simOpenScreen:name];
        if (why) {
            [ws appendLine:[NSString stringWithFormat:@"[screen] failed %@ %@: %@", seq, name, why]];
            return;
        }
        simScreenOpened = [NSString stringWithFormat:@"%@ %@", seq, name];
        simScreenOpenedAt = CACurrentMediaTime();
    }];
}

// Logs ready for a "game hold" once its menu's rows are built, checking every 0.1 s, or failed after `tries`
// checks. (menuOpen alone won't do: the press sets it before the engine has built the menu.)
- (void)simAnswerOnceMenuOpens:(NSString *)seq name:(NSString *)name tries:(int)tries {
    BOOL built = self.menuOpen && !self.menuBuilding && self.menuContainer;
    if (!self.menuOpen || !self.menuBuilding || tries <= 0) { // built, closed, or the build gave up (0.6 s)
        [self appendLine:built ? [NSString stringWithFormat:@"[screen] ready %@ %@", seq, name]
                               : [NSString stringWithFormat:@"[screen] failed %@ %@: no menu opened", seq, name]];
        return;
    }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws simAnswerOnceMenuOpens:seq name:name tries:tries - 1];
    });
}

// The "game" driver verbs. Returns why one didn't run, or nil.
//   tap X Y       a tap there, routed as a finger's is (worldTapAtScreenPoint:)
//   hold X Y      a long press there: answers once the right-click menu is open, so a pick can follow
//   pick TEXT     choose the open menu's first row whose option and target contain TEXT (any case); in a tap
//                 list a submenu's parent row opens it, so pick again to choose inside
//   camera DX DY  turn the camera as a two-finger drag of that many px does
//   zoom N        N wheel notches at the middle of the game (negative zooms in)
//   key CODE      one AWT key stroke (27 = Escape)
//   text WORDS    type the words
//   unhover       take the pointer off the game, so no hover tooltip is left showing
//   button LABEL  press the shown native control with that accessibility label (or segment with that title)
- (NSString *)simGameInput:(NSString *)input {
    if (![JVMLauncher bridgeReady])
        return @"the bridge isn't up";
    NSArray<NSString *> *w = [input componentsSeparatedByString:@" "];
    NSString *verb = w.firstObject;
    NSString *rest = w.count > 1 ? [input substringFromIndex:verb.length + 1] : @"";
    CGPoint p = w.count == 3 ? CGPointMake(w[1].doubleValue, w[2].doubleValue) : CGPointZero;
    if ([verb isEqualToString:@"tap"] && w.count == 3) {
        [self worldTapAtScreenPoint:p];
        return nil;
    }
    if ([verb isEqualToString:@"hold"] && w.count == 3) {
        int gx = 0, gy = 0;
        if (![self mapPoint:p toGameX:&gx toGameY:&gy])
            return @"that point is off the game";
        [JVMLauncher postCancelArmedTap];
        [self openEngineMenuAtGameX:gx gameY:gy anchor:p];
        return nil;
    }
    if ([verb isEqualToString:@"pick"] && rest.length) {
        if (!self.menuOpen || !self.menuContainer)
            return @"no menu is open";
        NSString *want = rest.lowercaseString;
        if (self.menuTapMode) {
            // The tap list (submenus, or too many rows to drag): press the shown row as a finger would. A parent
            // row opens its submenu, so a second pick chooses inside it.
            for (UIView *v in self.menuRows) {
                if (![v isKindOfClass:[UIButton class]])
                    continue;
                NSString *row = ((UIButton *)v).currentAttributedTitle.string ?: @"";
                row = [row stringByReplacingOccurrencesOfString:@"<[^>]*>"
                                                     withString:@""
                                                        options:NSRegularExpressionSearch
                                                          range:NSMakeRange(0, row.length)];
                if ([row.lowercaseString rangeOfString:want].location != NSNotFound) {
                    [self onTapMenuRow:(UIButton *)v];
                    return nil;
                }
            }
            return @"no row has that text";
        }
        if (!self.menuGeomValid)
            return @"no menu is open";
        for (NSInteger k = 0; k < (NSInteger)self.menuRowEntries.count; k++) {
            NSDictionary *e = [self.menuRowEntries[k] isKindOfClass:[NSDictionary class]] ? self.menuRowEntries[k] : @{};
            NSString *row = [NSString stringWithFormat:@"%@ %@", e[@"opt"] ?: @"", e[@"tgt"] ?: @""];
            row = [row stringByReplacingOccurrencesOfString:@"<[^>]*>"
                                                 withString:@""
                                                    options:NSRegularExpressionSearch
                                                      range:NSMakeRange(0, row.length)];
            if ([row.lowercaseString rangeOfString:want].location == NSNotFound)
                continue;
            // The engine row's centre, as a drag over the native row reports it (updateNativeMenuHighlight:).
            CGRect r = self.menuGeomGame;
            self.menuSelX = (int)lround(CGRectGetMidX(r));
            self.menuSelY = (int)CGRectGetMinY(r) + kMenuHeaderPx + (int)k * kMenuRowPx + kMenuRowPx / 2;
            self.menuFingerOnMenu = YES;
            [self commitMenuSelection];
            return nil;
        }
        return @"no row has that text";
    }
    if ([verb isEqualToString:@"camera"] && w.count == 3) {
        [JVMLauncher postCameraDx:w[1].intValue dy:w[2].intValue];
        return nil;
    }
    if ([verb isEqualToString:@"zoom"] && w.count == 2) {
        int gx = 0, gy = 0;
        CGRect b = self.screen.bounds;
        if (![self mapPoint:CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)) toGameX:&gx toGameY:&gy])
            return @"no game picture";
        [JVMLauncher postWheelX:gx y:gy rotation:w[1].intValue];
        return nil;
    }
    if ([verb isEqualToString:@"key"] && w.count == 2) {
        [JVMLauncher postKeyStroke:w[1].intValue];
        return nil;
    }
    if ([verb isEqualToString:@"unhover"]) {
        [JVMLauncher postClearHover];
        return nil;
    }
    if ([verb isEqualToString:@"button"] && rest.length) {
        // A native control anywhere in the window (a presented panel too), frontmost first, by its accessibility
        // label, or a segment of a segmented control by its title. A tap on one never reaches the game.
        // (Not self.view.window: a full-screen presentation takes this view out of the window.)
        UIView *root = [UIApplication sharedApplication].delegate.window ?: self.view;
        NSMutableArray<UIView *> *todo = [NSMutableArray arrayWithObject:root];
        while (todo.count) {
            UIView *v = todo.lastObject;
            [todo removeLastObject];
            if (v.hidden || v.alpha < 0.01)
                continue;
            if ([v isKindOfClass:[UISegmentedControl class]] && v.userInteractionEnabled) {
                UISegmentedControl *seg = (UISegmentedControl *)v;
                for (NSUInteger i = 0; i < seg.numberOfSegments; i++) {
                    NSString *title = [seg titleForSegmentAtIndex:i]; // nil for an image segment
                    if (title && [title caseInsensitiveCompare:rest] == NSOrderedSame) {
                        seg.selectedSegmentIndex = (NSInteger)i;
                        [seg sendActionsForControlEvents:UIControlEventValueChanged];
                        return nil;
                    }
                }
            }
            // (A nil label must not match: a compare sent to nil answers 0, which is NSOrderedSame.)
            if ([v isKindOfClass:[UIControl class]] && v.userInteractionEnabled && v.accessibilityLabel &&
                [v.accessibilityLabel caseInsensitiveCompare:rest] == NSOrderedSame) {
                [self appendLine:[NSString stringWithFormat:@"[screen] pressing %@ at %@", NSStringFromClass(v.class),
                                                            NSStringFromCGRect([v convertRect:v.bounds
                                                                                       toView:self.view])]];
                [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
                return nil;
            }
            [todo addObjectsFromArray:v.subviews];
        }
        return @"no shown control has that label";
    }
    if ([verb isEqualToString:@"text"] && rest.length) {
        [JVMLauncher postText:rest];
        return nil;
    }
    return @"unknown game verb";
}

// Opens a screen through the same entry point as its button. Returns why it didn't open, or nil.
- (NSString *)simOpenScreen:(NSString *)name {
    if ([name isEqualToString:@"settings"])
        [self onOpenSettings];
    else if ([name isEqualToString:@"game-settings"]) {
        [self onOpenSettings];
        UINavigationController *nav = (UINavigationController *)self.presentedViewController;
        [nav pushViewController:[[RMGameSettingsViewController alloc] init] animated:NO];
    } else if ([name isEqualToString:@"about"])
        [self onOpenAbout];
    else if ([name isEqualToString:@"hub"])
        [self onOpenHub];
    else if ([name isEqualToString:@"plugins"] || [name hasPrefix:@"plugins:"]) {
        // "plugins:<text>" types <text> into the list's search. The search outlives the panel, so plain "plugins"
        // clears what is left in it and always opens the whole list. With nothing to clear it opens the list
        // exactly as the button does.
        [self onOpenPluginPanel];
        NSString *q = [name hasPrefix:@"plugins:"] ? [name substringFromIndex:8] : @"";
        if (q.length || self.pluginSearch.text.length) {
            self.pluginSearch.text = q;
            [self searchBar:self.pluginSearch textDidChange:q];
        }
    } else if ([name isEqualToString:@"edit-controls"])
        [self onEditControls];
    else if ([name isEqualToString:@"overlays"])
        [self onOpenOverlayEdit];
    else if ([name isEqualToString:@"profiles"])
        [self.panelDock presentConfigProfiles];
    else if ([name isEqualToString:@"infoboxes"])
        [self.panelDock presentInfoboxes];
    else if ([name hasPrefix:@"panel:"]) {
        if (![self.panelDock simOpenPanelNamed:[name substringFromIndex:6]])
            return @"no panel with that name on the rail";
    } else if ([name hasPrefix:@"config:"]) {
        NSString *why = [self simOpenConfigFor:[name substringFromIndex:7]];
        if (why)
            return why;
    } else if ([name hasPrefix:@"tab:"]) {
        // "tab:<engine tab index>" taps that stone of the grid (10 = the logout door), "tab:expand" the expand stone.
        NSString *t = [name substringFromIndex:4];
        if ([t isEqualToString:@"expand"]) {
            [self onTabExpand];
            return nil;
        }
        int i = t.intValue;
        if (i < 0 || i >= (int)self.tabButtons.count || self.tabButtons[i].hidden)
            return @"that tab isn't shown";
        [self onTabButton:self.tabButtons[i]];
        return nil;
    } else if ([name isEqualToString:@"chat:toggle"]) {
        // The speech bubbles by the door: put the chat away, or bring it back.
        if (self.chatToggleButton.hidden)
            return @"the chat column isn't shown";
        [self onChatToggle];
        return nil;
    } else
        return @"unknown screen";
    BOOL open = self.presentedViewController || self.panelDock.presentedViewController || self.pluginPanelOpen ||
                self.editOverlay || self.overlayEdit || [self.panelDock simPanelOpen];
    return open ? nil : @"nothing opened (not available in this state?)";
}

- (void)simCloseScreenThen:(void (^)(void))next {
    if (self.pluginPanelOpen)
        [self onClosePluginPanel];
    if (self.editOverlay)
        [self onEditControlsDone];
    if (self.overlayEdit) {
        [self.overlayEdit dismiss];
        self.overlayEdit = nil;
    }
    [self.panelDock simClosePanel];
    UIViewController *p = self.presentedViewController ?: self.panelDock.presentedViewController;
    if (p)
        [p.presentingViewController dismissViewControllerAnimated:NO completion:next];
    else
        next();
}

static BOOL simIsSetting(id c) {
    return [c isKindOfClass:[NSArray class]] && [c count] == 3 && [c[0] isKindOfClass:[NSString class]] &&
           [c[1] isKindOfClass:[NSString class]] && [c[2] isKindOfClass:[NSString class]];
}

// Why a plugin in `expect` (class name -> on) doesn't read back switched that way and started or stopped, or nil.
static NSString *simPluginsPending(NSDictionary<NSString *, NSNumber *> *expect) {
    if (!expect.count)
        return nil;
    NSString *json = [JVMLauncher mobilePlugins];
    id plugins = json.length ? parseBridgeJSON(json, "ViewController.simPluginsPending") : nil;
    if (![plugins isKindOfClass:[NSArray class]])
        return @"listPlugins returned no list";
    for (NSString *cls in expect) {
        BOOL on = [expect[cls] boolValue];
        NSDictionary *row = nil;
        for (NSDictionary *p in plugins)
            if ([[p[@"className"] description] isEqualToString:cls])
                row = p;
        if (!row)
            return [NSString stringWithFormat:@"%@ isn't in the plugin list", cls];
        if ([row[@"enabled"] boolValue] != on || [row[@"active"] boolValue] != on)
            return [NSString stringWithFormat:@"%@ hasn't %@", row[@"name"], on ? @"started" : @"stopped"];
    }
    return nil;
}

// Asks pending() every 0.2 s until it returns nil, then calls done(nil); after kSimConfirmTimeout, done(what it
// last said is still pending).
- (void)simWaitFor:(NSString * (^)(void))pending since:(CFTimeInterval)start then:(void (^)(NSString *why))done {
    NSString *what = pending();
    if (!what || CACurrentMediaTime() - start > kSimConfirmTimeout) {
        done(what ? [NSString stringWithFormat:@"%@ after %.0f s", what, kSimConfirmTimeout] : nil);
        return;
    }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws simWaitFor:pending since:start then:done];
    });
}

// Switches each plugin in `enable` (class name -> on) and writes each [group, key, value] in `config`. Notes in
// `expect` how each plugin should read back and in *writeId the last settings write to wait for.
- (NSString *)simApplyPlugins:(NSDictionary *)enable
                       config:(NSArray *)config
                       expect:(NSMutableDictionary *)expect
                      writeId:(long long *)writeId {
    for (NSString *cls in enable) {
        NSString *json = [JVMLauncher mobileSetPluginEnabled:cls enabled:[enable[cls] boolValue]];
        NSDictionary *r = json.length ? parseBridgeJSON(json, "ViewController.simApplyPlugins") : nil;
        if (![r isKindOfClass:[NSDictionary class]] || ![r[@"ok"] boolValue])
            return [NSString stringWithFormat:@"couldn't switch %@: %@", cls, json ?: @"no answer"];
        expect[cls] = enable[cls];
    }
    for (NSArray *c in config) {
        NSString *json = [JVMLauncher mobileSetConfigGroup:c[0] key:c[1] value:c[2]];
        NSDictionary *r = json.length ? parseBridgeJSON(json, "ViewController.simApplyPlugins") : nil;
        if (![r isKindOfClass:[NSDictionary class]] || ![r[@"ok"] boolValue])
            return [NSString stringWithFormat:@"couldn't set %@.%@: %@", c[0], c[1], json ?: @"no answer"];
        *writeId = MAX(*writeId, [r[@"writeId"] longLongValue]);
    }
    return nil;
}

// Waits until the plugins in `expect` read back the way they were switched and the settings writes up to `writeId`
// have run, then queues a config flush behind them and waits for that too, so the change is in the profile on disk
// when done(nil) runs. Both waits share one kSimConfirmTimeout, well inside the sweep's own wait for an answer.
- (void)simConfirm:(NSDictionary *)expect writeId:(long long)writeId then:(void (^)(NSString *why))done {
    __weak typeof(self) ws = self;
    CFTimeInterval start = CACurrentMediaTime();
    NSString * (^applied)(void) = ^NSString * {
        if ([JVMLauncher mobileProcessedWriteId] < writeId)
            return @"the settings writes haven't run";
        return simPluginsPending(expect);
    };
    void (^flush)(NSString *) = ^(NSString *why) {
        long long flushId = why ? 0 : [JVMLauncher mobileFlushConfig];
        if (!flushId) {
            done(why ?: @"couldn't queue the config flush");
            return;
        }
        NSString * (^flushed)(void) = ^NSString * {
            return [JVMLauncher mobileProcessedWriteId] < flushId ? @"the config flush hasn't run" : nil;
        };
        [ws simWaitFor:flushed since:start then:done];
    };
    [self simWaitFor:applied since:start then:flush];
}

// "prepare": switch the plugins on or off and change the settings screen-prepare.json names, after saving what each was to
// screen-restore.json. Only what actually changes is saved, so a restore touches nothing else. A setting with no
// stored value is refused: the bridge can only write a value, so a restore couldn't make it unset again. RuneLite
// stores every plugin's defaults when it starts, so only an item without a default has none.
- (void)simPrepare:(NSString *)docs then:(void (^)(NSString *why))done {
    NSMutableDictionary *expect = [NSMutableDictionary dictionary];
    long long writeId = 0;
    NSString *why = [self simPrepareApply:docs expect:expect writeId:&writeId];
    if (why) {
        done(why);
        return;
    }
    [self simConfirm:expect writeId:writeId then:done];
}

- (NSString *)simPrepareApply:(NSString *)docs expect:(NSMutableDictionary *)expect writeId:(long long *)writeId {
    NSString *restorePath = [docs stringByAppendingPathComponent:@"screen-restore.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:restorePath])
        return @"screen-restore.json from an earlier sweep is still there; send restore first";
    NSData *d = [NSData dataWithContentsOfFile:[docs stringByAppendingPathComponent:@"screen-prepare.json"]];
    NSDictionary *want = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if (![want isKindOfClass:[NSDictionary class]])
        return @"no readable screen-prepare.json";
    NSString *json = [JVMLauncher mobilePlugins];
    id plugins = json.length ? parseBridgeJSON(json, "ViewController.simPrepare") : nil;
    if (![plugins isKindOfClass:[NSArray class]])
        return @"listPlugins returned no list";
    NSMutableDictionary *wasEnabled = [NSMutableDictionary dictionary];
    for (NSString *cls in want[@"enable"]) {
        for (NSDictionary *p in plugins) {
            if ([[p[@"className"] description] isEqualToString:cls] && ![p[@"enabled"] boolValue])
                wasEnabled[cls] = @NO;
        }
    }
    for (NSString *cls in want[@"disable"]) {
        for (NSDictionary *p in plugins) {
            if ([[p[@"className"] description] isEqualToString:cls] && [p[@"enabled"] boolValue])
                wasEnabled[cls] = @YES;
        }
    }
    NSMutableArray *wasConfig = [NSMutableArray array];
    for (NSArray *c in want[@"config"]) {
        if (!simIsSetting(c))
            return @"a config entry isn't [group, key, value], all strings";
        NSString *cfg = [JVMLauncher mobilePluginConfig:c[0]];
        NSDictionary *desc = cfg.length ? parseBridgeJSON(cfg, "ViewController.simPrepare") : nil;
        NSDictionary *item = nil;
        for (NSDictionary *it in ([desc isKindOfClass:[NSDictionary class]] ? desc[@"items"] : nil))
            if ([it[@"key"] isEqual:c[1]])
                item = it;
        if (!item)
            return [NSString stringWithFormat:@"no setting %@.%@", c[0], c[1]];
        if (![item[@"value"] isKindOfClass:[NSString class]])
            return [NSString stringWithFormat:@"%@.%@ has no stored value, so a restore couldn't put it back", c[0], c[1]];
        if (![item[@"value"] isEqual:c[2]])
            [wasConfig addObject:@[ c[0], c[1], item[@"value"] ]];
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:@{@"enable" : wasEnabled, @"config" : wasConfig}
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:NULL];
    if (![out writeToFile:restorePath atomically:YES])
        return @"couldn't write screen-restore.json";
    NSMutableDictionary *enable = [NSMutableDictionary dictionary];
    for (NSString *cls in wasEnabled)
        enable[cls] = @(![wasEnabled[cls] boolValue]);
    // Whatever this gets through before a failure is in screen-restore.json, so a restore puts it back.
    NSString *why = [self simApplyPlugins:enable config:want[@"config"] expect:expect writeId:writeId];
    if (why)
        return why;
    [self appendLine:[NSString stringWithFormat:@"[screen] prepare: switched %lu plugin(s), changed %lu setting(s)",
                                                (unsigned long)wasEnabled.count, (unsigned long)wasConfig.count]];
    return nil;
}

// "restore": put back what prepare saved in screen-restore.json. The file is deleted only once the old values are in
// the profile on disk, so a restore that fails or is cut short leaves it for the next one.
- (void)simRestore:(NSString *)path then:(void (^)(NSString *why))done {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        done(nil);
        return;
    }
    NSData *d = [NSData dataWithContentsOfFile:path];
    NSDictionary *was = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    NSDictionary *enable = [was isKindOfClass:[NSDictionary class]] ? was[@"enable"] : nil;
    NSArray *config = [was isKindOfClass:[NSDictionary class]] ? was[@"config"] : nil;
    BOOL ok = [enable isKindOfClass:[NSDictionary class]] && [config isKindOfClass:[NSArray class]];
    for (id cls in ok ? enable : nil)
        ok = ok && [cls isKindOfClass:[NSString class]] && [enable[cls] isKindOfClass:[NSNumber class]];
    for (id c in ok ? config : nil)
        ok = ok && simIsSetting(c);
    if (!ok) {
        done(@"screen-restore.json isn't what prepare writes; it is left in place");
        return;
    }
    NSMutableDictionary *expect = [NSMutableDictionary dictionary];
    long long writeId = 0;
    NSString *why = [self simApplyPlugins:enable config:config expect:expect writeId:&writeId];
    if (why) {
        done(why);
        return;
    }
    __weak typeof(self) ws = self;
    [self simConfirm:expect
             writeId:writeId
                then:^(NSString *problem) {
                    if (!problem) {
                        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                        [ws appendLine:[NSString stringWithFormat:@"[screen] restore: %lu plugin(s), %lu setting(s)",
                                                                  (unsigned long)enable.count,
                                                                  (unsigned long)config.count]];
                    }
                    done(problem);
                }];
}

// A sweep that died between prepare and restore leaves screen-restore.json behind. Every simulator launch, driven or
// not, restores it once the plugins have started (the rail has filled in), so the config never stays the way a
// sweep left it.
- (void)simRestoreAtLaunch:(CFTimeInterval)now {
    static BOOL done;
    static CFTimeInterval nextCheck;
    if (done || now < nextCheck)
        return;
    nextCheck = now + 1.0;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"screen-restore.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        done = YES;
        return;
    }
    if (![self.panelDock simPanelNames].count)
        return;
    done = YES;
    [self appendLine:@"[screen] an earlier sweep didn't restore its changes; restoring them now"];
    __weak typeof(self) ws = self;
    [self simRestore:path
                then:^(NSString *why) {
                    if (why)
                        [ws appendLine:[NSString stringWithFormat:@"[screen] the restore at launch failed: %@", why]];
                }];
}

// "config:<plugin>": open the plugin list, then that row's settings the way a tap on its gear does (or, for the
// config-only RuneLite and Chat Color rows, a tap on the row).
- (NSString *)simOpenConfigFor:(NSString *)pluginName {
    [self onOpenPluginPanel];
    NSDictionary *row = nil;
    for (NSDictionary *p in self.pluginAll) {
        if (![[p[@"name"] description] isEqualToString:pluginName])
            continue;
        if (row)
            return @"two plugins have that name";
        row = p;
    }
    if (!row)
        return @"no plugin with that name in the list";
    if (![row[@"hasConfig"] boolValue])
        return @"the plugin has no settings";
    if ([row[@"configOnly"] boolValue])
        [self openPluginConfigForRow:row];
    else
        [self presentConfigEditorForPlugin:row];
    return [self.presentedViewController isKindOfClass:[PluginConfigViewController class]]
               ? nil
               : @"the settings screen didn't open";
}

// The plugin list (listPlugins, as the plugin panel reads it) and the rail's panels, in the order they show.
- (NSString *)simWriteInventory:(NSString *)path {
    NSString *json = [JVMLauncher mobilePlugins];
    id plugins = json.length ? parseBridgeJSON(json, "ViewController.simWriteInventory") : nil;
    if (![plugins isKindOfClass:[NSArray class]])
        return @"listPlugins returned no list";
    NSDictionary *inv = @{@"plugins" : plugins, @"panels" : [self.panelDock simPanelNames]};
    NSData *out = [NSJSONSerialization dataWithJSONObject:inv options:NSJSONWritingPrettyPrinted error:NULL];
    return [out writeToFile:path atomically:YES] ? nil : @"couldn't write screen-inventory.json";
}

// Counts what a screen shows, for the sweep's blank check: views with text, table and collection cells, and image
// views holding an image. Only what is on screen counts: hidden and transparent views and anything scrolled out of
// the window are skipped.
static void simCensus(UIView *v, CGRect win, NSUInteger *texts, NSUInteger *cells, NSUInteger *images) {
    if (v.hidden || v.alpha < 0.01)
        return;
    if (CGRectIsEmpty(CGRectIntersection([v convertRect:v.bounds toView:nil], win)))
        return;
    if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length)
        (*texts)++;
    else if ([v isKindOfClass:[UITextView class]] && ((UITextView *)v).text.length)
        (*texts)++;
    else if ([v isKindOfClass:[UITextField class]] &&
             (((UITextField *)v).text.length || ((UITextField *)v).placeholder.length))
        (*texts)++;
    else if ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image)
        (*images)++;
    if ([v isKindOfClass:[UITableViewCell class]] || [v isKindOfClass:[UICollectionViewCell class]])
        (*cells)++;
    for (UIView *s in v.subviews)
        simCensus(s, win, texts, cells, images);
}

static NSArray<NSNumber *> *simRectArray(CGRect r) {
    return @[ @(round(r.origin.x)), @(round(r.origin.y)), @(round(r.size.width)), @(round(r.size.height)) ];
}

// What the open screen shows: which screen it is ("screen"), the census of its views, the window size in points
// and the rect ("rect", window points) where its content goes, plus what the screen itself knows (a settings
// screen's item count, a rendered panel's frame).
- (NSDictionary *)simScreenInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    UIViewController *top = nil;
    for (UIViewController *p = self.presentedViewController ?: self.panelDock.presentedViewController; p;
         p = p.presentedViewController)
        top = p;
    UIView *root = nil;
    if (top) {
        info[@"screen"] = NSStringFromClass([top class]);
        root = top.view;
        if ([top isKindOfClass:[PluginConfigViewController class]])
            [info addEntriesFromDictionary:[(PluginConfigViewController *)top simSummary]];
    } else if ([self.panelDock simPanelOpen]) {
        info[@"screen"] = @"rendered-panel";
        [info addEntriesFromDictionary:[self.panelDock simPanelInfo]];
        root = self.panelDock.view;
    } else if (self.pluginPanelOpen) {
        info[@"screen"] = @"plugin-list";
        root = self.pluginPanel;
    } else if (self.overlayEdit || self.editOverlay) {
        info[@"screen"] = self.overlayEdit ? @"overlay-edit" : @"edit-controls";
        root = self.overlayEdit ?: self.editOverlay;
    } else {
        info[@"screen"] = @"none";
    }
    // A full-screen modal takes this controller's view out of the window while it is up, so ask the screen's own.
    UIWindow *window = self.view.window;
    if (!window)
        window = top.view.window ?: root.window;
    CGRect win = window.bounds;
    info[@"window"] = @[ @(win.size.width), @(win.size.height) ];
    if (root) {
        if (!info[@"rect"])
            info[@"rect"] = simRectArray([root convertRect:root.bounds toView:nil]);
        NSUInteger texts = 0, cells = 0, images = 0;
        simCensus(root, win, &texts, &cells, &images);
        info[@"texts"] = @(texts);
        info[@"cells"] = @(cells);
        info[@"images"] = @(images);
    }
    return info;
}

// The game's own layers (the PiP presenter, the GL layers) go in at index 0 of the screen's layer, under its
// subviews, and can arrive after this cover does, so keep the cover above the topmost of them on every tick.
- (void)simBlankGame {
    if (!simBlankView) {
        simBlankView = [[UIView alloc] initWithFrame:self.screen.bounds];
        simBlankView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        simBlankView.backgroundColor = self.screen.backgroundColor;
        simBlankView.userInteractionEnabled = NO;
        [self.screen insertSubview:simBlankView atIndex:0];
    }
    NSArray<CALayer *> *layers = self.screen.layer.sublayers;
    CALayer *game = nil;
    for (CALayer *l in layers)
        if (![l.delegate isKindOfClass:[UIView class]])
            game = l;
    if (game && [layers indexOfObject:game] > [layers indexOfObject:simBlankView.layer])
        [self.screen.layer insertSublayer:simBlankView.layer above:game];
}
#endif

@end
