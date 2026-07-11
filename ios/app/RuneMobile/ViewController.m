#import "ViewController.h"
#import "JVMLauncher.h"
#import "PluginConfigViewController.h"
#import "PluginHubViewController.h"
#import "PluginPanelsViewController.h"
#import "OverlayEditView.h"
#import "JagexLoginViewController.h"
#import "GLRecon.h"
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
#import <unistd.h>
#import <fcntl.h>
#import <os/lock.h>            // os_unfair_lock — guards the JSON-fault rate-limiter (QA-SYS-1 sibling)
#import <time.h>               // clock_gettime_nsec_np — monotonic window for the rate-limiter

// The chat tabs match the official mobile app's small size, which makes them fiddly to hit. This button expands its
// touch area vertically (the 7 tabs are contiguous, so a horizontal miss already lands on a neighbour) so near-miss
// taps above/below a tab still register on that column. Purely a hit-test grow — the visible sprite is unchanged.
static const CGFloat kChatTabTouchExpand = 15.0;   // screen pt added above AND below each tab's touch rect
@interface ChatTabButton : UIButton
@end
@implementation ChatTabButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, 0, -kChatTabTouchExpand), point);
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

@interface ViewController () <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate, SFSafariViewControllerDelegate, UNUserNotificationCenterDelegate, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, UISearchBarDelegate, OverlayEditChatHost>
{
    // Game-canvas centres of each tab stone (updated each chrome refresh), used to proxy a tap onto the live
    // desktop stone. A C array, so it lives as an ivar rather than a property.
    CGPoint _tabCentres[14];
}
@property (nonatomic, strong) UITextView *console;
@property (nonatomic, strong) UIButton *launchButton;
@property (nonatomic, strong) UIButton *gpuButton;   // GPU Route C: dedicated one-tap button to boot full RuneLite on GPU
@property (nonatomic, strong) UIButton *zoneButton;  // GPU Zone: dedicated one-tap button to boot full RuneLite on 117HD
@property (nonatomic, strong) UIButton *zoneFastButton;  // GPU Zone: 117HD resizable + DIRECT present (no readback)
@property (nonatomic, strong) UIButton *canaryButton;
@property (nonatomic, strong) UIButton *keyboardButton;
@property (nonatomic, strong) UIButton *shiftButton;     // sticky-Shift toggle (holds VK_SHIFT for shift-click)
@property (nonatomic, assign) BOOL shiftHeld;
@property (nonatomic, strong) UIButton *ctrlButton; // PARITY-IOS-LATCH: sticky-Ctrl toggle (holds VK_CONTROL)
@property (nonatomic, assign) BOOL ctrlHeld;
@property (nonatomic, assign) BOOL notifAuthRequested;   // UNUserNotificationCenter authorization asked once
@property (nonatomic, assign) BOOL safariOpen;           // an SFSafariViewController is currently presented
@property (nonatomic, strong) UIButton *screenshotButton; // 📷 save the live frame to Photos
// KEY-1: an optional on-screen action-hotkey strip. The ⚡ chip toggles a row of buttons, one per *pinned*
// plugin hotkey (Ground Items hide, quick-hop, screenshot, …); a tap fires that plugin's configured Keybind via
// the bridge. Long-press the ⚡ chip to pick which hotkeys are pinned. Pinned set persists in NSUserDefaults.
@property (nonatomic, strong) UIButton *hotkeyButton;     // ⚡ toggle + (long-press) picker for the hotkey strip
@property (nonatomic, strong) UIStackView *hotkeyStrip;   // horizontal row of pinned hotkey buttons
@property (nonatomic, strong) NSArray *hotkeyActions;     // cached [{group,key,label,keyCode,mods,bind}] from the bridge
@property (nonatomic, assign) BOOL hotkeyStripVisible;
// W3 hybrid-chrome device de-risk: read the MobileChromeBridge snapshot + proxy a tab switch via the proven
// JavaBridge.onClick, logging a md5-gateable verdict. The seam proof before native rails are drawn.
@property (nonatomic, strong) UIButton *chromeButton;
// On-device Jagex login: opens an embedded OAuth login (WKWebView), mints a session, writes tokens.json.
// Pure native (no JVM/JIT) so it's enabled from launch, not gated on StikDebug attach.
@property (nonatomic, strong) UIButton *loginButton;
// Log out: clears tokens.json (disarms autologin) + purges any persisted Jagex web cookies. Shown only
// when a session is saved.
@property (nonatomic, strong) UIButton *logoutButton;
// LOGIN-1: switch to another already-signed-in character from tokens.json (no re-OAuth) — rewrites
// chosen_account_id and restarts. Shown only when 2+ accounts are saved.
@property (nonatomic, strong) UIButton *switchCharButton;
// Set once the login WKWebView has been shown this session. WebKit then stays permanently resident in the
// process and breaks the JVM's JIT-mirror brk #0x69 (it crashes at code-cache init), so the JVM must be
// launched in a fresh process. Gates onLaunch → a one-tap restart.
@property (nonatomic, assign) BOOL webKitUsedThisSession;
// Collapsible debug overlay: a small always-on-top toggle shows/hides a panel holding the status,
// launch/canary buttons and the log console, so the game stays full-screen.
@property (nonatomic, strong) UIView *debugPanel;
@property (nonatomic, strong) UIButton *debugToggle;
// Hidden capture field: becomes first responder to raise the soft keyboard; its change/return callbacks
// are translated into AWT KeyEvents. It never actually holds text (a zero-width sentinel keeps backspace
// firing, and every change returns NO).
@property (nonatomic, strong) UITextField *kbField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *jitTimer;
@property (nonatomic, strong) NSFileHandle *logFile;
@property (nonatomic, assign) int jvmFd;   // raw fd for crash-proof libjvm stdout/stderr
@property (nonatomic, assign) BOOL launched;
@property (nonatomic, assign) BOOL pendingRouteCL1;   // GPU Route C: long-press Start -> boot the L1 kill-test
@property (nonatomic, assign) BOOL pendingRouteCGpu;  // GPU Route C: two-finger long-press -> full RuneLite on GPU
@property (nonatomic, assign) BOOL pendingRouteCZone; // GPU Zone: three-finger long-press -> full RuneLite on 117HD
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
@property (nonatomic, assign) BOOL   menuFingerOnMenu;    // finger over the menu (with grace) -> select; else cancel
@property (nonatomic, strong) UISelectionFeedbackGenerator *menuHaptic; // light tick when the highlight moves
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
// DRAG-1: a one-finger drag that BEGAN over the inventory grid rearranges items (synthesized engine mouse-drag)
// instead of rotating the camera. Only set when the drag starts inside the published inventory rect.
@property (nonatomic, assign) BOOL itemDragging;
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
@property (nonatomic, strong) UIImpactFeedbackGenerator *tapHaptic;
// The click ring is deferred one beat so it can pick the official colour: RED if the tap resolved to an
// interactable (the engine bumped interactTapSeq), YELLOW for a plain walk (no bump within the grace window).
@property (nonatomic, assign) BOOL pendingClick;
@property (nonatomic, assign) CGPoint pendingClickPoint;
@property (nonatomic, assign) NSTimeInterval pendingClickAt;
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

// W3 Feature-A (A3): chat-at-top = the engine's OWN chatbox relocated to the top + flipped transparent
// (ChatRelocateProbe proved it renders there, not occluded). Tabs/scrollback/colors/input stay live since it IS
// the real chat — no native reproduction needed.
@property (nonatomic, assign) BOOL engineChatRelocated;   // one-shot: asked the engine to relocate the HUD (A4)
// Edge-to-edge (A1+A4): the scene fills the whole screen; the engine HUD (chat/minimap/orbs) is relocated INTO
// the safe area so nothing clips under the island/corners/home-indicator. renderW/H = the canvas the engine
// draws (set at launch); chatHitCanvas = the relocated chat tab-row rect in canvas px (onTap treats it as UI).
@property (nonatomic, assign) int renderW;
@property (nonatomic, assign) int renderH;

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
@property (nonatomic, assign) CGRect chatHitCanvas;
// Pre-composited tab images (stone background + centred icon) built once from the bundled OSRS sprite assets
// (stone-inactive/active + icon-0..13). Index = tab index; active/inactive variants. Authentic, crisp, no
// crop fragility.
@property (nonatomic, strong) NSMutableArray<UIImage *> *tabImgInactive;
@property (nonatomic, strong) NSMutableArray<UIImage *> *tabImgActive;
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

// W3 A3 (bigger chat tabs): native UIKit recreation of the engine's chat tab buttons (All/Game/Public/Private/
// Channel/Clan/Trade + Report) drawn LARGER over the relocated engine chat. The engine has no per-widget scale
// and the tab sprites are fixed-size, so we redraw them: each button is backed by the extracted gamepack sprite
// (CHATBOX_BUTTON 3051 / SELECTED 3053 / NEW 3055 / REPORT 3057) with a RuneScape-font label, and a tap proxies
// a precise click onto the live engine button (CONTROLS stays shown underneath, covered by the native row). The
// engine pushes its message area down past the taller row (setEngineChatTabRowHeight). State + click targets
// come from JVMLauncher.chatSnapshot each tick; re-applied so the engine's TOPLEVEL_REDRAW can't undo it.
@property (nonatomic, strong) NSMutableArray<UIButton *> *chatTabButtons;
@property (nonatomic, strong) UIImage *chatBtnImg;      // 3051 — idle tab background
@property (nonatomic, strong) UIImage *chatBtnSelImg;   // 3053 — selected (active) tab
@property (nonatomic, strong) UIImage *chatBtnNewImg;   // 3055 — tab with unread messages
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
@property (nonatomic, strong) UITextView *chatMessagesView;  // native-rendered chat MESSAGE lines (engine can't raster relocated chat)
// Native dialogue: an OPAQUE parchment drawn over the whole chatbox region while a dialogue is open (occluding the
// engine's transparent dialogue + the chat tabs/messages), with a CUTOUT where the engine's real 3D head renders.
@property (nonatomic, strong) UIView *dialogueView;          // the parchment box (masked with a head cutout)
@property (nonatomic, strong) UIView *dialogueContentView;   // the text area (inset to clear the head column)
@property (nonatomic, strong) UIStackView *dialogueStack;    // name / text / continue, or option rows
@property (nonatomic, copy)   NSString *lastDialogueJson;    // rebuild the stack only when the content changes
@property (nonatomic, assign) CGPoint dialogueContinuePoint; // engine CONTINUE widget centre (canvas px), or (-1,-1)
@property (nonatomic, assign) int chatLinesSeq;              // last rendered getChatLines seq (skip re-parse when unchanged)
@property (nonatomic, assign) int chatBaseX;                 // safe-area-anchored chat origin (canvas px), before the user offset
@property (nonatomic, assign) int chatBaseY;
@property (nonatomic, assign) int chatUserDX;               // persisted chat position offset from the base anchor (canvas px)
@property (nonatomic, assign) int chatUserDY;
// Phase-6 native plugin panel: a ⚙ button opens a full-screen modal sheet (scrim eats all touches so nothing
// falls through to the game) listing the plugins (MobileUiBridge.listPlugins) with an enable/disable switch
// and a running/stopped indicator. Refreshed when the bridge's event sequence advances (toggles, conflicts).
@property (nonatomic, strong) UIButton *pluginButton;
@property (nonatomic, strong) UIButton *gridButton;   // §3.3: opens the labelled plugin-panel grid launcher
@property (nonatomic, strong) UIButton *overlaysCardButton;   // plugin card: enters overlay edit-mode
@property (nonatomic, strong) OverlayEditView *overlayEdit;   // active overlay edit-mode view (OVL-2/3/5)
// FIX-9 (iOS parity with Android ReconnectingOverlayView): a native "Reconnecting…" scrim shown over the live
// frame while the headless auto-reconnect recovers an in-session drop, driven off the chrome snapshot's
// "reconnecting" flag (HeadlessLogin.isReconnecting -> MobileChromeBridge). reconnectShown = last-applied state.
@property (nonatomic, strong) UIView *reconnectScrim;
@property (nonatomic, strong) UIActivityIndicatorView *reconnectSpinner;
@property (nonatomic, assign) BOOL reconnectShown;
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
// PERF-MEMORY-THERMAL-01 (iOS parity with Android's ThermalGovernor): protect sustained 117HD play from
// silent thermal throttling by stepping the 117HD sceneResolutionScale DOWN under NSProcessInfo thermal
// pressure (serious -> 65, critical -> 50, never above the user's own baseline) and restoring the captured
// baseline once the device cools. CPU/base-GPU are light enough to leave untouched — the governor only runs
// on a 117HD boot. Driven from onDisplayTick (~0.5 Hz — already main-thread, which the mobile* bridge
// selectors require) rather than the thermal notification: the tick gives the two correctness guards their
// retry loop for free — the baseline is captured ONLY from a real live sceneResolutionScale (config not
// readable yet -> defer, never guess), and a leaked NSUserDefaults marker from a session killed mid-throttle
// is restored before arming (the bridge write PERSISTS config, so a throttle must never become the next
// session's "baseline").
@property (nonatomic, assign) int thermalBaselineScale; // <=0 (the ivar default) = not captured yet
@property (nonatomic, assign) int thermalAppliedScale;  // last scale this governor wrote (valid once captured)
@property (nonatomic, strong) UIView *pluginPanel;
@property (nonatomic, strong) UITableView *pluginTable;
@property (nonatomic, strong) NSArray<NSDictionary *> *pluginList;  // the FILTERED view the table renders
@property (nonatomic, strong) NSArray<NSDictionary *> *pluginAll;   // the full sorted list (search filters this)
@property (nonatomic, strong) UISearchBar *pluginSearch;           // CFG-5 plugin-list search
@property (nonatomic, strong) UIView *accountBar;                  // RuneLite-account login/status row (config sync)
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, strong) NSLayoutConstraint *accountBarHeight;
@property (nonatomic, strong) NSTimer *accountTimer;
@property (nonatomic, copy) NSString *pluginFilter;                // current lowercase search text
@property (nonatomic, assign) long long pluginSeq;     // last MobileUiBridge event seq the panel has seen
@property (nonatomic, assign) BOOL pluginPanelOpen;
// className -> CFAbsoluteTime when we first saw it enabled-but-not-active, so a plugin that never reaches
// running (e.g. a native-lib/GPU plugin whose macOS .dylib can't load on iOS) flips from "enabling…" to
// "couldn't start" after a grace period instead of spinning forever.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pluginEnabledSince;
// Picture-in-Picture + background keepalive: the game keeps playing after a swipe-home. pipLayer is an
// AVSampleBufferDisplayLayer fed the SAME engine frames as the on-screen blit, parked BEHIND the (opaque)
// game view so it never shows in-app; the system lifts it into the PiP window when the app backgrounds
// (canStartPictureInPictureAutomaticallyFromInline). A silent, mixable AVAudioEngine holds the `audio`
// background mode so the process — JVM, render loop, game socket — keeps running even with PiP dismissed;
// the in-game logout timer (RuneLite, up to 30 min) then decides how long the character stays in.
@property (nonatomic, strong) AVSampleBufferDisplayLayer *pipLayer;
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) dispatch_source_t pipBgPump;   // 15 Hz frame pump while backgrounded (the
                                                             // CADisplayLink stops firing there)
@property (nonatomic, assign) int32_t pipFrameSeq;           // last engine frame seq fed to the PiP layer
@property (nonatomic, strong) UIButton *pipButton;           // 📺 manual PiP start/stop (also the diagnostic
                                                             // for the auto-start gate)
@property (nonatomic, strong) AVAudioEngine *keepaliveEngine;   // renders silence; holds the audio session
@property (nonatomic, strong) AVAudioSourceNode *keepaliveSource;
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
// Zero-width sentinel so a backspace on an "empty" field still fires shouldChangeCharactersInRange.
static NSString * const kKbSentinel = @"​";

// W3 A3/A4: the relocated engine chat's tab row is the top kChatTabRowH px of a kChatW-wide box. Its canvas
// origin moves with the safe-area relocate (self.chatHitCanvas, set in updateHudLayout); these are the fixed
// engine-px dimensions used to treat tab-row taps as UI (precise click, no walk ring).
static const int kChatW = 519;
static const int kChatTabRowH = 23;

// W3 A3 (native chat tabs, matching the official OSRS-mobile app): 7 tabs (NO Report — the official app doesn't
// show it in the tab row), each a stone button with the channel name on top and, for the filterable channels, the
// live filter state ("On"/"Off"/"Filter"/"Hide") below it in the engine's state colour. The 7 tabs span the chat
// width (kChatW), so each is kChatW/7 wide; the row is taller than the bare sprite to fit the two text lines.
// CHAT-3 (deliberate): the Report channel is intentionally omitted from this row to match the official mobile app
// — it is NOT a lost capability: reporting a player is reached the way mobile does it, via the player's
// right-click (long-press) menu "Report" entry, which surfaces through the native menu like any other entry.
static const int kChatTabCount = 7;
static const int kChatTabRowCanvasH = 40;   // 2-line tab height (name + state). 40 canvas px = the Android twin's
                                            // ChatPillView.ROW_H_CANVAS, pushed into the engine row the same way
                                            // (setEngineChatTabRowHeight). The old 24 rendered the labels at ~7pt/
                                            // ~6pt effective — illegible at arm's length. Label fonts scale off
                                            // this height (0.40/0.34 below), as does the dialogue parchment box.
static const int kChatContentCanvasH = 142; // the chat message-area height (engine-canvas px) below the tab row
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

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.bgTask = UIBackgroundTaskInvalid;
    [self buildUI];
    [self openLogFile];
    self.bgKeepTask = UIBackgroundTaskInvalid;
    // Flush RuneLite config to disk when the app backgrounds (iOS skips RuneLite's own shutdown flush).
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
    // Coming back: stop the background PiP pump (the CADisplayLink takes over) and re-arm the keepalive
    // audio in case the session was interrupted while away.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
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
}

#pragma mark - #1 Tap-to-Play front screen

- (void)buildLaunchScreen {
    UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.05 alpha:1.0]; // opaque OSRS-mobile tone
    cover.userInteractionEnabled = YES;   // swallow every touch so nothing reaches the game/HUD beneath
    self.launchScreen = cover;

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
    status.numberOfLines = 2;
    [cover addSubview:status];
    self.playStatusLabel = status;

    // Login row — reflects the saved session (refreshLaunchLogin keeps the title current). Pure native, so
    // it works before any attach: log in here, then attach + play.
    UIButton *login = [UIButton buttonWithType:UIButtonTypeSystem];
    login.translatesAutoresizingMaskIntoConstraints = NO;
    login.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [login setTitleColor:[UIColor colorWithWhite:0.78 alpha:1.0] forState:UIControlStateNormal];
    [login addTarget:self action:@selector(onLoginWithJagex) forControlEvents:UIControlEventTouchUpInside];
    [cover addSubview:login];
    self.playLoginButton = login;

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

    [self refreshLaunchLogin];
}

// Mirror the saved tokens.json onto the launch-screen login button (same source as refreshLoginButton).
- (void)refreshLaunchLogin {
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *t = [o isKindOfClass:[NSDictionary class]] ? o : nil;
    NSString *sid  = [t[@"session_id"] isKindOfClass:[NSString class]] ? t[@"session_id"] : nil;
    NSString *name = [t[@"chosen_display_name"] isKindOfClass:[NSString class]] ? t[@"chosen_display_name"] : nil;
    NSString *title = sid.length
        ? (name.length ? [NSString stringWithFormat:@"Logged in: %@  ·  switch account", name]
                       : @"Logged in  ·  switch account")
        : @"Log in with Jagex";
    [self.playLoginButton setTitle:title forState:UIControlStateNormal];
}

// Hidden dev affordance: dismiss the cover to expose the W1 debug panel (does NOT launch the JVM).
- (void)onRevealDebug {
    self.debugPanel.hidden = NO;
    self.launchScreen.hidden = YES;
    [self.launchScreen removeFromSuperview];
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
    // If the login web view ran this session, WebKit is resident and the JVM can't start cleanly — onLaunch
    // will prompt a restart instead. Keep the cover up in that case so the user lands back here post-restart.
    // Tap to Play boots the renderer the user SELECTED in the plugins panel, saved in NSUserDefaults
    // "rendererPref" (cpu | gpu | 117hd). Default = cpu (the software renderer — vanilla, always works). The
    // GPU + 117HD plugins are loaded into the panel in every mode (RendererPanelStarter) so they're selectable;
    // flipping one there saves the preference (with a "restart to apply" message), and THIS reads it at launch.
    // base GPU uses the readback present (int[] frames like CPU); 117HD uses the CAEAGLLayer direct present.
    NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:@"rendererPref"] ?: @"cpu";
    BOOL wantGpu = [pref isEqualToString:@"gpu"];
    BOOL wantHd = [pref isEqualToString:@"117hd"];
    if (wantHd && [self hdBootCookiePresent]) {
        // The last 117HD boot armed the cookie and died before its first GL present (GL-init/shader-compile
        // crash or an OOM kill mid-warmup). Fall back to the always-works software renderer so the user is
        // never crash-looped out of the game, and tell them where to turn 117HD back on.
        [self hdBootCookieClear];
        [[NSUserDefaults standardUserDefaults] setObject:@"cpu" forKey:@"rendererPref"];
        pref = @"cpu";
        wantHd = NO;
        [self appendLine:@"[shell] 117HD did not survive its last launch — reverted to the standard renderer"];
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"HD renderer didn't start"
                             message:@"117HD crashed while starting last time, so this launch uses the standard "
                                     @"renderer. You can turn 117HD back on in the plugins panel."
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
    self.screen = [[UIImageView alloc] init];
    self.screen.translatesAutoresizingMaskIntoConstraints = NO;
    self.screen.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    self.screen.contentMode = UIViewContentModeScaleAspectFit;   // render aspect == screen aspect -> fills
    self.screen.layer.magnificationFilter = kCAFilterLinear;     // smooth when scaled to native res
    self.screen.userInteractionEnabled = YES;                    // receive the game gestures
    [self.view addSubview:self.screen];

    // Phase 5 control scheme on the game view. UIKit gesture recognizers own classification: tap = left
    // click (walk/interact/menu-entry), long-press = drag-to-select menu, one-finger drag = camera rotate,
    // pinch = zoom. Mutual-exclusivity disambiguates the one-finger trio.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onTap:)];
    tap.delegate = self;   // never fire a game tap when the touch lands on a native control (chat tab / keyboard)
    [self.screen addGestureRecognizer:tap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLongPress:)];
    longPress.minimumPressDuration = 0.4;
    longPress.delegate = self;
    [self.screen addGestureRecognizer:longPress];
    UIPanGestureRecognizer *camPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onCameraPan:)];
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
    bar.items = @[flex, send, hide];
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

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [UIColor systemYellowColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:14];
    self.statusLabel.text = @"JIT: waiting…";
    [self.debugPanel addSubview:self.statusLabel];

    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"Run AWT activation (§6.0)" forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.launchButton.enabled = NO;
    [self.launchButton addTarget:self action:@selector(onLaunch)
                forControlEvents:UIControlEventTouchUpInside];
    // GPU Route C dev affordance: LONG-PRESS the launch button to boot the L1 GPU kill-test (routec-l1.jar +
    // RouteC_registerGLNatives + RouteCL1Probe) instead of the full RuneLite boot. A plain tap is unchanged.
    UILongPressGestureRecognizer *l1lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLaunchRouteCL1Gesture:)];
    [self.launchButton addGestureRecognizer:l1lp];
    // TWO-FINGER long-press the launch button to boot the FULL RuneLite in GPU Route C mode (bridge natives
    // registered -> the gpu plugin renders on the device GPU). Distinct from the one-finger L1 gesture.
    UILongPressGestureRecognizer *gpulp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLaunchRouteCGpuGesture:)];
    gpulp.numberOfTouchesRequired = 2;
    [self.launchButton addGestureRecognizer:gpulp];
    // THREE-FINGER long-press the launch button to boot the FULL RuneLite in GPU Zone (117HD/RLHD) mode: the
    // staged rlhd jar joins the classpath, the zone facade-delta natives register, and RLHDStarter loads +
    // starts rs117.hd.HdPlugin (the Zone renderer). Distinct from one-finger L1 / two-finger base-GPU.
    UILongPressGestureRecognizer *zonelp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLaunchRouteCZoneGesture:)];
    zonelp.numberOfTouchesRequired = 3;
    [self.launchButton addGestureRecognizer:zonelp];
    [self.debugPanel addSubview:self.launchButton];

    self.canaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.canaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.canaryButton setTitle:@"RWX canary" forState:UIControlStateNormal];
    [self.canaryButton addTarget:self action:@selector(onCanary)
                forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.canaryButton];

    self.chromeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.chromeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chromeButton setTitle:@"Chrome test (read+switch)" forState:UIControlStateNormal];
    self.chromeButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.chromeButton addTarget:self action:@selector(onChromeTest)
                forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.chromeButton];

    // GPU Route C: dedicated one-tap button to boot full RuneLite on the device GPU (equivalent to the
    // two-finger long-press on the launch button, but unambiguous). Enabled together with the launch button
    // once the JIT debugger is attached.
    self.gpuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.gpuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.gpuButton setTitle:@"▶ Run GPU (Route C)" forState:UIControlStateNormal];
    self.gpuButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.gpuButton.enabled = NO;
    [self.gpuButton addTarget:self action:@selector(onLaunchGpu)
             forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.gpuButton];

    self.zoneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.zoneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.zoneButton setTitle:@"▶ 117HD (Zone)" forState:UIControlStateNormal];
    self.zoneButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.zoneButton.tintColor = [UIColor systemGreenColor];
    self.zoneButton.enabled = NO;
    [self.zoneButton addTarget:self action:@selector(onLaunchZone)
             forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.zoneButton];

    // Fallback: 117HD resizable on the READBACK present (no CAEAGLLayer). The green button defaults to direct
    // present (faster); this is here if direct present ever scans out black or regresses.
    self.zoneFastButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.zoneFastButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.zoneFastButton setTitle:@"117HD readback" forState:UIControlStateNormal];
    self.zoneFastButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.zoneFastButton.tintColor = [UIColor systemGrayColor];
    self.zoneFastButton.enabled = NO;
    [self.zoneFastButton addTarget:self action:@selector(onLaunchZoneReadback)
             forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.zoneFastButton];

    // "Renderers as plugins": the renderer launch buttons are retired — Tap to Play reads the saved renderer
    // preference and the user selects GPU/117HD from the plugins panel. Hidden (not deleted) so the dev
    // gestures + their constraints stay intact. The L1 kill-test button (if any) is unaffected.
    self.gpuButton.hidden = YES;
    self.zoneButton.hidden = YES;
    self.zoneFastButton.hidden = YES;

    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton setTitle:@"Log in with Jagex" forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [self.loginButton addTarget:self action:@selector(onLoginWithJagex)
               forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.loginButton];

    self.logoutButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.logoutButton.translatesAutoresizingMaskIntoConstraints = NO;
    // LOGIN-2: this clears tokens.json + the OAuth cookies and disarms autologin — it does NOT end a live in-game
    // session (that's the in-game Logout tab). Labelled honestly so it isn't mistaken for the game logout.
    [self.logoutButton setTitle:@"Forget account" forState:UIControlStateNormal];
    self.logoutButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.logoutButton.tintColor = [UIColor systemRedColor];
    self.logoutButton.hidden = YES;   // refreshLoginButton reveals it when a session is saved
    [self.logoutButton addTarget:self action:@selector(onLogout)
                forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.logoutButton];

    // LOGIN-1: switch to another stored character (reuses the saved session — no web re-login). Hidden until
    // tokens.json holds 2+ accounts (refreshLoginButton reveals it).
    self.switchCharButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.switchCharButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.switchCharButton setTitle:@"Switch character" forState:UIControlStateNormal];
    self.switchCharButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.switchCharButton.hidden = YES;
    [self.switchCharButton addTarget:self action:@selector(onSwitchCharacter)
                    forControlEvents:UIControlEventTouchUpInside];
    [self.debugPanel addSubview:self.switchCharButton];

    self.console = [[UITextView alloc] init];
    self.console.translatesAutoresizingMaskIntoConstraints = NO;
    self.console.editable = NO;
    self.console.backgroundColor = [UIColor clearColor];
    self.console.textColor = [UIColor greenColor];
    self.console.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.debugPanel addSubview:self.console];

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

    // §3.3 redesign: a ⊞ "Plugins" FAB that opens the labelled/searchable/favourites grid launcher (a more
    // discoverable entry to the side-panels than the 38pt icon rail). Sits at the top of the corner stack (above ≡).
    self.gridButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.gridButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.gridButton setTitle:@"⊞" forState:UIControlStateNormal];
    self.gridButton.accessibilityLabel = @"Plugins";
    self.gridButton.accessibilityHint = @"Opens the plugin launcher; long press to toggle the icon rail";
    self.gridButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.gridButton.tintColor = [UIColor whiteColor];
    self.gridButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.gridButton.layer.cornerRadius = 8;
    [self.gridButton addTarget:self action:@selector(onOpenGridLauncher)
              forControlEvents:UIControlEventTouchUpInside];
    // Long-press the ⊞ FAB toggles the plugin-icon rail on/off (shown by default) — lets you collapse to a
    // FAB-only entry if you prefer, reversible on device without a rebuild.
    UILongPressGestureRecognizer *gridLp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onToggleRail:)];
    [self.gridButton addGestureRecognizer:gridLp];
    [self.view addSubview:self.gridButton];

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

        // In-game keyboard control, bottom-left of the safe area.
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

        // §3.3 grid launcher FAB — top of the corner stack, above ≡.
        [self.gridButton.bottomAnchor constraintEqualToAnchor:self.debugToggle.topAnchor
                                                     constant:-8],
        [self.gridButton.leadingAnchor constraintEqualToAnchor:self.keyboardButton.leadingAnchor],
        [self.gridButton.widthAnchor constraintEqualToConstant:44],
        [self.gridButton.heightAnchor constraintEqualToConstant:36],

        // Debug panel — left ~62% of the safe area, full height, below the toggle row.
        [self.debugPanel.topAnchor constraintEqualToAnchor:g.topAnchor
                                                  constant:8],
        [self.debugPanel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor
                                                      constant:8],
        [self.debugPanel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor
                                                     constant:-8],
        [self.debugPanel.widthAnchor constraintEqualToAnchor:g.widthAnchor
                                                  multiplier:0.62],

        // Panel contents.
        [self.statusLabel.topAnchor constraintEqualToAnchor:p.topAnchor],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.launchButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor
                                                    constant:6],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.canaryButton.centerYAnchor constraintEqualToAnchor:self.launchButton.centerYAnchor],
        [self.canaryButton.leadingAnchor constraintEqualToAnchor:self.launchButton.trailingAnchor
                                                        constant:24],
        [self.chromeButton.topAnchor constraintEqualToAnchor:self.launchButton.bottomAnchor
                                                    constant:6],
        [self.chromeButton.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.gpuButton.centerYAnchor constraintEqualToAnchor:self.chromeButton.centerYAnchor],
        [self.gpuButton.leadingAnchor constraintEqualToAnchor:self.chromeButton.trailingAnchor
                                                     constant:24],
        [self.zoneButton.centerYAnchor constraintEqualToAnchor:self.gpuButton.centerYAnchor],
        [self.zoneButton.leadingAnchor constraintEqualToAnchor:self.gpuButton.trailingAnchor
                                                      constant:24],
        // ⚡ Fast on its own row (the chrome/gpu/zone row is already full-width).
        [self.zoneFastButton.topAnchor constraintEqualToAnchor:self.chromeButton.bottomAnchor
                                                      constant:6],
        [self.zoneFastButton.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.loginButton.topAnchor constraintEqualToAnchor:self.zoneFastButton.bottomAnchor
                                                   constant:6],
        [self.loginButton.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.logoutButton.centerYAnchor constraintEqualToAnchor:self.loginButton.centerYAnchor],
        [self.logoutButton.leadingAnchor constraintEqualToAnchor:self.loginButton.trailingAnchor
                                                        constant:16],
        [self.switchCharButton.centerYAnchor constraintEqualToAnchor:self.loginButton.centerYAnchor],
        [self.switchCharButton.leadingAnchor constraintEqualToAnchor:self.logoutButton.trailingAnchor
                                                            constant:16],
        [self.console.topAnchor constraintEqualToAnchor:self.loginButton.bottomAnchor
                                               constant:6],
        [self.console.leadingAnchor constraintEqualToAnchor:p.leadingAnchor],
        [self.console.trailingAnchor constraintEqualToAnchor:p.trailingAnchor],
        [self.console.bottomAnchor constraintEqualToAnchor:p.bottomAnchor],
    ]];

    [self refreshLoginButton];   // reflect any already-saved session on the button title
}

- (void)onToggleDebug {
    self.debugPanel.hidden = !self.debugPanel.hidden;
}

// On-device Jagex login: present the embedded OAuth login, and on success persist the chosen character to
// tokens.json — exactly the file loadJagexTokens (JVMLauncher) reads to arm autologin. Pure native (no
// JVM), so this works before any StikDebug attach: log in here, then attach + Start JVM to play.
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
        ? [NSString stringWithFormat:@"[login] tokens.json written — logged in as %@. Attach StikDebug, then Start JVM.",
           display.length ? display : @"(unnamed)"]
        : [NSString stringWithFormat:@"[login] tokens.json write FAILED: %@", err.localizedDescription ?: @"?"]];
}

// Reflect the saved login on the button title so the user can see they're signed in (and re-login if needed).
- (void)refreshLoginButton {
    NSData *data = [NSData dataWithContentsOfFile:[JVMLauncher tokensPath]];
    id o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *t = [o isKindOfClass:[NSDictionary class]] ? o : nil;
    NSString *sid  = [t[@"session_id"] isKindOfClass:[NSString class]] ? t[@"session_id"] : nil;
    NSString *name = [t[@"chosen_display_name"] isKindOfClass:[NSString class]] ? t[@"chosen_display_name"] : nil;
    NSString *title = sid.length
        ? (name.length ? [NSString stringWithFormat:@"Logged in: %@  ·  re-login", name] : @"Logged in  ·  re-login")
        : @"Log in with Jagex";
    [self.loginButton setTitle:title forState:UIControlStateNormal];
    self.logoutButton.hidden = (sid.length == 0);
    // LOGIN-1: only offer "Switch character" when there's a live session AND 2+ stored characters to switch between.
    id accs = t[@"accounts"];
    NSUInteger nAcc = [accs isKindOfClass:[NSArray class]] ? [(NSArray *)accs count] : 0;
    self.switchCharButton.hidden = (sid.length == 0 || nAcc < 2);
    [self refreshLaunchLogin];   // #1: keep the Tap-to-Play login row in sync
}

// Log out: delete the saved game session (so autologin won't fire) and purge any persisted Jagex web
// cookies from older builds (the login webview itself is now ephemeral, so it leaves none going forward).
- (void)onLogout {
    NSString *path = [JVMLauncher tokensPath];
    BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (existed) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    NSSet *types = [NSSet setWithObjects:WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
                    WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases, nil];
    WKWebsiteDataStore *ds = [WKWebsiteDataStore defaultDataStore];
    [ds fetchDataRecordsOfTypes:types completionHandler:^(NSArray<WKWebsiteDataRecord *> *records) {
        NSMutableArray *kill = [NSMutableArray array];
        for (WKWebsiteDataRecord *r in records) {
            NSString *n = r.displayName.lowercaseString ?: @"";
            if ([n containsString:@"jagex"] || [n containsString:@"runescape"]) [kill addObject:r];
        }
        if (kill.count) [ds removeDataOfTypes:types forDataRecords:kill completionHandler:^{}];
    }];

    [self refreshLoginButton];
    [self appendLine:existed ? @"[login] account forgotten — tokens.json cleared; autologin disarmed."
                             : @"[login] no saved account (no tokens.json)."];
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
    sheet.popoverPresentationController.sourceView = self.switchCharButton;
    sheet.popoverPresentationController.sourceRect = self.switchCharButton.bounds;
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
    title.font = [UIFont boldSystemFontOfSize:18];
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

    // (§3.5: the legacy "▣ Panels" drawer/centered openers were removed — the ⊞ FAB grid launcher is the single
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
    [card addSubview:self.pluginSearch];

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
        [card.topAnchor constraintEqualToAnchor:sg.topAnchor constant:10],
        [card.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor constant:-10],
        [card.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:24],
        [card.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-24],

        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [hub.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [hub.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-18],
        [self.overlaysCardButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.overlaysCardButton.trailingAnchor constraintEqualToAnchor:hub.leadingAnchor constant:-18],

        [self.pluginSearch.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [self.pluginSearch.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:6],
        [self.pluginSearch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-6],

        [self.accountBar.topAnchor constraintEqualToAnchor:self.pluginSearch.bottomAnchor constant:4],
        [self.accountBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [self.accountBar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [self.accountLabel.leadingAnchor constraintEqualToAnchor:self.accountBar.leadingAnchor constant:12],
        [self.accountLabel.centerYAnchor constraintEqualToAnchor:self.accountBar.centerYAnchor],
        [self.accountButton.trailingAnchor constraintEqualToAnchor:self.accountBar.trailingAnchor constant:-12],
        [self.accountButton.centerYAnchor constraintEqualToAnchor:self.accountBar.centerYAnchor],
        [self.accountButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.accountLabel.trailingAnchor constant:8],

        [self.pluginTable.topAnchor constraintEqualToAnchor:self.accountBar.bottomAnchor constant:4],
        [self.pluginTable.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [self.pluginTable.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [self.pluginTable.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    // Collapsible height (0 until the account bridge is available); updated by refreshAccountRow.
    self.accountBarHeight = [self.accountBar.heightAnchor constraintEqualToConstant:0];
    self.accountBarHeight.active = YES;
    [self refreshAccountRow];
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

// §3.3: open the labelled grid launcher for the plugin side-panels (the persistent dock holds the live list).
- (void)onOpenGridLauncher {
    [self.panelDock presentGridLauncher];
}

// §3.5 step 3 (reversible): long-press the ⊞ FAB to toggle the legacy 38pt plugin icon rail. Default is hidden
// (FAB-only entry); this brings it back for anyone who prefers the always-visible rail. Persisted across launches.
- (void)onToggleRail:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL nowHidden = ([ud objectForKey:@"rightBarRailHidden"] == nil) ? NO : [ud boolForKey:@"rightBarRailHidden"];
    BOOL newHidden = !nowHidden;
    [ud setBool:newHidden forKey:@"rightBarRailHidden"];
    self.panelDock.railHidden = newHidden;
    if (self.presentedViewController) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Plugin rail"
        message:(newHidden ? @"Hidden — use the ⊞ button to open plugin panels."
                           : @"Shown — the icon rail is back on the right edge.")
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
                                                         canvasW:self.renderW canvasH:self.renderH presenter:self];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.chatHost = self;                            // show the chatbox as a draggable "Chat" handle
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

// App going to background (user swiped home / to the switcher, before any termination): flush config so
// every edit/toggle made this session survives a relaunch. The one lifecycle hook iOS reliably delivers.
// Then keep the session ALIVE back there: a fresh background-task grace covers the handover, the silent
// audio engine (audio background mode) blocks suspension so the JVM + game socket keep running, and a
// 15 Hz pump keeps feeding live frames to the (auto-started) Picture-in-Picture window.
- (void)onEnterBackground {
    [JVMLauncher mobileFlushConfig];
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
        [self startPipBgPump];
    }
    if (self.pipController) {
        // The auto-engage state at the exact moment it matters, for the device log.
        [self appendLine:[NSString stringWithFormat:
            @"[pip] bg snapshot: possible=%d active=%d layerStatus=%ld fedSeq=%d audioRunning=%d",
            (int)self.pipController.isPictureInPicturePossible,
            (int)self.pipController.isPictureInPictureActive,
            (long)self.pipLayer.status, self.pipFrameSeq,
            (int)self.keepaliveEngine.isRunning]];
    }
    [self appendLine:@"[shell] backgrounded -> flushed config, keepalive armed"];
}

- (void)onWillEnterForeground {
    [self stopPipBgPump];
    if (self.bgKeepTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgKeepTask];
        self.bgKeepTask = UIBackgroundTaskInvalid;
    }
    if (self.launched) [self startKeepaliveEngine];
    [self appendLine:@"[shell] foregrounded -> background pump stopped"];
}

// Read listPlugins() once, parse the JSON array, sort by name, reload the table.
- (void)refreshPluginList {
    if (self.accountBar) { [self refreshAccountRow]; }   // keep the RuneLite-account row current when the panel opens
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
            if ([name containsString:f] || [desc containsString:f]) [out addObject:p];
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
    }
    NSIndexPath *ip = [self.pluginTable indexPathForRowAtPoint:pt];
    if (ip) [self togglePluginAtRow:ip.row];
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
    }
    NSDictionary *p = self.pluginList[(NSUInteger)indexPath.row];
    BOOL enabled = [p[@"enabled"] boolValue];
    BOOL active  = [p[@"active"] boolValue];
    BOOL hasConfig = [p[@"hasConfig"] boolValue]
        && [p[@"configGroup"] isKindOfClass:[NSString class]] && [p[@"configGroup"] length] > 0;
    cell.textLabel.text = [p[@"name"] description];
    BOOL pinned = [p[@"pinned"] boolValue];
    cell.imageView.image = pinned ? [UIImage systemImageNamed:@"star.fill"] : nil;
    cell.imageView.tintColor = [UIColor colorWithRed:0.95 green:0.78 blue:0.30 alpha:1.0];
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
        enabled = [[self rendererPref] isEqualToString:rk];
        status = enabled ? @"● selected — restart to apply" : @"○ off";
        statusColor = enabled ? [UIColor colorWithRed:0.45 green:0.85 blue:0.40 alpha:1.0]
                              : [UIColor colorWithWhite:0.6 alpha:1.0];
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

// A renderer-plugin row was toggled: select it (or fall back to the software renderer), save the preference,
// and tell the user it applies on the next launch. No live setPluginEnabled.
- (void)toggleRenderer:(NSString *)rendererKey {
    BOOL turnOn = ![[self rendererPref] isEqualToString:rendererKey];   // tapping the selected one turns it off
    NSString *newPref = turnOn ? rendererKey : @"cpu";
    [[NSUserDefaults standardUserDefaults] setObject:newPref forKey:@"rendererPref"];
    NSString *label = [rendererKey isEqualToString:@"117hd"] ? @"117HD" : @"GPU";
    NSString *msg = turnOn
        ? [NSString stringWithFormat:@"%@ will be your renderer the next time you launch.\n\nFully quit RuneLite (swipe it away) and relaunch to apply.", label]
        : @"The software renderer will be used the next time you launch.\n\nFully quit RuneLite (swipe it away) and relaunch to apply.";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart to apply"
                                                              message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
#if DEBUG
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // CompleteUnlessOpen, NOT Complete: the keepalive keeps these files being written while the screen is
    // locked, and Complete makes a file unwritable once locked. The class is set at creation and persists;
    // opened here while unlocked, the fd/handle stays writable after the device locks.
    NSDictionary *prot = @{NSFileProtectionKey: NSFileProtectionCompleteUnlessOpen};
    NSString *path = [docs stringByAppendingPathComponent:@"hello-shell.log"];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:prot];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:path];
    // Separate raw file for libjvm stdout/stderr, written synchronously (survives a
    // crash) so the [JIT26] mapping trace + the Hello verdict are always retrievable.
    NSString *jpath = [docs stringByAppendingPathComponent:@"jvm-stdio.log"];
    [[NSFileManager defaultManager] createFileAtPath:jpath contents:nil attributes:prot];  // protection persists across open()
    self.jvmFd = open(jpath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0600);
#else
    // QA-P1-12: the daily-driver (Release) build writes no log sinks to the (no-longer-file-shared) Documents
    // dir. logFile stays nil (appendLine's file write no-ops on nil); force jvmFd negative so captureStdio's
    // `jvmFd >= 0` guard skips the dup2 (the default int property is 0, which would alias fd 0/stdin).
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
        // In Release self.logFile is nil (openLogFile writes no sinks) so this is a no-op.
        [self.logFile writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];

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
    // go to the system default. Nothing to capture.
#endif
}

#pragma mark - JIT gate (the W1-audit Claim E)

- (void)startJitPolling {
    self.jitTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        BOOL attached = [JVMLauncher isDebuggerAttached];
        self.statusLabel.text = attached ? @"JIT: CS_DEBUGGED ✓ (ready)" : @"JIT: waiting…";
        self.statusLabel.textColor = attached ? [UIColor systemGreenColor] : [UIColor systemYellowColor];
        // #1: drive the Tap-to-Play cover. Enable the big play button on attach; reflect the gate in its status.
        if (attached) {
            self.playStatusLabel.text = @"Ready to play";
            self.playStatusLabel.textColor = [UIColor systemGreenColor];
            if (!self.playButton.enabled) {
                self.playButton.enabled = YES;
                [UIView animateWithDuration:0.2 animations:^{ self.playButton.alpha = 1.0; }];
            }
        } else {
            self.playStatusLabel.text = @"Attach StikDebug to play…";
            self.playStatusLabel.textColor = [UIColor systemYellowColor];
        }
        if (attached && !self.launchButton.enabled && !self.launched) {
            self.launchButton.enabled = YES;
            self.gpuButton.enabled = YES;
            self.zoneButton.enabled = YES;
            self.zoneFastButton.enabled = YES;
            [self appendLine:@"StikDebug attached — CS_DEBUGGED set. Tap Start JVM."];
        }
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
    if ((iw <= 0 || ih <= 0) && self.renderW > 0) { iw = self.renderW; ih = self.renderH; }  // GPU present: no UIImage
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

// Composite an icon centred on a stone background into one tab image (nearest-neighbour, native px).
- (UIImage *)compositeStone:(UIImage *)stone icon:(UIImage *)icon {
    if (stone == nil) return icon;
    CGSize sz = stone.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetInterpolationQuality(ctx.CGContext, kCGInterpolationNone);
        [stone drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        if (icon) {
            CGFloat ix = floor((sz.width - icon.size.width) / 2.0);
            CGFloat iy = floor((sz.height - icon.size.height) / 2.0);
            [icon drawInRect:CGRectMake(ix, iy, icon.size.width, icon.size.height)];
        }
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

// Decode a JVMLauncher.tabSprites payload into the live chrome images (stones recomposited with each glyph into the
// 14 active/inactive grid tiles; the 3 chat-tab backgrounds). updateChrome/updateChatTabs re-read these ivars every
// tick, so the next frame picks up the new art automatically. Returns YES only for a COMPLETE engine-published set.
- (BOOL)applyTabSpriteJSON:(NSString *)json {
    if (json.length == 0) return NO;
    NSDictionary *d = parseBridgeJSON(json, "ViewController.applyTabSpriteJSON");
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    UIImage *stoneI = imageFromSpriteDict(d[@"stoneInactive"]);
    UIImage *stoneA = imageFromSpriteDict(d[@"stoneActive"]);
    id iconsObj = d[@"icons"];
    NSArray *icons = [iconsObj isKindOfClass:[NSArray class]] ? (NSArray *)iconsObj : nil;
    BOOL gridOK = (stoneI && stoneA && icons.count == 14);
    if (gridOK) {
        NSMutableArray<UIImage *> *inact = [NSMutableArray arrayWithCapacity:14];
        NSMutableArray<UIImage *> *act = [NSMutableArray arrayWithCapacity:14];
        for (int i = 0; i < 14; i++) {
            UIImage *icon = imageFromSpriteDict(icons[i]);
            inact[i] = [self compositeStone:stoneI icon:icon] ?: (UIImage *)[NSNull null];
            act[i]   = [self compositeStone:stoneA icon:icon] ?: (UIImage *)[NSNull null];
        }
        self.tabImgInactive = inact;
        self.tabImgActive = act;
    }
    UIImage *cb  = imageFromSpriteDict(d[@"chatbtn"]);
    UIImage *cbs = imageFromSpriteDict(d[@"chatbtnSelected"]);
    UIImage *cbn = imageFromSpriteDict(d[@"chatbtnNew"]);
    if (cb)  self.chatBtnImg    = cb;
    if (cbs) self.chatBtnSelImg = cbs;
    if (cbn) self.chatBtnNewImg = cbn;
    return [d[@"complete"] boolValue] && gridOK && cb && cbs && cbn;
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

// Build the static 7-tab channel row once, as subviews of the game view (above the blit). Each tab is interactive:
// a tap switches to that channel (tapping the active tab collapses the box); a long-press on a filterable channel
// opens its filter menu (onChatTabLongPress). Sprite-backed two-line RuneScape-font labels (name + filter state)
// like the official app; hidden until the chat is relocated + logged in. updateChatTabs lays them out + states them.
- (void)buildChatTabs {
    // chatBtnImg/SelImg/NewImg are rendered from the live OSRS cache (seeded from disk in buildTabAssets, refreshed
    // by refreshTabSpritesFromCache post-login) — no bundled PNGs. nil until captured: paintChatButton falls back to
    // its opaque stone-brown fill, which the real sprite replaces within a tick of capture.
    self.chatTabButtons = [NSMutableArray arrayWithCapacity:kChatTabCount];
    for (int i = 0; i < kChatTabCount; i++) {
        UIButton *b = [ChatTabButton buttonWithType:UIButtonTypeCustom];   // expanded touch area (kChatTabTouchExpand)
        b.tag = i;
        b.hidden = YES;
        b.adjustsImageWhenHighlighted = NO;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.titleLabel.numberOfLines = 2;   // channel name + filter state, like the official app
        b.titleLabel.lineBreakMode = NSLineBreakByClipping;
        // The background sprite is pixel-art with rounded ends + a vertical gradient; stretch it with bilinear so
        // the enlarged button reads smooth (the official mobile chat scales these the same way).
        b.layer.magnificationFilter = kCAFilterLinear;
        [b addTarget:self action:@selector(onChatTabButton:) forControlEvents:UIControlEventTouchUpInside];
        // Long-press a FILTERABLE channel's tab -> the engine's filter menu (On/Filter/Off/Hide …) via the native
        // big-row overlay (drag to a row, release to select). All/Game have no filter, so they get NO long-press
        // recognizer — otherwise it would recognize on a slow press and cancel the tap (a dead gesture).
        if (kChatTabFilterable[i]) {
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                initWithTarget:self action:@selector(onChatTabLongPress:)];
            lp.minimumPressDuration = 0.4;
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
    self.chatUserDX = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"chatUserDX"];
    self.chatUserDY = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"chatUserDY"];

    self.chatTabsBuilt = YES;
    self.optimisticChatTab = -1;
    self.chatActiveTab = -1;
    [self appendLine:[NSString stringWithFormat:@"[chat] tab buttons built (sprites %@/%@/%@)",
                      self.chatBtnImg ? @"ok" : @"X", self.chatBtnSelImg ? @"ok" : @"X",
                      self.chatBtnNewImg ? @"ok" : @"X"]];
}

// Convert a packed 0xRRGGBB int (the engine widget text colour) to a UIColor; nil for < 0 (unknown).
static UIColor *rgbColor(int rgb) {
    if (rgb < 0) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// The native chat tab row height in ENGINE-CANVAS px (screen-scale independent), so it converts cleanly to the
// engine's CHATAREA push-down. Tall enough for the two text lines (name + filter state).
static int chatRowCanvasH(void) {
    return kChatTabRowCanvasH;
}

// Paint one channel tab button sprite-backed with a two-line RuneScape-font label (name on top,
// filter state below in the engine's state colour). selected -> the gold SELECTED sprite; new -> the unread
// sprite; else the idle sprite. tab = the snapshot entry for channel i (may be nil while collapsed).
- (void)paintChatButton:(UIButton *)b channel:(int)i tab:(NSDictionary *)t selected:(BOOL)selected
               nameFont:(UIFont *)nameFont stateFont:(UIFont *)stateFont {
    BOOL hasNew = [t[@"new"] boolValue];
    UIImage *bg = self.chatBtnImg;
    if (selected) bg = self.chatBtnSelImg;
    else if (hasNew) bg = self.chatBtnNewImg;
    [b setBackgroundImage:bg forState:UIControlStateNormal];
    // The tab sprite has fully-transparent rounded corners; the engine's own chat tab row stays SHOWN underneath
    // (hiding it blanks the whole chat raster), so without an opaque backing the engine tabs peek through those
    // corners. Fill each button with the sprite's stone-brown base so nothing shows through behind the native row.
    b.backgroundColor = [UIColor colorWithRed:66.0/255.0 green:60.0/255.0 blue:51.0/255.0 alpha:1.0];
    b.clipsToBounds = YES;

    NSString *name = (i >= 0 && i < kChatTabCount) ? kChatTabNames[i] : @"";
    NSString *filter = [t[@"filter"] isKindOfClass:[NSString class]] ? t[@"filter"] : @"";
    UIColor *nameColor = rgbColor(t ? [t[@"labelColor"] intValue] : -1)
        ?: [UIColor colorWithRed:1.0 green:0.97 blue:0.85 alpha:1.0];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByClipping;
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:name
        attributes:@{NSFontAttributeName: nameFont, NSForegroundColorAttributeName: nameColor,
                     NSParagraphStyleAttributeName: ps}];
    if (filter.length) {
        UIColor *fc = rgbColor([t[@"filterColor"] intValue]) ?: [UIColor colorWithRed:0.0 green:0.9 blue:0.0 alpha:1.0];
        [title appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@"\n" stringByAppendingString:filter]
            attributes:@{NSFontAttributeName: stateFont, NSForegroundColorAttributeName: fc,
                         NSParagraphStyleAttributeName: ps}]];
    }
    [b setAttributedTitle:title forState:UIControlStateNormal];
}

// Lay out + state the static 7-tab channel row from the chat snapshot each tick. Mirrors updateChrome: hides
// everything (revealing the engine's own chat) when the native chrome is toggled off or the layout is unsupported
// (not Classic/164). The row spans the chat width (kChatW) at the chat origin; content (sprite + label) is
// refreshed every tick and the just-tapped tab is held selected until the engine sprite catches up.
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
    // LAYOUT GUARD (same as updateChrome): the native HUD only works in the Classic resizable layout (164).
    if ([d[@"topLevelId"] intValue] != 164) { [self hideChatTabs]; return; }
    // Dialogue open: the engine renders its own dialogue (NPC/player/options/level-up/message/make-X) — an
    // OPAQUE parchment + head — into the relocated chatbox region at the top, exactly like desktop. Hide the
    // native chat veneer (lines + input) so it doesn't overlap the parchment; it auto-restores when the dialogue
    // closes (the snapshot's dialogueActive flips false).
    BOOL dlg = [d[@"dialogueActive"] boolValue];
    if (dlg != self.chatDialogueActive) {
        self.chatDialogueActive = dlg;
        // Auto-open/close: a collapsed chat hides the engine tabs -> the engine dialogue raster is suppressed. So
        // un-collapse for the dialogue's duration and restore the collapsed state when it closes (mirrors Android;
        // official-mobile behaviour). Native is the single owner of chatCollapsed.
        if (dlg && self.chatCollapsed) {
            self.savedCollapsedForDialogue = YES;
            self.chatCollapsed = NO;
            [JVMLauncher setEngineChatCollapsed:NO];
        } else if (!dlg && self.savedCollapsedForDialogue) {
            self.savedCollapsedForDialogue = NO;
            self.chatCollapsed = YES;
            [JVMLauncher setEngineChatCollapsed:YES];
        }
        [self appendLine:dlg ? @"[chat] dialogue open -> native chat hidden, engine dialogue (opaque) shown"
                             : @"[chat] dialogue closed -> native chat veneer restored"];
    }
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
    self.chatScrollable = !self.chatCollapsed;   // chat open + supported -> finger-scroll (off while collapsed)

    CGFloat W = self.view.bounds.size.width;
    CGFloat s = W / (CGFloat)self.renderW;           // canvas px -> screen pt (uniform: render aspect == screen)
    CGFloat rowX = [d[@"chatX"] intValue] * s;
    CGFloat rowY = [d[@"chatY"] intValue] * s;
    CGFloat rowW = kChatW * s;
    CGFloat rowH = kChatTabRowCanvasH * s;
    CGFloat tabW = rowW / kChatTabCount;
    [JVMLauncher setEngineChatTabRowHeight:kChatTabRowCanvasH];   // push messages below the (taller) tab row
    [JVMLauncher setEngineChatAreaWidth:0];                        // chat keeps its natural 519 width

    // The native tab row is ALWAYS shown (no collapsible bubble). "Collapse" (tap the active tab) only hides the
    // engine MESSAGE area — the bridge hides the engine chat container while the tabs stay put. The tabs are also
    // hidden when a forefront window (bank/GE/…) is open so the chat sits behind it (windowOpen in the snapshot).
    if ([d[@"windowOpen"] boolValue]) { [self hideChatTabs]; return; }

    // The ENGINE renders the chat MESSAGES itself now (its tabs stay shown so the raster isn't suppressed; the
    // native tab row below just covers the engine's small tabs). So we no longer recreate the message lines —
    // keep the native message view hidden and let the engine draw the real colored text + scrollbar underneath.
    self.chatMessagesView.hidden = YES;

    // Two text lines: channel name (top) + filter state (bottom). Size both to the row height.
    CGFloat nameSize = floor(rowH * 0.40);
    CGFloat stateSize = floor(rowH * 0.34);
    UIFont *nameFont = [UIFont fontWithName:@"RuneScape" size:nameSize] ?: [UIFont boldSystemFontOfSize:nameSize];
    UIFont *stateFont = [UIFont fontWithName:@"RuneScape" size:stateSize] ?: [UIFont systemFontOfSize:stateSize];

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

    // Lay out + paint all 7 tabs as a STATIC row (no pill, no fan): each equal-width, spanning the chat width,
    // always visible, tap-to-switch. Highlight the (sticky) active tab while open; none while collapsed.
    for (int i = 0; i < kChatTabCount; i++) {
        UIButton *b = self.chatTabButtons[i];
        b.frame = CGRectMake(floor(rowX + i * tabW), floor(rowY), ceil(tabW), ceil(rowH));
        NSDictionary *t = (i < (int)tabs.count && [tabs[i] isKindOfClass:[NSDictionary class]]) ? tabs[i] : nil;
        [self paintChatButton:b channel:i tab:t selected:(!self.chatCollapsed && i == self.chatActiveTab)
                     nameFont:nameFont stateFont:stateFont];
        b.hidden = NO;
    }
}

- (void)hideChatTabs {
    self.chatScrollable = NO;   // chat not open -> drags fall through to the camera
    self.chatMessagesView.hidden = YES;
    for (UIButton *b in self.chatTabButtons) b.hidden = YES;
    // Restore the engine's own (small) chat tab row + native width whenever the native tabs aren't shown.
    [JVMLauncher setEngineChatTabRowHeight:0];
    [JVMLauncher setEngineChatAreaWidth:0];
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
    NSString *js = [JVMLauncher dialogueJson];
    if (js.length == 0) { [self hideDialogue]; return; }
    NSDictionary *d = parseBridgeJSON(js, "ViewController.updateDialogueView");
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"type"] isKindOfClass:[NSString class]]) { [self hideDialogue]; return; }

    [self ensureDialogueView];
    CGFloat s = self.view.bounds.size.width / (CGFloat)self.renderW;
    CGFloat boxX = floor([cd[@"chatX"] intValue] * s);
    CGFloat boxY = floor([cd[@"chatY"] intValue] * s);
    CGFloat boxW = ceil(kChatW * s);
    CGFloat boxH = ceil((kChatTabRowCanvasH + kChatContentCanvasH) * s);
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

    if (![js isEqualToString:self.lastDialogueJson]) {
        self.lastDialogueJson = js;
        [self rebuildDialogueContent:d scale:s];
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

// Continue tap -> SPACE (OSRS "space bar to continue"); option tap -> its number key. postText sends the full
// KEY_PRESSED+TYPED+RELEASED for the char, so the engine's (occluded but live) dialogue handler advances/selects.
- (void)onDialogueContinue {
    if (!self.dialogueView || self.dialogueView.hidden) return;
    NSString *js = self.lastDialogueJson;
    if (js && [js containsString:@"\"type\":\"options\""]) return;   // options need a choice, not a blind continue
    // Prefer a PRECISE click on the engine's live CONTINUE widget (works regardless of the "space bar to continue"
    // setting); fall back to SPACE if its bounds weren't published.
    if (self.dialogueContinuePoint.x >= 0) {
        [JVMLauncher postClickPreciseX:(int)self.dialogueContinuePoint.x y:(int)self.dialogueContinuePoint.y button:1];
        [self appendLine:[NSString stringWithFormat:@"[shell] dialogue continue (click %.0f,%.0f)",
            self.dialogueContinuePoint.x, self.dialogueContinuePoint.y]];
    } else {
        [JVMLauncher postText:@" "];
        [self appendLine:@"[shell] dialogue continue (space)"];
    }
}

- (void)onDialogueOption:(UIButton *)b {
    NSInteger digit = b.tag;
    if (digit < 1 || digit > 9) return;
    [JVMLauncher postText:[NSString stringWithFormat:@"%ld", (long)digit]];
    [self appendLine:[NSString stringWithFormat:@"[shell] dialogue option %ld", (long)digit]];
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
    if (self.renderH > 0 && by >= self.renderH) return NO;   // shoved off-canvas (e.g. while the chat is collapsed)
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
            // While collapsed the engine filter button is shoved off-canvas (y~3000), so a right-click there opens
            // nothing. Reopen the box first; the engine restores the widget next snapshot, so a follow-up long-press
            // then opens the filter (rather than this gesture posting a dead off-canvas click).
            if (self.chatCollapsed) {
                self.chatCollapsed = NO;
                [JVMLauncher setEngineChatCollapsed:NO];
                [self appendLine:@"[chat] long-press on collapsed chat -> expand first"];
                break;
            }
            int cx = 0, cy = 0;
            if (![self engineChatButtonCenterForTag:b.tag x:&cx y:&cy]) return;
            [self openEngineMenuAtGameX:cx gameY:cy anchor:loc];
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

- (void)onFatalErrorClose {
    exit(0); // same as promptRestartToPlay's restart: the applet is dead; a fresh process is the only recovery
}

// PERF-MEMORY-THERMAL-01: read the LIVE 117HD sceneResolutionScale off the config bridge. Returns -1 while
// the config isn't readable (bridge not up / plugin config not loaded) so the caller defers instead of
// restoring a wrong default — the governor must never raise a user's deliberately lower scale.
- (int)thermalReadLiveScale {
    NSString *json = [JVMLauncher mobilePluginConfig:@"hd"];
    if (json.length == 0)
        return -1;
    NSDictionary *d = parseBridgeJSON(json, "ViewController.thermalReadLiveScale");
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

// PERF-MEMORY-THERMAL-01: one governor evaluation (see the property block for the full contract). Called
// ~0.5 Hz from onDisplayTick on 117HD boots only. Cheap while waiting (one early-out or one JSON parse);
// after the baseline is captured it's an enum compare + at most one bridge write per thermal transition.
- (void)thermalGovernorTick {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (self.thermalBaselineScale <= 0) {
        // Self-heal a leaked throttle first (a prior session killed mid-throttle never restored — the
        // persisted config still holds the stepped-down value). The marker records the TRUE baseline.
        int leaked = (int)[ud integerForKey:@"thermalBaselineScale"];
        if (leaked > 0) {
            if ([JVMLauncher mobileSetConfigGroup:@"hd"
                                              key:@"sceneResolutionScale"
                                            value:[NSString stringWithFormat:@"%d", leaked]] == nil) {
                return; // bridge not up yet — retry next tick, keep the marker
            }
            self.thermalBaselineScale = leaked;
            self.thermalAppliedScale = leaked;
            [ud removeObjectForKey:@"thermalBaselineScale"];
            [self appendLine:[NSString stringWithFormat:
                                           @"[shell] thermal: recovered a leaked throttle -> restored sceneResolutionScale=%d", leaked]];
        } else {
            int live = [self thermalReadLiveScale];
            if (live <= 0)
                return; // config not ready — defer rather than guess a baseline
            self.thermalBaselineScale = live;
            self.thermalAppliedScale = live;
            [self appendLine:[NSString stringWithFormat:
                                           @"[shell] thermal governor armed (117HD) — baseline sceneResolutionScale=%d", live]];
        }
    }
    // Pressure -> scale: nominal/fair keep the baseline; serious and critical cap progressively lower
    // (never above the baseline, so a low-res user config is honoured). Same steps as Android (65 / 50).
    NSProcessInfoThermalState st = [NSProcessInfo processInfo].thermalState;
    int baseline = self.thermalBaselineScale;
    int target = baseline;
    if (st == NSProcessInfoThermalStateCritical)
        target = MIN(baseline, 50);
    else if (st == NSProcessInfoThermalStateSerious)
        target = MIN(baseline, 65);
    if (target == self.thermalAppliedScale)
        return;
    if ([JVMLauncher mobileSetConfigGroup:@"hd"
                                      key:@"sceneResolutionScale"
                                    value:[NSString stringWithFormat:@"%d", target]] == nil) {
        return; // write didn't take — leave appliedScale unchanged so the next tick retries
    }
    int prev = self.thermalAppliedScale;
    self.thermalAppliedScale = target;
    if (target < baseline)
        [ud setInteger:baseline forKey:@"thermalBaselineScale"];
    else
        [ud removeObjectForKey:@"thermalBaselineScale"];
    [self appendLine:[NSString stringWithFormat:
                                   @"[shell] thermal state=%ld -> sceneResolutionScale %d->%d (baseline=%d)", (long)st, prev, target, baseline]];
}

- (void)updateChrome {
    NSString *snap = [JVMLauncher chromeSnapshot];
    if (snap.length == 0) return;
    NSDictionary *d = parseBridgeJSON(snap, "ViewController.updateChrome");
    self.tabRailBg.hidden = YES;   // mobile cells are individually styled; no solid rail strip behind them
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"loggedIn"] boolValue] || self.mapOpen) {
        // (mapOpen: the fullscreen world map owns the screen — the native grid would cover it + steal taps)
        for (UIButton *btn in self.tabButtons) btn.hidden = YES;
        for (UIView *cv in self.stoneCovers) cv.hidden = YES;
        return;
    }
    // LAYOUT GUARD: the native HUD overlay only works in the Classic resizable layout (PRE_EOC = toplevel 164). If
    // the in-game OSRS "resizable layout" setting is switched to Modern (OSRS_STRETCH = 165) or anything else, our
    // tab grid targets widgets that don't exist, so the tab buttons open nothing. Rather than soft-lock the user,
    // hide the native overlay and un-hide the engine's OWN tab stones so the real game HUD renders + is tappable
    // (the user can then switch the layout back). Re-engages automatically once back in toplevel 164.
    int topLevelId = [d[@"topLevelId"] intValue];
    if (topLevelId != 164) {
        for (UIButton *btn in self.tabButtons) btn.hidden = YES;
        for (UIView *cv in self.stoneCovers) cv.hidden = YES;
        [JVMLauncher setEngineStonesHidden:NO];
        if (self.framesShown % 120 == 0) {
            [self appendLine:[NSString stringWithFormat:@"[chrome] unsupported layout topLevel=%d (not 164/Classic) -> native HUD off, engine HUD shown", topLevelId]];
        }
        return;
    }
    [JVMLauncher setEngineStonesHidden:YES];   // supported Classic layout: the native grid replaces the engine stones
    int active = [d[@"activeTab"] intValue];

    // All 14 tabs in ONE 2-column grid at the BOTTOM-RIGHT — the official OSRS-mobile arrangement. The engine
    // stones are HIDDEN (setEngineStonesHidden), so these native buttons ARE the tabs; a tap replays the stone's
    // op script to open the tab (onTabButton) — no cover patch / gray box. TAB_GRID_ORDER maps grid slot ->
    // engine tab index, row-major (slot 0 = top-left, 1 = top-right, …). Tweak it to match the official order.
    // Cells auto-fit the bottom ~56% of the safe height so the grid never collides with the minimap (top-right).
    static const int TAB_GRID_ORDER[14] = { 3, 1,  4, 2,  5, 13,  6, 7,  0, 12,  8, 9,  10, 11 };
    UIEdgeInsets ins = self.view.safeAreaInsets;
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    const CGFloat gap = 0.0, margin = 6.0;   // NO gap — the stones tile flush, like the official app
    // TOUCH-1: 44pt cells are geometrically impossible here (7 rows must fit under the top-right minimap —
    // the 0.56 band IS that clearance), so the cells stay official-mobile-sized and the tappability gap is
    // closed with outward-only hit slop per grid edge (TabGridButton) — edge taps land, interiors stay exact.
    CGFloat availH = (H - ins.top - ins.bottom) * 0.56;
    CGFloat cell = MIN(48.0, availH / 7.0);
    CGFloat gridW = 2 * cell + gap, gridH = 7 * cell + 6 * gap;
    CGFloat gx0 = W - ins.right - margin - gridW;
    CGFloat gy0 = H - ins.bottom - margin - gridH;
    for (int slot = 0; slot < 14; slot++) {
        int i = TAB_GRID_ORDER[slot];
        UIButton *btn = self.tabButtons[i];
        int col = slot % 2, row = slot / 2;
        btn.frame = CGRectMake(gx0 + col * (cell + gap), gy0 + row * (cell + gap), cell, cell);
        if ([btn isKindOfClass:[TabGridButton class]]) {
            ((TabGridButton *)btn).hitOutset = UIEdgeInsetsMake(
                row == 0 ? 4.0 : 0.0,                 // top row: into the gap below the minimap
                col == 0 ? 10.0 : 0.0,                // left column: into the open scene
                row == 6 ? margin + ins.bottom : 0.0, // bottom row: through the margin to the screen edge
                col == 1 ? margin + ins.right : 0.0); // right column: through the margin to the screen edge
        }
        BOOL isActive = (i == active);
        // Authentic composited tab image (live-cache OSRS stone + icon). Active = red stone, inactive = grey.
        NSArray<UIImage *> *imgs = isActive ? self.tabImgActive : self.tabImgInactive;
        UIImage *img = (i < (int)imgs.count && [imgs[i] isKindOfClass:[UIImage class]]) ? imgs[i] : nil;
        [btn setImage:img forState:UIControlStateNormal];
        // Until the sprites are captured from the cache (first-ever login, pre-capture), show an opaque stone-brown
        // tile so the grid reads as buttons rather than vanishing; the real stone replaces it within a tick.
        if (img) {
            btn.backgroundColor = [UIColor clearColor];
            btn.layer.cornerRadius = 0.0;
        } else {
            btn.backgroundColor = isActive ? [UIColor colorWithRed:96.0/255.0 green:32.0/255.0 blue:24.0/255.0 alpha:1.0]
                                           : [UIColor colorWithRed:66.0/255.0 green:60.0/255.0 blue:51.0/255.0 alpha:1.0];
            btn.layer.cornerRadius = 3.0;
            btn.clipsToBounds = YES;
        }
        btn.layer.borderWidth = 0.0;
        btn.alpha = 1.0;   // active vs inactive carried by the red/grey stone itself
        btn.hidden = NO;
    }

    // Relocate the engine side panel (the open inventory/skills/etc. "menu") to sit flush LEFT of the tab grid,
    // top-aligned — the official OSRS-mobile arrangement. Convert the grid's screen-point edge to canvas px
    // (canvasPx = pt * renderW/W); the side panel width comes from the chrome snapshot (fixed engine px).
    if (self.renderW > 0 && W > 0) {
        CGFloat k = (CGFloat)self.renderW / W;
        int sideW = 204;   // fallback until the panel is open and reports its real width
        NSArray *sc = [d[@"sideContainer"] isKindOfClass:[NSArray class]] ? d[@"sideContainer"] : nil;
        if (sc.count >= 4 && [sc[2] intValue] > 0) sideW = [sc[2] intValue];
        int sideX = (int)lround(gx0 * k) - sideW;   // right edge flush against the grid's left edge
        // The stones are hidden, so there is no bottom row to avoid — align the panel's top with the grid top.
        int sideY = (int)lround(gy0 * k);
        if (sideX < 0) sideX = 0;
        if (sideY < 0) sideY = 0;
        [JVMLauncher relocateEngineSidePanelX:sideX y:sideY];
    }
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
        for (UIButton *btn in self.tabButtons) btn.hidden = YES;
        for (UIView *cv in self.stoneCovers) cv.hidden = YES;   // reveal the real stones in the fallback view
        [JVMLauncher setEngineStonesHidden:NO];   // flip HudVeneerBridge.hideStones OFF so the engine's own tab
                                                  // stones reappear; without this the per-frame re-hide leaves
                                                  // NO tab access at all (native grid hidden + stones still hidden)
        self.tabRailBg.hidden = YES;
        [self hideChatTabs];   // also restores the engine's own chat row (setEngineChatTabRowHeight:0)
    }
    // (When toggled back ON, updateChatTabs re-applies the enlarged row height each tick.)
    [self appendLine:[NSString stringWithFormat:@"[chrome] rails %@", self.chromeVisible ? @"ON" : @"OFF"]];
}

// W3 hybrid-chrome device de-risk: prove the native side can (a) READ the MobileChromeBridge snapshot on
// device and (b) SWITCH the active tab by proxying a click on a live tab-stone centre through the proven
// JavaBridge.onClick — the cover-and-proxy seam, before any native rails are drawn. Emits a single
// bash-parseable verdict line to hello-shell.log (md5-gated off-device).
- (void)onChromeTest {
    if (![JVMLauncher bridgeReady]) { [self appendLine:@"[chrome-dev] bridge not ready (log in first)"]; return; }
    NSString *snap = [JVMLauncher chromeSnapshot];
    if (snap.length == 0) { [self appendLine:@"[chrome-dev] snapshot nil/empty"]; return; }
    // Log a trimmed copy so the device snapshot bounds are recoverable for building the rails next.
    NSString *trim = snap.length > 600 ? [snap substringToIndex:600] : snap;
    [self appendLine:[NSString stringWithFormat:@"[chrome-dev] snapshot=%@", trim]];

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[snap dataUsingEncoding:NSUTF8StringEncoding]
                                             options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        [self appendLine:[NSString stringWithFormat:@"[chrome-dev] parse failed: %@", err.localizedDescription]];
        return;
    }
    NSDictionary *d = (NSDictionary *)obj;
    if (![d[@"loggedIn"] boolValue]) { [self appendLine:@"[chrome-dev] not LOGGED_IN yet — log in then retry"]; return; }
    int activeBefore = [d[@"activeTab"] intValue];
    NSArray *tabs = [d[@"tabs"] isKindOfClass:[NSArray class]] ? d[@"tabs"] : @[];

    // Pick a target: the first present tab stone (non-null bounds) whose index != the active tab.
    int target = -1, tcx = 0, tcy = 0, present = 0;
    for (NSUInteger i = 0; i < tabs.count; i++) {
        id t = tabs[i];
        if (![t isKindOfClass:[NSArray class]] || [(NSArray *)t count] < 4) continue;
        present++;
        if (target < 0 && (int)i != activeBefore) {
            NSArray *b = (NSArray *)t;
            target = (int)i;
            tcx = [b[0] intValue] + [b[2] intValue] / 2;
            tcy = [b[1] intValue] + [b[3] intValue] / 2;
        }
    }
    if (target < 0) { [self appendLine:[NSString stringWithFormat:@"[chrome-dev] no switchable tab (present=%d active=%d)", present, activeBefore]]; return; }

    [self appendLine:[NSString stringWithFormat:@"[chrome-dev] read=ok present=%d activeBefore=%d target=%d centre=%d,%d -> proxy click",
                      present, activeBefore, target, tcx, tcy]];
    [JVMLauncher postClickX:tcx y:tcy button:1];

    // Re-read after the engine has had a few ticks to switch + the bridge to re-snapshot, then verdict.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *snap2 = [JVMLauncher chromeSnapshot];
        NSDictionary *d2 = [snap2 isKindOfClass:[NSString class]]
            ? [NSJSONSerialization JSONObjectWithData:[snap2 dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]
            : nil;
        int activeAfter = [d2 isKindOfClass:[NSDictionary class]] ? [d2[@"activeTab"] intValue] : -999;
        BOOL switched = (activeAfter == target);
        [self appendLine:[NSString stringWithFormat:
            @"[chrome-dev] CHROME_DEVICE read=ok present=%d activeBefore=%d target=%d activeAfter=%d switched=%@",
            present, activeBefore, target, activeAfter, switched ? @"yes" : @"no"]];
    });
}

// GPU Route C — long-press the launch button to route into the L1 kill-test (single fire on press-began).
- (void)onLaunchRouteCL1Gesture:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.launched) return;
    self.pendingRouteCL1 = YES;
    [self onLaunch];
}

- (void)onLaunchRouteCGpuGesture:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.launched) return;
    // GPU Route C black-scene bisection: two-finger long-press = GPU in FIXED mode (NO headless.resize, stays
    // 765x503). The CPU path renders the scene fine at the resizable 1304x600 + viewport=0x0 state, while GPU
    // resizable never dispatches the scene render (drawScene=0). Fixed mode isolates whether the resizable
    // viewport/scene-dispatch path is the GPU-broken one. The ▶ Run GPU button stays GPU + resize.
    self.pendingRouteCGpu = YES;
    self.pendingRouteCGpuNoResize = YES;
    [self onLaunch];
}

// "117HD readback" button: 117HD resizable on the proven glReadPixels READBACK present (no CAEAGLLayer) — the
// fallback if the default direct-present path scans out black or regresses on a future change. Same resizable
// canvas/sharpness/chrome as the green button; just the slower present (~15fps vs ~18+).
- (void)onLaunchZoneReadback {
    if (self.launched) return;
    self.pendingRouteCZone = YES;
    [self onLaunch];
}

// THREE-FINGER long-press: boot 117HD/Zone in the FIXED 765x503 fallback (no headless.resize) — the proven
// readback path from Zone bring-up. The one-tap buttons cover resizable readback (green) + resizable direct
// present (⚡); this gesture stays as the fixed-mode escape hatch.
- (void)onLaunchRouteCZoneGesture:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.launched) return;
    self.pendingRouteCZone = YES;
    self.pendingRouteCGpuNoResize = YES;
    [self onLaunch];
}

// GPU Route C — dedicated one-tap button (same effect as the two-finger long-press, but unambiguous).
- (void)onLaunchGpu {
    if (self.launched) return;
    self.pendingRouteCGpu = YES;
    [self onLaunch];
}

// The DEFAULT 117HD boot (one-tap green button): RESIZABLE + DIRECT present. Resizable = the engine canvas resizes
// to renderW×renderH (~1302x600) after login (sharp + the native Jagex-mobile chrome activates, all gated on
// client.isResized()); direct present = RLHD renders straight into a CAEAGLLayer drawable scanned out by
// presentRenderbuffer (no per-frame glReadPixels readback — device-confirmed faster). The CAEAGLLayer starts hidden
// so the CPU login/loading blit shows during boot and is revealed only once the world is warmed up (no black boot,
// no sky flash). Fallbacks: the "117HD readback" button (resizable readback) and the 3-finger gesture (fixed 765).
- (void)onLaunchZone {
    if (self.launched) return;
    self.pendingRouteCZone = YES;
    self.pendingRouteCZoneDirect = YES;
    [self onLaunch];
}

- (void)onLaunch {
    if (self.launched) return;
    // If the login web view ran this session, WebKit is resident and the JVM would crash at code-cache
    // init (the JIT brk can't be serviced). Require a fresh process first — restart instead of launching.
    if (self.webKitUsedThisSession) { [self promptRestartToPlay]; return; }
    self.launched = YES;
    self.launchButton.enabled = NO;
    self.gpuButton.enabled = NO;
    self.zoneButton.enabled = NO;
    self.zoneFastButton.enabled = NO;
    [self.jitTimer invalidate];
    [self captureStdio];

    // Full-screen landscape: collapse the debug panel so the game owns the whole screen. The ≡ toggle
    // re-opens it (logs/canary), and logs still go to Documents/hello-shell.log; the ⌨ control stays.
    self.debugPanel.hidden = YES;

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
    launcher.routecL1Mode = self.pendingRouteCL1;   // GPU Route C L1 kill-test (set by the long-press gesture)
    launcher.routecGpuMode = self.pendingRouteCGpu;  // GPU Route C full path (two-finger long-press)
    launcher.routecZoneMode = self.pendingRouteCZone; // GPU Zone 117HD path (three-finger long-press)
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
    CGFloat aspect = (sh > 0 ? sw / sh : 2.0);
    // Render height is the sharpness<->FPS<->UI-SIZE dial: the engine SOFTWARE-renders at renderW×renderH every
    // frame (no GPU on iOS), so a LOWER renderH = bigger UI on screen. The minimap can't be enlarged on its own
    // (the engine pins its orbs + breaks the terrain raster if the globe is repositioned — see HudVeneerBridge),
    // so we scale the WHOLE HUD up via renderH to make the minimap bigger. 600 was the prior "official-sized"
    // value; 540 enlarges the HUD ~11% (bigger minimap/chat/orbs). Watch the right column (minimap top + native
    // tab grid bottom) for overlap as this drops (480 collided historically) — tune here.
    // DISP-1: user-selectable "Interface size" — a smaller canvas = a larger HUD. Persisted; applied at launch
    // (long-press the ⚙ button to change). Default + clamp to the safe 480..600 band proven not to overlap.
    int renderH = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"interfaceRenderH"];
    if (renderH < 480 || renderH > 600) renderH = 540;
    int renderW = (int)lround(renderH * aspect);
    self.renderW = renderW;
    self.renderH = renderH;
    if (self.pendingRouteCGpuNoResize) {
        // GPU Route C bisection: leave the canvas at the classic fixed 765x503 (no resizable switch) so we can
        // tell whether the scene render is suppressed by GPU mode itself or only by the resizable-layout path.
        launcher.resizeSpec = nil;
        [self appendLine:@"[shell] *** GPU Route C — FIXED mode (no headless.resize, 765x503 bisection) ***"];
    } else {
        launcher.resizeSpec = [NSString stringWithFormat:@"%dx%d", renderW, renderH];
        [self appendLine:[NSString stringWithFormat:@"[shell] full-screen %.0fx%.0f aspect %.3f -> render %@",
                          sw, sh, aspect, launcher.resizeSpec]];
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
            gl.frame = self.screen.bounds;
            gl.opaque = YES;
            gl.contentsScale = (sh > 0 ? (CGFloat)renderH / sh : 1.0);   // drawable = renderW x renderH (== engine canvas)
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
        ml.frame = self.screen.bounds;
        ml.opaque = YES;
        ml.framebufferOnly = NO;
        ml.drawableSize = CGSizeMake(renderW, renderH);
        ml.contentsScale = (sh > 0 ? (CGFloat)renderH / sh : 1.0);
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

    NSThread *t = [[NSThread alloc] initWithBlock:^{
        [launcher runProbesWithLog:log];
        // VM lifecycle done; tear the render loop + bridge down on main, then release the assertion. (Unreached
        // today — DestroyJavaVM blocks on the engine's non-daemon threads — but it's the correct clean teardown
        // for a future real exit: stop driving JNI into a destroyed VM instead of freezing on the last frame.)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLine:@"[shell] JVM thread returned — tearing down render loop + bridge"];
            [self.displayLink invalidate];
            self.displayLink = nil;
            [self teardownPictureInPicture];
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

- (void)updateHudLayout {
    if (self.engineChatRelocated) return;
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
    int topC   = (int)lround(ins.top * k);
    int leftC  = (int)lround(ins.left * k);
    int rightC = (int)lround(ins.right * k);
    const int m = 8;                          // canvas-px margin from the safe edge
    const int MM_W = 211;                     // minimap+orbs cluster width (fixed engine px, from the de-risk)
    // Make the minimap BIGGER: enlarge the engine globe + reposition its chrome (HudVeneerBridge.setMinimapScale).
    // The globe is right-anchored, so it grows left+down within the cluster — the right edge stays at MM_W, so the
    // cluster still aligns to the right safe edge; only the orbs/compass spread further left/down (into the gap
    // between the top-left chat and the top-right minimap). 0/100 = natural size.
    const int kMinimapScalePct = 100;   // 100 = natural (the engine pins the orbs, so a bigger globe can't be wrapped cleanly)

    self.chatBaseX = leftC + m;
    self.chatBaseY = topC + m;
    int mmX = self.renderW - MM_W - rightC - m;
    int mmY = topC + m;

    // transparent:YES = OSRS-mobile translucent chat (text over the scene, no opaque box) — the official look.
    // Apply the persisted user drag offset to the base anchor (relocates the engine chat + sets the hit/scroll rects).
    [self applyChatRelocate];
    // W3 A3: the native veneer recreates the tab row BIGGER (engine push-down applied per-tick in updateChatTabs).
    [JVMLauncher relocateEngineMinimapX:mmX y:mmY];
    [JVMLauncher setEngineMinimapScale:kMinimapScalePct];   // enlarge the globe + reposition its chrome to hug it
    [JVMLauncher setEngineStonesHidden:YES];   // the native 2-col grid replaces them (no cover patch / gray box)
    // Overlay snap-corner safe frame: plugin overlays snapped to a corner (Quest Helper's top-left guidance
    // panel etc.) clear the curved bezel/notch; the engine also drops the top-left corner below the chat.
    int botC = (int)lround(ins.bottom * k);
    [JVMLauncher setEngineOverlaySafeInsetsL:leftC t:topC r:rightC b:botC];
    // The whole enlarged tab row is UI: a stray tap in it (between native buttons) should be a precise click, not
    // a walk. The native buttons own their taps; this rect just keeps any leak from drawing a walk ring.
    [self appendLine:[NSString stringWithFormat:@"[hud] relocate chat->%d,%d(+%d,%d) minimap->%d,%d (insets L%d T%d R%d k%.2f)",
                      self.chatBaseX, self.chatBaseY, self.chatUserDX, self.chatUserDY, mmX, mmY, leftC, topC, rightC, k]];
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
    self.chatHitCanvas = CGRectMake(chatX, chatY, kChatW, chatRowCanvasH());
    self.chatScrollCanvas = CGRectMake(chatX, chatY, kChatW, chatRowCanvasH() + kChatContentCanvasH);
}

- (int)clampChatX:(int)x {
    int maxX = self.renderW - kChatW;
    if (maxX < 0) maxX = 0;
    return x < 0 ? 0 : (x > maxX ? maxX : x);
}

- (int)clampChatY:(int)y {
    int boxH = chatRowCanvasH() + kChatContentCanvasH;
    int maxY = self.renderH - boxH;
    if (maxY < 0) maxY = 0;
    return y < 0 ? 0 : (y > maxY ? maxY : y);
}

// ---- OverlayEditChatHost: the chatbox is repositioned in overlay edit-mode (a draggable "Chat" handle) ----

- (CGRect)overlayEditChatCanvasRect {
    if (!kChatVeneerEnabled) return CGRectNull;   // veneer removed: no native chat to drag in overlay edit-mode
    if (self.renderW <= 0 || self.chatBaseX <= 0) return CGRectNull;   // not placed yet
    int chatX = [self clampChatX:self.chatBaseX + self.chatUserDX];
    int chatY = [self clampChatY:self.chatBaseY + self.chatUserDY];
    return CGRectMake(chatX, chatY, kChatW, chatRowCanvasH() + kChatContentCanvasH);
}

- (void)overlayEditMoveChatToCanvasX:(int)x y:(int)y {
    self.chatUserDX = [self clampChatX:x] - self.chatBaseX;
    self.chatUserDY = [self clampChatY:y] - self.chatBaseY;
    [self applyChatRelocate];   // tab row + messages follow via the snapshot next tick
}

- (void)overlayEditCommitChatMove {
    [[NSUserDefaults standardUserDefaults] setInteger:self.chatUserDX forKey:@"chatUserDX"];
    [[NSUserDefaults standardUserDefaults] setInteger:self.chatUserDY forKey:@"chatUserDY"];
    [self appendLine:[NSString stringWithFormat:@"[chat] moved -> offset %d,%d", self.chatUserDX, self.chatUserDY]];
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
    // fully on-screen and tappable.
    self.keyboardButton.hidden = open;
    self.shiftButton.hidden = open;
    self.screenshotButton.hidden = open;
    self.panelDock.view.hidden = open;
    self.debugToggle.hidden = open;
    self.chromeToggle.hidden = open;
    self.pluginButton.hidden = open;
    [self appendLine:open ? @"[map] world map OPEN -> map pan/taps, chrome hidden"
                          : @"[map] world map closed -> chrome restored"];
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
    // 117HD crash cookie: CLEAR on the very first GL present (survival proof — deliberately looser than the
    // reveal below, which also waits for sceneWarmedUp; a user quitting at the login screen must not demote),
    // ARM once the JVM is demonstrably running a 117HD boot (a frame has published) but hasn't presented yet.
    // Clear is checked first so a boot that presents before the shell's first CPU blit never arms at all.
    // Gated on the 117HD flag (not just gpuPresentArmed, which an ANGLE build also sets for base GPU): only
    // a 117HD death may write the marker, because only the 117HD pref consumes it at the next Play tap.
    if (self.pendingRouteCZoneDirect && self.gpuPresentArmed && !self.hdBootCookieSettled) {
        if ([RouteCBridge hasPresentedFrame]) {
            [self hdBootCookieClear];
            self.hdBootCookieArmed = NO;
            self.hdBootCookieSettled = YES;
            [self appendLine:@"[shell] 117HD first GL present — crash cookie cleared"];
        } else if (!self.hdBootCookieArmed && self.framesShown > 0) {
            [self hdBootCookieArm];
            self.hdBootCookieArmed = YES;
            [self appendLine:@"[shell] 117HD boot underway — crash cookie armed (clears on first GL present)"];
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
            // 117HD pip-present: the bridge takes over the PiP layer (the shell's CPU pump stops via the
            // gpuPresent gates); first enqueued frame is the warmed-up world, matching the old reveal UX.
            [RouteCBridge setPipPresentEnabled:YES];
            [self appendLine:@"[shell] GPU pip-present LIVE (world warmed up — bridge feeds the PiP layer)"];
        }
    }
    if (self.gpuPresent) {
        // GPU direct-present: the engine renders straight into the CAEAGLLayer and presents on its own thread, so
        // there is no per-tick blit here. Keep the tick alive for the heartbeat + native HUD/chrome refresh below.
        self.framesShown++;
    } else {
        // The PiP AVSampleBufferDisplayLayer (a sublayer of `screen` at index 0) is the visible presenter, fed
        // below by pipPumpFrame — so while it's actively rendering, blitting screen.image here is fully-occluded
        // work, and latestFrame costs 2 full-canvas copies + a CGImage alloc per frame. Feed the UIImageView only
        // as a FALLBACK: when the PiP layer isn't presenting (not-yet / failed / torn down), plus a ~1 Hz refresh
        // so the occluded fallback stays current if the PiP layer ever drops out mid-session.
        BOOL pipPresenting = (self.pipLayer != nil
            && self.pipLayer.status == AVQueuedSampleBufferRenderingStatusRendering);
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

    // Feed the Picture-in-Picture layer every tick (the copy is skipped inside unless the engine composited
    // a NEW frame, so this is engine-rate ~50 fps, not display-rate). The layer IS the visible presenter —
    // it draws over the UIImageView's identical blit — because the system only auto-lifts video it considers
    // visibly playing inline; an occluded feed layer never engaged on device.
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
        [self updateReconnectOverlay];
        [self updateSessionExpiredOverlay]; // UX-LOGIN-01: same cadence/ungating as the reconnect scrim
        [self updateFatalErrorOverlay];     // FATAL-1: latch-once fatal card, same cadence
    }

    // W3 Feature-A (A2.5): refresh the crude native chat-at-top + HUD-status overlay from the HudDataBridge
    // snapshot (~10 Hz). Verifies the device data-flow before the full native chat veneer.
    if (self.framesShown % 6 == 0) {
        [self updateHudLayout];
        [self updateWorldMap];
    }

    // Drain the shared-core notification + outbound-link queues (~2 Hz). Both no-op until something is queued;
    // a fired plugin notification becomes a real OS notification, a plugin "open page" link opens in-app.
    if (self.framesShown % 30 == 0) {
        [self drainNotifications];
        [self drainLinks];
        [self drainScreenshots];   // SHOT-2: surface engine auto-screenshots to Photos (when enabled)
    }

    // PERF-MEMORY-THERMAL-01: thermal governor, 117HD boots only (~0.5 Hz; see thermalGovernorTick).
    if (self.pendingRouteCZone && self.framesShown % 120 == 0) {
        [self thermalGovernorTick];
    }

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
        BOOL wants = [JVMLauncher textInputOpen];
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
        if (!self.tapHaptic) { self.tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; }
        [self.tapHaptic impactOccurred];
        [self.tapHaptic prepare];
        if (self.pendingClick) {
            [self flashClickRingAt:self.pendingClickPoint color:[UIColor colorWithRed:1.0 green:0.2 blue:0.15 alpha:1.0]];
            self.pendingClick = NO;
        }
    }
    if (self.pendingClick && CACurrentMediaTime() - self.pendingClickAt > 0.25) {
        [self flashClickRingAt:self.pendingClickPoint color:[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]];
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
    [self startKeepaliveEngine];
    [self appendLine:@"[pip] keepalive audio armed (silent, mixable — blocks background suspension)"];
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
    if (type == AVAudioSessionInterruptionTypeEnded) {
        [self startKeepaliveEngine];
        [self appendLine:@"[pip] audio interruption ended -> keepalive restarted"];
    }
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
    self.pipFrameSeq = -1;

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
    self.pipButton.hidden = NO;
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
                          (long)self.pipLayer.status, self.pipFrameSeq]];
        [self.pipController startPictureInPicture];
    }
}

// Pull the newest engine frame (no-op when nothing new composited) and enqueue it on the PiP layer,
// stamped display-immediately so no timebase juggling is needed for a live feed.
- (void)pipPumpFrame {
    // KEEPALIVE-1 idle gate (runs for EVERY renderer, before the frame-feed early-returns): sample the
    // session ~every 5 s; once the game has been continuously logged OUT for the threshold — an AFK-logout
    // rendering the login screen to nobody — stop the pump and the keepalive audio so iOS can suspend the
    // JVM instead of burning battery at full rate indefinitely. Skipped while PiP is visibly active (the
    // user is watching the window, logged in or not). Foregrounding re-arms everything; the cost of a
    // suspension is a possible jetsam → relaunch + StikDebug re-attach, accepted for a dead session.
    static const CFTimeInterval kBgIdleStopSeconds = 600.0;
    self.bgPumpTicks++;
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
            return;
        }
    }
    if (!self.pipLayer) return;
    if (self.gpuPresent) return;   // 117HD pip-present: the GL bridge feeds the layer from the render thread
    if (self.pipLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.pipLayer flush];   // e.g. after a background round-trip; recovers on the next enqueue
    }
    int32_t seq = self.pipFrameSeq;
    CVPixelBufferRef pb = [JVMLauncher copyFramePixelBufferSinceSeq:&seq];
    if (!pb) return;
    self.pipFrameSeq = seq;

    // Format description cached across frames; rebuilt when the canvas dimensions change (resizable render).
    static CMVideoFormatDescriptionRef fmt = NULL;
    if (fmt && !CMVideoFormatDescriptionMatchesImageBuffer(fmt, pb)) { CFRelease(fmt); fmt = NULL; }
    if (!fmt && CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr) {
        fmt = NULL;
        CVPixelBufferRelease(pb);
        return;
    }
    CMSampleTimingInfo timing = { .duration = kCMTimeInvalid,
                                  .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
                                  .decodeTimeStamp = kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb) == noErr && sb) {
        CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, true);
        if (atts && CFArrayGetCount(atts) > 0) {
            CFMutableDictionaryRef att = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
            CFDictionarySetValue(att, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        [self.pipLayer enqueueSampleBuffer:sb];
        CFRelease(sb);
    }
    CVPixelBufferRelease(pb);
}

// Background frame pump: the CADisplayLink stops firing once backgrounded, so a plain 15 Hz main-queue
// timer feeds PiP instead (main queue = the thread the reverse-JNI bridge env is bound to; the run loop
// keeps servicing it because the keepalive audio blocks suspension).
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
    if ((iw <= 0 || ih <= 0) && self.renderW > 0) { iw = self.renderW; ih = self.renderH; }  // GPU present: no UIImage
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
- (void)onTap:(UITapGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady]) return;
    // The native dialogue parchment owns its own taps (continue / option rows). Re-gate here too (belt-and-
    // suspenders with shouldReceiveTouch) so a tap on it can never ALSO route as a world/precise click.
    if (self.dialogueView && !self.dialogueView.hidden
        && CGRectContainsPoint(self.dialogueView.frame, [g locationInView:self.screen])) return;
    CGPoint vp = [g locationInView:self.view];
    int gx = 0, gy = 0;
    if (![self mapPoint:[g locationInView:self.screen] toGameX:&gx toGameY:&gy]) return;
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
    // W3 A3: the relocated chat tab-row is UI, not the world. Send a PRECISE click straight to the engine (no
    // world-snap pulling it to a tile/entity) and DON'T draw the walk ring — taps there toggle a chat filter, they
    // don't walk. The rect moves with the safe-area relocate (chatHitCanvas, set in updateHudLayout).
    CGRect ch = self.chatHitCanvas;
    if (ch.size.width > 0 && gx >= ch.origin.x && gx <= ch.origin.x + ch.size.width
            && gy >= ch.origin.y && gy <= ch.origin.y + ch.size.height) {
        [JVMLauncher postClickPreciseX:gx y:gy button:1];
        [self appendLine:[NSString stringWithFormat:@"[shell] chat-tab tap %d,%d (precise, no ring)", gx, gy]];
        return;
    }
    // CHAT-2: a tap on the OPEN chat MESSAGE area is chat UI (continue dialogue, click a player name / chat link),
    // not the world behind the transparent chat — so click it PRECISELY (no world-snap, no walk-ring), like the
    // tab row above. The tab row is already handled+returned above, so this only catches the message area below it.
    if (self.chatScrollable && self.chatScrollCanvas.size.width > 0
            && CGRectContainsPoint(self.chatScrollCanvas, CGPointMake(gx, gy))) {
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
            [JVMLauncher postClickPreciseX:gx y:gy button:1];
            [self appendLine:[NSString stringWithFormat:@"[shell] dialogue tap %d,%d (precise, consumed)", gx, gy]];
            return;
        }
    }
    // Defer the ring one beat: onDisplayTick draws it red (interactable) or yellow (walk) once the engine has
    // resolved the tap. Pump the haptic generator so the buzz is low-latency if it turns out to be an interact.
    self.pendingClick = YES;
    self.pendingClickPoint = vp;
    self.pendingClickAt = CACurrentMediaTime();
    if (!self.tapHaptic) { self.tapHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; }
    [self.tapHaptic prepare];
    [JVMLauncher postClickX:gx y:gy button:1];
    [self appendLine:[NSString stringWithFormat:@"[shell] tap -> click(L) game %d,%d", gx, gy]];
}

// Draw the official-style click marker: a ring (red = interactable, yellow = walk) that expands and fades out
// over ~0.45s at the tap point, then removes itself. Pure native (CAShapeLayer) — no game involvement.
- (void)flashClickRingAt:(CGPoint)p color:(UIColor *)color {
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
    [CATransaction setCompletionBlock:^{ [ring removeFromSuperlayer]; }];
    [ring addAnimation:grp forKey:@"clickRing"];
    ring.opacity = 0.0;   // end state (the animation drives the visible fade)
    [CATransaction commit];
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
    self.menuHandRight = (loc.x > self.screen.bounds.size.width * 0.5); // pressed on the right -> open leftward
    self.menuHapticY = loc.y;
    self.menuHaptic = [UISelectionFeedbackGenerator new];
    [self.menuHaptic prepare];
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

// Build the opaque OSRS-styled native menu: a "Choose Option" header + one 32pt row per entry (display order,
// index 0 = top = left-click default). The box is sized + positioned to fully COVER the engine's own tiny
// rendered menu so there's no double-menu. Selection is driven by the long-press drag (rows are inert).
- (void)buildDragMenuWithEntries:(NSArray *)entries {
    [self.menuContainer removeFromSuperview];
    self.menuRowEntries = entries;
    NSInteger count = entries.count;

    // The engine menu rect in view coords — what we must cover.
    CGRect er = [self viewRectForGameX:(int)CGRectGetMinX(self.menuGeomGame)
                                     y:(int)CGRectGetMinY(self.menuGeomGame)
                                     w:(int)CGRectGetWidth(self.menuGeomGame)
                                     h:(int)CGRectGetHeight(self.menuGeomGame)];

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
    CGRect er = [self viewRectForGameX:(int)CGRectGetMinX(self.menuGeomGame)
                                     y:(int)CGRectGetMinY(self.menuGeomGame)
                                     w:(int)CGRectGetWidth(self.menuGeomGame)
                                     h:(int)CGRectGetHeight(self.menuGeomGame)];

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
        [self.menuHaptic selectionChanged];
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
        [self.menuHaptic selectionChanged]; [self.menuHaptic prepare];
        [self buildTapMenuWithEntries:sub drilledParent:(int)k];   // drill in
        return;
    }
    // Flat row. When the engine renders the whole menu (not self-scrolling), click its fixed-geometry row — this
    // honours the entry's RuneLite onClick + worldViewId. When the engine menu is SCROLLABLE (>~30 entries) the
    // fixed per-row geometry is unreliable (off-screen rows clamp to the wrong place), so commit the entry
    // directly by index instead (childIndex<0 = the top-level entry itself).
    if (self.menuScrollable) {
        [self.menuHaptic selectionChanged];
        [JVMLauncher invokeMenuEntryParent:(int)k child:-1];
        [self appendLine:[NSString stringWithFormat:@"[shell] menu tap select row=%ld (invoke, scrollable)", (long)k]];
        [self closeTapMenuAfterInvoke];
        return;
    }
    CGRect r = self.menuGeomGame;
    int ex = (int)lround(CGRectGetMidX(r));
    int ey = (int)CGRectGetMinY(r) + kMenuHeaderPx + (int)k * kMenuRowPx + kMenuRowPx / 2;
    ey = (int)fmin(fmax((CGFloat)ey, CGRectGetMinY(r) + 1), CGRectGetMaxY(r) - 2);
    [self.menuHaptic selectionChanged];
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
    if (!self.shiftHeld) [self onToggleShift];   // latch Shift + update the corner button state
    int gx = self.lastMenuX, gy = self.lastMenuY;
    CGPoint anchor = self.menuAnchor;
    // Close the open engine menu (title-strip click = no action), tear down native, then reopen shortly after.
    CGRect r = self.menuGeomGame;
    if (r.size.width > 0) [JVMLauncher postMenuSelectX:(int)lround(CGRectGetMidX(r)) y:(int)CGRectGetMinY(r) + 2];
    self.menuOpen = NO;
    [self teardownMenuViews];
    self.customizeReopenPending = YES;   // a new long-press before the delay fires cancels this (openEngineMenuAtGameX)
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
        if (hit >= 0) { [self.menuHaptic selectionChanged]; [self.menuHaptic prepare]; }
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
            [self openEngineMenuAtGameX:gx gameY:gy anchor:loc];
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
        [self.menuHaptic selectionChanged];
        [self.menuHaptic prepare];
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
    // Restore the default engine-menu raster suppression (the build-timeout fallback un-gates it).
    [JVMLauncher setEngineMenuRenderSuppressed:YES];
}

// one-finger drag -> rotate the camera. Feed incremental pixel deltas (reset the recognizer's translation
// each step) to the bridge, which applies them to the camera yaw/pitch targets directly. The menuOpen
// guard is belt-and-suspenders: if a long-press already claimed the touch, never also rotate.
- (void)onCameraPan:(UIPanGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady] || self.menuOpen) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        // DRAG-1: read the pre-reset translation so we can recover the TRUE touch start (the pan only fires after
        // ~10px of slop, so locationInView is already that far from where the finger landed on the item).
        CGPoint t0 = [g translationInView:self.screen];
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
        // DRAG-1: a drag that STARTS over the inventory grid rearranges items (engine WidgetDrag) rather than
        // rotating the camera. The press must land on the SOURCE item, so map the true touch start (loc - slop),
        // not the already-moved current point. Only diverts inventory-origin drags — scene drags still rotate.
        CGRect inv = [JVMLauncher inventoryCanvasBounds];
        if (!CGRectIsNull(inv) && CGRectGetWidth(inv) > 0 && CGRectGetHeight(inv) > 0) {
            CGPoint startLoc = CGPointMake([g locationInView:self.screen].x - t0.x,
                                           [g locationInView:self.screen].y - t0.y);
            int sx = 0, sy = 0;
            if ([self mapPoint:startLoc toGameX:&sx toGameY:&sy]
                    && CGRectContainsPoint(inv, CGPointMake(sx, sy))) {
                self.itemDragging = YES;
                self.itemDragLastX = sx; self.itemDragLastY = sy;   // seed the release-fallback point
                [JVMLauncher postTouchType:0 x:sx y:sy button:1];   // MOUSE_PRESSED on the source item slot
                [self appendLine:[NSString stringWithFormat:@"[shell] item drag begin @canvas %d,%d", sx, sy]];
                return;
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
        // A camera drag moves the world, not the pointer — so clear any frozen hover first, otherwise
        // scenery rotating under the stale cursor lights up and the next walk-tap mis-clicks it.
        [JVMLauncher postClearHover];
        [self appendLine:@"[shell] camera pan begin (1-finger)"];
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
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
        // Swipe-scroll the Key list / surface dropdown: wheel notches parked over the list (the engine
        // scrolls the hovered scrollable). Content follows the finger: swipe up -> wheel down.
        const CGFloat kMapScrollPtPerNotch = 22.0;
        self.mapListScrollAcc += -d.y / kMapScrollPtPerNotch;
        int notches = (int)(self.mapListScrollAcc > 0 ? floor(self.mapListScrollAcc) : ceil(self.mapListScrollAcc));
        if (notches != 0) {
            self.mapListScrollAcc -= notches;
            [JVMLauncher postWheelX:(int)self.mapListWheelPt.x y:(int)self.mapListWheelPt.y rotation:notches];
        }
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
    [JVMLauncher postCameraDx:(int)lround(-d.x) dy:(int)lround(-d.y)];
}

// Convert a vertical drag delta (screen pt) into a chat scroll, applied to the chat's OWN scroll layer (not a
// mouse wheel — a wheel over the transparent chat also zooms the camera). The drag is scaled to engine-canvas px
// (1:1 with the finger) and accumulated so sub-pixel drags aren't lost; content follows the finger via kChatScrollDir.
- (void)scrollChatByDragDeltaY:(CGFloat)dy {
    CGFloat W = self.view.bounds.size.width;
    if (self.renderW <= 0 || W <= 0) return;
    CGFloat canvasPerPt = (CGFloat)self.renderW / W;   // screen pt -> engine-canvas px
    self.chatScrollAccum += dy * canvasPerPt;
    int whole = (int)(self.chatScrollAccum < 0 ? ceil(self.chatScrollAccum) : floor(self.chatScrollAccum));
    if (whole == 0) return;
    self.chatScrollAccum -= whole;
    [JVMLauncher scrollEngineChat:(whole * kChatScrollDir)];
}

// pinch -> zoom via the mouse wheel. Accumulate the scale change into whole wheel notches; pinch out
// (scale grows) = zoom in = negative rotation. Centroid is the wheel point so the gamepack zooms about it.
- (void)onPinch:(UIPinchGestureRecognizer *)g {
    if (![JVMLauncher bridgeReady]) return;
    if (g.state == UIGestureRecognizerStateBegan) {
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
    NSString *json = [JVMLauncher mobileHotkeyActions];
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
    self.hotkeyStrip.hidden = !self.hotkeyStripVisible;
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
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [JVMLauncher mobileFireHotkeyGroup:parts[0] key:parts[1]];
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
        NSString *title, *body, *soundType = @"";
        if (parts.count >= 4) {
            title = parts[0];
            soundType = parts[parts.count - 2];
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
        // NOTIF-1: honor the desktop notification-sound type. OFF → deliver the banner silently; NATIVE/CUSTOM →
        // the platform default sound (no sandbox source for a user's custom .wav, so CUSTOM collapses to default);
        // unspecified (older 2-arg path) → default. Volume (parts[last]) is advisory — iOS has no per-banner gain.
        c.sound = [soundType isEqualToString:@"OFF"] ? nil : [UNNotificationSound defaultSound];
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
        UIImageWriteToSavedPhotosAlbum(img, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
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
    if (img == nil) { [self appendLine:@"[shell] screenshot: no frame yet"]; return; }
    // PERF-1: latestFrame's CGImage borrows a rotating scratch slot that the pump rewrites within a few
    // frames — fine for the immediate screen blit, NOT for the async Photos encode / a deferred pasteboard
    // paste. Redraw into an independent bitmap NOW so the saved bytes can't be overwritten mid-encode.
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:img.size];
    UIImage *stable = [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawAtPoint:CGPointZero];
    }];
    UIImageWriteToSavedPhotosAlbum(stable, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
    // SHOT-5: also copy to the clipboard, so it can be pasted straight into Messages / a notes app.
    [UIPasteboard generalPasteboard].image = stable;
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)ctx {
    [self appendLine:error
        ? [NSString stringWithFormat:@"[shell] screenshot save failed: %@", error.localizedDescription]
        : @"[shell] screenshot saved to Photos"];
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

@end
