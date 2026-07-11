#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-6 (W3): the native replacement for RuneLite's desktop config panel for ONE plugin. Reads the
/// plugin's config descriptor via MobileUiBridge.getPluginConfig (hidden items already filtered, secret
/// values masked) and renders a typed control per item — boolean/int/double/string/enum/color editable,
/// the rest read-only — each writing back through the device-proven MobileUiBridge.setConfig serialization.
/// Presented modally over the plugin list.
@interface PluginConfigViewController : UIViewController

- (instancetype)initWithGroup:(NSString *)group pluginName:(NSString *)name;

/// Curated variant: only config items whose key is in `whitelist` are shown, in the whitelist's order. Used for
/// the native Graphics panel, which must expose ONLY the iOS-ported 117HD settings (the rest would recompile an
/// unported shader and stop the plugin). Pass nil for the full plugin config.
- (instancetype)initWithGroup:(NSString *)group pluginName:(NSString *)name
                    whitelist:(nullable NSArray<NSString *> *)whitelist;

@end

NS_ASSUME_NONNULL_END
