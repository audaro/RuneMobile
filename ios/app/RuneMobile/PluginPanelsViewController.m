#import "PluginPanelsViewController.h"
#import "JVMLauncher.h"

// Right-edge drawer / dock geometry. Desktop-faithful: a vertical icon rail pinned to the far-right edge, the
// rendered panel content opening to its left. The panel's natural 1:1 width is ~PluginPanel.PANEL_WIDTH
// supersampled then shown at device scale (≈322pt on a 3x screen); size the content column to fit it snug.
static const CGFloat kRailWidth = 42.0;       // touch-friendly icon column in the outer screen-edge strip
static const CGFloat kDrawerWidth = 392.0;   // modal drawer: content(322) + rail + insets/gap
static const CGFloat kDrawerHInset = 10.0;
static const CGFloat kTitleBarHeight = 44.0;
static const CGFloat kRailButtonH = 44.0;     // mobile touch target per plugin icon
// Docked geometry. The native tab stones sit INSIDE the safe area (the game is inset by the tab strip), so the
// outer sliver between them and the screen edge is free — put the plugin rail there, to the RIGHT of the tabs.
// kRailCornerClear keeps the rail's top + bottom OUT of the iPhone's rounded-corner radius (~55pt) so the curve
// can't clip the top-right / bottom-right of the bar; the rail floats in the flat middle of the right edge.
static const CGFloat kRailCornerClear = 60.0;
static const CGFloat kDockPanelW = 334.0;     // inline panel column width (≈322 content + chrome)

/// Passthrough container for docked mode: touches that don't land on a real subview (rail/strip/panel) fall
/// through to the live game beneath, so the game stays fully usable while the dock is up.
@interface PassthroughView : UIView
@end
@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v == self ? nil : v;
}
@end

// Native, reflowed plugin screens (data via the bridges). Defined at the bottom of this file.
@interface QuestHelperViewController : UIViewController
@end
@interface WorldSwitcherViewController : UIViewController
@end
@interface XpTrackerViewController : UIViewController
@end
@interface NotesViewController : UIViewController
@end
@interface GeViewController : UIViewController
@end
@interface LootTrackerViewController : UIViewController
@end
@interface TimeTrackingViewController : UIViewController
@end
@interface ConfigProfilesViewController : UIViewController
@end
@interface InfoBoxMenuViewController : UIViewController
@end

// §3.3 redesign: the labelled/searchable/favourites grid launcher. Defined at the bottom of this file.
@interface MUIPluginGrid : UIViewController
- (instancetype)initWithPanels:(NSArray<NSDictionary *> *)panels onPick:(void (^)(NSString *tooltip))onPick;
@end

@interface PluginPanelsViewController () <UIScrollViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *panelKbField;   // PANEL-1: hidden field mirroring a focused Swing text box
@property (nonatomic, assign) CGSize lastPanelImgSize;     // re-layout only on size change (preserve zoom)
@property (nonatomic, strong) UIScrollView *toolbar;       // legacy: horizontal text-pill strip
@property (nonatomic, strong) UIScrollView *rail;          // vertical plugin-icon rail (right edge)
@property (nonatomic, strong) NSLayoutConstraint *railHeight; // sized to content, clamped to the clear band
@property (nonatomic, strong) UIView *panelContainer;      // docked: collapsible inline panel column
@property (nonatomic, strong) NSLayoutConstraint *panelTrailRail;  // panel trailing -> rail leading (rail shown)
@property (nonatomic, strong) NSLayoutConstraint *panelTrailEdge;  // panel trailing -> screen edge (rail hidden)
@property (nonatomic, strong) UIScrollView *panelScroll;   // vertical scroll of the rendered panel
@property (nonatomic, strong) UIImageView *panelView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *panels;
@property (nonatomic, copy) NSString *panelsSignature;     // detect nav-button changes (toggles/new plugins)
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong) CADisplayLink *refresh;
@property (nonatomic, assign) int lastSeq;
@property (nonatomic, assign) int frameCounter;
@property (nonatomic, assign) CGFloat panelNativeW;
@property (nonatomic, strong) NSMutableArray<UIButton *> *railButtons;
@property (nonatomic, strong) NSMutableArray<UIButton *> *toolbarButtons; // legacy
// Modal-drawer chrome.
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation PluginPanelsViewController

- (instancetype)init {
    if ((self = [super init])) {
        _currentIndex = -1; _lastSeq = -1; _panelNativeW = 242; _drawerMode = YES;
    }
    return self;
}

- (void)loadView {
    if (self.docked) {
        self.view = [[PassthroughView alloc] init];   // game-usable overlay
    } else {
        [super loadView];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.docked) {
        [self setupDocked];
        [self loadPanels];
        [self rebuildSelectors];               // start collapsed; selectors populate when panels appear
    } else if (self.drawerMode) {
        [self setupDrawer];
        [self loadPanels];
        [self buildRail];
        [self startOnFirstPanel];
    } else {
        [self setupLegacy];
        [self loadPanels];
        [self buildLegacyToolbar];
        [self startOnFirstPanel];
    }

    self.refresh = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    self.refresh.preferredFramesPerSecond = 15;
    [self.refresh addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)startOnFirstPanel {
    if (self.panels.count > 0) {
        [self selectIndex:0];
    } else {
        self.emptyLabel.text = @"No plugins with panels are enabled.";
    }
}

#pragma mark - Docked layout (persistent dock on the game screen)

- (void)setupDocked {
    self.view.backgroundColor = [UIColor clearColor];

    // §3.5 step 3: default to the rail HIDDEN (⊞ FAB grid is the entry); a debug long-press on the FAB flips it.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    _railHidden = ([ud objectForKey:@"rightBarRailHidden"] == nil) ? NO : [ud boolForKey:@"rightBarRailHidden"];

    self.rail = [[UIScrollView alloc] init];
    self.rail.translatesAutoresizingMaskIntoConstraints = NO;
    self.rail.showsVerticalScrollIndicator = NO;
    self.rail.backgroundColor = [UIColor colorWithRed:40/255.0 green:40/255.0 blue:40/255.0 alpha:0.96]; // RuneLite DARK_GRAY
    self.rail.layer.cornerRadius = 10;
    [self.view addSubview:self.rail];

    // Collapsible inline panel column (hidden until an icon is tapped). Game stays visible to its left.
    self.panelContainer = [[UIView alloc] init];
    self.panelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelContainer.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:0.98];
    self.panelContainer.layer.cornerRadius = 8;
    self.panelContainer.clipsToBounds = YES;
    self.panelContainer.hidden = YES;
    [self.view addSubview:self.panelContainer];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.titleLabel.textColor = [UIColor whiteColor];
    [self.panelContainer addSubview:self.titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [close addTarget:self action:@selector(collapsePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelContainer addSubview:close];

    UIView *sep = [[UIView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [self.panelContainer addSubview:sep];

    self.panelScroll = [[UIScrollView alloc] init];
    self.panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelScroll.backgroundColor = [UIColor clearColor];
    [self.panelContainer addSubview:self.panelScroll];
    [self buildPanelViewInto:self.panelScroll];

    self.railHeight = [self.rail.heightAnchor constraintEqualToConstant:200];
    self.railHeight.priority = UILayoutPriorityDefaultLow;          // sized to content, clamped by the band
    NSLayoutConstraint *railCenter = [self.rail.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor];
    railCenter.priority = UILayoutPriorityDefaultHigh;             // centre in the clear band when it fits

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // Right rail: floats in the outer strip just off the screen edge, to the RIGHT of the native tab stones.
        // Top/bottom are clamped OUT of the rounded-corner radius (kRailCornerClear, measured from the PHYSICAL
        // edges) so the curve never clips the bar; vertically centred; scrolls if the plugin count overflows.
        [self.rail.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-5],
        [self.rail.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.topAnchor constant:kRailCornerClear],
        [self.rail.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-kRailCornerClear],
        [self.rail.widthAnchor constraintEqualToConstant:kRailWidth],
        railCenter,
        self.railHeight,

        // Inline panel column: left of the rail (over the game world, not the native tabs), full clear height.
        // (Trailing is one of two swappable constraints set up below — to the rail when shown, else the edge.)
        [self.panelContainer.topAnchor constraintEqualToAnchor:sg.topAnchor constant:6],
        [self.panelContainer.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor constant:-6],
        [self.panelContainer.widthAnchor constraintEqualToConstant:kDockPanelW],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor constant:12],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.panelContainer.topAnchor constant:10],
        [close.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor constant:-12],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],
        [sep.topAnchor constraintEqualToAnchor:self.panelContainer.topAnchor constant:kTitleBarHeight],
        [sep.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor],
        [sep.heightAnchor constraintEqualToConstant:1],
        [self.panelScroll.topAnchor constraintEqualToAnchor:sep.bottomAnchor],
        [self.panelScroll.leadingAnchor constraintEqualToAnchor:self.panelContainer.leadingAnchor constant:6],
        [self.panelScroll.trailingAnchor constraintEqualToAnchor:self.panelContainer.trailingAnchor constant:-6],
        [self.panelScroll.bottomAnchor constraintEqualToAnchor:self.panelContainer.bottomAnchor constant:-6],
    ]];

    // Swappable panel trailing: anchored to the rail's leading edge when the rail is shown, else to the screen
    // edge so the panel reclaims the rail strip when the rail is hidden (FAB-only mode). applyRailVisibility picks.
    self.panelTrailRail = [self.panelContainer.trailingAnchor constraintEqualToAnchor:self.rail.leadingAnchor constant:-6];
    self.panelTrailEdge = [self.panelContainer.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-6];
    [self applyRailVisibility];
}

// §3.5 step 3: show the rail only when it's not hidden AND there are panels; otherwise the ⊞ FAB is the entry and
// the inline panel stretches to the screen edge (reclaiming the rail strip). Idempotent; safe to call any time.
- (void)applyRailVisibility {
    BOOL railVisible = !self.railHidden && self.panels.count > 0;
    self.rail.hidden = !railVisible;
    self.panelTrailRail.active = railVisible;
    self.panelTrailEdge.active = !railVisible;
}

- (void)setRailHidden:(BOOL)railHidden {
    _railHidden = railHidden;
    if (self.docked && self.rail) [self applyRailVisibility];
}

// (Re)build the rail + bottom strip from the current panel list. Called on first load and whenever the nav
// buttons change (a plugin toggled on/off, or the client finished registering them after boot).
- (void)rebuildSelectors {
    for (UIButton *b in self.railButtons) [b removeFromSuperview];
    self.railButtons = [NSMutableArray array];

    CGFloat y = 4;
    for (NSUInteger i = 0; i < self.panels.count; i++) {
        UIButton *rb = [self makeIconButton:self.panels[i] index:i];
        rb.frame = CGRectMake(3, y, kRailWidth - 6, kRailButtonH - 4);
        [self.rail addSubview:rb];
        [self.railButtons addObject:rb];
        y += kRailButtonH;
    }
    self.rail.contentSize = CGSizeMake(kRailWidth, y + 4);
    self.railHeight.constant = y + 4;          // sized to content; clamped to the clear band, then scrolls

    // Show the rail only when not hidden (§3.5 step 3) and there are panels; else the ⊞ FAB grid is the entry.
    [self applyRailVisibility];

    if (self.panels.count == 0) {
        [self collapsePanel];
    } else if (self.currentIndex >= (NSInteger)self.panels.count) {
        [self collapsePanel];
    } else if (self.currentIndex >= 0) {
        [self highlightSelectors];             // keep showing the open panel
    }
}

- (UIButton *)makeIconButton:(NSDictionary *)p index:(NSUInteger)i {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.layer.cornerRadius = 6;
    b.tag = (NSInteger)i;
    b.adjustsImageWhenHighlighted = NO;
    UIImage *icon = [self decodeIcon:p[@"iconPng"]];
    if (icon) {
        [b setImage:icon forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.contentEdgeInsets = UIEdgeInsetsMake(7, 7, 7, 7);
    } else {
        NSString *t = [p[@"tooltip"] description];
        [b setTitle:(t.length ? [[t substringToIndex:1] uppercaseString] : @"?") forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    [b addTarget:self action:@selector(onSelectorButton:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)highlightSelectors {
    UIColor *on = [UIColor colorWithRed:0.20 green:0.45 blue:0.22 alpha:1.0];
    for (UIButton *b in self.railButtons) b.backgroundColor = (b.tag == self.currentIndex) ? on : [UIColor clearColor];
}

- (void)collapsePanel {
    self.currentIndex = -1;
    self.panelContainer.hidden = YES;
    [self.panelKbField resignFirstResponder];   // PANEL-1: drop the soft keyboard with the panel
    [self highlightSelectors];
    [JVMLauncher mobileClosePanel];
    [JVMLauncher mobileFlushConfig];
}

#pragma mark - Modal drawer layout (A/B fallback via the plugins menu)

- (void)buildRail {
    self.railButtons = [NSMutableArray array];
    CGFloat y = 4;
    for (NSUInteger i = 0; i < self.panels.count; i++) {
        UIButton *b = [self makeIconButton:self.panels[i] index:i];
        b.frame = CGRectMake(3, y, kRailWidth - 6, kRailButtonH - 4);
        [self.rail addSubview:b];
        [self.railButtons addObject:b];
        y += kRailButtonH;
    }
    self.rail.contentSize = CGSizeMake(kRailWidth, y + 4);
}

- (void)setupDrawer {
    self.view.backgroundColor = [UIColor clearColor];

    self.dimView = [[UIView alloc] init];
    self.dimView.translatesAutoresizingMaskIntoConstraints = NO;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:self.dimView];
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)];
    [self.dimView addGestureRecognizer:dismissTap];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    self.drawer.layer.shadowColor = [UIColor blackColor].CGColor;
    self.drawer.layer.shadowOffset = CGSizeMake(-3, 0);
    self.drawer.layer.shadowRadius = 8;
    self.drawer.layer.shadowOpacity = 0.5;
    [self.view addSubview:self.drawer];

    self.rail = [[UIScrollView alloc] init];
    self.rail.translatesAutoresizingMaskIntoConstraints = NO;
    self.rail.showsVerticalScrollIndicator = NO;
    self.rail.backgroundColor = [UIColor colorWithWhite:0 alpha:0.22];
    [self.drawer addSubview:self.rail];

    UIView *railSep = [[UIView alloc] init];
    railSep.translatesAutoresizingMaskIntoConstraints = NO;
    railSep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [self.drawer addSubview:railSep];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.text = @"Plugin Panels";
    [self.drawer addSubview:self.titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [self.drawer addSubview:close];

    UIView *titleSep = [[UIView alloc] init];
    titleSep.translatesAutoresizingMaskIntoConstraints = NO;
    titleSep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [self.drawer addSubview:titleSep];

    self.panelScroll = [[UIScrollView alloc] init];
    self.panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelScroll.backgroundColor = [UIColor clearColor];
    [self.drawer addSubview:self.panelScroll];
    [self buildPanelViewInto:self.panelScroll];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"Loading panels…";
    self.emptyLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    [self.drawer addSubview:self.emptyLabel];

    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:kDrawerWidth],
        [self.rail.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [self.rail.bottomAnchor constraintEqualToAnchor:self.drawer.bottomAnchor],
        [self.rail.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [self.rail.widthAnchor constraintEqualToConstant:kRailWidth],
        [railSep.topAnchor constraintEqualToAnchor:self.drawer.topAnchor],
        [railSep.bottomAnchor constraintEqualToAnchor:self.drawer.bottomAnchor],
        [railSep.trailingAnchor constraintEqualToAnchor:self.rail.leadingAnchor],
        [railSep.widthAnchor constraintEqualToConstant:1],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:kDrawerHInset],
        [self.titleLabel.topAnchor constraintEqualToAnchor:dg.topAnchor constant:10],
        [close.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:railSep.leadingAnchor constant:-10],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],
        [titleSep.topAnchor constraintEqualToAnchor:dg.topAnchor constant:kTitleBarHeight],
        [titleSep.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [titleSep.trailingAnchor constraintEqualToAnchor:railSep.leadingAnchor],
        [titleSep.heightAnchor constraintEqualToConstant:1],
        [self.panelScroll.topAnchor constraintEqualToAnchor:titleSep.bottomAnchor],
        [self.panelScroll.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:kDrawerHInset],
        [self.panelScroll.trailingAnchor constraintEqualToAnchor:railSep.leadingAnchor constant:-6],
        [self.panelScroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor constant:-8],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.panelScroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.panelScroll.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintEqualToConstant:kDrawerWidth - kRailWidth - 2 * kDrawerHInset - 16],
    ]];
}

#pragma mark - Legacy layout (centered fullscreen — A/B fallback)

- (void)setupLegacy {
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Plugin Panels";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    done.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [done addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    self.toolbar = [[UIScrollView alloc] init];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.toolbar.showsHorizontalScrollIndicator = NO;
    self.toolbar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    [self.view addSubview:self.toolbar];

    self.panelScroll = [[UIScrollView alloc] init];
    self.panelScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelScroll.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    [self.view addSubview:self.panelScroll];
    [self buildPanelViewInto:self.panelScroll];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"Loading panels…";
    self.emptyLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.emptyLabel];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [self.toolbar.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.toolbar.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor],
        [self.toolbar.heightAnchor constraintEqualToConstant:44],
        [self.panelScroll.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor constant:6],
        [self.panelScroll.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:8],
        [self.panelScroll.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-8],
        [self.panelScroll.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor constant:-8],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.panelScroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.panelScroll.centerYAnchor],
    ]];
}

- (void)buildLegacyToolbar {
    self.toolbarButtons = [NSMutableArray array];
    CGFloat x = 8;
    const CGFloat bw = 116, bh = 34, gap = 6;
    for (NSUInteger i = 0; i < self.panels.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 5, bw, bh);
        [b setTitle:[self.panels[i][@"tooltip"] description] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14];
        b.titleLabel.adjustsFontSizeToFitWidth = YES;
        b.titleLabel.minimumScaleFactor = 0.7;
        b.tintColor = [UIColor whiteColor];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        b.layer.cornerRadius = 7;
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(onSelectorButton:) forControlEvents:UIControlEventTouchUpInside];
        [self.toolbar addSubview:b];
        [self.toolbarButtons addObject:b];
        x += bw + gap;
    }
    self.toolbar.contentSize = CGSizeMake(x + 2, 44);
}

#pragma mark - Shared

- (void)loadPanels {
    NSString *json = [JVMLauncher mobileListPanels] ?: @"[]";
    self.panelsSignature = json;
    NSArray *arr = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
    self.panels = arr ?: @[];
}

- (void)buildPanelViewInto:(UIScrollView *)scroll {
    self.panelView = [[UIImageView alloc] init];
    self.panelView.userInteractionEnabled = YES;
    self.panelView.contentMode = UIViewContentModeScaleToFill;
    self.panelView.layer.magnificationFilter = kCAFilterTrilinear;
    [scroll addSubview:self.panelView];
    // Pinch-to-zoom + pan: the rendered desktop panel is dense, so let the user zoom in to read any part. The
    // buffer is supersampled, so zooming in stays crisp. viewForZooming returns panelView (its only subview).
    scroll.delegate = self;
    scroll.minimumZoomScale = 1.0;
    scroll.maximumZoomScale = 4.0;
    scroll.bouncesZoom = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onPanelTap:)];
    [self.panelView addGestureRecognizer:tap];
    // PANEL-2: long-press = a right-click (BUTTON3) into the panel's Swing tree (context handlers, e.g. reset).
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                     action:@selector(onPanelLongPress:)];
    [self.panelView addGestureRecognizer:lp];

    // PANEL-1: a hidden text field. When a panel tap focuses a Swing text box, it becomes first responder (raising
    // the soft keyboard) and mirrors its text into the Swing field on every change.
    if (!self.panelKbField) {
        self.panelKbField = [[UITextField alloc] initWithFrame:CGRectMake(-300, -300, 10, 10)];
        self.panelKbField.delegate = self;
        self.panelKbField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.panelKbField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.panelKbField.spellCheckingType = UITextSpellCheckingTypeNo;
        self.panelKbField.smartQuotesType = UITextSmartQuotesTypeNo;
        self.panelKbField.smartDashesType = UITextSmartDashesTypeNo;
        self.panelKbField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        self.panelKbField.keyboardType = UIKeyboardTypeASCIICapable;
        self.panelKbField.keyboardAppearance = UIKeyboardAppearanceDark;
        self.panelKbField.returnKeyType = UIReturnKeyDone;
        [self.panelKbField addTarget:self action:@selector(onPanelKbChanged)
                    forControlEvents:UIControlEventEditingChanged];
        [self.view addSubview:self.panelKbField];
    }
}

// Buffer-pixel coords for a gesture on panelView (shared by tap + long-press).
- (CGPoint)panelBufferPointFor:(UIGestureRecognizer *)g {
    CGPoint loc = [g locationInView:self.panelView];
    CGFloat s = self.panelNativeW / self.panelView.bounds.size.width;
    return CGPointMake(lround(loc.x * s), lround(loc.y * s));
}

- (void)onPanelLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (self.currentIndex < 0 || self.panelView.bounds.size.width < 1) return;
    CGPoint p = [self panelBufferPointFor:g];
    [JVMLauncher mobilePanelLongPressX:(int)p.x y:(int)p.y];
}

- (BOOL)panelKeyboardActive {
    return self.panelKbField.isFirstResponder;
}

// The hidden field changed: mirror its whole text into the focused Swing field (live-filter search boxes react).
- (void)onPanelKbChanged {
    [JVMLauncher mobileSetPanelText:(self.panelKbField.text ?: @"")];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [JVMLauncher mobilePanelKey:10];   // VK_ENTER — submit (search fields that act on Enter)
    [textField resignFirstResponder];
    return NO;
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.panelView;
}

- (nullable UIImage *)decodeIcon:(id)base64 {
    if (![base64 isKindOfClass:[NSString class]] || [(NSString *)base64 length] == 0) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    return d ? [UIImage imageWithData:d] : nil;
}

- (void)onSelectorButton:(UIButton *)b {
    [self openPanelAtIndex:b.tag fromGrid:NO];
}

// §3.3: the FAB-launched grid. Reuses the live panel list (label + icon + pinned) and routes a tile back through
// the same openPanelAtIndex fork (native Quest Helper / World Switcher, else the rendered panel).
- (void)presentGridLauncher {
    if (self.presentedViewController) return;
    __weak typeof(self) ws = self;
    MUIPluginGrid *grid = [[MUIPluginGrid alloc] initWithPanels:[self gridTilesWithSynthetics]
                                                         onPick:^(NSString *tooltip) {
                                                             if ([ws presentSyntheticPanel:tooltip])
                                                                 return; // Profiles / Infoboxes (not plugin nav buttons)
                                                             NSInteger idx = [ws indexForPanelTooltip:tooltip];
                                                             if (idx >= 0)
                                                                 [ws openPanelAtIndex:idx fromGrid:YES];
                                                         }];
    if (@available(iOS 15.0, *)) {
        grid.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController *sheet = grid.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    } else {
        grid.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    [self presentViewController:grid animated:YES completion:nil];
}

// Open the panel at `index`: route Quest Helper / World Switcher to their native reflowed screens (when the
// reflection bridge can reach the plugin), else open the generic rendered surface. Shared by the rail buttons
// and the grid launcher (§3.3). `fromGrid` skips the tap-active-icon-to-close shortcut (the grid always opens).
- (void)openPanelAtIndex:(NSInteger)index fromGrid:(BOOL)fromGrid {
    if (index < 0 || index >= (NSInteger)self.panels.count) return;
    NSString *tip = [self.panels[index][@"tooltip"] description];
    // The native reflowed Quest Helper / World Switcher screens are docked-mode only (the grid only runs docked).
    // The drawer/legacy A-B fallback modes keep showing the rendered panel, matching the prior onSelectorButton.
    if (self.docked) {
        if ([tip isEqualToString:@"Quest Helper"] && [JVMLauncher questAvailable]) {
            QuestHelperViewController *qh = [[QuestHelperViewController alloc] init];
            qh.modalPresentationStyle = UIModalPresentationOverFullScreen;
            qh.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:qh animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"World Switcher"] && [JVMLauncher worldAvailable]) {
            WorldSwitcherViewController *ws = [[WorldSwitcherViewController alloc] init];
            ws.modalPresentationStyle = UIModalPresentationOverFullScreen;
            ws.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:ws animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"XP Tracker"] && [JVMLauncher xpTrackerAvailable]) {
            XpTrackerViewController *xp = [[XpTrackerViewController alloc] init];
            xp.modalPresentationStyle = UIModalPresentationOverFullScreen;
            xp.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:xp animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"Notes"] && [JVMLauncher notesAvailable]) {
            NotesViewController *nv = [[NotesViewController alloc] init];
            nv.modalPresentationStyle = UIModalPresentationOverFullScreen;
            nv.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:nv animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"Grand Exchange"] && [JVMLauncher geAvailable]) {
            GeViewController *ge = [[GeViewController alloc] init];
            ge.modalPresentationStyle = UIModalPresentationOverFullScreen;
            ge.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:ge animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"Loot Tracker"] && [JVMLauncher lootAvailable]) {
            LootTrackerViewController *lt = [[LootTrackerViewController alloc] init];
            lt.modalPresentationStyle = UIModalPresentationOverFullScreen;
            lt.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:lt animated:YES completion:nil];
            return;
        }
        if ([tip isEqualToString:@"Time Tracking"] && [JVMLauncher timeTrackingAvailable]) {
            TimeTrackingViewController *tt = [[TimeTrackingViewController alloc] init];
            tt.modalPresentationStyle = UIModalPresentationOverFullScreen;
            tt.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:tt animated:YES completion:nil];
            return;
        }
        if (!fromGrid && index == self.currentIndex) {
            [self collapsePanel];          // tapping the active rail icon closes the panel
            return;
        }
    }
    [self selectIndex:index];
}

// Live array position of the panel with this tooltip, or -1. The grid snapshots the panel list, so it resolves
// its pick by stable name (the dock's tick may have rebuilt self.panels between present and pick).
- (NSInteger)indexForPanelTooltip:(NSString *)tooltip {
    for (NSUInteger i = 0; i < self.panels.count; i++) {
        if ([[self.panels[i][@"tooltip"] description] isEqualToString:tooltip]) return (NSInteger)i;
    }
    return -1;
}

// The grid launcher's tile list: the live plugin panels plus synthetic tiles for native screens that are NOT
// plugin nav buttons (Config Profiles, Infobox menu) — Android surfaces these as TileSpec entries too. Gated on
// availability so they only appear once the bridges are wired (after the client is up).
- (NSArray<NSDictionary *> *)gridTilesWithSynthetics {
    NSMutableArray<NSDictionary *> *tiles = [(self.panels ?: @[]) mutableCopy];
    if ([JVMLauncher profilesAvailable]) {
        [tiles addObject:@{@"tooltip" : @"Profiles", @"name" : @"Profiles", @"synthetic" : @YES}];
    }
    if ([JVMLauncher infoBoxAvailable]) {
        [tiles addObject:@{@"tooltip" : @"Infoboxes", @"name" : @"Infoboxes", @"synthetic" : @YES}];
    }
    return tiles;
}

// Present a synthetic native screen (Profiles / Infoboxes) by its tile name; returns YES if it handled the pick.
- (BOOL)presentSyntheticPanel:(NSString *)tooltip {
    if ([tooltip isEqualToString:@"Profiles"] && [JVMLauncher profilesAvailable]) {
        ConfigProfilesViewController *vc = [[ConfigProfilesViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:vc animated:YES completion:nil];
        return YES;
    }
    if ([tooltip isEqualToString:@"Infoboxes"] && [JVMLauncher infoBoxAvailable]) {
        InfoBoxMenuViewController *vc = [[InfoBoxMenuViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:vc animated:YES completion:nil];
        return YES;
    }
    return NO;
}

- (void)selectIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.panels.count) return;
    self.currentIndex = index;
    self.lastSeq = -1;                         // force a re-pull
    self.lastPanelImgSize = CGSizeZero;        // re-layout + reset zoom for the newly selected panel
    if (self.emptyLabel) self.emptyLabel.text = @"";
    self.titleLabel.text = [self.panels[index][@"tooltip"] description];
    if (self.docked) {
        self.panelContainer.hidden = NO;
        [self highlightSelectors];
    } else {
        UIColor *on = [UIColor colorWithRed:0.20 green:0.45 blue:0.22 alpha:1.0];
        UIColor *off = self.drawerMode ? [UIColor clearColor] : [UIColor colorWithWhite:1 alpha:0.10];
        for (UIButton *b in self.railButtons)    b.backgroundColor = (b.tag == index) ? on : off;
        for (UIButton *b in self.toolbarButtons) b.backgroundColor = (b.tag == index) ? on : off;
    }
    [JVMLauncher mobileOpenPanel:(int)index];
}

- (void)tick {
    // Docked: cheaply poll the panel list every ~1.5s so the rail/strip populate once the client is up and
    // track plugin toggles. (The list is empty for a while after launch.)
    if (self.docked && (++self.frameCounter % 22 == 0)) {
        NSString *json = [JVMLauncher mobileListPanels] ?: @"[]";
        if (![json isEqualToString:self.panelsSignature]) {
            self.panelsSignature = json;
            NSArray *arr = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
            self.panels = arr ?: @[];
            [self rebuildSelectors];
        }
    }

    if (self.currentIndex < 0) return;
    if (self.docked && self.panelContainer.hidden) return;
    int seq = [JVMLauncher mobilePanelFrameSeq];
    if (seq == self.lastSeq) return;
    UIImage *img = [JVMLauncher mobilePanelImage];
    if (!img || img.size.width < 1) return;
    self.lastSeq = seq;
    self.panelNativeW = img.size.width;
    self.panelView.image = img;                 // refresh content every frame (live updates)
    // Only (re)compute the base layout when the buffer SIZE changes — re-laying out every repaint would reset
    // the user's pinch-zoom/scroll. Same panel keeps the same buffer dimensions across repaints.
    if (CGSizeEqualToSize(img.size, self.lastPanelImgSize)) return;
    self.lastPanelImgSize = img.size;
    CGFloat vw = self.panelScroll.bounds.size.width;
    if (vw < 1) { self.lastPanelImgSize = CGSizeZero; return; }
    CGFloat oneToOne = img.size.width / UIScreen.mainScreen.scale;
    // Dock: fill the panel column at a consistent width regardless of the buffer's supersample scale (so a
    // tall panel rendered at a lower scale doesn't display tiny). Legacy fullscreen: cap at 1:1 to avoid
    // blowing a 242-wide panel across the whole screen. Either way, pinch-zoom reads the detail.
    CGFloat dispW = self.docked ? vw : MIN(vw, oneToOne);
    CGFloat scale = dispW / img.size.width;
    CGFloat dispH = img.size.height * scale;
    self.panelScroll.zoomScale = 1.0;           // new panel/size → reset zoom
    self.panelView.frame = CGRectMake(0, 0, dispW, dispH);
    self.panelScroll.contentSize = CGSizeMake(dispW, dispH);
    // Centre horizontally when the panel is narrower than the viewport (legacy fullscreen); 0 in the dock.
    CGFloat sideInset = MAX(0.0, floor((vw - dispW) / 2.0));
    self.panelScroll.contentInset = UIEdgeInsetsMake(0, sideInset, 0, sideInset);
}

- (void)onPanelTap:(UITapGestureRecognizer *)tap {
    if (self.currentIndex < 0 || self.panelView.bounds.size.width < 1) return;
    CGPoint p = [self panelBufferPointFor:tap];
    [JVMLauncher mobilePanelClickX:(int)p.x y:(int)p.y];
    // PANEL-1: the click dispatch is async on the Swing EDT (which is also supersampling the panel every ~500ms),
    // so poll a few times before deciding — a single fixed delay can race the busy EDT and miss the focus.
    [self pollPanelKeyboard:0 forIndex:self.currentIndex];
}

// Up to 5 polls (~80ms apart) of whether the last panel tap focused a text field: raise+prefill the keyboard on
// the first true; if all are false, resign once. Bails if the panel was switched/closed mid-poll.
- (void)pollPanelKeyboard:(int)attempt forIndex:(NSInteger)index {
    if (self.currentIndex != index || self.currentIndex < 0) return;   // panel switched/closed → abandon
    if ([JVMLauncher mobilePanelTextActive]) {
        self.panelKbField.text = [JVMLauncher mobilePanelText] ?: @"";
        if (![self.panelKbField isFirstResponder]) [self.panelKbField becomeFirstResponder];
        return;
    }
    if (attempt >= 4) {
        if ([self.panelKbField isFirstResponder]) [self.panelKbField resignFirstResponder];
        return;
    }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ws pollPanelKeyboard:attempt + 1 forIndex:index];
    });
}

- (void)onDone {
    [self.refresh invalidate];
    self.refresh = nil;
    [self.panelKbField resignFirstResponder];
    [JVMLauncher mobileClosePanel];
    [JVMLauncher mobileFlushConfig];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Native Quest Helper (reflowed)

// A genuinely native, reflowed Quest Helper: a searchable/filterable quest list (status pills) that starts a
// helper on tap, plus a "Current quest" view showing the active quest's current-step text and requirement
// checklist. Data comes from QuestHelperBridge (reflection into the external plugin) via JVMLauncher; the
// in-world step arrows still come from the plugin's own overlays on the game canvas.
@interface QuestHelperViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UISegmentedControl *modeSeg;     // Browse | Current
@property (nonatomic, strong) UIView *browseView;
@property (nonatomic, strong) UIView *currentView;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UISegmentedControl *statusSeg;   // All | In progress | Not started | Done
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *currentNameLabel;
@property (nonatomic, strong) UITextView *detailText;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) NSArray<NSDictionary *> *allQuests;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, copy)   NSString *lastListSig;
@property (nonatomic, strong) NSDictionary *activeDict;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL didInitialMode;
@end

@implementation QuestHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [JVMLauncher questSetUiOpen:YES];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    [self.view addSubview:self.drawer];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Quest Helper";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [self.drawer addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [self.drawer addSubview:close];

    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"Browse", @"Current quest"]];
    self.modeSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.modeSeg.selectedSegmentIndex = 0;
    [self.modeSeg addTarget:self action:@selector(onModeChanged) forControlEvents:UIControlEventValueChanged];
    [self.drawer addSubview:self.modeSeg];

    // ---- Browse view ----
    self.browseView = [[UIView alloc] init];
    self.browseView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.drawer addSubview:self.browseView];

    self.search = [[UISearchBar alloc] init];
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    self.search.placeholder = @"Search quests";
    self.search.delegate = self;
    self.search.barStyle = UIBarStyleBlack;
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    [self.browseView addSubview:self.search];

    self.statusSeg = [[UISegmentedControl alloc] initWithItems:@[@"All", @"In progress", @"Not started", @"Done"]];
    self.statusSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusSeg.selectedSegmentIndex = 0;
    [self.statusSeg addTarget:self action:@selector(applyFilter) forControlEvents:UIControlEventValueChanged];
    [self.browseView addSubview:self.statusSeg];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    [self.browseView addSubview:self.table];

    // ---- Current view ----
    self.currentView = [[UIView alloc] init];
    self.currentView.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentView.hidden = YES;
    [self.drawer addSubview:self.currentView];

    self.currentNameLabel = [[UILabel alloc] init];
    self.currentNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.currentNameLabel.font = [UIFont boldSystemFontOfSize:17];
    self.currentNameLabel.textColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:1.0];
    self.currentNameLabel.numberOfLines = 0;
    [self.currentView addSubview:self.currentNameLabel];

    self.detailText = [[UITextView alloc] init];
    self.detailText.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailText.editable = NO;
    self.detailText.backgroundColor = [UIColor clearColor];
    self.detailText.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    self.detailText.font = [UIFont systemFontOfSize:15];
    [self.currentView addSubview:self.detailText];

    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stopButton setTitle:@"Stop helper" forState:UIControlStateNormal];
    self.stopButton.tintColor = [UIColor colorWithRed:1.0 green:0.5 blue:0.45 alpha:1.0];
    self.stopButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.stopButton addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [self.currentView addSubview:self.stopButton];

    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    CGFloat drawerW = MIN(460.0, self.view.bounds.size.width * 0.55);
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [title.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:dg.topAnchor constant:12],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-16],

        [self.modeSeg.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.modeSeg.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:14],
        [self.modeSeg.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-14],

        [self.browseView.topAnchor constraintEqualToAnchor:self.modeSeg.bottomAnchor constant:8],
        [self.browseView.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [self.browseView.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [self.browseView.bottomAnchor constraintEqualToAnchor:self.drawer.bottomAnchor],

        [self.search.topAnchor constraintEqualToAnchor:self.browseView.topAnchor],
        [self.search.leadingAnchor constraintEqualToAnchor:self.browseView.leadingAnchor constant:8],
        [self.search.trailingAnchor constraintEqualToAnchor:self.browseView.trailingAnchor constant:-8],
        [self.statusSeg.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:4],
        [self.statusSeg.leadingAnchor constraintEqualToAnchor:self.browseView.leadingAnchor constant:14],
        [self.statusSeg.trailingAnchor constraintEqualToAnchor:self.browseView.trailingAnchor constant:-14],
        [self.table.topAnchor constraintEqualToAnchor:self.statusSeg.bottomAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:self.browseView.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.browseView.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.browseView.safeAreaLayoutGuide.bottomAnchor],

        [self.currentView.topAnchor constraintEqualToAnchor:self.modeSeg.bottomAnchor constant:12],
        [self.currentView.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:16],
        [self.currentView.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-16],
        [self.currentView.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor constant:-12],

        [self.currentNameLabel.topAnchor constraintEqualToAnchor:self.currentView.topAnchor],
        [self.currentNameLabel.leadingAnchor constraintEqualToAnchor:self.currentView.leadingAnchor],
        [self.currentNameLabel.trailingAnchor constraintEqualToAnchor:self.currentView.trailingAnchor],
        [self.detailText.topAnchor constraintEqualToAnchor:self.currentNameLabel.bottomAnchor constant:8],
        [self.detailText.leadingAnchor constraintEqualToAnchor:self.currentView.leadingAnchor],
        [self.detailText.trailingAnchor constraintEqualToAnchor:self.currentView.trailingAnchor],
        [self.detailText.bottomAnchor constraintEqualToAnchor:self.stopButton.topAnchor constant:-8],
        [self.stopButton.leadingAnchor constraintEqualToAnchor:self.currentView.leadingAnchor],
        [self.stopButton.bottomAnchor constraintEqualToAnchor:self.currentView.bottomAnchor],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onModeChanged {
    BOOL browse = (self.modeSeg.selectedSegmentIndex == 0);
    self.browseView.hidden = !browse;
    self.currentView.hidden = browse;
}

- (void)refresh {
    // Quest list (reload table only when the snapshot actually changed, to avoid clobbering scroll/typing).
    NSString *lj = [JVMLauncher questListJson] ?: @"{}";
    if (![lj isEqualToString:self.lastListSig]) {
        self.lastListSig = lj;
        NSDictionary *d = [self parseObj:lj];
        id quests = d[@"quests"];
        self.allQuests = [quests isKindOfClass:[NSArray class]] ? quests : @[];
        [self applyFilter];
    }
    // Active quest.
    self.activeDict = [self parseObj:[JVMLauncher questActiveJson] ?: @"{}"];
    [self updateCurrent];
    if (!self.didInitialMode) {
        self.didInitialMode = YES;
        if ([self.activeDict[@"active"] boolValue]) {
            self.modeSeg.selectedSegmentIndex = 1;
            [self onModeChanged];
        }
    }
}

- (NSDictionary *)parseObj:(NSString *)json {
    id o = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

- (void)applyFilter {
    NSString *q = self.search.text.lowercaseString;
    NSInteger seg = self.statusSeg.selectedSegmentIndex;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *quest in self.allQuests) {
        NSString *name = [quest[@"name"] description];
        if (q.length && [name.lowercaseString rangeOfString:q].location == NSNotFound) continue;
        NSString *state = [quest[@"state"] description];
        BOOL ok = YES;
        if (seg == 1) ok = [state isEqualToString:@"IN_PROGRESS"];
        else if (seg == 2) ok = [state isEqualToString:@"NOT_STARTED"];
        else if (seg == 3) ok = [state isEqualToString:@"FINISHED"];
        if (ok) [out addObject:quest];
    }
    self.filtered = out;
    [self.table reloadData];
}

- (void)updateCurrent {
    BOOL active = [self.activeDict[@"active"] boolValue];
    if (!active) {
        self.currentNameLabel.text = @"No quest selected";
        self.detailText.text = @"Pick a quest in Browse and tap it to start the helper. In-world step arrows still show on the game screen.";
        self.stopButton.hidden = YES;
        return;
    }
    self.stopButton.hidden = NO;
    self.currentNameLabel.text = [self.activeDict[@"name"] description];
    NSMutableString *s = [NSMutableString string];
    for (id line in (self.activeDict[@"steps"] ?: @[])) {
        if (s.length) [s appendString:@"\n\n"];
        [s appendString:[line description]];
    }
    NSArray *items = self.activeDict[@"items"];
    if ([items isKindOfClass:[NSArray class]] && items.count) {
        [s appendString:@"\n\n— Items —"];
        for (id it in items) [s appendFormat:@"\n• %@", [it description]];
    }
    NSArray *gen = self.activeDict[@"general"];
    if ([gen isKindOfClass:[NSArray class]] && gen.count) {
        [s appendString:@"\n\n— Requirements —"];
        for (id g in gen) [s appendFormat:@"\n• %@", [g description]];
    }
    if (s.length == 0) [s appendString:@"(no current step text)"];
    self.detailText.text = s;
}

- (void)onStop {
    [JVMLauncher questStop];
}

- (void)onDone {
    [self.timer invalidate];
    self.timer = nil;
    [JVMLauncher questSetUiOpen:NO];
    [self dismissViewControllerAnimated:YES completion:nil];
}

// QA-P1-08: the repeating target:self timer retains this VC and keeps firing JNI quest polls forever if the
// panel is dismissed any way other than -onDone (swipe-down, parent dismissal). Invalidate on disappear so the
// retain cycle breaks (the VC can dealloc) and the polling stops — mirrors XpTrackerViewController. These panels
// are leaf modals (no viewDidAppear re-arm), so disappear == dismissal here.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate]; self.timer = nil;
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.filtered.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"q"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"q"];
        cell.backgroundColor = [UIColor clearColor];
    }
    NSDictionary *quest = self.filtered[ip.row];
    cell.textLabel.text = [quest[@"name"] description];
    cell.textLabel.textColor = [UIColor whiteColor];
    NSString *diff = [[quest[@"difficulty"] description] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    cell.detailTextLabel.text = diff.capitalizedString;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];

    NSString *state = [quest[@"state"] description];
    UILabel *pill = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 96, 22)];
    pill.font = [UIFont boldSystemFontOfSize:11];
    pill.textAlignment = NSTextAlignmentCenter;
    pill.layer.cornerRadius = 11;
    pill.clipsToBounds = YES;
    pill.textColor = [UIColor blackColor];
    if ([state isEqualToString:@"FINISHED"]) {
        pill.text = @"Done"; pill.backgroundColor = [UIColor colorWithRed:0.45 green:0.78 blue:0.45 alpha:1.0];
    } else if ([state isEqualToString:@"IN_PROGRESS"]) {
        pill.text = @"In progress"; pill.backgroundColor = [UIColor colorWithRed:0.95 green:0.80 blue:0.35 alpha:1.0];
    } else {
        pill.text = @"Not started"; pill.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    }
    cell.accessoryView = pill;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *name = [self.filtered[ip.row][@"name"] description];
    [JVMLauncher questStart:name];
    self.modeSeg.selectedSegmentIndex = 1;
    [self onModeChanged];
}

#pragma mark UISearchBar

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text { [self applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

@end

#pragma mark - Native World Switcher (reflowed)

// Native World Switcher: a live, filterable world list (members/F2P/PVP, player counts, current-world
// highlight) driven by WorldService via WorldSwitcherBridge; tapping a world hops to it (client thread).
@interface WorldSwitcherViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UISegmentedControl *filterSeg;   // All | Members | Free | PVP
@property (nonatomic, strong) UIButton *sortRegionButton;      // WH-4/WH-5: sort + region menu
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSDictionary *> *allWorlds;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, assign) NSInteger current;
@property (nonatomic, assign) NSInteger sortMode;     // 0 World · 1 Players · 2 Activity (WH-4)
@property (nonatomic, assign) NSInteger regionCode;   // -1 All · else the location code 0/1/3/7 (WH-5)
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation WorldSwitcherViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [JVMLauncher worldSetUiOpen:YES];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    [self.view addSubview:self.drawer];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"World Switcher";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [self.drawer addSubview:title];

    self.regionCode = -1;   // WH-5: all regions by default

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [self.drawer addSubview:close];

    // WH-3 quick-hop: previous / next world (the plugin's signature keybind action, as on-screen buttons).
    UIButton *hopPrev = [UIButton buttonWithType:UIButtonTypeSystem];
    hopPrev.translatesAutoresizingMaskIntoConstraints = NO;
    [hopPrev setTitle:@"◀" forState:UIControlStateNormal];
    hopPrev.accessibilityLabel = @"Previous world";
    hopPrev.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    hopPrev.tintColor = [UIColor whiteColor];
    [hopPrev addTarget:self action:@selector(onHopPrev) forControlEvents:UIControlEventTouchUpInside];
    [self.drawer addSubview:hopPrev];

    UIButton *hopNext = [UIButton buttonWithType:UIButtonTypeSystem];
    hopNext.translatesAutoresizingMaskIntoConstraints = NO;
    [hopNext setTitle:@"▶" forState:UIControlStateNormal];
    hopNext.accessibilityLabel = @"Next world";
    hopNext.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    hopNext.tintColor = [UIColor whiteColor];
    [hopNext addTarget:self action:@selector(onHopNext) forControlEvents:UIControlEventTouchUpInside];
    [self.drawer addSubview:hopNext];

    // WH-4/WH-5: a sort + region menu (kept compact so the ~52%-width drawer stays uncluttered).
    self.sortRegionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sortRegionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sortRegionButton setTitle:@"⇅" forState:UIControlStateNormal];
    self.sortRegionButton.accessibilityLabel = @"Sort and filter worlds";
    self.sortRegionButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.sortRegionButton.tintColor = [UIColor whiteColor];
    self.sortRegionButton.showsMenuAsPrimaryAction = YES;
    [self.drawer addSubview:self.sortRegionButton];
    [self rebuildSortRegionMenu];

    self.search = [[UISearchBar alloc] init];
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    self.search.placeholder = @"World number or activity";
    self.search.delegate = self;
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    [self.drawer addSubview:self.search];

    self.filterSeg = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Members", @"Free", @"PVP"]];
    self.filterSeg.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterSeg.selectedSegmentIndex = 0;
    [self.filterSeg addTarget:self action:@selector(applyFilter) forControlEvents:UIControlEventValueChanged];
    [self.drawer addSubview:self.filterSeg];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 52;
    [self.drawer addSubview:self.table];

    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [title.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:dg.topAnchor constant:12],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-16],
        // Header buttons, right-to-left: ✕ … ▶ ◀ ⇅
        [hopNext.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [hopNext.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-14],
        [hopPrev.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [hopPrev.trailingAnchor constraintEqualToAnchor:hopNext.leadingAnchor constant:-10],
        [self.sortRegionButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [self.sortRegionButton.trailingAnchor constraintEqualToAnchor:hopPrev.leadingAnchor constant:-14],

        [self.search.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.search.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:6],
        [self.search.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-6],
        [self.filterSeg.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:4],
        [self.filterSeg.leadingAnchor constraintEqualToAnchor:dg.leadingAnchor constant:14],
        [self.filterSeg.trailingAnchor constraintEqualToAnchor:dg.trailingAnchor constant:-14],
        [self.table.topAnchor constraintEqualToAnchor:self.filterSeg.bottomAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)refresh {
    NSString *json = [JVMLauncher worldListJson] ?: @"{}";
    id o = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSDictionary *d = [o isKindOfClass:[NSDictionary class]] ? o : @{};
    self.current = [d[@"current"] integerValue];
    id worlds = d[@"worlds"];
    self.allWorlds = [worlds isKindOfClass:[NSArray class]] ? worlds : @[];
    [self applyFilter];
}

- (void)applyFilter {
    NSString *q = self.search.text;
    NSInteger seg = self.filterSeg.selectedSegmentIndex;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *w in self.allWorlds) {
        BOOL members = [w[@"members"] boolValue];
        BOOL pvp = [w[@"pvp"] boolValue];
        if (seg == 1 && !members) continue;
        if (seg == 2 && members) continue;
        if (seg == 3 && !pvp) continue;
        if (self.regionCode >= 0 && [w[@"location"] integerValue] != self.regionCode) continue;   // WH-5
        if (q.length) {
            NSString *idStr = [NSString stringWithFormat:@"%@", w[@"id"]];
            NSString *act = [[w[@"activity"] description] lowercaseString];
            if ([idStr rangeOfString:q].location == NSNotFound &&
                [act rangeOfString:q.lowercaseString].location == NSNotFound) continue;
        }
        [out addObject:w];
    }
    // WH-1 favourites float to the top, then WH-4 sort (World / Players desc / Activity) within each group.
    NSInteger mode = self.sortMode;
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL fa = [a[@"favourite"] boolValue], fb = [b[@"favourite"] boolValue];
        if (fa != fb) return fa ? NSOrderedAscending : NSOrderedDescending;
        if (mode == 1) {   // Players — busiest first
            NSInteger pa = [a[@"players"] integerValue], pb = [b[@"players"] integerValue];
            if (pa != pb) return pa > pb ? NSOrderedAscending : NSOrderedDescending;
        } else if (mode == 2) {   // Activity (alpha), blanks last
            NSString *aa = [a[@"activity"] description] ?: @"", *ab = [b[@"activity"] description] ?: @"";
            if (aa.length == 0 && ab.length) return NSOrderedDescending;
            if (ab.length == 0 && aa.length) return NSOrderedAscending;
            NSComparisonResult r = [aa caseInsensitiveCompare:ab];
            if (r != NSOrderedSame) return r;
        }
        NSInteger ia = [a[@"id"] integerValue], ib = [b[@"id"] integerValue];   // tie-break / World mode
        return ia < ib ? NSOrderedAscending : (ia > ib ? NSOrderedDescending : NSOrderedSame);
    }];
    self.filtered = out;
    [self.table reloadData];
}

// WH-4/WH-5: the sort + region menu (checkmark reflects the current choice).
- (void)rebuildSortRegionMenu {
    __weak typeof(self) ws = self;
    UIAction *(^sortAction)(NSString *, NSInteger) = ^UIAction *(NSString *t, NSInteger m) {
        UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *act) {
            ws.sortMode = m; [ws rebuildSortRegionMenu]; [ws applyFilter];
        }];
        a.state = (ws.sortMode == m) ? UIMenuElementStateOn : UIMenuElementStateOff;
        return a;
    };
    UIMenu *sort = [UIMenu menuWithTitle:@"Sort by" image:nil identifier:nil
                                 options:UIMenuOptionsDisplayInline
                                children:@[sortAction(@"World", 0), sortAction(@"Players", 1), sortAction(@"Activity", 2)]];
    UIAction *(^regionAction)(NSString *, NSInteger) = ^UIAction *(NSString *t, NSInteger code) {
        UIAction *a = [UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *act) {
            ws.regionCode = code; [ws rebuildSortRegionMenu]; [ws applyFilter];
        }];
        a.state = (ws.regionCode == code) ? UIMenuElementStateOn : UIMenuElementStateOff;
        return a;
    };
    UIMenu *region = [UIMenu menuWithTitle:@"Region" image:nil identifier:nil
                                   options:UIMenuOptionsDisplayInline
                                  children:@[regionAction(@"All regions", -1), regionAction(@"US", 0),
                                             regionAction(@"UK", 1), regionAction(@"AUS", 3), regionAction(@"GER", 7)]];
    self.sortRegionButton.menu = [UIMenu menuWithTitle:@"" children:@[sort, region]];
}

- (void)onHopPrev { [JVMLauncher worldHopDirection:YES]; }
- (void)onHopNext { [JVMLauncher worldHopDirection:NO]; }

- (NSString *)locationLabel:(NSInteger)loc {
    switch (loc) {
        case 0: return @"US";
        case 1: return @"UK";
        case 3: return @"AUS";
        case 7: return @"GER";
        default: return @"";
    }
}

- (void)onDone {
    [self.timer invalidate];
    self.timer = nil;
    [JVMLauncher worldSetUiOpen:NO];
    [self dismissViewControllerAnimated:YES completion:nil];
}

// QA-P1-08: the repeating target:self timer retains this VC and keeps firing JNI world-list polls forever if the
// panel is dismissed any way other than -onDone. Invalidate on disappear so the retain cycle breaks and the
// polling stops — mirrors XpTrackerViewController. Leaf modal (no viewDidAppear re-arm), so disappear == dismissal.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate]; self.timer = nil;
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.filtered.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"w"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"w"];
        cell.backgroundColor = [UIColor clearColor];
    }
    NSDictionary *w = self.filtered[ip.row];
    NSInteger wid = [w[@"id"] integerValue];
    BOOL isCurrent = (wid == self.current);
    NSString *act = [w[@"activity"] description];
    cell.textLabel.text = [NSString stringWithFormat:@"World %ld%@", (long)wid, isCurrent ? @"  • current" : @""];
    cell.textLabel.textColor = isCurrent ? [UIColor colorWithRed:0.45 green:0.85 blue:0.45 alpha:1.0] : [UIColor whiteColor];

    NSMutableArray *tags = [NSMutableArray array];
    [tags addObject:[w[@"members"] boolValue] ? @"Members" : @"Free"];
    NSString *locL = [self locationLabel:[w[@"location"] integerValue]];
    if (locL.length) [tags addObject:locL];
    if ([w[@"pvp"] boolValue]) [tags addObject:@"PVP"];
    if ([w[@"highRisk"] boolValue]) [tags addObject:@"High risk"];
    NSString *sub = [tags componentsJoinedByString:@" · "];
    if (act.length) sub = [NSString stringWithFormat:@"%@ — %@", sub, act];
    cell.detailTextLabel.text = sub;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];

    NSInteger players = [w[@"players"] integerValue];
    BOOL fav = [w[@"favourite"] boolValue];
    // Accessory: a ★ favourite toggle (WH-1) + the player count. The star's tag carries the world id.
    UIView *acc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 92, 28)];
    UIButton *star = [UIButton buttonWithType:UIButtonTypeSystem];
    star.frame = CGRectMake(0, 0, 32, 28);
    [star setTitle:(fav ? @"★" : @"☆") forState:UIControlStateNormal];
    star.titleLabel.font = [UIFont systemFontOfSize:18];
    star.tintColor = fav ? [UIColor colorWithRed:0.95 green:0.78 blue:0.30 alpha:1.0] : [UIColor colorWithWhite:0.55 alpha:1.0];
    star.tag = wid;
    [star addTarget:self action:@selector(onToggleFavourite:) forControlEvents:UIControlEventTouchUpInside];
    [acc addSubview:star];
    UILabel *pc = [[UILabel alloc] initWithFrame:CGRectMake(34, 4, 58, 20)];
    pc.font = [UIFont systemFontOfSize:13];
    pc.textAlignment = NSTextAlignmentRight;
    pc.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    pc.text = players >= 0 ? [NSString stringWithFormat:@"%ld", (long)players] : @"—";
    [acc addSubview:pc];
    cell.accessoryView = acc;
    return cell;
}

// WH-1: toggle a world's favourite (the star button), then re-pull so it floats to the top.
- (void)onToggleFavourite:(UIButton *)star {
    NSInteger wid = star.tag;
    BOOL nowFav = NO;
    for (NSDictionary *w in self.allWorlds) {
        if ([w[@"id"] integerValue] == wid) { nowFav = ![w[@"favourite"] boolValue]; break; }
    }
    [JVMLauncher worldSetFavourite:(int)wid favourite:nowFav];
    // Optimistic: flip the local snapshot so the star + sort update before the next bridge poll lands.
    NSMutableArray *updated = [NSMutableArray array];
    for (NSDictionary *w in self.allWorlds) {
        if ([w[@"id"] integerValue] == wid) {
            NSMutableDictionary *m = [w mutableCopy]; m[@"favourite"] = @(nowFav); [updated addObject:m];
        } else { [updated addObject:w]; }
    }
    self.allWorlds = updated;
    [self applyFilter];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger wid = [self.filtered[ip.row][@"id"] integerValue];
    [JVMLauncher worldHop:(int)wid];
}

#pragma mark UISearchBar

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text { [self applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; }

@end

#pragma mark - Grid launcher tile + VC (§3.3 redesign)

// One labelled plugin tile: the plugin icon over its name, with a small ★ when pinned (a favourite).
@interface MUIGridTile : UICollectionViewCell
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *name;
@property (nonatomic, strong) UILabel *star;
@end

@implementation MUIGridTile
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        self.contentView.layer.cornerRadius = 10;
        self.contentView.clipsToBounds = YES;

        _icon = [[UIImageView alloc] init];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_icon];

        _name = [[UILabel alloc] init];
        _name.translatesAutoresizingMaskIntoConstraints = NO;
        _name.font = [UIFont systemFontOfSize:11];
        _name.textColor = [UIColor whiteColor];
        _name.textAlignment = NSTextAlignmentCenter;
        _name.numberOfLines = 2;
        [self.contentView addSubview:_name];

        _star = [[UILabel alloc] init];
        _star.translatesAutoresizingMaskIntoConstraints = NO;
        _star.text = @"★";
        _star.font = [UIFont systemFontOfSize:12];
        _star.textColor = [UIColor colorWithRed:0.95 green:0.78 blue:0.30 alpha:1.0];
        _star.hidden = YES;
        [self.contentView addSubview:_star];

        [NSLayoutConstraint activateConstraints:@[
            [_icon.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_icon.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_icon.widthAnchor constraintEqualToConstant:30],
            [_icon.heightAnchor constraintEqualToConstant:30],
            [_name.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:6],
            [_name.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [_name.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            [_star.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_star.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
        ]];
    }
    return self;
}
@end

#pragma mark - Native XP Tracker panel (RuneLite charcoal style, real session data)

// RuneLite's actual colour scheme + the bundled RuneScape font + square corners (no rounding), per the design.
static UIFont *XpRsFont(CGFloat size) { return [UIFont fontWithName:@"RuneScape" size:size] ?: [UIFont systemFontOfSize:size]; }
static UIColor *XpGray(CGFloat w) { return [UIColor colorWithWhite:w alpha:1.0]; }
// RuneLite XP-tracker formatting: < 10K shows comma-grouped; else 1-decimal K / M (matches the desktop panel).
static NSString *XpFmt(long n) {
    if (n < 10000) {
        NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
        f.numberStyle = NSNumberFormatterDecimalStyle;
        return [f stringFromNumber:@(n)] ?: [NSString stringWithFormat:@"%ld", n];
    }
    if (n < 1000000) return [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    return [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
}

@interface XpTrackerViewController ()
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastJson;
@end

@implementation XpTrackerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40/255.0 green:40/255.0 blue:40/255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30/255.0 green:30/255.0 blue:30/255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerLabel.font = XpRsFont(15);
    self.headerLabel.textColor = XpGray(0.72);
    self.headerLabel.text = @"XP tracker";
    [headerBar addSubview:self.headerLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    [self.drawer addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = XpRsFont(15);
    self.emptyLabel.textColor = XpGray(0.55);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.text = @"Start training a skill to track XP.";
    self.emptyLabel.hidden = YES;
    [self.drawer addSubview:self.emptyLabel];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor constant:10],
        [self.headerLabel.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [self.headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:6],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:6],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-6],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-6],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-12],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor constant:40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor constant:20],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor constant:-20],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onDone {
    [self.timer invalidate]; self.timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate]; self.timer = nil;
}

- (void)refresh {
    NSString *json = [JVMLauncher xpTrackerJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson]) return;   // unchanged -> keep the built boxes
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) d = @{};
    long tg = [d[@"totalGained"] longLongValue];
    long th = [d[@"totalHr"] longLongValue];
    self.headerLabel.text = [NSString stringWithFormat:@"Gained: %@   ·   Per hour: %@", XpFmt(tg), XpFmt(th)];

    NSArray *skills = [d[@"skills"] isKindOfClass:[NSArray class]] ? d[@"skills"] : @[];
    for (UIView *v in [self.stack.arrangedSubviews copy]) { [self.stack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSDictionary *s in skills) {
        if (![s isKindOfClass:[NSDictionary class]]) continue;
        [self.stack addArrangedSubview:[self skillBox:s]];
    }
    self.emptyLabel.hidden = (skills.count > 0);
}

- (UILabel *)statLabel:(NSString *)text right:(BOOL)right {
    UILabel *l = [[UILabel alloc] init];
    l.font = XpRsFont(14);
    l.textColor = XpGray(0.62);
    l.text = text;
    l.textAlignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    return l;
}

- (UIView *)skillBox:(NSDictionary *)s {
    long gained = [s[@"gained"] longLongValue], hr = [s[@"hr"] longLongValue];
    long left = [s[@"left"] longLongValue], actions = [s[@"actions"] longLongValue];

    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 6;
    box.layoutMarginsRelativeArrangement = YES;
    box.layoutMargins = UIEdgeInsetsMake(7, 8, 7, 8);
    box.backgroundColor = [UIColor colorWithRed:43/255.0 green:43/255.0 blue:43/255.0 alpha:1.0];

    UIStackView *topRow = [[UIStackView alloc] init];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.spacing = 8;
    topRow.alignment = UIStackViewAlignmentCenter;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    NSString *b64 = [s[@"icon"] isKindOfClass:[NSString class]] ? s[@"icon"] : nil;
    if (b64.length) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (data) icon.image = [UIImage imageWithData:data];
    }
    [topRow addArrangedSubview:icon];

    UIStackView *leftCol = [[UIStackView alloc] init];
    leftCol.axis = UILayoutConstraintAxisVertical; leftCol.spacing = 2;
    [leftCol addArrangedSubview:[self statLabel:[NSString stringWithFormat:@"XP gained: %@", XpFmt(gained)] right:NO]];
    [leftCol addArrangedSubview:[self statLabel:[NSString stringWithFormat:@"XP/hour: %@", XpFmt(hr)] right:NO]];

    UIStackView *rightCol = [[UIStackView alloc] init];
    rightCol.axis = UILayoutConstraintAxisVertical; rightCol.spacing = 2;
    [rightCol addArrangedSubview:[self statLabel:[NSString stringWithFormat:@"XP left: %@", XpFmt(left)] right:YES]];
    [rightCol addArrangedSubview:[self statLabel:[NSString stringWithFormat:@"Actions: %@", XpFmt(actions)] right:YES]];

    UIStackView *cols = [[UIStackView alloc] init];
    cols.axis = UILayoutConstraintAxisHorizontal; cols.distribution = UIStackViewDistributionFillEqually; cols.spacing = 6;
    [cols addArrangedSubview:leftCol];
    [cols addArrangedSubview:rightCol];
    [topRow addArrangedSubview:cols];

    [box addArrangedSubview:topRow];
    [box addArrangedSubview:[self barStart:[s[@"startLevel"] intValue] end:[s[@"endLevel"] intValue] progress:[s[@"progress"] intValue]]];
    return box;
}

- (UIView *)barStart:(int)start end:(int)end progress:(int)pct {
    if (pct < 0) pct = 0; if (pct > 100) pct = 100;
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
    [bar.heightAnchor constraintEqualToConstant:16].active = YES;

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = [UIColor colorWithRed:79/255.0 green:122/255.0 blue:35/255.0 alpha:1.0]; // progress green
    [bar addSubview:fill];
    [NSLayoutConstraint activateConstraints:@[
        [fill.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [fill.widthAnchor constraintEqualToAnchor:bar.widthAnchor multiplier:(pct / 100.0)],
    ]];

    UILabel *(^lvl)(NSString *) = ^UILabel *(NSString *t) {
        UILabel *l = [[UILabel alloc] init];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        l.font = XpRsFont(14);
        l.textColor = [UIColor whiteColor];
        l.text = t;
        return l;
    };
    UILabel *lv1 = lvl([NSString stringWithFormat:@"Lvl %d", start]);
    UILabel *pc = lvl([NSString stringWithFormat:@"%d%%", pct]);
    UILabel *lv2 = lvl([NSString stringWithFormat:@"Lvl %d", end]);
    [bar addSubview:lv1]; [bar addSubview:pc]; [bar addSubview:lv2];
    [NSLayoutConstraint activateConstraints:@[
        [lv1.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:6],
        [lv1.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [pc.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
        [pc.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [lv2.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-6],
        [lv2.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];
    return bar;
}

@end

#pragma mark - Native Loot Tracker panel (read-only per-source loot, RuneLite charcoal style)

// Mirrors the XP Tracker drawer: a right-edge charcoal drawer of per-source (per-NPC/event) loot boxes, each
// listing its merged item drops + value, refreshed on a 2s diff-poll while open. Replaces the rendered-Swing
// image fallback, which OOM'd the 256MB game heap on tall histories. Data: JVMLauncher.lootJson (the shared
// LootTrackerBridge snapshot); "Reset All" mirrors the desktop panel's clear (LootTrackerBridge.resetAll).
@interface LootTrackerViewController ()
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastJson;
@end

@implementation LootTrackerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40 / 255.0 green:40 / 255.0 blue:40 / 255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30 / 255.0 green:30 / 255.0 blue:30 / 255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerLabel.font = XpRsFont(15);
    self.headerLabel.textColor = XpGray(0.72);
    self.headerLabel.text = @"Loot tracker";
    [headerBar addSubview:self.headerLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.translatesAutoresizingMaskIntoConstraints = NO;
    [reset setTitle:@"Reset" forState:UIControlStateNormal];
    reset.titleLabel.font = XpRsFont(14);
    [reset setTitleColor:XpGray(0.62) forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:reset];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    [self.drawer addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = XpRsFont(15);
    self.emptyLabel.textColor = XpGray(0.55);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.text = @"No loot tracked yet.\nKill an NPC or open a reward to start.";
    self.emptyLabel.hidden = YES;
    [self.drawer addSubview:self.emptyLabel];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor
                                                       constant:10],
        [self.headerLabel.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [self.headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:reset.leadingAnchor
                                                                  constant:-8],
        [reset.trailingAnchor constraintEqualToAnchor:close.leadingAnchor
                                             constant:-12],
        [reset.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor
                                             constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:scroll.topAnchor
                                             constant:6],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                                 constant:6],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                                  constant:-6],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor
                                                constant:-6],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor
                                               constant:-12],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor
                                                  constant:40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor
                                                      constant:20],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor
                                                       constant:-20],
    ]];

    [JVMLauncher lootSetUiOpen:YES]; // gate the client-thread snapshot refresh to while-shown
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onDone {
    [JVMLauncher lootSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [JVMLauncher lootSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)onReset {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset All"
                                                               message:@"Clear the entire loot log? This cannot be undone."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Reset"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *act) {
                                            [JVMLauncher lootResetAll];
                                            ws.lastJson = nil; // force a rebuild on the next poll (the bridge re-snapshots empty)
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)refresh {
    NSString *json = [JVMLauncher lootJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson])
        return; // unchanged -> keep the built boxes
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]])
        d = @{};
    NSArray *sources = [d[@"sources"] isKindOfClass:[NSArray class]] ? d[@"sources"] : @[];

    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    long grandValue = 0;
    for (NSDictionary *s in sources) {
        if (![s isKindOfClass:[NSDictionary class]])
            continue;
        grandValue += [s[@"totalValue"] longLongValue];
        [self.stack addArrangedSubview:[self sourceBox:s]];
    }
    self.headerLabel.text = sources.count ? [NSString stringWithFormat:@"Total value: %@", XpFmt(grandValue)] : @"Loot tracker";
    self.emptyLabel.hidden = (sources.count > 0);
}

- (UILabel *)lootLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color right:(BOOL)right {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    l.text = text;
    l.textAlignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    return l;
}

- (UIView *)sourceBox:(NSDictionary *)s {
    NSString *name = [s[@"name"] isKindOfClass:[NSString class]] ? s[@"name"] : @"?";
    NSString *subTitle = [s[@"subTitle"] isKindOfClass:[NSString class]] ? s[@"subTitle"] : @"";
    long kills = [s[@"kills"] longLongValue];
    long total = [s[@"totalValue"] longLongValue];
    NSArray *items = [s[@"items"] isKindOfClass:[NSArray class]] ? s[@"items"] : @[];

    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 3;
    box.layoutMarginsRelativeArrangement = YES;
    box.layoutMargins = UIEdgeInsetsMake(7, 8, 7, 8);
    box.backgroundColor = [UIColor colorWithRed:43 / 255.0 green:43 / 255.0 blue:43 / 255.0 alpha:1.0];

    // Title row: source name (+ optional subtitle, e.g. a clue tier) on the left, stacked GE value on the right.
    NSString *titleText = subTitle.length ? [NSString stringWithFormat:@"%@ (%@)", name, subTitle] : name;
    UIStackView *titleRow = [[UIStackView alloc] init];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.spacing = 8;
    titleRow.alignment = UIStackViewAlignmentCenter;
    UILabel *nameL = [self lootLabel:titleText font:XpRsFont(15) color:[UIColor whiteColor] right:NO];
    [nameL setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *valL = [self lootLabel:[NSString stringWithFormat:@"%@", XpFmt(total)]
                               font:XpRsFont(15)
                              color:[UIColor colorWithRed:1.0 green:0.86 blue:0.34 alpha:1.0]
                              right:YES]; // gp gold
    [valL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [titleRow addArrangedSubview:nameL];
    [titleRow addArrangedSubview:valL];
    [box addArrangedSubview:titleRow];

    if (kills > 0) {
        [box addArrangedSubview:[self lootLabel:[NSString stringWithFormat:@"Count: %@", XpFmt(kills)]
                                           font:XpRsFont(13)
                                          color:XpGray(0.5)
                                          right:NO]];
    }

    // One row per merged drop: "qty × name" on the left, its stacked value on the right.
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:[NSDictionary class]])
            continue;
        NSString *iname = [it[@"name"] isKindOfClass:[NSString class]] ? it[@"name"] : @"?";
        long qty = [it[@"qty"] longLongValue];
        long ge = [it[@"ge"] longLongValue];
        NSString *left = qty > 1 ? [NSString stringWithFormat:@"%@ × %@", XpFmt(qty), iname] : iname;

        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 8;
        row.alignment = UIStackViewAlignmentCenter;
        UILabel *l = [self lootLabel:left font:XpRsFont(14) color:XpGray(0.7) right:NO];
        [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *r = [self lootLabel:ge > 0 ? XpFmt(ge) : @"" font:XpRsFont(14) color:XpGray(0.5) right:YES];
        [r setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:l];
        [row addArrangedSubview:r];
        [box addArrangedSubview:row];
    }
    return box;
}

@end

#pragma mark - Native Time Tracking panel (read-only farming/bird-house/timer countdowns)

// Mirrors the Loot Tracker drawer, but read-only: a right-edge charcoal drawer of the Time Tracking plugin's
// farming patches, farming contract, bird houses, timers and stopwatches, each shown as a live status/countdown
// instead of the dense desktop image. Data: JVMLauncher.timeTrackingJson (the shared TimeTrackingBridge
// snapshot); the bridge gives an absolute readyTime + a derived remainingSec, so a 2s diff-poll keeps the
// countdowns ticking while the screen is open.

// Pretty seconds -> compact countdown: "2h 05m" / "12m 30s" / "45s".
static NSString *TtCountdown(long sec) {
    if (sec <= 0)
        return @"0s";
    long h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60;
    if (h > 0)
        return [NSString stringWithFormat:@"%ldh %02ldm", h, m];
    if (m > 0)
        return [NSString stringWithFormat:@"%ldm %02lds", m, s];
    return [NSString stringWithFormat:@"%lds", s];
}

// Status text + colour for a farming/contract/bird-house entry from its {state, remainingSec}.
static NSString *TtFarmStatus(id stateObj, long remainingSec, UIColor **outColor) {
    UIColor *amber = [UIColor colorWithRed:1.0 green:0.78 blue:0.36 alpha:1.0];  // growing
    UIColor *green = [UIColor colorWithRed:0.49 green:0.83 blue:0.45 alpha:1.0]; // ready
    UIColor *dim = XpGray(0.5);                                                  // empty / unknown
    if (remainingSec > 0) {
        *outColor = amber;
        return TtCountdown(remainingSec);
    }
    NSString *st = [stateObj isKindOfClass:[NSString class]] ? stateObj : @"";
    if ([st isEqualToString:@"COMPLETED"] || [st isEqualToString:@"HARVESTABLE"]) {
        *outColor = green;
        return @"Ready";
    }
    if ([st isEqualToString:@"EMPTY"]) {
        *outColor = dim;
        return @"Empty";
    }
    if ([st isEqualToString:@"IN_PROGRESS"] || [st isEqualToString:@"GROWING"] || [st isEqualToString:@"SEEDED"]) {
        *outColor = amber;
        return @"Growing";
    }
    if ([st isEqualToString:@"OCCUPIED"]) {
        *outColor = dim;
        return @"Occupied";
    }
    if (st.length == 0 || [st isEqualToString:@"UNKNOWN"]) {
        *outColor = dim;
        return @"—";
    }
    // Default: "FOO_BAR" -> "Foo bar".
    NSString *pretty = [[st stringByReplacingOccurrencesOfString:@"_" withString:@" "] lowercaseString];
    pretty = [[[pretty substringToIndex:1] uppercaseString] stringByAppendingString:[pretty substringFromIndex:1]];
    *outColor = dim;
    return pretty;
}

@interface TimeTrackingViewController ()
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastJson;
@end

@implementation TimeTrackingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40 / 255.0 green:40 / 255.0 blue:40 / 255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30 / 255.0 green:30 / 255.0 blue:30 / 255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerLabel.font = XpRsFont(15);
    self.headerLabel.textColor = XpGray(0.72);
    self.headerLabel.text = @"Time tracking";
    [headerBar addSubview:self.headerLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    [self.drawer addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = XpRsFont(15);
    self.emptyLabel.textColor = XpGray(0.55);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.text = @"Nothing tracked yet.\nPlant a crop, set a timer, or seed a bird house.";
    self.emptyLabel.hidden = YES;
    [self.drawer addSubview:self.emptyLabel];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor
                                                       constant:10],
        [self.headerLabel.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [self.headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor
                                                                  constant:-8],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor
                                             constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:scroll.topAnchor
                                             constant:6],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                                 constant:6],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                                  constant:-6],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor
                                                constant:-6],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor
                                               constant:-12],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor
                                                  constant:40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor
                                                      constant:20],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor
                                                       constant:-20],
    ]];

    [JVMLauncher timeTrackingSetUiOpen:YES]; // gate the client-thread snapshot refresh to while-shown
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onDone {
    [JVMLauncher timeTrackingSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [JVMLauncher timeTrackingSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
}

- (UILabel *)ttLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color right:(BOOL)right {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    l.text = text;
    l.textAlignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    return l;
}

// A titled charcoal box with one "left … right" row per entry. Each row is @[leftString, rightString, rightColor].
- (UIView *)sectionBox:(NSString *)title rows:(NSArray<NSArray *> *)rows {
    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 3;
    box.layoutMarginsRelativeArrangement = YES;
    box.layoutMargins = UIEdgeInsetsMake(7, 8, 7, 8);
    box.backgroundColor = [UIColor colorWithRed:43 / 255.0 green:43 / 255.0 blue:43 / 255.0 alpha:1.0];

    [box addArrangedSubview:[self ttLabel:title font:XpRsFont(15) color:[UIColor whiteColor] right:NO]];

    for (NSArray *row in rows) {
        UIStackView *r = [[UIStackView alloc] init];
        r.axis = UILayoutConstraintAxisHorizontal;
        r.spacing = 8;
        r.alignment = UIStackViewAlignmentCenter;
        UILabel *l = [self ttLabel:row[0] font:XpRsFont(14) color:XpGray(0.7) right:NO];
        [l setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *rl = [self ttLabel:row[1] font:XpRsFont(14) color:row[2] right:YES];
        [rl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [r addArrangedSubview:l];
        [r addArrangedSubview:rl];
        [box addArrangedSubview:r];
    }
    return box;
}

- (void)refresh {
    NSString *json = [JVMLauncher timeTrackingJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson])
        return; // unchanged -> keep the built boxes
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]])
        d = @{};

    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSInteger sections = 0;

    // Farming patches (all tabs, so an empty patch reads "Empty").
    NSArray *farming = [d[@"farming"] isKindOfClass:[NSArray class]] ? d[@"farming"] : @[];
    NSMutableArray *frows = [NSMutableArray array];
    for (NSDictionary *p in farming) {
        if (![p isKindOfClass:[NSDictionary class]])
            continue;
        UIColor *c = nil;
        NSString *st = TtFarmStatus(p[@"state"], [p[@"remainingSec"] longLongValue], &c);
        NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"?";
        [frows addObject:@[ name, st, c ]];
    }
    if (frows.count) {
        [self.stack addArrangedSubview:[self sectionBox:@"Farming patches" rows:frows]];
        sections++;
    }

    // Farming contract (only when one is active).
    NSDictionary *contract = [d[@"contract"] isKindOfClass:[NSDictionary class]] ? d[@"contract"] : nil;
    if (contract && [contract[@"active"] boolValue]) {
        UIColor *c = nil;
        NSString *st = TtFarmStatus(contract[@"state"], [contract[@"remainingSec"] longLongValue], &c);
        NSString *name = [contract[@"name"] isKindOfClass:[NSString class]] ? contract[@"name"] : @"Contract";
        [self.stack addArrangedSubview:[self sectionBox:@"Farming contract" rows:@[ @[ name, st, c ] ]]];
        sections++;
    }

    // Bird houses.
    NSArray *birdhouses = [d[@"birdhouses"] isKindOfClass:[NSArray class]] ? d[@"birdhouses"] : @[];
    NSMutableArray *brows = [NSMutableArray array];
    for (NSDictionary *b in birdhouses) {
        if (![b isKindOfClass:[NSDictionary class]])
            continue;
        UIColor *c = nil;
        NSString *st = TtFarmStatus(b[@"state"], [b[@"remainingSec"] longLongValue], &c);
        NSString *name = [b[@"name"] isKindOfClass:[NSString class]] ? b[@"name"] : @"?";
        [brows addObject:@[ name, st, c ]];
    }
    if (brows.count) {
        [self.stack addArrangedSubview:[self sectionBox:@"Bird houses" rows:brows]];
        sections++;
    }

    // Timers (countdown while active, else paused).
    NSArray *timers = [d[@"timers"] isKindOfClass:[NSArray class]] ? d[@"timers"] : @[];
    NSMutableArray *trows = [NSMutableArray array];
    for (NSDictionary *t in timers) {
        if (![t isKindOfClass:[NSDictionary class]])
            continue;
        BOOL active = [t[@"active"] boolValue];
        long rem = [t[@"remainingSec"] longLongValue];
        UIColor *c = active ? (rem > 0 ? [UIColor colorWithRed:1.0 green:0.78 blue:0.36 alpha:1.0]
                                       : [UIColor colorWithRed:0.49 green:0.83 blue:0.45 alpha:1.0])
                            : XpGray(0.5);
        NSString *st = !active ? @"Paused" : (rem > 0 ? TtCountdown(rem) : @"Done");
        NSString *name = [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : @"Timer";
        [trows addObject:@[ name, st, c ]];
    }
    if (trows.count) {
        [self.stack addArrangedSubview:[self sectionBox:@"Timers" rows:trows]];
        sections++;
    }

    // Stopwatches (count up).
    NSArray *stopwatches = [d[@"stopwatches"] isKindOfClass:[NSArray class]] ? d[@"stopwatches"] : @[];
    NSMutableArray *srows = [NSMutableArray array];
    for (NSDictionary *sw in stopwatches) {
        if (![sw isKindOfClass:[NSDictionary class]])
            continue;
        BOOL active = [sw[@"active"] boolValue];
        long el = [sw[@"elapsedSec"] longLongValue];
        UIColor *c = active ? [UIColor colorWithRed:0.49 green:0.83 blue:0.45 alpha:1.0] : XpGray(0.5);
        NSString *name = [sw[@"name"] isKindOfClass:[NSString class]] ? sw[@"name"] : @"Stopwatch";
        [srows addObject:@[ name, TtCountdown(el), c ]];
    }
    if (srows.count) {
        [self.stack addArrangedSubview:[self sectionBox:@"Stopwatches" rows:srows]];
        sections++;
    }

    self.emptyLabel.hidden = (sections > 0);
}

@end

#pragma mark - Native Config Profiles panel (list + switch active profile)

@interface ConfigProfilesViewController ()
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastJson;
@property (nonatomic, copy) NSArray<NSDictionary *> *profiles;
@end

@implementation ConfigProfilesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40 / 255.0 green:40 / 255.0 blue:40 / 255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30 / 255.0 green:30 / 255.0 blue:30 / 255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = XpRsFont(15);
    title.textColor = XpGray(0.72);
    title.text = @"Profiles";
    [headerBar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    [self.drawer addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = XpRsFont(15);
    self.emptyLabel.textColor = XpGray(0.55);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.text = @"No config profiles.";
    self.emptyLabel.hidden = YES;
    [self.drawer addSubview:self.emptyLabel];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [title.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor
                                            constant:10],
        [title.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor
                                             constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:scroll.topAnchor
                                             constant:8],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                                 constant:8],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                                  constant:-8],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor
                                                constant:-8],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor
                                               constant:-16],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor
                                                  constant:40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor
                                                      constant:20],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor
                                                       constant:-20],
    ]];

    [self refresh];
    // Re-poll on a light cadence: a switch reloads config asynchronously, so the active flag flips a beat later.
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onDone {
    [self.timer invalidate];
    self.timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)refresh {
    NSString *json = [JVMLauncher profilesJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson])
        return; // unchanged -> keep the built rows
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]])
        d = @{};
    NSArray *profiles = [d[@"profiles"] isKindOfClass:[NSArray class]] ? d[@"profiles"] : @[];
    self.profiles = profiles;

    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (NSUInteger i = 0; i < profiles.count; i++) {
        NSDictionary *p = profiles[i];
        if (![p isKindOfClass:[NSDictionary class]])
            continue;
        [self.stack addArrangedSubview:[self profileRow:p index:(NSInteger)i]];
    }
    self.emptyLabel.hidden = (profiles.count > 0);
}

- (UIView *)profileRow:(NSDictionary *)p index:(NSInteger)index {
    NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"?";
    BOOL active = [p[@"active"] boolValue];
    BOOL internal = [p[@"internal"] boolValue];
    BOOL sync = [p[@"sync"] boolValue];

    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.tag = index;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    row.titleLabel.font = XpRsFont(16);
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    row.layer.cornerRadius = 6;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;

    NSMutableString *label = [NSMutableString string];
    [label appendString:active ? @"✓ " : @"   "];
    [label appendString:name];
    if (sync)
        [label appendString:@"  ⟳"]; // synced to the RuneLite account
    if (internal)
        [label appendString:@"  (system)"]; // engine profile, not user-switchable

    if (active) {
        row.backgroundColor = [UIColor colorWithRed:0.20 green:0.45 blue:0.22 alpha:1.0]; // active = green
        [row setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else if (internal) {
        row.backgroundColor = [UIColor colorWithRed:43 / 255.0 green:43 / 255.0 blue:43 / 255.0 alpha:1.0];
        [row setTitleColor:XpGray(0.40) forState:UIControlStateNormal]; // greyed: read-only
    } else {
        row.backgroundColor = [UIColor colorWithRed:43 / 255.0 green:43 / 255.0 blue:43 / 255.0 alpha:1.0];
        [row setTitleColor:XpGray(0.82) forState:UIControlStateNormal];
    }
    [row setTitle:label forState:UIControlStateNormal];

    // Active or internal profiles are not switch targets (switching to the active one is a no-op; internal
    // engine profiles aren't user-selectable, matching the desktop panel).
    if (!active && !internal) {
        [row addTarget:self action:@selector(onTapProfile:) forControlEvents:UIControlEventTouchUpInside];
    }
    return row;
}

- (void)onTapProfile:(UIButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.profiles.count)
        return;
    NSDictionary *p = self.profiles[(NSUInteger)b.tag];
    if ([p[@"active"] boolValue] || [p[@"internal"] boolValue])
        return;
    long long pid = [p[@"id"] longLongValue];
    NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"?";

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Switch profile"
                                                               message:[NSString stringWithFormat:@"Load profile “%@”? This reloads all config and plugin settings.", name]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Switch"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
                                            [JVMLauncher switchProfile:pid];
                                            ws.lastJson = nil; // force a rebuild so the active flag flips on the next poll
                                        }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Native Infobox menu panel (the touch equivalent of right-clicking an infobox, #20)

@interface InfoBoxMenuViewController ()
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *lastJson;
@property (nonatomic, copy) NSArray<NSDictionary *> *infoboxes;
@end

@implementation InfoBoxMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40 / 255.0 green:40 / 255.0 blue:40 / 255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30 / 255.0 green:30 / 255.0 blue:30 / 255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = XpRsFont(15);
    title.textColor = XpGray(0.72);
    title.text = @"Infoboxes";
    [headerBar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    [self.drawer addSubview:scroll];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.font = XpRsFont(15);
    self.emptyLabel.textColor = XpGray(0.55);
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.text = @"No infoboxes active.\nTap one to open its menu.";
    self.emptyLabel.hidden = YES;
    [self.drawer addSubview:self.emptyLabel];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [title.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor
                                            constant:10],
        [title.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor
                                             constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [scroll.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:scroll.topAnchor
                                             constant:8],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor
                                                 constant:8],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                                  constant:-8],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor
                                                constant:-8],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor
                                               constant:-16],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor
                                                  constant:40],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor
                                                      constant:20],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor
                                                       constant:-20],
    ]];

    [JVMLauncher infoBoxSetUiOpen:YES]; // gate the client-thread snapshot refresh to while-shown
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onDone {
    [JVMLauncher infoBoxSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [JVMLauncher infoBoxSetUiOpen:NO];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)refresh {
    NSString *json = [JVMLauncher infoBoxesJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson])
        return; // unchanged -> keep the built rows
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]])
        d = @{};
    NSArray *boxes = [d[@"infoboxes"] isKindOfClass:[NSArray class]] ? d[@"infoboxes"] : @[];
    self.infoboxes = boxes;

    for (UIView *v in [self.stack.arrangedSubviews copy]) {
        [self.stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    for (NSUInteger i = 0; i < boxes.count; i++) {
        NSDictionary *box = boxes[i];
        if (![box isKindOfClass:[NSDictionary class]])
            continue;
        [self.stack addArrangedSubview:[self infoBoxRow:box index:(NSInteger)i]];
    }
    self.emptyLabel.hidden = (boxes.count > 0);
}

- (UIView *)infoBoxRow:(NSDictionary *)box index:(NSInteger)index {
    NSString *name = [box[@"name"] isKindOfClass:[NSString class]] ? box[@"name"] : @"";
    NSString *text = [box[@"text"] isKindOfClass:[NSString class]] ? box[@"text"] : @"";
    NSString *tooltip = [box[@"tooltip"] isKindOfClass:[NSString class]] ? box[@"tooltip"] : @"";
    NSArray *menu = [box[@"menu"] isKindOfClass:[NSArray class]] ? box[@"menu"] : @[];

    // Pick the most descriptive label available (tooltip > name > text), with the counter text appended.
    NSString *primary = tooltip.length ? tooltip : (name.length ? name : text);
    NSString *label = (text.length && ![text isEqualToString:primary])
                          ? [NSString stringWithFormat:@"%@  —  %@", primary, text]
                          : (primary.length ? primary : @"(infobox)");

    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.tag = index;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
    row.titleLabel.font = XpRsFont(15);
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    row.layer.cornerRadius = 6;
    row.backgroundColor = [UIColor colorWithRed:43 / 255.0 green:43 / 255.0 blue:43 / 255.0 alpha:1.0];
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:42].active = YES;
    [row setTitle:label forState:UIControlStateNormal];

    if (menu.count) {
        [row setTitleColor:XpGray(0.82) forState:UIControlStateNormal];
        [row addTarget:self action:@selector(onTapInfoBox:) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [row setTitleColor:XpGray(0.45) forState:UIControlStateNormal]; // no menu options -> not actionable
    }
    return row;
}

- (void)onTapInfoBox:(UIButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.infoboxes.count)
        return;
    NSDictionary *box = self.infoboxes[(NSUInteger)b.tag];
    NSArray *menu = [box[@"menu"] isKindOfClass:[NSArray class]] ? box[@"menu"] : @[];
    if (!menu.count)
        return;
    // Invoke uses the engine list index from the snapshot (the JSON skips null boxes, so it may differ from the
    // row position), matching InfoBoxBridge.invokeInfoBoxMenu's index model.
    NSInteger engineIndex = [box[@"index"] integerValue];
    NSString *primary = [box[@"tooltip"] isKindOfClass:[NSString class]] && [box[@"tooltip"] length]
                            ? box[@"tooltip"]
                            : ([box[@"name"] isKindOfClass:[NSString class]] ? box[@"name"] : @"Infobox");

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:primary
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (id opt in menu) {
        if (![opt isKindOfClass:[NSString class]] || [(NSString *)opt length] == 0)
            continue;
        NSString *option = opt;
        BOOL destructive = [option caseInsensitiveCompare:@"Delete"] == NSOrderedSame;
        [sheet addAction:[UIAlertAction actionWithTitle:option
                                                  style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *act) {
                                                    [JVMLauncher invokeInfoBoxMenu:(int)engineIndex option:option];
                                                    ws.lastJson = nil; // the action may add/remove/move infoboxes -> rebuild
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // iPad/large-screen: anchor the action sheet's popover to the tapped row (a nil source crashes).
    sheet.popoverPresentationController.sourceView = b;
    sheet.popoverPresentationController.sourceRect = b.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Native Notes panel (editable, RuneLite charcoal style)

@interface NotesViewController () <UITextViewDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *writeTimer;
@end

@implementation NotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    UIView *drawer = [[UIView alloc] init];
    drawer.translatesAutoresizingMaskIntoConstraints = NO;
    drawer.backgroundColor = [UIColor colorWithRed:40/255.0 green:40/255.0 blue:40/255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30/255.0 green:30/255.0 blue:30/255.0 alpha:1.0]; // DARKER_GRAY
    [drawer addSubview:headerBar];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = XpRsFont(15);
    title.textColor = XpGray(0.72);
    title.text = @"Notes";
    [headerBar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.backgroundColor = [UIColor colorWithRed:35/255.0 green:35/255.0 blue:35/255.0 alpha:1.0];
    self.textView.textColor = XpGray(0.84);
    self.textView.font = XpRsFont(16);
    self.textView.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // caret = brand orange
    self.textView.autocorrectionType = UITextAutocorrectionTypeYes;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.textView.delegate = self;
    self.textView.text = [JVMLauncher notesGet] ?: @"";
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    [drawer addSubview:self.textView];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [title.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor constant:10],
        [title.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [self.textView.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:drawer.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:drawer.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],
    ]];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];
    // Never lose an edit: flush the note immediately if the app backgrounds before the debounce timer fires.
    [nc addObserver:self selector:@selector(flushWrite) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)kbShow:(NSNotification *)n {
    UIWindow *w = self.view.window;
    if (!w) return;
    CGRect kf = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect tvInWin = [self.textView convertRect:self.textView.bounds toView:w];
    CGFloat overlap = CGRectGetMaxY(tvInWin) - kf.origin.y;
    if (overlap < 0) overlap = 0;
    self.textView.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    self.textView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, overlap, 0);
}

- (void)kbHide:(NSNotification *)n {
    self.textView.contentInset = UIEdgeInsetsZero;
    self.textView.verticalScrollIndicatorInsets = UIEdgeInsetsZero;
}

- (void)textViewDidChange:(UITextView *)textView {
    [self.writeTimer invalidate];
    self.writeTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 target:self selector:@selector(flushWrite) userInfo:nil repeats:NO];
}

- (void)flushWrite {
    [self.writeTimer invalidate];
    self.writeTimer = nil;
    [JVMLauncher notesSet:self.textView.text ?: @""];
}

- (void)onDone {
    [self.textView resignFirstResponder];
    [self flushWrite];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self flushWrite];
}

- (void)dealloc {
    [_writeTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

#pragma mark - Native Grand Exchange panel (Offers + live Search, RuneLite charcoal style)

// The rendered Swing GE panel couldn't be typed into (its search field has no live filter and the plugin can't be
// forked), so the native screen drives the GE directly: an Offers tab reflowing the live 8-slot snapshot + saved
// trade history (GrandExchangeBridge.getGeJson), and a Search tab whose native field types straight into the iOS
// keyboard and queries GrandExchangeBridge.search. Same right-anchored charcoal drawer geometry as XP Tracker.
@interface GeViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *drawer;
@property (nonatomic, strong) UISegmentedControl *tabs;
@property (nonatomic, strong) UIView *offersTab;
@property (nonatomic, strong) UIView *searchTab;
@property (nonatomic, strong) UIStackView *offersStack;
@property (nonatomic, strong) UILabel *offersEmpty;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIStackView *searchStack;
@property (nonatomic, strong) UILabel *searchEmpty;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSTimer *searchDebounce;
@property (nonatomic, copy) NSString *lastJson;
@end

@implementation GeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [JVMLauncher geSetUiOpen:YES];   // arm the client-thread offer refresh while shown

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self.view addSubview:dim];
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDone)]];

    self.drawer = [[UIView alloc] init];
    self.drawer.translatesAutoresizingMaskIntoConstraints = NO;
    self.drawer.backgroundColor = [UIColor colorWithRed:40/255.0 green:40/255.0 blue:40/255.0 alpha:1.0]; // DARK_GRAY
    [self.view addSubview:self.drawer];

    UIView *headerBar = [[UIView alloc] init];
    headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    headerBar.backgroundColor = [UIColor colorWithRed:30/255.0 green:30/255.0 blue:30/255.0 alpha:1.0]; // DARKER_GRAY
    [self.drawer addSubview:headerBar];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = XpRsFont(15);
    titleLabel.textColor = XpGray(0.72);
    titleLabel.text = @"Grand Exchange";
    [headerBar addSubview:titleLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.accessibilityLabel = @"Close";
    close.titleLabel.font = [UIFont systemFontOfSize:17];
    close.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0]; // BRAND_ORANGE
    [close addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [headerBar addSubview:close];

    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Offers", @"Search"]];
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabs.selectedSegmentIndex = 0;
    self.tabs.selectedSegmentTintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0];
    [self.tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: XpGray(0.7)} forState:UIControlStateNormal];
    [self.tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor]} forState:UIControlStateSelected];
    [self.tabs addTarget:self action:@selector(onTab) forControlEvents:UIControlEventValueChanged];
    [self.drawer addSubview:self.tabs];

    // ---- Offers tab -------------------------------------------------------------------------------
    self.offersTab = [[UIView alloc] init];
    self.offersTab.translatesAutoresizingMaskIntoConstraints = NO;
    [self.drawer addSubview:self.offersTab];

    UIScrollView *offScroll = [[UIScrollView alloc] init];
    offScroll.translatesAutoresizingMaskIntoConstraints = NO;
    offScroll.alwaysBounceVertical = YES;
    [self.offersTab addSubview:offScroll];

    self.offersStack = [[UIStackView alloc] init];
    self.offersStack.axis = UILayoutConstraintAxisVertical;
    self.offersStack.spacing = 6;
    self.offersStack.translatesAutoresizingMaskIntoConstraints = NO;
    [offScroll addSubview:self.offersStack];

    self.offersEmpty = [[UILabel alloc] init];
    self.offersEmpty.translatesAutoresizingMaskIntoConstraints = NO;
    self.offersEmpty.font = XpRsFont(15);
    self.offersEmpty.textColor = XpGray(0.55);
    self.offersEmpty.numberOfLines = 0;
    self.offersEmpty.textAlignment = NSTextAlignmentCenter;
    self.offersEmpty.text = @"No active offers.";
    self.offersEmpty.hidden = YES;
    [self.offersTab addSubview:self.offersEmpty];

    // ---- Search tab -------------------------------------------------------------------------------
    self.searchTab = [[UIView alloc] init];
    self.searchTab.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchTab.hidden = YES;
    [self.drawer addSubview:self.searchTab];

    self.searchField = [[UITextField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.delegate = self;
    self.searchField.font = XpRsFont(15);
    self.searchField.textColor = [UIColor whiteColor];
    self.searchField.tintColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0];
    self.searchField.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
    self.searchField.borderStyle = UITextBorderStyleNone;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search items…"
        attributes:@{NSForegroundColorAttributeName: XpGray(0.4)}];
    // a little left padding inside the field
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 1)];
    self.searchField.leftView = pad; self.searchField.leftViewMode = UITextFieldViewModeAlways;
    [self.searchField addTarget:self action:@selector(onSearchChanged) forControlEvents:UIControlEventEditingChanged];
    [self.searchTab addSubview:self.searchField];

    UIScrollView *seScroll = [[UIScrollView alloc] init];
    seScroll.translatesAutoresizingMaskIntoConstraints = NO;
    seScroll.alwaysBounceVertical = YES;
    seScroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.searchTab addSubview:seScroll];

    self.searchStack = [[UIStackView alloc] init];
    self.searchStack.axis = UILayoutConstraintAxisVertical;
    self.searchStack.spacing = 4;
    self.searchStack.translatesAutoresizingMaskIntoConstraints = NO;
    [seScroll addSubview:self.searchStack];

    self.searchEmpty = [[UILabel alloc] init];
    self.searchEmpty.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchEmpty.font = XpRsFont(15);
    self.searchEmpty.textColor = XpGray(0.55);
    self.searchEmpty.numberOfLines = 0;
    self.searchEmpty.textAlignment = NSTextAlignmentCenter;
    self.searchEmpty.text = @"Type an item name to see its guide price.";
    [self.searchTab addSubview:self.searchEmpty];

    CGFloat drawerW = MIN(440.0, self.view.bounds.size.width * 0.52);
    UILayoutGuide *dg = self.drawer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.drawer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.drawer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.drawer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.drawer.widthAnchor constraintEqualToConstant:drawerW],

        [headerBar.topAnchor constraintEqualToAnchor:dg.topAnchor],
        [headerBar.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [headerBar.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [headerBar.heightAnchor constraintEqualToConstant:34],
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerBar.leadingAnchor constant:10],
        [titleLabel.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],
        [close.trailingAnchor constraintEqualToAnchor:headerBar.trailingAnchor constant:-10],
        [close.centerYAnchor constraintEqualToAnchor:headerBar.centerYAnchor],

        [self.tabs.topAnchor constraintEqualToAnchor:headerBar.bottomAnchor constant:8],
        [self.tabs.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor constant:8],
        [self.tabs.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor constant:-8],

        [self.offersTab.topAnchor constraintEqualToAnchor:self.tabs.bottomAnchor constant:8],
        [self.offersTab.leadingAnchor constraintEqualToAnchor:self.drawer.leadingAnchor],
        [self.offersTab.trailingAnchor constraintEqualToAnchor:self.drawer.trailingAnchor],
        [self.offersTab.bottomAnchor constraintEqualToAnchor:dg.bottomAnchor],
        [self.searchTab.topAnchor constraintEqualToAnchor:self.offersTab.topAnchor],
        [self.searchTab.leadingAnchor constraintEqualToAnchor:self.offersTab.leadingAnchor],
        [self.searchTab.trailingAnchor constraintEqualToAnchor:self.offersTab.trailingAnchor],
        [self.searchTab.bottomAnchor constraintEqualToAnchor:self.offersTab.bottomAnchor],

        // offers scroll/stack
        [offScroll.topAnchor constraintEqualToAnchor:self.offersTab.topAnchor],
        [offScroll.leadingAnchor constraintEqualToAnchor:self.offersTab.leadingAnchor],
        [offScroll.trailingAnchor constraintEqualToAnchor:self.offersTab.trailingAnchor],
        [offScroll.bottomAnchor constraintEqualToAnchor:self.offersTab.bottomAnchor],
        [self.offersStack.topAnchor constraintEqualToAnchor:offScroll.topAnchor constant:6],
        [self.offersStack.leadingAnchor constraintEqualToAnchor:offScroll.leadingAnchor constant:8],
        [self.offersStack.trailingAnchor constraintEqualToAnchor:offScroll.trailingAnchor constant:-8],
        [self.offersStack.bottomAnchor constraintEqualToAnchor:offScroll.bottomAnchor constant:-6],
        [self.offersStack.widthAnchor constraintEqualToAnchor:offScroll.widthAnchor constant:-16],
        [self.offersEmpty.topAnchor constraintEqualToAnchor:self.offersTab.topAnchor constant:30],
        [self.offersEmpty.leadingAnchor constraintEqualToAnchor:self.offersTab.leadingAnchor constant:20],
        [self.offersEmpty.trailingAnchor constraintEqualToAnchor:self.offersTab.trailingAnchor constant:-20],

        // search field + scroll/stack
        [self.searchField.topAnchor constraintEqualToAnchor:self.searchTab.topAnchor],
        [self.searchField.leadingAnchor constraintEqualToAnchor:self.searchTab.leadingAnchor constant:8],
        [self.searchField.trailingAnchor constraintEqualToAnchor:self.searchTab.trailingAnchor constant:-8],
        [self.searchField.heightAnchor constraintEqualToConstant:34],
        [seScroll.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:6],
        [seScroll.leadingAnchor constraintEqualToAnchor:self.searchTab.leadingAnchor],
        [seScroll.trailingAnchor constraintEqualToAnchor:self.searchTab.trailingAnchor],
        [seScroll.bottomAnchor constraintEqualToAnchor:self.searchTab.bottomAnchor],
        [self.searchStack.topAnchor constraintEqualToAnchor:seScroll.topAnchor constant:2],
        [self.searchStack.leadingAnchor constraintEqualToAnchor:seScroll.leadingAnchor constant:8],
        [self.searchStack.trailingAnchor constraintEqualToAnchor:seScroll.trailingAnchor constant:-8],
        [self.searchStack.bottomAnchor constraintEqualToAnchor:seScroll.bottomAnchor constant:-6],
        [self.searchStack.widthAnchor constraintEqualToAnchor:seScroll.widthAnchor constant:-16],
        [self.searchEmpty.topAnchor constraintEqualToAnchor:seScroll.topAnchor constant:24],
        [self.searchEmpty.leadingAnchor constraintEqualToAnchor:self.searchTab.leadingAnchor constant:20],
        [self.searchEmpty.trailingAnchor constraintEqualToAnchor:self.searchTab.trailingAnchor constant:-20],
    ]];

    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)onTab {
    BOOL search = (self.tabs.selectedSegmentIndex == 1);
    self.offersTab.hidden = search;
    self.searchTab.hidden = !search;
    if (search) {
        [self.searchField becomeFirstResponder];
    } else {
        [self.searchField resignFirstResponder];
        [self refresh];   // don't wait up to 2s for the timer when returning to Offers
    }
}

- (void)onDone {
    [self stopTimers];
    [JVMLauncher geSetUiOpen:NO];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopTimers];
    [JVMLauncher geSetUiOpen:NO];
}

- (void)stopTimers {
    [self.timer invalidate]; self.timer = nil;
    [self.searchDebounce invalidate]; self.searchDebounce = nil;
}

// ---- Offers --------------------------------------------------------------------------------------

- (void)refresh {
    if (self.tabs.selectedSegmentIndex != 0) return;   // only rebuild offers while the Offers tab is showing
    NSString *json = [JVMLauncher geJson] ?: @"{}";
    if (self.lastJson && [json isEqualToString:self.lastJson]) return;
    self.lastJson = json;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) d = @{};
    NSArray *offers = [d[@"offers"] isKindOfClass:[NSArray class]] ? d[@"offers"] : @[];
    NSArray *history = [d[@"history"] isKindOfClass:[NSArray class]] ? d[@"history"] : @[];

    for (UIView *v in [self.offersStack.arrangedSubviews copy]) { [self.offersStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSDictionary *o in offers) {
        if (![o isKindOfClass:[NSDictionary class]]) continue;
        [self.offersStack addArrangedSubview:[self offerBox:o]];
    }
    if (history.count > 0) {
        [self.offersStack addArrangedSubview:[self sectionHeader:@"Recent history"]];
        // newest last in storage → show most recent first
        for (NSDictionary *h in [history reverseObjectEnumerator]) {
            if (![h isKindOfClass:[NSDictionary class]]) continue;
            [self.offersStack addArrangedSubview:[self historyRow:h]];
        }
    }
    self.offersEmpty.hidden = (offers.count > 0 || history.count > 0);
}

- (UILabel *)sectionHeader:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.font = XpRsFont(14);
    l.textColor = [UIColor colorWithRed:1.0 green:0.596 blue:0.122 alpha:1.0];
    l.text = text;
    return l;
}

- (UILabel *)geStat:(NSString *)text right:(BOOL)right {
    UILabel *l = [[UILabel alloc] init];
    l.font = XpRsFont(14);
    l.textColor = XpGray(0.62);
    l.text = text;
    l.textAlignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
    return l;
}

// Map a GrandExchangeOfferState name to a readable label + buy/sell tint.
- (NSString *)prettyState:(NSString *)state buying:(BOOL *)buying {
    NSString *s = state ?: @"";
    BOOL buy = [s hasPrefix:@"BUY"] || [s isEqualToString:@"BOUGHT"] || [s isEqualToString:@"CANCELLED_BUY"];
    if (buying) *buying = buy;
    NSDictionary *map = @{
        @"BUYING": @"Buying", @"BOUGHT": @"Bought",
        @"SELLING": @"Selling", @"SOLD": @"Sold",
        @"CANCELLED_BUY": @"Cancelled buy", @"CANCELLED_SELL": @"Cancelled sell",
    };
    return map[s] ?: s;
}

- (UIView *)offerBox:(NSDictionary *)o {
    BOOL buying = NO;
    NSString *state = [self prettyState:([o[@"state"] isKindOfClass:[NSString class]] ? o[@"state"] : @"") buying:&buying];
    NSString *name = [o[@"name"] isKindOfClass:[NSString class]] ? o[@"name"] : @"";
    long qty = [o[@"qty"] longLongValue], total = [o[@"total"] longLongValue], price = [o[@"price"] longLongValue];
    double progress = [o[@"progress"] doubleValue];

    UIStackView *box = [[UIStackView alloc] init];
    box.axis = UILayoutConstraintAxisVertical;
    box.spacing = 5;
    box.layoutMarginsRelativeArrangement = YES;
    box.layoutMargins = UIEdgeInsetsMake(7, 8, 7, 8);
    box.backgroundColor = [UIColor colorWithRed:43/255.0 green:43/255.0 blue:43/255.0 alpha:1.0];

    UIStackView *titleRow = [[UIStackView alloc] init];
    titleRow.axis = UILayoutConstraintAxisHorizontal; titleRow.spacing = 8;
    UILabel *nameL = [[UILabel alloc] init];
    nameL.font = XpRsFont(15); nameL.textColor = [UIColor whiteColor];
    nameL.text = name.length ? name : @"(item)";
    [nameL setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *stateL = [[UILabel alloc] init];
    stateL.font = XpRsFont(14);
    stateL.textColor = buying
        ? [UIColor colorWithRed:0.45 green:0.74 blue:1.0 alpha:1.0]    // buy = blue
        : [UIColor colorWithRed:0.31 green:0.78 blue:0.31 alpha:1.0];  // sell = green
    stateL.text = state;
    stateL.textAlignment = NSTextAlignmentRight;
    [stateL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [titleRow addArrangedSubview:nameL];
    [titleRow addArrangedSubview:stateL];

    UIStackView *statRow = [[UIStackView alloc] init];
    statRow.axis = UILayoutConstraintAxisHorizontal; statRow.distribution = UIStackViewDistributionFillEqually; statRow.spacing = 6;
    [statRow addArrangedSubview:[self geStat:[NSString stringWithFormat:@"Price: %@", XpFmt(price)] right:NO]];
    [statRow addArrangedSubview:[self geStat:[NSString stringWithFormat:@"%@ / %@", XpFmt(qty), XpFmt(total)] right:YES]];

    [box addArrangedSubview:titleRow];
    [box addArrangedSubview:statRow];
    [box addArrangedSubview:[self progressBar:progress]];
    return box;
}

- (UIView *)progressBar:(double)progress {
    if (progress < 0) progress = 0; if (progress > 1) progress = 1;
    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
    [bar.heightAnchor constraintEqualToConstant:8].active = YES;
    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = [UIColor colorWithRed:79/255.0 green:122/255.0 blue:35/255.0 alpha:1.0];
    [bar addSubview:fill];
    [NSLayoutConstraint activateConstraints:@[
        [fill.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [fill.widthAnchor constraintEqualToAnchor:bar.widthAnchor multiplier:progress],
    ]];
    return bar;
}

- (UIView *)historyRow:(NSDictionary *)h {
    BOOL buy = [h[@"buy"] boolValue];
    NSString *name = [h[@"name"] isKindOfClass:[NSString class]] ? h[@"name"] : @"";
    long qty = [h[@"qty"] longLongValue], price = [h[@"price"] longLongValue];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8;
    row.layoutMarginsRelativeArrangement = YES;
    row.layoutMargins = UIEdgeInsetsMake(3, 8, 3, 8);

    UILabel *nameL = [[UILabel alloc] init];
    nameL.font = XpRsFont(14);
    nameL.textColor = buy
        ? [UIColor colorWithRed:0.45 green:0.74 blue:1.0 alpha:1.0]
        : [UIColor colorWithRed:0.31 green:0.78 blue:0.31 alpha:1.0];
    nameL.text = [NSString stringWithFormat:@"%@ %ld× %@", buy ? @"Bought" : @"Sold", qty, name];
    [nameL setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *priceL = [[UILabel alloc] init];
    priceL.font = XpRsFont(14); priceL.textColor = XpGray(0.6);
    priceL.text = [NSString stringWithFormat:@"%@ ea", XpFmt(price)];
    priceL.textAlignment = NSTextAlignmentRight;
    [priceL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [row addArrangedSubview:nameL];
    [row addArrangedSubview:priceL];
    return row;
}

// ---- Search --------------------------------------------------------------------------------------

- (void)onSearchChanged {
    [self.searchDebounce invalidate];
    self.searchDebounce = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(runSearch) userInfo:nil repeats:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self.searchDebounce invalidate]; self.searchDebounce = nil;
    [self runSearch];
    return NO;
}

- (void)runSearch {
    self.searchDebounce = nil;
    NSString *q = self.searchField.text ?: @"";
    NSString *trimmed = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (UIView *v in [self.searchStack.arrangedSubviews copy]) { [self.searchStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (trimmed.length < 2) {
        self.searchEmpty.text = @"Type an item name to see its guide price.";
        self.searchEmpty.hidden = NO;
        return;
    }
    NSString *json = [JVMLauncher geSearch:trimmed] ?: @"{}";
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSArray *results = ([d isKindOfClass:[NSDictionary class]] && [d[@"results"] isKindOfClass:[NSArray class]]) ? d[@"results"] : @[];
    for (NSDictionary *r in results) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        [self.searchStack addArrangedSubview:[self searchRow:r]];
    }
    if (results.count == 0) {
        self.searchEmpty.text = @"No tradeable items match.";
        self.searchEmpty.hidden = NO;
    } else {
        self.searchEmpty.hidden = YES;
    }
}

- (UIView *)searchRow:(NSDictionary *)r {
    NSString *name = [r[@"name"] isKindOfClass:[NSString class]] ? r[@"name"] : @"";
    long price = [r[@"price"] longLongValue];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 8;
    row.layoutMarginsRelativeArrangement = YES;
    row.layoutMargins = UIEdgeInsetsMake(6, 8, 6, 8);
    row.backgroundColor = [UIColor colorWithRed:43/255.0 green:43/255.0 blue:43/255.0 alpha:1.0];

    UILabel *nameL = [[UILabel alloc] init];
    nameL.font = XpRsFont(15); nameL.textColor = [UIColor whiteColor];
    nameL.text = name;
    [nameL setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *priceL = [[UILabel alloc] init];
    priceL.font = XpRsFont(14);
    priceL.textColor = [UIColor colorWithRed:1.0 green:0.83 blue:0.0 alpha:1.0]; // coin yellow
    priceL.text = [NSString stringWithFormat:@"%@ gp", XpFmt(price)];
    priceL.textAlignment = NSTextAlignmentRight;
    [priceL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [row addArrangedSubview:nameL];
    [row addArrangedSubview:priceL];
    return row;
}

@end

@interface MUIPluginGrid () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>
@end

@implementation MUIPluginGrid {
    NSArray<NSDictionary *> *_all;       // every panel ({index,tooltip,name,iconPng,pinned})
    NSMutableArray<NSDictionary *> *_shown; // filtered + favourites-first
    NSString *_filter;
    void (^_onPick)(NSString *);
    UICollectionView *_grid;
    UISearchBar *_search;
}

- (instancetype)initWithPanels:(NSArray<NSDictionary *> *)panels onPick:(void (^)(NSString *))onPick {
    if ((self = [super init])) {
        _all = [panels copy] ?: @[];
        _onPick = [onPick copy];
        _filter = @"";
        _shown = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Plugins";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [self.view addSubview:title];

    _search = [[UISearchBar alloc] init];
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _search.delegate = self;
    _search.placeholder = @"Search plugins";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.barStyle = UIBarStyleBlack;
    _search.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [self.view addSubview:_search];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 14;
    layout.sectionInset = UIEdgeInsetsMake(6, 16, 24, 16);
    _grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _grid.backgroundColor = [UIColor clearColor];
    _grid.dataSource = self;
    _grid.delegate = self;
    _grid.alwaysBounceVertical = YES;
    _grid.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_grid registerClass:[MUIGridTile class] forCellWithReuseIdentifier:@"tile"];
    [self.view addSubview:_grid];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                     action:@selector(onTileLongPress:)];
    [_grid addGestureRecognizer:lp];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_search.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_grid.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:2],
        [_grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_grid.bottomAnchor constraintEqualToAnchor:sg.bottomAnchor],
    ]];
    [self applyFilter];
}

- (void)applyFilter {
    NSArray *base = _all;
    if (_filter.length) {
        NSMutableArray *f = [NSMutableArray array];
        for (NSDictionary *p in _all) {
            NSString *n = [[p[@"tooltip"] description] lowercaseString] ?: @"";
            if ([n containsString:_filter]) [f addObject:p];
        }
        base = f;
    }
    [_shown setArray:[base sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL pa = [a[@"pinned"] boolValue], pb = [b[@"pinned"] boolValue];
        if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;   // favourites float to the top
        return [[a[@"tooltip"] description] caseInsensitiveCompare:([b[@"tooltip"] description] ?: @"")];
    }]];
    [_grid reloadData];
}

- (nullable UIImage *)decodeIcon:(id)base64 {
    if (![base64 isKindOfClass:[NSString class]] || [(NSString *)base64 length] == 0) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    return d ? [UIImage imageWithData:d] : nil;
}

#pragma mark search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _filter = [searchText lowercaseString];
    [self applyFilter];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark grid

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_shown.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    MUIGridTile *cell = [cv dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:ip];
    NSDictionary *p = _shown[(NSUInteger)ip.item];
    cell.name.text = [p[@"tooltip"] description];
    UIImage *icon = [self decodeIcon:p[@"iconPng"]];
    cell.icon.image = icon;
    cell.icon.hidden = (icon == nil);
    cell.star.hidden = ![p[@"pinned"] boolValue];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat avail = cv.bounds.size.width - 32;   // section insets
    NSInteger cols = MAX(2, (NSInteger)floor(avail / 110.0));   // ~100pt tiles, more columns in landscape
    CGFloat w = floor((avail - (cols - 1) * 10.0) / cols);
    return CGSizeMake(w, 84);
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *p = _shown[(NSUInteger)ip.item];
    NSString *tooltip = [p[@"tooltip"] description] ?: @"";
    void (^pick)(NSString *) = _onPick;
    [self dismissViewControllerAnimated:YES completion:^{ if (pick) pick(tooltip); }];
}

// Long-press a tile = pin/unpin (favourite). Reuses the shared pinnedPlugins CSV via mobileSetPinned.
- (void)onTileLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [_grid indexPathForItemAtPoint:[g locationInView:_grid]];
    if (!ip || ip.item < 0 || ip.item >= (NSInteger)_shown.count) return;
    NSDictionary *p = _shown[(NSUInteger)ip.item];
    NSString *name = [p[@"tooltip"] description] ?: @"";
    BOOL pinned = [p[@"pinned"] boolValue];
    [JVMLauncher mobileSetPinned:name pinned:!pinned];
    // Reflect immediately: flip the pinned flag in the local snapshot and re-sort (the dock reconciles on its poll).
    NSMutableArray *updated = [NSMutableArray array];
    for (NSDictionary *q in _all) {
        if ([[q[@"tooltip"] description] isEqualToString:name]) {
            NSMutableDictionary *m = [q mutableCopy];
            m[@"pinned"] = @(!pinned);
            [updated addObject:m];
        } else {
            [updated addObject:q];
        }
    }
    _all = updated;
    [self applyFilter];
}

@end
