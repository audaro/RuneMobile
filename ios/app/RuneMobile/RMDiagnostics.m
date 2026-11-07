#import "RMDiagnostics.h"
#import "JVMLauncher.h"
#import "RMHeat.h"
#import "RMRedact.h"
#import <sys/utsname.h>

// How much of each log goes in. The whole report stays near 1 MB, well under a Discord attachment.
static const unsigned long long kClientLogTail = 512 * 1024;
static const unsigned long long kShellLogTail = 192 * 1024;
static const unsigned long long kPrevShellLogTail = 96 * 1024;
static const unsigned long long kCrashReportHead = 96 * 1024;
static const NSTimeInterval kEngineWait = 3.0;

@implementation RMDiagnostics

#pragma mark - Share sheet

+ (void)shareFrom:(UIViewController *)presenter sourceView:(UIView *)source {
    UIAlertController *note = [UIAlertController
        alertControllerWithTitle:@"Share logs"
                         message:@"This makes a text file to post with your bug report: app and device versions, "
                                 @"your plugins, heat and battery readings, and recent log lines. Login tokens, "
                                 @"emails and your character name are taken out first."
                  preferredStyle:UIAlertControllerStyleAlert];
    [note addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [note addAction:[UIAlertAction actionWithTitle:@"Share"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                                               [self buildAndShareFrom:presenter sourceView:source];
                                           }]];
    [presenter presentViewController:note animated:YES completion:nil];
}

+ (void)buildAndShareFrom:(UIViewController *)presenter sourceView:(UIView *)source {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Preparing logs…"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    void (^build)(void) = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSURL *file = [self writeReport];
            dispatch_async(dispatch_get_main_queue(), ^{
                [wait dismissViewControllerAnimated:YES
                                         completion:^{
                                             [self presentShareOf:file from:presenter sourceView:source];
                                         }];
            });
        });
    };
    [presenter presentViewController:wait animated:YES completion:build];
}

// The share sheet for the finished file, or why there is none.
+ (void)presentShareOf:(nullable NSURL *)file from:(UIViewController *)presenter sourceView:(UIView *)source {
    if (!file) {
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"Couldn't make the log file"
                                                                      message:@"The phone may be out of space."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:fail animated:YES completion:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ file ]
                                                                        applicationActivities:nil];
    share.popoverPresentationController.sourceView = source;
    share.popoverPresentationController.sourceRect = source.bounds;
    [presenter presentViewController:share animated:YES completion:nil];
}

// The report in tmp/share-logs/, replacing any earlier one so they don't pile up.
+ (NSURL *)writeReport {
    NSString *text = [self reportText];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"share-logs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dir error:NULL];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL])
        return nil;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"RuneMobile-logs-%@.txt",
                                                                                    [f stringFromDate:[NSDate date]]]];
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        return nil;
    return [NSURL fileURLWithPath:path];
}

#pragma mark - Report

+ (NSString *)reportText {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *secrets = [NSMutableArray array];
    [RMRedact collectAccount:[NSData dataWithContentsOfFile:[JVMLauncher tokensPath]] names:names secrets:secrets];

    NSMutableString *r = [NSMutableString string];
    [r appendString:@"RuneMobile diagnostics report\n"];
    [r appendString:[self headerText]];

    [r appendString:@"\n== Engine ==\n"];
    [r appendString:[self engineTextAddingNames:names]];

    [r appendString:@"\n== Heat ==\n"];
    [r appendString:[RMHeatLog.shared report]];

    NSString *dir = [JVMLauncher appLogDir];
    [r appendString:@"\n== Crash reports ==\n"];
    [r appendString:[self crashReportsIn:dir]];

    [r appendString:@"\n== App log, this launch ==\n"];
    [r appendString:[self tailOf:[dir stringByAppendingPathComponent:@"hello-shell.log"] bytes:kShellLogTail]];
    [r appendString:@"\n== App log, previous launch ==\n"];
    [r appendString:[self tailOf:[dir stringByAppendingPathComponent:@"hello-shell.log.prev"] bytes:kPrevShellLogTail]];

    [r appendString:@"\n== RuneLite client.log ==\n"];
    [r appendString:[self clientLogIn:[dir stringByAppendingPathComponent:@".runelite/logs"]]];

    // Logs from an earlier session can still hold the name: say so rather than imply it was removed.
    if (names.count == 0)
        [r insertString:@"(No character name was found to take out: logged out, or the account file is unreadable. "
                        @"If your name appears below, remove it before you post this file.)\n"
                atIndex:[r rangeOfString:@"\n"].location + 1];

    return [RMRedact redact:r names:names secrets:secrets];
}

+ (NSString *)headerText {
    struct utsname sys;
    uname(&sys);
    NSBundle *b = [NSBundle mainBundle];
    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZ";
    static NSString *const thermal[] = {@"nominal", @"fair", @"serious", @"critical"};
    NSInteger t = pi.thermalState;
#if DEBUG
    NSString *config = @"debug";
#else
    NSString *config = @"release";
#endif
#if TARGET_OS_SIMULATOR
    NSString *where = @"iOS Simulator";
#else
    NSString *where = @"iOS";
#endif
    NSMutableString *h = [NSMutableString string];
    [h appendFormat:@"Made      %@\n", [f stringFromDate:[NSDate date]]];
    [h appendFormat:@"App       %@ (build %@, %@) on %@\n", [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                    [b objectForInfoDictionaryKey:@"CFBundleVersion"], config, where];
    // NSProcessInfo, not UIDevice: this runs off the main thread.
    NSOperatingSystemVersion os = pi.operatingSystemVersion;
    [h appendFormat:@"Device    %s | iOS %ld.%ld.%ld | %.1f GB RAM | thermal %@ | device up %.0f min\n", sys.machine,
                    (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion, pi.physicalMemory / 1073741824.0,
                    (t >= 0 && t < 4) ? thermal[t] : @"?", pi.systemUptime / 60.0];
    [h appendFormat:@"Renderer  %@ (chosen)\n",
                    [[NSUserDefaults standardUserDefaults] stringForKey:@"rendererPref"] ?: @"cpu"];
    [h appendFormat:@"JIT       %@\n", [self jitText]];
    return h;
}

+ (NSString *)jitText {
#if TARGET_OS_SIMULATOR
    return @"simulator (served in-process)";
#else
    static NSString *const checks[] = {@"not run", @"running", @"served by runelite-jit.js",
                                       @"unanswered (no script ran)", @"wrong answer (another script ran)"};
    RMJitScriptCheck c = [JVMLauncher jitScriptCheck];
    return [NSString stringWithFormat:@"debugged %@ | debugger attached now %@ | script check %@",
                                      [JVMLauncher isDebuggerAttached] ? @"yes" : @"no",
                                      [JVMLauncher isDebuggerTracing] ? @"yes" : @"no",
                                      (c >= 0 && c <= RMJitScriptCheckWrongAnswer) ? checks[c] : @"?"];
#endif
}

// The engine's section, and the names it reports to take out of the whole report.
+ (NSString *)engineTextAddingNames:(NSMutableArray<NSString *> *)names {
    if (![JVMLauncher vmStarted]) // not bridgeReady: that one caches the calling thread's env as the main one
        return @"(the game engine isn't running)\n";
    BOOL timedOut = NO;
    NSString *json = [JVMLauncher engineDiagnosticsJSONWaiting:kEngineWait timedOut:&timedOut];
    if (timedOut)
        return [NSString stringWithFormat:@"(the engine didn't answer within %.0f s: it may be frozen)\n", kEngineWait];
    NSDictionary *o = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0
                                                               error:NULL]
                           : nil;
    if (![o isKindOfClass:[NSDictionary class]] || ![o[@"text"] isKindOfClass:[NSString class]])
        return @"(the engine gave no report: an older build of the bridge)\n";
    for (id n in [o[@"names"] isKindOfClass:[NSArray class]] ? o[@"names"] : @[]) {
        if ([n isKindOfClass:[NSString class]])
            [names addObject:n];
    }
    return o[@"text"];
}

// crash.log (an uncaught Objective-C exception) and the newest VM crash report, each with its date.
+ (NSString *)crashReportsIn:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *crash = [dir stringByAppendingPathComponent:@"crash.log"];
    if ([fm fileExistsAtPath:crash])
        [paths addObject:crash];
    NSString *newestVm = nil;
    NSDate *newestDate = nil;
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if (![name hasPrefix:@"hs_err_pid"] || ![name hasSuffix:@".log"])
            continue;
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSDate *d = [fm attributesOfItemAtPath:p error:NULL].fileModificationDate;
        if (d && (!newestDate || [d compare:newestDate] == NSOrderedDescending)) {
            newestDate = d;
            newestVm = p;
        }
    }
    if (newestVm)
        [paths addObject:newestVm];
    if (!paths.count)
        return @"(none)\n";
    NSMutableString *out = [NSMutableString string];
    for (NSString *p in paths) {
        NSDate *d = [fm attributesOfItemAtPath:p error:NULL].fileModificationDate;
        [out appendFormat:@"-- %@, written %@ --\n", p.lastPathComponent, d ?: @"?"];
        [out appendString:[self headOf:p bytes:kCrashReportHead]];
    }
    return out;
}

// client.log's tail, plus the newest rolled-over file when today's is short (it rolls at midnight).
+ (NSString *)clientLogIn:(NSString *)logs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *current = [logs stringByAppendingPathComponent:@"client.log"];
    unsigned long long size = [fm attributesOfItemAtPath:current error:NULL].fileSize;
    NSMutableString *out = [NSMutableString string];
    if (size < kClientLogTail / 2) {
        NSString *rolled = nil;
        NSDate *rolledDate = nil;
        for (NSString *name in [fm contentsOfDirectoryAtPath:logs error:NULL]) {
            if (![name hasPrefix:@"client_"] || ![name hasSuffix:@".log"])
                continue;
            NSString *p = [logs stringByAppendingPathComponent:name];
            NSDate *d = [fm attributesOfItemAtPath:p error:NULL].fileModificationDate;
            if (d && (!rolledDate || [d compare:rolledDate] == NSOrderedDescending)) {
                rolledDate = d;
                rolled = p;
            }
        }
        if (rolled) {
            [out appendFormat:@"-- %@ --\n", rolled.lastPathComponent];
            [out appendString:[self tailOf:rolled bytes:kClientLogTail / 2]];
            [out appendString:@"-- client.log --\n"];
        }
    }
    [out appendString:[self tailOf:current bytes:kClientLogTail]];
    return out;
}

#pragma mark - Files

// The last `bytes` of a file, starting at a line, or a note saying why there is nothing.
+ (NSString *)tailOf:(NSString *)path bytes:(unsigned long long)bytes {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h)
        return @"(no file)\n";
    unsigned long long size = [h seekToEndOfFile];
    unsigned long long from = size > bytes ? size - bytes : 0;
    [h seekToFileOffset:from];
    NSData *data = [h readDataToEndOfFile];
    [h closeFile];
    if (data.length == 0)
        return @"(empty)\n";
    if (from > 0) {
        NSRange nl = [data rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, data.length)];
        if (nl.location != NSNotFound)
            data = [data subdataWithRange:NSMakeRange(NSMaxRange(nl), data.length - NSMaxRange(nl))];
    }
    NSString *s = [self decode:data];
    NSString *cut = from > 0 ? [NSString stringWithFormat:@"(last %llu KB of %llu KB)\n", bytes >> 10, size >> 10] : @"";
    return [NSString stringWithFormat:@"%@%@%@", cut, s, [s hasSuffix:@"\n"] ? @"" : @"\n"];
}

+ (NSString *)headOf:(NSString *)path bytes:(unsigned long long)bytes {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h)
        return @"(unreadable)\n";
    NSData *data = [h readDataOfLength:(NSUInteger)bytes];
    unsigned long long size = [h seekToEndOfFile];
    [h closeFile];
    NSString *s = [self decode:data];
    return [NSString stringWithFormat:@"%@%@%@", s, [s hasSuffix:@"\n"] ? @"" : @"\n",
                                      size > bytes ? [NSString stringWithFormat:@"(first %llu KB of %llu KB)\n",
                                                                                bytes >> 10, size >> 10]
                                                   : @""];
}

// UTF-8, or Latin-1 when a byte sequence isn't valid UTF-8 (a cut multi-byte character), so a log is never lost.
+ (NSString *)decode:(NSData *)data {
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
               ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

@end
