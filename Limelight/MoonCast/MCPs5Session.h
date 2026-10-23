//
//  MCPs5Session.h
//  MoonCast: PS5 Remote Play on iPad over chiaki (the same libchiaki as the Android app's Ps5StreamActivity).
//  Video goes to an AVSampleBufferDisplayLayer (VideoToolbox decodes), audio through chiaki's Opus decoder to
//  AVAudioEngine, pad state from the stream screen.
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MCPs5SessionDelegate <NSObject>
- (void) ps5Connected;
/// The session ended: reason is chiaki's, empty when we stopped it.
- (void) ps5Quit:(NSString*)reason;
/// The console asks for its login PIN (incorrect = the one sent was wrong).
- (void) ps5LoginPinRequested:(BOOL)incorrect;
- (void) ps5Rumble:(uint8_t)left right:(uint8_t)right;
@end

@interface MCPs5Session : NSObject

@property (nonatomic, weak) id<MCPs5SessionDelegate> delegate;
/// Where the picture is drawn.
@property (nonatomic, readonly) AVSampleBufferDisplayLayer* videoLayer;
/// Set when the picture goes through FSR (Settings → Picture → Super resolution): frames are decoded for it instead.
@property (nonatomic, strong, nullable) id fsrDecoder;

/// registKey and morning are hex (as stored by registration). width 1280/1920, fps 30/60, bitrate kbps, h265.
- (instancetype) initWithHost:(NSString*)host registKey:(NSString*)registKeyHex morning:(NSString*)morningHex
                        width:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrateKbps h265:(BOOL)h265;

/// Away from home: the PSN token, the console's PSN device id (hex) and the account id (8 bytes). When set, start
/// first punches a hole through PSN to the console (up to a minute).
@property (nonatomic, copy, nullable) NSString* psnToken;
@property (nonatomic, copy, nullable) NSString* psnDuid;
@property (nonatomic, copy, nullable) NSData* psnAccountId;

/// Nil when it started, else what went wrong. Over PSN this blocks: call it off the main thread.
- (nullable NSString*) start;
/// Stops a PSN connect in flight (the screen closed).
+ (void) cancelPsn;
/// Ends the session and waits for it (safe to call twice).
- (void) stop;
/// Puts the PS5 in rest mode, then ends.
- (void) restMode;

- (void) setButtons:(uint32_t)buttons l2:(uint8_t)l2 r2:(uint8_t)r2
              leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry;
- (void) setLoginPin:(NSString*)pin;

/// fps (shown), rtt ms, Mbps received, frames lost (since start).
- (NSDictionary*) stats;

/// Links a PS5 ("Link Device"): its address, the PSN account id (8 bytes) and the 8-digit code on its screen.
/// Calls back on the main thread with registKey, morning (hex) and nickname, or nil when it failed. Up to 30 s.
+ (void) registerHost:(NSString*)host accountId:(NSData*)accountId pin:(uint32_t)pin
           completion:(void (^)(NSDictionary* _Nullable result))completion;

/// Sends the wake-up packet: the credential is the registKey's ASCII hex before its zero padding.
+ (void) wakeHost:(NSString*)host registKey:(NSString*)registKeyHex;

@end

NS_ASSUME_NONNULL_END
