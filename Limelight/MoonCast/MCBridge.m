//
//  MCBridge.m
//  MoonCast
//

#import "MCBridge.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "HttpResponse.h"
#import "ServerInfoResponse.h"
#import "AppListResponse.h"
#import "ConnectionHelper.h"
#import "ControllerSupport.h"
#import "StreamFrameViewController.h"
#import "CryptoManager.h"
#import "Utils.h"
#import "MCPyroWave.h"

#include <openssl/pem.h>
#include <openssl/x509.h>

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <Limelight.h>

/// The raw answer to a request (Polaris's JSON rather than Moonlight's XML).
@interface MCRawResponse : NSObject <Response>
@end

@implementation MCRawResponse
@synthesize statusCode, statusMessage, data;
- (void) populateWithData:(NSData*)d { self.data = d; self.statusCode = 200; }
@end

@implementation MCBridge

+ (NSDictionary<NSString*, NSNumber*>*) linkSignals {
    uint64_t packets = 0, bytes = 0, missing = 0;
    LiGetVideoReceiveTotals(&packets, &bytes, &missing);
    uint32_t rtt = 0, var = 0;
    BOOL haveRtt = LiGetEstimatedRttInfo(&rtt, &var);
    return @{ @"packets": @(packets), @"bytes": @(bytes), @"missing": @(missing),
              @"unrecoverable": @(LiGetVideoUnrecoverableFrames()),
              @"rtt": @(haveRtt ? (int)rtt : -1), @"rttVar": @(haveRtt ? (int)var : -1),
              @"pending": @(LiGetPendingVideoFrames()) };
}

+ (nullable NSDictionary*) polarisJSON:(TemporaryHost*)host path:(NSString*)path body:(nullable NSDictionary*)body {
    NSData* json = nil;
    if (body != nil) {
        json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        if (json == nil) return nil;
    }
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    NSURLRequest* req = [hMan newPolarisRequest:path jsonBody:json];
    if (req == nil) return nil;
    MCRawResponse* resp = [[MCRawResponse alloc] init];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resp withUrlRequest:req]];
    if (resp.data == nil) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:resp.data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

+ (NSDictionary<NSString*, NSData*>*) clientIdentity {
    NSData* cert = [CryptoManager readCertFromFile];
    NSData* keyPem = [CryptoManager readKeyFromFile];
    if (cert == nil || keyPem == nil) {
        return nil;
    }
    BIO* in = BIO_new_mem_buf(keyPem.bytes, (int)keyPem.length);
    EVP_PKEY* pkey = PEM_read_bio_PrivateKey(in, NULL, NULL, NULL);
    BIO_free(in);
    if (pkey == NULL) {
        return nil;
    }
    // unencrypted PKCS#8 DER, as the Android apps keep client.key
    BIO* out = BIO_new(BIO_s_mem());
    NSData* key = nil;
    if (i2d_PKCS8PrivateKey_bio(out, pkey, NULL, NULL, 0, NULL, NULL) == 1) {
        char* p;
        long n = BIO_get_mem_data(out, &p);
        key = [NSData dataWithBytes:p length:n];
    }
    BIO_free(out);
    EVP_PKEY_free(pkey);
    return key == nil ? nil : @{ @"cert": cert, @"key": key };
}

+ (NSDictionary*) splitAddress:(NSString*)addressPort {
    if (addressPort.length == 0) {
        return nil;
    }
    NSRange a, p;
    if (![Utils parseAddressPortString:addressPort address:&a port:&p]) {
        return nil;
    }
    int port = p.location != NSNotFound ? [[addressPort substringWithRange:p] intValue] : 47989;
    return @{ @"address": [addressPort substringWithRange:a], @"port": @(port > 0 ? port : 47989) };
}

+ (StreamConfiguration*) streamConfigForApp:(TemporaryApp*)app {
    StreamConfiguration* config = [[StreamConfiguration alloc] init];
    config.host = app.host.activeAddress;
    config.httpsPort = app.host.httpsPort;
    config.appID = app.id;
    config.appName = app.name;
    config.serverCert = app.host.serverCert;

    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];

    config.frameRate = [settings.framerate intValue];
    // Don't stream more FPS than the display can show
    if (config.frameRate > [UIScreen mainScreen].maximumFramesPerSecond) {
        config.frameRate = (int)[UIScreen mainScreen].maximumFramesPerSecond;
    }
    config.height = [settings.height intValue];
    config.width = [settings.width intValue];
    config.bitRate = [settings.bitrate intValue];
    config.optimizeGameSettings = settings.optimizeGames;
    config.playAudioOnPC = settings.playAudioOnPC;
    config.useFramePacing = settings.useFramePacing;
    config.swapABXYButtons = settings.swapABXYButtons;

    // multiController must be set before calling getConnectedGamepadMask
    config.multiController = settings.multiController;
    config.gamepadMask = [ControllerSupport getConnectedGamepadMask:config];

    int physicalOutputChannels = (int)[AVAudioSession sharedInstance].maximumOutputNumberOfChannels;
    int numberOfChannels = MIN([settings.audioConfig intValue], physicalOutputChannels);
    if (numberOfChannels >= 8) {
        config.audioConfiguration = AUDIO_CONFIGURATION_71_SURROUND;
    }
    else if (numberOfChannels >= 6) {
        config.audioConfiguration = AUDIO_CONFIGURATION_51_SURROUND;
    }
    else {
        config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    }

    config.serverCodecModeSupport = app.host.serverCodecModeSupport;

    // YUV 4:4:4 is no longer offered (it is PyroWave's on Android): a value left by an older build is ignored
    [MCBridge setVideoFormats:config codec:settings.preferredCodec hdr:settings.enableHdr yuv444:NO];
    return config;
}

+ (void) setVideoFormats:(StreamConfiguration*)config codec:(uint32_t)codec hdr:(BOOL)hdr yuv444:(BOOL)yuv444 {
    config.supportedVideoFormats = 0;
    switch (codec) {
        case CODEC_PREF_AV1:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
            }
            // Fall-through
        case CODEC_PREF_AUTO:
        case CODEC_PREF_HEVC:
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                config.supportedVideoFormats |= VIDEO_FORMAT_H265;
            }
            // Fall-through
        case CODEC_PREF_H264:
            config.supportedVideoFormats |= VIDEO_FORMAT_H264;
            break;
    }

    if ((config.width > 4096 || config.height > 4096 || hdr) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (hdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
            config.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
        }
    }

    if ((config.supportedVideoFormats & VIDEO_FORMAT_MASK_AV1) && hdr &&
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10) != 0) {
        config.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN10;
    }

    // MoonCast: Settings → Picture → YUV 4:4:4 (HEVC): full colour detail, used when the PC offers HEVC 4:4:4
    if (yuv444 && (config.supportedVideoFormats & VIDEO_FORMAT_H265)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265_REXT8_444;
        if (config.supportedVideoFormats & VIDEO_FORMAT_H265_MAIN10) {
            config.supportedVideoFormats |= VIDEO_FORMAT_H265_REXT10_444;
        }
    }
}

+ (nullable NSString*) offerPyroWave:(StreamConfiguration*)config away:(BOOL)away allow444:(BOOL)allow444 {
    if (!MCPyroWave.wanted) {
        return nil;
    }
    if (away) {
        Log(LOG_I, @"PyroWave: not away from home (the usual codec plays)");
        return nil;
    }
    if (!MCPyroWave.deviceSupported) {
        Log(LOG_I, @"PyroWave: this device doesn't decode it (the usual codec plays)");
        return nil;
    }
    int scm = config.serverCodecModeSupport;
    if (!(scm & SCM_PYROWAVE)) {
        Log(LOG_I, @"PyroWave asked for, but the PC doesn't offer it (codec modes 0x%x)", scm);
        return @"This PC doesn't offer PyroWave, so the stream uses your usual codec";
    }
    TemporarySettings* settings = [[[DataManager alloc] init] getSettings];
    BOOL tenBit = settings.enableHdr;
    BOOL yuv444 = MCPyroWave.want444 && allow444;
    int formats = VIDEO_FORMAT_PYROWAVE;
    if (tenBit && (scm & SCM_PYROWAVE_10BIT)) formats |= VIDEO_FORMAT_PYROWAVE_10BIT;
    if (yuv444 && (scm & SCM_PYROWAVE_444)) formats |= VIDEO_FORMAT_PYROWAVE_444;
    if (tenBit && yuv444 && (scm & SCM_PYROWAVE_10BIT_444)) formats |= VIDEO_FORMAT_PYROWAVE_10BIT_444;
    config.supportedVideoFormats |= formats;
    Log(LOG_I, @"Asking the PC for PyroWave (formats 0x%x; recommended at %dx%d %d fps: %d Mbps, set %d Mbps)", formats,
        config.width, config.height, config.frameRate,
        [MCPyroWave recommendedKbpsWidth:config.width height:config.height fps:config.frameRate] / 1000, config.bitRate / 1000);
    return nil;
}

+ (nullable NSString*) refreshServerInfo:(TemporaryHost*)host discovery:(DiscoveryManager*)disc {
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
    [disc pauseDiscoveryForHost:host];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                        fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
    [disc resumeDiscoveryForHost:host];
    if (![serverInfoResp isStatusOk]) {
        return serverInfoResp.statusMessage ?: @"The PC didn't answer.";
    }
    [serverInfoResp populateHost:host];
    return nil;
}

+ (BOOL) unpairHost:(TemporaryHost*)host discovery:(DiscoveryManager*)disc {
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    HttpResponse* resp = [[HttpResponse alloc] init];
    [disc pauseDiscoveryForHost:host];
    [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resp withUrlRequest:[hMan newUnpairRequest]]];
    [disc resumeDiscoveryForHost:host];
    if (resp.statusCode != 200) return NO;
    // the PC forgot this device: forget its certificate too, so the next pairing starts clean
    host.pairState = PairStateUnpaired;
    host.serverCert = nil;
    [[[DataManager alloc] init] updateHost:host];
    return YES;
}

+ (nullable NSString*) quitAppOnHost:(TemporaryHost*)host discovery:(DiscoveryManager*)disc {
    HttpManager* hMan = [[HttpManager alloc] initWithHost:host];
    HttpResponse* quitResponse = [[HttpResponse alloc] init];
    HttpRequest* quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];

    [disc pauseDiscoveryForHost:host];
    [hMan executeRequestSynchronously:quitRequest];
    if (quitResponse.statusCode == 200) {
        ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:false]
                                                            fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
            // newer GFE says yes even when another device's game didn't quit
            quitResponse.statusCode = 599;
        }
        else {
            [serverInfoResp populateHost:host];
        }
    }
    [disc resumeDiscoveryForHost:host];

    if (quitResponse.statusCode != 200) {
        return @"The game didn't quit. If another device started it, quit it from that device.";
    }
    host.currentGame = @"0";
    return nil;
}

+ (nullable NSString*) refreshAppList:(TemporaryHost*)host discovery:(DiscoveryManager*)disc {
    [disc pauseDiscoveryForHost:host];
    AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host];
    [disc resumeDiscoveryForHost:host];

    if (![appListResp isStatusOk] || [appListResp getAppList] == nil) {
        return appListResp.statusMessage ?: @"The PC didn't send its games.";
    }

    NSSet* newList = [appListResp getAppList];
    __block NSString* result = nil;
    // the database is only touched from the main thread, as in MainFrameViewController
    dispatch_sync(dispatch_get_main_queue(), ^{
        DataManager* database = [[DataManager alloc] init];
        NSMutableSet* merged = [NSMutableSet setWithSet:host.appList];

        for (TemporaryApp* app in newList) {
            BOOL known = NO;
            for (TemporaryApp* saved in merged) {
                if ([app.id isEqualToString:saved.id]) {
                    saved.name = app.name;
                    saved.hdrSupported = app.hdrSupported;
                    known = YES;
                    break;
                }
            }
            if (!known) {
                app.host = host;
                [merged addObject:app];
            }
        }

        NSMutableArray* gone = [NSMutableArray array];
        for (TemporaryApp* saved in merged) {
            BOOL still = NO;
            for (TemporaryApp* app in newList) {
                if ([app.id isEqualToString:saved.id]) { still = YES; break; }
            }
            if (!still) [gone addObject:saved];
        }
        for (TemporaryApp* app in gone) {
            [merged removeObject:app];
            [database removeApp:app];
        }

        host.appList = merged;
        [database updateAppsForExistingHost:host];
    });
    return result;
}

+ (NSArray<TemporaryHost*>*) savedHosts {
    NSArray* hosts = [[[DataManager alloc] init] getHosts];
    for (TemporaryHost* host in hosts) {
        if (host.activeAddress == nil) host.activeAddress = host.localAddress;
        if (host.activeAddress == nil) host.activeAddress = host.externalAddress;
        if (host.activeAddress == nil) host.activeAddress = host.address;
        if (host.activeAddress == nil) host.activeAddress = host.ipv6Address;
    }
    return hosts;
}

+ (UIViewController*) streamControllerWithConfig:(StreamConfiguration*)config {
    UIStoryboard* sb = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
    StreamFrameViewController* vc = [sb instantiateViewControllerWithIdentifier:@"MainFrame"];
    vc.streamConfig = config;
    return vc;
}

+ (int) testNetworkPorts {
    unsigned int r = LiTestClientConnectivity(CONN_TEST_SERVER, 443, ML_PORT_FLAG_ALL);
    return r == ML_TEST_RESULT_INCONCLUSIVE ? -1 : (int)r;
}

+ (void) saveHost:(TemporaryHost*)host {
    [[[DataManager alloc] init] updateHost:host];
}

+ (void) removeHost:(TemporaryHost*)host {
    [[[DataManager alloc] init] removeHost:host];
}

@end
