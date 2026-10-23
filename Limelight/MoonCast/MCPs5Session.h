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

/// registKey and morning are hex (as stored by registration). width 1280/1920, fps 30/60, bitrate kbps, h265.
- (instancetype) initWithHost:(NSString*)host registKey:(NSString*)registKeyHex morning:(NSString*)morningHex
                        width:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrateKbps h265:(BOOL)h265;

/// Nil when it started, else what went wrong.
- (nullable NSString*) start;
/// Ends the session and waits for it (safe to call twice).
- (void) stop;
/// Puts the PS5 in rest mode, then ends.
- (void) restMode;

- (void) setButtons:(uint32_t)buttons l2:(uint8_t)l2 r2:(uint8_t)r2
              leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry;
- (void) setLoginPin:(NSString*)pin;

/// fps (shown), rtt ms, Mbps received, frames lost (since start).
- (NSDictionary*) stats;

/// Sends the wake-up packet: the credential is the registKey's ASCII hex before its zero padding.
+ (void) wakeHost:(NSString*)host registKey:(NSString*)registKeyHex;

@end

NS_ASSUME_NONNULL_END
