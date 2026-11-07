#import "RMResidency.h"

#import <UIKit/UIKit.h>
#import <os/proc.h>

// Heartbeat resolution. 15s is fine-grained enough to tell a 40-minute session from a 4-minute one
// and to catch headroom trending down, and coarse enough that the write cost is irrelevant.
static const NSTimeInterval kBeatInterval = 15.0;

// Below this much available memory, a death with no notice is far more likely jetsam than anything
// else. Deliberately generous: os_proc_available_memory() reports the headroom to this process's
// jetsam limit, and the JVM is configured with a 1024m heap plus off-heap NIO buffers, so the band
// where the kernel starts looking at us is wide.
static const double kJetsamSuspicionMB = 120.0;

// How many ended sessions the history keeps. A few hundred bytes each, so the whole file stays
// under 100KB -- small enough to rewrite in one go at launch, and to pull off the phone whole.
static const NSUInteger kHistoryEntries = 200;

static NSMutableDictionary *sRecord;
static NSTimeInterval sStarted;
static NSTimer *sBeat;

static NSString *DocPath(NSString *name) {
    NSArray *dirs =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!dirs.count)
        return nil;
    return [dirs[0] stringByAppendingPathComponent:name];
}

// The live record: one session, replaced by the next.
static NSString *RecordPath(void) {
    return DocPath(@"residency.plist");
}

// Every session that has ended, one line each. The verdict used to exist only in the launch log,
// which openLogFile rotates on every launch and Release does not write at all -- so the build
// that is actually lived in computed a verdict and dropped it, and a Debug build kept two. The
// keepalive cannot be tuned on two lines: the candidate causes want opposite fixes and only their
// PROPORTIONS over a week of ordinary use separate them. So the lines pile up here instead, in a
// file no launch truncates, in both configurations. It holds no secrets -- durations, counters and
// a memory figure -- which is what QA-P1-12 took out of Release, and it is not file-shared.
static NSString *HistoryPath(void) {
    return DocPath(@"residency-history.log");
}

static double AvailMB(void) {
    return (double)os_proc_available_memory() / (1024.0 * 1024.0);
}

// mach_continuous_time's clock, via NSDate, is not what this wants for DURATION: it has to keep
// counting while the device sleeps, which wall-clock does, and a backgrounded session sleeping for
// six hours is precisely the case being measured.
static void Persist(void) {
    NSString *path = RecordPath();
    if (path && sRecord)
        [sRecord writeToURL:[NSURL fileURLWithPath:path] error:NULL];
}

// A record that is not shaped like one is discarded rather than read. Every field below is taken
// with -doubleValue or -intValue, which a stray NSData or NSArray in a corrupt file would answer
// with an unrecognized selector: a crash at launch, on every launch, with the bad file still there
// to do it again. Nothing we write can produce one -- the plist is replaced atomically -- so this
// only has to be safe.
//
// FINITE, not merely numeric. A plist can hold a NaN or an infinity quite happily, and such a
// number is a perfectly good NSNumber that fails three ways further on: JSON cannot spell it, so
// the session would be dropped from the history without a word; the date formatter can answer nil
// for it, and a nil in a dictionary literal raises; and the verdict would read "lasted nan".
// Rejecting it here means every consumer below can stop worrying about it.
static BOOL RecordLooksSane(NSDictionary *d) {
    for (NSString *key in @[
             @"start", @"beat", @"minAvailMB", @"memWarnings", @"clean", @"jit", @"idleReleased",
             @"rearms"
         ]) {
        NSNumber *n = d[key];
        if (![n isKindOfClass:[NSNumber class]] || !isfinite(n.doubleValue))
            return NO;
    }
    if (![d[@"state"] isKindOfClass:[NSString class]])
        return NO;
    // Absent in a record written before the breakdown existed, which is fine; present and not a
    // string-to-finite-number map is not. Checked here rather than left to isValidJSONObject,
    // because that one can only decline to write the line, silently.
    id by = d[@"rearmsBy"];
    if (!by)
        return YES;
    if (![by isKindOfClass:[NSDictionary class]])
        return NO;
    for (id key in (NSDictionary *)by) {
        NSNumber *n = ((NSDictionary *)by)[key];
        if (![key isKindOfClass:[NSString class]] || ![n isKindOfClass:[NSNumber class]] ||
            !isfinite(n.doubleValue))
            return NO;
    }
    return YES;
}

// One JSON object per line, carrying both the fields and the sentence. The fields are what a
// summary adds up and the sentence is what someone reads months from now; deriving the first from
// the second would turn every wording change into a silent data break, and dropping the second
// would leave a file only a script can read. `class` is the branch the verdict took, written here
// rather than re-derived by the reader, so the two can never disagree about what a session was.
// ios/dev-tools/residency.py is that reader.
static void AppendHistory(NSDictionary *prev, double lived, NSString *klass, NSString *verdict) {
    NSString *path = HistoryPath();
    if (!path)
        return;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    double start = [prev[@"start"] doubleValue];

    // ?: because -stringFromDate: answers nil for a date the calendar cannot place, and a nil
    // value in a dictionary literal raises -- which would be a launch crash over a cosmetic field.
    NSString *started = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]] ?: @"?";

    NSDictionary *entry = @{
        @"started" : started,
        @"start" : @(start),
        @"lastBeat" : @([prev[@"beat"] doubleValue]),
        @"livedSec" : @(lived),
        @"class" : klass,
        @"state" : prev[@"state"],
        @"clean" : @([prev[@"clean"] boolValue]),
        @"jit" : @([prev[@"jit"] boolValue]),
        @"idleReleased" : @([prev[@"idleReleased"] boolValue]),
        @"rearms" : @([prev[@"rearms"] intValue]),
        @"rearmsBy" : prev[@"rearmsBy"] ?: @{},
        @"memWarnings" : @([prev[@"memWarnings"] intValue]),
        @"minAvailMB" : @([prev[@"minAvailMB"] doubleValue]),
        @"verdict" : verdict,
    };
    // Asked, not assumed: -dataWithJSONObject: RAISES on an object it cannot encode rather than
    // returning nil, and a non-finite double is a perfectly good NSNumber that JSON has no
    // spelling for. RecordLooksSane checks classes, which does not catch a NaN in a corrupt
    // record -- and an exception here would be the launch crash that check exists to prevent.
    if (![NSJSONSerialization isValidJSONObject:entry])
        return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry
                                                   options:NSJSONWritingSortedKeys
                                                     error:NULL];
    if (!json)
        return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *existing = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    // nil means "no file yet" on every launch but one: the first. If the file is THERE and still
    // unreadable, writing over it would replace months of sessions with a single line and say
    // nothing -- so the bytes are kept under .bad, where a container listing will show them, and
    // collection restarts rather than stopping.
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!existing && [fm fileExistsAtPath:path]) {
        NSString *bad = [path stringByAppendingPathExtension:@"bad"];
        [fm removeItemAtPath:bad error:NULL];
        [fm moveItemAtPath:path toPath:bad error:NULL];
    }
    for (NSString *l in [existing componentsSeparatedByString:@"\n"]) {
        if (l.length)
            [lines addObject:l];
    }
    [lines addObject:line];
    if (lines.count > kHistoryEntries)
        [lines removeObjectsInRange:NSMakeRange(0, lines.count - kHistoryEntries)];

    // Rewritten whole rather than appended to: the trim needs the whole file in hand anyway, and
    // an atomic replace cannot leave a half-written line for the reader to choke on. Default file
    // protection, like the record -- the stricter classes buy a write on a locked device at the
    // cost of the READ this needs, and a launch happens on an unlocked one.
    NSString *out = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [[out dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path
                                                      options:NSDataWritingAtomic
                                                        error:NULL];
}

@implementation RMResidency

+ (void)beat {
    if (!sRecord)
        return;
    double avail = AvailMB();
    sRecord[@"beat"] = @([NSDate date].timeIntervalSince1970);
    sRecord[@"availMB"] = @(avail);
    double seen = [sRecord[@"minAvailMB"] doubleValue];
    if (avail < seen || seen == 0.0)
        sRecord[@"minAvailMB"] = @(avail);
    Persist();
}

+ (void)noteForeground {
    if (!sRecord)
        return;
    sRecord[@"state"] = @"foreground";
    [self beat];
}

+ (void)noteBackground {
    if (!sRecord)
        return;
    sRecord[@"state"] = @"background";
    // Beat immediately rather than waiting up to kBeatInterval: the transition itself is the
    // interesting moment, and a kill arriving seconds into the background is the common shape.
    [self beat];
}

+ (void)noteMemoryWarning {
    if (!sRecord)
        return;
    sRecord[@"memWarnings"] = @([sRecord[@"memWarnings"] intValue] + 1);
    [self beat];
}

+ (void)noteJitAttached {
    if (!sRecord)
        return;
    sRecord[@"jit"] = @YES;
    Persist();
}

+ (void)noteIdleGateReleased {
    if (!sRecord)
        return;
    sRecord[@"idleReleased"] = @YES;
    Persist();
}

+ (void)noteKeepaliveRearmed:(NSString *)reason {
    if (!sRecord)
        return;
    sRecord[@"rearms"] = @([sRecord[@"rearms"] intValue] + 1);
    // mutableCopy, because the literal sRecord is built from leaves its nested dictionary
    // immutable -- and a missing reason becomes a tag rather than a raised exception on nil.
    NSMutableDictionary *by = [sRecord[@"rearmsBy"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *tag = reason.length ? reason : @"untagged";
    by[tag] = @([by[tag] intValue] + 1);
    sRecord[@"rearmsBy"] = by;
    Persist();
}

+ (void)noteKeepaliveWindowBegan {
    if (!sRecord)
        return;
    // Mirrors ViewController's keepaliveIdleReleased exactly, which is the point: the record has to
    // mean "the gate was in force when this process died", not "the gate fired at some point".
    sRecord[@"idleReleased"] = @NO;
    Persist();
}

+ (void)noteCleanExit {
    if (!sRecord)
        return;
    sRecord[@"clean"] = @YES;
    sRecord[@"beat"] = @([NSDate date].timeIntervalSince1970);
    Persist();
}

+ (NSString *)recentSessions:(NSUInteger)count {
    NSString *path = HistoryPath();
    NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSData *json = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *e = line.length ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
        if (![e isKindOfClass:[NSDictionary class]] || ![e[@"started"] isKindOfClass:[NSString class]] ||
            ![e[@"verdict"] isKindOfClass:[NSString class]])
            continue;
        NSString *verdict = [e[@"verdict"] stringByReplacingOccurrencesOfString:@"[residency] previous session " withString:@""];
        [rows addObject:[NSString stringWithFormat:@"%@ %@\n", e[@"started"], verdict]];
    }
    if (!rows.count)
        return @"(none yet)\n";
    NSUInteger keep = MIN(count, rows.count);
    return [[rows subarrayWithRange:NSMakeRange(rows.count - keep, keep)] componentsJoinedByString:@""];
}

+ (NSString *)noteLaunchAndVerdict {
    NSString *path = RecordPath();
    NSDictionary *prev =
        path ? [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL]
             : nil;
    // Kept, because "no record" and "a record I refused" are different facts and the second one
    // is worth saying out loud: silently reported as a first run, it would read as the history
    // simply not having started yet.
    BOOL discarded = prev && !RecordLooksSane(prev);
    if (discarded)
        prev = nil;

    sStarted = [NSDate date].timeIntervalSince1970;
    sRecord = [@{
        @"start" : @(sStarted),
        @"beat" : @(sStarted),
        @"state" : @"foreground",
        @"availMB" : @(AvailMB()),
        @"minAvailMB" : @(AvailMB()),
        @"memWarnings" : @0,
        @"jit" : @NO,
        @"clean" : @NO,
        @"idleReleased" : @NO,
        @"rearms" : @0,
        @"rearmsBy" : @{},
    } mutableCopy];
    Persist();

    // The timer lives here rather than in the view controller so the interval stays next to the
    // constant that documents it. It keeps firing while backgrounded, which is the whole point --
    // the keepalive is what stops iOS suspending us, so a session that goes quiet in the record
    // went quiet because the process stopped, which is exactly the event being measured.
    [sBeat invalidate];
    sBeat = [NSTimer scheduledTimerWithTimeInterval:kBeatInterval
                                            repeats:YES
                                              block:^(NSTimer *t) {
                                                  [RMResidency beat];
                                              }];

    if (!prev) {
        if (discarded)
            return @"[residency] the previous session's record would not read as one and was "
                   @"discarded — this launch starts a fresh one";
        return nil; // first run on this install -- nothing to report, and nothing went wrong
    }

    double start = [prev[@"start"] doubleValue];
    double last = [prev[@"beat"] doubleValue];
    double lived = last - start;
    // Non-finite as well as negative: RecordLooksSane rejects a NaN, but two finite timestamps of
    // absurd magnitude still subtract to an infinity, which JSON cannot spell -- so the session
    // would vanish from the history without a word. Same answer as a clock that moved under us:
    // report the shape, not a nonsense duration.
    if (!isfinite(lived) || lived < 0)
        lived = 0;

    BOOL clean = [prev[@"clean"] boolValue];
    BOOL hadJit = [prev[@"jit"] boolValue];
    BOOL wasBg = [prev[@"state"] isEqualToString:@"background"];
    double minAvail = [prev[@"minAvailMB"] doubleValue];
    int warns = [prev[@"memWarnings"] intValue];
    BOOL idleReleased = [prev[@"idleReleased"] boolValue];
    int rearms = [prev[@"rearms"] intValue];

    // Rendered as the largest useful unit, because the number that matters is "did it last minutes
    // or hours" and a bare seconds count makes that harder to read, not easier.
    NSString *span = lived >= 3600 ? [NSString stringWithFormat:@"%.1fh", lived / 3600.0]
                     : lived >= 60 ? [NSString stringWithFormat:@"%.0fm", lived / 60.0]
                                   : [NSString stringWithFormat:@"%.0fs", lived];

    // "at least", unless iOS told us it was ending. Every other duration is measured to the last
    // beat, so the process outlived it by up to kBeatInterval -- and by arbitrarily more than that
    // if iOS SUSPENDED it first, because a suspended process fires no timer while staying
    // perfectly resident, CS_DEBUGGED and all. A session the idle gate released is exactly that
    // case, deliberately, so for those the number is a floor and not a close one.
    //
    // A clean one is not a floor in any sense that matters: noteCleanExit stamps the beat inside
    // applicationWillTerminate, so it misses only the milliseconds between that callback and the
    // process going away -- iOS allows a handful of seconds there at the outside, against a figure
    // rendered in seconds, minutes or tenths of an hour. Keeping the distinction is the point of
    // the word: one of these numbers was measured, the rest are lower bounds.
    NSString *lasted = clean ? @"lasted" : @"ran for at least";

    // WORDING IS LOAD-BEARING HERE. Only the clean case is evidence; every other branch is an
    // inference from a sample taken up to kBeatInterval before the process died, and a line that
    // reads as a verdict will later be quoted as one by someone who no longer remembers it was a
    // guess -- including me. So each inferred cause states what was observed and what it is
    // CONSISTENT WITH, never what happened. See the header for where ground truth actually lives.
    NSString *cause;
    NSString *klass;
    if (clean) {
        klass = @"clean";
        cause = @"ended cleanly — iOS reported it was terminating";
    } else if (warns > 0 || (minAvail > 0 && minAvail < kJetsamSuspicionMB)) {
        klass = @"jetsam-suspected";
        cause = [NSString
            stringWithFormat:@"terminated with no notice; headroom fell to %.0fMB with %d memory "
                             @"warning%@, which is consistent with jetsam",
                             minAvail, warns, warns == 1 ? @"" : @"s"];
    } else if (idleReleased && wasBg) {
        klass = @"idle-gate";
        // Ahead of the generic background branch on purpose: this is the design working. The gate
        // stops the keepalive once the game has been logged out in the background for a while,
        // precisely so iOS can suspend the JVM, so a kill after it is expected rather than a fault.
        cause = @"was released by the background idle gate (logged out, so the keepalive was "
                @"stopped on purpose) and then suspended or terminated — expected, not a fault";
    } else if (wasBg) {
        klass = @"background-unknown";
        // Explicitly NOT "so it was not memory": the sample only says headroom was fine when it
        // was last taken, and a footprint spike between samples is invisible to this record.
        cause = [NSString
            stringWithFormat:@"terminated with no notice in the background, %.0fMB free at the "
                             @"last sample — less like memory than the keepalive losing the "
                             @"process, though a spike between samples would not show here",
                             minAvail];
    } else {
        klass = @"foreground-unexpected";
        cause = [NSString
            stringWithFormat:@"terminated unexpectedly in the FOREGROUND, %.0fMB free at the last "
                             @"sample — usually a crash rather than residency, but this record "
                             @"cannot tell a crash from a kill",
                             minAvail];
    }

    // The cost clause is the point of the whole record: a death that had JIT is a death that makes
    // the user run the attach, and on cellular the airplane-mode sequence, all over again.
    // The re-arm count rides along rather than becoming its own branch: it is a property of the
    // session, not a cause of its death, and it is informative whatever ended the session. It
    // states that the keepalive STOPPED and names the events that stopped it; it does not call
    // that a dropped audio session, because a route change and a watchdog tick are not one.
    NSDictionary *by = prev[@"rearmsBy"];
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    for (NSString *tag in [by.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [reasons addObject:[NSString stringWithFormat:@"%@ %@", tag, by[tag]]];
    NSString *detail =
        reasons.count ? [@" — " stringByAppendingString:[reasons componentsJoinedByString:@", "]]
                      : @"";
    NSString *flaky =
        rearms > 0 ? [NSString stringWithFormat:@" (the keepalive stopped and was restarted %d×%@)",
                                                rearms, detail]
                   : @"";
    NSString *verdict = [NSString
        stringWithFormat:@"[residency] previous session %@ %@ and %@%@%@", lasted, span, cause,
                         flaky, hadJit ? @" — it held JIT, so this launch had to re-attach" : @""];
    AppendHistory(prev, lived, klass, verdict);
    return verdict;
}

@end
