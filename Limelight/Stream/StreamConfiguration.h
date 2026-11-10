//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@interface StreamConfiguration : NSObject

@property NSString* host;
@property unsigned short httpsPort;
@property NSString* appVersion;
@property NSString* gfeVersion;
@property NSString* appID;
@property NSString* appName;
@property NSString* rtspSessionUrl;
@property int serverCodecModeSupport;
@property int width;
@property int height;
@property int frameRate;
@property int bitRate;
@property int riKeyId;
@property NSData* riKey;
@property int gamepadMask;
@property BOOL optimizeGameSettings;
@property BOOL playAudioOnPC;
@property BOOL swapABXYButtons;
@property int audioConfiguration;
@property int supportedVideoFormats;
@property BOOL multiController;
@property BOOL useFramePacing;
// MoonCast: 0 Lowest delay, 1 Balanced, 2 Smoothest (MCPacing); useFramePacing is the old on/off of it
@property int pacingMode;
@property NSData* serverCert;
// MoonCast: a controller-only session (DirectPad): joins the running game, never launches, drops the picture and sound
@property BOOL mcHeadless;

@end
