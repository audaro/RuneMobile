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

/// The game's config and the throttle marker, as RMHeatScaleKeeper sees them. Apart so its test runs on the Mac.
@protocol RMHeatScaleStore <NSObject>

/// The live sceneResolutionScale, or -1 if the config can't be read yet.
- (int)heatReadScale;
/// Queues a write on the client thread. NO if the bridge didn't take it, as it won't before the JVM is up.
- (BOOL)heatWriteScale:(int)scale;
/// YES once no config write is still queued on the client thread.
- (BOOL)heatWritesLanded;
/// Queues a save behind the writes already queued. Its write id, or 0 if it couldn't queue.
- (long long)heatQueueSave;
/// The newest write id the client thread has run. A save's id gets here once the file is written.
- (long long)heatProcessedWriteId;
/// The player's value from the marker, or 0 when there is no marker.
- (int)heatReadMarker;
/// NO if the marker couldn't be written.
- (BOOL)heatWriteMarker:(int)baseline;
- (void)heatClearMarker;
- (void)appendLine:(NSString *)line;

@end

/// Holds 117HD's sceneResolutionScale to a limit and gives the player's value back afterwards. It has to get that right
/// through three things the game does to config writes:
///  - Before the JVM is up the bridge takes nothing, so the write that recovers a killed session can't happen yet. The
///    marker stays until the bridge has taken it.
///  - Writes queue on the client thread, which can stall for minutes in a scene load or a shader compile. While any
///    wait, the live value isn't what it will be, and a write now would land on top of a player's. So this waits.
///  - A write that has landed is only in memory, and iOS runs no periodic save. So the marker goes only after a save
///    queued behind the writes has run. A session killed before that still has its marker, and the next launch
///    finishes the job.
/// All of it is on the main thread, which the mobile* bridge selectors require. ThermalScaleKeeper is Android's.
@interface RMHeatScaleKeeper : NSObject

@property (nonatomic, readonly) int baselineScale; // the player's value, 0 until the marker or the config says
@property (nonatomic, readonly) int appliedScale;  // what the config should hold once the queue has drained

- (instancetype)initWithStore:(id<RMHeatScaleStore>)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// One pass at `limitPercent`, 0 for no limit. Call it on every tick: nothing else retries. `thermal` is for the log.
- (void)stepWithLimit:(int)limitPercent thermal:(NSInteger)thermal;

@end

/// One look at the phone and the game.
typedef struct {
    NSInteger thermalState; // NSProcessInfoThermalState
    BOOL lowPower;
    BOOL background;
    int frames;         // frames drawn since the last reading
    // All since the last reading, and all CPU or waiting, not time the frames took.
    double gameCpuSeconds; // the game thread on a CPU, negative when it can't be read
    double gpuWaitSeconds; // the game thread stuck waiting for the GPU
    double appCpuSeconds;  // every thread in the app on a CPU
    int batteryState;   // a UIDeviceBatteryState: 0 unknown, 1 on battery, 2 charging, 3 full
    float batteryLevel; // 0 to 1, or negative when the phone doesn't say
    int fpsLimit;       // the limit in force, 0 for none
    int scalePercent;   // 117HD's scale in force, 0 on the other renderers
    int baselineScale;  // what the player set it to, 0 on the other renderers
} RMHeatReading;

/// CPU used by every thread in the app since launch.
double RMAppCpuSeconds(void);

/// The session's readings, for the "Heat" section of Share logs: what the phone is doing now, and one line a minute.
/// Written from the main thread, read from wherever the report is built. Foundation only, as above.
@interface RMHeatLog : NSObject

@property (class, nonatomic, readonly) RMHeatLog *shared;

- (void)addReading:(RMHeatReading)reading at:(NSTimeInterval)now;
- (NSString *)report;

@end

NS_ASSUME_NONNULL_END
