#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-6 (W3): the native host for RuneLite plugin SIDE-PANELS (XP tracker, GE search, notes, world
/// hopper, etc.). A top toolbar lists the plugins that provide a panel (MobileUiBridge.listPanels); selecting
/// one opens it (openPanel) and the panel's Swing tree is rendered headless to a buffer the shell blits into
/// a scroll view (mobilePanelImage). Taps map back to panel coords and dispatch as Swing clicks
/// (mobilePanelClick) — the embedded-Swing surface, sibling to the game blit.
@interface PluginPanelsViewController : UIViewController
/// When YES (and not docked), present as a right-edge tool drawer over the dimmed, still-running game. When NO,
/// the legacy centered-fullscreen layout (A/B fallback). Ignored when `docked`. Defaults to the drawer.
@property (nonatomic, assign) BOOL drawerMode;

/// When YES, run as a PERSISTENT dock hosted as a child on the game screen (not a modal): an always-visible
/// plugin-icon rail on the right edge + an always-visible icon strip across the bottom, with the rendered
/// panel opening inline over the live (still-usable) game. The host adds this as a child view controller and
/// pins its (passthrough) view over the game. Takes precedence over `drawerMode`.
@property (nonatomic, assign) BOOL docked;

/// §3.3 redesign: present the labelled, searchable, favourites GRID launcher (a bottom sheet of named plugin
/// tiles) as a more discoverable entry than the 38pt icon rail. A tile opens the same panel the rail would.
- (void)presentGridLauncher;

/// The right-edge plugin-icon rail is SHOWN by default (the user's primary entry). When YES it's hidden and the ⊞
/// FAB grid becomes the sole entry; the inline panel then reclaims the rail's edge strip. Setting it re-lays the
/// dock immediately. A long-press on the ⊞ FAB toggles it (persisted in NSUserDefaults `rightBarRailHidden`).
@property (nonatomic, assign) BOOL railHidden;

/// YES while the panel's own soft keyboard (a focused Swing text box) is up — the host gates its game-keyboard
/// auto-poll on this so a game textInputOpen flip doesn't yank the keyboard out from under panel typing (PANEL-1).
- (BOOL)panelKeyboardActive;
@end

NS_ASSUME_NONNULL_END
