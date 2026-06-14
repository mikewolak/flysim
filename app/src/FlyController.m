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

    _lock = OS_UNFAIR_LOCK_INIT;
    _neuronCount = flysim_neuron_count(_sim);
    _edgeCount   = flysim_edge_count(_sim);

    _sugar  = flysim_set_by_modality(_sim, MOD_GUSTATORY_SUGAR, -1);
    _water  = flysim_set_by_modality(_sim, MOD_GUSTATORY_WATER, -1);
    _bitter = flysim_set_by_modality(_sim, MOD_GUSTATORY_BITTER, -1);
    _mn9    = flysim_set_by_celltype(_sim, "MN9");
    _l2     = flysim_set_by_celltype(_sim, "feeding_interneuron");

    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    _t2ns = (double)tb.numer / (double)tb.denom;

    memset(&_snap, 0, sizeof(_snap));
    return self;
}

- (void)dealloc {
    [self stop];
    if (_sim) flysim_close(_sim);
}

- (BOOL)usingGPU { return flysim_backend(_sim) == FLYSIM_GPU; }

- (void)setUseGPU:(BOOL)gpu {
    _wantGPU = gpu;
    if (!_runFlag) {
        // safe to switch immediately when the sim thread is idle
        flysim_set_backend(_sim, gpu ? FLYSIM_GPU : FLYSIM_CPU);
        _pendingBackend = 0;
    } else {
        _pendingBackend = 1;   // sim thread applies at the next chunk boundary
    }
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
        _sugar  = flysim_set_by_modality(_sim, MOD_GUSTATORY_SUGAR, -1);
        _water  = flysim_set_by_modality(_sim, MOD_GUSTATORY_WATER, -1);
        _bitter = flysim_set_by_modality(_sim, MOD_GUSTATORY_BITTER, -1);
        _mn9    = flysim_set_by_celltype(_sim, "MN9");
        _l2     = flysim_set_by_celltype(_sim, "feeding_interneuron");
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
    const int    K  = 8;            // steps per chunk (amortizes dispatch — §6.3)

    uint64_t t0 = mach_absolute_time();
    uint64_t stepAcc = 0;
    uint64_t perfT0 = t0;

    while (_runFlag) {
        // apply a pending backend switch on the thread that owns _sim
        if (_pendingBackend) {
            flysim_set_backend(_sim, _wantGPU ? FLYSIM_GPU : FLYSIM_CPU);
            _pendingBackend = 0;
        }
        // apply UI stimulus to the model
        flysim_clamp(_sim, _sugar,  self.sugarHz);
        flysim_clamp(_sim, _water,  self.waterHz);
        flysim_clamp(_sim, _bitter, self.bitterHz);

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
    s.l2Rate     = flysim_set_rate(_sim, _l2);
    s.lastSpikes = flysim_last_spike_count(_sim);
    s.simTime    = flysim_sim_time(_sim);

    // spatial bins: mean rate over contiguous row ranges -> the heat strip
    for (int b = 0; b < FS_BINS; ++b) {
        uint32_t lo = (uint32_t)((uint64_t)b * n / FS_BINS);
        uint32_t hi = (uint32_t)((uint64_t)(b + 1) * n / FS_BINS);
        if (hi <= lo) { s.bins[b] = 0; continue; }
        double sum = 0;
        for (uint32_t j = lo; j < hi; ++j) sum += rate[j];
        s.bins[b] = (float)(sum / (hi - lo));
    }

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
    flysim_clamp(_sim, _sugar,  self.sugarHz);
    flysim_clamp(_sim, _water,  self.waterHz);
    flysim_clamp(_sim, _bitter, self.bitterHz);
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

- (NSDictionary *)telemetry {
    FlySnapshot s = [self snapshot];
    return @{
        @"running":        @(_runFlag),
        @"backend":        self.usingGPU ? @"gpu" : @"cpu",
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
        @"clamp": @{ @"sugar_hz":@(self.sugarHz),
                     @"water_hz":@(self.waterHz),
                     @"bitter_hz":@(self.bitterHz) },
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
            @"feeding":    @(flysim_set_size(_sim, _l2)),
            @"mn9":        @(flysim_set_size(_sim, _mn9)),
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
