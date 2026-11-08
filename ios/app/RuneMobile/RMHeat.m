#import "RMHeat.h"
#import <sys/resource.h>

// By thermal state. The frame rate is the first lever because it works on every renderer and saves nothing to the
// player's settings. 117HD's scale is a saved setting, so it stays for the states where the phone is throttling.
static const RMHeatLimit kThermalLimits[] = {
    {0, 0},   // nominal
    {0, 40},  // fair
    {65, 30}, // serious
    {50, 20}, // critical
};
static const NSInteger kHottest = sizeof(kThermalLimits) / sizeof(kThermalLimits[0]) - 1;
static const int kLowPowerFps = 30;
static const NSTimeInterval kCalmSeconds = 60.0;

// A line a minute for four hours, about 17 KB of the report.
static const NSUInteger kMaxLines = 240;
static const NSTimeInterval kLineSeconds = 60.0;
// A gap longer than this between readings is the phone asleep or the app suspended, not time spent playing.
static const NSTimeInterval kMaxGapSeconds = 30.0;

@implementation RMHeatPolicy {
    NSInteger _level;
    NSTimeInterval _calmSince; // when the readings fell below _level, or negative while they haven't
}

- (instancetype)init {
    self = [super init];
    if (self)
        _calmSince = -1;
    return self;
}

- (RMHeatLimit)limitForThermalState:(NSInteger)state lowPower:(BOOL)lowPower at:(NSTimeInterval)now {
    NSInteger reading = MAX(0, MIN(state, kHottest));
    if (reading >= _level) {
        _level = reading;
        _calmSince = -1;
    } else if (_calmSince < 0) {
        _calmSince = now;
    } else if (now - _calmSince >= kCalmSeconds) {
        _level--;
        _calmSince = _level > reading ? now : -1;
    }
    RMHeatLimit limit = kThermalLimits[_level];
    // The player chose this one, so it needs no calming down: it comes and goes with the switch.
    if (lowPower && (limit.fps == 0 || limit.fps > kLowPowerFps))
        limit.fps = kLowPowerFps;
    return limit;
}

@end

@implementation RMHeatScaleKeeper {
    __weak id<RMHeatScaleStore> _store; // it owns this
    BOOL _markerRetiring;               // the marker can go once the player's value is on disk
    long long _markerSaveId;            // the save that puts it there, 0 until one is queued
}

- (instancetype)initWithStore:(id<RMHeatScaleStore>)store {
    self = [super init];
    if (self)
        _store = store;
    return self;
}

- (void)stepWithLimit:(int)limitPercent thermal:(NSInteger)thermal {
    if (_baselineScale <= 0 && ![self arm])
        return;
    [self settleMarker];
    // Cool, with nothing to put back, is the one time there's nothing to look at. Under a limit a player's move has to
    // reach the marker before a kill can come, and the limit has to go over it, wherever the scale was before.
    if (limitPercent == 0 && _appliedScale == _baselineScale)
        return;
    // No write can be judged, or made, until the queue is empty. Adopting a stale value could make a throttle
    // permanent, and no timer can stand in for this.
    if (![_store heatWritesLanded])
        return;
    int live = [_store heatReadScale];
    if (live <= 0)
        return;
    // The player has moved the setting since the last write: theirs is the new baseline, or cooling down would put the
    // old value back.
    if (live != _appliedScale && ![self adoptPlayersScale:live])
        return;
    int target = [self scaleForLimit:limitPercent];
    if (target != _appliedScale)
        [self write:target thermal:thermal];
    else if (target == _baselineScale)
        [self retireMarker]; // a player's own value, and otherwise a throttle that's holding
}

// NO while the player's value isn't known. A marker comes first: it's from a session killed mid-throttle, so the config
// holds the lowered value.
- (BOOL)arm {
    int leaked = [_store heatReadMarker];
    int known = leaked > 0 ? leaked : [_store heatReadScale];
    // Never guess a baseline: a wrong default could raise a player's lower scale.
    if (known <= 0 || (leaked > 0 && ![_store heatWriteScale:leaked]))
        return NO;
    _baselineScale = known;
    _appliedScale = known;
    if (leaked > 0) {
        _markerRetiring = YES;
        [_store appendLine:[NSString stringWithFormat:
                                         @"[shell] thermal: recovered a leaked throttle -> restored sceneResolutionScale=%d", leaked]];
    } else {
        [_store appendLine:[NSString stringWithFormat:
                                         @"[shell] thermal governor armed (117HD) - baseline sceneResolutionScale=%d", known]];
    }
    return YES;
}

- (void)write:(int)target thermal:(NSInteger)thermal {
    BOOL throttling = target < _baselineScale;
    // The marker goes down first and has to take: a lowered value must never reach the disk without one.
    if (throttling && ![_store heatWriteMarker:_baselineScale])
        return;
    if (![_store heatWriteScale:target]) {
        if (_appliedScale == _baselineScale)
            [self retireMarker]; // nothing was lowered after all, and a stale marker could overwrite a player's later move
        return;
    }
    int prev = _appliedScale;
    _appliedScale = target;
    if (throttling) {
        _markerRetiring = NO;
        _markerSaveId = 0;
    } else {
        [self retireMarker];
    }
    [_store appendLine:[NSString stringWithFormat:@"[shell] thermal state=%ld -> sceneResolutionScale %d->%d (baseline=%d)",
                                                  (long)thermal, prev, target, _baselineScale]];
}

// NO if the marker can't follow, because a kill would then bring back the old value. Nothing moves until it can.
- (BOOL)adoptPlayersScale:(int)live {
    if ([_store heatReadMarker] > 0 && ![_store heatWriteMarker:live])
        return NO;
    [_store appendLine:[NSString stringWithFormat:@"[shell] thermal: player set sceneResolutionScale=%d (was %d)", live,
                                                  _appliedScale]];
    _baselineScale = live;
    _appliedScale = live;
    return YES;
}

- (void)retireMarker {
    if ([_store heatReadMarker] > 0)
        _markerRetiring = YES;
}

- (void)settleMarker {
    if (!_markerRetiring)
        return;
    if (_markerSaveId == 0) {
        _markerSaveId = [_store heatQueueSave]; // 0 if it can't queue yet: next tick
    } else if ([_store heatProcessedWriteId] >= _markerSaveId) {
        [_store heatClearMarker];
        _markerRetiring = NO;
        _markerSaveId = 0;
    }
}

// Never above the baseline, so a low-res user config is honoured.
- (int)scaleForLimit:(int)limitPercent {
    return limitPercent > 0 ? MIN(_baselineScale, limitPercent) : _baselineScale;
}

@end

static NSString *thermalName(NSInteger state) {
    static NSString *const names[] = {@"nominal", @"fair", @"serious", @"critical"};
    return (state >= 0 && state <= kHottest) ? names[state] : @"?";
}

static NSString *batteryText(const RMHeatReading *r) {
    NSString *percent = r->batteryLevel >= 0 ? [NSString stringWithFormat:@" %.0f%%", r->batteryLevel * 100] : @"";
    switch (r->batteryState) {
        case 1:
            return [@"on battery" stringByAppendingString:percent];
        case 2:
            return [@"charging" stringByAppendingString:percent];
        case 3:
            return [@"full" stringByAppendingString:percent];
        default:
            return @"battery unknown";
    }
}

double RMAppCpuSeconds(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0)
        return 0;
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}

// Milliseconds a frame, or "-" for a reading that couldn't be taken.
static NSString *msText(double ms) {
    return ms >= 0 ? [NSString stringWithFormat:@"%.1f", ms] : @"-";
}

BOOL RMHeatNoticeSpot(CGRect area, CGSize size, const CGRect *blockers, NSUInteger count, CGFloat gap,
                      CGPoint *origin) {
    const CGFloat left = area.origin.x, right = area.origin.x + area.size.width;
    const CGFloat mid = left + area.size.width / 2;
    CGFloat starts[count + 1], ends[count + 1];
    CGFloat bottom = area.origin.y + area.size.height;
    while (bottom - size.height >= area.origin.y) {
        const CGFloat top = bottom - size.height;
        // What's in the way across this band, as x ranges sorted by where they start, and how far up the card has to
        // go to clear the lowest of them.
        NSUInteger n = 0;
        CGFloat lift = -INFINITY;
        for (NSUInteger i = 0; i < count; i++) {
            const CGRect b = blockers[i];
            if (b.origin.y - gap >= bottom || b.origin.y + b.size.height + gap <= top)
                continue;
            NSUInteger at = n++;
            for (; at > 0 && starts[at - 1] > b.origin.x - gap; at--) {
                starts[at] = starts[at - 1];
                ends[at] = ends[at - 1];
            }
            starts[at] = b.origin.x - gap;
            ends[at] = b.origin.x + b.size.width + gap;
            lift = MAX(lift, b.origin.y - gap);
        }
        // The gaps between them that the card fits in, and the spot in one of those nearest the middle.
        BOOL found = NO;
        CGFloat bestX = 0, bestOff = INFINITY, from = left;
        for (NSUInteger k = 0; k <= n; k++) {
            const CGFloat to = k < n ? MIN(starts[k], right) : right;
            if (to - from >= size.width) {
                const CGFloat x = MIN(MAX(mid - size.width / 2, from), to - size.width);
                const CGFloat off = fabs(x + size.width / 2 - mid);
                if (off < bestOff) {
                    bestOff = off;
                    bestX = x;
                    found = YES;
                }
            }
            if (k < n)
                from = MAX(from, ends[k]);
        }
        if (found) {
            *origin = (CGPoint){bestX, top};
            return YES;
        }
        if (n == 0)
            return NO; // nothing in the way and still no room: the area is narrower than the card
        bottom = lift;
    }
    return NO;
}

@implementation RMHeatLog {
    NSMutableArray<NSString *> *_lines;
    NSUInteger _dropped;
    BOOL _started;
    NSTimeInterval _startedAt, _lastAt, _playedSeconds, _warmSeconds, _backgroundSeconds;
    RMHeatReading _latest;
    double _latestFps; // negative until there are two readings in a row to measure between
    // The minute being counted.
    NSTimeInterval _windowSeconds;
    long _windowFrames;
    NSInteger _windowHottest;
    BOOL _windowBackground;
    double _windowAppCpu;
    // Frame timing covers the time on screen: time in the background draws nothing, so it would pass for slow frames.
    double _windowTimedSeconds, _windowGameCpu, _windowGpuWait;
    long _windowTimedFrames;
    long _windowGameFrames; // the frames _windowGameCpu covers, since the game thread can't always be read
    // The slowest reading of the minute, in ms a frame: a crowd or a hitch hardly moves a minute's average.
    double _slowestFrameMs, _slowestGameCpuMs, _slowestGpuWaitMs;
}

+ (RMHeatLog *)shared {
    static RMHeatLog *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = [[RMHeatLog alloc] init];
    });
    return log;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lines = [NSMutableArray array];
        _latestFps = -1;
    }
    return self;
}

- (void)addReading:(RMHeatReading)r at:(NSTimeInterval)now {
    @synchronized(self) {
        if (!_started) {
            _started = YES;
            _startedAt = _lastAt = now;
            _windowHottest = r.thermalState;
            _latest = r;
            return;
        }
        NSTimeInterval gap = now - _lastAt;
        // On screen at both ends: the first reading back spans the time away, with hardly a frame to show for it.
        BOOL onScreen = !_latest.background && !r.background;
        _lastAt = now;
        _latest = r;
        if (gap <= 0)
            return;
        if (gap > kMaxGapSeconds) {
            _latestFps = -1;
            return;
        }
        _latestFps = r.frames / gap;
        _playedSeconds += gap;
        if (r.thermalState > 0)
            _warmSeconds += gap;
        if (r.background)
            _backgroundSeconds += gap;
        _windowSeconds += gap;
        _windowFrames += r.frames;
        _windowHottest = MAX(_windowHottest, r.thermalState);
        _windowBackground = _windowBackground || r.background;
        _windowAppCpu += r.appCpuSeconds;
        if (onScreen)
            [self noteTiming:r over:gap];
        if (_windowSeconds >= kLineSeconds)
            [self closeWindowAt:now];
    }
}

- (void)noteTiming:(RMHeatReading)r over:(NSTimeInterval)gap {
    _windowTimedSeconds += gap;
    _windowTimedFrames += r.frames;
    _windowGpuWait += r.gpuWaitSeconds;
    if (r.gameCpuSeconds >= 0) {
        _windowGameCpu += r.gameCpuSeconds;
        _windowGameFrames += r.frames;
    }
    int frames = MAX(r.frames, 1); // a reading with no frames at all is a stall, the slowest kind
    double frameMs = gap * 1000.0 / frames;
    if (frameMs <= _slowestFrameMs)
        return;
    _slowestFrameMs = frameMs;
    _slowestGameCpuMs = r.gameCpuSeconds >= 0 ? r.gameCpuSeconds * 1000.0 / frames : -1;
    _slowestGpuWaitMs = r.gpuWaitSeconds * 1000.0 / frames;
}

// Where the minute's frames went. Nothing for a minute that drew none.
- (NSString *)timingText {
    if (_windowTimedFrames <= 0)
        return @"";
    return [NSString stringWithFormat:@"frame %.1f  cpu %@  gpu %.1f  worst %.1f (cpu %@ gpu %.1f)  cores %.1f  ",
                                      _windowTimedSeconds * 1000.0 / _windowTimedFrames,
                                      msText(_windowGameFrames > 0 ? _windowGameCpu * 1000.0 / _windowGameFrames : -1),
                                      _windowGpuWait * 1000.0 / _windowTimedFrames, _slowestFrameMs, msText(_slowestGameCpuMs),
                                      _slowestGpuWaitMs, _windowAppCpu / _windowSeconds];
}

// One line for the minute just counted. The thermal column is the hottest the minute got, and the rest is how it
// ended, so a short spike still shows.
- (void)closeWindowAt:(NSTimeInterval)now {
    NSString *line = [NSString stringWithFormat:@"%4.0f min  %-8s  %3.0f fps  limit %-3s  scale %-3s  %@%@%@%@",
                                                (now - _startedAt) / 60.0, thermalName(_windowHottest).UTF8String,
                                                _windowFrames / _windowSeconds,
                                                _latest.fpsLimit ? @(_latest.fpsLimit).stringValue.UTF8String : "-",
                                                _latest.scalePercent ? @(_latest.scalePercent).stringValue.UTF8String : "-",
                                                [self timingText], batteryText(&_latest), _latest.lowPower ? @", low power" : @"",
                                                _windowBackground ? @", in background" : @""];
    [_lines addObject:line];
    if (_lines.count > kMaxLines) {
        [_lines removeObjectAtIndex:0];
        _dropped++;
    }
    _windowSeconds = 0;
    _windowFrames = 0;
    _windowHottest = _latest.thermalState;
    _windowBackground = NO;
    _windowTimedSeconds = _windowGameCpu = _windowGpuWait = _windowAppCpu = 0;
    _windowTimedFrames = _windowGameFrames = 0;
    _slowestFrameMs = _slowestGameCpuMs = _slowestGpuWaitMs = 0;
}

- (NSString *)report {
    @synchronized(self) {
        if (!_started)
            return @"(no readings yet: the game hasn't started)\n";
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"Now: thermal %@ | %@ | ", thermalName(_latest.thermalState),
                          _latestFps >= 0 ? [NSString stringWithFormat:@"%.0f fps", _latestFps] : @"fps not measured yet"];
        if (_latest.fpsLimit)
            [out appendFormat:@"limited to %d fps | ", _latest.fpsLimit];
        else
            [out appendString:@"no limit | "];
        // Off, with nothing to put back, the keeper doesn't read the setting, so its numbers could be from before the
        // player's last move. Better none than a wrong one.
        if (_latest.scalePercent && !_latest.lowerResolution && _latest.scalePercent == _latest.baselineScale)
            [out appendString:@"117HD scale left to the player, lower when hot off | "];
        else if (_latest.scalePercent)
            [out appendFormat:@"117HD scale %d of %d, lower when hot %@ | ", _latest.scalePercent,
                              _latest.baselineScale, _latest.lowerResolution ? @"on" : @"off"];
        [out appendFormat:@"%@ | Low Power Mode %@\n", batteryText(&_latest), _latest.lowPower ? @"on" : @"off"];
        [out appendFormat:@"This launch: %.0f min, %.0f min above nominal, %.0f min in the background\n",
                          _playedSeconds / 60.0, _warmSeconds / 60.0, _backgroundSeconds / 60.0];
        if (_lines.count)
            [out appendString:@"Times are ms a frame: cpu is the game thread working, gpu is it waiting for the GPU, and "
                              @"the rest of frame is spare. worst is the minute's slowest few seconds. cores is the whole "
                              @"app's CPU.\n"];
        if (_dropped)
            [out appendFormat:@"(%lu older minutes dropped)\n", (unsigned long)_dropped];
        for (NSString *line in _lines)
            [out appendFormat:@"%@\n", line];
        return out;
    }
}

@end
