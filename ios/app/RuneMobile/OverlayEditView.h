#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The native chatbox isn't a RuneLite overlay, but the user repositions it the same way — in overlay edit-mode.
/// The host (ViewController) provides its canvas rect + applies moves, so edit-mode can show a "Chat" handle too.
@protocol OverlayEditChatHost <NSObject>
/// The chat box rect in game-canvas px (top-left + size), or {@code CGRectNull} when the chat isn't placeable yet.
- (CGRect)overlayEditChatCanvasRect;
/// Move the chat's top-left to canvas {@code (x,y)} — live, while dragging.
- (void)overlayEditMoveChatToCanvasX:(int)x y:(int)y;
/// Persist the chat's new position (drag ended).
- (void)overlayEditCommitChatMove;
@end

/// Desktop-parity OVL-2/3/5: a touch overlay edit-mode. On desktop you Alt-drag overlays around the canvas and
/// drop them onto snap corners; touch has none of that, so this view (over the live game) draws a draggable
/// labelled handle for every movable overlay (data from OverlayBridge) and writes the new free location — or a
/// snap corner when dropped near an edge — back through the bridge. Each handle also has a reset button.
///
/// Overlay bounds are in game-canvas pixels (renderW x renderH); this view maps them to screen points with the
/// same uniform scale the game blit uses (canvas fills the screen edge-to-edge, so scale = screenW / renderW).
@interface OverlayEditView : UIView

/// Called when edit-mode tears down (Done, or any removal) so the host can clear its strong reference.
@property (nonatomic, copy, nullable) void (^onClose)(void);

/// Optional host for the native chatbox so it shows as a draggable "Chat" handle alongside the overlays.
@property (nonatomic, weak, nullable) id<OverlayEditChatHost> chatHost;

/// `frame` should cover the whole game screen. `canvasW`/`canvasH` are the engine's render dimensions (renderW/H).
/// `presenter` is the host VC used to present the per-overlay snap/reset menu (a UIView can't present).
- (instancetype)initWithFrame:(CGRect)frame canvasW:(int)canvasW canvasH:(int)canvasH
                    presenter:(UIViewController *)presenter;

/// Close edit mode: tell the bridge the screen closed and remove self from the hierarchy.
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
