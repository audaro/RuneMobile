#import <UIKit/UIKit.h>

// On-device Jagex account login (Phase 6 login UX). Runs the Stage-A "consent" OAuth flow from
// ios/dev-tools/fetch-shield-tokens.sh entirely on the phone in an embedded WKWebView, then mints a game
// session + fetches the character list natively — so the user signs in with NO computer. On success it
// reports the chosen character via -onComplete; the caller persists it to tokens.json (the JX_* autologin
// path that loadJagexTokens already reads). No raw token is ever logged or surfaced.
//
// Proven by the login spike (commit 1c746a18): embedded WKWebView is not blocked and the http://localhost
// loopback redirect is interceptable; sessions + accounts return HTTP 200 on device.
@interface JagexLoginViewController : UIViewController
// Mirror each (redacted) progress line to the parent console (optional).
@property (nonatomic, copy) void (^onLog)(NSString *line);
// Called on the main thread once the user has authenticated AND chosen a character. `accounts` is the raw
// game-session account list (kept for persistence). NOT called if the user closes/cancels first.
@property (nonatomic, copy) void (^onComplete)(NSString *sessionId,
                                               NSString *accountId,
                                               NSString *displayName,
                                               NSArray *accounts);
@end
