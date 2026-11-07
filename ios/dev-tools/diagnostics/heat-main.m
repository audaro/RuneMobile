// Checks RMHeat.m's limits and its session log. Built and run by test-heat.sh.
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

int main(void) {
    @autoreleasepool {
        checkPolicy();
        checkLog();
    }
    if (failures)
        return 1;
    printf("HEAT_POLICY_GREEN\n");
    return 0;
}
