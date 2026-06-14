// flysim.h — public C API the GUI / render side calls. See FLYSIM_BUILD.md §4.
//
// One init, one step, a couple of clamps, a couple of readouts. The caller
// never touches model internals. Thread-safety: a single FlySim is driven by
// one sim thread; clamps and readouts are plain atomics-free scalar stores that
// are safe to call from another thread for UI purposes (values are advisory).

#ifndef FLYSIM_H
#define FLYSIM_H

#include <stdint.h>
#include "flysim_format.h"   // FlyModality, FlySuperclass enums

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FlySim FlySim;

typedef enum { FLYSIM_CPU = 0, FLYSIM_GPU = 1 } FlyBackend;

// An opaque, resolved set of neuron rows (handle into the model).
typedef uint32_t FlySet;
#define FLYSET_NONE 0xFFFFFFFFu

// ---- lifecycle -------------------------------------------------------------
FlySim* flysim_open(const char* bin_path, FlyBackend backend);
void    flysim_close(FlySim*);

// Model facts (post-open).
uint32_t flysim_neuron_count(const FlySim*);
uint32_t flysim_edge_count(const FlySim*);

// Switch compute backend at runtime. Returns the backend actually active
// (FLYSIM_CPU if Metal isn't available). State is preserved across the switch
// (shared/migrated), so CPU and GPU produce matching trajectories.
FlyBackend flysim_set_backend(FlySim*, FlyBackend);
FlyBackend flysim_backend(const FlySim*);

// GPU kernel selection: 1 = fast warp-per-neuron (default), 0 = bit-exact
// scalar-per-neuron (sums in CPU order; reproduces the CPU result exactly).
void flysim_gpu_fast(FlySim*, int fast);

// ---- set resolution --------------------------------------------------------
// Resolve a named cell type / modality / superclass to a row set. side: -1=both.
FlySet  flysim_set_by_celltype(FlySim*, const char* cell_type);
FlySet  flysim_set_by_modality(FlySim*, FlyModality, int side);
FlySet  flysim_set_by_superclass(FlySim*, uint8_t super_enum, int side);
uint32_t flysim_set_size(const FlySim*, FlySet);

// ---- stimulus (input) ------------------------------------------------------
// Clamp a set of neurons to a target firing rate (Hz). 0 releases the clamp.
void    flysim_clamp(FlySim*, FlySet, float hz);
void    flysim_clamp_modality(FlySim*, FlyModality, float hz);
void    flysim_release_all(FlySim*);

// ---- advance ---------------------------------------------------------------
void    flysim_step(FlySim*, float dt);          // one biological timestep
void    flysim_run(FlySim*, float dt, int k);    // k steps, amortized

// ---- readout (output) ------------------------------------------------------
float        flysim_rate(const FlySim*, uint32_t row);   // smoothed Hz, one neuron
float        flysim_set_rate(const FlySim*, FlySet);     // mean Hz over a set
const float* flysim_rate_buffer(const FlySim*, uint32_t* count_out);
const uint8_t* flysim_spike_buffer(const FlySim*, uint32_t* count_out);

// Convenience for the v0 proboscis reflex.
float   flysim_mn9_rate(const FlySim*);

// Total spikes emitted in the last step (cheap "is the brain alive" meter).
uint32_t flysim_last_spike_count(const FlySim*);
double   flysim_sim_time(const FlySim*);   // accumulated biological seconds

#ifdef __cplusplus
}
#endif
#endif // FLYSIM_H
