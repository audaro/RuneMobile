#import "OverlayEditView.h"
#import "JVMLauncher.h"

// The native chatbox handle's reserved key (it's not a RuneLite overlay, so it never appears in overlaysJson).
static NSString * const kChatHandleKey = @"__chat__";

// One draggable overlay handle: a translucent labelled box pinned over the overlay's on-screen rect. Drag it to
// reposition (free location); tap it for the snap-corner / reset menu.
@interface OverlayHandle : UIView
@property (nonatomic, copy) NSString *overlayName;
@property (nonatomic, assign) BOOL snappable;
@property (nonatomic, assign) BOOL isChat;     // the native chatbox handle (moves via the chat host, not OverlayBridge)
@property (nonatomic, strong) UILabel *label;
@end

@implementation OverlayHandle
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:0.18];
        self.layer.borderColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:0.95].CGColor;
        self.layer.borderWidth = 1.5;
        self.layer.cornerRadius = 4;
        _label = [[UILabel alloc] init];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.font = [UIFont boldSystemFontOfSize:10];
        _label.textColor = [UIColor whiteColor];
        _label.numberOfLines = 2;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.minimumScaleFactor = 0.6;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:2],
            [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-2],
        ]];
    }
    return self;
}
@end

@interface OverlayEditView ()
@property (nonatomic, assign) int canvasW;
@property (nonatomic, assign) int canvasH;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) UIView *handleLayer;     // holds the handles, below the header bar
@property (nonatomic, strong) NSMutableDictionary<NSString *, OverlayHandle *> *handles;
// After a write (move/snap/reset) the bridge snapshot lags ~700ms; suppress re-pinning a handle from the stale
// snapshot until this wall-clock time so the box doesn't visibly snap back to where it was.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *suppressRepinUntil;
@property (nonatomic, copy) NSString *lastJson;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, weak) OverlayHandle *dragging;
@end

@implementation OverlayEditView

- (instancetype)initWithFrame:(CGRect)frame canvasW:(int)canvasW canvasH:(int)canvasH
                    presenter:(UIViewController *)presenter {
    if ((self = [super initWithFrame:frame])) {
        _canvasW = canvasW > 0 ? canvasW : 1;
        _canvasH = canvasH > 0 ? canvasH : 1;
        _presenter = presenter;
        _handles = [NSMutableDictionary dictionary];
        _suppressRepinUntil = [NSMutableDictionary dictionary];
        // A light scrim so the real overlays (rendered into the game behind us) stay visible while editing.
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];

        _handleLayer = [[UIView alloc] initWithFrame:self.bounds];
        _handleLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_handleLayer];

        [self buildHeader];

        [JVMLauncher overlaySetUiOpen:YES];
        // Poll the overlay snapshot ~3 Hz so handles track overlays that move/resize as the user edits. A
        // BLOCK timer with weak self (not target:self) so the timer can't keep this view alive — a stray
        // timer firing JNI on a detached view would be a leak + zombie call.
        __weak typeof(self) weakSelf = self;
        _poll = [NSTimer scheduledTimerWithTimeInterval:0.33 repeats:YES block:^(NSTimer *t) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) { [t invalidate]; return; }
            [s rebuildHandles];
            [s ensureChatHandle];
        }];
        [self rebuildHandles];
        [self ensureChatHandle];
    }
    return self;
}

// Teardown backstops: stop the timer + the JNI snapshot if the view leaves the window by ANY path (not just Done).
- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil && self.poll) {
        [self.poll invalidate];
        self.poll = nil;
        [JVMLauncher overlaySetUiOpen:NO];
    }
}

- (void)dealloc {
    [_poll invalidate];
}

- (void)buildHeader {
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:0.92];
    bar.layer.cornerRadius = 10;
    [self addSubview:bar];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Move overlays";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = [UIColor whiteColor];
    [bar addSubview:title];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"Drag to reposition · tap a box to snap or reset";
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [bar addSubview:hint];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    done.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [done addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];

    UILayoutGuide *sg = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:sg.topAnchor constant:8],
        [bar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [bar.heightAnchor constraintEqualToConstant:46],
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [title.topAnchor constraintEqualToAnchor:bar.topAnchor constant:6],
        [hint.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [hint.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1],
        [done.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14],
        [done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [done.leadingAnchor constraintEqualToAnchor:hint.trailingAnchor constant:16],
    ]];
}

// Uniform canvas-px -> screen-pt scale (the game blit fills the screen edge-to-edge, no letterbox).
- (CGFloat)scale {
    return self.bounds.size.width / (CGFloat)self.canvasW;
}

- (void)rebuildHandles {
    if (self.dragging) return;   // never re-pin a box the user is dragging
    NSString *json = [JVMLauncher overlaysJson];
    if (json.length == 0) return;
    if ([json isEqualToString:self.lastJson]) return;
    self.lastJson = json;
    id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;
    NSArray *overlays = parsed[@"overlays"];
    if (![overlays isKindOfClass:[NSArray class]]) overlays = @[];

    CGFloat s = [self scale];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *o in overlays) {
        if (![o[@"movable"] boolValue]) continue;
        NSString *name = [o[@"name"] description];
        NSArray *b = o[@"bounds"];
        if (name.length == 0 || ![b isKindOfClass:[NSArray class]] || b.count < 4) continue;
        // Skip the engine's CHATBOX widget overlay (RESIZABLE/FIXED_VIEWPORT_*_CHATBOX_PARENT): the chat is
        // native-rendered here, so use the "Chat" handle instead of this duplicate/non-functional box. Other widget
        // overlays (the minimap) + plugin overlays (XP tracker etc.) keep their handles.
        if ([name containsString:@"CHATBOX"]) continue;
        CGRect r = CGRectMake([b[0] doubleValue] * s, [b[1] doubleValue] * s,
                              [b[2] doubleValue] * s, [b[3] doubleValue] * s);
        if (r.size.width < 8 || r.size.height < 8) continue;   // skip degenerate/unrendered overlays
        [seen addObject:name];
        OverlayHandle *h = self.handles[name];
        if (!h) {
            h = [[OverlayHandle alloc] initWithFrame:r];
            h.overlayName = name;
            h.label.text = [self prettyName:name];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
            [h addGestureRecognizer:pan];
            [h addGestureRecognizer:tap];
            [self.handleLayer addSubview:h];
            self.handles[name] = h;
        } else {
            // Hold the box where the user just put it until the lagging snapshot catches up (no snap-back).
            NSNumber *until = self.suppressRepinUntil[name];
            if (!until || now >= until.doubleValue) {
                h.frame = r;   // track moves/resizes from the snapshot
                if (until) [self.suppressRepinUntil removeObjectForKey:name];
            }
        }
        h.snappable = [o[@"snappable"] boolValue];
    }
    // Drop handles for overlays that vanished (never the chat handle — it isn't in overlaysJson).
    for (NSString *name in self.handles.allKeys) {
        if ([name isEqualToString:kChatHandleKey]) continue;
        if (![seen containsObject:name]) {
            [self.handles[name] removeFromSuperview];
            [self.handles removeObjectForKey:name];
        }
    }
}

// Pin a "Chat" handle over the native chatbox so it's repositioned the same way as the overlays. The chat isn't a
// RuneLite overlay, so its rect + moves come from the chat host (the ViewController), not OverlayBridge.
- (void)ensureChatHandle {
    if (self.dragging) return;
    CGRect cr = self.chatHost ? [self.chatHost overlayEditChatCanvasRect] : CGRectNull;
    OverlayHandle *h = self.handles[kChatHandleKey];
    if (CGRectIsNull(cr) || cr.size.width <= 0 || cr.size.height <= 0) {
        if (h) { [h removeFromSuperview]; [self.handles removeObjectForKey:kChatHandleKey]; }
        return;
    }
    CGFloat s = [self scale];
    CGRect r = CGRectMake(cr.origin.x * s, cr.origin.y * s, cr.size.width * s, cr.size.height * s);
    if (!h) {
        h = [[OverlayHandle alloc] initWithFrame:r];
        h.overlayName = kChatHandleKey;
        h.isChat = YES;
        h.label.text = @"Chat";
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [h addGestureRecognizer:pan];   // no snap/reset menu for chat
        [self.handleLayer addSubview:h];
        self.handles[kChatHandleKey] = h;
    } else {
        NSNumber *until = self.suppressRepinUntil[kChatHandleKey];
        if (!until || CFAbsoluteTimeGetCurrent() >= until.doubleValue) {
            h.frame = r;
            if (until) [self.suppressRepinUntil removeObjectForKey:kChatHandleKey];
        }
    }
}

// "XpInfoBoxOverlay" -> "Xp Info Box Overlay" (space only at a lower->upper boundary so acronym runs like
// "GPU" don't become "G P U"); trim a trailing "Overlay". Cosmetic label only.
- (NSString *)prettyName:(NSString *)name {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        unichar prev = i > 0 ? [name characterAtIndex:i - 1] : 0;
        BOOL boundary = (c >= 'A' && c <= 'Z') && !(prev >= 'A' && prev <= 'Z');
        if (i > 0 && boundary) [out appendString:@" "];
        [out appendFormat:@"%C", c];
    }
    NSString *s = out;
    if ([s hasSuffix:@" Overlay"]) s = [s substringToIndex:s.length - 8];
    return s;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    OverlayHandle *h = (OverlayHandle *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragging = h;
        [self.handleLayer bringSubviewToFront:h];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.handleLayer];
        h.center = CGPointMake(h.center.x + t.x, h.center.y + t.y);
        [g setTranslation:CGPointZero inView:self.handleLayer];
        if (h.isChat) {
            // Move the live (under-scrim) chat with the handle so it tracks the finger.
            CGFloat s = [self scale];
            [self.chatHost overlayEditMoveChatToCanvasX:(int)lround(h.frame.origin.x / s)
                                                      y:(int)lround(h.frame.origin.y / s)];
        }
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGFloat s = [self scale];
        int wpx = (int)lround(h.frame.size.width / s);
        int hpx = (int)lround(h.frame.size.height / s);
        int cx = (int)lround(h.frame.origin.x / s);
        int cy = (int)lround(h.frame.origin.y / s);
        cx = MAX(0, MIN(cx, self.canvasW - wpx));
        cy = MAX(0, MIN(cy, self.canvasH - hpx));
        // Reflect the clamp on screen, then hold it against the lagging snapshot.
        h.frame = CGRectMake(cx * s, cy * s, h.frame.size.width, h.frame.size.height);
        if (h.isChat) {
            [self.chatHost overlayEditMoveChatToCanvasX:cx y:cy];
            [self.chatHost overlayEditCommitChatMove];
        } else {
            // Persist the overlay's free location (top-left, canvas px) through the bridge.
            [JVMLauncher overlaySetLocation:h.overlayName x:cx y:cy];
        }
        [self holdHandle:h.overlayName];
        self.dragging = nil;
    }
}

// Suppress re-pinning this handle from the (stale) snapshot for ~1.2s after a write.
- (void)holdHandle:(NSString *)name {
    self.suppressRepinUntil[name] = @(CFAbsoluteTimeGetCurrent() + 1.2);
}

- (void)onTap:(UITapGestureRecognizer *)g {
    OverlayHandle *h = (OverlayHandle *)g.view;
    UIViewController *pres = self.presenter;
    if (!pres) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[self prettyName:h.overlayName]
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    if (h.snappable) {
        NSArray<NSArray<NSString *> *> *corners = @[
            @[@"Snap top-left", @"TOP_LEFT"], @[@"Snap top-center", @"TOP_CENTER"], @[@"Snap top-right", @"TOP_RIGHT"],
            @[@"Snap bottom-left", @"BOTTOM_LEFT"], @[@"Snap bottom-right", @"BOTTOM_RIGHT"]];
        for (NSArray<NSString *> *c in corners) {
            [ac addAction:[UIAlertAction actionWithTitle:c[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [JVMLauncher overlaySetPosition:h.overlayName position:c[1]];
                [self holdHandle:h.overlayName];
            }]];
        }
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Reset to default" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [JVMLauncher overlayReset:h.overlayName];
        [self holdHandle:h.overlayName];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = h;
    ac.popoverPresentationController.sourceRect = h.bounds;
    [pres presentViewController:ac animated:YES completion:nil];
}

- (void)dismiss {
    [self.poll invalidate];
    self.poll = nil;
    [JVMLauncher overlaySetUiOpen:NO];
    [JVMLauncher mobileFlushConfig];   // persist the moved-overlay config now (iOS won't run the periodic flush)
    void (^cb)(void) = self.onClose;
    [self removeFromSuperview];
    if (cb) cb();
}

@end
