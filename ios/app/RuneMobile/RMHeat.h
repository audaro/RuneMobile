#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the game is held to for now. 0 means no limit.
typedef struct {
    int scalePercent; // 117HD's resolution scale, the one renderer that has one to lower
    int fps;          // the frame rate, on every renderer
} RMHeatLimit;

/// Turns the phone's thermal state and Low Power Mode into limits. A limit comes on at the first reading that calls
/// for it, and lifts one step per minute of calm, so a state that bounces doesn't bounce the frame rate with it.
/// Foundation only, so ios/dev-tools/diagnostics/test-heat.sh can run it on the Mac.
@interface RMHeatPolicy : NSObject

/// `state` is an NSProcessInfoThermalState; `now` is any clock in seconds that only goes forward.
- (RMHeatLimit)limitForThermalState:(NSInteger)state lowPower:(BOOL)lowPower at:(NSTimeInterval)now;

@end

/// One look at the phone and the game.
typedef struct {
    NSInteger thermalState; // NSProcessInfoThermalState
    BOOL lowPower;
    BOOL background;
    int frames;         // frames drawn since the last reading
    int batteryState;   // a UIDeviceBatteryState: 0 unknown, 1 on battery, 2 charging, 3 full
    float batteryLevel; // 0 to 1, or negative when the phone doesn't say
    int fpsLimit;       // the limit in force, 0 for none
    int scalePercent;   // 117HD's scale in force, 0 on the other renderers
    int baselineScale;  // what the player set it to, 0 on the other renderers
} RMHeatReading;

/// The session's readings, for the "Heat" section of Share logs: what the phone is doing now, and one line a minute.
/// Written from the main thread, read from wherever the report is built. Foundation only, as above.
@interface RMHeatLog : NSObject

@property (class, nonatomic, readonly) RMHeatLog *shared;

- (void)addReading:(RMHeatReading)reading at:(NSTimeInterval)now;
- (NSString *)report;

@end

NS_ASSUME_NONNULL_END
