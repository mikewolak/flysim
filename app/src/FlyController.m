// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlyController.m

#import "FlyController.h"
#import "flysim.h"
#import <os/lock.h>
#import <mach/mach_time.h>

@implementation FlyController {
    FlySim*   _sim;
    NSThread* _thread;
    volatile BOOL _runFlag;

    // resolved sets (indices into the model)
    FlySet _sugar, _water, _bitter, _mn9, _l2;
    FlySet _smell, _touch, _heat, _humid, _light;   // the rest of the senses
    FlySet _motor, _dn;                              // motor + descending outputs
    FlySet _smellL, _smellR, _lightL, _lightR, _dnL, _dnR;   // bilateral (3D flight)
    FlySet _steerL, _steerR;                                 // DNa steering DNs L/R
    FlySet _escL, _escR;                                     // DNp escape/loom DNs L/R

    NSDictionary<NSString *, NSNumber *> *_sensePeak;   // sense name -> peak heat-bin (0..1)

    os_unfair_lock _lock;     // guards _snap
    FlySnapshot    _snap;

    BOOL _wantGPU;
    volatile int _pendingBackend;   // sim thread should apply _wantGPU
    double _t2ns;             // mach timebase -> ns
    NSString* _binPath;
}

- (instancetype)initWithBinPath:(NSString *)path {
    if (!(self = [super init])) return nil;

    _sim = flysim_open(path.fileSystemRepresentation, FLYSIM_CPU);
    if (!_sim) return nil;
    _binPath = [path copy];
    _speed = 1.0;            // real time by default
    _eventDriven = YES;      // sparse scatter on by default (bit-exact, faster)

    _lock = OS_UNFAIR_LOCK_INIT;
    _neuronCount = flysim_neuron_count(_sim);
    _edgeCount   = flysim_edge_count(_sim);

    [self _resolveSets];
    flysim_set_eventdriven(_sim, _eventDriven);

    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    _t2ns = (double)tb.numer / (double)tb.denom;

    memset(&_snap, 0, sizeof(_snap));
    return self;
}

- (void)dealloc {
    [self stop];
    if (_sim) flysim_close(_sim);
}

// resolve every named population we clamp or read (called at open + reset)
- (void)_resolveSets {
    _sugar  = flysim_set_by_modality(_sim, MOD_GUSTATORY_SUGAR,  -1);
    _water  = flysim_set_by_modality(_sim, MOD_GUSTATORY_WATER,  -1);
    _bitter = flysim_set_by_modality(_sim, MOD_GUSTATORY_BITTER, -1);
    _smell  = flysim_set_by_modality(_sim, MOD_OLFACTORY,        -1);
    _touch  = flysim_set_by_modality(_sim, MOD_MECHANO_ANTENNA,  -1);
    _heat   = flysim_set_by_modality(_sim, MOD_THERMO,           -1);
    _humid  = flysim_set_by_modality(_sim, MOD_HYGRO,            -1);
    _light  = flysim_set_by_modality(_sim, MOD_VISUAL,           -1);
    _motor  = flysim_set_by_superclass(_sim, SC_MOTOR,           -1);
    _dn     = flysim_set_by_superclass(_sim, SC_DESCENDING,      -1);
    _mn9    = flysim_set_by_celltype(_sim, "MN9");
    _l2     = flysim_set_by_celltype(_sim, "feeding_interneuron");
    // bilateral pathway for the 3D flight loop: left/right olfactory ORNs in,
    // left/right descending neurons (the brain's command lines) out.
    _smellL = flysim_set_by_modality(_sim, MOD_OLFACTORY, SIDE_LEFT);
    _smellR = flysim_set_by_modality(_sim, MOD_OLFACTORY, SIDE_RIGHT);
    _lightL = flysim_set_by_modality(_sim, MOD_VISUAL, SIDE_LEFT);   // left eye
    _lightR = flysim_set_by_modality(_sim, MOD_VISUAL, SIDE_RIGHT);  // right eye
    _dnL    = flysim_set_by_superclass(_sim, SC_DESCENDING, SIDE_LEFT);
    _dnR    = flysim_set_by_superclass(_sim, SC_DESCENDING, SIDE_RIGHT);
    // the DNa steering family (DNa01..08) split by side — the actual turn-command
    // descending neurons, far cleaner than averaging all 1,303 descending cells.
    _steerL = flysim_set_by_celltype_prefix(_sim, "DNa", SIDE_LEFT);
    _steerR = flysim_set_by_celltype_prefix(_sim, "DNa", SIDE_RIGHT);
    // the DNp "posterior" cluster (DNp01 giant fiber + the loom-sensitive escape
    // DNs) split by side — the brain's collision-avoidance / escape command.
    _escL = flysim_set_by_celltype_prefix(_sim, "DNp", SIDE_LEFT);
    _escR = flysim_set_by_celltype_prefix(_sim, "DNp", SIDE_RIGHT);

    // Where each sense's afferent population sits along the heat strip (peak row-
    // bin, 0..1) — so the UI can mark which heatmap rows light up per sense.
    NSDictionary<NSString *, NSNumber *> *named =
        @{ @"sugar":@(_sugar), @"water":@(_water), @"bitter":@(_bitter),
           @"smell":@(_smell), @"touch":@(_touch), @"heat":@(_heat),
           @"humidity":@(_humid), @"light":@(_light) };
    float prof[FS_BINS];
    NSMutableDictionary *pk = [NSMutableDictionary dictionary];
    for (NSString *nm in named) {
        int pb = flysim_set_bins(_sim, (FlySet)[named[nm] unsignedIntValue], FS_BINS, prof);
        if (pb >= 0) pk[nm] = @((double)pb / (FS_BINS - 1));
    }
    _sensePeak = pk;
}

- (NSDictionary<NSString *, NSNumber *> *)sensePeakBins { return _sensePeak; }

// apply every UI sensory clamp to the model (called each sim chunk + on step)
- (void)_applyClamps {
    flysim_clamp(_sim, _sugar,  self.sugarHz);
    flysim_clamp(_sim, _water,  self.waterHz);
    flysim_clamp(_sim, _bitter, self.bitterHz);
    // olfactory: bilateral when the 3D flight loop is driving it, else symmetric
    if (self.smellLeftHz > 0 || self.smellRightHz > 0) {
        flysim_clamp(_sim, _smellL, self.smellLeftHz);
        flysim_clamp(_sim, _smellR, self.smellRightHz);
    } else {
        flysim_clamp(_sim, _smell, self.smellHz);
    }
    flysim_clamp(_sim, _touch,  self.touchHz);
    flysim_clamp(_sim, _heat,   self.heatHz);
    flysim_clamp(_sim, _humid,  self.humidityHz);
    // vision: bilateral (left/right eye) when the flight loop drives it, else symmetric
    if (self.lightLeftHz > 0 || self.lightRightHz > 0) {
        flysim_clamp(_sim, _lightL, self.lightLeftHz);
        flysim_clamp(_sim, _lightR, self.lightRightHz);
    } else {
        flysim_clamp(_sim, _light, self.lightHz);
    }
}

// left/right descending-neuron mean firing (Hz) — the brain's steering output
- (void)descendingLeft:(float *)l right:(float *)r {
    if (l) *l = flysim_set_rate(_sim, _dnL);
    if (r) *r = flysim_set_rate(_sim, _dnR);
}
- (uint32_t)dnLeftSize  { return flysim_set_size(_sim, _dnL); }
- (uint32_t)dnRightSize { return flysim_set_size(_sim, _dnR); }

// map a friendly sensory name → FlyModality, or -1
static int FSModalityForName(NSString *n) {
    n = n.lowercaseString;
    if ([n isEqualToString:@"sugar"])  return MOD_GUSTATORY_SUGAR;
    if ([n isEqualToString:@"water"])  return MOD_GUSTATORY_WATER;
    if ([n isEqualToString:@"bitter"]) return MOD_GUSTATORY_BITTER;
    if ([n isEqualToString:@"smell"] || [n isEqualToString:@"olfactory"]) return MOD_OLFACTORY;
    if ([n isEqualToString:@"touch"] || [n isEqualToString:@"mechano"] ||
        [n isEqualToString:@"mechanosensory"]) return MOD_MECHANO_ANTENNA;
    if ([n isEqualToString:@"heat"]  || [n isEqualToString:@"thermo"]) return MOD_THERMO;
    if ([n isEqualToString:@"humidity"] || [n isEqualToString:@"hygro"]) return MOD_HYGRO;
    if ([n isEqualToString:@"light"] || [n isEqualToString:@"visual"] ||
        [n isEqualToString:@"vision"]) return MOD_VISUAL;
    return -1;
}
// map a friendly superclass name → FlySuperclass, or -1
static int FSSuperclassForName(NSString *n) {
    n = n.lowercaseString;
    if ([n isEqualToString:@"sensory"])    return SC_SENSORY;
    if ([n isEqualToString:@"motor"])      return SC_MOTOR;
    if ([n isEqualToString:@"descending"]) return SC_DESCENDING;
    if ([n isEqualToString:@"ascending"])  return SC_ASCENDING;
    if ([n isEqualToString:@"endocrine"])  return SC_ENDOCRINE;
    if ([n isEqualToString:@"central"])    return SC_CENTRAL;
    if ([n isEqualToString:@"optic"])      return SC_OPTIC;
    if ([n isEqualToString:@"visual_projection"])  return SC_VISUAL_PROJECTION;
    if ([n isEqualToString:@"visual_centrifugal"]) return SC_VISUAL_CENTRIFUGAL;
    return -1;
}

- (BOOL)usingGPU { return flysim_backend(_sim) == FLYSIM_GPU; }

- (void)setUseGPU:(BOOL)gpu {
    _wantGPU = gpu;
    if (!_runFlag) {
        // safe to switch immediately when the sim thread is idle
        flysim_set_backend(_sim, gpu ? FLYSIM_GPU : FLYSIM_CPU);
        flysim_set_eventdriven(_sim, _eventDriven);   // new GPU ctx inherits mode
        _pendingBackend = 0;
    } else {
        _pendingBackend = 1;   // sim thread applies at the next chunk boundary
    }
}

- (void)setEventDriven:(BOOL)on {
    _eventDriven = on;
    flysim_set_eventdriven(_sim, on);
}

- (void)start {
    if (_runFlag) return;
    _runFlag = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(_loop) object:nil];
    _thread.name = @"flysim.clock";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];
}

- (void)stop {
    _runFlag = NO;
    while (_thread && !_thread.isFinished) { usleep(500); }
    _thread = nil;
}

- (BOOL)isRunning { return _runFlag; }

- (void)reset {
    BOOL wasRunning = _runFlag;
    [self stop];
    // cheapest correct reset: reopen the model (clears V/spike/rate/clamps)
    NSString* path = _binPath;
    if (path) {
        flysim_close(_sim);
        _sim = flysim_open(path.fileSystemRepresentation, FLYSIM_CPU);
        [self _resolveSets];
        flysim_set_eventdriven(_sim, _eventDriven);
        if (_wantGPU) flysim_set_backend(_sim, FLYSIM_GPU);   // keep backend across reset
    }
    os_unfair_lock_lock(&_lock);
    memset(&_snap, 0, sizeof(_snap));
    os_unfair_lock_unlock(&_lock);
    if (wasRunning) [self start];
}

// the biological clock --------------------------------------------------------
- (void)_loop {
    const float  dt = 0.001f;       // 1 ms biological timestep
    const int    K  = 8;            // steps per chunk (amortizes dispatch — §6.3). The
                                    // 139k brain is compute-bound at ~1x real-time live;
                                    // bigger K doesn't help (publish isn't the bottleneck).

    uint64_t t0 = mach_absolute_time();
    uint64_t stepAcc = 0;
    uint64_t perfT0 = t0;

    while (_runFlag) {
        // apply a pending backend switch on the thread that owns _sim
        if (_pendingBackend) {
            flysim_set_backend(_sim, _wantGPU ? FLYSIM_GPU : FLYSIM_CPU);
            flysim_set_eventdriven(_sim, _eventDriven);
            _pendingBackend = 0;
        }
        // apply UI stimulus to the model
        [self _applyClamps];

        flysim_run(_sim, dt, K);
        stepAcc += K;

        [self _publish];

        // pace to the speed cap (speed<=0 => unthrottled, run flat out)
        uint64_t now = mach_absolute_time();
        double spd = self.speed;
        if (spd > 0) {
            double targetNs = (double)K * dt * 1e9 / spd;   // wall time this chunk should take
            double elapsedNs = (double)(now - t0) * _t2ns;
            if (elapsedNs < targetNs) {
                useconds_t us = (useconds_t)((targetNs - elapsedNs) / 1000.0);
                if (us > 0 && us < 200000) usleep(us);
            }
        }
        t0 = mach_absolute_time();

        // refresh measured throughput ~4x/sec
        double perfNs = (double)(now - perfT0) * _t2ns;
        if (perfNs > 0.25e9) {
            double sps = stepAcc / (perfNs / 1e9);
            os_unfair_lock_lock(&_lock);
            _snap.stepsPerSec    = sps;
            _snap.realtimeFactor = sps * dt;
            os_unfair_lock_unlock(&_lock);
            stepAcc = 0; perfT0 = now;
        }
    }
}

- (void)_publish {
    uint32_t n = 0;
    const float* rate = flysim_rate_buffer(_sim, &n);

    FlySnapshot s;
    s.mn9Rate    = flysim_set_rate(_sim, _mn9);
    s.sugarRate  = flysim_set_rate(_sim, _sugar);
    s.waterRate  = flysim_set_rate(_sim, _water);
    s.bitterRate = flysim_set_rate(_sim, _bitter);
    s.smellRate  = flysim_set_rate(_sim, _smell);
    s.touchRate  = flysim_set_rate(_sim, _touch);
    s.heatRate   = flysim_set_rate(_sim, _heat);
    s.humidRate  = flysim_set_rate(_sim, _humid);
    s.lightRate  = flysim_set_rate(_sim, _light);
    s.l2Rate     = flysim_set_rate(_sim, _l2);
    s.motorRate  = flysim_set_rate(_sim, _motor);
    s.dnRate     = flysim_set_rate(_sim, _dn);
    s.dnLeftRate = flysim_set_rate(_sim, _dnL);
    s.dnRightRate= flysim_set_rate(_sim, _dnR);
    s.steerLeftRate = flysim_set_rate(_sim, _steerL);
    s.steerRightRate= flysim_set_rate(_sim, _steerR);
    s.escLeftRate   = flysim_set_rate(_sim, _escL);
    s.escRightRate  = flysim_set_rate(_sim, _escR);
    s.lastSpikes = flysim_last_spike_count(_sim);
    s.simTime    = flysim_sim_time(_sim);

    // activity strip bins: mean rate per bin, neurons in processing-stage order
    // (senses at the bottom → central → descending → motor at the top), so the
    // strip reads as information flow, not arbitrary connectome file order.
    (void)rate;
    flysim_ordered_bins(_sim, FS_BINS, s.bins);

    os_unfair_lock_lock(&_lock);
    s.stepsPerSec    = _snap.stepsPerSec;     // preserve perf fields
    s.realtimeFactor = _snap.realtimeFactor;
    _snap = s;
    os_unfair_lock_unlock(&_lock);
}

- (FlySnapshot)snapshot {
    os_unfair_lock_lock(&_lock);
    FlySnapshot s = _snap;
    os_unfair_lock_unlock(&_lock);
    return s;
}

// ---------------------------------------------------------------------------
#pragma mark - MCP surface

- (void)stepK:(int)k {
    if (_runFlag) return;            // deterministic stepping only while paused
    if (k <= 0) k = 1;
    [self _applyClamps];
    flysim_run(_sim, 0.001f, k);
    [self _publish];
}

- (NSDictionary *)regionRates {
    return @{
        @"sugar":   @(flysim_set_rate(_sim, _sugar)),
        @"water":   @(flysim_set_rate(_sim, _water)),
        @"bitter":  @(flysim_set_rate(_sim, _bitter)),
        @"feeding": @(flysim_set_rate(_sim, _l2)),
        @"mn9":     @(flysim_set_rate(_sim, _mn9)),
    };
}

- (NSDictionary *)sensoryRates {     // every input, mean Hz
    return @{
        @"sugar":    @(flysim_set_rate(_sim, _sugar)),
        @"water":    @(flysim_set_rate(_sim, _water)),
        @"bitter":   @(flysim_set_rate(_sim, _bitter)),
        @"smell":    @(flysim_set_rate(_sim, _smell)),
        @"touch":    @(flysim_set_rate(_sim, _touch)),
        @"heat":     @(flysim_set_rate(_sim, _heat)),
        @"humidity": @(flysim_set_rate(_sim, _humid)),
        @"light":    @(flysim_set_rate(_sim, _light)),
    };
}

- (NSDictionary *)motorRates {       // every output, mean Hz
    return @{
        @"mn9":        @(flysim_set_rate(_sim, _mn9)),
        @"feeding":    @(flysim_set_rate(_sim, _l2)),
        @"motor":      @(flysim_set_rate(_sim, _motor)),
        @"descending": @(flysim_set_rate(_sim, _dn)),
    };
}

- (NSDictionary *)populations {      // discovery: name → {clampable, size}
    #define POP(nm,set,clamp) nm: @{@"size":@(flysim_set_size(_sim,set)),@"clampable":@(clamp)}
    return @{
        POP(@"sugar",_sugar,YES),  POP(@"water",_water,YES),  POP(@"bitter",_bitter,YES),
        POP(@"smell",_smell,YES),  POP(@"touch",_touch,YES),  POP(@"heat",_heat,YES),
        POP(@"humidity",_humid,YES), POP(@"light",_light,YES),
        POP(@"feeding",_l2,NO),    POP(@"mn9",_mn9,NO),
        POP(@"motor",_motor,NO),   POP(@"descending",_dn,NO),
    };
    #undef POP
}

- (NSDictionary *)clampKind:(NSString *)kind name:(NSString *)name
                       side:(int)side hz:(float)hz {
    FlySet set = FLYSET_NONE; BOOL ok = NO;
    NSString *k = kind.lowercaseString;
    if ([k isEqualToString:@"modality"]) {
        int m = FSModalityForName(name);
        if (m >= 0) { set = flysim_set_by_modality(_sim, (FlyModality)m, side); ok = YES; }
    } else if ([k isEqualToString:@"superclass"]) {
        int sc = FSSuperclassForName(name);
        if (sc >= 0) { set = flysim_set_by_superclass(_sim, (uint8_t)sc, side); ok = YES; }
    } else if ([k isEqualToString:@"celltype"]) {
        set = flysim_set_by_celltype(_sim, name.UTF8String); ok = YES;
    }
    if (!ok) return @{@"ok":@NO, @"error":@"kind must be modality|superclass|celltype with a known name"};
    uint32_t sz = flysim_set_size(_sim, set);
    if (sz == 0) return @{@"ok":@NO, @"size":@0,
        @"error":[NSString stringWithFormat:@"no neurons matched %@ '%@'", kind, name]};
    flysim_clamp(_sim, set, hz);
    return @{@"ok":@YES, @"kind":kind, @"name":name, @"side":@(side),
             @"hz":@(hz), @"size":@(sz), @"rate":@(flysim_set_rate(_sim, set))};
}

- (NSDictionary *)readKind:(NSString *)kind name:(NSString *)name side:(int)side {
    FlySet set = FLYSET_NONE; BOOL ok = NO;
    NSString *k = kind.lowercaseString;
    if ([k isEqualToString:@"modality"]) {
        int m = FSModalityForName(name);
        if (m >= 0) { set = flysim_set_by_modality(_sim, (FlyModality)m, side); ok = YES; }
    } else if ([k isEqualToString:@"superclass"]) {
        int sc = FSSuperclassForName(name);
        if (sc >= 0) { set = flysim_set_by_superclass(_sim, (uint8_t)sc, side); ok = YES; }
    } else if ([k isEqualToString:@"celltype"]) {
        set = flysim_set_by_celltype(_sim, name.UTF8String); ok = YES;
    }
    if (!ok) return @{@"ok":@NO, @"error":@"kind must be modality|superclass|celltype with a known name"};
    uint32_t sz = flysim_set_size(_sim, set);
    return @{@"ok":@YES, @"kind":kind, @"name":name, @"side":@(side),
             @"size":@(sz), @"rate":@(sz ? flysim_set_rate(_sim, set) : 0)};
}

- (NSDictionary *)telemetry {
    FlySnapshot s = [self snapshot];
    return @{
        @"running":        @(_runFlag),
        @"backend":        self.usingGPU ? @"gpu" : @"cpu",
        @"eventdriven":    @(self.eventDriven),
        @"sim_time_s":     @(s.simTime),
        @"steps_per_sec":  @(s.stepsPerSec),
        @"realtime_factor":@(s.realtimeFactor),
        @"speed_cap":      self.speed <= 0 ? @"max" : @(self.speed),
        @"spikes_last_step":@(s.lastSpikes),
        @"mn9_hz":         @(s.mn9Rate),
        @"regions": @{
            @"sugar":   @(s.sugarRate),
            @"water":   @(s.waterRate),
            @"bitter":  @(s.bitterRate),
            @"feeding": @(s.l2Rate),
            @"mn9":     @(s.mn9Rate),
        },
        @"sensory": @{
            @"sugar":   @(s.sugarRate),  @"water":   @(s.waterRate),
            @"bitter":  @(s.bitterRate), @"smell":   @(s.smellRate),
            @"touch":   @(s.touchRate),  @"heat":    @(s.heatRate),
            @"humidity":@(s.humidRate),  @"light":   @(s.lightRate),
        },
        @"motor": @{
            @"mn9":        @(s.mn9Rate),   @"feeding":    @(s.l2Rate),
            @"motor":      @(s.motorRate), @"descending": @(s.dnRate),
        },
        @"clamp": @{ @"sugar_hz":@(self.sugarHz),  @"water_hz":@(self.waterHz),
                     @"bitter_hz":@(self.bitterHz), @"smell_hz":@(self.smellHz),
                     @"touch_hz":@(self.touchHz),   @"heat_hz":@(self.heatHz),
                     @"humidity_hz":@(self.humidityHz),@"light_hz":@(self.lightHz) },
    };
}

- (NSDictionary *)modelInfo {
    return @{
        @"neurons": @(_neuronCount),
        @"edges":   @(_edgeCount),
        @"sets": @{
            @"sugar_grn":  @(flysim_set_size(_sim, _sugar)),
            @"water_grn":  @(flysim_set_size(_sim, _water)),
            @"bitter_grn": @(flysim_set_size(_sim, _bitter)),
            @"smell_orn":  @(flysim_set_size(_sim, _smell)),
            @"touch":      @(flysim_set_size(_sim, _touch)),
            @"heat":       @(flysim_set_size(_sim, _heat)),
            @"humidity":   @(flysim_set_size(_sim, _humid)),
            @"light_photoreceptor": @(flysim_set_size(_sim, _light)),
            @"feeding":    @(flysim_set_size(_sim, _l2)),
            @"mn9":        @(flysim_set_size(_sim, _mn9)),
            @"motor":      @(flysim_set_size(_sim, _motor)),
            @"descending": @(flysim_set_size(_sim, _dn)),
        },
        @"params": @{
            @"dt_ms":@1, @"v_rest_mv":@(-52), @"v_thresh_mv":@(-45),
            @"v_reset_mv":@(-52), @"t_refrac_ms":@2.2,
            @"tau_syn_ms":@5, @"tau_m_ms":@20, @"w_syn_mv":@0.275 },
    };
}

- (NSArray<NSNumber *> *)_slice:(const void *)buf isFloat:(BOOL)isFloat
                          count:(uint32_t)n from:(NSUInteger)from
                             to:(NSUInteger)to stride:(NSUInteger)stride {
    if (stride == 0) stride = 1;
    if (to == 0 || to > n) to = n;
    if (from >= to) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:(to-from)/stride + 1];
    if (isFloat) { const float *f = buf;
        for (NSUInteger i = from; i < to; i += stride) [out addObject:@(f[i])]; }
    else { const uint8_t *u = buf;
        for (NSUInteger i = from; i < to; i += stride) [out addObject:@(u[i])]; }
    return out;
}

- (NSArray<NSNumber *> *)ratesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride {
    uint32_t n = 0; const float *r = flysim_rate_buffer(_sim, &n);
    return [self _slice:r isFloat:YES count:n from:from to:to stride:stride];
}
- (NSArray<NSNumber *> *)spikesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride {
    uint32_t n = 0; const uint8_t *sp = flysim_spike_buffer(_sim, &n);
    return [self _slice:sp isFloat:NO count:n from:from to:to stride:stride];
}
- (NSArray<NSNumber *> *)bins {
    FlySnapshot s = [self snapshot];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:FS_BINS];
    for (int i = 0; i < FS_BINS; i++) [a addObject:@(s.bins[i])];
    return a;
}

@end
