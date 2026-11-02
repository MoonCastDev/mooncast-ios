//
//  MCPyroWave.mm
//  MoonCast: PyroWave PC streams on the iPad and iPhone (see MCPyroWave.h). Each frame: its records go into
//  PyroWave's Metal decoder, which decodes it into Y, Cb and Cr textures on a command buffer of ours; a second
//  command buffer draws those as RGB into the CAMetalLayer's drawable and presents it. Two frames at most are on the
//  GPU, and a frame that has a newer one waiting behind it is skipped, so the newest frame is the one shown.
//

#import "MCPyroWave.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <Limelight.h>
#include "pyrowave_metal.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <pthread.h>

namespace {

// MARK: record framing

// From MoonCast Android's pyrowave_bitstream.h (Moonlight X, GPL-3.0). PyroWave's bitstream (docs/bitstream.md in
// PyroWave): an 8 byte header starts the frame, then each 32x32 block of coefficients is a whole number of 32-bit
// words with an 8 byte header of its own. Both headers share the first word's top half: payload words (12 bits,
// blocks only), a 3 bit frame sequence number, and whether it's the frame header.
struct BlockHeader {
    uint32_t payloadWords;
    uint32_t sequence;
    bool frameHeader;
    uint32_t blockIndex;
};

inline BlockHeader readHeader(const uint8_t* p) {
    uint16_t word;
    uint32_t second;
    memcpy(&word, p + 2, sizeof(word));
    memcpy(&second, p + 4, sizeof(second));
    return {word & 0xFFFu, (word >> 12) & 0x7u, (word >> 15) != 0, second >> 8};
}

constexpr size_t kHeaderSize = 8;

// Calls push(offset, length) for each run of records in a whole frame in record framing (moonlight-common-c asks
// for it: x-ss-video[0].pyrowaveFeatures), leaving out its padding records: 0xFFFFFFFF, a word count N, then N zero
// words. PyroWave would take one for a broken frame header. A host without record framing sends no padding, so the
// frame goes in one run. Returns false if the records don't add up to the frame, or push does.
template <typename Push>
bool pushRecords(const uint8_t* data, size_t size, Push push) {
    size_t runStart = 0;
    size_t pos = 0;
    while (pos < size) {
        if (size - pos < kHeaderSize) {
            return false;
        }
        uint32_t first;
        memcpy(&first, data + pos, sizeof(first));
        if (first == 0xFFFFFFFFu) {
            uint32_t words;
            memcpy(&words, data + pos + 4, sizeof(words));
            if (pos > runStart && !push(runStart, pos - runStart)) {
                return false;
            }
            if (words > (size - pos - kHeaderSize) / 4) {
                return false;
            }
            pos += kHeaderSize + 4 * static_cast<size_t>(words);
            runStart = pos;
            continue;
        }

        const BlockHeader header = readHeader(data + pos);
        const size_t length = header.frameHeader ? kHeaderSize : 4 * static_cast<size_t>(header.payloadWords);
        if (length < kHeaderSize || length > size - pos) {
            return false;
        }
        pos += length;
    }
    return pos == runStart || push(runStart, pos - runStart);
}

// MARK: the shared PyroWave device

void logMessage(void*, const char* msg) { NSLog(@"MoonCast: PyroWave: %s", msg); }

std::mutex gDeviceLock;
id<MTLDevice> gMtl;
pyrowave_device gDevice;

// PyroWave's device object compiles its decode pipelines, so there's one for the app's life, shared by every stream.
pyrowave_device sharedDevice() {
    std::lock_guard<std::mutex> lock(gDeviceLock);
    if (gDevice) {
        return gDevice;
    }
    @autoreleasepool {
        id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
        if (!mtl || !pyrowave_device_is_supported((__bridge void*)mtl)) {
            NSLog(@"MoonCast: PyroWave: %@ isn't an Apple7-family GPU", mtl.name ?: @"no Metal device");
            return nullptr;
        }
        pyrowave_device_create_info info = {};
        info.mtl_device = (__bridge void*)mtl;
        info.message_callback = logMessage;
        pyrowave_device dev = nullptr;
        pyrowave_result r = pyrowave_device_create(&info, &dev);
        if (r != PYROWAVE_SUCCESS) {
            NSLog(@"MoonCast: PyroWave: device didn't start: %s", pyrowave_result_to_string(r));
            return nullptr;
        }
        gMtl = mtl;
        gDevice = dev;
    }
    return gDevice;
}

// MARK: GPU boost

// Light GPU work between frames so the GPU's clock stays up (Android's gpu_keep_busy; keepbusy.mm in the
// feasibility bench, where it took an A14's decode at stream pace from 4.2-4.5 ms to about 1.5 ms at 4:2:0): a few
// threadgroups of dependent FMAs, about half a millisecond each, two command buffers in flight on a queue of their
// own. Costs battery and heat.
const char* kBoostSource =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void kb(device float *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint g [[thread_position_in_grid]]) {"
    " float x = float(g); for (uint i = 0; i < n; i++) x = x * 0.999987f + 0.5f; o[g] = x; }";

class GpuBoost {
public:
    explicit GpuBoost(id<MTLDevice> dev) : dev_(dev) {}
    ~GpuBoost() { stop(); }

    void start() {
        if (thread_.joinable()) {
            return;
        }
        quit_ = false;
        id<MTLDevice> dev = dev_;
        thread_ = std::thread([this, dev]() {
            pthread_setname_np("MoonCast GPU boost");
            @autoreleasepool {
                NSError* err = nil;
                id<MTLLibrary> lib = [dev newLibraryWithSource:@(kBoostSource) options:nil error:&err];
                id<MTLFunction> fn = [lib newFunctionWithName:@"kb"];
                id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
                if (!ps) {
                    NSLog(@"MoonCast: PyroWave: GPU boost didn't start: %@", err);
                    return;
                }
                const int groups = 4;
                const double chunkMs = 0.5;
                id<MTLCommandQueue> q = [dev newCommandQueue];
                q.label = @"MoonCast GPU boost";
                id<MTLBuffer> buf = [dev newBufferWithLength:groups * 64 * 4 options:MTLResourceStorageModePrivate];
                uint32_t iters = 20000;
                id<MTLCommandBuffer> inflight[2] = {nil, nil};
                int k = 0;
                while (!quit_) {
                    const int s = k++ & 1;
                    if (inflight[s]) {
                        [inflight[s] waitUntilCompleted];
                        const double ms = (inflight[s].GPUEndTime - inflight[s].GPUStartTime) * 1e3;
                        if (ms > 0.01) {
                            double f = chunkMs / ms;
                            f = f > 2 ? 2 : f < 0.5 ? 0.5 : f;
                            iters = uint32_t(iters * f);
                            if (iters < 100) iters = 100;
                        }
                        inflight[s] = nil;
                    }
                    @autoreleasepool {
                        id<MTLCommandBuffer> cb = [q commandBuffer];
                        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                        [e setComputePipelineState:ps];
                        [e setBuffer:buf offset:0 atIndex:0];
                        [e setBytes:&iters length:sizeof(iters) atIndex:1];
                        [e dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                        [e endEncoding];
                        [cb commit];
                        inflight[s] = cb;
                    }
                }
                for (int s = 0; s < 2; s++) {
                    [inflight[s] waitUntilCompleted];
                }
            }
        });
    }

    void stop() {
        quit_ = true;
        if (thread_.joinable()) {
            thread_.join();
        }
    }

private:
    id<MTLDevice> dev_;
    std::atomic<bool> quit_{false};
    std::thread thread_;
};

// MARK: the picture

// Full range YCbCr in separate Y, Cb and Cr planes (4:2:0 or 4:4:4), as PyroWave decodes it, to the layer: as it is
// (SDR, 10-bit SDR, or PQ HDR10 on an EDR layer), or PQ HDR10 tone mapped to SDR where the screen has no EDR, with
// optional dithering. MoonCast Android's pyrowave.frag (from Moonlight X's video_planar.frag, GPL-3.0) in MSL.
const char* kPictureSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// One triangle over the whole layer
vertex VOut pw_vert(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct Params {
    float4 uvClamp;
    float4 params;   // x unused, y dither amplitude, z frame counter, w output mode (1: PQ to SDR)
    float4 params2;  // x content peak nits, y SDR reference white nits
    float4 ycbcr;    // x Kr, y Kb, z chroma midpoint, w chroma U offset
};

// Interleaved gradient noise (Jimenez 2014): fine grain rather than blotches
static float ign(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// SMPTE ST 2084 EOTF, returning linear light where 1.0 is 10000 nits
static float3 pqToLinear(float3 e) {
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;
    float3 ep = pow(max(e, 0.0), float3(1.0 / m2));
    return pow(max(ep - c1, 0.0) / (c2 - c3 * ep), float3(1.0 / m1));
}

// HDR10 content on a screen without EDR: map to SDR BT.709
static float3 pqToSdr(float3 e, constant Params& pc) {
    float sdrWhite = pc.params2.y;
    float3 lin = pqToLinear(e) * (10000.0 / sdrWhite);
    // BT.2020 to BT.709 primaries (columns)
    float3x3 m = float3x3(float3(1.6605, -0.1246, -0.0182),
                          float3(-0.5876, 1.1329, -0.1006),
                          float3(-0.0728, -0.0083, 1.1187));
    lin = max(m * lin, 0.0);
    // Extended Reinhard on luminance, with the content peak mapped to SDR white
    float white = max(pc.params2.x / sdrWhite, 1.0);
    float l = dot(lin, float3(0.2126, 0.7152, 0.0722));
    if (l > 0.0) {
        float lt = l * (1.0 + l / (white * white)) / (1.0 + l);
        lin *= lt / l;
    }
    return pow(clamp(lin, 0.0, 1.0), float3(1.0 / 2.2));
}

fragment float4 pw_frag(VOut in [[stage_in]],
                        texture2d<float> ty [[texture(0)]],
                        texture2d<float> tcb [[texture(1)]],
                        texture2d<float> tcr [[texture(2)]],
                        sampler s [[sampler(0)]],
                        constant Params& pc [[buffer(0)]]) {
    float2 uv = clamp(in.uv, pc.uvClamp.xy, pc.uvClamp.zw);
    float y = ty.sample(s, uv).r;

    // Some hosts site 4:2:0 chroma with the left luma sample of each pair, not between them
    float2 chromaUv = uv + float2(pc.ycbcr.w, 0.0);
    float cb = tcb.sample(s, chromaUv).r - pc.ycbcr.z;
    float cr = tcr.sample(s, chromaUv).r - pc.ycbcr.z;

    float kr = pc.ycbcr.x;
    float kb = pc.ycbcr.y;
    float r = y + 2.0 * (1.0 - kr) * cr;
    float b = y + 2.0 * (1.0 - kb) * cb;
    float g = (y - kr * r - kb * b) / (1.0 - kr - kb);
    float3 color = clamp(float3(r, g, b), 0.0, 1.0);

    if (pc.params.w == 1.0) {
        color = pqToSdr(color, pc);
    }

    float amplitude = pc.params.y;
    if (amplitude > 0.0) {
        // Triangular dither of +/- 1 LSB from two decorrelated noise samples, moved each frame
        float2 p = in.pos.xy + 5.588238 * fmod(pc.params.z, 64.0);
        float n = ign(p) + ign(p + float2(47.0, 17.0)) - 1.0;
        color += n * amplitude;
    }
    return float4(color, 1.0);
}
)MSL";

struct PictureParams {
    float uvClamp[4];
    float params[4];
    float params2[4];
    float ycbcr[4];
};

constexpr float kSdrWhiteNits = 203.0f;
constexpr int kFramesInFlight = 2;

}  // namespace

// MARK: settings and probe

@implementation MCPyroWave

static BOOL probeDevice(void) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSString* build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"0";
    NSString* key = [NSString stringWithFormat:@"%@/%@", build, UIDevice.currentDevice.systemVersion];
    NSString* cached = [d stringForKey:@"mc_pyrowave_probe"];
    NSRange bar = cached ? [cached rangeOfString:@"|" options:NSBackwardsSearch] : NSMakeRange(NSNotFound, 0);
    if (bar.location != NSNotFound && [[cached substringToIndex:bar.location] isEqualToString:key]) {
        // "probing" left behind means the probe took the app down last time (a GPU driver crash): never again
        BOOL ok = [[cached substringFromIndex:bar.location + 1] isEqualToString:@"1"];
        if (!ok) {
            NSLog(@"MoonCast: PyroWave: not on this device (%@)", cached);
        }
        return ok;
    }
    [d setObject:[key stringByAppendingString:@"|probing"] forKey:@"mc_pyrowave_probe"];
    [d synchronize];
    BOOL ok = NO;
    @autoreleasepool {
        pyrowave_device dev = sharedDevice();
        if (dev) {
            pyrowave_decoder_create_info di = {};
            di.device = dev;
            di.width = 256;
            di.height = 256;
            di.chroma = PYROWAVE_CHROMA_SUBSAMPLING_420;
            pyrowave_decoder dec = nullptr;
            ok = pyrowave_decoder_create(&di, &dec) == PYROWAVE_SUCCESS;
            if (dec) {
                pyrowave_decoder_destroy(dec);
            }
        }
    }
    [d setObject:[key stringByAppendingString:ok ? @"|1" : @"|0"] forKey:@"mc_pyrowave_probe"];
    NSLog(@"MoonCast: PyroWave probe on %@: %@", gMtl.name ?: @"this GPU", ok ? @"yes" : @"no");
    return ok;
}

+ (BOOL)deviceSupported {
    static dispatch_once_t once;
    static BOOL able;
    dispatch_once(&once, ^{ able = probeDevice(); });
    return able;
}

+ (BOOL)wanted { return [NSUserDefaults.standardUserDefaults boolForKey:@"mc_pyrowave"]; }

static BOOL boolDefault(NSString* key, BOOL def) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : def;
}

+ (BOOL)want444 { return boolDefault(@"mc_pyrowave_444", YES); }
+ (BOOL)gpuBoost { return boolDefault(@"mc_pyrowave_boost", YES); }

+ (int)ditherMode {
    NSString* v = [NSUserDefaults.standardUserDefaults stringForKey:@"mc_pyrowave_dither"] ?: @"low";
    return [v isEqualToString:@"high"] ? 2 : [v isEqualToString:@"off"] ? 0 : 1;
}

+ (int)recommendedKbpsWidth:(int)width height:(int)height fps:(int)fps {
    const double bitsPerPixel = 400000000.0 / (2560.0 * 1440 * 120);
    return (int)llround((double)width * height * fps * bitsPerPixel / 1000000) * 1000;
}

@end

// MARK: the renderer

/// The display link's target, so it doesn't keep the renderer alive. The link only asks ProMotion for the stream's
/// frame rate; frames are presented as they're decoded.
@interface MCPyroWaveTick : NSObject
- (void)tick:(CADisplayLink*)link;
@end

@implementation MCPyroWaveTick
- (void)tick:(CADisplayLink*)link {}
@end

@implementation MCPyroWaveRenderer {
    CAMetalLayer* _layer;
    CADisplayLink* _link;
    id<MTLDevice> _mtl;
    id<MTLCommandQueue> _queue;
    id<MTLLibrary> _library;
    id<MTLSamplerState> _sampler;
    NSMutableDictionary<NSNumber*, id<MTLRenderPipelineState>>* _pipelines;

    pyrowave_decoder _decoder;
    id<MTLTexture> _planes[kFramesInFlight][3];
    int _slot;
    int _width, _height;
    BOOL _tenBit, _chroma444, _centerChroma;
    int _dither;
    uint32_t _frameCounter;

    dispatch_semaphore_t _inflight;
    NSLock* _frameLock;
    std::atomic<bool> _stopped;
    std::atomic<bool> _background;
    std::atomic<bool> _hdrActive;
    std::atomic<float> _peakNits;
    /// The layer takes PQ (EDR): set on the main thread with the layer
    std::atomic<bool> _pqLayer;
    BOOL _shown;
    BOOL _loggedBadFrame;
    uint64_t _badFrames;

    std::mutex _statsLock;
    double _gpuMsSum;
    int _gpuFrames;
    CFTimeInterval _windowStart;
    double _decodeMs;

    std::unique_ptr<GpuBoost> _boost;
    BOOL _boostWanted;
    id _backgroundObserver;
    id _foregroundObserver;
}

- (instancetype)initWithView:(UIView*)view above:(CALayer*)below videoFormat:(int)videoFormat
                       width:(int)width height:(int)height fps:(int)fps {
    self = [super init];
    if (!self) return nil;

    pyrowave_device dev = sharedDevice();
    if (!dev) return nil;
    _mtl = gMtl;
    _width = width;
    _height = height;
    _tenBit = (videoFormat & VIDEO_FORMAT_MASK_10BIT) != 0;
    _chroma444 = (videoFormat & VIDEO_FORMAT_MASK_YUV444) != 0;
    // Hosts that say which PyroWave they encode with (vibeshine) site 4:2:0 chroma at the center; the others (this
    // fork's Sunshine, Polaris) with the left luma sample
    const char* bitstreamId = LiGetHostPyroWaveBitstreamId();
    _centerChroma = bitstreamId != NULL && bitstreamId[0] != '\0';
    _dither = MCPyroWave.ditherMode;
    _peakNits = 1000.0f;
    _decodeMs = -1;

    pyrowave_decoder_create_info di = {};
    di.device = dev;
    di.width = width;
    di.height = height;
    di.chroma = _chroma444 ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
    pyrowave_result r = pyrowave_decoder_create(&di, &_decoder);
    if (r != PYROWAVE_SUCCESS) {
        NSLog(@"MoonCast: PyroWave: decoder for %dx%d didn't start: %s", width, height, pyrowave_result_to_string(r));
        _decoder = nullptr;
        return nil;
    }

    // Full range, as PyroWave writes it: 8-bit planes as R8, 10-bit as R16 (normalized)
    const MTLPixelFormat pf = _tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm;
    for (int s = 0; s < kFramesInFlight; s++) {
        for (int p = 0; p < 3; p++) {
            const BOOL half = p != 0 && !_chroma444;
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf
                                                                                         width:half ? width / 2 : width
                                                                                        height:half ? height / 2 : height
                                                                                     mipmapped:NO];
            td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            _planes[s][p] = [_mtl newTextureWithDescriptor:td];
            if (!_planes[s][p]) {
                NSLog(@"MoonCast: PyroWave: no memory for %dx%d planes", width, height);
                pyrowave_decoder_destroy(_decoder);
                _decoder = nullptr;
                return nil;
            }
        }
    }

    NSError* err = nil;
    _library = [_mtl newLibraryWithSource:@(kPictureSource) options:nil error:&err];
    if (!_library) {
        NSLog(@"MoonCast: PyroWave: picture shader didn't compile: %@", err);
        pyrowave_decoder_destroy(_decoder);
        _decoder = nullptr;
        return nil;
    }
    _pipelines = [NSMutableDictionary dictionary];
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_mtl newSamplerStateWithDescriptor:sd];
    _queue = [_mtl newCommandQueue];
    _queue.label = @"MoonCast PyroWave";
    _inflight = dispatch_semaphore_create(kFramesInFlight);
    _frameLock = [NSLock new];

    _layer = [CAMetalLayer layer];
    _layer.device = _mtl;
    _layer.framebufferOnly = YES;
    _layer.opaque = YES;
    _layer.backgroundColor = UIColor.blackColor.CGColor;
    _layer.contentsScale = view.window.screen.nativeScale ?: UIScreen.mainScreen.nativeScale;
    // Two: a frame waits for at most one on screen (the lowest delay)
    _layer.maximumDrawableCount = 2;
    [self configureLayerForHdr:NO];
    // over the (hidden) display layer, under everything drawn on top of the picture
    if (below.superlayer == view.layer) [view.layer insertSublayer:_layer above:below];
    else [view.layer insertSublayer:_layer atIndex:0];
    [self layoutInFrame:below.frame];

    // ProMotion runs at the stream's frame rate while the link asks for it
    _link = [CADisplayLink displayLinkWithTarget:[MCPyroWaveTick new] selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
    } else {
        _link.preferredFramesPerSecond = fps;
    }
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    _boostWanted = MCPyroWave.gpuBoost;
    _boost.reset(new GpuBoost(_mtl));
    if (_boostWanted) {
        _boost->start();
    }
    // No GPU work in the background: frames are dropped there (the stream ends there anyway, PiP being off)
    __weak MCPyroWaveRenderer* weakSelf = self;
    _backgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                                         object:nil queue:nil usingBlock:^(NSNotification*) {
        MCPyroWaveRenderer* me = weakSelf;
        if (!me) return;
        me->_background = true;
        if (me->_boost) me->_boost->stop();
    }];
    _foregroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                         object:nil queue:nil usingBlock:^(NSNotification*) {
        MCPyroWaveRenderer* me = weakSelf;
        if (!me || me->_stopped) return;
        me->_background = false;
        if (me->_boostWanted && me->_boost) me->_boost->start();
    }];

    NSLog(@"MoonCast: PyroWave decoding %dx%d %d fps%s%s on %@, chroma %s, dither %d, GPU boost %d", width, height, fps,
          _tenBit ? " 10-bit" : "", _chroma444 ? " 4:4:4" : " 4:2:0", _mtl.name,
          _chroma444 ? "full" : _centerChroma ? "centered" : "left-sited", _dither, (int)_boostWanted);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)layoutInFrame:(CGRect)frame {
    CAMetalLayer* layer = _layer;
    if (!layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.frame = frame;
    [CATransaction commit];
    const CGFloat k = layer.contentsScale;
    layer.drawableSize = CGSizeMake(MAX(1, round(frame.size.width * k)), MAX(1, round(frame.size.height * k)));
}

// SDR: the stream's own precision in sRGB. HDR on a screen with EDR: PQ BT.2100, as the host sends it. Main thread.
- (void)configureLayerForHdr:(BOOL)pq {
    CAMetalLayer* layer = _layer;
    CGColorSpaceRef cs = NULL;
    if (pq) {
        if (@available(iOS 16.0, *)) {
            layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
            cs = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
            layer.wantsExtendedDynamicRangeContent = YES;
            SS_HDR_METADATA md;
            float maxNits = 1000, minNits = 0.005f;
            if (LiGetHdrMetadata(&md) && md.maxDisplayLuminance != 0 && md.maxDisplayLuminance < 10000) {
                maxNits = md.maxDisplayLuminance;
                minNits = md.minDisplayLuminance * 0.0001f;
            }
            layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:minNits maxLuminance:maxNits opticalOutputScale:100];
        }
    }
    else {
        layer.pixelFormat = _tenBit ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
        cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (@available(iOS 16.0, *)) {
            layer.wantsExtendedDynamicRangeContent = NO;
            layer.EDRMetadata = nil;
        }
    }
    layer.colorspace = cs;
    if (cs) CGColorSpaceRelease(cs);
    _pqLayer = pq && cs != NULL && layer.pixelFormat == MTLPixelFormatBGR10A2Unorm && _hdrActive;
}

- (void)setHdr:(BOOL)enabled {
    const bool hdr = enabled && _tenBit;
    if (hdr) {
        SS_HDR_METADATA md;
        float peak = 1000.0f;
        if (LiGetHdrMetadata(&md)) {
            // A 10000 nit peak is the top of the PQ range, which hosts send when they don't know the display's own
            if (md.maxContentLightLevel != 0 && md.maxContentLightLevel < 10000) peak = md.maxContentLightLevel;
            else if (md.maxDisplayLuminance != 0 && md.maxDisplayLuminance < 10000) peak = md.maxDisplayLuminance;
        }
        _peakNits = peak;
    }
    BOOL edr = NO;
    if (@available(iOS 16.0, *)) {
        edr = UIScreen.mainScreen.potentialEDRHeadroom > 1.0;
    }
    const BOOL pq = hdr && edr;
    _hdrActive = hdr;
    NSLog(@"MoonCast: PyroWave HDR %s%s", hdr ? "on" : "off", hdr ? (pq ? ", PQ on an EDR screen" : ", tone mapped to SDR") : "");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stopped) return;
        [self configureLayerForHdr:pq];
    });
}

- (id<MTLRenderPipelineState>)pipelineFor:(MTLPixelFormat)format {
    id<MTLRenderPipelineState> p = _pipelines[@(format)];
    if (p) return p;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [_library newFunctionWithName:@"pw_vert"];
    d.fragmentFunction = [_library newFunctionWithName:@"pw_frag"];
    d.colorAttachments[0].pixelFormat = format;
    NSError* err = nil;
    p = [_mtl newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) {
        NSLog(@"MoonCast: PyroWave: picture pipeline for format %d failed: %@", (int)format, err);
        return nil;
    }
    _pipelines[@(format)] = p;
    return p;
}

- (int)submitFrame:(const uint8_t*)data length:(size_t)length {
    if (_stopped || _background) return DR_OK;
    // Every frame stands alone, so with a newer one waiting this one is just skipped: the newest is shown
    if (LiGetPendingVideoFrames() > 0) return DR_OK;
    [_frameLock lock];
    if (!_stopped && _decoder) {
        @autoreleasepool {
            [self decode:data length:length];
        }
    }
    [_frameLock unlock];
    return DR_OK;
}

- (void)badFrame:(const char*)why {
    _badFrames++;
    if (!_loggedBadFrame) {
        _loggedBadFrame = YES;
        NSLog(@"MoonCast: PyroWave: frame dropped: %s", why);
    }
}

- (void)decode:(const uint8_t*)data length:(size_t)length {
    // Each frame arrives on its own, so anything left from an earlier one is stale
    pyrowave_decoder_clear(_decoder);
    pyrowave_result result = PYROWAVE_SUCCESS;
    pyrowave_decoder dec = _decoder;
    const bool pushed = pushRecords(data, length, [&](size_t offset, size_t len) {
        result = pyrowave_decoder_push_packet(dec, data + offset, len);
        return result == PYROWAVE_SUCCESS;
    });
    if (!pushed || result != PYROWAVE_SUCCESS) {
        [self badFrame:result != PYROWAVE_SUCCESS ? pyrowave_result_to_string(result) : "records don't add up"];
        return;
    }
    // moonlight-common-c hands over only whole frames; one PyroWave still finds short is decoded with its missing
    // blocks as zero (a little blur) when it has its coarsest levels
    if (!pyrowave_decoder_decode_is_ready(dec, false) && !pyrowave_decoder_decode_is_ready(dec, true)) {
        [self badFrame:"incomplete"];
        return;
    }

    // Two frames on the GPU at most; a GPU that stopped answering drops frames rather than queueing them
    if (dispatch_semaphore_wait(_inflight, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        [self badFrame:"GPU busy"];
        return;
    }
    const int s = _slot;
    _slot = (_slot + 1) % kFramesInFlight;
    dispatch_semaphore_t inflight = _inflight;

    id<MTLCommandBuffer> decodeCb = [_queue commandBuffer];
    decodeCb.label = @"PyroWave decode";
    pyrowave_gpu_buffers buffers = {};
    for (int p = 0; p < 3; p++) buffers.planes[p] = (__bridge void*)_planes[s][p];
    pyrowave_result r = pyrowave_decoder_decode_gpu_buffer(dec, (__bridge void*)decodeCb, &buffers);
    if (r != PYROWAVE_SUCCESS) {
        dispatch_semaphore_signal(inflight);
        [self badFrame:pyrowave_result_to_string(r)];
        return;
    }
    __weak MCPyroWaveRenderer* weakSelf = self;
    [decodeCb addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        if (cb.status == MTLCommandBufferStatusCompleted) {
            [weakSelf addGpuMs:(cb.GPUEndTime - cb.GPUStartTime) * 1e3];
        }
    }];
    // The decode starts on the GPU while we wait for a drawable
    [decodeCb commit];

    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    id<MTLCommandBuffer> drawCb = [_queue commandBuffer];
    drawCb.label = @"PyroWave picture";
    [drawCb addCompletedHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(inflight); }];
    id<MTLRenderPipelineState> pipe = drawable ? [self pipelineFor:drawable.texture.pixelFormat] : nil;
    if (pipe) {
        const MTLPixelFormat fmt = drawable.texture.pixelFormat;
        const bool hdr = _hdrActive;
        // the layer is PQ (EDR) only while HDR is on and the screen has EDR; otherwise HDR is tone mapped
        const bool pqLayer = hdr && _pqLayer && fmt == MTLPixelFormatBGR10A2Unorm;
        const int outBits = fmt == MTLPixelFormatBGR10A2Unorm ? 10 : 8;
        const float w = (float)_width, h = (float)_height;
        PictureParams pc = {};
        // Stay half a texel inside the picture so filtering never pulls in the edge
        pc.uvClamp[0] = 0.5f / w;
        pc.uvClamp[1] = 0.5f / h;
        pc.uvClamp[2] = 1.0f - 0.5f / w;
        pc.uvClamp[3] = 1.0f - 0.5f / h;
        // Low dithers at the output's own precision, High at 8-bit precision even on a 10-bit output
        pc.params[1] = _dither == 1 ? 1.0f / (float)((1 << outBits) - 1) : _dither == 2 ? 1.0f / 255.0f : 0.0f;
        pc.params[2] = (float)(_frameCounter++ % 64);
        pc.params[3] = (hdr && !pqLayer) ? 1.0f : 0.0f;
        pc.params2[0] = _peakNits;
        pc.params2[1] = kSdrWhiteNits;
        // PyroWave is always full range, BT.709 as we ask for it, or BT.2020 while the host is in HDR
        pc.ycbcr[0] = hdr ? 0.2627f : 0.2126f;
        pc.ycbcr[1] = hdr ? 0.0593f : 0.0722f;
        // Gray chroma as an 8-bit UNORM plane stores it; 16-bit is as good as 0.5
        pc.ycbcr[2] = _tenBit ? 0.5f : 128.0f / 255.0f;
        // 4:4:4 has a chroma sample at every pixel
        pc.ycbcr[3] = (_centerChroma || _chroma444) ? 0.0f : 0.5f / w;

        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [drawCb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipe];
        for (int p = 0; p < 3; p++) [enc setFragmentTexture:_planes[s][p] atIndex:p];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc setFragmentBytes:&pc length:sizeof(pc) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [drawCb presentDrawable:drawable];
    }
    [drawCb commit];

    if (pipe && !_shown) {
        _shown = YES;
        void (^first)(void) = self.onFirstFrame;
        if (first) dispatch_async(dispatch_get_main_queue(), first);
    }
}

- (void)addGpuMs:(double)ms {
    std::lock_guard<std::mutex> lock(_statsLock);
    const CFTimeInterval now = CACurrentMediaTime();
    if (_windowStart == 0) _windowStart = now;
    _gpuMsSum += ms;
    _gpuFrames++;
    // a one second window, like the other stream stats
    if (now - _windowStart >= 1.0) {
        _decodeMs = _gpuMsSum / _gpuFrames;
        _gpuMsSum = 0;
        _gpuFrames = 0;
        _windowStart = now;
    }
}

- (double)decodeMs {
    std::lock_guard<std::mutex> lock(_statsLock);
    return _decodeMs;
}

- (void)stop {
    if (_stopped.exchange(true) || !_inflight) return;
    [_frameLock lock];
    // the GPU finishes with the frames it has before the decoder goes
    for (int i = 0; i < kFramesInFlight; i++) dispatch_semaphore_wait(_inflight, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    for (int i = 0; i < kFramesInFlight; i++) dispatch_semaphore_signal(_inflight);
    if (_decoder) {
        pyrowave_decoder_destroy(_decoder);
        _decoder = nullptr;
    }
    [_frameLock unlock];
    if (_boost) _boost->stop();
    if (_backgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:_backgroundObserver];
    if (_foregroundObserver) [NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];
    _backgroundObserver = nil;
    _foregroundObserver = nil;
    CADisplayLink* link = _link;
    CAMetalLayer* layer = _layer;
    _link = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [link invalidate];
        [layer removeFromSuperlayer];
    });
    if (_badFrames) NSLog(@"MoonCast: PyroWave: %llu frames dropped as bad", (unsigned long long)_badFrames);
}

@end
