#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Removes account details from a "Share logs" report before it leaves the phone: the literal tokens.json values,
/// the character's name, then generic shapes (web tokens, bearer headers, URL query secrets, key=value secrets,
/// emails, UUIDs). Foundation only, so ios/dev-tools/diagnostics/test-redaction.sh builds it for the Mac and runs
/// it against tools/diagnostics/redaction-cases.txt, the cases Android's Redact.kt is tested against too.
@interface RMRedact : NSObject

/// `names` are replaced by <player> as whole words, ignoring case and treating space, underscore and hyphen as
/// one; `secrets` of six or more characters by <redacted> wherever they appear.
+ (NSString *)redact:(NSString *)text names:(NSArray<NSString *> *)names secrets:(NSArray<NSString *> *)secrets;

/// Adds the names and literal secrets in a tokens.json to `names` and `secrets`, wherever they sit (the chosen
/// character and every other one on the account). Values only; nothing from the file goes into a report.
+ (void)collectAccount:(nullable NSData *)tokensJSON
                 names:(NSMutableArray<NSString *> *)names
               secrets:(NSMutableArray<NSString *> *)secrets;

@end

NS_ASSUME_NONNULL_END
