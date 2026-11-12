//
//  StreamConfiguration.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"

@implementation StreamConfiguration
@synthesize host, httpsPort, appID, width, height, frameRate, bitRate, riKeyId, riKey, gamepadMask, appName, optimizeGameSettings, playAudioOnPC, swapABXYButtons, audioConfiguration, supportedVideoFormats, multiController, serverCert, rtspSessionUrl, serverCodecModeSupport;

// MoonCast: the start watchdog's retry gets its own copy (StreamManager init rewrites riKey, riKeyId, appVersion, rtspSessionUrl)
- (id) copyWithZone:(NSZone*)zone {
    StreamConfiguration* c = [[StreamConfiguration allocWithZone:zone] init];
    c.host = self.host;
    c.httpsPort = self.httpsPort;
    c.appVersion = self.appVersion;
    c.gfeVersion = self.gfeVersion;
    c.appID = self.appID;
    c.appName = self.appName;
    c.rtspSessionUrl = self.rtspSessionUrl;
    c.serverCodecModeSupport = self.serverCodecModeSupport;
    c.width = self.width;
    c.height = self.height;
    c.frameRate = self.frameRate;
    c.bitRate = self.bitRate;
    c.riKeyId = self.riKeyId;
    c.riKey = self.riKey;
    c.gamepadMask = self.gamepadMask;
    c.optimizeGameSettings = self.optimizeGameSettings;
    c.playAudioOnPC = self.playAudioOnPC;
    c.swapABXYButtons = self.swapABXYButtons;
    c.audioConfiguration = self.audioConfiguration;
    c.supportedVideoFormats = self.supportedVideoFormats;
    c.multiController = self.multiController;
    c.useFramePacing = self.useFramePacing;
    c.pacingMode = self.pacingMode;
    c.serverCert = self.serverCert;
    c.mcHeadless = self.mcHeadless;
    return c;
}

@end
