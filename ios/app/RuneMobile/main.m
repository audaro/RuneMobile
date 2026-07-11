#import <UIKit/UIKit.h>
#import "AppDelegate.h"

// Dump the symbolicated stack of any uncaught ObjC exception to Documents/crash.log
// so we can see exactly which frame creates the second UIApplication (the raw
// addresses in jvm-stdio.log are unanchored).
static void RuneMobileUncaughtHandler(NSException *e) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"UNCAUGHT %@: %@\n", e.name, e.reason];
    for (NSString *frame in e.callStackSymbols) {
        [s appendFormat:@"%@\n", frame];
    }
    // QA-P1-12: Debug writes the crash dump to the Files/USB-exposed Documents dir for off-device retrieval;
    // Release writes it to the sandboxed App Support dir (Documents is no longer file-shared in Release).
#if DEBUG
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
#else
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
#endif
    NSString *path = [dir stringByAppendingPathComponent:@"crash.log"];
    [[s dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path
        options:(NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUnlessOpen) error:NULL];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSSetUncaughtExceptionHandler(&RuneMobileUncaughtHandler);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
