// RMGameUpdate - new game files without a reinstall (docs/GAME-UPDATES-PLAN.md, local).
//
// When the game moves to a new revision, the Mac publishes a signed manifest naming a new set of the three jars this
// app boots (client-shaded, client-rlhd, probes), built for this exact shell commit. This class fetches and verifies
// that manifest, downloads and hash-checks a set, and at each boot picks the set to run: the newest verified
// download, or the jars in the app bundle. A set that twice fails to reach the engine's first frame is marked bad and
// the bundled jars run again. Nothing here runs Java or touches the network on its own: the cover, the fatal card and
// the JVM boot call in.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RMGameUpdateLog)(NSString *line);

// One verified set of jars for this shell, from a signed manifest.
@interface RMGameUpdateSet : NSObject
@property (nonatomic, copy, readonly) NSString *setId;
@property (nonatomic, assign, readonly) NSInteger manifestRevision;
@property (nonatomic, assign, readonly) NSInteger gameRevision;
@property (nonatomic, copy, readonly) NSString *runelite;
// The Plugin Hub version to pass the JVM instead of the bundled pin, or nil to keep it.
@property (nonatomic, copy, readonly, nullable) NSString *pluginHubVersion;
// The publisher's call: this set replaces jars the game no longer accepts, so the cover waits for it.
@property (nonatomic, assign, readonly) BOOL required;
@property (nonatomic, assign, readonly) long long totalBytes;
// The installed directory, once the set is on disk and verified.
@property (nonatomic, copy, readonly, nullable) NSString *dir;
- (NSString *)pathForJar:(NSString *)name;
@end

typedef NS_ENUM(NSInteger, RMGameUpdateCheckResult) {
    RMGameUpdateCheckDisabled, // this build takes no game updates (a dev build: not a clean, stamped commit)
    RMGameUpdateCheckFailed,   // network or verification failure: nothing is known
    RMGameUpdateCheckNoSet,    // a valid manifest has no usable set for this build: only a new app build helps
    RMGameUpdateCheckCurrent,  // the newest set for this build is already installed
    RMGameUpdateCheckOffer,    // a newer set is available to download
};

@interface RMGameUpdate : NSObject
+ (instancetype)shared;
// The commit this app was built from (Info.plist RMSourceCommit), "-dirty" suffixed for a modified tree.
+ (NSString *)shellCommit;
// Whether this build takes game updates at all: a clean 40-hex commit stamp (or, in Debug, -RMGameUpdateShell).
@property (nonatomic, readonly) BOOL enabled;

// Boot path, on the JVM's thread before JNI_CreateJavaVM. Returns the installed set to boot (fully re-verified),
// or nil for the bundled jars. A set whose last boots never settled is marked bad here.
- (nullable RMGameUpdateSet *)setForBootWithLog:(RMGameUpdateLog)log;
// Arm the boot cookie for the set about to boot.
- (void)armBoot:(RMGameUpdateSet *)set;
// The booted set works (first frame, or the engine reached the network): clear the cookie. Idempotent.
- (void)settleBoot;
// The set this process booted, or nil for the bundled jars (or before boot).
@property (atomic, copy, readonly, nullable) NSString *bootedSetId;

// Network. Completions run on the main queue. A second call while one is in flight joins it.
- (void)check:(void (^)(RMGameUpdateCheckResult result, RMGameUpdateSet *_Nullable offer, NSString *detail))completion;
- (void)download:(RMGameUpdateSet *)set
        progress:(nullable void (^)(long long done, long long total))progress
      completion:(void (^)(BOOL ok, NSString *detail))completion;
@property (atomic, readonly) BOOL downloading;
// A set newer than the one this process runs is installed: the next launch boots it.
@property (atomic, readonly) BOOL readyForNextLaunch;
// One line for Share logs: what booted, what is installed, the last check.
@property (atomic, copy, readonly) NSString *statusLine;
@end

NS_ASSUME_NONNULL_END
