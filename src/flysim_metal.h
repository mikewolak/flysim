// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
// flysim_metal.h — C ABI for the optional Metal backend (src/flysim_metal.m).
// Declared weak so binaries that don't link Metal (CLI tools) fall back to CPU:
// take the address of fly_metal_available; NULL means "no GPU backend linked".

#ifndef FLYSIM_METAL_H
#define FLYSIM_METAL_H
#include <stdint.h>

// Fixed-point scale for the synaptic gather. A power of two so int->float
// conversion (val / SCALE) is exact. Integer accumulation is order-independent,
// so CPU, GPU-scalar and GPU-warp produce identical gathers regardless of how
// the threads sum — eliminating the chaotic divergence floats would cause.
#define FLYSIM_FIX_SCALE 16384       /* Q14: ~6e-5 mV resolution */

typedef struct {
    unsigned N;
    float dt, syn_decay, leak_k, rate_k, inv_dt;
    float v_rest, v_reset, v_thresh, t_refrac;
} FlyMetalParams;

#ifdef __cplusplus
extern "C" {
#endif

int   fly_metal_available(void) __attribute__((weak_import));
void* fly_metal_create(uint32_t N, uint32_t E, const uint32_t* indptr,
                       const uint32_t* indices, const int32_t* weights_fixed,
                       const uint32_t* indptr_pre, const uint32_t* post_csr,
                       const int32_t* wfix_csr) __attribute__((weak_import));
void  fly_metal_destroy(void* ctx) __attribute__((weak_import));
void  fly_metal_set_kernel(void* ctx, int warp) __attribute__((weak_import));
void  fly_metal_set_eventdriven(void* ctx, int on) __attribute__((weak_import));
void  fly_metal_upload_state(void* ctx, const float* V, const float* Isyn,
                             const float* refrac, const unsigned char* spike_prev,
                             const float* rate, const float* clamp_phase) __attribute__((weak_import));
void  fly_metal_download_state(void* ctx, float* V, float* Isyn, float* refrac,
                               unsigned char* spike_prev, float* rate,
                               float* clamp_phase) __attribute__((weak_import));
uint32_t fly_metal_run(void* ctx, FlyMetalParams p, int k, const float* clamp_hz,
                       float* rate_out, unsigned char* spike_prev_out) __attribute__((weak_import));

#ifdef __cplusplus
}
#endif
#endif
