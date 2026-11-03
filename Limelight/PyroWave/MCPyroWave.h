//
//  MCPyroWave.h
//  MoonCast: PyroWave PC streams on the iPad and iPhone (Pyrowave.kt and pyrowave_renderer on Android). PyroWave is
//  an intra-only wavelet codec (Themaister/pyrowave, MIT) that decodes on the GPU in a couple of milliseconds, for
//  the lowest delay on a wired or fast Wi-Fi link, at hundreds of Mbps. Its frames skip VideoToolbox: PyroWave's
//  native Metal decoder (vendored in this folder) decodes them into Y, Cb and Cr textures, and MoonCast draws those
//  as RGB on a CAMetalLayer in place of the stream's AVSampleBufferDisplayLayer.
//
//  Only with Settings' PyroWave play style (mc_pyrowave), on a device the probe passed, at home, and when the PC
//  offers it (Polaris and other Sunshine builds with PyroWave); otherwise the stream uses the usual codec.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPyroWave : NSObject

/// This device decodes PyroWave: an Apple7-family GPU (A14 / M1 and later) PyroWave's Metal decoder starts on. The
/// first answer is kept per app build and system version; a probe that took the app down is never tried again.
@property (class, readonly) BOOL deviceSupported;

/// Settings' PyroWave play style is the one in use.
@property (class, readonly) BOOL wanted;
/// The PyroWave style's YUV 4:4:4 (default on).
@property (class, readonly) BOOL want444;
/// The PyroWave style's GPU boost (default on).
@property (class, readonly) BOOL gpuBoost;
/// The PyroWave style's spatial dithering: 0 off, 1 low, 2 high (default low).
@property (class, readonly) int ditherMode;

/// A PyroWave stream is decoding now.
@property (class, readonly) BOOL streamActive;

/// The video stream's totals so far (moonlight-common-c): "packets" and "bytes" that reached the socket, and
/// "missing" packets by RTP sequence (lost before the socket, on the network or the Wi-Fi link).
+ (NSDictionary<NSString*, NSNumber*>*)receiveTotals;

/// The bitrate PyroWave looks good at, in kbps: 400 Mbps at 1440p120 scaled by pixels and frame rate (Moonlight X).
+ (int)recommendedKbpsWidth:(int)width height:(int)height fps:(int)fps;

@end

/// One PyroWave stream's decoder and picture. Made at decoder setup, fed every frame on the frame thread, stopped at
/// the stream's end.
@interface MCPyroWaveRenderer : NSObject

/// Puts a CAMetalLayer on [view]'s layer just above [below] (the display layer it takes the place of), at [below]'s
/// frame (the picture's place, as Picture shape puts it). Nil when PyroWave's decoder doesn't start. Main thread.
- (nullable instancetype)initWithView:(UIView*)view above:(CALayer*)below videoFormat:(int)videoFormat
                                width:(int)width height:(int)height fps:(int)fps;

/// Decodes and shows one frame (on the frame thread). A newer frame already waiting wins: this one is skipped.
/// Returns DR_OK; the data stays the caller's.
- (int)submitFrame:(const uint8_t*)data length:(size_t)length;

/// The view changed size (a turn, a resize): the picture's new place. Main thread.
- (void)layoutInFrame:(CGRect)frame;
/// The host's display went in or out of HDR.
- (void)setHdr:(BOOL)enabled;
/// Ends the stream's decoding: waits for the GPU, takes the layer away and stops the GPU boost.
- (void)stop;

/// The GPU's decode time per frame over the last second, in ms (-1 before the first second).
@property (readonly) double decodeMs;
/// Frames per second over the last second (-1 before the first second): handed to the renderer, decoded, actually
/// presented on screen (the drawable's presented handler), and skipped because a newer one was already waiting.
@property (readonly) double receivedFps;
@property (readonly) double decodedFps;
@property (readonly) double presentedFps;
@property (readonly) double skippedFps;
/// Called once, on the main thread, when the first frame is on screen.
@property (nullable, copy) void (^onFirstFrame)(void);

@end

NS_ASSUME_NONNULL_END
