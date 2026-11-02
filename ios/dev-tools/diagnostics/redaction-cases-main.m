// Runs RMRedact over tools/diagnostics/redaction-cases.txt and its account walk over tokens-sample.json (the files
// Android's RedactTest checks too). Built and run by test-redaction.sh.
#import <Foundation/Foundation.h>
#import "RMRedact.h"

// The account walk against tokens-sample.expect ("name X" / "secret Y" lines), compared as sets. 0 when it matches.
static int checkAccountWalk(NSString *jsonPath, NSString *expectPath) {
    NSData *json = [NSData dataWithContentsOfFile:jsonPath];
    NSString *expect = [NSString stringWithContentsOfFile:expectPath encoding:NSUTF8StringEncoding error:NULL];
    if (!json || !expect) {
        fprintf(stderr, "cannot read %s or %s\n", jsonPath.UTF8String, expectPath.UTF8String);
        return 2;
    }
    NSMutableSet *wantNames = [NSMutableSet set], *wantSecrets = [NSMutableSet set];
    for (NSString *line in [expect componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"name "])
            [wantNames addObject:[line substringFromIndex:5]];
        else if ([line hasPrefix:@"secret "])
            [wantSecrets addObject:[line substringFromIndex:7]];
    }
    NSMutableArray *names = [NSMutableArray array], *secrets = [NSMutableArray array];
    [RMRedact collectAccount:json names:names secrets:secrets];
    NSSet *gotNames = [NSSet setWithArray:names], *gotSecrets = [NSSet setWithArray:secrets];
    if ([gotNames isEqualToSet:wantNames] && [gotSecrets isEqualToSet:wantSecrets] && wantNames.count &&
        wantSecrets.count) {
        printf("ACCOUNT_WALK_GREEN %lu names, %lu secrets\n", (unsigned long)gotNames.count,
               (unsigned long)gotSecrets.count);
        return 0;
    }
    printf("ACCOUNT_WALK_RED\n  want names:   %s\n  got names:    %s\n  want secrets: %s\n  got secrets:  %s\n",
           [wantNames.allObjects componentsJoinedByString:@", "].UTF8String,
           [gotNames.allObjects componentsJoinedByString:@", "].UTF8String,
           [wantSecrets.allObjects componentsJoinedByString:@", "].UTF8String,
           [gotSecrets.allObjects componentsJoinedByString:@", "].UTF8String);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: %s <redaction-cases.txt> <tokens-sample.json> <tokens-sample.expect>\n", argv[0]);
            return 2;
        }
        int walk = checkAccountWalk([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        if (walk == 2)
            return 2;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *all = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (!all) {
            fprintf(stderr, "cannot read %s\n", argv[1]);
            return 2;
        }
        NSMutableArray *names = [NSMutableArray array], *secrets = [NSMutableArray array];
        NSString *input = nil;
        int cases = 0, failed = 0;
        for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"@name "])
                [names addObject:[line substringFromIndex:6]];
            else if ([line hasPrefix:@"@secret "])
                [secrets addObject:[line substringFromIndex:8]];
            else if ([line hasPrefix:@"< "])
                input = [line substringFromIndex:2];
            else if ([line hasPrefix:@"> "]) {
                if (!input) {
                    fprintf(stderr, "'>' line with no '<' before it: %s\n", line.UTF8String);
                    return 2;
                }
                NSString *want = [line substringFromIndex:2];
                NSString *got = [RMRedact redact:input names:names secrets:secrets];
                cases++;
                if (![got isEqualToString:want]) {
                    failed++;
                    printf("FAIL\n  in:   %s\n  want: %s\n  got:  %s\n", input.UTF8String, want.UTF8String,
                           got.UTF8String);
                }
                input = nil;
            }
        }
        if (cases == 0 || input) {
            fprintf(stderr, cases == 0 ? "no cases found\n" : "a '<' line has no '>' after it\n");
            return 2;
        }
        printf("%s %d/%d\n", failed ? "REDACTION_CASES_RED" : "REDACTION_CASES_GREEN", cases - failed, cases);
        return (failed || walk) ? 1 : 0;
    }
}
