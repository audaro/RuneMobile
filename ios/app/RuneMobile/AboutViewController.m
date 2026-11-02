#import "AboutViewController.h"
#import "RMDiagnostics.h"

// Modelled on the MUISetChooser full-screen-modal pattern (dark background, bold title top-leading, amber Done
// top-trailing, scroll area below). The four disclosure sections use copy verbatim from Android's AboutScreen
// (PluginPanel.kt) so both platforms show identical language.
@implementation AboutViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.09 blue:0.07 alpha:1.0];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"About";
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

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    [scroll addSubview:stack];

    // Logo + app name + version header (version read the same way as ViewController's CFBundleShortVersionString use).
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Logo"]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    [logo.widthAnchor constraintEqualToConstant:56].active = YES;
    [logo.heightAnchor constraintEqualToConstant:56].active = YES;
    UIStackView *names = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self headerLabelWithText:@"RuneMobile"
                             font:[UIFont boldSystemFontOfSize:22]
                            color:[UIColor whiteColor]
                           topPad:2],
        [self headerLabelWithText:[NSString stringWithFormat:@"Version %@", version]
                             font:[UIFont systemFontOfSize:12]
                            color:[UIColor colorWithWhite:0.62 alpha:1.0]
                           topPad:0],
    ]];
    names.axis = UILayoutConstraintAxisVertical;
    names.spacing = 4;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ logo, names ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 12;
    [stack addArrangedSubview:header];

    [self addSection:stack
               title:@"Unofficial fan client"
                body:@"RuneMobile is an unofficial, fan-made client. It is not affiliated with, endorsed by, or "
                     @"sponsored by Jagex Ltd. or the RuneLite project."];
    [self addSection:stack
               title:@"Account-ban risk"
                body:@"This is an unapproved third-party client for live Old School RuneScape. It is not on "
                     @"Jagex's approved-client list, so playing on it puts your account at risk of a ban. Use a "
                     @"throwaway account - never your main."];
    [self addSection:stack
               title:@"Built on open source"
                body:@"Derived from RuneLite (BSD 2-Clause) and runs the game on an on-device OpenJDK 21 VM "
                     @"(GPLv2 with Classpath Exception). The 117HD renderer is by the rs117 project (BSD 2-Clause). "
                     @"The plugin ecosystem is unmodified. Full third-party attribution is in "
                     @"THIRD-PARTY-NOTICES.md in the project repository."];
    [self addSection:stack
               title:@"Trademarks & game art"
                body:@"RuneScape and Old School RuneScape, and their interface art, are property of Jagex Ltd. "
                     @"This app bundles no Jagex art assets: the mobile chrome draws those interface sprites from "
                     @"your own live game cache at runtime - the same way the upstream RuneLite client does - so "
                     @"the art is never redistributed."];
    [self addSection:stack
               title:@"Report a problem"
                body:@"Share logs makes a text file to post with your bug report. Login tokens, emails and your "
                     @"character name are taken out first."];
    UIButton *shareLogs = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareLogs setTitle:@"Share logs" forState:UIControlStateNormal];
    shareLogs.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    shareLogs.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:1.0];
    shareLogs.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [shareLogs addTarget:self action:@selector(onShareLogs:) forControlEvents:UIControlEventTouchUpInside];
    [stack setCustomSpacing:6 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:shareLogs];

    UILayoutGuide *sg = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:sg.topAnchor
                                        constant:14],
        [title.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor
                                            constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor
                                            constant:-20],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                         constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:sg.leadingAnchor
                                             constant:20],
        [scroll.trailingAnchor constraintEqualToAnchor:sg.trailingAnchor
                                              constant:-20],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor
                                           constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
    ]];
}

- (UILabel *)headerLabelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color topPad:(CGFloat)pad {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

// A teal section heading (matching the "RuneLite account" teal used elsewhere) + a light parchment body.
- (void)addSection:(UIStackView *)stack title:(NSString *)title body:(NSString *)body {
    UILabel *head = [[UILabel alloc] init];
    head.text = title;
    head.font = [UIFont boldSystemFontOfSize:14];
    head.textColor = [UIColor colorWithRed:0.50 green:0.80 blue:0.77 alpha:1.0];
    head.numberOfLines = 0;

    UILabel *text = [[UILabel alloc] init];
    text.text = body;
    text.font = [UIFont systemFontOfSize:14];
    text.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    text.numberOfLines = 0;

    [stack setCustomSpacing:14 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:head];
    [stack setCustomSpacing:4 afterView:head];
    [stack addArrangedSubview:text];
}

- (void)onShareLogs:(UIButton *)sender {
    [RMDiagnostics shareFrom:self sourceView:sender];
}

- (void)onDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
