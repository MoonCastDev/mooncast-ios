//
//  MCBridge.h
//  MoonCast: Moonlight's own steps for the MoonCast home (stream settings, server info, quitting a game),
//  kept in Objective-C so they stay the same as MainFrameViewController's.
//

#import <UIKit/UIKit.h>
#import "TemporaryHost.h"
#import "TemporaryApp.h"
#import "StreamConfiguration.h"
#import "DiscoveryManager.h"

NS_ASSUME_NONNULL_BEGIN

/// What the stream screen does for the Quick menu (StreamFrameViewController implements it).
@protocol MCQuickActions <NSObject>
- (NSDictionary*) mcStats;
- (NSString*) mcTitle;
- (NSString*) mcHostAddress;
- (BOOL) mcStatsOn;
- (void) mcToggleStats;
- (int) mcTouchMode;
- (void) mcSetTouchMode:(int)mode;
- (void) mcToggleKeyboard;
- (void) mcTaskManager;
- (void) mcMenuOpen:(BOOL)open;
- (void) mcDisconnect;
@end

@interface MCBridge : NSObject

/// What MainFrameViewController's prepareToStreamApp builds: the saved settings, clamped to this screen.
+ (StreamConfiguration*) streamConfigForApp:(TemporaryApp*)app;

/// Asks the PC for its server info and fills the host in. Nil when it worked, else the error to show.
+ (nullable NSString*) refreshServerInfo:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// Quits the game running on the PC. Nil when it worked, else the error to show.
+ (nullable NSString*) quitAppOnHost:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// The PC's app list, merged into what's saved (names updated, removed apps dropped). Nil when it worked.
+ (nullable NSString*) refreshAppList:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// Fills in activeAddress for hosts loaded from the database (as MainFrameViewController's retrieveSavedHosts).
+ (NSArray<TemporaryHost*>*) savedHosts;

/// Moonlight's stream screen, set up to play this.
+ (UIViewController*) streamControllerWithConfig:(StreamConfiguration*)config;

/// Removes a PC from this device.
+ (void) removeHost:(TemporaryHost*)host;

@end

NS_ASSUME_NONNULL_END
