#import "RMMemoryTrail.h"

#import "JVMLauncher.h"

#import <mach/mach.h>
#import <malloc/malloc.h>
#import <os/proc.h>
#import <time.h>
#if DEBUG
#import <dlfcn.h>
#import <objc/runtime.h>
#import <pthread.h>
#endif

static const uint64_t kIntervalSec = 60;
// A little under the interval, so a sleep that wakes a moment early doesn't skip a line.
static const uint64_t kMinGapSec = 55;
// A sample is its "t=" line plus the indented lines under it. Six hours of them: whole-file writes of this much once a
// minute cost nothing, and an atomic replace can't leave a half line.
static const NSUInteger kKeepSamples = 360;
// A report carries the last two hours of a trail: enough to see a climb, without burying the rest of the file.
static const NSUInteger kReportSamples = 120;
// A launch that dies inside five minutes says nothing about a slow climb, so it doesn't push out the one before it.
static const NSUInteger kSamplesWorthKeeping = 5;
// The zones line leaves out zones holding less than this.
static const size_t kZoneFloorBytes = 1 << 20;

static NSMutableArray<NSString *> *sLines; // sLines[0] says when the session started
static NSUInteger sSamples;                // the "t=" lines in sLines
static uint64_t sStartNs;
static uint64_t sLastNs;

static NSString *TrailPath(void) {
    return [[JVMLauncher appLogDir] stringByAppendingPathComponent:@"memory-trail.log"];
}

static NSString *PreviousPath(void) {
    return [TrailPath() stringByAppendingString:@".prev"];
}

static BOOL IsSample(NSString *line) {
    return [line hasPrefix:@"t="];
}

static NSUInteger SamplesIn(NSArray<NSString *> *lines) {
    NSUInteger n = 0;
    for (NSString *l in lines)
        n += IsSample(l);
    return n;
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

// A block count to read at a glance: 950k, or the number itself under ten thousand.
static NSString *Blocks(uint64_t n) {
    return n >= 10000 ? [NSString stringWithFormat:@"%lluk", (n + 500) / 1000] : [NSString stringWithFormat:@"%llu", n];
}

// malloc's introspection calls read through a reader, written for a tool in another process. In this one the memory is
// already here.
static kern_return_t SelfReader(task_t task, vm_address_t address, vm_size_t size, void **local) {
    (void)task;
    (void)size;
    *local = (void *)address;
    return KERN_SUCCESS;
}

// MB/blocks for every zone holding a megabyte or more. Most of the process shares the default zones (the JVM, our own
// code, most of the frameworks), so a zone of its own climbing names who is allocating.
static NSString *ZonesLine(void) {
    vm_address_t *zones = NULL;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), SelfReader, &zones, &count) != KERN_SUCCESS)
        return @"   zones (unreadable)";
    NSMutableString *line = [NSMutableString stringWithString:@"   zones"];
    for (unsigned i = 0; i < count; i++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[i];
        malloc_statistics_t st = {0};
        malloc_zone_statistics(zone, &st);
        if (st.size_in_use < kZoneFloorBytes)
            continue;
        const char *name = malloc_get_zone_name(zone);
        [line appendFormat:@" %s %zu/%@", name ?: "unnamed", st.size_in_use >> 20, Blocks(st.blocks_in_use)];
    }
    return line;
}

#if DEBUG
// What the live blocks are, from a walk of every block in malloc's own zones. Debug builds only until a phone run
// shows what a walk costs: each zone is locked while it is walked, so every malloc in it waits. The recorder only
// counts into memory set aside beforehand, because a malloc in a zone this thread holds would never return. Other
// zones (WebKit's, say) still show in the zones line; their walkers aren't written for a reader in their own process.
//   sizes   MB/blocks by block size, every minute
//   objc    the classes holding the most bytes, every fifth minute, matched by the class pointer at the start of a
//           block. Not exact: a raw buffer that happens to start with a class's address counts as that class.
//   pools   autorelease pool pages by the thread that owns them, every minute. A page holds about 500 autoreleased
//           objects, so a thread that autoreleases and never pops a pool grows a chain of them.
//   strings Swift's string objects, every minute: how many, and the commonest texts among a sample of them.
//   stack   where the thread with the most pool pages is, in a dozen samples, every minute
static const vm_size_t kBucketTop[] = {256, 1024, 4096, 16384, 65536, 262144, 1048576, (vm_size_t)-1};
static const char *const kBucketName[] = {"<=256", "<=1K", "<=4K", "<=16K", "<=64K", "<=256K", "<=1M", ">1M"};
enum { kBuckets = sizeof kBucketTop / sizeof kBucketTop[0],
       kTopClasses = 10,
       kPoolThreads = 32,
       kTopPools = 4,
       kStringSamples = 256,
       kStringSampleBytes = 40,
       kTopStrings = 6 };
static const uint64_t kClassEveryMin = 5;

// objc4's AutoreleasePoolPage starts with magic_t (0xA1A1A1A1 then "AUTORELEASE!"), then next, thread, parent,
// child, depth. Pages are PAGE_MIN_SIZE (4 KB on arm64) unless the runtime protects them, which uses 16 KB.
static const uint32_t kPoolMagic = 0xA1A1A1A1;
static const size_t kPoolThreadOffset = 24, kPoolDepthOffset = 48;
// Swift's __StringStorage on 64-bit: isa, refcount, capacity and flags, then count and flags (the count is the low
// 48 bits), then the UTF-8 text.
static const size_t kStringCountOffset = 24, kStringTextOffset = 32;

typedef struct {
    uintptr_t thread;
    uint64_t pages;
    uint32_t depth;
} PoolThread;

typedef struct {
    uint64_t length;
    char text[kStringSampleBytes];
} StringSample;

typedef struct {
    uint64_t bytes[kBuckets];
    uint64_t blocks[kBuckets];
    BOOL classes;
    PoolThread pools[kPoolThreads];
    unsigned poolThreads;
    uint64_t poolPages, poolPagesUnplaced;
    uintptr_t stringClass;
    uint64_t strings, stringBytes, stringEvery;
    StringSample samples[kStringSamples];
    unsigned sampled;
} Census;

// Every class the runtime knows, in an open-addressed table at most half full; a block's counts go to its class's slot.
static uintptr_t *sClassSlots;
static uint64_t *sClassBytes;
static uint64_t *sClassBlocks;
static size_t sClassMask;
static uintptr_t sIsaMask;

static inline size_t SlotHash(uintptr_t p) {
    return (size_t)(((uint64_t)p * 0x9E3779B97F4A7C15ull) >> 29);
}

static inline long SlotOf(uintptr_t cls) {
    for (size_t i = SlotHash(cls) & sClassMask;; i = (i + 1) & sClassMask) {
        if (sClassSlots[i] == cls)
            return (long)i;
        if (sClassSlots[i] == 0)
            return -1;
    }
}

// Once. objc_copyClassList realizes every class in the process, which costs a one-off step in malloc and some time.
static NSString *IndexClasses(void) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    size_t slots = 1;
    while (slots < (size_t)n * 2)
        slots <<= 1;
    sClassSlots = list ? calloc(slots, sizeof *sClassSlots) : NULL;
    sClassBytes = calloc(slots, sizeof *sClassBytes);
    sClassBlocks = calloc(slots, sizeof *sClassBlocks);
    if (!sClassSlots || !sClassBytes || !sClassBlocks) {
        free(list);
        free(sClassSlots);
        free(sClassBytes);
        free(sClassBlocks);
        sClassSlots = NULL;
        return @"class index failed";
    }
    sClassMask = slots - 1;
    for (unsigned i = 0; i < n; i++) {
        uintptr_t cls = (uintptr_t)list[i];
        size_t j = SlotHash(cls) & sClassMask;
        while (sClassSlots[j] != 0 && sClassSlots[j] != cls)
            j = (j + 1) & sClassMask;
        sClassSlots[j] = cls;
    }
    free(list);
    return [NSString stringWithFormat:@"indexed %u classes in %llu ms", n,
                                      (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / NSEC_PER_MSEC];
}

// Once, before the first walk: anything that may allocate has to happen outside the zone locks.
static uintptr_t sStringClass;
static void PrepareWalks(void) {
    static BOOL done;
    if (done)
        return;
    done = YES;
    // The runtime exports the mask that strips a non-pointer isa down to its class; the fallbacks are objc4's.
    const uintptr_t *mask = dlsym(RTLD_DEFAULT, "objc_debug_isa_class_mask");
#if TARGET_OS_SIMULATOR
    sIsaMask = mask ? *mask : 0x007ffffffffffff8ull;
#else
    sIsaMask = mask ? *mask : 0x0000000ffffffff8ull;
#endif
    Class s = objc_lookUpClass("_TtCs15__StringStorage") ?: objc_lookUpClass("Swift.__StringStorage");
    sStringClass = (uintptr_t)(__bridge void *)s;
}

static inline void CountPoolPage(Census *c, const uint8_t *page) {
    uintptr_t thread = *(const uintptr_t *)(page + kPoolThreadOffset);
    uint32_t depth = *(const uint32_t *)(page + kPoolDepthOffset);
    c->poolPages++;
    for (unsigned k = 0; k < c->poolThreads; k++) {
        if (c->pools[k].thread == thread) {
            c->pools[k].pages++;
            c->pools[k].depth = MAX(c->pools[k].depth, depth);
            return;
        }
    }
    if (c->poolThreads == kPoolThreads) {
        c->poolPagesUnplaced++;
        return;
    }
    c->pools[c->poolThreads++] = (PoolThread){thread, 1, depth};
}

static inline void CountString(Census *c, const uint8_t *object, vm_size_t size) {
    c->strings++;
    c->stringBytes += size;
    if (c->sampled == kStringSamples || c->strings % c->stringEvery != 0)
        return;
    uint64_t length = *(const uint64_t *)(object + kStringCountOffset) & 0x0000ffffffffffffull;
    if (length >= size - kStringTextOffset)
        return; // not laid out the way this build expects; leave it out rather than read past the block
    StringSample *s = &c->samples[c->sampled++];
    s->length = length;
    memcpy(s->text, object + kStringTextOffset, MIN(length, (uint64_t)kStringSampleBytes));
}

static void CountRanges(task_t task, void *context, unsigned type, vm_range_t *ranges, unsigned count) {
    (void)task;
    (void)type;
    Census *c = context;
    for (unsigned i = 0; i < count; i++) {
        vm_size_t size = ranges[i].size;
        unsigned b = 0;
        while (size > kBucketTop[b])
            b++;
        c->bytes[b] += size;
        c->blocks[b]++;
        if (size < sizeof(uintptr_t))
            continue;
        const uint8_t *p = (const uint8_t *)ranges[i].address;
        uintptr_t cls = *(const uintptr_t *)p & sIsaMask;
        if (size >= 4096 && size <= 16384 && *(const uint32_t *)p == kPoolMagic && !memcmp(p + 4, "AUTORELEASE!", 12))
            CountPoolPage(c, p);
        else if (cls && cls == c->stringClass && size > kStringTextOffset)
            CountString(c, p, size);
        if (c->classes && cls) {
            long slot = SlotOf(cls);
            if (slot >= 0) {
                sClassBytes[slot] += size;
                sClassBlocks[slot]++;
            }
        }
    }
}

// Image constructors run on the main thread, before main().
static pthread_t sMainThread;
__attribute__((constructor)) static void NoteMainThread(void) {
    sMainThread = pthread_self();
}

// "Java: Client (4120p, depth 4119)": the owning thread's name, read only if the thread still exists.
static NSString *PoolsLine(Census *c) {
    if (!c->poolThreads)
        return @"   pools none found";
    NSMutableArray<NSString *> *owners = [NSMutableArray array];
    BOOL picked[kPoolThreads] = {NO};
    for (unsigned k = 0; k < kTopPools; k++) {
        int best = -1;
        for (unsigned i = 0; i < c->poolThreads; i++)
            if (!picked[i] && (best < 0 || c->pools[i].pages > c->pools[best].pages))
                best = (int)i;
        if (best < 0)
            break;
        picked[best] = YES;
        PoolThread *t = &c->pools[best];
        // pthread_getname_np and pthread_threadid_np check the thread list first and fail on a thread that is gone.
        char name[64] = "";
        uint64_t tid = 0;
        pthread_t pt = (pthread_t)t->thread;
        BOOL alive = pt && pthread_threadid_np(pt, &tid) == 0; // a null thread would read as this one
        if (alive)
            alive = pthread_getname_np(pt, name, sizeof name) == 0; // it can exit between the two calls
        NSString *who = !alive              ? [NSString stringWithFormat:@"exited thread 0x%lx", (unsigned long)t->thread]
                        : pt == sMainThread ? @"main"
                        : name[0]           ? [NSString stringWithFormat:@"\"%s\"", name]
                                            : [NSString stringWithFormat:@"unnamed tid %llu", tid];
        [owners addObject:[NSString stringWithFormat:@"%@ %llup depth %u", who, t->pages, t->depth]];
    }
    NSMutableString *line = [NSMutableString
        stringWithFormat:@"   pools %llu pages: %@", c->poolPages, [owners componentsJoinedByString:@", "]];
    if (c->poolPagesUnplaced)
        [line appendFormat:@" (+%llu pages on other threads)", c->poolPagesUnplaced];
    return line;
}

// The stack of the thread holding the most pool pages, sampled a few times: a pools line can only give an unnamed
// thread's id, and the frames say whose thread it is even while it sleeps. Nothing but Mach calls run while the
// thread is stopped, because it may hold malloc's lock; the names are looked up after it runs again.
enum { kStackFrames = 28,
       kStackSamples = 12,
       kStackMinPages = 64,
       kStackShown = 3 };

typedef struct {
    uintptr_t pc[kStackFrames];
    unsigned frames, seen;
} StackSample;

static unsigned CaptureStack(thread_t th, uintptr_t *pc) {
    unsigned n = 0;
    if (thread_suspend(th) != KERN_SUCCESS)
        return 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        const uintptr_t kAddressBits = 0x0000007FFFFFFFFFul; // drops a pointer signature, if there is one
        pc[n++] = (uintptr_t)arm_thread_state64_get_pc(st) & kAddressBits;
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        while (n < kStackFrames && fp) {
            uintptr_t frame[2];
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), fp, sizeof frame, (vm_address_t)frame, &got) != KERN_SUCCESS ||
                got != sizeof frame)
                break;
            if (frame[1])
                pc[n++] = frame[1] & kAddressBits;
            if (frame[0] <= fp)
                break;
            fp = frame[0];
        }
    }
    thread_resume(th);
    return n;
}

// "libobjc.A.dylib objc_autorelease+132 (0x1fea4)": the nearest exported symbol, which inside a system framework can
// be a neighbour of the real function, so the offset into the image is there to look it up properly.
static NSString *FrameName(uintptr_t pc) {
    Dl_info info;
    if (!dladdr((void *)pc, &info) || !info.dli_fname)
        return [NSString stringWithFormat:@"0x%lx", (unsigned long)pc];
    const char *slash = strrchr(info.dli_fname, '/');
    const char *image = slash ? slash + 1 : info.dli_fname;
    unsigned long inImage = (unsigned long)(pc - (uintptr_t)info.dli_fbase);
    if (!info.dli_sname)
        return [NSString stringWithFormat:@"%s (0x%lx)", image, inImage];
    return [NSString stringWithFormat:@"%s %s+%lu (0x%lx)", image, info.dli_sname,
                                      (unsigned long)(pc - (uintptr_t)info.dli_saddr), inImage];
}

static NSArray<NSString *> *StackLines(Census *c) {
    PoolThread *top = NULL;
    for (unsigned i = 0; i < c->poolThreads; i++)
        if (!top || c->pools[i].pages > top->pages)
            top = &c->pools[i];
    pthread_t pt = top ? (pthread_t)top->thread : NULL;
    uint64_t tid = 0;
    if (!pt || top->pages < kStackMinPages || pt == pthread_self() || pthread_threadid_np(pt, &tid) != 0)
        return @[];
    thread_t th = pthread_mach_thread_np(pt);
    if (!th)
        return @[];
    static StackSample stacks[kStackSamples]; // only the trail's own thread comes here
    unsigned distinct = 0, taken = 0;
    for (unsigned s = 0; s < kStackSamples; s++) {
        uintptr_t pc[kStackFrames];
        unsigned n = CaptureStack(th, pc);
        if (n) {
            taken++;
            unsigned k = 0;
            while (k < distinct && (stacks[k].frames != n || memcmp(stacks[k].pc, pc, n * sizeof *pc) != 0))
                k++;
            if (k == distinct) {
                memcpy(stacks[k].pc, pc, n * sizeof *pc);
                stacks[k].frames = n;
                stacks[k].seen = 0;
                distinct++;
            }
            stacks[k].seen++;
        }
        usleep(7000);
    }
    if (!taken)
        return @[ [NSString stringWithFormat:@"   stack tid %llu: could not be read", tid] ];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    BOOL picked[kStackSamples] = {NO};
    for (unsigned shown = 0; shown < kStackShown; shown++) {
        int best = -1;
        for (unsigned k = 0; k < distinct; k++)
            if (!picked[k] && (best < 0 || stacks[k].seen > stacks[best].seen))
                best = (int)k;
        if (best < 0)
            break;
        picked[best] = YES;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned f = 0; f < stacks[best].frames; f++)
            [names addObject:FrameName(stacks[best].pc[f])];
        [lines addObject:[NSString stringWithFormat:@"   stack tid %llu x%u of %u: %@", tid, stacks[best].seen, taken,
                                                    [names componentsJoinedByString:@" < "]]];
    }
    return lines;
}

static int CompareSamples(const void *a, const void *b) {
    const StringSample *x = a, *y = b;
    if (x->length != y->length)
        return x->length < y->length ? -1 : 1;
    return memcmp(x->text, y->text, MIN(x->length, (uint64_t)kStringSampleBytes));
}

// "strings 5766k 271 MB: "some text" x40, ...": the texts are cut at 40 bytes, with anything unprintable as '.'.
static NSString *StringsLine(Census *c) {
    if (!c->stringClass)
        return @"   strings (no Swift string class in this process)";
    NSMutableString *line = [NSMutableString
        stringWithFormat:@"   strings %@ %.1f MB, %u sampled:", Blocks(c->strings), c->stringBytes / 1048576.0, c->sampled];
    qsort(c->samples, c->sampled, sizeof c->samples[0], CompareSamples);
    unsigned runStart[kStringSamples], runLength[kStringSamples], runs = 0;
    for (unsigned i = 0; i < c->sampled; i++) {
        if (i == 0 || CompareSamples(&c->samples[i - 1], &c->samples[i]) != 0) {
            runStart[runs] = i;
            runLength[runs++] = 0;
        }
        runLength[runs - 1]++;
    }
    for (unsigned k = 0; k < kTopStrings && runs; k++) {
        unsigned best = 0;
        for (unsigned r = 1; r < runs; r++)
            if (runLength[r] > runLength[best])
                best = r;
        if (!runLength[best])
            break;
        StringSample *s = &c->samples[runStart[best]];
        char text[kStringSampleBytes + 1];
        unsigned n = (unsigned)MIN(s->length, (uint64_t)kStringSampleBytes);
        for (unsigned i = 0; i < n; i++)
            text[i] = (s->text[i] >= 0x20 && s->text[i] < 0x7f && s->text[i] != '"') ? s->text[i] : '.';
        text[n] = 0;
        [line appendFormat:@" \"%s\"%s (%llu) x%u", text, s->length > kStringSampleBytes ? "..." : "", s->length,
                           runLength[best]];
        runLength[best] = 0;
    }
    return line;
}

static BOOL IsMallocsOwnZone(const char *name) {
    return name && (!strcmp(name, "DefaultMallocZone") || !strcmp(name, "MallocHelperZone") ||
                    !strcmp(name, "DefaultPurgeableMallocZone"));
}

// The walk's lines, after the sample line; minute picks whether the classes are counted this time.
static NSArray<NSString *> *CensusLines(uint64_t minute) {
    static NSString *indexNote;
    static BOOL noted;
    // From the third minute, once boot is over, then every fifth. Two samples can round to the same minute, so this
    // counts from the last census rather than matching minute numbers.
    static uint64_t classesDue = 3;
    // Spread the string sample over the whole walk: one in every (last walk's count / samples).
    static uint64_t lastStrings;
    Census c;
    memset(&c, 0, sizeof c);
    PrepareWalks();
    c.stringClass = sStringClass;
    c.stringEvery = MAX(1, lastStrings / kStringSamples);
    if (minute >= classesDue) {
        classesDue = minute + kClassEveryMin;
        if (!sClassSlots && !indexNote)
            indexNote = IndexClasses();
        if (sClassSlots) {
            memset(sClassBytes, 0, (sClassMask + 1) * sizeof *sClassBytes);
            memset(sClassBlocks, 0, (sClassMask + 1) * sizeof *sClassBlocks);
            c.classes = YES;
        }
    }
    vm_address_t *all = NULL;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), SelfReader, &all, &count) != KERN_SUCCESS)
        return @[ @"   sizes (zones unreadable)" ];
    malloc_zone_t *zones[16];
    unsigned walk = 0;
    for (unsigned i = 0; i < count && walk < 16; i++) {
        malloc_zone_t *zone = (malloc_zone_t *)all[i];
        malloc_introspection_t *in = zone->introspect;
        if (IsMallocsOwnZone(malloc_get_zone_name(zone)) && in && in->enumerator && in->force_lock && in->force_unlock)
            zones[walk++] = zone;
    }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), worst = 0;
    for (unsigned i = 0; i < walk; i++) {
        uint64_t z0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        malloc_introspection_t *in = zones[i]->introspect;
        in->force_lock(zones[i]);
        in->enumerator(mach_task_self(), &c, MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zones[i], SelfReader,
                       CountRanges);
        in->force_unlock(zones[i]);
        worst = MAX(worst, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - z0);
    }
    uint64_t took = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;

    NSMutableString *sizes = [NSMutableString stringWithString:@"   sizes"];
    for (unsigned b = 0; b < kBuckets; b++)
        [sizes appendFormat:@" %s %.1f/%@", kBucketName[b], c.bytes[b] / 1048576.0, Blocks(c.blocks[b])];
    [sizes appendFormat:@" (walked %u zones in %llu ms, longest lock %llu ms)", walk, took / NSEC_PER_MSEC,
                        worst / NSEC_PER_MSEC];
    lastStrings = c.strings;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObjects:sizes, PoolsLine(&c), StringsLine(&c), nil];
    [lines addObjectsFromArray:StackLines(&c)];
    if (c.classes) {
        NSMutableString *objc = [NSMutableString stringWithString:@"   objc"];
        size_t picked[kTopClasses];
        for (unsigned k = 0; k < kTopClasses; k++) {
            size_t best = SIZE_MAX;
            for (size_t i = 0; i <= sClassMask; i++) {
                if (!sClassBytes[i] || (best != SIZE_MAX && sClassBytes[i] <= sClassBytes[best]))
                    continue;
                BOOL dup = NO;
                for (unsigned j = 0; j < k && !dup; j++)
                    dup = picked[j] == i;
                if (!dup)
                    best = i;
            }
            if (best == SIZE_MAX)
                break;
            picked[k] = best;
            [objc appendFormat:@" %s %.1f/%@", class_getName((__bridge Class)(void *)sClassSlots[best]), sClassBytes[best] / 1048576.0,
                               Blocks(sClassBlocks[best])];
        }
        [lines addObject:objc];
    }
    if (indexNote && !noted) {
        [lines addObject:[@"   objc " stringByAppendingString:indexNote]];
        noted = YES;
    }
    return lines;
}
#endif

void RMMemoryTrailStart(void) {
    NSString *current = TrailPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (SamplesIn(LinesOf(current)) > kSamplesWorthKeeping) {
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
    sSamples = 0;
    sStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    Write();
}

void RMMemoryTrailSample(long heapUsedMB, long heapCommittedMB, long directMB) {
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
    NSString *direct = directMB < 0 ? @"-" : [NSString stringWithFormat:@"%ld", directMB];
    uint64_t minute = (now - sStartNs + 30 * NSEC_PER_SEC) / (60 * NSEC_PER_SEC);
    [sLines addObject:[NSString stringWithFormat:@"t=%llum fp=%llu free=%zu gfx=%llu media=%llu malloc=%zu blocks=%@ heap=%@ "
                                                 @"direct=%@ threads=%d",
                                                 minute, vm.phys_footprint >> 20, os_proc_available_memory() >> 20,
                                                 gfx >> 20, media >> 20, zones.size_in_use >> 20,
                                                 Blocks(zones.blocks_in_use), heap, direct, ThreadCount()]];
    [sLines addObject:ZonesLine()];
#if DEBUG
    [sLines addObjectsFromArray:CensusLines(minute)];
#endif
    sSamples++;
    while (sSamples > kKeepSamples) {
        // The oldest sample goes with the indented lines under it.
        [sLines removeObjectAtIndex:1];
        while (sLines.count > 1 && !IsSample(sLines[1]))
            [sLines removeObjectAtIndex:1];
        sSamples--;
    }
    Write();
}

NSString *RMMemoryTrailReport(void) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *path in @[ PreviousPath(), TrailPath() ]) {
        NSArray<NSString *> *lines = LinesOf(path);
        if (!lines.count)
            continue;
        [out appendFormat:@"%@\n", lines.firstObject];
        NSUInteger samples = SamplesIn(lines), first = 1;
        if (samples > kReportSamples) {
            [out appendFormat:@"(last %lu of %lu samples)\n", (unsigned long)kReportSamples, (unsigned long)samples];
            // Skip to the first sample the report keeps.
            for (NSUInteger skip = samples - kReportSamples; skip > 0 || !IsSample(lines[first]); first++)
                skip -= IsSample(lines[first]);
        }
        for (NSUInteger i = first; i < lines.count; i++)
            [out appendFormat:@"%@\n", lines[i]];
    }
    return out.length ? out : @"(none yet: a trail starts when the game does)\n";
}
