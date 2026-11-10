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
@optional
/// "pc" (default) or "ps5": which items the Quick menu shows
- (NSString*) mcKind;
- (void) mcPsButton;
- (void) mcRestMode;
/// Leaves without asking (Move to a TV): a PS5 stays on for the TV
- (void) mcLeaveKeepOn;
/// Power (PC): "hibernate", "restart" or "shutdown" on a Windows PC
- (void) mcPower:(NSString*)what;
@end

/// The video format the stream running now negotiated (VIDEO_FORMAT_*), and whether its video is running.
FOUNDATION_EXPORT int McActiveVideoFormat(void);
FOUNDATION_EXPORT BOOL McVideoRunning(void);

/// A controller-only session to the PC for DirectPad: joins the game already running (never launches one), drops the
/// picture and the sound, and sends this device's pad as controller 0. [events] runs on any thread with "up" (the
/// session started), "ended" (it ended after starting) or "failed" (it didn't start; [why] says why).
@interface MCDirectLink : NSObject
- (instancetype) initWithHost:(TemporaryHost*)host appID:(NSString*)appID appName:(NSString*)appName
                       events:(void (^)(NSString* event, NSString* _Nullable why))events;
- (void) start;
/// Lets go of every button and ends the session. Safe to call more than once.
- (void) stop;
/// The W3C Standard Gamepad state (17 buttons, 4 axes, Y down-positive) as controller 0.
- (void) sendButtons:(NSArray<NSNumber*>*)b axes:(NSArray<NSNumber*>*)a;
@end

@interface MCBridge : NSObject

/// The id of the game running on the PC ("0" when none), or nil when the PC didn't answer. Blocks; not on the main thread.
+ (nullable NSString*) currentGame:(TemporaryHost*)host;

/// Polaris's paired JSON API (/polaris/v1/...): the answer parsed, or nil when it failed or isn't JSON. Blocks; not on
/// the main thread. [body] nil: GET, else POST.
/// Automatic bitrate's signals for the stream running now (MCLink), all totals since it started except the last
/// three: "packets", "bytes", "missing" (by RTP sequence), "unrecoverable" (frames FEC couldn't save), "rtt" and
/// "rttVar" (ms, -1 unknown), "pending" (decode units waiting).
+ (NSDictionary<NSString*, NSNumber*>*) linkSignals;

+ (nullable NSDictionary*) polarisJSON:(TemporaryHost*)host path:(NSString*)path body:(nullable NSDictionary*)body;

/// What MainFrameViewController's prepareToStreamApp builds: the saved settings, clamped to this screen.
+ (StreamConfiguration*) streamConfigForApp:(TemporaryApp*)app;

/// The video formats to offer for a codec preference (CODEC_PREF_*), HDR and YUV 4:4:4, as streamConfigForApp does.
+ (void) setVideoFormats:(StreamConfiguration*)config codec:(uint32_t)codec hdr:(BOOL)hdr yuv444:(BOOL)yuv444;

/// Settings' PyroWave play style: offers the PyroWave formats on top of [config]'s usual ones when this device decodes
/// PyroWave, the stream is at home ([away] NO) and the PC offers it (SCM_PYROWAVE); 10-bit with HDR on, 4:4:4 with
/// the style's 4:4:4 on, each only when the PC has it. Returns the note to show when the style is in use but the
/// PC doesn't offer PyroWave (the stream then uses the usual codec), else nil.
/// [allow444] NO: 4:2:0 this time whatever the style says (a slow link, MCLink).
+ (nullable NSString*) offerPyroWave:(StreamConfiguration*)config away:(BOOL)away allow444:(BOOL)allow444;

/// Asks the PC for its server info and fills the host in. Nil when it worked, else the error to show.
+ (nullable NSString*) refreshServerInfo:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// Quits the game running on the PC. Nil when it worked, else the error to show.
+ (nullable NSString*) quitAppOnHost:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// Tells the PC to forget this device (Moonlight's unpair request) and forgets the PC's certificate here. YES when it
/// worked, NO when the PC didn't answer. Blocks; not on the main thread.
+ (BOOL) unpairHost:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// The PC's app list, merged into what's saved (names updated, removed apps dropped). Nil when it worked.
+ (nullable NSString*) refreshAppList:(TemporaryHost*)host discovery:(DiscoveryManager*)disc;

/// Fills in activeAddress for hosts loaded from the database (as MainFrameViewController's retrieveSavedHosts).
+ (NSArray<TemporaryHost*>*) savedHosts;

/// Moonlight's stream screen, set up to play this.
+ (UIViewController*) streamControllerWithConfig:(StreamConfiguration*)config;

/// Moonlight's port check against its test server: 0 = nothing blocked, -1 = couldn't tell, else blocked ports.
+ (int) testNetworkPorts;

/// Saves a changed host (its away address).
+ (void) saveHost:(TemporaryHost*)host;

/// Removes a PC from this device.
+ (void) removeHost:(TemporaryHost*)host;

/// This device's Sunshine client identity in the form the MoonCast TV reads (identity transfer): "cert" is the
/// PEM certificate, "key" the private key as PKCS#8 DER. Nil when there is none yet (never paired).
+ (nullable NSDictionary<NSString*, NSData*>*) clientIdentity;

/// A host address with its port ("address", "port"; 47989 when it has none). Nil for an empty address.
+ (nullable NSDictionary*) splitAddress:(nullable NSString*)addressPort;

@end

NS_ASSUME_NONNULL_END
