//
//  MCPs5Session.m
//  MoonCast
//

#import "MCPs5Session.h"
#import <VideoToolbox/VideoToolbox.h>
#import "Moonlight-Swift.h"
#import <stdatomic.h>

#include <chiaki/session.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>
#include <pthread.h>

static pthread_mutex_t mcPsnMutex = PTHREAD_MUTEX_INITIALIZER;
static ChiakiHolepunchSession mcPsnActive = NULL;
static bool mcPsnCancelled = false;

/// Remote Play over PSN, as the Android app's mc_psn_connect: STUN with port guessing, offer, punch the control port.
static ChiakiHolepunchSession MCPsnConnect(ChiakiLog* log, const char* token, NSString* duidHex) {
    NSData* duid = nil;
    {
        NSMutableData* d = [NSMutableData data];
        for (NSUInteger i = 0; i + 1 < duidHex.length; i += 2) {
            unsigned int b = 0;
            [[NSScanner scannerWithString:[duidHex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&b];
            uint8_t c = (uint8_t)b; [d appendBytes:&c length:1];
        }
        duid = d;
    }
    if (duid.length == 0) return NULL;
    ChiakiHolepunchSession hs = chiaki_holepunch_session_init(token, log);
    if (!hs) return NULL;
    pthread_mutex_lock(&mcPsnMutex);
    mcPsnActive = hs; mcPsnCancelled = false;
    pthread_mutex_unlock(&mcPsnMutex);
    chiaki_holepunch_session_force_port_guessing(hs, true);
    ChiakiErrorCode err = chiaki_holepunch_session_create(hs);
    if (err == CHIAKI_ERR_SUCCESS) err = holepunch_session_create_offer(hs);
    if (err == CHIAKI_ERR_SUCCESS) err = chiaki_holepunch_session_start(hs, duid.bytes, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5);
    if (err == CHIAKI_ERR_SUCCESS) err = chiaki_holepunch_session_punch_hole(hs, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
    pthread_mutex_lock(&mcPsnMutex);
    mcPsnActive = NULL;
    bool cancelled = mcPsnCancelled;
    pthread_mutex_unlock(&mcPsnMutex);
    if (err == CHIAKI_ERR_SUCCESS && cancelled) err = CHIAKI_ERR_CANCELED;
    if (err != CHIAKI_ERR_SUCCESS) {
        CHIAKI_LOGE(log, "MoonCast PSN: hole-punch failed: %s", chiaki_error_string(err));
        chiaki_holepunch_session_fini(hs);
        return NULL;
    }
    return hs;
}

static NSData* MCHex(NSString* hex) {
    NSMutableData* d = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int b = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&b];
        uint8_t c = (uint8_t)b;
        [d appendBytes:&c length:1];
    }
    return d;
}

static void MCChiakiLog(ChiakiLogLevel level, const char* msg, void* user) {
    NSLog(@"[chiaki %d] %s", level, msg);
}

#pragma mark - audio: a small ring of 16-bit frames pulled by AVAudioSourceNode

#define MC_RING (48000 * 2)   // one second of stereo

/// Sound from the PS5 to the speaker: a single-producer / single-consumer ring. Only the decoder thread moves
/// `head` (and drops new sound when the ring is full); only the audio render thread moves `tail` (and skips ahead
/// when too much is queued, so the sound stays close to the picture).
@interface MCPs5Audio : NSObject {
@public
    int16_t ring[MC_RING];
    _Atomic size_t head, tail;
    _Atomic int renders;
    uint32_t channels, rate;
    size_t capSamples, keepSamples;
}
@property (nonatomic) AVAudioEngine* engine;
@end

@implementation MCPs5Audio

- (void) startWithChannels:(uint32_t)ch rate:(uint32_t)r {
    channels = ch ? ch : 2;
    rate = r ? r : 48000;
    BOOL ull = MCUltraLowLatency.enabled;
    capSamples = (size_t)rate * channels * (ull ? 60 : 120) / 1000;
    keepSamples = (size_t)rate * channels * (ull ? 20 : 40) / 1000;
    NSError* err = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&err]) NSLog(@"MCAUDIO category: %@", err);
    [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:0.005 error:nil];
    if (![[AVAudioSession sharedInstance] setActive:YES error:&err]) NSLog(@"MCAUDIO active: %@", err);
    self.engine = [[AVAudioEngine alloc] init];
    AVAudioFormat* fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:channels interleaved:NO];
    __unsafe_unretained MCPs5Audio* me = self;
    AVAudioSourceNode* src = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(BOOL* silence, const AudioTimeStamp* ts, AVAudioFrameCount frames, AudioBufferList* out) {
        uint32_t chs = me->channels;
        size_t h = atomic_load_explicit(&me->head, memory_order_acquire);
        size_t t = atomic_load_explicit(&me->tail, memory_order_relaxed);
        size_t queued = (h + MC_RING - t) % MC_RING;
        if (queued > me->capSamples) {
            // too far behind the picture: skip to the newest sound
            t = (h + MC_RING - me->keepSamples) % MC_RING;
            queued = me->keepSamples;
        }
        size_t avail = queued / chs;
        size_t used = MIN((size_t)frames, avail);
        for (AVAudioFrameCount f = 0; f < frames; f++) {
            for (uint32_t c = 0; c < chs && c < out->mNumberBuffers; c++) {
                ((float*)out->mBuffers[c].mData)[f] = f < used ? me->ring[(t + f * chs + c) % MC_RING] / 32768.0f : 0.0f;
            }
        }
        atomic_store_explicit(&me->tail, (t + used * chs) % MC_RING, memory_order_release);
        atomic_fetch_add_explicit(&me->renders, 1, memory_order_relaxed);
        if (used == 0) *silence = YES;
        return noErr;
    }];
    [self.engine attachNode:src];
    [self.engine connect:src to:self.engine.mainMixerNode format:fmt];
    if (![self.engine startAndReturnError:&err]) NSLog(@"MCAUDIO engine: %@", err);
}

- (void) push:(int16_t*)buf samples:(size_t)samples {
    size_t n = samples * channels;
    size_t h = atomic_load_explicit(&head, memory_order_relaxed);
    size_t t = atomic_load_explicit(&tail, memory_order_acquire);
    size_t free = MC_RING - 1 - (h + MC_RING - t) % MC_RING;
    if (n > free) return;   // the speaker isn't keeping up: drop this packet (the render side skips ahead)
    for (size_t i = 0; i < n; i++) {
        ring[h] = buf[i];
        h = (h + 1) % MC_RING;
    }
    atomic_store_explicit(&head, h, memory_order_release);
#if DEBUG
    static int pushes = 0;
    if (++pushes % 500 == 1) NSLog(@"MCAUDIO push #%d queued=%zu renders=%d", pushes, (h + MC_RING - t) % MC_RING, atomic_load(&renders));
#endif
}

- (void) stop {
    [self.engine stop];
    self.engine = nil;
}

@end

#pragma mark - session

@interface MCPs5Session () {
    ChiakiLog _log;
    ChiakiSession _session;
    ChiakiOpusDecoder _opus;
    ChiakiConnectInfo _info;
    char* _hostC;
    BOOL _inited, _started, _stopped;
    BOOL _h265;
    CMVideoFormatDescriptionRef _format;
    NSData* _vps; NSData* _sps; NSData* _pps;
    uint64_t _frames, _bytes, _lost;
    CFTimeInterval _statsStart;
    ChiakiControllerState _pad;   // buttons and sticks from the controller, touches from the screen
    double _fps, _mbps;
}
@property (nonatomic) AVSampleBufferDisplayLayer* videoLayer;
@property (atomic) MCPs5Audio* audio;
@end

static void MCEvent(ChiakiEvent* e, void* user);
static bool MCVideo(uint8_t* buf, size_t size, int32_t lost, bool recovered, void* user);
static void MCAudioSettings(uint32_t channels, uint32_t rate, void* user);
static void MCAudioFrame(int16_t* buf, size_t samples, void* user);

static NSString* MCHexOf(const uint8_t* b, size_t n) {
    NSMutableString* s = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

@interface MCPs5Regist : NSObject {
@public
    ChiakiLog log;
    ChiakiRegist regist;
    char* host;
    dispatch_semaphore_t done;
    NSDictionary* result;
}
@end
@implementation MCPs5Regist
@end

static void MCRegistCb(ChiakiRegistEvent* e, void* user) {
    MCPs5Regist* r = (__bridge MCPs5Regist*)user;
    if (e->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && e->registered_host) {
        ChiakiRegisteredHost* h = e->registered_host;
        r->result = @{ @"registKey": MCHexOf((const uint8_t*)h->rp_regist_key, sizeof(h->rp_regist_key)),
                       @"morning": MCHexOf(h->rp_key, sizeof(h->rp_key)),
                       @"nickname": [NSString stringWithUTF8String:h->server_nickname] ?: @"" };
    }
    dispatch_semaphore_signal(r->done);
}

@implementation MCPs5Session

- (instancetype) initWithHost:(NSString*)host registKey:(NSString*)registKeyHex morning:(NSString*)morningHex
                        width:(int)width height:(int)height fps:(int)fps bitrate:(int)bitrateKbps h265:(BOOL)h265 {
    if ((self = [super init])) {
        chiaki_log_init(&_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, MCChiakiLog, NULL);
        memset(&_info, 0, sizeof(_info));
        _info.ps5 = true;
        chiaki_controller_state_set_idle(&_pad);
        _hostC = strdup(host.UTF8String);
        _info.host = _hostC;
        NSData* rk = MCHex(registKeyHex);
        memcpy(_info.regist_key, rk.bytes, MIN(rk.length, sizeof(_info.regist_key)));
        NSData* mo = MCHex(morningHex);
        memcpy(_info.morning, mo.bytes, MIN(mo.length, sizeof(_info.morning)));
        chiaki_connect_video_profile_preset(&_info.video_profile,
                                            height >= 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p,
                                            fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
        if (bitrateKbps > 0) _info.video_profile.bitrate = bitrateKbps;
        _info.video_profile.codec = h265 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
        _h265 = h265;
        _info.video_profile_auto_downgrade = true;
        _info.enable_dualsense = true;
        _info.packet_loss_max = 0.05;
        _info.enable_idr_on_fec_failure = true;
        _videoLayer = [AVSampleBufferDisplayLayer layer];
        _videoLayer.videoGravity = AVLayerVideoGravityResize;   // the player sizes it for Settings → Picture → Picture shape
        _videoLayer.masksToBounds = YES;
        _videoLayer.backgroundColor = UIColor.blackColor.CGColor;
    }
    return self;
}

+ (void) cancelPsn {
    pthread_mutex_lock(&mcPsnMutex);
    mcPsnCancelled = true;
    if (mcPsnActive) chiaki_holepunch_main_thread_cancel(mcPsnActive, false);
    pthread_mutex_unlock(&mcPsnMutex);
}

- (nullable NSString*) start {
    // the curl inside chiaki has no trust store on iPadOS: give it Mozilla's roots, shipped in the app
    NSString* ca = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (ca) setenv("MC_CA_BUNDLE", ca.fileSystemRepresentation, 1);
    if (self.psnToken.length && self.psnDuid.length) {
        ChiakiHolepunchSession hs = MCPsnConnect(&_log, self.psnToken.UTF8String, self.psnDuid);
        if (!hs) return @"Couldn't reach the PS5 over PlayStation Network.";
        _info.holepunch_session = hs;
        if (self.psnAccountId.length == CHIAKI_PSN_ACCOUNT_ID_SIZE) memcpy(_info.psn_account_id, self.psnAccountId.bytes, CHIAKI_PSN_ACCOUNT_ID_SIZE);
    }
    @synchronized (self) { if (_stopped) return @""; }
    ChiakiErrorCode err = chiaki_session_init(&_session, &_info, &_log);
    if (err != CHIAKI_ERR_SUCCESS) {
        return [NSString stringWithFormat:@"Couldn't set up the session: %s", chiaki_error_string(err)];
    }
    _inited = YES;
    chiaki_opus_decoder_init(&_opus, &_log);
    chiaki_opus_decoder_set_cb(&_opus, MCAudioSettings, MCAudioFrame, (__bridge void*)self);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&_opus, &sink);
    chiaki_session_set_audio_sink(&_session, &sink);
    chiaki_session_set_event_cb(&_session, MCEvent, (__bridge void*)self);
    chiaki_session_set_video_sample_cb(&_session, MCVideo, (__bridge void*)self);
    _statsStart = CACurrentMediaTime();
    err = chiaki_session_start(&_session);
    if (err != CHIAKI_ERR_SUCCESS) {
        return [NSString stringWithFormat:@"Couldn't start: %s", chiaki_error_string(err)];
    }
    _started = YES;
    return nil;
}

- (void) stop {
    @synchronized (self) {
        if (_stopped) return;
        _stopped = YES;
    }
    if (_started) {
        chiaki_session_stop(&_session);
        chiaki_session_join(&_session);
    }
    if (_inited) {
        chiaki_session_fini(&_session);
        chiaki_opus_decoder_fini(&_opus);
    }
    [self.audio stop];
    if (_format) { CFRelease(_format); _format = NULL; }
}

- (void) restMode {
    if (_started && !_stopped) {
        chiaki_session_goto_bed(&_session);
    }
}

- (void) dealloc {
    [self stop];
    free(_hostC);
}

- (void) setButtons:(uint32_t)buttons l2:(uint8_t)l2 r2:(uint8_t)r2
              leftX:(int16_t)lx leftY:(int16_t)ly rightX:(int16_t)rx rightY:(int16_t)ry {
    if (!_started || _stopped) return;
    @synchronized (self) {
        _pad.buttons = buttons;
        _pad.l2_state = l2; _pad.r2_state = r2;
        _pad.left_x = lx; _pad.left_y = ly; _pad.right_x = rx; _pad.right_y = ry;
        chiaki_session_set_controller_state(&_session, &_pad);
    }
}

- (int) touchDownX:(int)x y:(int)y {
    if (!_started || _stopped) return -1;
    @synchronized (self) {
        int8_t tid = chiaki_controller_state_start_touch(&_pad, (uint16_t)x, (uint16_t)y);
        chiaki_session_set_controller_state(&_session, &_pad);
        return tid;
    }
}

- (void) touchMove:(int)touchId x:(int)x y:(int)y {
    if (!_started || _stopped || touchId < 0) return;
    @synchronized (self) {
        chiaki_controller_state_set_touch_pos(&_pad, (uint8_t)touchId, (uint16_t)x, (uint16_t)y);
        chiaki_session_set_controller_state(&_session, &_pad);
    }
}

- (void) touchUp:(int)touchId {
    if (!_started || _stopped || touchId < 0) return;
    @synchronized (self) {
        chiaki_controller_state_stop_touch(&_pad, (uint8_t)touchId);
        chiaki_session_set_controller_state(&_session, &_pad);
    }
}

- (void) setLoginPin:(NSString*)pin {
    NSData* d = [pin dataUsingEncoding:NSUTF8StringEncoding];
    chiaki_session_set_login_pin(&_session, d.bytes, d.length);
}

- (NSDictionary*) stats {
    CFTimeInterval now = CACurrentMediaTime(), dt = now - _statsStart;
    if (dt >= 1) {
        _fps = _frames / dt;
        _mbps = _bytes * 8 / dt / 1e6;
        _frames = 0; _bytes = 0; _statsStart = now;
    }
    return @{ @"fps": @(_fps), @"mbps": @(_mbps), @"rtt": @(_started ? (int)(_session.rtt_us / 1000) : -1),
              @"lost": @(_lost), @"codec": _h265 ? @"H.265" : @"H.264" };
}

+ (void) registerHost:(NSString*)host accountId:(NSData*)accountId pin:(uint32_t)pin
           completion:(void (^)(NSDictionary* _Nullable result))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MCPs5Regist* r = [[MCPs5Regist alloc] init];
        chiaki_log_init(&r->log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, MCChiakiLog, NULL);
        r->host = strdup(host.UTF8String);
        r->done = dispatch_semaphore_create(0);
        ChiakiRegistInfo info;
        memset(&info, 0, sizeof(info));
        info.target = CHIAKI_TARGET_PS5_1;
        info.host = r->host;
        info.broadcast = false;
        memcpy(info.psn_account_id, accountId.bytes, MIN(accountId.length, (NSUInteger)CHIAKI_PSN_ACCOUNT_ID_SIZE));
        info.pin = pin;
        NSDictionary* out = nil;
        if (chiaki_regist_start(&r->regist, &r->log, &info, MCRegistCb, (__bridge void*)r) == CHIAKI_ERR_SUCCESS) {
            if (dispatch_semaphore_wait(r->done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
                chiaki_regist_stop(&r->regist);
            }
            chiaki_regist_fini(&r->regist);
            out = r->result;
        }
        free(r->host);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(out); });
    });
}

+ (void) wakeHost:(NSString*)host registKey:(NSString*)registKeyHex {
    // the registKey is ASCII hex ("c7f1c88d") padded with zeros: that ASCII, read as hex, is the credential
    NSData* rk = MCHex(registKeyHex);
    NSString* ascii = [[NSString alloc] initWithBytes:rk.bytes length:strnlen(rk.bytes, rk.length) encoding:NSASCIIStringEncoding];
    unsigned long long cred = 0;
    [[NSScanner scannerWithString:ascii ?: @""] scanHexLongLong:&cred];
    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING, MCChiakiLog, NULL);
    chiaki_discovery_wakeup(&log, NULL, host.UTF8String, cred, true);
}

#pragma mark - callbacks

- (void) handleEvent:(ChiakiEvent*)e {
    id<MCPs5SessionDelegate> d = self.delegate;
    switch (e->type) {
        case CHIAKI_EVENT_CONNECTED: {
            dispatch_async(dispatch_get_main_queue(), ^{ [d ps5Connected]; });
            break;
        }
        case CHIAKI_EVENT_QUIT: {
            NSString* reason = [NSString stringWithUTF8String:chiaki_quit_reason_string(e->quit.reason)] ?: @"";
            if (e->quit.reason_str) reason = [reason stringByAppendingFormat:@": %s", e->quit.reason_str];
            if (e->quit.reason == CHIAKI_QUIT_REASON_STOPPED) reason = @"";
            dispatch_async(dispatch_get_main_queue(), ^{ [d ps5Quit:reason]; });
            break;
        }
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST: {
            BOOL wrong = e->login_pin_request.pin_incorrect;
            dispatch_async(dispatch_get_main_queue(), ^{ [d ps5LoginPinRequested:wrong]; });
            break;
        }
        case CHIAKI_EVENT_RUMBLE: {
            uint8_t l = e->rumble.left, r = e->rumble.right;
            dispatch_async(dispatch_get_main_queue(), ^{ [d ps5Rumble:l right:r]; });
            break;
        }
        default:
            break;
    }
}

/// Annex B NAL units of one frame: parameter sets make the format, the rest become one AVCC sample.
- (void) handleVideo:(uint8_t*)buf size:(size_t)size lost:(int32_t)lost {
    _frames++; _bytes += size;
    if (lost > 0) _lost += lost;
    NSMutableData* sample = [NSMutableData data];
    BOOL newParams = NO;
    size_t i = 0;
    // find NAL starts
    NSMutableArray<NSValue*>* nals = [NSMutableArray array];
    while (i + 3 < size) {
        size_t sc = 0;
        if (buf[i] == 0 && buf[i+1] == 0 && buf[i+2] == 1) sc = 3;
        else if (i + 4 <= size && buf[i] == 0 && buf[i+1] == 0 && buf[i+2] == 0 && buf[i+3] == 1) sc = 4;
        if (sc) { [nals addObject:[NSValue valueWithRange:NSMakeRange(i + sc, 0)]]; i += sc; } else i++;
    }
    for (NSUInteger n = 0; n < nals.count; n++) {
        size_t start = nals[n].rangeValue.location;
        size_t end = size;
        if (n + 1 < nals.count) {
            end = nals[n+1].rangeValue.location - 3;
            if (end > start && buf[end - 1] == 0) end--;   // 4-byte start code
        }
        if (end <= start) continue;
        NSData* nal = [NSData dataWithBytes:buf + start length:end - start];
        int type = _h265 ? (buf[start] >> 1) & 0x3f : buf[start] & 0x1f;
        BOOL param = _h265 ? (type == 32 || type == 33 || type == 34) : (type == 7 || type == 8);
        if (param) {
            if (_h265 ? type == 32 : NO) { if (![nal isEqualToData:_vps]) { _vps = nal; newParams = YES; } }
            else if (_h265 ? type == 33 : type == 7) { if (![nal isEqualToData:_sps]) { _sps = nal; newParams = YES; } }
            else { if (![nal isEqualToData:_pps]) { _pps = nal; newParams = YES; } }
            continue;
        }
        uint32_t len = CFSwapInt32HostToBig((uint32_t)nal.length);
        [sample appendBytes:&len length:4];
        [sample appendData:nal];
    }
    if (newParams && _sps && _pps && (!_h265 || _vps)) {
        CMVideoFormatDescriptionRef fd = NULL;
        OSStatus st;
        if (_h265) {
            const uint8_t* p[3] = { _vps.bytes, _sps.bytes, _pps.bytes };
            size_t s[3] = { _vps.length, _sps.length, _pps.length };
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, p, s, 4, NULL, &fd);
        } else {
            const uint8_t* p[2] = { _sps.bytes, _pps.bytes };
            size_t s[2] = { _sps.length, _pps.length };
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, p, s, 4, &fd);
        }
        if (st == noErr) {
            if (_format) CFRelease(_format);
            _format = fd;
        }
    }
    if (!_format || sample.length == 0) return;

    CMBlockBufferRef block = NULL;
    void* mem = malloc(sample.length);
    memcpy(mem, sample.bytes, sample.length);
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, mem, sample.length, kCFAllocatorMalloc, NULL, 0, sample.length, 0, &block) != noErr) {
        free(mem);
        return;
    }
    CMSampleBufferRef sb = NULL;
    size_t sampleSize = sample.length;
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &sampleSize, &sb) == noErr) {
        CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        MCFsrDecoder* fsr = self.fsrDecoder;
        if (fsr != nil) {
            [fsr decode:sb];
        } else {
            AVSampleBufferDisplayLayer* layer = self.videoLayer;
            if (layer.status == AVQueuedSampleBufferRenderingStatusFailed || layer.requiresFlushToResumeDecoding) {
                [layer flush];
            }
            [layer enqueueSampleBuffer:sb];
        }
        CFRelease(sb);
    }
    CFRelease(block);
}

@end

static void MCEvent(ChiakiEvent* e, void* user) { [(__bridge MCPs5Session*)user handleEvent:e]; }

static bool MCVideo(uint8_t* buf, size_t size, int32_t lost, bool recovered, void* user) {
    [(__bridge MCPs5Session*)user handleVideo:buf size:size lost:lost];
    return true;
}

static void MCAudioSettings(uint32_t channels, uint32_t rate, void* user) {
    NSLog(@"MCAUDIO settings ch=%u rate=%u", channels, rate);
    MCPs5Session* s = (__bridge MCPs5Session*)user;
    // async: stop() may be waiting on the main thread for this session's threads
    dispatch_async(dispatch_get_main_queue(), ^{
        [s.audio stop];
        MCPs5Audio* a = [[MCPs5Audio alloc] init];
        [a startWithChannels:channels rate:rate];
        s.audio = a;
    });
}

static void MCAudioFrame(int16_t* buf, size_t samples, void* user) {
    [((__bridge MCPs5Session*)user).audio push:buf samples:samples];
}
