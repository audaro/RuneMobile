#import "PluginConfigViewController.h"
#import "JVMLauncher.h"

#pragma mark - Set multi-select chooser (#5)

// A full-screen modal checklist for a Set<Enum> config item: every enum constant is a tappable row with a
// checkmark; Done returns the selected element names so the editor can write them back as a json-array.
@interface MUISetChooser : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation MUISetChooser {
    NSString *_title;
    NSArray<NSString *> *_choices;
    NSMutableSet<NSString *> *_selected;
    void (^_onDone)(NSArray<NSString *> *);
    UITableView *_table;
}

- (instancetype)initWithTitle:(NSString *)title choices:(NSArray<NSString *> *)choices
                     selected:(NSArray<NSString *> *)selected onDone:(void (^)(NSArray<NSString *> *))onDone {
    if ((self = [super init])) {
        _title = [title copy];
        _choices = [choices copy] ?: @[];
        _selected = [NSMutableSet setWithArray:(selected ?: @[])];
        _onDone = [onDone copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = _title ?: @"Select";
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

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = [UIColor clearColor];
    _table.dataSource = self;
    _table.delegate = self;
    [self.view addSubview:_table];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [_table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)onDone {
    // Preserve the choices' declaration order in the written array (stable, matches the enum order).
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *c in _choices) { if ([_selected containsObject:c]) [out addObject:c]; }
    if (_onDone) _onDone(out);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_choices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSString *c = _choices[indexPath.row];
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.text = c;
    cell.accessoryType = [_selected containsObject:c]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *c = _choices[indexPath.row];
    if ([_selected containsObject:c]) [_selected removeObject:c]; else [_selected addObject:c];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - Bounded int slider (CFG-7)

// A full-screen slider editor for an int config item with a @Range — snaps to integers, shows the live value
// (+ units) and the min/max so the user can see the bounds desktop renders as a JSpinner.
@interface MUISliderEditor : UIViewController
@end

@implementation MUISliderEditor {
    NSString *_title; long long _min; long long _max; long long _value; NSString *_units;
    void (^_onDone)(long long);
    UISlider *_slider; UILabel *_valueLabel;
}

- (instancetype)initWithTitle:(NSString *)title min:(long long)mn max:(long long)mx value:(long long)val
                        units:(NSString *)units onDone:(void (^)(long long))onDone {
    if ((self = [super init])) {
        _title = [title copy]; _min = mn; _max = mx; _value = MAX(mn, MIN(mx, val));
        _units = [units copy] ?: @""; _onDone = [onDone copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    UIColor *gold = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = _title ?: @"Value"; title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor]; title.numberOfLines = 0;
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16]; done.tintColor = gold;
    [done addTarget:self action:@selector(onDoneTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16];
    cancel.tintColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [cancel addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:44 weight:UIFontWeightBold];
    _valueLabel.textColor = [UIColor whiteColor]; _valueLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_valueLabel];

    _slider = [[UISlider alloc] init];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.minimumValue = (float)_min; _slider.maximumValue = (float)_max; _slider.value = (float)_value;
    _slider.minimumTrackTintColor = gold;
    [_slider addTarget:self action:@selector(onSlide) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_slider];

    UILabel *minL = [[UILabel alloc] init];
    minL.translatesAutoresizingMaskIntoConstraints = NO;
    minL.text = [NSString stringWithFormat:@"%lld", _min];
    minL.font = [UIFont systemFontOfSize:13]; minL.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    [self.view addSubview:minL];
    UILabel *maxL = [[UILabel alloc] init];
    maxL.translatesAutoresizingMaskIntoConstraints = NO;
    maxL.text = [NSString stringWithFormat:@"%lld", _max];
    maxL.font = [UIFont systemFontOfSize:13]; maxL.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    [self.view addSubview:maxL];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:cancel.leadingAnchor constant:-8],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [cancel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-16],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [_valueLabel.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [_slider.topAnchor constraintEqualToAnchor:_valueLabel.bottomAnchor constant:30],
        [_slider.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:30],
        [_slider.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-30],
        [minL.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:6],
        [minL.leadingAnchor constraintEqualToAnchor:_slider.leadingAnchor],
        [maxL.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:6],
        [maxL.trailingAnchor constraintEqualToAnchor:_slider.trailingAnchor],
    ]];
    [self updateLabel];
}

- (void)onSlide { _value = (long long)llroundf(_slider.value); [self updateLabel]; }
- (void)updateLabel { _valueLabel.text = [NSString stringWithFormat:@"%lld%@", _value, _units]; }
- (void)onDoneTap { if (_onDone) _onDone(_value); [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)onCancel { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - Multi-line string editor (CFG-9)

// A full-screen UITextView editor for String config (desktop renders String as a wrapping JTextArea), so
// newline-delimited list values (ChatFilter words/regex/names) are editable.
@interface MUITextEditor : UIViewController
@end

@implementation MUITextEditor {
    NSString *_title; NSString *_initial; void (^_onDone)(NSString *);
    UITextView *_tv;
}

- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text onDone:(void (^)(NSString *))onDone {
    if ((self = [super init])) {
        _title = [title copy]; _initial = [text copy] ?: @""; _onDone = [onDone copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];
    UIColor *gold = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = _title ?: @"Edit"; title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor]; title.numberOfLines = 0;
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16]; done.tintColor = gold;
    [done addTarget:self action:@selector(onDoneTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16];
    cancel.tintColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [cancel addTarget:self action:@selector(onCancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    _tv = [[UITextView alloc] init];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.text = _initial;
    _tv.font = [UIFont systemFontOfSize:16];
    _tv.textColor = [UIColor whiteColor];
    _tv.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    _tv.layer.cornerRadius = 8;
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.keyboardAppearance = UIKeyboardAppearanceDark;
    [self.view addSubview:_tv];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:cancel.leadingAnchor constant:-8],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [cancel.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-16],
        [_tv.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [_tv.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:16],
        [_tv.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-16],
        [_tv.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-10],
    ]];
    [_tv becomeFirstResponder];
}

- (void)onDoneTap { if (_onDone) _onDone(_tv.text ?: @""); [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)onCancel { [self dismissViewControllerAnimated:YES completion:nil]; }

@end

#pragma mark - Notification sub-editor (NOTIF-2)

// A pushed editor for one Notification config item: enabled / game-message / sound type / flash mode / flash
// color / volume — the mobile-relevant subset of the desktop NotificationPanel. Edits the serialized Notification
// dict in place (override+initialized forced true so the engine uses these fields) and returns it via onDone.
@interface MUINotificationEditor : UIViewController <UITableViewDataSource, UITableViewDelegate, UIColorPickerViewControllerDelegate>
@end

@implementation MUINotificationEditor {
    NSString *_title;
    NSMutableDictionary *_n;            // working Notification dict
    void (^_onDone)(NSDictionary *);
    UITableView *_table;
}

// Row identifiers, in display order.
typedef NS_ENUM(NSInteger, MUINotifRow) {
    MUINotifEnabled = 0, MUINotifGameMsg, MUINotifSound, MUINotifFlash, MUINotifFlashColor, MUINotifVolume, MUINotifRowCount
};

- (instancetype)initWithTitle:(NSString *)title notification:(NSMutableDictionary *)n
                       onDone:(void (^)(NSDictionary *))onDone {
    if ((self = [super init])) {
        _title = [title copy];
        _n = n ?: [NSMutableDictionary dictionary];
        _onDone = [onDone copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = _title ?: @"Notification"; title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor whiteColor]; title.numberOfLines = 0;
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    done.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    [done addTarget:self action:@selector(onDoneTap) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = [UIColor clearColor];
    _table.dataSource = self; _table.delegate = self; _table.delaysContentTouches = NO;
    [self.view addSubview:_table];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [_table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

// Any edit means the user is customizing this notification: force override+initialized so the engine honors it.
- (void)markCustomized { _n[@"override"] = @YES; _n[@"initialized"] = @YES; }

- (void)onDoneTap {
    [self markCustomized];
    if (_onDone) _onDone(_n);
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Flash modes: (display, stored enum name). Sound types likewise.
+ (NSArray<NSArray<NSString *> *> *)flashOptions {
    return @[@[@"Off", @"DISABLED"], @[@"Flash for 2 seconds", @"FLASH_TWO_SECONDS"],
             @[@"Solid for 2 seconds", @"SOLID_TWO_SECONDS"], @[@"Flash until cancelled", @"FLASH_UNTIL_CANCELLED"],
             @[@"Solid until cancelled", @"SOLID_UNTIL_CANCELLED"]];
}
+ (NSArray<NSArray<NSString *> *> *)soundOptions {
    return @[@[@"Native", @"NATIVE"], @[@"Custom", @"CUSTOM"], @[@"Off", @"OFF"]];
}
+ (NSString *)displayFor:(NSString *)value in:(NSArray<NSArray<NSString *> *> *)opts fallback:(NSString *)fb {
    for (NSArray *pair in opts) { if ([pair[1] isEqual:value]) return pair[0]; }
    return fb;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return MUINotifRowCount; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    switch ((MUINotifRow)indexPath.row) {
        case MUINotifEnabled: {
            cell.textLabel.text = @"Enabled";
            cell.accessoryView = [self switchFor:@"enabled" defaultOn:NO action:@selector(onEnabled:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case MUINotifGameMsg: {
            cell.textLabel.text = @"Game message";
            cell.accessoryView = [self switchFor:@"gameMessage" defaultOn:NO action:@selector(onGameMsg:)];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case MUINotifSound: {
            cell.textLabel.text = @"Sound";
            cell.detailTextLabel.text = [MUINotificationEditor displayFor:_n[@"sound"]
                in:[MUINotificationEditor soundOptions] fallback:@"Native"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MUINotifFlash: {
            cell.textLabel.text = @"Flash";
            cell.detailTextLabel.text = [MUINotificationEditor displayFor:_n[@"flash"]
                in:[MUINotificationEditor flashOptions] fallback:@"Off"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MUINotifFlashColor: {
            cell.textLabel.text = @"Flash color";
            UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
            sw.backgroundColor = [self colorFromHex:_n[@"flashColor"]] ?: [UIColor clearColor];
            sw.layer.cornerRadius = 5; sw.layer.borderWidth = 1;
            sw.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
            cell.accessoryView = sw;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case MUINotifVolume: {
            cell.textLabel.text = @"Volume";
            int v = _n[@"volume"] ? [_n[@"volume"] intValue] : 100;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d%%", v];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        default: break;
    }
    return cell;
}

- (UISwitch *)switchFor:(NSString *)key defaultOn:(BOOL)def action:(SEL)action {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = _n[key] ? [_n[key] boolValue] : def;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return sw;
}

- (void)onEnabled:(UISwitch *)sw { _n[@"enabled"] = @(sw.isOn); [self markCustomized]; }
- (void)onGameMsg:(UISwitch *)sw { _n[@"gameMessage"] = @(sw.isOn); [self markCustomized]; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch ((MUINotifRow)indexPath.row) {
        case MUINotifSound:
            [self pickFrom:[MUINotificationEditor soundOptions] title:@"Sound" key:@"sound" at:indexPath];
            break;
        case MUINotifFlash:
            [self pickFrom:[MUINotificationEditor flashOptions] title:@"Flash" key:@"flash" at:indexPath];
            break;
        case MUINotifFlashColor: {
            UIColorPickerViewController *cp = [[UIColorPickerViewController alloc] init];
            cp.delegate = self; cp.supportsAlpha = YES;
            UIColor *seed = [self colorFromHex:_n[@"flashColor"]];
            if (seed) cp.selectedColor = seed;
            [self presentViewController:cp animated:YES completion:nil];
            break;
        }
        case MUINotifVolume: {
            int v = _n[@"volume"] ? [_n[@"volume"] intValue] : 100;
            MUISliderEditor *ed = [[MUISliderEditor alloc] initWithTitle:@"Volume" min:0 max:100 value:v units:@"%"
                onDone:^(long long nv) {
                    self->_n[@"volume"] = @((int)nv); [self markCustomized];
                    [self->_table reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                }];
            [self presentViewController:ed animated:YES completion:nil];
            break;
        }
        default: break;
    }
}

- (void)pickFrom:(NSArray<NSArray<NSString *> *> *)opts title:(NSString *)t key:(NSString *)key at:(NSIndexPath *)ip {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray<NSString *> *pair in opts) {
        [ac addAction:[UIAlertAction actionWithTitle:pair[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            self->_n[key] = pair[1]; [self markCustomized];
            [self->_table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = [_table cellForRowAtIndexPath:ip];
    [self presentViewController:ac animated:YES completion:nil];
}

// Notification flashColor is stored as the gson ColorTypeAdapter's "#AARRGGBB" hex (distinct from a top-level
// Color config item, which is a signed decimal). Convert both ways here.
- (UIColor *)colorFromHex:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] < 7) return nil;
    NSString *s = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    unsigned long long v = 0; [[NSScanner scannerWithString:s] scanHexLongLong:&v];
    uint32_t argb = (uint32_t)v;
    if (s.length <= 6) argb |= 0xFF000000u;   // RGB without alpha → opaque
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0, r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0, b = (argb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}
- (NSString *)hexFromColor:(UIColor *)c {
    CGFloat r = 0, g = 0, b = 0, a = 1; [c getRed:&r green:&g blue:&b alpha:&a];
    uint32_t argb = ((uint32_t)lround(a * 255.0) << 24) | ((uint32_t)lround(r * 255.0) << 16)
        | ((uint32_t)lround(g * 255.0) << 8) | (uint32_t)lround(b * 255.0);
    return [NSString stringWithFormat:@"#%08X", argb];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)vc {
    _n[@"flashColor"] = [self hexFromColor:vc.selectedColor]; [self markCustomized];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    [_table reloadData];
}

@end

@interface PluginConfigViewController () <UITableViewDataSource, UITableViewDelegate, UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy) NSString *pluginName;
@property (nonatomic, copy) NSArray<NSString *> *whitelist;   // nil = full config; else only these keys, in order
@property (nonatomic, strong) UITableView *table;
// Sections in declaration order: each @{ @"name": NSString, @"items": NSMutableArray<NSMutableDictionary*> }.
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *sections;
// CFG-6: per-section-key collapsed state, persisted across loadItems re-reads (seeded from closedByDefault).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *sectionCollapsed;
// The item currently being edited via the system color picker (so the delegate callback knows the key/type).
@property (nonatomic, strong) NSMutableDictionary *colorEditItem;
@end

@implementation PluginConfigViewController

- (instancetype)initWithGroup:(NSString *)group pluginName:(NSString *)name {
    return [self initWithGroup:group pluginName:name whitelist:nil];
}

- (instancetype)initWithGroup:(NSString *)group pluginName:(NSString *)name
                    whitelist:(NSArray<NSString *> *)whitelist {
    if ((self = [super init])) {
        _group = [group copy];
        _pluginName = [name copy];
        _whitelist = [whitelist copy];
        _sections = [NSMutableArray array];
        _sectionCollapsed = [NSMutableDictionary dictionary];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.pluginName ?: @"Configuration";
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

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.dataSource = self;
    self.table.delegate = self;
    // Deliver touches to the cell controls immediately (snappier), but keep canCancelContentTouches at its
    // default so the list still scrolls normally.
    self.table.delaysContentTouches = NO;
    [self.view addSubview:self.table];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor constant:-20],
        [self.table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self loadItems];
}

- (void)onDone {
    // Persist edits now — iOS won't run RuneLite's shutdown/periodic flush when the app closes.
    [JVMLauncher mobileFlushConfig];
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Read getPluginConfig(group) and bucket items into sections (declaration order).
- (void)loadItems {
    [self.sections removeAllObjects];
    NSString *json = [JVMLauncher mobilePluginConfig:self.group];
    if (!json.length) { [self.table reloadData]; return; }
    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:&err];
    if (![parsed isKindOfClass:[NSDictionary class]]) { [self.table reloadData]; return; }
    NSArray *items = parsed[@"items"];
    if (![items isKindOfClass:[NSArray class]]) { [self.table reloadData]; return; }
    // Section metadata (key -> {name, description, closedByDefault}) for friendly, collapsible headers (CFG-6).
    NSMutableDictionary<NSString *, NSDictionary *> *metaByKey = [NSMutableDictionary dictionary];
    NSArray *secMeta = parsed[@"sections"];
    if ([secMeta isKindOfClass:[NSArray class]]) {
        for (NSDictionary *s in secMeta) {
            if ([s[@"key"] isKindOfClass:[NSString class]]) metaByKey[s[@"key"]] = s;
        }
    }
    // Curated (whitelist) mode: one flat section, items in whitelist order, skipping anything not present. No
    // collapsible sections and no whole-plugin reset (the 117HD whitelist must not reset its unported keys).
    if (self.whitelist) {
        NSMutableArray *picked = [NSMutableArray array];
        for (NSString *wantKey in self.whitelist) {
            for (NSDictionary *it in items) {
                if ([it[@"key"] isEqualToString:wantKey]) { [picked addObject:[it mutableCopy]]; break; }
            }
        }
        [self.sections addObject:[@{ @"key": @"", @"name": @"", @"items": picked,
                                     @"collapsible": @NO, @"collapsed": @NO } mutableCopy]];
        [self.table reloadData];
        return;
    }
    for (NSDictionary *it in items) {
        NSString *secKey = [it[@"section"] isKindOfClass:[NSString class]] ? it[@"section"] : @"";
        NSMutableDictionary *bucket = nil;
        for (NSMutableDictionary *s in self.sections) {
            if ([s[@"key"] isEqualToString:secKey]) { bucket = s; break; }
        }
        if (!bucket) {
            NSDictionary *meta = metaByKey[secKey];
            NSString *display = ([meta[@"name"] isKindOfClass:[NSString class]] && [meta[@"name"] length])
                ? meta[@"name"] : secKey;
            BOOL collapsible = secKey.length > 0;
            BOOL collapsed = collapsible
                && [self collapsedStateForKey:secKey defaultClosed:[meta[@"closedByDefault"] boolValue]];
            bucket = [@{ @"key": secKey, @"name": (display ?: @""), @"items": [NSMutableArray array],
                         @"collapsible": @(collapsible), @"collapsed": @(collapsed) } mutableCopy];
            [self.sections addObject:bucket];
        }
        [bucket[@"items"] addObject:[it mutableCopy]];
    }
    // CFG-10: a whole-plugin "Reset all settings" row in a trailing section (full config only).
    [self.sections addObject:[@{ @"key": @"__reset__", @"name": @"", @"collapsible": @NO, @"collapsed": @NO,
                                 @"items": [@[ [@{ @"type": @"resetPlugin" } mutableCopy] ] mutableCopy] } mutableCopy]];
    [self.table reloadData];
}

// Persisted collapse state for a section key (seed from closedByDefault on first encounter; remember user toggles).
- (BOOL)collapsedStateForKey:(NSString *)key defaultClosed:(BOOL)def {
    NSNumber *v = self.sectionCollapsed[key];
    if (v) return v.boolValue;
    self.sectionCollapsed[key] = @(def);
    return def;
}

- (NSMutableDictionary *)itemAt:(NSIndexPath *)ip {
    NSMutableArray *items = self.sections[ip.section][@"items"];
    return items[ip.row];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSMutableDictionary *s = self.sections[section];
    if ([s[@"collapsed"] boolValue]) return 0;   // CFG-6: a collapsed section shows only its header
    return (NSInteger)[s[@"items"] count];
}

// CFG-6: a tappable header showing the friendly section NAME + a collapse chevron. Empty-name sections (the
// no-section bucket and the trailing reset row) get no header.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSMutableDictionary *s = self.sections[section];
    NSString *name = s[@"name"];
    if (name.length == 0) return nil;
    BOOL collapsible = [s[@"collapsible"] boolValue];
    BOOL collapsed = [s[@"collapsed"] boolValue];
    UIView *header = [[UIView alloc] init];
    header.tag = section;
    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [UIFont boldSystemFontOfSize:13];
    lbl.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    NSString *chevron = collapsible ? (collapsed ? @"▸  " : @"▾  ") : @"";
    lbl.text = [NSString stringWithFormat:@"%@%@", chevron, name.uppercaseString];
    [header addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [lbl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [lbl.topAnchor constraintEqualToAnchor:header.topAnchor constant:14],
        [lbl.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6],
    ]];
    if (collapsible) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(onSectionHeaderTap:)];
        [header addGestureRecognizer:tap];
    }
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *name = self.sections[section][@"name"];
    return name.length ? 38.0 : 0.0001;
}

- (void)onSectionHeaderTap:(UITapGestureRecognizer *)g {
    NSInteger section = g.view.tag;
    if (section < 0 || section >= (NSInteger)self.sections.count) return;
    NSMutableDictionary *s = self.sections[section];
    BOOL collapsed = ![s[@"collapsed"] boolValue];
    s[@"collapsed"] = @(collapsed);
    NSString *key = s[@"key"];
    if (key.length) self.sectionCollapsed[key] = @(collapsed);
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:section]
              withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *it = [self itemAt:indexPath];
    NSString *type = it[@"type"];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.text = it[@"name"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSString *value = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : nil;

    if ([type isEqualToString:@"resetPlugin"]) {
        // CFG-10 synthetic row: reset the whole plugin's config to defaults (+ plugin.resetConfiguration()).
        cell.textLabel.text = @"Reset all settings";
        cell.textLabel.textColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.40 alpha:1.0];
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    if ([type isEqualToString:@"boolean"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [value isEqualToString:@"true"];
        sw.tag = (indexPath.section << 16) | indexPath.row;
        [sw addTarget:self action:@selector(onSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"color"]) {
        // Small swatch + the signed value as detail; tap opens the system color picker.
        UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        swatch.backgroundColor = [self colorFromSigned:value] ?: [UIColor clearColor];
        swatch.layer.cornerRadius = 5;
        swatch.layer.borderWidth = 1;
        swatch.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
        cell.accessoryView = swatch;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"int"] || [type isEqualToString:@"double"]
               || [type isEqualToString:@"string"] || [type isEqualToString:@"enum"]) {
        NSString *units = [it[@"units"] isKindOfClass:[NSString class]] ? it[@"units"] : @"";
        cell.detailTextLabel.text = value ? [value stringByAppendingString:units] : @"(default)";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"font"]) {
        // CFG-2: FontType preset. Map the stored value back to a friendly label via the choices/choiceValues pair.
        NSArray *choices = [it[@"choices"] isKindOfClass:[NSArray class]] ? it[@"choices"] : @[];
        NSArray *vals = [it[@"choiceValues"] isKindOfClass:[NSArray class]] ? it[@"choiceValues"] : @[];
        NSString *label = nil;
        for (NSUInteger i = 0; i < vals.count && i < choices.count; i++) {
            if ([vals[i] isEqual:value]) { label = choices[i]; break; }
        }
        cell.detailTextLabel.text = label ?: (value.length ? @"Custom" : @"(default)");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"dimension"]) {
        // "WIDTHxHEIGHT" (bridge encoding=WxH); tap opens a two-field editor.
        cell.detailTextLabel.text = value.length ? value : @"(default)";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"set"]) {
        // Set<Enum> (bridge encoding=json-array); show the selected element names; tap opens the multi-select.
        NSArray *sel = [self setValuesFrom:value];
        cell.detailTextLabel.text = sel.count ? [sel componentsJoinedByString:@", "] : @"(none)";
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([type isEqualToString:@"notification"]) {
        // The enabled switch is a quick on/off; tapping the row opens the full sub-editor (sound/flash/color/
        // game-message/volume) — NOTIF-2. The engine checks per-item enabled before falling back to defaults.
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self notificationEnabled:value];
        sw.tag = (indexPath.section << 16) | indexPath.row;
        [sw addTarget:self action:@selector(onNotificationSwitch:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;   // tap (not the switch) → sub-editor
    } else {
        // set / keybind / dimension / unknown → read-only for v1. Don't dump raw serialized blobs as the value.
        BOOL looksSerialized = [value hasPrefix:@"{"] || [value hasPrefix:@"["];
        cell.detailTextLabel.text = (value && !looksSerialized) ? value : @"(not editable yet)";
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *it = [self itemAt:indexPath];
    NSString *type = it[@"type"];
    if ([type isEqualToString:@"resetPlugin"]) {
        [self confirmResetPlugin];
    } else if ([type isEqualToString:@"enum"]) {
        [self editEnum:it at:indexPath];
    } else if ([type isEqualToString:@"font"]) {
        [self editFont:it at:indexPath];
    } else if ([type isEqualToString:@"color"]) {
        [self editColor:it];
    } else if ([type isEqualToString:@"notification"]) {
        [self editNotification:it at:indexPath];
    } else if ([type isEqualToString:@"int"]) {
        // CFG-7: a bounded int with a small span gets a slider; otherwise the number-pad editor.
        long long span = it[@"min"] && it[@"max"] ? ([it[@"max"] longLongValue] - [it[@"min"] longLongValue]) : -1;
        if (span > 0 && span <= 1000) {
            [self editBoundedInt:it at:indexPath];
        } else {
            [self editText:it type:@"int" at:indexPath];
        }
    } else if ([type isEqualToString:@"double"]) {
        [self editText:it type:@"double" at:indexPath];
    } else if ([type isEqualToString:@"string"]) {
        [self editTextMultiline:it at:indexPath];
    } else if ([type isEqualToString:@"dimension"]) {
        [self editDimension:it at:indexPath];
    } else if ([type isEqualToString:@"set"]) {
        [self editSet:it at:indexPath];
    }
}

// Reset-to-default via a trailing swipe on any editable row.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *it = [self itemAt:indexPath];
    NSString *type = it[@"type"];
    BOOL editable = [@[@"boolean", @"int", @"double", @"string", @"enum", @"color", @"dimension", @"set", @"font"]
                     containsObject:type ?: @""];
    if (!editable) return nil;
    __weak typeof(self) ws = self;
    UIContextualAction *reset = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"Reset" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
            [JVMLauncher mobileResetConfigGroup:ws.group key:it[@"key"]];
            // re-read the group after the client thread applies the default
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [ws loadItems]; });
            completion(YES);
        }];
    reset.backgroundColor = [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[reset]];
}

#pragma mark - editors

- (void)onSwitch:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(sw.tag & 0xFFFF) inSection:(sw.tag >> 16)];
    NSMutableDictionary *it = [self itemAt:ip];
    [self writeKey:it[@"key"] value:(sw.isOn ? @"true" : @"false") item:it];
}

// The "enabled" field of a serialized Notification config value (default YES when absent/unparseable).
- (BOOL)notificationEnabled:(NSString *)json {
    if (![json isKindOfClass:[NSString class]] || json.length == 0) return YES;
    id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return YES;
    id e = ((NSDictionary *)obj)[@"enabled"];
    return e ? [e boolValue] : YES;
}

// Toggle a Notification config item on/off by flipping ONLY its "enabled" field (preserving every other field),
// then writing the re-serialized object back. The engine checks per-item enabled first, so this turns the
// notification on/off without overriding the user's other notification settings.
- (void)onNotificationSwitch:(UISwitch *)sw {
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(sw.tag & 0xFFFF) inSection:(sw.tag >> 16)];
    NSMutableDictionary *it = [self itemAt:ip];
    NSString *cur = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : @"";
    NSMutableDictionary *obj = nil;
    if (cur.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[cur dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingMutableContainers error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) obj = parsed;
    }
    if (!obj) obj = [NSMutableDictionary dictionary];
    obj[@"enabled"] = @(sw.isOn);
    NSData *out = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    NSString *json = out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : nil;
    if (json) [self writeKey:it[@"key"] value:json item:it];
}

- (void)editEnum:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSArray *choices = [it[@"choices"] isKindOfClass:[NSArray class]] ? it[@"choices"] : @[];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:it[@"name"] message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *c in choices) {
        [ac addAction:[UIAlertAction actionWithTitle:c style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self writeKey:it[@"key"] value:c item:it];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = [self.table cellForRowAtIndexPath:ip];
    [self presentViewController:ac animated:YES completion:nil];
}

// CFG-2: FontType preset picker — write the constant name (REGULAR/BOLD/SMALL); FontTypeSerializer accepts it.
- (void)editFont:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSArray *choices = [it[@"choices"] isKindOfClass:[NSArray class]] ? it[@"choices"] : @[];
    NSArray *vals = [it[@"choiceValues"] isKindOfClass:[NSArray class]] ? it[@"choiceValues"] : @[];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:it[@"name"] message:it[@"description"]
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < choices.count; i++) {
        NSString *label = choices[i];
        NSString *val = i < vals.count ? vals[i] : label;
        [ac addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self writeKey:it[@"key"] value:val item:it];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = [self.table cellForRowAtIndexPath:ip];
    [self presentViewController:ac animated:YES completion:nil];
}

// CFG-7: bounded-int slider editor.
- (void)editBoundedInt:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    long long mn = [it[@"min"] longLongValue], mx = [it[@"max"] longLongValue];
    long long cur = [it[@"value"] isKindOfClass:[NSString class]] ? [it[@"value"] longLongValue] : mn;
    NSString *units = [it[@"units"] isKindOfClass:[NSString class]] ? it[@"units"] : @"";
    __weak typeof(self) ws = self;
    MUISliderEditor *ed = [[MUISliderEditor alloc] initWithTitle:it[@"name"] min:mn max:mx value:cur units:units
        onDone:^(long long v) {
            [ws writeKey:it[@"key"] value:[NSString stringWithFormat:@"%lld", v] item:it];
            [ws.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }];
    [self presentViewController:ed animated:YES completion:nil];
}

// CFG-9: multi-line string editor (desktop renders String as a wrapping JTextArea).
- (void)editTextMultiline:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSString *cur = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : @"";
    __weak typeof(self) ws = self;
    MUITextEditor *ed = [[MUITextEditor alloc] initWithTitle:it[@"name"] text:cur onDone:^(NSString *text) {
        [ws writeKey:it[@"key"] value:(text ?: @"") item:it];
        [ws.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }];
    [self presentViewController:ed animated:YES completion:nil];
}

// NOTIF-2: full per-notification sub-editor. Seed an uninitialized notification from the RuneLite defaults so
// override=true never leaves a field unset, then push the editor; on Done write the whole Notification JSON back.
- (void)editNotification:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSString *cur = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : @"";
    NSMutableDictionary *n = nil;
    if (cur.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[cur dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingMutableContainers error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) n = parsed;
    }
    if (!n) n = [NSMutableDictionary dictionary];
    if (![n[@"initialized"] boolValue]) {
        NSString *defJson = [JVMLauncher mobileNotificationDefaults];
        if (defJson.length) {
            id dp = [NSJSONSerialization JSONObjectWithData:[defJson dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:NSJSONReadingMutableContainers error:nil];
            if ([dp isKindOfClass:[NSDictionary class]]) {
                BOOL wasEnabled = [n[@"enabled"] boolValue];
                n = dp;
                n[@"enabled"] = @(wasEnabled);   // keep the current on/off; everything else seeded from defaults
            }
        }
    }
    __weak typeof(self) ws = self;
    MUINotificationEditor *ed = [[MUINotificationEditor alloc] initWithTitle:it[@"name"] notification:n
        onDone:^(NSDictionary *edited) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:edited options:0 error:nil];
            NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
            if (json) {
                [ws writeKey:it[@"key"] value:json item:it];
                [ws.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            }
        }];
    [self presentViewController:ed animated:YES completion:nil];
}

// CFG-10: confirm + reset the whole plugin's config (defaults + plugin.resetConfiguration()).
- (void)confirmResetPlugin {
    __weak typeof(self) ws = self;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reset all settings?"
        message:@"This restores every setting in this plugin to its default and clears any drawn markers/tiles."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [JVMLauncher mobileResetPluginConfig:ws.group];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [ws loadItems]; });
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)editText:(NSMutableDictionary *)it type:(NSString *)type at:(NSIndexPath *)ip {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:it[@"name"]
        message:it[@"description"] preferredStyle:UIAlertControllerStyleAlert];
    NSString *cur = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : @"";
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        if ([type isEqualToString:@"int"]) tf.keyboardType = UIKeyboardTypeNumberPad;
        else if ([type isEqualToString:@"double"]) tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *raw = ac.textFields.firstObject.text ?: @"";
        NSString *out = raw;
        if ([type isEqualToString:@"int"]) {
            long long v = [raw longLongValue];
            if (it[@"min"]) v = MAX(v, [it[@"min"] longLongValue]);
            if (it[@"max"]) v = MIN(v, [it[@"max"] longLongValue]);
            out = [NSString stringWithFormat:@"%lld", v];
        } else if ([type isEqualToString:@"double"]) {
            out = [NSString stringWithFormat:@"%g", [raw doubleValue]];
        }
        [self writeKey:it[@"key"] value:out item:it];
        [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Dimension editor: two number fields -> "WIDTHxHEIGHT" (the bridge's WxH encoding).
- (void)editDimension:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSString *cur = [it[@"value"] isKindOfClass:[NSString class]] ? it[@"value"] : @"";
    NSArray *parts = [cur componentsSeparatedByString:@"x"];
    NSString *cw = parts.count == 2 ? parts[0] : @"";
    NSString *ch = parts.count == 2 ? parts[1] : @"";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:it[@"name"]
        message:it[@"description"] preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Width"; tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = cw;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Height"; tf.keyboardType = UIKeyboardTypeNumberPad; tf.text = ch;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        int nw = [ac.textFields[0].text intValue];
        int nh = [ac.textFields[1].text intValue];
        if (nw <= 0 || nh <= 0) return;   // ignore garbage; keep the prior value
        [self writeKey:it[@"key"] value:[NSString stringWithFormat:@"%dx%d", nw, nh] item:it];
        [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// Set<Enum> editor: multi-select checklist -> json-array of element names (the bridge's json-array encoding).
- (void)editSet:(NSMutableDictionary *)it at:(NSIndexPath *)ip {
    NSArray *choices = [it[@"choices"] isKindOfClass:[NSArray class]] ? it[@"choices"] : @[];
    NSArray *selected = [self setValuesFrom:it[@"value"]];
    __weak typeof(self) ws = self;
    MUISetChooser *ch = [[MUISetChooser alloc] initWithTitle:it[@"name"] choices:choices selected:selected
        onDone:^(NSArray<NSString *> *newSel) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:newSel options:0 error:nil];
            NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"[]";
            [ws writeKey:it[@"key"] value:json item:it];
            [ws.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        }];
    ch.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:ch animated:YES completion:nil];
}

// Parse a Set value (gson json-array of element names) into an ordered string array.
- (NSArray<NSString *> *)setValuesFrom:(id)json {
    if (![json isKindOfClass:[NSString class]] || [(NSString *)json length] == 0) return @[];
    id arr = [NSJSONSerialization JSONObjectWithData:[(NSString *)json dataUsingEncoding:NSUTF8StringEncoding]
                                             options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id e in arr) { if ([e isKindOfClass:[NSString class]]) [out addObject:e]; }
    return out;
}

- (void)editColor:(NSMutableDictionary *)it {
    self.colorEditItem = it;
    UIColorPickerViewController *cp = [[UIColorPickerViewController alloc] init];
    cp.delegate = self;
    cp.supportsAlpha = [it[@"alpha"] boolValue];
    UIColor *seed = [self colorFromSigned:it[@"value"]];
    if (seed) cp.selectedColor = seed;
    [self presentViewController:cp animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    NSMutableDictionary *it = self.colorEditItem;
    if (!it) return;
    NSString *dec = [self signedFromColor:viewController.selectedColor alpha:[it[@"alpha"] boolValue]];
    [self writeKey:it[@"key"] value:dec item:it];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    self.colorEditItem = nil;
    [self.table reloadData];
}

// Write through the proven facade and update the local snapshot so the row reflects it immediately.
- (void)writeKey:(NSString *)key value:(NSString *)value item:(NSMutableDictionary *)it {
    NSString *ack = [JVMLauncher mobileSetConfigGroup:self.group key:key value:value];
    it[@"value"] = value;
#if DEBUG
    // QA-P1-12: dev-only — config values can be secrets (e.g. webhook URLs); keep them out of the persistent
    // unified log in the hardened build.
    NSLog(@"[plugincfg] %@.%@ = %@ : %@", self.group, key, value, ack ?: @"(nil)");
#endif
}

#pragma mark - color helpers (signed-decimal ARGB == ConfigManager's Color contract)

- (UIColor *)colorFromSigned:(id)dec {
    if (![dec isKindOfClass:[NSString class]] || [(NSString *)dec length] == 0) return nil;
    long long v = [(NSString *)dec longLongValue];
    uint32_t argb = (uint32_t)v;
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = (argb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

- (NSString *)signedFromColor:(UIColor *)c alpha:(BOOL)alpha {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [c getRed:&r green:&g blue:&b alpha:&a];
    uint32_t A = alpha ? (uint32_t)lround(a * 255.0) : 0xFFu;
    uint32_t argb = (A << 24)
        | (((uint32_t)lround(r * 255.0)) << 16)
        | (((uint32_t)lround(g * 255.0)) << 8)
        | ((uint32_t)lround(b * 255.0));
    return [NSString stringWithFormat:@"%d", (int32_t)argb];  // signed decimal — what ColorUtil.fromString expects
}

@end
