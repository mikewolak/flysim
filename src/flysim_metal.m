// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  flysim_metal.m — Metal GPU backend for the LIF core (FLYSIM_BUILD.md §6).
//
//  One fused dispatch per timestep: one thread per POSTsynaptic neuron gathers
//  its own in-edges from the CSC arrays (no scatter, no float atomics, no
//  races). State lives in shared (unified-memory) MTLBuffers — the same memory
//  the CPU path would touch, so switching backends needs no data migration and
//  the two backends produce identical results (same per-thread gather order).
//
//  Exposes a small C ABI consumed by flysim.c via weak symbols, so the CLI
//  tools (which don't link Metal) fall back to CPU automatically.

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include "flysim_metal.h"

static NSString *kSrc = @R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Params {
    uint  N;
    float dt, syn_decay, leak_k, rate_k, inv_dt;
    float v_rest, v_reset, v_thresh, t_refrac;
};
kernel void lif_step(
    device const uint*  indptr      [[buffer(0)]],
    device const uint*  indices     [[buffer(1)]],
    device const int*   weights     [[buffer(2)]],
    device const uchar* spike_in    [[buffer(3)]],
    device       uchar* spike_out   [[buffer(4)]],
    device       float* V           [[buffer(5)]],
    device       float* Isyn        [[buffer(6)]],
    device       float* refrac      [[buffer(7)]],
    device const float* clamp_hz    [[buffer(8)]],
    device       float* clamp_phase [[buffer(9)]],
    device       float* rate        [[buffer(10)]],
    device atomic_uint* spkcount    [[buffer(11)]],
    constant Params&    P           [[buffer(12)]],
    uint j [[thread_position_in_grid]])
{
    if (j >= P.N) return;

    int acc = 0;                                  // integer gather (order-free)
    uint a = indptr[j], b = indptr[j+1];
    for (uint e = a; e < b; ++e)
        acc += weights[e] * (int)spike_in[indices[e]];
    float gathered = (float)acc * (1.0f / 16384.0f);

    float isyn = Isyn[j] * P.syn_decay + gathered;
    Isyn[j] = isyn;

    uchar fired = 0;
    if (refrac[j] > 0.0f) {
        refrac[j] -= P.dt;
    } else if (clamp_hz[j] > 0.0f) {
        float ph = clamp_phase[j] + clamp_hz[j] * P.dt;
        if (ph >= 1.0f) { ph -= 1.0f; fired = 1; V[j] = P.v_reset; }
        clamp_phase[j] = ph;
    } else {
        float v = V[j] + P.leak_k * (P.v_rest - V[j]) + isyn;
        if (v >= P.v_thresh) { fired = 1; v = P.v_reset; refrac[j] = P.t_refrac; }
        V[j] = v;
    }
    spike_out[j] = fired;
    if (fired) atomic_fetch_add_explicit(spkcount, 1u, memory_order_relaxed);

    float inst = fired ? P.inv_dt : 0.0f;
    rate[j] += (inst - rate[j]) * P.rate_k;
}

// Warp-per-neuron: one SIMD-group (32 lanes on Apple GPUs) cooperatively sums
// each row's in-edges. This balances the in-degree skew (all 32 lanes share a
// hub neuron's work) and coalesces the indices/weights reads. simd_sum runs on
// the whole simdgroup, so every lane reaches it (all 32 lanes share the same j).
kernel void lif_step_warp(
    device const uint*  indptr      [[buffer(0)]],
    device const uint*  indices     [[buffer(1)]],
    device const int*   weights     [[buffer(2)]],
    device const uchar* spike_in    [[buffer(3)]],
    device       uchar* spike_out   [[buffer(4)]],
    device       float* V           [[buffer(5)]],
    device       float* Isyn        [[buffer(6)]],
    device       float* refrac      [[buffer(7)]],
    device const float* clamp_hz    [[buffer(8)]],
    device       float* clamp_phase [[buffer(9)]],
    device       float* rate        [[buffer(10)]],
    device atomic_uint* spkcount    [[buffer(11)]],
    constant Params&    P           [[buffer(12)]],
    uint gid  [[thread_position_in_grid]],
    uint lane [[thread_index_in_simdgroup]])
{
    uint j = gid / 32u;
    if (j >= P.N) return;

    // integer partials reduced by simd_sum: integer addition is associative, so
    // this equals the sequential CPU sum exactly — order/thread-count free.
    uint a = indptr[j], b = indptr[j+1];
    int partial = 0;
    for (uint e = a + lane; e < b; e += 32u)
        partial += weights[e] * (int)spike_in[indices[e]];
    int total = simd_sum(partial);
    float gathered = (float)total * (1.0f / 16384.0f);
    if (lane != 0u) return;

    float isyn = Isyn[j] * P.syn_decay + gathered;
    Isyn[j] = isyn;

    uchar fired = 0;
    if (refrac[j] > 0.0f) {
        refrac[j] -= P.dt;
    } else if (clamp_hz[j] > 0.0f) {
        float ph = clamp_phase[j] + clamp_hz[j] * P.dt;
        if (ph >= 1.0f) { ph -= 1.0f; fired = 1; V[j] = P.v_reset; }
        clamp_phase[j] = ph;
    } else {
        float v = V[j] + P.leak_k * (P.v_rest - V[j]) + isyn;
        if (v >= P.v_thresh) { fired = 1; v = P.v_reset; refrac[j] = P.t_refrac; }
        V[j] = v;
    }
    spike_out[j] = fired;
    if (fired) atomic_fetch_add_explicit(spkcount, 1u, memory_order_relaxed);
    float inst = fired ? P.inv_dt : 0.0f;
    rate[j] += (inst - rate[j]) * P.rate_k;
}

// ===== event-driven (scatter) path: 3 kernels per step =====================
// Only neurons that spiked contribute, so work tracks the ~2-3% active set
// instead of all 16.8M edges. Atomic INTEGER accumulation -> order-independent,
// bit-identical to the dense gather.

kernel void ev_clear(device int* isyn_in [[buffer(0)]],
                     constant uint& N [[buffer(1)]],
                     uint j [[thread_position_in_grid]]) {
    if (j < N) isyn_in[j] = 0;
}

// warp-per-neuron: a whole simdgroup handles one (spiking) neuron's out-edges
kernel void ev_scatter(
    device const uint*   indptr_pre [[buffer(0)]],
    device const uint*   post_csr   [[buffer(1)]],
    device const int*    wfix_csr   [[buffer(2)]],
    device const uchar*  spike_in   [[buffer(3)]],
    device atomic_int*   isyn_in    [[buffer(4)]],
    constant uint&       N          [[buffer(5)]],
    uint gid  [[thread_position_in_grid]],
    uint lane [[thread_index_in_simdgroup]])
{
    uint i = gid / 32u;
    if (i >= N) return;
    if (spike_in[i] == 0) return;            // uniform across the 32 lanes
    uint a = indptr_pre[i], b = indptr_pre[i+1];
    for (uint e = a + lane; e < b; e += 32u)
        atomic_fetch_add_explicit(&isyn_in[post_csr[e]], wfix_csr[e], memory_order_relaxed);
}

// thread-per-neuron membrane update reading the scattered integer drive
kernel void ev_update(
    device const int*   isyn_in     [[buffer(0)]],
    device       uchar* spike_out   [[buffer(1)]],
    device       float* V           [[buffer(2)]],
    device       float* Isyn        [[buffer(3)]],
    device       float* refrac      [[buffer(4)]],
    device const float* clamp_hz    [[buffer(5)]],
    device       float* clamp_phase [[buffer(6)]],
    device       float* rate        [[buffer(7)]],
    device atomic_uint* spkcount    [[buffer(8)]],
    constant Params&    P           [[buffer(9)]],
    uint j [[thread_position_in_grid]])
{
    if (j >= P.N) return;
    float gathered = (float)isyn_in[j] * (1.0f / 16384.0f);
    float isyn = Isyn[j] * P.syn_decay + gathered;
    Isyn[j] = isyn;

    uchar fired = 0;
    if (refrac[j] > 0.0f) {
        refrac[j] -= P.dt;
    } else if (clamp_hz[j] > 0.0f) {
        float ph = clamp_phase[j] + clamp_hz[j] * P.dt;
        if (ph >= 1.0f) { ph -= 1.0f; fired = 1; V[j] = P.v_reset; }
        clamp_phase[j] = ph;
    } else {
        float v = V[j] + P.leak_k * (P.v_rest - V[j]) + isyn;
        if (v >= P.v_thresh) { fired = 1; v = P.v_reset; refrac[j] = P.t_refrac; }
        V[j] = v;
    }
    spike_out[j] = fired;
    if (fired) atomic_fetch_add_explicit(spkcount, 1u, memory_order_relaxed);
    float inst = fired ? P.inv_dt : 0.0f;
    rate[j] += (inst - rate[j]) * P.rate_k;
}
)METAL";

typedef struct {
    id<MTLDevice>               dev;
    id<MTLCommandQueue>         queue;
    id<MTLComputePipelineState> pso_scalar;  // 1 thread/neuron — bit-exact vs CPU
    id<MTLComputePipelineState> pso_warp;    // 32 lanes/neuron — fast
    id<MTLComputePipelineState> pso_clear, pso_scatter, pso_update;  // event-driven
    int use_warp;
    int use_event;
    uint32_t N, E;
    // CSC (uploaded once)
    id<MTLBuffer> indptr, indices, weights;
    // CSR-by-presynaptic + scatter target (event-driven path)
    id<MTLBuffer> indptr_pre, post_csr, wfix_csr, isyn_in;
    // state (shared, persistent on GPU between steps)
    id<MTLBuffer> V, Isyn, refrac, clamp_hz, clamp_phase, rate;
    id<MTLBuffer> spikeA, spikeB;   // double-buffered; `prevIsA` tracks current
    id<MTLBuffer> spkcount;
    int prevIsA;
} FlyMetal;

int fly_metal_available(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return d != nil;
}

void* fly_metal_create(uint32_t N, uint32_t E,
                       const uint32_t* indptr, const uint32_t* indices,
                       const int32_t* weights_fixed,
                       const uint32_t* indptr_pre, const uint32_t* post_csr,
                       const int32_t* wfix_csr) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return NULL;

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSrc options:nil error:&err];
        if (!lib) { NSLog(@"[metal] lib: %@", err); return NULL; }
        #define PSO(nm) [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:nm] error:&err]
        id<MTLComputePipelineState> psoS = PSO(@"lif_step");
        id<MTLComputePipelineState> psoW = PSO(@"lif_step_warp");
        id<MTLComputePipelineState> psoC = PSO(@"ev_clear");
        id<MTLComputePipelineState> psoSc= PSO(@"ev_scatter");
        id<MTLComputePipelineState> psoU = PSO(@"ev_update");
        #undef PSO
        if (!psoS || !psoW || !psoC || !psoSc || !psoU) { NSLog(@"[metal] pso: %@", err); return NULL; }

        FlyMetal *m = calloc(1, sizeof(FlyMetal));
        m->dev = dev; m->queue = [dev newCommandQueue];
        m->pso_scalar = psoS; m->pso_warp = psoW; m->use_warp = 1;
        m->pso_clear = psoC; m->pso_scatter = psoSc; m->pso_update = psoU;
        m->N = N; m->E = E; m->prevIsA = 1;

        MTLResourceOptions sh = MTLResourceStorageModeShared;
        m->indptr  = [dev newBufferWithBytes:indptr length:(N+1)*sizeof(uint32_t) options:sh];
        m->indices = [dev newBufferWithBytes:indices length:(size_t)E*sizeof(uint32_t) options:sh];
        m->weights = [dev newBufferWithBytes:weights_fixed length:(size_t)E*sizeof(int32_t) options:sh];
        m->indptr_pre = [dev newBufferWithBytes:indptr_pre length:(N+1)*sizeof(uint32_t) options:sh];
        m->post_csr   = [dev newBufferWithBytes:post_csr length:(size_t)E*sizeof(uint32_t) options:sh];
        m->wfix_csr   = [dev newBufferWithBytes:wfix_csr length:(size_t)E*sizeof(int32_t) options:sh];
        m->isyn_in    = [dev newBufferWithLength:N*sizeof(int32_t) options:sh];
        m->V          = [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->Isyn       = [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->refrac     = [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->clamp_hz   = [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->clamp_phase= [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->rate       = [dev newBufferWithLength:N*sizeof(float) options:sh];
        m->spikeA     = [dev newBufferWithLength:N options:sh];
        m->spikeB     = [dev newBufferWithLength:N options:sh];
        m->spkcount   = [dev newBufferWithLength:sizeof(uint32_t) options:sh];
        return m;
    }
}

void fly_metal_destroy(void* ctx) { if (ctx) free(ctx); }

// 1 => fast warp-per-neuron kernel; 0 => bit-exact scalar-per-neuron kernel.
void fly_metal_set_kernel(void* ctx, int warp) { ((FlyMetal*)ctx)->use_warp = warp; }
// 1 => event-driven scatter path; 0 => dense gather path.
void fly_metal_set_eventdriven(void* ctx, int on) { ((FlyMetal*)ctx)->use_event = on; }

// Push the current CPU state up before switching to GPU.
void fly_metal_upload_state(void* ctx,
        const float* V, const float* Isyn, const float* refrac,
        const unsigned char* spike_prev, const float* rate,
        const float* clamp_phase) {
    FlyMetal *m = ctx; uint32_t N = m->N;
    memcpy(m->V.contents, V, N*sizeof(float));
    memcpy(m->Isyn.contents, Isyn, N*sizeof(float));
    memcpy(m->refrac.contents, refrac, N*sizeof(float));
    memcpy(m->rate.contents, rate, N*sizeof(float));
    memcpy(m->clamp_phase.contents, clamp_phase, N*sizeof(float));
    m->prevIsA = 1;
    memcpy(m->spikeA.contents, spike_prev, N);
    memset(m->spikeB.contents, 0, N);
}

// Pull state back down (e.g. when switching to CPU).
void fly_metal_download_state(void* ctx,
        float* V, float* Isyn, float* refrac,
        unsigned char* spike_prev, float* rate, float* clamp_phase) {
    FlyMetal *m = ctx; uint32_t N = m->N;
    memcpy(V, m->V.contents, N*sizeof(float));
    memcpy(Isyn, m->Isyn.contents, N*sizeof(float));
    memcpy(refrac, m->refrac.contents, N*sizeof(float));
    memcpy(rate, m->rate.contents, N*sizeof(float));
    memcpy(clamp_phase, m->clamp_phase.contents, N*sizeof(float));
    id<MTLBuffer> prev = m->prevIsA ? m->spikeA : m->spikeB;
    memcpy(spike_prev, prev.contents, N);
}

// Run k steps on the GPU. Refreshes clamp_hz from the CPU array each call,
// then downloads rate + spike_prev for readout. Returns spikes in the final step.
uint32_t fly_metal_run(void* ctx, FlyMetalParams p, int k,
                       const float* clamp_hz, float* rate_out,
                       unsigned char* spike_prev_out) {
    @autoreleasepool {
        FlyMetal *m = ctx; uint32_t N = m->N;
        memcpy(m->clamp_hz.contents, clamp_hz, N*sizeof(float));

        id<MTLCommandBuffer> cb = [m->queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

        const MTLSize tg   = MTLSizeMake(256, 1, 1);
        const MTLSize gN   = MTLSizeMake((NSUInteger)N, 1, 1);
        const MTLSize gN32 = MTLSizeMake((NSUInteger)N * 32, 1, 1);
        uint32_t Nu = N;

        for (int i = 0; i < k; ++i) {
            *(uint32_t*)m->spkcount.contents = 0;   // last step's count survives
            id<MTLBuffer> in  = m->prevIsA ? m->spikeA : m->spikeB;
            id<MTLBuffer> out = m->prevIsA ? m->spikeB : m->spikeA;

            if (m->use_event) {
                // 1) clear scatter target
                [enc setComputePipelineState:m->pso_clear];
                [enc setBuffer:m->isyn_in offset:0 atIndex:0];
                [enc setBytes:&Nu length:sizeof(Nu) atIndex:1];
                [enc dispatchThreads:gN threadsPerThreadgroup:tg];
                [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
                // 2) scatter from spiking neurons (atomic integer adds)
                [enc setComputePipelineState:m->pso_scatter];
                [enc setBuffer:m->indptr_pre offset:0 atIndex:0];
                [enc setBuffer:m->post_csr   offset:0 atIndex:1];
                [enc setBuffer:m->wfix_csr   offset:0 atIndex:2];
                [enc setBuffer:in            offset:0 atIndex:3];
                [enc setBuffer:m->isyn_in    offset:0 atIndex:4];
                [enc setBytes:&Nu length:sizeof(Nu) atIndex:5];
                [enc dispatchThreads:gN32 threadsPerThreadgroup:tg];
                [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
                // 3) membrane update (one thread per neuron)
                [enc setComputePipelineState:m->pso_update];
                [enc setBuffer:m->isyn_in    offset:0 atIndex:0];
                [enc setBuffer:out           offset:0 atIndex:1];
                [enc setBuffer:m->V          offset:0 atIndex:2];
                [enc setBuffer:m->Isyn       offset:0 atIndex:3];
                [enc setBuffer:m->refrac     offset:0 atIndex:4];
                [enc setBuffer:m->clamp_hz   offset:0 atIndex:5];
                [enc setBuffer:m->clamp_phase offset:0 atIndex:6];
                [enc setBuffer:m->rate       offset:0 atIndex:7];
                [enc setBuffer:m->spkcount   offset:0 atIndex:8];
                [enc setBytes:&p length:sizeof(p) atIndex:9];
                [enc dispatchThreads:gN threadsPerThreadgroup:tg];
                [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
            } else {
                // dense gather: warp (32 lanes/neuron) or scalar (1 thread/neuron)
                [enc setComputePipelineState:(m->use_warp ? m->pso_warp : m->pso_scalar)];
                [enc setBuffer:m->indptr      offset:0 atIndex:0];
                [enc setBuffer:m->indices     offset:0 atIndex:1];
                [enc setBuffer:m->weights     offset:0 atIndex:2];
                [enc setBuffer:in             offset:0 atIndex:3];
                [enc setBuffer:out            offset:0 atIndex:4];
                [enc setBuffer:m->V           offset:0 atIndex:5];
                [enc setBuffer:m->Isyn        offset:0 atIndex:6];
                [enc setBuffer:m->refrac      offset:0 atIndex:7];
                [enc setBuffer:m->clamp_hz    offset:0 atIndex:8];
                [enc setBuffer:m->clamp_phase offset:0 atIndex:9];
                [enc setBuffer:m->rate        offset:0 atIndex:10];
                [enc setBuffer:m->spkcount    offset:0 atIndex:11];
                [enc setBytes:&p length:sizeof(p) atIndex:12];
                [enc dispatchThreads:(m->use_warp ? gN32 : gN) threadsPerThreadgroup:tg];
                [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
            }
            m->prevIsA = !m->prevIsA;   // out becomes next step's prev
        }
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (rate_out) memcpy(rate_out, m->rate.contents, N*sizeof(float));
        if (spike_prev_out) {
            id<MTLBuffer> prev = m->prevIsA ? m->spikeA : m->spikeB;
            memcpy(spike_prev_out, prev.contents, N);
        }
        return *(uint32_t*)m->spkcount.contents;
    }
}
