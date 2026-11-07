#import "RMHeat.h"

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
        if (_windowSeconds >= kLineSeconds)
            [self closeWindowAt:now];
    }
}

// One line for the minute just counted. The thermal column is the hottest the minute got, and the rest is how it
// ended, so a short spike still shows.
- (void)closeWindowAt:(NSTimeInterval)now {
    NSString *line = [NSString stringWithFormat:@"%4.0f min  %-8s  %3.0f fps  limit %-3s  scale %-3s  %@%@%@",
                                                (now - _startedAt) / 60.0, thermalName(_windowHottest).UTF8String,
                                                _windowFrames / _windowSeconds,
                                                _latest.fpsLimit ? @(_latest.fpsLimit).stringValue.UTF8String : "-",
                                                _latest.scalePercent ? @(_latest.scalePercent).stringValue.UTF8String : "-",
                                                batteryText(&_latest), _latest.lowPower ? @", low power" : @"",
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
        if (_latest.scalePercent)
            [out appendFormat:@"117HD scale %d of %d | ", _latest.scalePercent, _latest.baselineScale];
        [out appendFormat:@"%@ | Low Power Mode %@\n", batteryText(&_latest), _latest.lowPower ? @"on" : @"off"];
        [out appendFormat:@"This launch: %.0f min, %.0f min above nominal, %.0f min in the background\n",
                          _playedSeconds / 60.0, _warmSeconds / 60.0, _backgroundSeconds / 60.0];
        if (_dropped)
            [out appendFormat:@"(%lu older minutes dropped)\n", (unsigned long)_dropped];
        for (NSString *line in _lines)
            [out appendFormat:@"%@\n", line];
        return out;
    }
}

@end
