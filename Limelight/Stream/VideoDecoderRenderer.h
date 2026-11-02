//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"

#include "Limelight.h"

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio useFramePacing:(BOOL)useFramePacing;

/// 0 when the decoder is ready (MoonCast: non-zero when PyroWave's didn't start)
- (int)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)start;
- (void)stop;
- (void)setHdrMode:(BOOL)enabled;
/// MoonCast: the view changed size (an iPad turned mid-game): fit the picture again
- (void)mcRelayout;
/// MoonCast: the display layer the picture goes to (nil while Super resolution draws it), for picture in picture
- (nullable AVSampleBufferDisplayLayer*)mcDisplayLayer;
/// MoonCast: this stream is PyroWave (decoded with Metal on a CAMetalLayer, not the display layer)
- (BOOL)mcPyroWave;
/// MoonCast: PyroWave's GPU decode time per frame over the last second, ms (-1: none)
- (double)mcDecodeMs;
/// MoonCast: PyroWave's frame rates over the last second: "received", "decoded", "presented", "skipped" (nil: not
/// PyroWave, or before the first second)
- (nullable NSDictionary*)mcPyroRates;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType decodeUnit:(PDECODE_UNIT)du;

@end
