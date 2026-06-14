// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlyController.h — Obj-C wrapper around the C LIF core.
//
//  Owns the FlySim*, runs the biological clock on a dedicated sim thread, and
//  publishes a sampled snapshot the UI reads each display frame. This is the
//  §6.1 split: the sim writes shared state; the renderer samples it — the same
//  structure the Metal GPU backend will use (unified memory, zero copy).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define FS_BINS 128   // spatial bins for the population activity strip

// A consistent sample of model state for one UI frame.
typedef struct {
    float    mn9Rate;        // Hz, smoothed
    float    sugarRate;      // mean Hz over sugar GRNs
    float    waterRate;
    float    bitterRate;
    float    l2Rate;         // feeding interneuron stage
    uint32_t lastSpikes;     // spikes in the most recent step
    double   simTime;        // accumulated biological seconds
    double   stepsPerSec;    // measured sim throughput
    double   realtimeFactor; // stepsPerSec * dt  (1.0 == real time)
    float    bins[FS_BINS];  // mean firing rate per spatial bin (the heat strip)
} FlySnapshot;

@interface FlyController : NSObject

@property (readonly) uint32_t neuronCount;
@property (readonly) uint32_t edgeCount;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly) BOOL usingGPU;            // backend actually in use

// Stimulus levels (Hz) set by the UI; read by the sim thread. 0 == released.
@property (atomic) float sugarHz;
@property (atomic) float waterHz;
@property (atomic) float bitterHz;

// Sim speed cap: 1.0 == real time (1000 steps/s @ 1ms tick). <=0 == unthrottled.
@property (atomic) double speed;

// Event-driven scatter (default YES): only spiking neurons contribute. Bit-exact
// vs the dense gather, far faster on the sparse real brain.
@property (nonatomic) BOOL eventDriven;

- (nullable instancetype)initWithBinPath:(NSString *)path;

- (void)start;                 // launch the sim thread
- (void)stop;                  // halt and join
- (void)reset;                 // zero membrane state, release clamps
- (void)setUseGPU:(BOOL)gpu;   // request backend (falls back to CPU if absent)

- (FlySnapshot)snapshot;       // latest published state (thread-safe copy)

// ---- MCP surface: deterministic control + full data access ----------------
- (void)stepK:(int)k;          // advance k 1ms steps (only while paused)
- (NSDictionary *)telemetry;   // every scalar output + bins + region rates
- (NSDictionary *)regionRates; // {sugar,water,bitter,feeding,mn9} Hz
- (NSDictionary *)modelInfo;   // N, E, named sets + sizes, sim params
// per-neuron arrays (sliceable): rows [from,to) by stride. to=0 => full.
- (NSArray<NSNumber *> *)ratesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride;
- (NSArray<NSNumber *> *)spikesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride;
- (NSArray<NSNumber *> *)bins;

@end

NS_ASSUME_NONNULL_END
