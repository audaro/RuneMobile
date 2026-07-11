/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * GPU depth-sim — minimal headless-style iOS app that runs the depth-precision / z-fight repro on launch and
 * writes a verdict log to its Documents container (pulled off the Simulator via `simctl get_app_container … data`).
 * No UI needed — the EAGL offscreen FBO path needs a current GLES context, not a window. Mirrors the gpu-b1 harness.
 */
#import <UIKit/UIKit.h>
#import "DepthProbe.h"

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
	NSString *logPath = [docs stringByAppendingPathComponent:@"gpu-depthsim-verdict.log"];
	NSMutableString *buf = [NSMutableString string];
	void (^log)(NSString *) = ^(NSString *line) {
		NSLog(@"%@", line);
		[buf appendString:line];
		[buf appendString:@"\n"];
		[buf writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	};

	// run slightly after launch so the app is fully realized
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		@try { [DepthProbe runWithLog:log]; }
		@catch (NSException *ex) { log([NSString stringWithFormat:@"[ds] EXCEPTION %@: %@", ex.name, ex.reason]); }
		log([NSString stringWithFormat:@"[ds] log written to %@", logPath]);
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
