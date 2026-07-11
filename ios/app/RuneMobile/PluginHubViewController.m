#import "PluginHubViewController.h"
#import "JVMLauncher.h"

@interface PluginHubViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) NSArray<NSMutableDictionary *> *all;     // every hub plugin
@property (nonatomic, strong) NSArray<NSMutableDictionary *> *shown;   // filtered view
@property (nonatomic, copy)   NSString *filter;
@property (nonatomic, strong) NSTimer *pollTimer;
// #17 install progress: while a hub install/remove is in-flight (jar download + plugin load happen async,
// completing with ExternalPluginsChanged) we poll MobileUiBridge.hubState ({refreshing,seq}) and surface a
// spinner + per-row "…" until it settles, then reconcile the real installed flags (catches silent failures).
@property (nonatomic, strong) NSTimer *hubProgressTimer;
@property (nonatomic, strong) NSMutableSet<NSString *> *inflight;   // internalNames currently installing/removing
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSDate *progressStartedAt;           // deadline anchor so the spinner can't hang
@end

@implementation PluginHubViewController

- (instancetype)init {
    if ((self = [super init])) {
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        _all = @[]; _shown = @[]; _filter = @"";
        _inflight = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Plugin Hub";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor];
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    done.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [done addTarget:self action:@selector(onDone) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    self.search = [[UISearchBar alloc] init];
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    self.search.delegate = self;
    self.search.placeholder = @"Search plugins";
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.barStyle = UIBarStyleBlack;
    [self.view addSubview:self.search];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.text = @"Loading manifest…";
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    // Fixed row height (NOT UITableViewAutomaticDimension): with ~1700 rows the estimated-height path
    // mis-sizes the content and rows drift out from under the finger (taps hit the wrong plugin). A fixed
    // height keeps hit-testing aligned. The 2-line description truncates.
    self.table.rowHeight = 68;
    self.table.estimatedRowHeight = 0;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.table];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [self.search.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [self.search.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:8],
        [self.search.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-8],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:4],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.statusLabel.centerYAnchor],
        [self.spinner.leadingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor constant:8],
        [self.table.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:6],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Poll the manifest until it's downloaded (Java fetches it on a background thread).
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                    selector:@selector(pollManifest) userInfo:nil repeats:YES];
    [self pollManifest];
}

- (void)onDone {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self stopHubProgress];
    [JVMLauncher mobileFlushConfig];   // persist the installed-plugins list
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)pollManifest {
    NSString *json = [JVMLauncher mobileHubManifest];
    if (!json.length) { self.statusLabel.text = @"Bridge not ready…"; return; }
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:&err];
    if (![parsed isKindOfClass:[NSDictionary class]]) return;
    NSString *status = parsed[@"status"];
    if ([status isEqualToString:@"loading"]) { self.statusLabel.text = @"Downloading manifest…"; return; }
    if (![status isEqualToString:@"ok"]) {
        self.statusLabel.text = [NSString stringWithFormat:@"Manifest unavailable (%@)", status];
        [self.pollTimer invalidate]; self.pollTimer = nil;
        return;
    }
    // status ok — load once, stop polling.
    [self.pollTimer invalidate]; self.pollTimer = nil;
    NSArray *plugins = parsed[@"plugins"];
    NSMutableArray *rows = [NSMutableArray array];
    if ([plugins isKindOfClass:[NSArray class]]) {
        for (NSDictionary *p in plugins) [rows addObject:[p mutableCopy]];
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [([a[@"displayName"] description] ?: @"") caseInsensitiveCompare:([b[@"displayName"] description] ?: @"")];
        }];
    }
    self.all = rows;
    [self applyFilter];
    self.statusLabel.text = [NSString stringWithFormat:@"%lu plugins", (unsigned long)self.all.count];
}

- (void)applyFilter {
    if (self.filter.length == 0) {
        self.shown = self.all;
    } else {
        NSString *f = self.filter.lowercaseString;
        NSMutableArray *out = [NSMutableArray array];
        for (NSMutableDictionary *p in self.all) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@",
                             p[@"displayName"] ?: @"", p[@"author"] ?: @"", p[@"description"] ?: @""];
            if ([hay.lowercaseString containsString:f]) [out addObject:p];
        }
        self.shown = out;
    }
    [self.table reloadData];
}

#pragma mark search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.filter = searchText ?: @"";
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"hubCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.66 alpha:1.0];
        cell.detailTextLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, 0, 92, 30);
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        btn.layer.cornerRadius = 7;
        [btn addTarget:self action:@selector(onToggleInstall:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = btn;
    }
    NSDictionary *p = self.shown[(NSUInteger)indexPath.row];
    NSString *author = [p[@"author"] isKindOfClass:[NSString class]] ? p[@"author"] : @"";
    NSString *desc = [p[@"description"] isKindOfClass:[NSString class]] ? p[@"description"] : @"";
    cell.textLabel.text = [p[@"displayName"] description];
    cell.detailTextLabel.text = author.length ? [NSString stringWithFormat:@"%@ — %@", author, desc] : desc;

    UIButton *btn = (UIButton *)cell.accessoryView;
    btn.tag = indexPath.row;
    BOOL unavailable = [p[@"unavailable"] isKindOfClass:[NSString class]] && [p[@"unavailable"] length] > 0;
    BOOL installed = [p[@"installed"] boolValue];
    BOOL installing = [p[@"installing"] boolValue];
    if (installing) {
        // In-flight: the row shows progress (the global spinner carries the verb); button is inert until settle.
        [btn setTitle:@"…" forState:UIControlStateNormal];
        btn.enabled = NO;
        btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        btn.tintColor = [UIColor whiteColor];
    } else if (unavailable) {
        [btn setTitle:@"N/A" forState:UIControlStateNormal];
        btn.enabled = NO;
        btn.backgroundColor = [UIColor clearColor];
        btn.tintColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    } else {
        btn.enabled = YES;
        [btn setTitle:(installed ? @"Remove" : @"Install") forState:UIControlStateNormal];
        btn.backgroundColor = installed ? [UIColor colorWithWhite:1 alpha:0.12]
                                        : [UIColor colorWithRed:0.20 green:0.45 blue:0.22 alpha:1.0];
        btn.tintColor = [UIColor whiteColor];
    }
    return cell;
}

- (void)onToggleInstall:(UIButton *)btn {
    NSInteger row = btn.tag;
    if (row < 0 || row >= (NSInteger)self.shown.count) return;
    NSMutableDictionary *p = self.shown[(NSUInteger)row];
    BOOL installed = [p[@"installed"] boolValue];
    NSString *name = [p[@"internalName"] description];
    if (name.length == 0) return;
    NSString *ack = [JVMLauncher mobileHubInstall:name uninstall:installed];
    // Optimistic flip + mark in-flight; #17 polls hubState until the async download+load settles.
    p[@"installed"] = @(!installed);
    p[@"installing"] = @YES;
    [self.inflight addObject:name];
    [self.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]]
                      withRowAnimation:UITableViewRowAnimationNone];
    self.statusLabel.text = installed ? [NSString stringWithFormat:@"Removing %@…", [p[@"displayName"] description]]
                                      : [NSString stringWithFormat:@"Installing %@…", [p[@"displayName"] description]];
    [self.spinner startAnimating];
    self.progressStartedAt = [NSDate date];   // (re)anchor the deadline on every tap
    [self startHubProgressPolling];
#if DEBUG
    // QA-P1-12: dev-only — keep hub action/name out of the persistent unified log in the hardened build.
    NSLog(@"[hub] %@ %@ : %@", installed ? @"remove" : @"install", name, ack ?: @"(nil)");
#endif
}

#pragma mark - #17 install progress

- (void)startHubProgressPolling {
    if (self.hubProgressTimer) return;   // one shared poller for any concurrent installs
    self.hubProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self
                                                          selector:@selector(pollHubProgress) userInfo:nil repeats:YES];
}

- (void)pollHubProgress {
    NSTimeInterval elapsed = self.progressStartedAt ? -[self.progressStartedAt timeIntervalSinceNow] : 0;
    NSString *json = [JVMLauncher mobileHubState];
    NSDictionary *d = json.length
        ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]
        : nil;
    BOOL haveState = [d isKindOfClass:[NSDictionary class]];
    BOOL refreshing = haveState && [d[@"refreshing"] boolValue];

    // Clean completion: hubInstall sets refreshing=true synchronously, so a readable false means the async
    // download+load finished (ExternalPluginsChanged cleared it).
    if (haveState && !refreshing) { [self settleHubProgress]; return; }

    // Otherwise still refreshing, OR the bridge can't report state at all (mobileHubState nil — older jar /
    // unresolved method). Never hang: cap the wait. Genuine refresh gets a generous window; an unreadable
    // state settles quickly (fire-and-forget, then reconcile against the manifest = the source of truth).
    NSTimeInterval deadline = haveState ? 25.0 : 2.5;
    if (elapsed >= deadline) { [self settleHubProgress]; }
}

// Reconcile the real installed flags from the manifest (corrects a silent failure), clear the in-flight rows,
// and stop the spinner. Idempotent — safe whether we reached it by completion or by deadline.
- (void)settleHubProgress {
    if (self.inflight.count > 0) {
        [self reconcileInstalledState];
        [self.inflight removeAllObjects];
    }
    [self stopHubProgress];
}

// Re-read the manifest (cached in Java) and trust its installed flags for the rows that were in-flight, so a
// silent install/remove failure is corrected rather than left showing the optimistic state.
- (void)reconcileInstalledState {
    NSString *json = [JVMLauncher mobileHubManifest];
    NSDictionary *parsed = json.length
        ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]
        : nil;
    NSArray *plugins = [parsed isKindOfClass:[NSDictionary class]] ? parsed[@"plugins"] : nil;
    NSMutableDictionary<NSString *, NSNumber *> *installedMap = [NSMutableDictionary dictionary];
    if ([plugins isKindOfClass:[NSArray class]]) {
        for (NSDictionary *pp in plugins) {
            NSString *n = [pp[@"internalName"] description];
            if (n.length) installedMap[n] = @([pp[@"installed"] boolValue]);
        }
    }
    for (NSMutableDictionary *p in self.all) {
        NSString *n = [p[@"internalName"] description];
        if (n.length && [self.inflight containsObject:n]) {
            NSNumber *truth = installedMap[n];
            if (truth) p[@"installed"] = truth;   // correct the optimistic flip if the refresh disagreed
            [p removeObjectForKey:@"installing"];
        }
    }
    [self applyFilter];
    self.statusLabel.text = [NSString stringWithFormat:@"%lu plugins", (unsigned long)self.all.count];
}

- (void)stopHubProgress {
    [self.hubProgressTimer invalidate];
    self.hubProgressTimer = nil;
    [self.spinner stopAnimating];
}

@end
