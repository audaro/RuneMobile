#import "RMGameSettings.h"
#import "JVMLauncher.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>

NSNotificationName const RMGameSettingsDidChangeNotification = @"RMGameSettingsDidChangeNotification";

static NSString *const kHapticKeys[4] = {@"haptic.op", @"haptic.drag", @"haptic.menuOpen", @"haptic.menuHover"};
static NSString *const kHapticStrengthKey = @"haptic.strength";
static NSString *const kLongPressKey = @"touch.longPressMs";
static NSString *const kCameraSensitivityKey = @"camera.sensitivity";
static NSString *const kPortraitKey = @"screen.portrait";
static NSString *const kAutoRotateKey = @"screen.auto";
static NSString *const kAutoLoginKey = @"login.auto";
static NSString *const kGameSoundKey = @"audio.game";
static NSString *const kHeatLowerResolutionKey = @"heat.lowerResolution";
static NSString *const kHeatNoticeOffKey = @"heat.noticeOff";

static const NSInteger kLongPressMinMs = 200, kLongPressMaxMs = 1000, kLongPressStepMs = 50, kLongPressDefaultMs = 400;
static const NSInteger kDragHoldMaxMs = 150;
static const double kCameraSensMin = 0.1, kCameraSensMax = 4.0, kCameraSensDefault = 2.0;

// Auto follows the motion sensor, not UIDevice orientation: Portrait Orientation Lock freezes that at upright, so
// under the lock Auto turned the game upright and kept it there. Auto holds one orientation at a time (sAutoMask)
// and moves it once the phone has stood a new way for kTurnDwell, so the lock can't pull it back; Landscape and
// Portrait are the in-game lock. 0 = no reading since Auto came on.
static UIInterfaceOrientationMask sAutoMask = 0;
static CMAcceleration sGravity; // the sensor, smoothed (kGravitySmoothing per reading at kMotionHz)
static BOOL sGravityValid = NO;
static UIInterfaceOrientationMask sCandidate = 0; // a new way the phone stands, waiting out kTurnDwell
static CFTimeInterval sCandidateSince = 0;
static BOOL sAppInFront = NO;
static void (^sScreenLog)(NSString *) = nil;
static const double kMotionHz = 10.0, kGravitySmoothing = 0.3, kTurnDwell = 0.4;

@implementation RMGameSettings

+ (NSUserDefaults *)defaults {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kHapticKeys[RMHapticOp] : @YES,
            kHapticKeys[RMHapticDrag] : @YES,
            kHapticKeys[RMHapticMenuOpen] : @YES,
            kHapticKeys[RMHapticMenuHover] : @YES,
            kHapticStrengthKey : @1,
            kLongPressKey : @(kLongPressDefaultMs),
            kCameraSensitivityKey : @(kCameraSensDefault),
            kPortraitKey : @NO,
            kAutoRotateKey : @NO,
            kAutoLoginKey : @NO,
            kGameSoundKey : @YES,
            kHeatLowerResolutionKey : @NO,
            kHeatNoticeOffKey : @NO,
        }];
    });
    return [NSUserDefaults standardUserDefaults];
}

+ (BOOL)gameSound {
    return [[self defaults] boolForKey:kGameSoundKey];
}

+ (void)setGameSound:(BOOL)on {
    [[self defaults] setBool:on forKey:kGameSoundKey];
    [JVMLauncher setGameAudioMuted:!on];
}

+ (BOOL)autoLogin {
    return [[self defaults] boolForKey:kAutoLoginKey];
}

+ (void)setAutoLogin:(BOOL)on {
    [[self defaults] setBool:on forKey:kAutoLoginKey];
    [self changed];
}

+ (BOOL)heatLowerResolution {
    return [[self defaults] boolForKey:kHeatLowerResolutionKey];
}

+ (void)setHeatLowerResolution:(BOOL)on {
    [[self defaults] setBool:on forKey:kHeatLowerResolutionKey];
    [self changed];
}

+ (BOOL)heatNoticeOff {
    return [[self defaults] boolForKey:kHeatNoticeOffKey];
}

+ (void)setHeatNoticeOff:(BOOL)off {
    [[self defaults] setBool:off forKey:kHeatNoticeOffKey];
}

+ (void)changed {
    [[NSNotificationCenter defaultCenter] postNotificationName:RMGameSettingsDidChangeNotification object:nil];
}

+ (BOOL)hapticOn:(RMHaptic)h {
    if (h < RMHapticOp || h > RMHapticMenuHover)
        return NO;
    return [[self defaults] boolForKey:kHapticKeys[h]];
}

+ (void)setHaptic:(RMHaptic)h on:(BOOL)on {
    if (h < RMHapticOp || h > RMHapticMenuHover)
        return;
    [[self defaults] setBool:on forKey:kHapticKeys[h]];
    [self changed];
}

+ (NSInteger)hapticStrength {
    return MIN(MAX([[self defaults] integerForKey:kHapticStrengthKey], 0), 2);
}

+ (void)setHapticStrength:(NSInteger)s {
    [[self defaults] setInteger:MIN(MAX(s, 0), 2) forKey:kHapticStrengthKey];
    [self changed];
}

+ (NSInteger)longPressMs {
    return MIN(MAX([[self defaults] integerForKey:kLongPressKey], kLongPressMinMs), kLongPressMaxMs);
}

+ (void)setLongPressMs:(NSInteger)ms {
    [[self defaults] setInteger:MIN(MAX(ms, kLongPressMinMs), kLongPressMaxMs) forKey:kLongPressKey];
    [self changed];
}

+ (double)cameraSensitivity {
    return MIN(MAX([[self defaults] doubleForKey:kCameraSensitivityKey], kCameraSensMin), kCameraSensMax);
}

+ (void)setCameraSensitivity:(double)v {
    [[self defaults] setDouble:MIN(MAX(v, kCameraSensMin), kCameraSensMax) forKey:kCameraSensitivityKey];
    [self changed];
}

+ (double)cameraGain {
    return [self cameraSensitivity] / kCameraSensDefault;
}

+ (NSInteger)dragHoldMs {
    return MIN([self longPressMs] * 2 / 3, kDragHoldMaxMs);
}

+ (BOOL)portrait {
    return [[self defaults] boolForKey:kPortraitKey];
}

+ (void)setPortrait:(BOOL)on {
    [[self defaults] setBool:on forKey:kPortraitKey];
    [self changed];
}

+ (BOOL)autoRotate {
    return [[self defaults] boolForKey:kAutoRotateKey];
}

+ (void)setAutoRotate:(BOOL)on {
    [[self defaults] setBool:on forKey:kAutoRotateKey];
    [self changed];
}

+ (UIInterfaceOrientationMask)orientationMask {
    if ([self autoRotate]) {
        if (sAutoMask)
            return sAutoMask;
        // No sensor (the simulator): the system turns it, within the lock.
        if (![self motion])
            return UIInterfaceOrientationMaskAllButUpsideDown;
        // Before the first reading: as the window stands, or the launch screen's landscape.
        UIInterfaceOrientation o = [UIApplication sharedApplication].delegate.window.windowScene.interfaceOrientation;
        if (o == UIInterfaceOrientationPortrait || o == UIInterfaceOrientationLandscapeLeft ||
            o == UIInterfaceOrientationLandscapeRight)
            return (UIInterfaceOrientationMask)(1 << o);
        return UIInterfaceOrientationMaskLandscape;
    }
    return [self portrait] ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape;
}

+ (void)applyOrientationToWindow:(UIWindow *)window {
    [self followPhone];
    [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowScene *scene = window.windowScene;
    if (!scene)
        return;
    UIInterfaceOrientationMask mask = [self orientationMask];
    // With no sensor, Auto allows either, so the window would stay as it stands until the phone next moves: turn it
    // to the way UIDevice says the phone is held now. Flat or unknown leaves it be. A landscape-left phone is a
    // landscape-right interface.
    if ([self autoRotate] && ![self motion]) {
        switch ([UIDevice currentDevice].orientation) {
            case UIDeviceOrientationPortrait:
                mask = UIInterfaceOrientationMaskPortrait;
                break;
            case UIDeviceOrientationLandscapeLeft:
                mask = UIInterfaceOrientationMaskLandscapeRight;
                break;
            case UIDeviceOrientationLandscapeRight:
                mask = UIInterfaceOrientationMaskLandscapeLeft;
                break;
            default:
                break;
        }
    }
    UIWindowSceneGeometryPreferencesIOS *prefs =
        [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
    [scene requestGeometryUpdateWithPreferences:prefs
                                   errorHandler:^(NSError *error) {
                                       NSLog(@"[screen] orientation update refused: %@", error);
                                       if (sScreenLog)
                                           sScreenLog([NSString stringWithFormat:@"[screen] orientation update refused: %@",
                                                                                 error.localizedDescription]);
                                   }];
}

+ (void (^)(NSString *))screenLog {
    return sScreenLog;
}

+ (void)setScreenLog:(void (^)(NSString *))log {
    sScreenLog = [log copy];
}

// The accelerometer, or nil where there is none (the simulator).
+ (CMMotionManager *)motion {
    static CMMotionManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [[CMMotionManager alloc] init];
        m.accelerometerUpdateInterval = 1.0 / kMotionHz;
    });
    return m.accelerometerAvailable ? m : nil;
}

+ (void)followPhone {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Read only while the app is in front: away (or under Control Centre) the window can't turn anyway. The state
        // is kept here because applicationState can still read active while the app resigns.
        sAppInFront = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(appCameToFront) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(appLeftFront) name:UIApplicationWillResignActiveNotification object:nil];
    });
    CMMotionManager *m = [self motion];
    if (!m)
        return;
    BOOL want = [self autoRotate] && sAppInFront;
    if (want == m.accelerometerActive)
        return;
    if (!want) {
        [m stopAccelerometerUpdates];
        sGravityValid = NO;
        sCandidate = 0;
        // Leaving Auto: the next time it comes on it starts from where the window stands, not from here.
        if (![self autoRotate])
            sAutoMask = 0;
        return;
    }
    [m startAccelerometerUpdatesToQueue:[NSOperationQueue mainQueue]
                            withHandler:^(CMAccelerometerData *data, NSError *error) {
                                if (data)
                                    [self phoneMoved:data.acceleration];
                            }];
}

+ (void)appCameToFront {
    sAppInFront = YES;
    [self followPhone];
}

+ (void)appLeftFront {
    sAppInFront = NO;
    [self followPhone];
}

// The interface orientation the phone stands in, from gravity in its own axes (upright portrait reads y = -1), or 0
// when it lies flat or upside down. Within 60 degrees of `current` it stays `current`, so a phone held at 45 degrees
// doesn't flip back and forth. A phone turned with its top to the left is a landscape-right interface.
static UIInterfaceOrientationMask maskForGravity(CMAcceleration g, UIInterfaceOrientationMask current) {
    if (hypot(g.x, g.y) < 0.45)
        return 0;
    double deg = atan2(g.x, -g.y) * 180.0 / M_PI; // 0 upright, -90 top to the left, +90 top to the right
    if (fabs(deg) > 135.0)
        return 0;
    double home = current == UIInterfaceOrientationMaskPortrait         ? 0.0
                  : current == UIInterfaceOrientationMaskLandscapeRight ? -90.0
                  : current == UIInterfaceOrientationMaskLandscapeLeft  ? 90.0
                                                                        : NAN;
    if (!isnan(home) && fabs(deg - home) < 60.0)
        return current;
    return deg < -45.0  ? UIInterfaceOrientationMaskLandscapeRight
           : deg > 45.0 ? UIInterfaceOrientationMaskLandscapeLeft
                        : UIInterfaceOrientationMaskPortrait;
}

+ (void)phoneMoved:(CMAcceleration)a {
    // A reading queued before the sensor stopped (Auto turned off, or the app left the front) is stale.
    if (![self autoRotate] || !sAppInFront)
        return;
    if (!sGravityValid) {
        sGravity = a;
        sGravityValid = YES;
    } else {
        sGravity.x += kGravitySmoothing * (a.x - sGravity.x);
        sGravity.y += kGravitySmoothing * (a.y - sGravity.y);
        sGravity.z += kGravitySmoothing * (a.z - sGravity.z);
    }
    UIInterfaceOrientationMask held = sAutoMask ?: [self orientationMask];
    UIInterfaceOrientationMask want = maskForGravity(sGravity, held);
    if (!want || want == held) {
        sCandidate = 0;
        // The first reading agrees with the window: hold it there from now on.
        if (want && !sAutoMask)
            sAutoMask = want;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (want != sCandidate) {
        sCandidate = want;
        sCandidateSince = now;
    }
    if (now - sCandidateSince < kTurnDwell)
        return;
    sCandidate = 0;
    sAutoMask = want;
    if (sScreenLog)
        sScreenLog([NSString stringWithFormat:@"[screen] phone turned -> %@",
                                              want == UIInterfaceOrientationMaskPortrait        ? @"portrait"
                                              : want == UIInterfaceOrientationMaskLandscapeLeft ? @"landscape-left"
                                                                                                : @"landscape-right"]);
    [self applyOrientationToWindow:[UIApplication sharedApplication].delegate.window];
}

@end

#pragma mark - Screen

// Sections, in order. GAME is listed only when the game is running (it reads two RuneLite plugins).
typedef NS_ENUM(NSInteger, RMGsSection) { RMGsScreen = 0,
                                          RMGsTouch,
                                          RMGsGame,
                                          RMGsHeat,
                                          RMGsSound,
                                          RMGsLogin,
                                          RMGsHaptics };

static NSString *const kHapticTitles[4] = {@"Actions", @"Drag start", @"Menu open", @"Menu rows"};
static NSString *const kHapticDetails[4] = {
    @"Tapping something you can interact with",
    @"Picking up an item to move it",
    @"The long-press menu appearing",
    @"Sliding over the menu's options",
};

// Frame-rate cap choices; 0 is no cap.
static const int kFpsCapChoices[] = {0, 20, 30, 40, 50, 60};

// Slider tags, so one value-changed handler can tell them apart.
enum { kTagLongPress = 1,
       kTagCamera,
       kTagIdle };

@interface RMGameSettingsViewController ()
@property (nonatomic, assign) BOOL gameLoaded; // the game answered with its settings
@property (nonatomic, assign) int fpsCap;      // 0 = no cap
@property (nonatomic, assign) int idleMinutes;
@property (nonatomic, copy) NSArray<NSNumber *> *fpsChoices;
@end

@implementation RMGameSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Game settings";
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self loadGameSettings];
}

- (void)loadGameSettings {
    NSString *json = [JVMLauncher gameSettings];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    self.gameLoaded = [d isKindOfClass:[NSDictionary class]];
    self.fpsCap = self.gameLoaded ? [d[@"fpsCap"] intValue] : 0;
    self.idleMinutes = self.gameLoaded ? [d[@"idleLogoutMinutes"] intValue] : 5;
    NSMutableArray<NSNumber *> *choices = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kFpsCapChoices) / sizeof(kFpsCapChoices[0]); i++)
        [choices addObject:@(kFpsCapChoices[i])];
    if (![choices containsObject:@(self.fpsCap)]) {
        [choices addObject:@(self.fpsCap)]; // a cap set from the plugin's own screen
        [choices sortUsingSelector:@selector(compare:)];
    }
    self.fpsChoices = choices;
}

- (UIColor *)accent {
    return [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:1.0];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return RMGsHaptics + 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case RMGsScreen:
            return 1; // orientation
        case RMGsTouch:
            return 2; // long-press time, camera sensitivity
        case RMGsGame:
            return self.gameLoaded ? 2 : 0; // idle logout, frame-rate cap
        case RMGsHeat:
            return 1; // lower 117HD's resolution when hot
        case RMGsSound:
            return 1; // Game sound
        case RMGsLogin:
            return 1; // Auto-login
        case RMGsHaptics:
            return 5; // four triggers + strength
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case RMGsScreen:
            return @"SCREEN";
        case RMGsTouch:
            return @"TOUCH";
        case RMGsGame:
            return @"GAME";
        case RMGsHeat:
            return @"117HD";
        case RMGsSound:
            return @"SOUND";
        case RMGsLogin:
            return @"LOGIN";
        case RMGsHaptics:
            return @"HAPTICS";
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == RMGsScreen && [RMGameSettings autoRotate])
        return @"Turns with the phone, even with Portrait Orientation Lock on. Pick Landscape or Portrait to hold it.";
    if (s == RMGsGame && !self.gameLoaded)
        return @"Available once the game is running.";
    return nil;
}

- (UITableViewCell *)baseCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

// A title, its current value on the right, and a full-width slider under them.
- (UITableViewCell *)sliderCellTitle:(NSString *)title
                               value:(NSString *)valueText
                                 min:(float)lo
                                 max:(float)hi
                             current:(float)cur
                                 tag:(NSInteger)tag {
    UITableViewCell *cell = [self baseCell];
    UILabel *name = [UILabel new];
    name.text = title;
    name.textColor = [UIColor whiteColor];
    UILabel *value = [UILabel new];
    value.text = valueText;
    value.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    value.tag = 100 + tag;
    [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[ name, value ]];
    UISlider *slider = [UISlider new];
    slider.minimumValue = lo;
    slider.maximumValue = hi;
    slider.value = cur;
    slider.tag = tag;
    slider.minimumTrackTintColor = [self accent];
    slider.accessibilityLabel = title;
    [slider addTarget:self action:@selector(onSlide:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self
                  action:@selector(onSlideDone:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self stackInCell:cell views:@[ top, slider ]];
    return cell;
}

// Lay views out top to bottom across the cell's full width.
- (void)stackInCell:(UITableViewCell *)cell views:(NSArray<UIView *> *)views {
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:views];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:col];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [col.topAnchor constraintEqualToAnchor:m.topAnchor],
        [col.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == RMGsTouch && ip.row == 0) {
        NSInteger ms = [RMGameSettings longPressMs];
        return [self sliderCellTitle:@"Long-press time"
                               value:[NSString stringWithFormat:@"%ld ms", (long)ms]
                                 min:kLongPressMinMs
                                 max:kLongPressMaxMs
                             current:ms
                                 tag:kTagLongPress];
    }
    if (ip.section == RMGsTouch) {
        double v = [RMGameSettings cameraSensitivity];
        return [self sliderCellTitle:@"Camera sensitivity"
                               value:[NSString stringWithFormat:@"%.1f", v]
                                 min:kCameraSensMin
                                 max:kCameraSensMax
                             current:v
                                 tag:kTagCamera];
    }
    if (ip.section == RMGsGame && ip.row == 0) {
        return [self sliderCellTitle:@"Idle logout"
                               value:[NSString stringWithFormat:@"%d min", self.idleMinutes]
                                 min:5
                                 max:30
                             current:self.idleMinutes
                                 tag:kTagIdle];
    }
    UITableViewCell *cell = [self baseCell];
    if (ip.section == RMGsScreen) {
        cell.textLabel.text = @"Orientation";
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"Landscape", @"Portrait", @"Auto" ]];
        NSInteger fixed = [RMGameSettings portrait] ? 1 : 0;
        seg.selectedSegmentIndex = [RMGameSettings autoRotate] ? 2 : fixed;
        seg.selectedSegmentTintColor = [self accent];
        seg.accessibilityLabel = @"Orientation";
        [seg addTarget:self action:@selector(onOrientation:) forControlEvents:UIControlEventValueChanged];
        [seg sizeToFit];
        cell.accessoryView = seg;
    } else if (ip.section == RMGsGame) {
        // Too many choices to sit beside the title, so they get a line of their own.
        UILabel *name = [UILabel new];
        name.text = @"Frame-rate cap";
        name.textColor = [UIColor whiteColor];
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (NSNumber *n in self.fpsChoices)
            [labels addObject:n.intValue == 0 ? @"Off" : n.stringValue];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:labels];
        seg.selectedSegmentIndex = (NSInteger)[self.fpsChoices indexOfObject:@(self.fpsCap)];
        seg.selectedSegmentTintColor = [self accent];
        seg.accessibilityLabel = @"Frame-rate cap";
        [seg addTarget:self action:@selector(onFpsCap:) forControlEvents:UIControlEventValueChanged];
        [self stackInCell:cell views:@[ name, seg ]];
    } else if (ip.section == RMGsHeat) {
        cell.textLabel.text = @"Lower resolution when hot";
        cell.detailTextLabel.text = @"While your phone is hot, 117HD draws at no more than 65% (50% when it's very hot), then "
                                    @"goes back to your setting when it cools. Off, only the frame rate is limited.";
        cell.detailTextLabel.numberOfLines = 0;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [RMGameSettings heatLowerResolution];
        sw.onTintColor = [self accent];
        sw.accessibilityLabel = @"Lower 117HD resolution when hot";
        [sw addTarget:self action:@selector(onHeatLowerResolution:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.section == RMGsSound) {
        cell.textLabel.text = @"Game sound";
        cell.detailTextLabel.text = @"Music, sound effects and area sounds. Their volumes are in the game's own settings.";
        cell.detailTextLabel.numberOfLines = 0;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [RMGameSettings gameSound];
        sw.onTintColor = [self accent];
        sw.accessibilityLabel = @"Game sound";
        [sw addTarget:self action:@selector(onGameSound:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.section == RMGsLogin) {
        cell.textLabel.text = @"Auto-login";
        cell.detailTextLabel.text =
            @"Presses Play Now when the game starts, on your Default World plugin's world. Applies at the next launch.";
        cell.detailTextLabel.numberOfLines = 0;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [RMGameSettings autoLogin];
        sw.onTintColor = [self accent];
        sw.accessibilityLabel = @"Auto-login";
        [sw addTarget:self action:@selector(onAutoLogin:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (ip.row < 4) {
        cell.textLabel.text = kHapticTitles[ip.row];
        cell.detailTextLabel.text = kHapticDetails[ip.row];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [RMGameSettings hapticOn:(RMHaptic)ip.row];
        sw.onTintColor = [self accent];
        sw.tag = ip.row;
        [sw addTarget:self action:@selector(onHapticSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        cell.textLabel.text = @"Strength";
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"Light", @"Medium", @"Heavy" ]];
        seg.selectedSegmentIndex = [RMGameSettings hapticStrength];
        seg.selectedSegmentTintColor = [self accent];
        [seg addTarget:self action:@selector(onStrength:) forControlEvents:UIControlEventValueChanged];
        [seg sizeToFit];
        cell.accessoryView = seg;
    }
    return cell;
}

// Snap to the setting's step and show it; native settings save as they move.
- (void)onSlide:(UISlider *)s {
    UILabel *value = [s.superview.superview viewWithTag:100 + s.tag];
    if (s.tag == kTagLongPress) {
        NSInteger ms = lround(s.value / kLongPressStepMs) * kLongPressStepMs;
        s.value = ms;
        value.text = [NSString stringWithFormat:@"%ld ms", (long)ms];
        [RMGameSettings setLongPressMs:ms];
    } else if (s.tag == kTagCamera) {
        double v = round(s.value * 10.0) / 10.0;
        s.value = (float)v;
        value.text = [NSString stringWithFormat:@"%.1f", v];
        [RMGameSettings setCameraSensitivity:v];
    } else if (s.tag == kTagIdle) {
        self.idleMinutes = (int)lround(s.value);
        s.value = self.idleMinutes;
        value.text = [NSString stringWithFormat:@"%d min", self.idleMinutes];
    }
}

// The idle logout goes to the game once, when the finger lifts.
- (void)onSlideDone:(UISlider *)s {
    if (s.tag == kTagIdle)
        [JVMLauncher setIdleLogoutMinutes:self.idleMinutes];
}

- (void)onFpsCap:(UISegmentedControl *)seg {
    if (seg.selectedSegmentIndex < 0 || seg.selectedSegmentIndex >= (NSInteger)self.fpsChoices.count)
        return;
    self.fpsCap = self.fpsChoices[seg.selectedSegmentIndex].intValue;
    [JVMLauncher setFpsCap:self.fpsCap];
}

- (void)onOrientation:(UISegmentedControl *)seg {
    // Auto keeps the last fixed choice underneath, so switching back to it lands where it was.
    if (seg.selectedSegmentIndex == 2) {
        [RMGameSettings setAutoRotate:YES];
    } else {
        [RMGameSettings setPortrait:seg.selectedSegmentIndex == 1];
        [RMGameSettings setAutoRotate:NO];
    }
    // The window turns now, and the game resizes its canvas to suit it.
    [RMGameSettings applyOrientationToWindow:self.view.window];
    // The footer explains Auto.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:RMGsScreen]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)onGameSound:(UISwitch *)sw {
    [RMGameSettings setGameSound:sw.on];
}

- (void)onHeatLowerResolution:(UISwitch *)sw {
    [RMGameSettings setHeatLowerResolution:sw.on];
}

- (void)onAutoLogin:(UISwitch *)sw {
    [RMGameSettings setAutoLogin:sw.on];
}

- (void)onHapticSwitch:(UISwitch *)sw {
    [RMGameSettings setHaptic:(RMHaptic)sw.tag on:sw.on];
}

- (void)onStrength:(UISegmentedControl *)seg {
    [RMGameSettings setHapticStrength:seg.selectedSegmentIndex];
    // A sample buzz at the new strength.
    static const UIImpactFeedbackStyle styles[3] = {UIImpactFeedbackStyleLight, UIImpactFeedbackStyleMedium,
                                                    UIImpactFeedbackStyleHeavy};
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:styles[[RMGameSettings hapticStrength]]] impactOccurred];
}

@end
