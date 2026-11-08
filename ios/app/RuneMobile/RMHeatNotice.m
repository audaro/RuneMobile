#import "RMHeatNotice.h"

@implementation RMHeatNoticeView {
    void (^_turnOn)(void);
    void (^_neverAgain)(void);
    BOOL _dismissed;
    UIStackView *_row;
    UILabel *_body;
    NSLayoutConstraint *_headerFill;
}

- (instancetype)initWithTurnOn:(void (^)(void))turnOn neverAgain:(void (^)(void))neverAgain {
    self = [super initWithFrame:CGRectZero];
    if (!self)
        return nil;
    _turnOn = [turnOn copy];
    _neverAgain = [neverAgain copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    self.layer.cornerRadius = 14;
    self.layer.borderWidth = 1;
    self.layer.borderColor = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:0.7].CGColor;
    self.accessibilityViewIsModal = NO;

    UIColor *accent = [UIColor colorWithRed:0.95 green:0.62 blue:0.11 alpha:1.0];
    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"thermometer.sun.fill"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]]];
    icon.tintColor = accent;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *title = [UILabel new];
    title.text = @"Your phone is getting hot";
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    UILabel *body = [UILabel new];
    body.text = @"Lowering 117HD's resolution while it's hot helps it cool.";
    body.font = [UIFont systemFontOfSize:12];
    body.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    body.numberOfLines = 2;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ title, body ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    UIButton *on = [self buttonTitled:@"Turn on" filled:YES accent:accent action:@selector(onTurnOn)];
    on.accessibilityHint = @"Turns on Lower resolution when hot in Game settings";
    UIButton *never = [self buttonTitled:@"Don't show again" filled:NO accent:accent action:@selector(onNeverAgain)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ never, on ]];
    buttons.spacing = 8;
    [buttons setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [buttons setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, text ]];
    header.spacing = 10;
    header.alignment = UIStackViewAlignmentCenter;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ header, buttons ]];
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    _row = row;
    _body = body;
    _headerFill = [header.widthAnchor constraintEqualToAnchor:row.widthAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:12],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-10],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:8],
        [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                         constant:-8],
    ]];
    return self;
}

- (UIButton *)buttonTitled:(NSString *)t filled:(BOOL)filled accent:(UIColor *)accent action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    b.tintColor = filled ? [UIColor blackColor] : [UIColor whiteColor];
    b.backgroundColor = filled ? accent : [UIColor colorWithWhite:1.0 alpha:0.12];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:32].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setCompact:(BOOL)compact {
    _compact = compact;
    _row.axis = compact ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    _row.alignment = compact ? UIStackViewAlignmentTrailing : UIStackViewAlignmentCenter;
    _row.spacing = compact ? 8 : 10;
    _headerFill.active = compact;
    _body.numberOfLines = compact ? 3 : 2;
}

// Only a button takes the touch. Anything else falls through to the game, so the card can't swallow a tap.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return [hit isKindOfClass:[UIControl class]] ? hit : nil;
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
