#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The hot-phone notice: a small card that offers Lower resolution when hot without getting in the way of play.
/// Only its two buttons take a touch. A touch anywhere else on the card goes to the game beneath, so a tap aimed at
/// the game still lands while it's up. It never takes focus and never pauses anything.
@interface RMHeatNoticeView : UIView
- (instancetype)initWithTurnOn:(void (^)(void))turnOn neverAgain:(void (^)(void))neverAgain;
/// The buttons go under the text instead of beside it, for a narrow screen (default NO).
@property (nonatomic) BOOL compact;
/// Asked as a touch lands on a button. NO lets the touch through to whatever is under the card instead. Nil = YES.
@property (nonatomic, copy, nullable) BOOL (^takesTouch)(void);
/// Fades in, unless Reduce Motion is on.
- (void)present;
/// Fades out and leaves its superview. Safe to call twice.
- (void)dismiss;
@end

NS_ASSUME_NONNULL_END
