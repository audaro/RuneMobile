#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-6 (W3): the native plugin-hub browse/install screen — the mobile replacement for RuneLite's desktop
/// PluginHubPanel. Reads the signed hub manifest via MobileUiBridge.hubManifest (downloaded once on a Java
/// background thread) and lists the available external plugins with a search filter and per-row Install /
/// Remove, driving MobileUiBridge.hubInstall/hubUninstall. Installed hub plugins then appear in the normal
/// plugin panel and are configurable via the config screen.
@interface PluginHubViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
