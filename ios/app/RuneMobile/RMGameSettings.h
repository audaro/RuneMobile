#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The four haptic triggers, each with its own switch.
typedef NS_ENUM(NSInteger, RMHaptic) {
    RMHapticOp = 0,    // tapping something you can interact with, or picking a menu option
    RMHapticDrag,      // picking up an item to move it
    RMHapticMenuOpen,  // the long-press menu appearing
    RMHapticMenuHover, // sliding over the menu's options
};

/// Posted on the main queue whenever a setting below changes.
extern NSNotificationName const RMGameSettingsDidChangeNotification;

/// The phone-side game settings behind Settings > Game settings. Kept in NSUserDefaults and read live, so a
/// change applies without a restart. Auto-login is the exception: it decides how the game starts, so it applies
/// at the next launch.
@interface RMGameSettings : NSObject
+ (BOOL)hapticOn:(RMHaptic)h; // default YES
+ (void)setHaptic:(RMHaptic)h on:(BOOL)on;
/// 0 light, 1 medium (default), 2 heavy.
+ (NSInteger)hapticStrength;
+ (void)setHapticStrength:(NSInteger)s;
/// How long a finger has to stay put before the long-press menu opens, in ms (200-1000, default 400).
+ (NSInteger)longPressMs;
+ (void)setLongPressMs:(NSInteger)ms;
/// Camera drag sensitivity, 0.1-4.0 (default 2.0, the drag speed the app has always used).
+ (double)cameraSensitivity;
+ (void)setCameraSensitivity:(double)v;
/// The camera drag multiplier: 1 at the default sensitivity.
+ (double)cameraGain;
/// How long a finger has to rest on an item before dragging it moves the item, in ms: two thirds of the
/// long-press time, at most 150. A quicker swipe never picks the item up.
+ (NSInteger)dragHoldMs;
/// Whether the game runs in portrait (default NO, landscape). Under Auto it is the choice Auto returns to.
+ (BOOL)portrait;
+ (void)setPortrait:(BOOL)on;
/// Auto: the game turns with the phone (default NO).
+ (BOOL)autoRotate;
+ (void)setAutoRotate:(BOOL)on;
/// Auto-login: press Play Now when the game starts (default NO, the player logs in).
+ (BOOL)autoLogin;
+ (void)setAutoLogin:(BOOL)on;
/// The orientations the window may take under the setting.
+ (UIInterfaceOrientationMask)orientationMask;
/// Turn `window` to the setting now. The game resizes its canvas when the window turns.
+ (void)applyOrientationToWindow:(UIWindow *)window;
/// Under Auto, while the app is in front, read the motion sensor and turn the app delegate's window with the phone,
/// Portrait Orientation Lock or not. The app delegate calls it once at launch; it then follows the setting and the
/// app's coming and going by itself.
+ (void)followPhone;
/// Where the screen lines go (the shell log). Set by the view controller.
@property (class, nonatomic, copy, nullable) void (^screenLog)(NSString *line);
@end

/// The native Game settings screen, pushed from Settings.
@interface RMGameSettingsViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
