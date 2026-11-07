#import "RMMemoryTrail.h"

#import "JVMLauncher.h"

#import <mach/mach.h>
#import <malloc/malloc.h>
#import <os/proc.h>
#import <time.h>

static const uint64_t kIntervalSec = 60;
// A little under the interval, so a sleep that wakes a moment early doesn't skip a line.
static const uint64_t kMinGapSec = 55;
// Six hours. Whole-file writes of this much once a minute cost nothing, and an atomic replace can't leave a half line.
static const NSUInteger kKeepLines = 360;
// A report carries the last two hours of a trail: enough to see a climb, without burying the rest of the file.
static const NSUInteger kReportLines = 120;
// A launch that dies inside five minutes says nothing about a slow climb, so it doesn't push out the one before it.
static const NSUInteger kLinesWorthKeeping = 5;

static NSMutableArray<NSString *> *sLines; // sLines[0] says when the session started
static uint64_t sStartNs;
static uint64_t sLastNs;

static NSString *TrailPath(void) {
    return [[JVMLauncher appLogDir] stringByAppendingPathComponent:@"memory-trail.log"];
}

static NSString *PreviousPath(void) {
    return [TrailPath() stringByAppendingString:@".prev"];
}

static NSArray<NSString *> *LinesOf(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
        if (l.length)
            [lines addObject:l];
    }
    return lines;
}

static void Write(void) {
    NSString *text = [[sLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [text writeToFile:TrailPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

// The thread count, or -1. task_threads hands over a send right per thread and the array itself.
static int ThreadCount(void) {
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
        return -1;
    for (mach_msg_type_number_t i = 0; i < count; i++)
        mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    return (int)count;
}

void RMMemoryTrailStart(void) {
    NSString *current = TrailPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (LinesOf(current).count > kLinesWorthKeeping) {
        [fm removeItemAtPath:PreviousPath() error:NULL];
        [fm moveItemAtPath:current toPath:PreviousPath() error:NULL];
    }
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZ";
    NSBundle *b = [NSBundle mainBundle];
    NSString *renderer = [[NSUserDefaults standardUserDefaults] stringForKey:@"rendererPref"] ?: @"cpu";
    sLines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"-- session started %@, app %@, renderer %@ --",
                                                                        [f stringFromDate:[NSDate date]],
                                                                        [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                                                                        renderer]];
    sStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    Write();
}

void RMMemoryTrailSample(long heapUsedMB, long heapCommittedMB) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (!sLines || (sLastNs && now - sLastNs < kMinGapSec * NSEC_PER_SEC))
        return;
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS)
        return;
    sLastNs = now;
    // Asked, because an older kernel fills in less of the struct and says how much.
    BOOL ledgers = count >= TASK_VM_INFO_REV3_COUNT;
    uint64_t gfx = ledgers ? (uint64_t)(vm.ledger_tag_graphics_footprint + vm.ledger_tag_graphics_footprint_compressed) : 0;
    uint64_t media = ledgers ? (uint64_t)(vm.ledger_tag_media_footprint + vm.ledger_tag_media_footprint_compressed) : 0;
    malloc_statistics_t zones = {0};
    malloc_zone_statistics(NULL, &zones);
    NSString *heap = heapCommittedMB < 0 ? @"-" : [NSString stringWithFormat:@"%ld/%ld", heapUsedMB, heapCommittedMB];
    [sLines addObject:[NSString stringWithFormat:@"t=%llum fp=%llu free=%zu gfx=%llu media=%llu malloc=%zu heap=%@ threads=%d",
                                                 (now - sStartNs + 30 * NSEC_PER_SEC) / (60 * NSEC_PER_SEC), vm.phys_footprint >> 20,
                                                 os_proc_available_memory() >> 20, gfx >> 20, media >> 20,
                                                 zones.size_in_use >> 20, heap, ThreadCount()]];
    if (sLines.count > kKeepLines + 1)
        [sLines removeObjectAtIndex:1];
    Write();
}

NSString *RMMemoryTrailReport(void) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *path in @[ PreviousPath(), TrailPath() ]) {
        NSArray<NSString *> *lines = LinesOf(path);
        if (!lines.count)
            continue;
        [out appendFormat:@"%@\n", lines.firstObject];
        NSUInteger samples = lines.count - 1;
        if (samples > kReportLines)
            [out appendFormat:@"(last %lu of %lu lines)\n", (unsigned long)kReportLines, (unsigned long)samples];
        NSUInteger first = lines.count - MIN(samples, kReportLines);
        for (NSUInteger i = first; i < lines.count; i++)
            [out appendFormat:@"%@\n", lines[i]];
    }
    return out.length ? out : @"(none yet: a trail starts when the game does)\n";
}
