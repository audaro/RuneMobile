/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * GPU Route C step 2 — minimal iOS app that runs the native-bridge render test on launch and writes a verdict log
 * to its Documents container (pulled off the Simulator via `simctl get_app_container … data`). No JVM (the
 * Simulator can't load our iOS-triple JVM); this validates the NATIVE GL bridge mechanics. The JVM↔JNI plumbing is
 * the proven JavaBridge reverse-JNI pattern, wired on device.
 */
#import <UIKit/UIKit.h>
#import "RouteCProbe.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts
{
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = [UIColor blackColor];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];

	NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString *logPath = [docs stringByAppendingPathComponent:@"routec-step2-verdict.log"];
	NSMutableString *buf = [NSMutableString string];
	void (^log)(NSString *) = ^(NSString *line) {
		NSLog(@"%@", line);
		[buf appendString:line];
		[buf appendString:@"\n"];
		[buf writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	};

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		@try { [RouteCProbe runWithLog:log]; }
		@catch (NSException *ex) { log([NSString stringWithFormat:@"[rc2] EXCEPTION %@: %@", ex.name, ex.reason]); }
		log([NSString stringWithFormat:@"[rc2] log written to %@", logPath]);
	});
	return YES;
}

@end

int main(int argc, char *argv[])
{
	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
	}
}
