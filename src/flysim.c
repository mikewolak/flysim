// flysim.c — CPU LIF backend + flysim_* API. C99. See FLYSIM_BUILD.md §5.
//
// mmap the packed connectome (read-only, zero parse), allocate membrane state,
// and advance a leaky integrate-and-fire network by CSC gather: one pass per
// postsynaptic neuron that sums its own in-edges. No scatter, no atomics, no
// races — deterministic and trivially correct as the reference path.

#include "flysim.h"
#include "flysim_metal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <dispatch/dispatch.h>

// ---- validated default parameters (Shiu et al.) — FLYSIM_BUILD.md §2.1 ------
// V in millivolts, time in seconds.
#define V_REST    (-52.0f)
#define V_RESET   (-52.0f)
#define V_THRESH  (-45.0f)
#define T_REFRAC  (2.2e-3f)
#define TAU_SYN   (5.0e-3f)   // synaptic decay
#define TAU_M     (20.0e-3f)  // membrane time constant (Shiu LIF; calibrate @ §10.4)
#define TAU_RATE  (50.0e-3f)  // firing-rate EMA window for readout

struct FlySim {
    FlyBackend backend;
    void*      mtl;          // Metal context (NULL until GPU first selected)
    int        gpu_active;   // 1 => steps run on the GPU

    // mmap'd file (read-only)
    void*       map;
    size_t      map_bytes;
    FlysimHeader hdr;

    uint32_t    N, E;

    // pointers into the mmap (do not free)
    const uint32_t* indptr;     // [N+1]
    const uint32_t* indices;    // [E]
    const float*    weights;    // [E] sign baked
    int32_t*        wfix;       // [E] weights in Q14 fixed-point (deterministic gather)

    // CSR-by-presynaptic (transpose of CSC) for event-driven scatter. Built at
    // load; no on-disk change. Lets a step touch only edges OUT of neurons that
    // actually spiked (~1.4% active) instead of every in-edge of every neuron.
    uint32_t*       indptr_pre; // [N+1] out-edge ranges per presynaptic neuron
    uint32_t*       post_csr;   // [E]   postsynaptic target per out-edge
    int32_t*        wfix_csr;   // [E]   Q14 weight per out-edge
    int32_t*        isyn_in;    // [N]   per-step integer accumulator (scatter target)
    int             eventdriven;// 1 => scatter from active set; 0 => dense gather
    const uint8_t*  nt;         // [N]
    const uint8_t*  flow;       // [N]
    const uint8_t*  super;      // [N]
    const uint8_t*  modality;   // [N]
    const uint8_t*  side;       // [N]
    const uint64_t* rootid;     // [N]
    const uint32_t* celltype;   // [N] -> strtab offset
    const char*     strtab;     // NUL-separated

    // runtime membrane state (allocated, not stored)
    float*   V;          // [N] membrane potential, mV
    float*   Isyn;       // [N] decaying synaptic drive, mV
    float*   refrac;     // [N] remaining refractory time, s
    uint8_t* spike;      // [N] spiked this step
    uint8_t* spike_prev; // [N] spiked previous step (gather source)
    float*   rate;       // [N] smoothed firing rate, Hz
    float*   clamp_hz;   // [N] >0 => clamp to this rate
    float*   clamp_phase;// [N] per-neuron regular-clamp phase accumulator

    // resolved sets
    struct { uint32_t* rows; uint32_t count; } *sets;
    uint32_t set_count, set_cap;

    uint32_t mn9_set;          // cached MN9 set (or FLYSET_NONE)
    uint32_t last_spikes;
    double   sim_time;
};

// ---------------------------------------------------------------------------
// open / close
// ---------------------------------------------------------------------------

static const void* at(const struct FlySim* s, uint64_t off) {
    return (const uint8_t*)s->map + off;
}

FlySim* flysim_open(const char* bin_path, FlyBackend backend) {
    int fd = open(bin_path, O_RDONLY);
    if (fd < 0) { perror("flysim_open: open"); return NULL; }

    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); return NULL; }

    void* map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { perror("mmap"); return NULL; }

    const FlysimHeader* h = (const FlysimHeader*)map;
    if (h->magic != FLYSIM_MAGIC) {
        fprintf(stderr, "flysim_open: bad magic 0x%08x\n", h->magic);
        munmap(map, st.st_size); return NULL;
    }
    if (h->version != FLYSIM_VERSION)
        fprintf(stderr, "flysim_open: version %u (expected %u), continuing\n",
                h->version, FLYSIM_VERSION);

    FlySim* s = calloc(1, sizeof(*s));
    s->backend   = backend;
    s->map       = map;
    s->map_bytes = (size_t)st.st_size;
    s->hdr       = *h;
    s->N = h->N; s->E = h->E;

    s->indptr   = at(s, h->off_indptr);
    s->indices  = at(s, h->off_indices);
    s->weights  = at(s, h->off_weights);
    s->nt       = at(s, h->off_nt);
    s->flow     = at(s, h->off_flow);
    s->super    = at(s, h->off_super);
    s->modality = at(s, h->off_modality);
    s->side     = at(s, h->off_side);
    s->rootid   = at(s, h->off_rootid);
    s->celltype = at(s, h->off_celltype);
    s->strtab   = at(s, h->off_strtab);

    uint32_t N = s->N;
    s->V          = malloc(N * sizeof(float));
    s->Isyn       = calloc(N, sizeof(float));
    s->refrac     = calloc(N, sizeof(float));
    s->spike      = calloc(N, sizeof(uint8_t));
    s->spike_prev = calloc(N, sizeof(uint8_t));
    s->rate       = calloc(N, sizeof(float));
    s->clamp_hz   = calloc(N, sizeof(float));
    s->clamp_phase= calloc(N, sizeof(float));
    for (uint32_t j = 0; j < N; ++j) s->V[j] = V_REST;

    // precompute Q14 fixed-point weights for the order-independent gather
    s->wfix = malloc((size_t)s->E * sizeof(int32_t));
    for (uint32_t e = 0; e < s->E; ++e)
        s->wfix[e] = (int32_t)lroundf(s->weights[e] * (float)FLYSIM_FIX_SCALE);

    // transpose CSC -> CSR (by presynaptic) for the event-driven scatter path
    {
        uint32_t Nn = s->N, Ee = s->E;
        s->indptr_pre = calloc((size_t)Nn + 1, sizeof(uint32_t));
        s->post_csr   = malloc((size_t)(Ee ? Ee : 1) * sizeof(uint32_t));
        s->wfix_csr   = malloc((size_t)(Ee ? Ee : 1) * sizeof(int32_t));
        s->isyn_in    = calloc(Nn, sizeof(int32_t));
        // out-degree per presynaptic neuron (= indices[e] across all columns)
        for (uint32_t e = 0; e < Ee; ++e) s->indptr_pre[s->indices[e] + 1]++;
        for (uint32_t i = 0; i < Nn; ++i) s->indptr_pre[i + 1] += s->indptr_pre[i];
        uint32_t* cur = malloc((size_t)Nn * sizeof(uint32_t));
        memcpy(cur, s->indptr_pre, (size_t)Nn * sizeof(uint32_t));
        // walk CSC columns: edge e in column j goes pre=indices[e] -> post=j
        for (uint32_t j = 0; j < Nn; ++j)
            for (uint32_t e = s->indptr[j]; e < s->indptr[j + 1]; ++e) {
                uint32_t pre = s->indices[e];
                uint32_t pos = cur[pre]++;
                s->post_csr[pos] = j;
                s->wfix_csr[pos] = s->wfix[e];
            }
        free(cur);
    }

    s->mn9_set = FLYSET_NONE;
    s->backend = FLYSIM_CPU;

    fprintf(stderr, "flysim_open: N=%u E=%u (%.1f MB mmap)\n",
            s->N, s->E, s->map_bytes / 1e6);

    if (backend == FLYSIM_GPU) flysim_set_backend(s, FLYSIM_GPU);
    return s;
}

// build the GPU param block from the runtime constants for this dt
static FlyMetalParams gpu_params(const FlySim* s, float dt) {
    (void)s;
    FlyMetalParams p;
    p.N = s->N; p.dt = dt;
    p.syn_decay = expf(-dt / TAU_SYN);
    p.leak_k    = dt / TAU_M;
    p.rate_k    = dt / TAU_RATE;
    p.inv_dt    = 1.0f / dt;
    p.v_rest = V_REST; p.v_reset = V_RESET;
    p.v_thresh = V_THRESH; p.t_refrac = T_REFRAC;
    return p;
}

FlyBackend flysim_backend(const FlySim* s) {
    return s->gpu_active ? FLYSIM_GPU : FLYSIM_CPU;
}

void flysim_gpu_fast(FlySim* s, int fast) {
    if (s->mtl && &fly_metal_set_kernel) fly_metal_set_kernel(s->mtl, fast);
}

FlyBackend flysim_set_backend(FlySim* s, FlyBackend want) {
    if (want == FLYSIM_GPU && !s->gpu_active) {
        if (&fly_metal_available == 0 || !fly_metal_available()) {
            fprintf(stderr, "flysim: GPU backend unavailable; staying on CPU\n");
            return FLYSIM_CPU;
        }
        if (!s->mtl) {
            s->mtl = fly_metal_create(s->N, s->E, s->indptr, s->indices, s->wfix);
            if (!s->mtl) { fprintf(stderr, "flysim: Metal init failed\n"); return FLYSIM_CPU; }
        }
        // migrate current CPU state up to the GPU
        fly_metal_upload_state(s->mtl, s->V, s->Isyn, s->refrac,
                               s->spike_prev, s->rate, s->clamp_phase);
        s->gpu_active = 1;
        fprintf(stderr, "flysim: backend -> GPU\n");
    } else if (want == FLYSIM_CPU && s->gpu_active) {
        // migrate state back down so the CPU path continues seamlessly
        fly_metal_download_state(s->mtl, s->V, s->Isyn, s->refrac,
                                 s->spike_prev, s->rate, s->clamp_phase);
        s->gpu_active = 0;
        fprintf(stderr, "flysim: backend -> CPU\n");
    }
    return flysim_backend(s);
}

void flysim_close(FlySim* s) {
    if (!s) return;
    for (uint32_t i = 0; i < s->set_count; ++i) free(s->sets[i].rows);
    free(s->sets);
    free(s->V); free(s->Isyn); free(s->refrac);
    free(s->spike); free(s->spike_prev); free(s->rate);
    free(s->clamp_hz); free(s->clamp_phase); free(s->wfix);
    free(s->indptr_pre); free(s->post_csr); free(s->wfix_csr); free(s->isyn_in);
    if (s->mtl && &fly_metal_destroy) fly_metal_destroy(s->mtl);
    if (s->map) munmap(s->map, s->map_bytes);
    free(s);
}

uint32_t flysim_neuron_count(const FlySim* s) { return s->N; }
uint32_t flysim_edge_count(const FlySim* s)   { return s->E; }

// ---------------------------------------------------------------------------
// set resolution
// ---------------------------------------------------------------------------

static FlySet push_set(FlySim* s, uint32_t* rows, uint32_t count) {
    if (s->set_count == s->set_cap) {
        s->set_cap = s->set_cap ? s->set_cap * 2 : 8;
        s->sets = realloc(s->sets, s->set_cap * sizeof(*s->sets));
    }
    s->sets[s->set_count].rows  = rows;
    s->sets[s->set_count].count = count;
    return s->set_count++;
}

// collect rows where predicate(s, j, arg) is true; side<0 disables side filter.
typedef int (*row_pred)(const FlySim*, uint32_t, int64_t);

static FlySet collect(FlySim* s, row_pred pred, int64_t arg, int side) {
    uint32_t cap = 64, count = 0;
    uint32_t* rows = malloc(cap * sizeof(uint32_t));
    for (uint32_t j = 0; j < s->N; ++j) {
        if (!pred(s, j, arg)) continue;
        if (side >= 0 && s->side[j] != (uint8_t)side) continue;
        if (count == cap) { cap *= 2; rows = realloc(rows, cap * sizeof(uint32_t)); }
        rows[count++] = j;
    }
    rows = realloc(rows, (count ? count : 1) * sizeof(uint32_t));
    return push_set(s, rows, count);
}

static int pred_modality(const FlySim* s, uint32_t j, int64_t m) {
    return s->modality[j] == (uint8_t)m;
}
static int pred_super(const FlySim* s, uint32_t j, int64_t sc) {
    return s->super[j] == (uint8_t)sc;
}
static int pred_celltype(const FlySim* s, uint32_t j, int64_t name_ptr) {
    const char* want = (const char*)(intptr_t)name_ptr;
    const char* have = s->strtab + s->celltype[j];
    return strcmp(have, want) == 0;
}

FlySet flysim_set_by_modality(FlySim* s, FlyModality m, int side) {
    return collect(s, pred_modality, (int64_t)m, side);
}
FlySet flysim_set_by_superclass(FlySim* s, uint8_t sc, int side) {
    return collect(s, pred_super, (int64_t)sc, side);
}
FlySet flysim_set_by_celltype(FlySim* s, const char* cell_type) {
    return collect(s, pred_celltype, (int64_t)(intptr_t)cell_type, -1);
}

uint32_t flysim_set_size(const FlySim* s, FlySet set) {
    if (set >= s->set_count) return 0;
    return s->sets[set].count;
}

// ---------------------------------------------------------------------------
// stimulus
// ---------------------------------------------------------------------------

void flysim_clamp(FlySim* s, FlySet set, float hz) {
    if (set >= s->set_count) return;
    const uint32_t* rows = s->sets[set].rows;
    for (uint32_t i = 0; i < s->sets[set].count; ++i) {
        uint32_t j = rows[i];
        s->clamp_hz[j] = hz;
        if (hz <= 0.0f) s->clamp_phase[j] = 0.0f;
    }
}

void flysim_clamp_modality(FlySim* s, FlyModality m, float hz) {
    for (uint32_t j = 0; j < s->N; ++j)
        if (s->modality[j] == (uint8_t)m) {
            s->clamp_hz[j] = hz;
            if (hz <= 0.0f) s->clamp_phase[j] = 0.0f;
        }
}

void flysim_release_all(FlySim* s) {
    memset(s->clamp_hz,    0, s->N * sizeof(float));
    memset(s->clamp_phase, 0, s->N * sizeof(float));
}

// ---------------------------------------------------------------------------
// the hot loop — CSC gather LIF step (FLYSIM_BUILD.md §5.1)
// ---------------------------------------------------------------------------

// Process neuron rows [lo,hi) for one timestep. Each row writes only its own
// state and reads the shared (read-only) spike_prev, so disjoint ranges run in
// parallel with no races. Returns the spike count for the range.
static uint32_t step_range(FlySim* s, uint32_t lo, uint32_t hi, float dt,
                           float syn_decay, float leak_k, float rate_k, float inv_dt) {
    const uint32_t* indptr  = s->indptr;
    const uint32_t* indices = s->indices;
    const int32_t*  wfix    = s->wfix;
    const uint8_t*  sprev   = s->spike_prev;
    uint32_t spikes = 0;

    for (uint32_t j = lo; j < hi; ++j) {
        // integer (order-independent) gather, then exact /2^14 back to mV
        int64_t acc = 0;
        const uint32_t a = indptr[j], b = indptr[j + 1];
        for (uint32_t e = a; e < b; ++e)
            acc += (int64_t)wfix[e] * sprev[indices[e]];
        float gathered = (float)acc / (float)FLYSIM_FIX_SCALE;

        float isyn = s->Isyn[j] * syn_decay + gathered;
        s->Isyn[j] = isyn;

        uint8_t fired = 0;
        if (s->refrac[j] > 0.0f) {
            s->refrac[j] -= dt;
        } else if (s->clamp_hz[j] > 0.0f) {
            float ph = s->clamp_phase[j] + s->clamp_hz[j] * dt;
            if (ph >= 1.0f) { ph -= 1.0f; fired = 1; s->V[j] = V_RESET; }
            s->clamp_phase[j] = ph;
        } else {
            float v = s->V[j] + leak_k * (V_REST - s->V[j]) + isyn;
            if (v >= V_THRESH) { fired = 1; v = V_RESET; s->refrac[j] = T_REFRAC; }
            s->V[j] = v;
        }
        s->spike[j] = fired;
        spikes += fired;

        float inst = fired ? inv_dt : 0.0f;
        s->rate[j] += (inst - s->rate[j]) * rate_k;
    }
    return spikes;
}

// Membrane update for neuron rows [lo,hi) reading a precomputed integer gather
// in isyn_in[] (the event-driven scatter target). Same arithmetic as step_range
// minus the gather, so it produces bit-identical results.
static uint32_t update_range(FlySim* s, uint32_t lo, uint32_t hi, float dt,
                             float syn_decay, float leak_k, float rate_k, float inv_dt) {
    const int32_t* isyn_in = s->isyn_in;
    uint32_t spikes = 0;
    for (uint32_t j = lo; j < hi; ++j) {
        float gathered = (float)isyn_in[j] / (float)FLYSIM_FIX_SCALE;
        float isyn = s->Isyn[j] * syn_decay + gathered;
        s->Isyn[j] = isyn;

        uint8_t fired = 0;
        if (s->refrac[j] > 0.0f) {
            s->refrac[j] -= dt;
        } else if (s->clamp_hz[j] > 0.0f) {
            float ph = s->clamp_phase[j] + s->clamp_hz[j] * dt;
            if (ph >= 1.0f) { ph -= 1.0f; fired = 1; s->V[j] = V_RESET; }
            s->clamp_phase[j] = ph;
        } else {
            float v = s->V[j] + leak_k * (V_REST - s->V[j]) + isyn;
            if (v >= V_THRESH) { fired = 1; v = V_RESET; s->refrac[j] = T_REFRAC; }
            s->V[j] = v;
        }
        s->spike[j] = fired;
        spikes += fired;
        float inst = fired ? inv_dt : 0.0f;
        s->rate[j] += (inst - s->rate[j]) * rate_k;
    }
    return spikes;
}

// active CPU count (cached)
static uint32_t cpu_threads(void) {
    static uint32_t n = 0;
    if (!n) { int v = 8; size_t sz = sizeof(v);
              if (sysctlbyname("hw.activecpu", &v, &sz, NULL, 0) != 0) v = 8;
              n = v < 1 ? 1 : (uint32_t)v; }
    return n;
}

typedef uint32_t (*range_fn)(FlySim*, uint32_t, uint32_t, float, float, float, float, float);

// Run a per-neuron range function across all cores (serial below threshold).
static uint32_t run_parallel(FlySim* s, range_fn fn, float dt,
                             float syn_decay, float leak_k, float rate_k, float inv_dt) {
    const uint32_t N = s->N;
    if (N < 16384) return fn(s, 0, N, dt, syn_decay, leak_k, rate_k, inv_dt);

    uint32_t NCH = cpu_threads() * 2; if (NCH > 64) NCH = 64;
    uint32_t parr[64]; uint32_t* pp = parr;
    dispatch_apply(NCH, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        ^(size_t c) {
            uint32_t lo = (uint32_t)((uint64_t)c * N / NCH);
            uint32_t hi = (uint32_t)((uint64_t)(c + 1) * N / NCH);
            pp[c] = fn(s, lo, hi, dt, syn_decay, leak_k, rate_k, inv_dt);
        });
    uint32_t spikes = 0;
    for (uint32_t c = 0; c < NCH; ++c) spikes += parr[c];
    return spikes;
}

void flysim_step(FlySim* s, float dt) {
    if (s->gpu_active) {
        FlyMetalParams p = gpu_params(s, dt);
        s->last_spikes = fly_metal_run(s->mtl, p, 1, s->clamp_hz, s->rate, s->spike_prev);
        s->sim_time += dt;
        return;
    }

    const uint32_t N = s->N;
    const float syn_decay = expf(-dt / TAU_SYN);
    const float leak_k    = dt / TAU_M;
    const float rate_k    = dt / TAU_RATE;
    const float inv_dt    = 1.0f / dt;

    uint32_t spikes;
    if (s->eventdriven) {
        // scatter: only neurons that spiked last step contribute. Integer adds,
        // so the result is identical to the dense gather regardless of order.
        memset(s->isyn_in, 0, (size_t)N * sizeof(int32_t));
        const uint8_t* sprev = s->spike_prev;
        for (uint32_t i = 0; i < N; ++i) {
            if (!sprev[i]) continue;
            const uint32_t a = s->indptr_pre[i], b = s->indptr_pre[i + 1];
            for (uint32_t e = a; e < b; ++e)
                s->isyn_in[s->post_csr[e]] += s->wfix_csr[e];
        }
        spikes = run_parallel(s, update_range, dt, syn_decay, leak_k, rate_k, inv_dt);
    } else {
        spikes = run_parallel(s, step_range, dt, syn_decay, leak_k, rate_k, inv_dt);
    }

    // swap spike buffers (this step's spikes drive next step's gather)
    uint8_t* tmp = s->spike_prev; s->spike_prev = s->spike; s->spike = tmp;

    s->last_spikes = spikes;
    s->sim_time += dt;
}

void flysim_set_eventdriven(FlySim* s, int on) { s->eventdriven = on ? 1 : 0; }
int  flysim_eventdriven(const FlySim* s) { return s->eventdriven; }

void flysim_run(FlySim* s, float dt, int k) {
    if (s->gpu_active) {                 // one batched dispatch — amortize §6.3
        FlyMetalParams p = gpu_params(s, dt);
        s->last_spikes = fly_metal_run(s->mtl, p, k, s->clamp_hz, s->rate, s->spike_prev);
        s->sim_time += (double)k * dt;
        return;
    }
    for (int i = 0; i < k; ++i) flysim_step(s, dt);
}

// ---------------------------------------------------------------------------
// readout
// ---------------------------------------------------------------------------

float flysim_rate(const FlySim* s, uint32_t row) {
    return row < s->N ? s->rate[row] : 0.0f;
}

float flysim_set_rate(const FlySim* s, FlySet set) {
    if (set >= s->set_count || s->sets[set].count == 0) return 0.0f;
    const uint32_t* rows = s->sets[set].rows;
    double sum = 0.0;
    for (uint32_t i = 0; i < s->sets[set].count; ++i) sum += s->rate[rows[i]];
    return (float)(sum / s->sets[set].count);
}

const float* flysim_rate_buffer(const FlySim* s, uint32_t* count_out) {
    if (count_out) *count_out = s->N;
    return s->rate;
}

const uint8_t* flysim_spike_buffer(const FlySim* s, uint32_t* count_out) {
    if (count_out) *count_out = s->N;
    return s->spike_prev;   // last completed step lives in spike_prev after swap
}

float flysim_mn9_rate(const FlySim* s) {
    FlySim* m = (FlySim*)s;   // lazily resolve+cache MN9 set
    if (m->mn9_set == FLYSET_NONE)
        m->mn9_set = flysim_set_by_celltype(m, "MN9");
    return flysim_set_rate(s, m->mn9_set);
}

uint32_t flysim_last_spike_count(const FlySim* s) { return s->last_spikes; }
double   flysim_sim_time(const FlySim* s)         { return s->sim_time; }
