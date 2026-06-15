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
    // sensory afferent populations (mean Hz)
    float    sugarRate;      // gustatory sugar/water GRNs
    float    waterRate;
    float    bitterRate;
    float    smellRate;      // olfactory ORNs (antennae)
    float    touchRate;      // mechanosensory
    float    heatRate;       // thermosensory
    float    humidRate;      // hygrosensory
    float    lightRate;      // visual photoreceptors
    // efferent / output populations (mean Hz)
    float    l2Rate;         // feeding interneuron stage
    float    motorRate;      // all motor neurons
    float    dnRate;         // descending neurons (brain → body command lines)
    float    dnLeftRate;     // left  descending (3D flight: steering)
    float    dnRightRate;    // right descending
    float    steerLeftRate;  // left  DNa steering family (clean turn command)
    float    steerRightRate; // right DNa steering family
    float    escLeftRate;    // left  DNp cluster (visual / looming escape)
    float    escRightRate;   // right DNp cluster
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
@property (atomic) float smellHz;    // olfactory (drives the search/walk)
@property (atomic) float touchHz;    // mechanosensory
@property (atomic) float heatHz;     // thermosensory
@property (atomic) float humidityHz;    // hygrosensory
@property (atomic) float lightHz;    // visual photoreceptors
// bilateral olfaction + vision for the 3D flight loop (override symmetric when >0)
@property (atomic) float smellLeftHz;
@property (atomic) float smellRightHz;
@property (atomic) float lightLeftHz;    // left eye photoreceptors
@property (atomic) float lightRightHz;   // right eye photoreceptors

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

// Each sense's peak position along the heat strip (name -> 0..1), for region marks.
@property (readonly) NSDictionary<NSString *, NSNumber *> *sensePeakBins;

// ---- MCP surface: deterministic control + full data access ----------------
- (void)stepK:(int)k;          // advance k 1ms steps (only while paused)
- (NSDictionary *)telemetry;   // every scalar output + bins + region rates
- (NSDictionary *)regionRates; // {sugar,water,bitter,feeding,mn9} Hz
- (NSDictionary *)sensoryRates;// every sensory modality mean Hz (the inputs)
- (NSDictionary *)motorRates;  // mn9 / motor / descending mean Hz (the outputs)
- (NSDictionary *)populations; // named clampable/readable sets + sizes
- (NSDictionary *)modelInfo;   // N, E, named sets + sizes, sim params
// left/right descending-neuron firing (Hz) — the brain's bilateral steering output
- (void)descendingLeft:(float *)l right:(float *)r;
@property (readonly) uint32_t dnLeftSize;
@property (readonly) uint32_t dnRightSize;

// Generic input control: clamp any modality / superclass / cell-type by name to
// a rate (Hz, 0 releases). kind ∈ "modality"|"superclass"|"celltype". Returns
// {ok,size,...} or {ok:false,error}.  Powers the MCP generic panel.
- (NSDictionary *)clampKind:(NSString *)kind name:(NSString *)name
                       side:(int)side hz:(float)hz;
// Read the mean rate of any named set the same way (no clamp).
- (NSDictionary *)readKind:(NSString *)kind name:(NSString *)name side:(int)side;
// per-neuron arrays (sliceable): rows [from,to) by stride. to=0 => full.
- (NSArray<NSNumber *> *)ratesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride;
- (NSArray<NSNumber *> *)spikesFrom:(NSUInteger)from to:(NSUInteger)to stride:(NSUInteger)stride;
- (NSArray<NSNumber *> *)bins;

@end

NS_ASSUME_NONNULL_END
