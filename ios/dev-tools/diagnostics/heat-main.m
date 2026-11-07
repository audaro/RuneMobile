// Checks RMHeat.m's limits, its 117HD scale keeper and its session log. Built and run by test-heat.sh.
#import "RMHeat.h"

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    if (!ok) {
        fprintf(stderr, "FAILED: %s\n", what.UTF8String);
        failures++;
    }
}

static void limitIs(RMHeatLimit got, int scale, int fps, NSString *what) {
    check(got.scalePercent == scale && got.fps == fps,
          [NSString stringWithFormat:@"%@: got scale %d, fps %d; wanted scale %d, fps %d", what, got.scalePercent, got.fps,
                                     scale, fps]);
}

static void checkPolicy(void) {
    RMHeatPolicy *p = [RMHeatPolicy new];
    limitIs([p limitForThermalState:0 lowPower:NO at:0], 0, 0, @"nominal has no limit");
    limitIs([p limitForThermalState:1 lowPower:NO at:1], 0, 40, @"fair caps the frame rate and leaves the scale");
    limitIs([p limitForThermalState:2 lowPower:NO at:2], 65, 30, @"serious");
    limitIs([p limitForThermalState:3 lowPower:NO at:3], 50, 20, @"critical");

    p = [RMHeatPolicy new];
    limitIs([p limitForThermalState:3 lowPower:NO at:0], 50, 20, @"a jump straight to critical comes on at once");
    limitIs([p limitForThermalState:0 lowPower:NO at:1], 50, 20, @"calm starts");
    limitIs([p limitForThermalState:0 lowPower:NO at:60], 50, 20, @"59 s of calm isn't enough");
    limitIs([p limitForThermalState:0 lowPower:NO at:61], 65, 30, @"a minute of calm lifts one step, not all of them");
    limitIs([p limitForThermalState:0 lowPower:NO at:120], 65, 30, @"the next step waits its own minute");
    limitIs([p limitForThermalState:0 lowPower:NO at:121], 0, 40, @"second step");
    limitIs([p limitForThermalState:0 lowPower:NO at:181], 0, 0, @"third step, and clear");

    p = [RMHeatPolicy new];
    [p limitForThermalState:2 lowPower:NO at:0];
    [p limitForThermalState:0 lowPower:NO at:1];
    limitIs([p limitForThermalState:2 lowPower:NO at:50], 65, 30, @"heat coming back");
    limitIs([p limitForThermalState:0 lowPower:NO at:51], 65, 30, @"calm starts over");
    limitIs([p limitForThermalState:0 lowPower:NO at:80], 65, 30, @"the earlier calm doesn't count");
    limitIs([p limitForThermalState:0 lowPower:NO at:111], 0, 40, @"a full minute from the new calm");

    p = [RMHeatPolicy new];
    [p limitForThermalState:2 lowPower:NO at:0];
    limitIs([p limitForThermalState:1 lowPower:NO at:1], 65, 30, @"fair doesn't lift serious at once");
    limitIs([p limitForThermalState:1 lowPower:NO at:62], 0, 40, @"it stops at the state the phone is in");
    limitIs([p limitForThermalState:1 lowPower:NO at:500], 0, 40, @"and stays there while it holds");

    p = [RMHeatPolicy new];
    limitIs([p limitForThermalState:0 lowPower:YES at:0], 0, 30, @"Low Power Mode caps a cool phone");
    limitIs([p limitForThermalState:1 lowPower:YES at:1], 0, 30, @"it's lower than fair's cap");
    limitIs([p limitForThermalState:3 lowPower:YES at:2], 50, 20, @"critical's cap is lower, and wins");
    p = [RMHeatPolicy new];
    limitIs([p limitForThermalState:0 lowPower:YES at:0], 0, 30, @"on");
    limitIs([p limitForThermalState:0 lowPower:NO at:1], 0, 0, @"turning it off needs no calm");

    p = [RMHeatPolicy new];
    limitIs([p limitForThermalState:-1 lowPower:NO at:0], 0, 0, @"a state below the table");
    limitIs([p limitForThermalState:9 lowPower:NO at:1], 50, 20, @"a state above it");
}

static RMHeatReading reading(NSInteger thermal, int frames) {
    RMHeatReading r = {0};
    r.thermalState = thermal;
    r.frames = frames;
    r.batteryState = 1;
    r.batteryLevel = 0.5f;
    return r;
}

static BOOL has(NSString *text, NSString *part) {
    return [text rangeOfString:part].location != NSNotFound;
}

static void checkLog(void) {
    RMHeatLog *log = [RMHeatLog new];
    check(has([log report], @"no readings yet"), @"an empty log says so");

    [log addReading:reading(0, 0) at:100];
    NSString *report = [log report];
    check(has(report, @"Now: thermal nominal | fps not measured yet"), @"one reading has no fps");

    // Two minutes at 50 fps, read every 2 s, with one reading of serious in the middle of the first.
    for (int t = 2; t <= 120; t += 2) {
        RMHeatReading r = reading(t == 30 ? 2 : 0, 100);
        r.fpsLimit = t > 60 ? 30 : 0;
        r.scalePercent = 65;
        r.baselineScale = 100;
        [log addReading:r at:100 + t];
    }
    report = [log report];
    NSArray<NSString *> *lines = [report componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *minutes = [lines filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS ' min  '"]];
    check(minutes.count == 2, [NSString stringWithFormat:@"a line a minute: got %lu\n%@", (unsigned long)minutes.count, report]);
    check(minutes.count == 2 && has(minutes[0], @"serious") && has(minutes[0], @" 50 fps"),
          [NSString stringWithFormat:@"a minute shows its hottest moment:\n%@", report]);
    check(minutes.count == 2 && has(minutes[1], @"nominal") && has(minutes[1], @"limit 30"),
          [NSString stringWithFormat:@"the next minute starts clean:\n%@", report]);
    check(has(report, @"limited to 30 fps"), @"the limit in force");
    check(has(report, @"117HD scale 65 of 100"), @"the scale in force");
    check(has(report, @"on battery 50%"), @"the battery");
    check(has(report, @"Low Power Mode off"), @"Low Power Mode");

    // A suspended app: the gap isn't play time, and the frames either side of it aren't a frame rate.
    log = [RMHeatLog new];
    [log addReading:reading(1, 0) at:0];
    for (int t = 2; t <= 58; t += 2)
        [log addReading:reading(1, 100) at:t];
    [log addReading:reading(1, 100) at:3658];
    report = [log report];
    check(has(report, @"This launch: 1 min, 1 min above nominal"), [NSString stringWithFormat:@"a gap isn't played:\n%@", report]);
    check(has(report, @"fps not measured yet"), [NSString stringWithFormat:@"no frame rate across a gap:\n%@", report]);
    [log addReading:reading(1, 100) at:3660];
    report = [log report];
    check(has(report, @" 50 fps") && has(report, @"Now: thermal fair | 50 fps"),
          [NSString stringWithFormat:@"the next reading measures again, and the minute isn't dragged down:\n%@", report]);

    // Older minutes go, and the report says so.
    log = [RMHeatLog new];
    [log addReading:reading(0, 0) at:0];
    for (int t = 2; t <= 245 * 60; t += 2)
        [log addReading:reading(0, 100) at:t];
    report = [log report];
    check(has(report, @"(5 older minutes dropped)"), [NSString stringWithFormat:@"dropped minutes:\n%@", [report substringToIndex:200]]);

    // Battery states the phone can report.
    RMHeatReading r = reading(0, 0);
    log = [RMHeatLog new];
    r.batteryState = 2;
    r.batteryLevel = 0.83f;
    [log addReading:r at:0];
    check(has([log report], @"charging 83%"), @"charging");
    log = [RMHeatLog new];
    r.batteryState = 0;
    r.batteryLevel = -1;
    [log addReading:r at:0];
    check(has([log report], @"battery unknown"), @"unknown");
}

// A game that behaves like the real one: writes and saves queue in order on the client thread, and a save takes what is
// in memory when its turn comes.
@interface FakeGame : NSObject <RMHeatScaleStore>
@property (nonatomic) int live;
@property (nonatomic) int disk;
@property (nonatomic) int marker;
@property (nonatomic) BOOL bridgeDown;
@property (nonatomic) BOOL refuseWrites;
@property (nonatomic) BOOL refuseSaves;
@property (nonatomic) BOOL refuseMarker;
@property (nonatomic) BOOL configUnreadable;
@property (nonatomic) int reads;
@property (nonatomic) long long processed;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *queue; // a scale, or 0 for a save
@property (nonatomic, strong) NSMutableArray<NSNumber *> *markerWhenQueued;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@end

@implementation FakeGame

- (instancetype)initWithScale:(int)scale marker:(int)marker {
    self = [super init];
    if (self) {
        _live = _disk = scale;
        _marker = marker;
        _queue = [NSMutableArray array];
        _markerWhenQueued = [NSMutableArray array];
        _lines = [NSMutableArray array];
    }
    return self;
}

- (void)land {
    for (NSNumber *entry in self.queue) {
        if (entry.intValue > 0)
            self.live = entry.intValue;
        else
            self.disk = self.live;
        self.processed++;
    }
    [self.queue removeAllObjects];
}

- (void)playerSets:(int)scale {
    [self.queue addObject:@(scale)];
}

- (void)appSaves {
    self.disk = self.live;
}

- (int)heatReadScale {
    self.reads++;
    return self.bridgeDown || self.configUnreadable ? -1 : self.live;
}

- (BOOL)heatWriteScale:(int)scale {
    if (self.bridgeDown || self.refuseWrites)
        return NO;
    [self.queue addObject:@(scale)];
    [self.markerWhenQueued addObject:@(self.marker)];
    return YES;
}

- (BOOL)heatWritesLanded {
    if (self.bridgeDown)
        return NO;
    for (NSNumber *entry in self.queue) {
        if (entry.intValue > 0)
            return NO;
    }
    return YES;
}

- (long long)heatQueueSave {
    if (self.bridgeDown || self.refuseSaves)
        return 0;
    [self.queue addObject:@0];
    return self.processed + (long long)self.queue.count;
}

- (long long)heatProcessedWriteId {
    return self.bridgeDown ? -1 : self.processed;
}

- (int)heatReadMarker {
    return self.marker;
}

- (BOOL)heatWriteMarker:(int)baseline {
    if (self.refuseMarker)
        return NO;
    self.marker = baseline;
    return YES;
}

- (void)heatClearMarker {
    self.marker = 0;
}

- (void)appendLine:(NSString *)line {
    [self.lines addObject:line];
}

@end

static FakeGame *game(int scale) {
    return [[FakeGame alloc] initWithScale:scale marker:0];
}

static RMHeatScaleKeeper *keeperFor(FakeGame *g) {
    return [[RMHeatScaleKeeper alloc] initWithStore:g];
}

static void step(RMHeatScaleKeeper *k, int limit) {
    [k stepWithLimit:limit
             thermal:limit == 50 ? 3 : limit == 65 ? 2
                                                   : 0];
}

static void same(long long got, long long want, NSString *what) {
    check(got == want, [NSString stringWithFormat:@"%@: got %lld, wanted %lld", what, got, want]);
}

// Armed at the game's scale and throttled to 50, with that throttle in memory and on disk.
static void throttled(FakeGame *g, RMHeatScaleKeeper *k) {
    step(k, 0);
    step(k, 50);
    [g land];
    [g appSaves];
    same(g.disk, 50, @"set-up: the throttle is on disk");
}

// Two passes around the queue, which is what a save behind a write takes to be seen.
static void settle(FakeGame *g, RMHeatScaleKeeper *k, int limit) {
    step(k, limit);
    [g land];
    step(k, limit);
}

static BOOL logged(FakeGame *g, NSString *part) {
    for (NSString *line in g.lines) {
        if (has(line, part))
            return YES;
    }
    return NO;
}

static void checkThrottling(void) {
    FakeGame *g = game(100);
    RMHeatScaleKeeper *k = keeperFor(g);
    step(k, 0);
    step(k, 65);
    [g land];
    same(g.live, 65, @"a throttle comes on");
    same(g.marker, 100, @"with the marker holding the player's value");
    same(k.baselineScale, 100, @"the report's baseline");
    same(k.appliedScale, 65, @"the report's scale");
    step(k, 50);
    [g land];
    same(g.live, 50, @"a second step");
    same(g.marker, 100, @"the marker doesn't take the first step's value");

    g = game(100);
    k = keeperFor(g);
    step(k, 65);
    check(logged(g, @"[shell] thermal state=2 -> sceneResolutionScale 100->65 (baseline=100)"), @"the log line for a step");
    g = [[FakeGame alloc] initWithScale:50 marker:85];
    step(keeperFor(g), 0);
    check(logged(g, @"[shell] thermal: recovered a leaked throttle -> restored sceneResolutionScale=85"), @"the log line for a recovery");

    // What it costs on the main thread.
    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    int armed = g.reads;
    for (int i = 0; i < 5; i++)
        step(k, 0);
    same(g.reads, armed, @"a cool phone doesn't read the config on every tick");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    for (int i = 0; i < 3; i++)
        step(k, 50);
    check(g.queue.count == 0, @"a steady throttle writes nothing");
    same(g.marker, 100, @"and keeps its marker");
    same(g.live, 50, @"and its scale");
}

static void checkMarkerOrder(void) {
    FakeGame *g = game(100);
    RMHeatScaleKeeper *k = keeperFor(g);
    step(k, 65);
    check([g.markerWhenQueued isEqualToArray:@[ @100 ]], [NSString stringWithFormat:@"the marker is down before a throttle queues: %@", g.markerWhenQueued]);

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    g.refuseMarker = YES;
    step(k, 50);
    check(g.queue.count == 0, @"no throttle without a marker");
    g.refuseMarker = NO;
    step(k, 50);
    [g land];
    same(g.live, 50, @"it comes on once the marker takes");
    same(g.marker, 100, @"with the marker");

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    g.refuseWrites = YES;
    step(k, 65);
    g.refuseWrites = NO;
    step(k, 65);
    [g land];
    same(g.live, 65, @"a refused write is tried again");
    same(g.marker, 100, @"with its marker");
    check(!logged(g, @"player set"), @"a refused write isn't a player's move");

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    g.refuseWrites = YES;
    step(k, 65);
    g.refuseWrites = NO;
    settle(g, k, 0);
    same(g.marker, 0, @"a refused throttle leaves no marker to overwrite a player later");
    same(g.live, 100, @"and nothing was lowered");

    g = game(100);
    k = keeperFor(g);
    step(k, 65);
    [g land];
    [g appSaves];
    g.refuseWrites = YES;
    step(k, 50);
    // Easing back to the throttle in force writes nothing, so nothing would put a lost marker back.
    settle(g, k, 65);
    same(g.marker, 100, @"a refused second step keeps the marker of the throttle in force");
    same(g.disk, 65, @"which is still what's saved");
}

static void checkCoolingDown(void) {
    FakeGame *g = game(100);
    RMHeatScaleKeeper *k = keeperFor(g);
    throttled(g, k);
    step(k, 0);
    same(g.live, 50, @"the restore is queued, not landed");
    same(g.marker, 100, @"so the marker stays");
    step(k, 0);
    step(k, 0);
    same(g.disk, 50, @"a stalled client thread is waited for");
    same(g.marker, 100, @"and the marker stays through it, with the save queued but not run");
    [g land];
    same(g.disk, 100, @"the save ran behind the restore");
    same(g.marker, 100, @"seen on the next tick");
    step(k, 0);
    same(g.marker, 0, @"the marker goes once the save has run");
    same(g.disk, 100, @"with the player's value on disk");
    for (int i = 0; i < 3; i++)
        step(k, 0);
    check(g.queue.count == 0, @"and that's the end of it");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    step(k, 0);
    [g land];
    g.refuseSaves = YES;
    step(k, 0);
    step(k, 0);
    same(g.marker, 100, @"a save that can't queue keeps the marker");
    g.refuseSaves = NO;
    settle(g, k, 0);
    same(g.marker, 0, @"and is tried again");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    step(k, 0);
    step(k, 0);
    settle(g, k, 50);
    settle(g, k, 50);
    same(g.live, 50, @"heat coming back mid-restore throttles again");
    same(g.marker, 100, @"with the marker");
    same(g.disk, 100, @"the player's value saved before it came back on");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    step(k, 0);
    [g land];
    g.refuseSaves = YES;
    step(k, 50);
    [g land];
    g.refuseSaves = NO;
    for (int i = 0; i < 3; i++)
        settle(g, k, 50);
    same(g.live, 50, @"a throttle while a save is failing");
    same(g.marker, 100, @"keeps the marker");

    // The save belongs to the cool spell before this throttle, so it says nothing about the value on disk now.
    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    step(k, 0);
    [g land];
    step(k, 0);
    step(k, 50);
    [g land];
    [g appSaves];
    step(k, 0);
    step(k, 0);
    same(g.disk, 50, @"the throttle is saved again");
    same(g.marker, 100, @"so a save from before it can't retire the marker");
    [g land];
    settle(g, k, 0);
    same(g.disk, 100, @"a save of its own does");
    same(g.marker, 0, @"and then the marker goes");
}

static void checkRecovery(void) {
    FakeGame *g = [[FakeGame alloc] initWithScale:50 marker:85];
    g.bridgeDown = YES;
    RMHeatScaleKeeper *k = keeperFor(g);
    step(k, 0);
    step(k, 0);
    same(g.marker, 85, @"the JVM isn't up at launch, so the marker stays");
    check(g.queue.count == 0, @"and nothing is queued");
    g.bridgeDown = NO;
    step(k, 0);
    same(k.baselineScale, 85, @"the player's value is the marker's, not the config's");
    same(g.marker, 85, @"the write is queued, not saved");
    same(g.disk, 50, @"not yet");
    settle(g, k, 0);
    settle(g, k, 0);
    same(g.disk, 85, @"recovery gets the player's value to disk");
    same(g.marker, 0, @"and then the marker goes");

    g = [[FakeGame alloc] initWithScale:50 marker:100];
    k = keeperFor(g);
    step(k, 65);
    [g land];
    settle(g, k, 65);
    [g land];
    same(g.live, 65, @"a recovery into a hot phone throttles again");
    same(g.marker, 100, @"from the player's value");
    same(k.baselineScale, 100, @"never the leaked one");

    g = game(80);
    g.bridgeDown = YES;
    k = keeperFor(g);
    step(k, 50);
    same(k.baselineScale, 0, @"an unreadable config is never guessed at");
    same(g.marker, 0, @"so there's no marker");
    check(g.queue.count == 0, @"or write");
    g.bridgeDown = NO;
    step(k, 50);
    [g land];
    same(g.live, 50, @"and it arms once it can read");
    same(g.marker, 80, @"on the real value");
    check(!logged(g, @"player set"), @"which isn't a player's move");

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    g.configUnreadable = YES;
    step(k, 50);
    same(g.marker, 0, @"an unreadable config after arming writes nothing");
    check(g.queue.count == 0, @"at all");
    g.configUnreadable = NO;
    step(k, 50);
    [g land];
    same(g.live, 50, @"and is tried again");
}

static void checkPlayersMoves(void) {
    FakeGame *g = game(100);
    RMHeatScaleKeeper *k = keeperFor(g);
    step(k, 0);
    [g playerSets:80];
    step(k, 65);
    check([g.queue isEqualToArray:@[ @80 ]], @"nothing is queued behind a player's write");
    [g land];
    step(k, 65);
    [g land];
    same(g.live, 65, @"it's waited for, then throttled");
    same(g.marker, 80, @"from their value");
    settle(g, k, 0);
    settle(g, k, 0);
    same(g.disk, 80, @"and that's what comes back");

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    [g playerSets:80];
    [g land];
    step(k, 65);
    [g land];
    settle(g, k, 0);
    settle(g, k, 0);
    same(g.live, 80, @"moved before a throttle");
    same(g.disk, 80, @"moved before a throttle, saved");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    [g playerSets:90];
    [g land];
    step(k, 0);
    check(g.queue.count == 0 || g.queue.lastObject.intValue == 0, @"their value needs no write");
    same(g.marker, 90, @"moved mid-throttle: not gone yet, the disk still has the throttle");
    settle(g, k, 0);
    same(g.disk, 90, @"moved mid-throttle, saved");
    same(g.marker, 0, @"and then the marker goes");
    same(g.live, 90, @"and they keep it");

    g = game(100);
    k = keeperFor(g);
    step(k, 65);
    [g land];
    [g playerSets:90];
    [g land];
    step(k, 50);
    [g land];
    same(g.live, 50, @"moved mid-throttle, then hotter");
    same(g.marker, 90, @"throttled from their value");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    [g playerSets:90];
    step(k, 50);
    same(g.marker, 100, @"a queued move isn't judged yet");
    [g land];
    step(k, 50);
    same(g.marker, 90, @"a move during a steady throttle reaches the marker before a kill");
    [g land];
    same(g.live, 50, @"and the limit goes back over it");
    same(k.baselineScale, 90, @"the report's baseline after the move");
    same(k.appliedScale, 50, @"the report's scale after the move");
    [g appSaves];
    k = keeperFor(g);
    settle(g, k, 0);
    settle(g, k, 0);
    same(g.disk, 90, @"the next launch gives them their move");
    same(g.marker, 0, @"and drops the marker");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    [g playerSets:90];
    [g land];
    g.refuseMarker = YES;
    step(k, 50);
    check(g.queue.count == 0, @"no limit over a move the marker doesn't have");
    check(!logged(g, @"player set"), @"and the move isn't adopted yet");
    same(g.marker, 100, @"the marker keeps what it had");
    g.refuseMarker = NO;
    step(k, 50);
    same(g.marker, 90, @"it's tried again");
    [g land];
    same(g.live, 50, @"and then the limit goes back over it");

    g = game(100);
    k = keeperFor(g);
    throttled(g, k);
    [g playerSets:40];
    [g land];
    settle(g, k, 50);
    settle(g, k, 50);
    same(g.disk, 40, @"a player below the limit ends the throttle");
    same(g.marker, 0, @"so the marker goes");

    g = game(40);
    k = keeperFor(g);
    step(k, 0);
    step(k, 50);
    check(g.queue.count == 0, @"a scale below the limit is left alone");
    same(g.marker, 0, @"with no marker");

    g = game(100);
    k = keeperFor(g);
    step(k, 0);
    [g playerSets:40];
    [g land];
    step(k, 50);
    step(k, 50);
    check(g.queue.count == 0, @"a player already below the limit is left alone, with no save either");
    same(g.live, 40, @"at their value");
    same(g.marker, 0, @"with no marker");

    // At or under the limit there's nothing to write, and a player can still raise it from there.
    g = game(40);
    k = keeperFor(g);
    step(k, 0);
    step(k, 50);
    [g playerSets:100];
    [g land];
    step(k, 50);
    [g land];
    same(g.live, 50, @"a player who raises it from under a limit in force gets the limit");
    same(g.marker, 100, @"with their value in the marker");
    settle(g, k, 0);
    settle(g, k, 0);
    same(g.disk, 100, @"and gets it back");

    g = game(40);
    k = keeperFor(g);
    step(k, 0);
    [g playerSets:100];
    [g land];
    step(k, 0);
    step(k, 65);
    [g land];
    same(g.live, 65, @"a player who raised it from under the limit on a cool phone gets the limit too");
    same(g.marker, 100, @"with their value in the marker, too");

    g = game(50);
    k = keeperFor(g);
    step(k, 50);
    [g playerSets:100];
    [g land];
    step(k, 50);
    [g land];
    same(g.live, 50, @"a player exactly at the limit, likewise");
    same(g.marker, 100, @"likewise, in the marker");
}

int main(void) {
    @autoreleasepool {
        checkPolicy();
        checkLog();
        checkThrottling();
        checkMarkerOrder();
        checkCoolingDown();
        checkRecovery();
        checkPlayersMoves();
    }
    if (failures)
        return 1;
    printf("HEAT_POLICY_GREEN\n");
    return 0;
}
