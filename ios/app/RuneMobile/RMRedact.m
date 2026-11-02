#import "RMRedact.h"

// The generic rules, in order. Keep them identical to Android's Redact.kt: both are checked against
// tools/diagnostics/redaction-cases.txt. Bearer runs before key=value so "Authorization: Bearer x" loses the
// token, not just the word "Bearer".
static NSString *const kRedactRules[][2] = {
    // JSON web tokens (Jagex and RuneLite sign-in)
    {@"eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}(?:\\.[A-Za-z0-9_-]+)?", @"<token>"},
    // Authorization: Bearer <token>
    {@"(?i)\\b(bearer\\s+)[A-Za-z0-9._~+/=-]{8,}", @"$1<token>"},
    // Query-string secrets in a logged URL (sign-in redirects carry one-time codes)
    {@"(?i)([?&][a-z_]*(?:code|token|state|session|key)[a-z_]*=)[^&\\s\"'#]+", @"$1<redacted>"},
    // key=value, key: value and "key":"value"
    {@"(?i)\\b((?:access|refresh|id|auth)[_-]?token|token|password|passwd|secret|session[_-]?id|session|"
     @"authorization|api[_-]?key|character[_-]?id|account[_-]?id|display[_-]?name|user[_-]?name|jx_[a-z_]+)"
     @"([\"']?\\s*[:=]\\s*[\"']?)([^\\s\"',;&}\\]]{4,})",
     @"$1$2<redacted>"},
    // Emails
    {@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", @"<email>"},
    // UUIDs (session and account ids)
    {@"\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b", @"<uuid>"},
};

// A name as a whole-word, any-case pattern in which space, underscore, hyphen and no-break space are one
// character: OSRS shows "Iron Man", logs may say "Iron_Man" or "Iron Man".
static NSString *RMNamePattern(NSString *name) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return nil;
    NSCharacterSet *joiners = [NSCharacterSet characterSetWithCharactersInString:@" _- "];
    NSMutableString *body = [NSMutableString string];
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar ch = [trimmed characterAtIndex:i];
        if ([joiners characterIsMember:ch])
            [body appendString:@"[ _\\u00a0-]"];
        else
            [body appendString:[NSRegularExpression escapedPatternForString:[NSString stringWithCharacters:&ch
                                                                                                    length:1]]];
    }
    return [NSString stringWithFormat:@"(?<![A-Za-z0-9])%@(?![A-Za-z0-9])", body];
}

@implementation RMRedact

+ (NSString *)redact:(NSString *)text names:(NSArray<NSString *> *)names secrets:(NSArray<NSString *> *)secrets {
    NSMutableString *s = [text mutableCopy];
    for (NSString *secret in secrets) {
        if (secret.length >= 6)
            [s replaceOccurrencesOfString:secret withString:@"<redacted>" options:0 range:NSMakeRange(0, s.length)];
    }
    for (NSString *name in names) {
        NSString *pattern = RMNamePattern(name);
        NSRegularExpression *re =
            pattern ? [NSRegularExpression regularExpressionWithPattern:pattern
                                                                options:NSRegularExpressionCaseInsensitive
                                                                  error:NULL]
                    : nil;
        [re replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"<player>"];
    }
    for (size_t i = 0; i < sizeof kRedactRules / sizeof kRedactRules[0]; i++) {
        NSError *err = nil;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:kRedactRules[i][0]
                                                                            options:0
                                                                              error:&err];
        // A rule that fails to compile would let its secrets through silently: fail the whole report instead.
        if (!re)
            return [NSString stringWithFormat:@"(report withheld: redaction rule %zu did not compile: %@)\n", i,
                                              err.localizedDescription];
        [re replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:kRedactRules[i][1]];
    }
    return s;
}

// The key sets match Android's Redact.collectAccount; tools/diagnostics/tokens-sample.json checks both.
+ (void)collectAccount:(NSData *)tokensJSON
                 names:(NSMutableArray<NSString *> *)names
               secrets:(NSMutableArray<NSString *> *)secrets {
    id root = tokensJSON ? [NSJSONSerialization JSONObjectWithData:tokensJSON options:0 error:NULL] : nil;
    NSSet *nameKeys = [NSSet setWithArray:@[ @"chosen_display_name", @"displayName", @"display_name" ]];
    NSSet *secretKeys = [NSSet setWithArray:@[
        @"session_id", @"chosen_account_id", @"accountId", @"account_id", @"access_token", @"refresh_token",
        @"id_token", @"otl_token", @"userHash"
    ]];
    NSMutableArray *stack = root ? [NSMutableArray arrayWithObject:root] : [NSMutableArray array];
    while (stack.count) {
        id node = stack.lastObject;
        [stack removeLastObject];
        if ([node isKindOfClass:[NSArray class]]) {
            [stack addObjectsFromArray:node];
        } else if ([node isKindOfClass:[NSDictionary class]]) {
            [(NSDictionary *)node enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
                    if ([nameKeys containsObject:key])
                        [names addObject:value];
                    else if ([secretKeys containsObject:key])
                        [secrets addObject:value];
                } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                    [stack addObject:value];
                }
            }];
        }
    }
}

@end
