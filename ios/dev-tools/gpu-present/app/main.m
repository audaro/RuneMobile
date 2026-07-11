/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * gpu-present — minimal iOS app that brings up an ANGLE/Metal EGL WINDOW surface on launch and live-presents an
 * animated pattern (present-path de-risk for the Route C backend swap). No JIT/StikDebug needed (pure GLES via
 * ANGLE, no JVM). Writes a verdict log to its Documents container (pull via `devicectl device copy from`) and the
 * bars/stripe should be visible on the device screen (screenshot to confirm the present scans out).
 *
 * This TU owns the UIKit + CAMetalLayer + CADisplayLink (Apple frameworks). It must NOT import any ANGLE GLES3
 * header — those live only in PresentProbe.m, which imports no UIKit/QuartzCore (the OpenGLES-module collision).
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import "PresentProbe.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) PresentProbe *probe;
@property (strong, nonatomic) CADisplayLink *link;
@property (assign, nonatomic) BOOL running;
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
	NSString *logPath = [docs stringByAppendingPathComponent:@"gpu-present-verdict.log"];
	NSMutableString *buf = [NSMutableString string];
	void (^log)(NSString *) = ^(NSString *line) {
		NSLog(@"%@", line);
		[buf appendString:line]; [buf appendString:@"\n"];
		[buf writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	};

	// Full-screen CAMetalLayer (ANGLE's Metal backend presents through it). Configure it here on the UIKit side;
	// PresentProbe only casts the pointer to EGLNativeWindowType for eglCreateWindowSurface.
	[vc.view layoutIfNeeded];
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.frame = vc.view.bounds;
	layer.opaque = YES;
	layer.framebufferOnly = NO;        // allow glReadPixels of the default framebuffer for the self-check
	CGFloat scale = UIScreen.mainScreen.nativeScale;
	layer.contentsScale = scale;
	layer.drawableSize = CGSizeMake(vc.view.bounds.size.width * scale, vc.view.bounds.size.height * scale);
	[vc.view.layer addSublayer:layer];

	self.probe = [PresentProbe new];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		@try {
			log([NSString stringWithFormat:@"[gp] CAMetalLayer %.0fx%.0f @%.1f -> drawable %.0fx%.0f",
				layer.bounds.size.width, layer.bounds.size.height, scale, layer.drawableSize.width, layer.drawableSize.height]);
			if ([self.probe startWithLayer:(__bridge void *)layer log:log]) {
				self.running = YES;
				self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
				[self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
			} else {
				log(@"[gp] start FAILED");
			}
		}
		@catch (NSException *ex) { log([NSString stringWithFormat:@"[gp] EXCEPTION %@: %@", ex.name, ex.reason]); }
		log([NSString stringWithFormat:@"[gp] log written to %@", logPath]);
	});
	return YES;
}

- (void)tick { if (self.running) [self.probe renderFrame]; }

@end

int main(int argc, char *argv[])
{
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
