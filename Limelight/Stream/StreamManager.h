//
//  StreamManager.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"
#import "Connection.h"

#import <AVFoundation/AVFoundation.h>

@interface StreamManager : NSOperation

- (id) initWithConfig:(StreamConfiguration*)config renderView:(UIView*)view connectionCallbacks:(id<ConnectionCallbacks>)callback;

- (void) stopStream;

- (NSString*) getStatsOverlayText;

// MoonCast Quick menu: fps, rttMs, lossPct, codec (empty before the first frames)
- (NSDictionary*) mcStats;
/// MoonCast: the view changed size: fit the picture again
- (void) mcRelayout;
/// MoonCast: the picture's display layer (nil while Super resolution draws it)
- (nullable AVSampleBufferDisplayLayer*) mcDisplayLayer;

@end
