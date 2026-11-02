#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// "Share logs": one text file a player can post with a bug report. It holds the app, device and JIT state, the
/// engine's section (version, plugins, thread dump; DiagnosticsBridge), crash reports, the app's own log for this
/// launch and the one before, and the tail of RuneLite's client.log. RMRedact takes tokens, emails and the
/// character's name out before the share sheet opens. Android's Diagnostics.kt builds the same report.
@interface RMDiagnostics : NSObject

/// Explains what the file holds, then builds it off the main thread and opens the share sheet from `source`.
+ (void)shareFrom:(UIViewController *)presenter sourceView:(UIView *)source;

/// The report text, redacted. Blocks for up to a few seconds while the engine answers: call it off the main thread.
+ (NSString *)reportText;

@end

NS_ASSUME_NONNULL_END
