#import "RMHeatNotice.h"

@implementation RMHeatNoticeView {
    void (^_turnOn)(void);
    void (^_neverAgain)(void);
    BOOL _dismissed;
    UIStackView *_row;
    UILabel *_text;
    NSLayoutConstraint *_headerFill;
    NSLayoutConstraint *_top;
}

// Kept discreet: one short line and two text buttons on a see-through strip, no border, no filled button, so it reads
// as a passing hint over the game rather than something that wants attention. Compact puts the buttons under the line.
- (instancetype)initWithTurnOn:(void (^)(void))turnOn neverAgain:(void (^)(void))neverAgain {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;
    _turnOn = [turnOn copy];
    _neverAgain = [neverAgain copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.layer.cornerRadius = 10;
    self.accessibilityViewIsModal = NO;

    UIColor *accent = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:1.0];
    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"thermometer.sun.fill"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]]];
    icon.tintColor = accent;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *text = [UILabel new];
    text.text = @"Phone's hot. Lower 117HD's resolution?";
    text.font = [UIFont systemFontOfSize:12];
    text.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    text.numberOfLines = 1;

    UIButton *on = [self buttonTitled:@"Turn on" color:accent bold:YES action:@selector(onTurnOn)];
    on.accessibilityHint = @"Turns on Lower resolution when hot in Game settings";
    UIButton *never = [self buttonTitled:@"Don't show again"
                                   color:[UIColor colorWithWhite:1 alpha:0.6]
                                    bold:NO
                                  action:@selector(onNeverAgain)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ never, on ]];
    [buttons setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [buttons setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, text ]];
    header.spacing = 6;
    header.alignment = UIStackViewAlignmentCenter;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ header, buttons ]];
    row.spacing = 2;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    _row = row;
    _text = text;
    _headerFill = [header.widthAnchor constraintEqualToAnchor:row.widthAnchor];
    _top = [row.topAnchor constraintEqualToAnchor:self.topAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:10],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-2],
        _top,
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

// A text button, no fill: still a finger's height to tap, though the strip shows only its words.
- (UIButton *)buttonTitled:(NSString *)t color:(UIColor *)color bold:(BOOL)bold action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:bold ? UIFontWeightSemibold : UIFontWeightRegular];
    b.tintColor = color;
    b.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setCompact:(BOOL)compact {
    _compact = compact;
    _row.axis = compact ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    _row.alignment = compact ? UIStackViewAlignmentTrailing : UIStackViewAlignmentCenter;
    _row.spacing = compact ? 0 : 2;
    _headerFill.active = compact;
    _top.constant = compact ? 7 : 0; // the buttons' own height pads a single line; a line above them needs its own
    _text.numberOfLines = compact ? 2 : 1;
}

// Only a button takes the touch. Anything else falls through to the game, so the card can't swallow a tap. A button
// asks takesTouch first: a control can come up under the card between two of the host's checks, and then the touch
// is that control's.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (![hit isKindOfClass:[UIControl class]])
        return nil;
    return !self.takesTouch || self.takesTouch() ? hit : nil;
}

- (void)present {
    if (UIAccessibilityIsReduceMotionEnabled())
        return;
    self.alpha = 0;
    [UIView animateWithDuration:0.25
                     animations:^{
                         self.alpha = 1;
                     }];
}

- (void)dismiss {
    if (_dismissed)
        return;
    _dismissed = YES;
    self.userInteractionEnabled = NO; // on its way out it takes no more taps: they go to whatever came up under it
    if (UIAccessibilityIsReduceMotionEnabled()) {
        [self removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.25
        animations:^{
            self.alpha = 0;
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
        }];
}

- (void)onTurnOn {
    if (_turnOn)
        _turnOn();
}

- (void)onNeverAgain {
    if (_neverAgain)
        _neverAgain();
}

@end
