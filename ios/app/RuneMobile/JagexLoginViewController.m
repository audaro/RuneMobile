#import "JagexLoginViewController.h"
#import <WebKit/WebKit.h>

// ── Jagex OAuth constants — verbatim from ios/dev-tools/fetch-shield-tokens.sh (Stage A consent flow) ──
// Pinned across all three login impls by tools/shared-contract/auth-contract.json — a change here that
// isn't mirrored to the Android port + the script fails check-auth-contract.sh (pre-commit + release gate).
// Stage A produces the id_token the game-session API accepts (the launcher client's id_token is rejected
// with INVALID_ID_TOKEN). redirect_uri is a loopback that never loads; we intercept the navigation to it
// and read the id_token out of the URL fragment.
static NSString *const kAuthEndpoint    = @"https://account.jagex.com/oauth2/auth";
static NSString *const kConsentClientId = @"1fddee4e-b100-4f4e-b2b0-097f9088f9d2";
static NSString *const kConsentRedirect = @"http://localhost";
static NSString *const kConsentScope    = @"openid offline";
static NSString *const kSessionsURL     = @"https://auth.runescape.com/game-session/v1/sessions";
static NSString *const kAccountsURL     = @"https://auth.runescape.com/game-session/v2/accounts?fetchMembership=true";
// Cloudflare in front of the game-session API is User-Agent sensitive — match the official Mac launcher.
static NSString *const kLauncherUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    @"JagexLauncher/2.4.4 Chrome/120.0.0.0 Safari/537.36";

@interface JagexLoginViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, copy)   NSString *nonce;
@property (nonatomic, copy)   NSString *oauthState;
@property (nonatomic, assign) BOOL captured;   // handle the redirect exactly once
- (void)teardownWeb;
@end

@implementation JagexLoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.nonce      = [self randomToken];
    self.oauthState = [self randomToken];

    // Top bar with a Close button.
    UIView *bar = [UIView new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    [self.view addSubview:bar];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Log in with Jagex";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [bar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:close];

    // Embedded login web view. Use an EPHEMERAL data store so each login starts with NO Jagex cookies —
    // otherwise the IdP auto-authenticates the last account from a warm SSO cookie and you can't switch
    // accounts. Staying logged in between launches is carried by tokens.json (the game session), not by
    // persisted web cookies, so a clean web session here costs nothing.
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self;
    [self.view addSubview:self.web];

    // Progress / verdict strip.
    self.logView = [UITextView new];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.editable = NO;
    self.logView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.logView.textColor = [UIColor greenColor];
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    [self.view addSubview:self.logView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:g.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:44],
        [title.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [title.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14],
        [close.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [self.web.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.logView.topAnchor constraintEqualToAnchor:self.web.bottomAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [self.logView.heightAnchor constraintEqualToConstant:96],
    ]];

    [self log:@"Loading Jagex login…"];
    [self loadConsent];
}

- (void)loadConsent {
    NSURLComponents *c = [NSURLComponents componentsWithString:kAuthEndpoint];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"id_token code"], // OIDC hybrid
        [NSURLQueryItem queryItemWithName:@"client_id"     value:kConsentClientId],
        [NSURLQueryItem queryItemWithName:@"redirect_uri"  value:kConsentRedirect],
        [NSURLQueryItem queryItemWithName:@"scope"         value:kConsentScope],
        [NSURLQueryItem queryItemWithName:@"nonce"         value:self.nonce],
        [NSURLQueryItem queryItemWithName:@"state"         value:self.oauthState],
    ];
    [self.web loadRequest:[NSURLRequest requestWithURL:c.URL]];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    // The consent flow redirects to http://localhost/#id_token=…&code=…&state=… — a loopback that won't
    // load. Catch it BEFORE the (doomed) navigation and pull the id_token from the fragment. The decision
    // delegate fires ahead of the network layer, so ATS never blocks the http://localhost we cancel.
    if ([url.host isEqualToString:@"localhost"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if (!self.captured) {
            self.captured = YES;
            [self handleConsentRedirect:url];
        }
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    if ([self isBenignCancel:error]) return;   // our own cancel of the localhost redirect
    [self log:[NSString stringWithFormat:@"nav error: %@", error.localizedDescription]];
}

// The cancel we issue for the localhost redirect surfaces as NSURLErrorCancelled (-999) or
// WebKitErrorDomain 102 ("Frame load interrupted") — both expected, not a real failure.
- (BOOL)isBenignCancel:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return YES;
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102) return YES;
    return NO;
}

- (void)handleConsentRedirect:(NSURL *)url {
    NSString *frag = url.fragment ?: @"";
    NSString *idToken = [self valueFor:@"id_token" in:frag];
    if (idToken.length == 0) {
        [self log:[NSString stringWithFormat:@"✗ no id_token in redirect (frag len=%lu)", (unsigned long)frag.length]];
        return;
    }
    // OAuth return-leg binding: the redirect must carry OUR `state` and the id_token's OIDC `nonce`
    // claim must be the one this view minted for the consent URL, so a token from any other consent
    // flow (or a hijacked in-page navigation) can't complete this sign-in. Re-arm `captured` on
    // rejection so a legitimate later redirect can still be handled.
    NSString *returnedState = [self valueFor:@"state" in:frag];
    if (![returnedState isEqualToString:self.oauthState] || ![[self nonceClaimOf:idToken] isEqualToString:self.nonce]) {
        self.captured = NO;
        [self log:@"✗ login response doesn't match this sign-in attempt — close and restart the sign-in"];
        return;
    }
    [self log:@"✓ authenticated — minting game session…"];
    self.web.hidden = YES;
    [self fetchSessionWithIdToken:idToken];
}

// Base64url-decode the JWT payload segment and return its OIDC `nonce` claim (@"" when absent or
// undecodable — which then fails the isEqualToString: binding check above).
- (NSString *)nonceClaimOf:(NSString *)jwt {
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2)
        return @"";
    NSMutableString *b64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [b64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b64.length)];
    while (b64.length % 4 != 0)
        [b64 appendString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!data)
        return @"";
    NSDictionary *claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![claims isKindOfClass:NSDictionary.class])
        return @"";
    NSString *nonce = claims[@"nonce"];
    return [nonce isKindOfClass:NSString.class] ? nonce : @"";
}

#pragma mark - Game-session API (native URLSession)

- (void)fetchSessionWithIdToken:(NSString *)idToken {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kSessionsURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:kLauncherUA        forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"idToken": idToken } options:0 error:nil];

    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { [self log:[NSString stringWithFormat:@"✗ session error: %@", error.localizedDescription]]; return; }
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *sessionId = [obj isKindOfClass:NSDictionary.class] ? obj[@"sessionId"] : nil;
            if (sessionId.length == 0) {
                [self log:[NSString stringWithFormat:@"✗ no sessionId (HTTP %ld): %@", (long)code, [self snippet:data]]];
                return;
            }
            [self fetchAccountsWithSession:sessionId];
        });
    }] resume];
}

- (void)fetchAccountsWithSession:(NSString *)sessionId {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAccountsURL]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", sessionId] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:kLauncherUA        forHTTPHeaderField:@"User-Agent"];

    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { [self log:[NSString stringWithFormat:@"✗ accounts error: %@", error.localizedDescription]]; return; }
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            id arr = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![arr isKindOfClass:NSArray.class] || [arr count] == 0) {
                [self log:[NSString stringWithFormat:@"✗ no characters (HTTP %ld): %@", (long)code, [self snippet:data]]];
                return;
            }
            [self log:[NSString stringWithFormat:@"✓ %lu character(s) — choose one:", (unsigned long)[arr count]]];
            [self presentPickerForAccounts:arr session:sessionId];
        });
    }] resume];
}

#pragma mark - Character picker

- (void)presentPickerForAccounts:(NSArray *)accounts session:(NSString *)sessionId {
    if (accounts.count == 1) {           // single character — no need to ask
        [self finishWithSession:sessionId account:accounts[0] accounts:accounts];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose character"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *a in accounts) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:[self labelForAccount:a]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) {
            [self finishWithSession:sessionId account:a accounts:accounts];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // iPhone-only target → action sheet presents without a popover anchor.
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)labelForAccount:(NSDictionary *)a {
    NSString *name = a[@"displayName"];
    if (name.length) return name;
    NSString *acc = a[@"accountId"] ?: @"";
    return [NSString stringWithFormat:@"Unnamed character (…%@)",
            acc.length > 4 ? [acc substringFromIndex:acc.length - 4] : acc];
}

- (void)finishWithSession:(NSString *)sessionId account:(NSDictionary *)a accounts:(NSArray *)accounts {
    NSString *accId = a[@"accountId"] ?: @"";
    NSString *name  = a[@"displayName"] ?: @"";
    [self log:[NSString stringWithFormat:@"✓ selected %@", name.length ? name : @"(unnamed)"]];
    // Release WebKit BEFORE the JVM is launched: tearing the web view down lets its WebContent/Networking
    // helper processes (and the memory + any fault handlers they carry) go away, so the subsequent
    // Start JVM runs as if from a clean launch. Lingering WebKit state is the leading suspect for the
    // same-session JVM crash — this is the in-app equivalent of the force-quit workaround.
    [self teardownWeb];
    if (self.onComplete) self.onComplete(sessionId, accId, name, accounts);
}

#pragma mark - helpers

// Pull a value out of an x-www-form-urlencoded fragment/query string.
- (NSString *)valueFor:(NSString *)key in:(NSString *)query {
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        if ([[pair substringToIndex:eq.location] isEqualToString:key]) {
            NSString *v = [pair substringFromIndex:eq.location + 1];
            return [v stringByRemovingPercentEncoding] ?: v;
        }
    }
    return nil;
}

- (NSString *)randomToken {
    uint8_t buf[24];
    arc4random_buf(buf, sizeof(buf));
    NSString *s = [[NSData dataWithBytes:buf length:sizeof(buf)] base64EncodedStringWithOptions:0];
    s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    s = [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return s;
}

- (NSString *)snippet:(NSData *)data {
    if (!data.length) return @"(no body)";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(binary)";
    return s.length > 300 ? [[s substringToIndex:300] stringByAppendingString:@"…"] : s;
}

// Only ever receives redacted lines (status / display names / verdicts) — never a raw token.
- (void)log:(NSString *)line {
#if DEBUG
    // QA-P1-12: NSLog writes to the iOS unified log (os_log), which persists on-device and is retrievable via
    // sysdiagnose/Console regardless of file-sharing — these lines include the character display name (account
    // PII) and, on error paths, raw Jagex HTTP response snippets. Dev-only; the on-screen logView stays.
    NSLog(@"[login] %@", line);
#endif
    if (self.onLog) self.onLog(line);
    self.logView.text = self.logView.text.length
        ? [NSString stringWithFormat:@"%@\n%@", self.logView.text, line] : line;
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
}

- (void)onClose {
    [self teardownWeb];
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Promptly release the web view (and with it WebKit's out-of-process WebContent/Networking helpers) so the
// JVM launch later this session isn't fighting WebKit for memory or fault handlers. Idempotent.
- (void)teardownWeb {
    if (!self.web) return;
    [self.web stopLoading];
    self.web.navigationDelegate = nil;
    [self.web removeFromSuperview];
    self.web = nil;
}

- (void)dealloc {
    [self teardownWeb];
}

@end
