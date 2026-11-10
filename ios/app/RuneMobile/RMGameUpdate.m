// RMGameUpdate - see the header. The manifest format and the rules are in docs/GAME-UPDATES-PLAN.md (local) and
// tools/game-update/make-manifest.py, which writes what this reads; Android's GameUpdate.kt applies the same rules.
//
// On disk, in Application Support/game-update/ (excluded from backup):
//   sets/<id>/       a verified set: the jars plus the manifest.json and manifest.sig it came from
//   sets/<id>.partial a download in progress (removed at boot unless this process is writing it)
//   current          the id of the set the next boot uses
//   boot-armed       "<id> <n>": n boots of <id> started and none reached the first frame yet
//   bad-sets         ids that failed kBadAfterBoots boots in a row, one per line
//   highest-revision the highest manifest revision accepted (an older one is a replay)
// The running process keeps its own set's directory untouched: a new set lands in its own directory and only the
// next boot switches to it, so a jar the JVM has open is never replaced under it.
#import "RMGameUpdate.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *const kManifestURL =
    @"https://github.com/audaro/runemobile/releases/download/game-update/game-update.json";
static NSString *const kKind = @"rune-mobile-game-update";
static NSString *const kPort = @"ios";
// SubjectPublicKeyInfo DER, base64: current, then spare (tools/game-update/keygen.sh --pins).
static NSString *const kPins[] = {
    @"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEN7ZacJwhId8Qd9r4CN4/G08j2Px7uus+6jTmHA+RM/"
    @"oYyiqRSslIpFFqW0JWqCSyqaLcg2LmjgFawSYxOY+rNQ==",
    @"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDcsQ0kW0or/4l2UY5GzmxNUters14AkcDjfjrWkTyu3V64jLPFVC7WSNDCbLFuoGxRn1h+"
    @"gY2upQndhpsfXlPA==",
};
static const NSUInteger kManifestMax = 256 * 1024;
static const NSUInteger kSigMax = 512;
static const long long kFileMax = 64LL << 20;
static const NSInteger kBadAfterBoots = 2;
static const NSUInteger kBadListMax = 32;

static NSArray<NSString *> *RMGUJarNames(void) {
    return @[ @"client-shaded.jar", @"client-rlhd.jar", @"probes.jar" ];
}

#pragma mark - Set

@interface RMGameUpdateSet ()
@property (nonatomic, copy, readwrite) NSString *setId;
@property (nonatomic, assign, readwrite) NSInteger manifestRevision;
@property (nonatomic, assign, readwrite) NSInteger gameRevision;
@property (nonatomic, copy, readwrite) NSString *runelite;
@property (nonatomic, copy, readwrite, nullable) NSString *pluginHubVersion;
@property (nonatomic, assign, readwrite) BOOL required;
@property (nonatomic, assign, readwrite) long long totalBytes;
@property (nonatomic, copy, readwrite, nullable) NSString *dir;
// name -> {url, size, sha256}
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *files;
// The exact manifest bytes and signature the set came from, written beside the jars on install.
@property (nonatomic, copy, nullable) NSData *manifestData;
@property (nonatomic, copy, nullable) NSData *signature;
@end

@implementation RMGameUpdateSet
- (NSString *)pathForJar:(NSString *)name {
    return [self.dir stringByAppendingPathComponent:name];
}
@end

#pragma mark - Pure checks

static BOOL RMGUVerifySignature(NSData *message, NSData *signature) {
    // P-256 SPKI = this fixed 26-byte header + the 65-byte X9.63 point SecKeyCreateWithData takes.
    static const uint8_t header[26] = {0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                       0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00};
    if (message.length == 0 || signature.length == 0 || signature.length > kSigMax)
        return NO;
    for (size_t i = 0; i < sizeof(kPins) / sizeof(kPins[0]); i++) {
        NSData *spki = [[NSData alloc] initWithBase64EncodedString:kPins[i] options:0];
        if (spki.length != 91 || memcmp(spki.bytes, header, sizeof(header)) != 0)
            continue;
        NSData *point = [spki subdataWithRange:NSMakeRange(26, 65)];
        NSDictionary *attrs = @{
            (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
            (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
            (id)kSecAttrKeySizeInBits : @256,
        };
        CFErrorRef err = NULL;
        SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)point, (__bridge CFDictionaryRef)attrs, &err);
        if (err)
            CFRelease(err);
        if (!key)
            continue;
        err = NULL;
        Boolean ok = SecKeyVerifySignature(key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                           (__bridge CFDataRef)message, (__bridge CFDataRef)signature, &err);
        if (err)
            CFRelease(err);
        CFRelease(key);
        if (ok)
            return YES;
    }
    return NO;
}

static BOOL RMGUMatches(NSString *s, NSString *pattern) {
    if (![s isKindOfClass:[NSString class]])
        return NO;
    NSString *anchored = [NSString stringWithFormat:@"^(?:%@)$", pattern];
    return [s rangeOfString:anchored options:NSRegularExpressionSearch].location != NSNotFound;
}

// A JSON integer (not a bool, not a fraction).
static BOOL RMGUInteger(id v, long long *out) {
    if (![v isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
        return NO;
    NSNumber *n = v;
    if (strcmp(n.objCType, @encode(double)) == 0 || strcmp(n.objCType, @encode(float)) == 0) {
        double d = n.doubleValue;
        if (d != (double)(long long)d)
            return NO;
    }
    *out = n.longLongValue;
    return YES;
}

static BOOL RMGUURLAllowed(NSString *url) {
    if (![url isKindOfClass:[NSString class]] || url.length > 2048)
        return NO;
    NSURL *u = [NSURL URLWithString:url];
    if (!u.host.length)
        return NO;
    if ([u.scheme isEqualToString:@"https"])
        return YES;
#if DEBUG
    // The local test server (tools/game-update/serve-local.sh) is plain HTTP on loopback.
    if ([u.scheme isEqualToString:@"http"] && ([u.host isEqualToString:@"127.0.0.1"] || [u.host isEqualToString:@"localhost"]))
        return YES;
#endif
    return NO;
}

// Parse a verified manifest and return this shell's set. *revision gets the manifest revision whenever the top level
// is valid, so a caller can store it even when there is no set for this build.
static RMGameUpdateSet *RMGUParse(NSData *data, NSString *shell, NSSet<NSString *> *bad, BOOL checkExpiry,
                                  NSInteger *revision, NSString **why) {
    *revision = 0;
    NSError *err = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        *why = @"manifest is not a JSON object";
        return nil;
    }
    long long schema = 0, rev = 0;
    if (!RMGUInteger(root[@"schema"], &schema) || schema != 1) {
        *why = @"unknown manifest schema";
        return nil;
    }
    if (![root[@"kind"] isEqual:kKind]) {
        *why = @"manifest kind is wrong";
        return nil;
    }
    if (!RMGUInteger(root[@"revision"], &rev) || rev < 1 || rev > INT32_MAX) {
        *why = @"manifest revision is invalid";
        return nil;
    }
    NSDate *expires = [root[@"expires"] isKindOfClass:[NSString class]]
                          ? [[[NSISO8601DateFormatter alloc] init] dateFromString:root[@"expires"]]
                          : nil;
    if (!expires) {
        *why = @"manifest expiry is invalid";
        return nil;
    }
    NSArray *sets = root[@"sets"];
    if (![sets isKindOfClass:[NSArray class]] || sets.count > 64) {
        *why = @"manifest sets are invalid";
        return nil;
    }
    *revision = (NSInteger)rev;
    if (checkExpiry && [expires timeIntervalSinceNow] < 0) {
        *why = @"manifest has expired";
        return nil;
    }
    NSDictionary *mine = nil;
    for (NSDictionary *s in sets) {
        if (![s isKindOfClass:[NSDictionary class]]) {
            *why = @"a manifest set is not an object";
            return nil;
        }
        if (![s[@"port"] isEqual:kPort] || ![s[@"shell"] isEqual:shell])
            continue;
        if (mine) {
            *why = @"manifest has two sets for this build";
            return nil;
        }
        mine = s;
    }
    if (!mine) {
        *why = @"manifest has no set for this build";
        return nil;
    }
    RMGameUpdateSet *set = [[RMGameUpdateSet alloc] init];
    set.manifestRevision = (NSInteger)rev;
    if (!RMGUMatches(mine[@"id"], @"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")) {
        *why = @"set id is invalid";
        return nil;
    }
    set.setId = mine[@"id"];
    long long game = 0;
    if (!RMGUInteger(mine[@"gameRevision"], &game) || game < 1 || game > 100000) {
        *why = @"set game revision is invalid";
        return nil;
    }
    set.gameRevision = (NSInteger)game;
    if (!RMGUMatches(mine[@"runelite"], @"[0-9A-Za-z.+-]{1,40}")) {
        *why = @"set runelite version is invalid";
        return nil;
    }
    set.runelite = mine[@"runelite"];
    id hub = mine[@"pluginHubVersion"];
    if (hub && hub != [NSNull null]) {
        if (!RMGUMatches(hub, @"[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}")) {
            *why = @"set plugin hub version is invalid";
            return nil;
        }
        set.pluginHubVersion = hub;
    }
    id req = mine[@"required"];
    if (req && CFGetTypeID((__bridge CFTypeRef)req) != CFBooleanGetTypeID()) {
        *why = @"set required flag is invalid";
        return nil;
    }
    set.required = [req boolValue];
    NSArray *files = mine[@"files"];
    if (![files isKindOfClass:[NSArray class]]) {
        *why = @"set files are invalid";
        return nil;
    }
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    long long total = 0;
    for (NSDictionary *f in files) {
        long long size = 0;
        if (![f isKindOfClass:[NSDictionary class]] || ![RMGUJarNames() containsObject:f[@"name"]] ||
            byName[f[@"name"]] || !RMGUURLAllowed(f[@"url"]) || !RMGUInteger(f[@"size"], &size) || size < 1 ||
            size > kFileMax || !RMGUMatches(f[@"sha256"], @"[0-9a-f]{64}")) {
            *why = @"a set file entry is invalid";
            return nil;
        }
        byName[f[@"name"]] = @{@"url" : f[@"url"],
                               @"size" : @(size),
                               @"sha256" : f[@"sha256"]};
        total += size;
    }
    if (byName.count != RMGUJarNames().count) {
        *why = @"set does not name every jar";
        return nil;
    }
    set.files = byName;
    set.totalBytes = total;
    if ([bad containsObject:set.setId]) {
        *why = [NSString stringWithFormat:@"set %@ is marked bad on this phone", set.setId];
        return nil;
    }
    return set;
}

static NSString *RMGUSha256File(NSString *path, long long *sizeOut) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh)
        return nil;
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    long long n = 0;
    for (;;) {
        @autoreleasepool {
            NSError *err = nil;
            NSData *d = [fh readDataUpToLength:(1 << 20) error:&err];
            if (!d) {
                [fh closeFile];
                return nil;
            }
            if (d.length == 0)
                break;
            CC_SHA256_Update(&c, d.bytes, (CC_LONG)d.length);
            n += (long long)d.length;
        }
    }
    [fh closeFile];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &c);
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [hex appendFormat:@"%02x", md[i]];
    *sizeOut = n;
    return hex;
}

static BOOL RMGUFileMatches(NSString *path, NSDictionary *want, NSString **why) {
    long long size = -1;
    NSString *hex = RMGUSha256File(path, &size);
    if (!hex) {
        *why = [NSString stringWithFormat:@"%@ is missing or unreadable", path.lastPathComponent];
        return NO;
    }
    if (size != [want[@"size"] longLongValue] || ![hex isEqualToString:want[@"sha256"]]) {
        *why = [NSString stringWithFormat:@"%@ does not match the manifest (size %lld)", path.lastPathComponent, size];
        return NO;
    }
    return YES;
}

#pragma mark - RMGameUpdate

@interface RMGameUpdate ()
@property (nonatomic, strong) dispatch_queue_t q; // every disk read/write of the game-update dir
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *base;
@property (atomic, copy, readwrite, nullable) NSString *bootedSetId;
@property (atomic, assign) BOOL booted;  // setForBoot ran in this process
@property (atomic, assign) BOOL settled; // settleBoot ran in this process
@property (atomic, assign, readwrite) BOOL downloading;
@property (atomic, copy) NSString *partialInFlight; // sets/<id>.partial this process is writing
@property (atomic, copy) NSString *lastCheck;
@property (nonatomic, strong) NSMutableArray *checkWaiters; // main queue only
@end

@implementation RMGameUpdate

+ (instancetype)shared {
    static RMGameUpdate *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[RMGameUpdate alloc] init];
    });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("dev.audaro.runemobile.gameupdate", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 20;
        cfg.timeoutIntervalForResource = 15 * 60;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        NSString *support =
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        _base = [support stringByAppendingPathComponent:@"game-update"];
        _lastCheck = @"not checked";
        _checkWaiters = [NSMutableArray array];
    }
    return self;
}

+ (NSString *)shellCommit {
#if DEBUG
    // Debug only: pretend to be a released shell so the simulator can take a set published for that commit.
    NSString *pretend = [[NSUserDefaults standardUserDefaults] stringForKey:@"RMGameUpdateShell"];
    if (pretend.length)
        return pretend;
#endif
    NSString *c = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RMSourceCommit"];
    return [c isKindOfClass:[NSString class]] && c.length ? c : @"unknown";
}

- (BOOL)enabled {
    return RMGUMatches([RMGameUpdate shellCommit], @"[0-9a-f]{40}");
}

- (NSURL *)manifestURL {
#if DEBUG
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"RMGameUpdateURL"];
    if (over.length)
        return [NSURL URLWithString:over];
#endif
    return [NSURL URLWithString:kManifestURL];
}

#pragma mark Disk (on q)

- (NSString *)path:(NSString *)name {
    return [self.base stringByAppendingPathComponent:name];
}

- (NSString *)setsDir {
    return [self path:@"sets"];
}

- (void)ensureBase {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[self setsDir] withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSURL fileURLWithPath:self.base] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
}

- (NSString *)readString:(NSString *)name {
    NSString *s = [NSString stringWithContentsOfFile:[self path:name] encoding:NSUTF8StringEncoding error:nil];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)writeString:(NSString *)s to:(NSString *)name {
    [self ensureBase];
    [s writeToFile:[self path:name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSSet<NSString *> *)badSets {
    NSArray *lines = [[self readString:@"bad-sets"] componentsSeparatedByString:@"\n"];
    NSMutableSet *s = [NSMutableSet set];
    for (NSString *l in lines)
        if (l.length)
            [s addObject:l];
    return s;
}

- (void)markBad:(NSString *)setId {
    NSMutableArray *lines = [[[self readString:@"bad-sets"] componentsSeparatedByString:@"\n"] mutableCopy];
    [lines removeObject:@""];
    if (![lines containsObject:setId])
        [lines addObject:setId];
    while (lines.count > kBadListMax)
        [lines removeObjectAtIndex:0];
    [self writeString:[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] to:@"bad-sets"];
}

- (NSInteger)highestRevision {
    return [[self readString:@"highest-revision"] integerValue];
}

// "<id> <n>" -> id and n, or nil.
- (NSString *)cookieId:(NSInteger *)count {
    NSArray *parts = [[self readString:@"boot-armed"] componentsSeparatedByString:@" "];
    *count = parts.count == 2 ? [parts[1] integerValue] : 0;
    return parts.count == 2 && [parts[0] length] ? parts[0] : nil;
}

- (void)removeSetDir:(NSString *)setId {
    [[NSFileManager defaultManager] removeItemAtPath:[[self setsDir] stringByAppendingPathComponent:setId] error:nil];
}

// Read sets/<id>/manifest.json + .sig and return the verified set for this shell, or nil with why.
- (RMGameUpdateSet *)installedSet:(NSString *)setId why:(NSString **)why {
    NSString *dir = [[self setsDir] stringByAppendingPathComponent:setId];
    NSData *json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"manifest.json"]];
    NSData *sig = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"manifest.sig"]];
    if (!json || !sig || json.length > kManifestMax) {
        *why = @"installed set has no manifest";
        return nil;
    }
    if (!RMGUVerifySignature(json, sig)) {
        *why = @"installed manifest signature does not verify";
        return nil;
    }
    NSInteger rev = 0;
    // No expiry check at boot: expiry limits what is offered, not a set already verified and installed.
    RMGameUpdateSet *set = RMGUParse(json, [RMGameUpdate shellCommit], [self badSets], NO, &rev, why);
    if (!set)
        return nil;
    if (![set.setId isEqualToString:setId]) {
        *why = @"installed manifest names a different set";
        return nil;
    }
    set.dir = dir;
    return set;
}

#pragma mark Boot

- (RMGameUpdateSet *)setForBootWithLog:(RMGameUpdateLog)log {
    __block RMGameUpdateSet *result = nil;
    __block NSMutableArray<NSString *> *lines = [NSMutableArray array];
    dispatch_sync(self.q, ^{
        result = [self bootSelect:lines];
    });
    for (NSString *l in lines)
        log(l);
    return result;
}

- (RMGameUpdateSet *)bootSelect:(NSMutableArray<NSString *> *)lines {
    self.booted = YES;
    if (!self.enabled) {
        [lines addObject:[NSString stringWithFormat:@"[game-update] off: this build's commit is %@, so it boots the "
                                                    @"bundled jars",
                                                    [RMGameUpdate shellCommit]]];
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *current = [self readString:@"current"];
    RMGameUpdateSet *set = nil;
    if (current.length) {
        NSString *why = nil;
        set = [self installedSet:current why:&why];
        NSInteger n = 0;
        NSString *cookie = [self cookieId:&n];
        if (set && [cookie isEqualToString:current] && n >= kBadAfterBoots) {
            [self markBad:current];
            [lines addObject:[NSString stringWithFormat:@"[game-update] set %@ started %ld times without reaching the "
                                                        @"first frame: marked bad, booting the bundled jars",
                                                        current, (long)n]];
            set = nil;
        } else if (set) {
            for (NSString *name in RMGUJarNames()) {
                if (!RMGUFileMatches([set pathForJar:name], set.files[name], &why)) {
                    set = nil;
                    break;
                }
            }
        }
        if (!set) {
            if (why)
                [lines addObject:[NSString stringWithFormat:@"[game-update] not booting set %@: %@", current, why]];
            [fm removeItemAtPath:[self path:@"current"] error:nil];
            [fm removeItemAtPath:[self path:@"boot-armed"] error:nil];
        } else if (cookie && ![cookie isEqualToString:current]) {
            [fm removeItemAtPath:[self path:@"boot-armed"] error:nil];
        }
    }
    // Remove every other set: the one the last process ran, leftovers, a failed one. Keep only a download this
    // process is writing right now.
    for (NSString *name in [fm contentsOfDirectoryAtPath:[self setsDir] error:nil]) {
        if ((set && [name isEqualToString:set.setId]) || [name isEqualToString:self.partialInFlight])
            continue;
        [fm removeItemAtPath:[[self setsDir] stringByAppendingPathComponent:name] error:nil];
    }
    if (set) {
        self.bootedSetId = set.setId;
        [lines addObject:[NSString stringWithFormat:@"[game-update] booting set %@ (game revision %ld, RuneLite %@, "
                                                    @"manifest %ld), every jar verified",
                                                    set.setId, (long)set.gameRevision, set.runelite,
                                                    (long)set.manifestRevision]];
    } else {
        [lines addObject:@"[game-update] booting the bundled jars"];
    }
    return set;
}

- (void)armBoot:(RMGameUpdateSet *)set {
    dispatch_sync(self.q, ^{
        NSInteger n = 0;
        NSString *cookie = [self cookieId:&n];
        if (![cookie isEqualToString:set.setId])
            n = 0;
        [self writeString:[NSString stringWithFormat:@"%@ %ld", set.setId, (long)(n + 1)] to:@"boot-armed"];
    });
}

- (void)settleBoot {
    if (self.settled)
        return;
    self.settled = YES;
    dispatch_async(self.q, ^{
        NSInteger n = 0;
        NSString *cookie = [self cookieId:&n];
        if (cookie && [cookie isEqualToString:self.bootedSetId])
            [[NSFileManager defaultManager] removeItemAtPath:[self path:@"boot-armed"] error:nil];
    });
}

- (BOOL)readyForNextLaunch {
    __block BOOL ready = NO;
    dispatch_sync(self.q, ^{
        NSString *current = [self readString:@"current"];
        ready = self.booted && current.length && ![current isEqualToString:self.bootedSetId ?: @""];
    });
    return ready;
}

- (NSString *)statusLine {
    __block NSString *current = nil;
    dispatch_sync(self.q, ^{
        current = [self readString:@"current"];
    });
    NSString *commit = [RMGameUpdate shellCommit];
    return [NSString stringWithFormat:@"%@ | build %@ | booted %@ | installed %@ | last check: %@",
                                      self.enabled ? @"on" : @"off (dev build)",
                                      commit.length > 12 ? [commit substringToIndex:12] : commit,
                                      self.booted ? (self.bootedSetId ?: @"bundled jars") : @"not yet",
                                      current.length ? current : @"none", self.lastCheck ?: @"?"];
}

#pragma mark Network

- (void)fetch:(NSURL *)url max:(NSUInteger)max completion:(void (^)(NSData *data, NSString *why))completion {
    NSURLSessionDataTask *t = [self.session
          dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            if (error)
                completion(nil, error.localizedDescription ?: @"network error");
            else if (status != 200)
                completion(nil, [NSString stringWithFormat:@"HTTP %ld for %@", (long)status, url.lastPathComponent]);
            else if (data.length == 0 || data.length > max)
                completion(nil, [NSString stringWithFormat:@"%@ is %lu bytes", url.lastPathComponent,
                                                           (unsigned long)data.length]);
            else
                completion(data, nil);
        }];
    [t resume];
}

- (void)check:(void (^)(RMGameUpdateCheckResult, RMGameUpdateSet *, NSString *))completion {
    NSAssert([NSThread isMainThread], @"check: is main-thread only");
    if (!self.enabled) {
        completion(RMGameUpdateCheckDisabled, nil, @"this build takes no game updates");
        return;
    }
    [self.checkWaiters addObject:[completion copy]];
    if (self.checkWaiters.count > 1)
        return;
    void (^finish)(RMGameUpdateCheckResult, RMGameUpdateSet *, NSString *) =
        ^(RMGameUpdateCheckResult r, RMGameUpdateSet *offer, NSString *detail) {
            dispatch_async(dispatch_get_main_queue(), ^{
                static NSString *const names[] = {@"off", @"failed", @"no set", @"up to date", @"offer"};
                self.lastCheck = [NSString stringWithFormat:@"%@ (%@)", names[r], detail];
                NSArray *waiters = [self.checkWaiters copy];
                [self.checkWaiters removeAllObjects];
                for (void (^w)(RMGameUpdateCheckResult, RMGameUpdateSet *, NSString *) in waiters)
                    w(r, offer, detail);
            });
        };
    NSURL *url = [self manifestURL];
    NSURL *sigURL = [NSURL URLWithString:[url.absoluteString stringByAppendingString:@".sig"]];
    [self fetch:url
               max:kManifestMax
        completion:^(NSData *json, NSString *why) {
            if (!json) {
                finish(RMGameUpdateCheckFailed, nil, why);
                return;
            }
            [self fetch:sigURL
                       max:kSigMax
                completion:^(NSData *sig, NSString *why2) {
                    if (!sig) {
                        finish(RMGameUpdateCheckFailed, nil, why2);
                        return;
                    }
                    dispatch_async(self.q, ^{
                        [self judge:json sig:sig finish:finish];
                    });
                }];
        }];
}

// On q: verify and decide.
- (void)judge:(NSData *)json
          sig:(NSData *)sig
       finish:(void (^)(RMGameUpdateCheckResult, RMGameUpdateSet *, NSString *))finish {
    if (!RMGUVerifySignature(json, sig)) {
        finish(RMGameUpdateCheckFailed, nil, @"manifest signature does not verify");
        return;
    }
    NSInteger rev = 0;
    NSString *why = nil;
    RMGameUpdateSet *set = RMGUParse(json, [RMGameUpdate shellCommit], [self badSets], YES, &rev, &why);
    NSInteger highest = [self highestRevision];
    if (rev > 0 && rev < highest) {
        finish(RMGameUpdateCheckFailed, nil,
               [NSString stringWithFormat:@"manifest revision %ld is older than %ld", (long)rev, (long)highest]);
        return;
    }
    if (rev > highest)
        [self writeString:[NSString stringWithFormat:@"%ld", (long)rev] to:@"highest-revision"];
    if (!set) {
        finish(rev > 0 ? RMGameUpdateCheckNoSet : RMGameUpdateCheckFailed, nil, why ?: @"no set");
        return;
    }
    set.manifestData = json;
    set.signature = sig;
    NSString *current = [self readString:@"current"];
    if ([current isEqualToString:set.setId]) {
        finish(RMGameUpdateCheckCurrent, nil, [NSString stringWithFormat:@"set %@ is installed", set.setId]);
        return;
    }
    finish(RMGameUpdateCheckOffer, set,
           [NSString stringWithFormat:@"set %@ (game revision %ld, %.1f MB%@)", set.setId, (long)set.gameRevision,
                                      set.totalBytes / 1048576.0, set.required ? @", required" : @""]);
}

- (void)download:(RMGameUpdateSet *)set
        progress:(void (^)(long long, long long))progress
      completion:(void (^)(BOOL, NSString *))completion {
    NSAssert([NSThread isMainThread], @"download: is main-thread only");
    if (self.downloading || !set.manifestData || !set.signature) {
        completion(NO, self.downloading ? @"a download is already running" : @"set did not come from a check");
        return;
    }
    self.downloading = YES;
    NSString *partialName = [set.setId stringByAppendingString:@".partial"];
    NSString *partial = [[self setsDir] stringByAppendingPathComponent:partialName];
    void (^done)(BOOL, NSString *) = ^(BOOL ok, NSString *detail) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloading = NO;
            completion(ok, detail);
        });
    };
    dispatch_async(self.q, ^{
        self.partialInFlight = partialName;
        [self ensureBase];
        [[NSFileManager defaultManager] removeItemAtPath:partial error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:partial withIntermediateDirectories:YES attributes:nil error:nil];
        [self downloadFiles:[RMGUJarNames() mutableCopy]
                        set:set
                       into:partial
                     before:0
                   progress:progress
                     finish:^(BOOL ok, NSString *why) {
                         // On q.
                         if (ok)
                             ok = [self install:set from:partial why:&why];
                         if (!ok)
                             [[NSFileManager defaultManager] removeItemAtPath:partial error:nil];
                         self.partialInFlight = nil;
                         done(ok, ok ? [NSString stringWithFormat:@"set %@ installed", set.setId] : why);
                     }];
    });
}

// One file at a time, so progress is a plain running total. `finish` runs on q.
- (void)downloadFiles:(NSMutableArray<NSString *> *)names
                  set:(RMGameUpdateSet *)set
                 into:(NSString *)partial
               before:(long long)before
             progress:(void (^)(long long, long long))progress
               finish:(void (^)(BOOL, NSString *))finish {
    if (names.count == 0) {
        finish(YES, nil);
        return;
    }
    NSString *name = names.firstObject;
    [names removeObjectAtIndex:0];
    NSDictionary *want = set.files[name];
    long long size = [want[@"size"] longLongValue];
    NSString *dest = [partial stringByAppendingPathComponent:name];
    __block NSURLSessionDownloadTask *task = nil;
    __block dispatch_source_t timer = nil;
    __block BOOL oversize = NO; // set on main before the cancel it causes, so the handler below sees it
    task = [self.session
        downloadTaskWithURL:[NSURL URLWithString:want[@"url"]]
          completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *error) {
              if (timer)
                  dispatch_source_cancel(timer);
              NSInteger status =
                  [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
              NSString *why = nil;
              if (oversize)
                  why = [NSString stringWithFormat:@"%@ is larger than the manifest says", name];
              else if (error)
                  why = error.localizedDescription ?: @"network error";
              else if (status != 200)
                  why = [NSString stringWithFormat:@"HTTP %ld for %@", (long)status, name];
              // The temporary file goes when this handler returns, so move it now.
              else if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:nil])
                  why = [NSString stringWithFormat:@"could not keep %@", name];
              dispatch_async(self.q, ^{
                  NSString *bad = why;
                  if (!bad)
                      RMGUFileMatches(dest, want, &bad);
                  if (bad) {
                      finish(NO, bad);
                      return;
                  }
                  if (progress) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                          progress(before + size, set.totalBytes);
                      });
                  }
                  [self downloadFiles:names set:set into:partial before:before + size progress:progress finish:finish];
              });
          }];
    // Every 250 ms: the progress, and a stop for a file that runs past its manifest size (the hash would refuse it
    // anyway, but only after the whole thing landed on disk).
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        long long received = MAX(task.countOfBytesReceived, 0);
        if (received > size && !oversize) {
            oversize = YES;
            [task cancel];
            return;
        }
        if (progress)
            progress(before + MIN(received, size), set.totalBytes);
    });
    dispatch_resume(timer);
    [task resume];
}

// On q: the partial dir holds every verified jar. Add the manifest, move it into place, point `current` at it.
- (BOOL)install:(RMGameUpdateSet *)set from:(NSString *)partial why:(NSString **)why {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![set.manifestData writeToFile:[partial stringByAppendingPathComponent:@"manifest.json"] atomically:YES] ||
        ![set.signature writeToFile:[partial stringByAppendingPathComponent:@"manifest.sig"] atomically:YES]) {
        *why = @"could not write the manifest beside the jars";
        return NO;
    }
    NSString *final = [[self setsDir] stringByAppendingPathComponent:set.setId];
    if ([set.setId isEqualToString:self.bootedSetId]) {
        // This process runs from that directory already: never touch it, just point at it again.
        [fm removeItemAtPath:partial error:nil];
    } else {
        [fm removeItemAtPath:final error:nil];
        if (![fm moveItemAtPath:partial toPath:final error:nil]) {
            *why = @"could not move the set into place";
            return NO;
        }
    }
    [self writeString:set.setId to:@"current"];
    // A cookie for some other set means nothing for this one.
    NSInteger n = 0;
    NSString *cookie = [self cookieId:&n];
    if (cookie && ![cookie isEqualToString:self.bootedSetId ?: @""])
        [fm removeItemAtPath:[self path:@"boot-armed"] error:nil];
    return YES;
}

@end
