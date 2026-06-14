<!-- FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved. -->
<!-- Educational & academic research use only — commercial use prohibited.  See LICENSE. -->
# FlySim — A Connectome-Driven Fruit Fly, C / Objective-C / Metal

A buildable plan for taking the FlyWire whole-brain connectome, running it as a
leaky integrate-and-fire (LIF) network on Apple Silicon, and feeding its motor
outputs into a Metal 3D fly. Validated against Shiu et al. (Nature 2024) so we
have a known-good answer to check the pipeline against before we trust anything.

The strategy is deliberately incremental: get the **proboscis extension reflex**
(sugar in → MN9 out → proboscis lunges) working end to end on CPU, diff it
against Shiu, *then* move the hot loop to the GPU and add behaviors. Resist the
urge to chase walking/flight until v0 proves the signal path — those motor
neurons aren't even in this dataset (see §9).

---

## 0. Architecture at a glance

```
  ┌─────────────────────────────────────────────────────────────────┐
  │  OFFLINE (one-time)                                              │
  │  CSV/Zenodo downloads ──> pack tool ──> flysim.bin (mmap'able)   │
  │  edges + NT signs + flow/superclass tags + id→row map            │
  └─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼  mmap, zero parse at runtime
  ┌─────────────────────────────────────────────────────────────────┐
  │  RUNTIME (per ~1 ms sim tick)                                    │
  │                                                                  │
  │   stimulus  ──clamp──>  [ LIF core: CSC gather matvec ]          │
  │   (sugar GRNs)              V[], spike[]  (N≈140k)               │
  │                                  │                               │
  │                                  ├─ read output rows (MN9, …)    │
  │                                  ▼                               │
  │                          firing-rate EMA per output neuron       │
  └─────────────────────────────────────────────────────────────────┘
                                  │  shared buffer, no copy (unified mem)
                                  ▼  sampled per render frame (60 fps)
  ┌─────────────────────────────────────────────────────────────────┐
  │  RENDER (Metal, your C/Obj-C PBR pipeline)                       │
  │   MN9 rate ──> proboscis joint angle ──> rig ──> draw            │
  │   contact test ──> re-stimulate GRNs (closes the loop)          │
  └─────────────────────────────────────────────────────────────────┘
```

Two clocks: the sim runs at a fixed ~1 ms biological timestep; the renderer runs
at display rate and just samples the latest state. Never lock one sim substep to
one frame.

---

## 1. Model data — exact URLs

Everything below is the **v783** public release (June 2024), the version the
Nature papers describe. You need a (free) FlyWire account for the Codex
downloads; the Zenodo mirror is open.

### 1.1 Primary downloads (start here)

| What | File | Source |
|------|------|--------|
| Connectivity (edge list, no threshold) | `connections_princeton_no_threshold.csv.gz` (~277 MB) | Codex → Info → Download Data: <https://codex.flywire.ai/api/download> |
| Cell types | `consolidated_cell_types.csv.gz` (~0.9 MB) | same Codex download page |
| Synapse + edge data (open mirror) | v783 connectivity bundle | Zenodo: <https://zenodo.org/records/10676866> |
| Codex portal (browse / verify IDs) | — | <https://codex.flywire.ai> |
| Codex download API root | — | <https://codex.flywire.ai/api/download> |

The connections table is the spine: **one row per connected neuron pair**, with
`pre_root_id, post_root_id, neuropil, syn_count, nt_type`. That's your weighted
directed edge list and the per-edge neurotransmitter in one file.

### 1.2 Annotations (flow / superclass / modality — the I/O tags)

| What | Source |
|------|--------|
| Curated annotations repo (`flow`, `super_class`, `cell_type`, `side`, modality) | <https://github.com/flyconnectome/flywire_annotations> |
| Use release **2.1.0** (the version reported in Schlegel et al. 2024, based on 783) | repo releases tab |

This is where `super_class ∈ {sensory, motor, descending, ascending, endocrine,
visual_projection, visual_centrifugal, central, optic}` lives, plus sensory
`modality` (gustatory/mechanosensory/olfactory/visual/…). This is how we select
input and output sets by tag instead of hand-listing IDs.

### 1.3 Validation anchor (reproduce before trusting our port)

| What | Source |
|------|--------|
| Shiu reference model (Brian2/Python, ships processed matrices) | <https://github.com/philshiu/Drosophila_brain_model> |
| Devineni sugar-circuit extension (clean param usage example) | <https://github.com/avdevineni/sugar-circuit> |
| Paper (open): "A Drosophila computational brain model…" Nature 2024 | <https://www.nature.com/articles/s41586-024-07763-9> |

### 1.4 If/when we want full-body (brain + nerve cord) — later, see §9

| What | Source |
|------|--------|
| BANC brain+cord connectome / Male CNS | via FlyWire / Codex (newer datasets) |
| Connectome dataset tutorial (BANC, MANC, Male CNS, FAFB, Hemibrain) | <https://github.com/sjcabs/fly_connectome_data_tutorial> |

---

## 2. The model in one paragraph (so the code makes sense)

Each neuron is a leaky integrator. When a neuron spikes, it nudges the membrane
potential of every downstream neuron by a fixed per-synapse weight times the
number of synapses, with the **sign set by the upstream neuron's
neurotransmitter** (Dale's principle: a neuron is either excitatory or
inhibitory for all its outputs). If a neuron's potential crosses threshold, it
spikes and resets. No biophysics beyond that — no compartments, no plasticity,
no gap junctions, no neuromodulation. That crudeness is the point: it still
predicts real sensorimotor circuits.

### 2.1 Validated default parameters (Shiu et al. — match these exactly first)

```
V_rest    = -52 mV     // resting potential
V_reset   = -52 mV     // post-spike reset
V_thresh  = -45 mV     // spike threshold
t_refrac  =  2.2 ms    // refractory period
tau_syn   =  5.0 ms    // synaptic decay
delay     =  1.8 ms    // spike -> postsynaptic effect
w_syn     =  0.275 mV  // per-synapse weight (multiplied by syn_count)
```

Sign convention (fly-specific — easy to get wrong):
- **acetylcholine → excitatory (+)**
- **GABA → inhibitory (−)**
- **glutamate → inhibitory (−)** in fly (GluCl), NOT excitatory like mammals
- dopamine / serotonin / octopamine → modulatory; crude model treats as ~0.
  Match Shiu's exact handling so diffs are clean.

Stimulus protocol used in the paper: clamp chosen input neurons to a fixed
firing rate for 1 s, read out rates. We'll keep this as the v0 contract.

---

## 3. On-disk format — the pack step

We don't parse CSV at runtime. A one-time `flypack` tool ingests the CSVs and
emits a flat, mmap-friendly binary. This is the same "build a binary blob, mmap
it, start instantly" pattern as ROM/sample packing.

### 3.1 Why CSC (compressed sparse column), not CSR

We index by **postsynaptic** neuron so each output thread *gathers* its own
inputs — no atomic writes, no races (see §6). Column `j` = all in-edges of
neuron `j`.

### 3.2 Binary layout (`flysim.bin`)

```
struct Header {
    uint32 magic;          // 'FLYS'
    uint32 version;        // dataset/pack version
    uint32 N;              // neuron count (rows/cols)
    uint32 E;              // edge count (nonzeros)
    uint64 off_indptr;     // [N+1] uint32  CSC column pointers
    uint64 off_indices;    // [E]   uint32  presynaptic row index per edge
    uint64 off_weights;    // [E]   float32 signed weight = sign(pre)*w_syn*syn_count
    uint64 off_nt;         // [N]   uint8   NT class per neuron (for reference)
    uint64 off_flow;       // [N]   uint8   0=intrinsic 1=afferent 2=efferent
    uint64 off_super;      // [N]   uint8   superclass enum
    uint64 off_modality;   // [N]   uint8   sensory modality enum (0 if n/a)
    uint64 off_side;       // [N]   uint8   0=left 1=right 2=center
    uint64 off_rootid;     // [N]   uint64  original FlyWire root_id (row -> id)
    // id -> row resolved via a sorted (rootid,row) table or a hash built at load
};
```

Membrane state (`V[]`, `spike[]`, `refrac_timer[]`, rate EMA) is allocated at
runtime, not stored. Weights bake in the sign so the hot loop is a plain
multiply-add.

### 3.3 Pack pseudocode

```
load connections csv  -> (pre_id, post_id, syn_count, nt_type) rows
load cell_types/annotations -> per neuron: flow, super_class, modality, side, nt
assign each unique root_id a dense row index 0..N-1
for each edge:
    w = w_syn * syn_count * sign_of(nt_type_of[pre_id])
    bucket into column[post_row]
build CSC indptr/indices/weights
write header + arrays
```

---

## 4. Public C interface (what the Metal/Obj-C side calls)

One init, one step, a couple of clamps, a couple of readouts. The renderer never
touches model internals.

```c
// ---- types ----
typedef struct FlySim FlySim;

typedef enum {
    MOD_NONE = 0,
    MOD_GUSTATORY_SUGAR,
    MOD_GUSTATORY_WATER,
    MOD_GUSTATORY_BITTER,
    MOD_MECHANO_ANTENNA,
    MOD_OLFACTORY,
    MOD_VISUAL,
    // ...
} FlyModality;

typedef enum { FLYSIM_CPU, FLYSIM_GPU } FlyBackend;

// ---- lifecycle ----
FlySim* flysim_open(const char* bin_path, FlyBackend backend);
void    flysim_close(FlySim*);

// resolve a named cell type (e.g. "MN9") or modality to a neuron-row set;
// returns an opaque handle we can clamp or read.
typedef uint32_t FlySet;
FlySet  flysim_set_by_celltype(FlySim*, const char* cell_type);
FlySet  flysim_set_by_modality(FlySim*, FlyModality, int side /*-1=both*/);
FlySet  flysim_set_by_superclass(FlySim*, uint8_t super_enum);

// ---- stimulus (input) ----
// force a set of neurons to fire at a target rate (Hz). 0 to release.
void    flysim_clamp(FlySim*, FlySet, float hz);
void    flysim_clamp_modality(FlySim*, FlyModality, float hz); // convenience

// ---- advance ----
// run one biological timestep (dt seconds, typ. 0.001). Returns nothing;
// state lives in shared buffers.
void    flysim_step(FlySim*, float dt);
// run k steps (keeps GPU dispatch amortized)
void    flysim_run(FlySim*, float dt, int k);

// ---- readout (output) ----
float   flysim_rate(FlySim*, uint32_t row);     // smoothed firing rate, Hz
float   flysim_set_rate(FlySim*, FlySet);       // mean rate over a set
// direct pointer to the shared rate buffer for the renderer to sample
const float* flysim_rate_buffer(FlySim*, uint32_t* count_out);

// convenience for the v0 reflex
float   flysim_mn9_rate(FlySim*);
```

### 4.1 Minimal driver (the whole v0 in spirit)

```c
FlySim* s = flysim_open("flysim.bin", FLYSIM_CPU);
FlySet sugar = flysim_set_by_modality(s, MOD_GUSTATORY_SUGAR, -1);
FlySet mn9   = flysim_set_by_celltype(s, "MN9");

flysim_clamp(s, sugar, 150.0f);          // present sugar
for (int t = 0; t < 1000; ++t)           // 1 s of bio time
    flysim_step(s, 0.001f);

float rate = flysim_set_rate(s, mn9);    // expect robust MN9 firing
printf("MN9 = %.1f Hz\n", rate);         // diff against Shiu
```

---

## 5. CPU backend (v0 — get it correct first)

For the feeding subnetwork (a few thousand active neurons) the CPU is *faster*
than the GPU because kernel-dispatch overhead would dominate. Use this to nail
correctness against Shiu, then keep it as the reference path forever.

### 5.1 Core step (CSC gather, NEON-friendly)

```c
// per timestep
for (uint32 j = 0; j < N; ++j) {
    if (refrac[j] > 0) { refrac[j] -= dt; continue; }

    float isyn = 0.0f;
    uint32 a = indptr[j], b = indptr[j+1];
    for (uint32 e = a; e < b; ++e)
        isyn += weights[e] * spike_prev[indices[e]];   // sign baked in

    // leak + input
    float v = V[j] + dt * ( -(V[j] - V_REST) * inv_tau_m ) + isyn;

    // clamped inputs override integration
    if (clamp_hz[j] > 0.0f) {
        spike[j] = poisson_or_regular_tick(clamp_hz[j], dt);
        v = spike[j] ? V_RESET : v;
    } else {
        spike[j] = (v >= V_THRESH);
        if (spike[j]) { v = V_RESET; refrac[j] = T_REFRAC; }
    }
    V[j] = v;
}
swap(spike, spike_prev);
update_rate_ema(spike_prev, dt);
```

- Use **Accelerate / `SparseMultiply` (BLAS sparse)** for the `isyn` gather if we
  represent the active spike vector as sparse — runs on the AMX coprocessor.
- Or hand-rolled CSR/CSC + NEON intrinsics; both are fine at v0 scale.
- `tau_syn` decay: keep an `Isyn[]` state and decay it (`Isyn *= exp(-dt/tau_syn)`)
  rather than instantaneous injection, to match the paper's α-synapse behavior.

---

## 6. GPU backend (v1 — whole-brain real-time on Apple Silicon)

### 6.1 Why this fits Apple Silicon specifically

**Unified memory**: `V[]`, `spike[]`, and the rate buffer live in one address
space both the compute kernel and the render pass see. The sim writes; the
renderer reads MN9's rate from the same `MTLBuffer` — zero copy, no PCIe round
trip per frame. This is the architectural reason to do it here rather than on a
discrete GPU.

### 6.2 Formulate as GATHER, never scatter

The event-driven "for each spike, scatter to targets" form needs atomic float
add into `V[post]` — and Metal has **no native atomic float add**. Avoid the
whole problem: with CSC, one thread per *postsynaptic* neuron gathers its own
in-edges. Each thread writes only its own `V[j]`/`spike[j]`: embarrassingly
parallel, deterministic, no synchronization.

### 6.3 The kernel (one fused dispatch per timestep)

```metal
kernel void lif_step(
    device const uint*   indptr   [[buffer(0)]],
    device const uint*   indices  [[buffer(1)]],
    device const float*  weights  [[buffer(2)]],
    device const uchar*  spike_in [[buffer(3)]],
    device       uchar*  spike_out[[buffer(4)]],
    device       float*  V        [[buffer(5)]],
    device       float*  refrac   [[buffer(6)]],
    device const float*  clamp_hz [[buffer(7)]],
    constant     Params& P        [[buffer(8)]],
    uint j [[thread_position_in_grid]])
{
    if (j >= P.N) return;

    if (refrac[j] > 0.0f) { refrac[j] -= P.dt; spike_out[j] = 0; return; }

    float isyn = 0.0f;
    uint a = indptr[j], b = indptr[j+1];
    for (uint e = a; e < b; ++e)
        isyn += weights[e] * (float)spike_in[indices[e]];

    float v = V[j] + P.dt * (-(V[j] - P.v_rest) * P.inv_tau_m) + isyn;

    uchar s;
    if (clamp_hz[j] > 0.0f) {
        s = clamp_tick(clamp_hz[j], P.dt, j, P.seed); // regular or Poisson
        v = s ? P.v_reset : v;
    } else {
        s = (v >= P.v_thresh) ? 1 : 0;
        if (s) { v = P.v_reset; refrac[j] = P.t_refrac; }
    }
    V[j] = v;
    spike_out[j] = s;
}
```

- **Bandwidth, not FLOPs, bounds this.** ~15M edges × ~8 B ≈ 120 MB read per
  step; at 200–400 GB/s (M-series Pro/Max/Ultra) that's well under 1 ms →
  faster than real time for the *whole* brain at 1 ms ticks.
- Double-buffer `spike_in`/`spike_out`; swap bindings each tick.
- Rate EMA: a tiny second kernel or fold into the same dispatch.
- **Load imbalance** by in-degree is the only wrinkle (some neurons have far
  more in-edges). Mild at this scale — don't fix until measured. If needed,
  switch to thread-per-edge + segmented reduction.
- `flysim_run(s, dt, k)` to amortize dispatch: run k ticks before handing back
  to the render loop.

### 6.4 If we ever want true event-driven (sparse active set)

Use the scatter form with **fixed-point accumulation in `atomic_int`** (Q16.16
into `Isyn`), which sidesteps the no-float-atomic problem and is deterministic.
Only worth it if the active fraction is tiny. Start with gather.

---

## 7. Stimuli we process in the feedback loop

Inputs we can clamp (afferent / sensory superclasses), with what each is for:

| Stimulus | Neuron set (tag) | Drives | v0? |
|----------|------------------|--------|-----|
| **Sugar** (appetitive taste) | gustatory GRNs, sugar modality | proboscis extension (MN9 etc.) | ✅ primary |
| **Water** | gustatory GRNs, water modality | proboscis extension (shares ~250 neurons w/ sugar) | ✅ |
| **Bitter** (aversive) | gustatory GRNs, bitter modality | suppresses/overrides sugar response | v1 |
| **Ir94e taste** | gustatory GRNs, Ir94e | modulatory taste | v1 |
| **Antennal mechanosensation** | mechanosensory, antenna | antennal grooming circuit | v1 |
| **Olfaction** | olfactory receptor neuron terminals | higher-order; no direct motor in brain | later |
| **Vision** | photoreceptors / visual projection neurons | optic → central; needs cord for motor | later |

The two facts that make sugar the right v0: its motor target (MN9) is **in the
brain dataset**, and Shiu validated the exact sugar→MN9 response so we can diff.

### 7.1 Stimulus generation

- **Regular** clamp: emit a spike every `1/hz` seconds per clamped neuron
  (deterministic, easiest to diff).
- **Poisson** clamp: per neuron per tick, spike with prob `hz*dt` (more
  biological). Keep a per-neuron RNG (counter-based, e.g. philox) so GPU and CPU
  match bit-for-bit.
- Paper protocol: clamp for 1 s, then read. Our loop will instead clamp
  continuously and let the renderer modulate `hz` from the world state (§8.2).

---

## 8. Input/output mapping and the feedback loop

### 8.1 Output neurons → 3D rig

Outputs are efferent superclasses. For v0 we read motor neurons whose targets
are head structures (the only motor neurons in this dataset):

| Output neuron(s) | Superclass | 3D rig target | Mapping |
|------------------|-----------|---------------|---------|
| **MN9** (+ MNs 6, 8, 11) | motor | proboscis extensor joint | rate → extension angle |
| Antennal grooming MNs | motor | foreleg sweep over antenna | rate → sweep amplitude/phase (v1) |
| Descending neurons (1,276) | descending | *hand off at neck* — body motion needs cord dataset (§9) | — |

Rate→angle mapping (smooth, debiologized for animation):

```c
// MN9 rate (Hz) -> proboscis extension in [0,1] -> joint angle
float r   = flysim_mn9_rate(s);                 // smoothed
float ext = clampf((r - R_LO) / (R_HI - R_LO), 0.f, 1.f);  // e.g. R_LO~5, R_HI~60
// critically-damped follow so the mesh doesn't twitch on spike noise
proboscis_angle = damp(proboscis_angle, ext * MAX_EXT_ANGLE, k_damp, dt);
rig_set_joint(PROBOSCIS, proboscis_angle);
```

Decouple cadences: the sim EMA already smooths; the render-side critically-damped
follow gives clean motion at 60 fps regardless of the 1 ms sim tick.

### 8.2 The feedback loop (closing it)

```
   world state (sugar drop on labellum?)
        │  yes → set sugar clamp hz ∝ contact strength
        ▼
   flysim_clamp_modality(s, MOD_GUSTATORY_SUGAR, hz)
        │
   flysim_run(s, 0.001, k)        // advance sim
        │
   r = flysim_mn9_rate(s)         // read output
        │
   proboscis_angle = map(r)       // drive rig
        │
   render frame; test proboscis tip vs sugar drop
        │
   contact? → consume drop, raise/lower next-tick sugar hz   ← feedback
        └──────────────────────────────────────────────────┘
```

Two honest kinds of feedback:
- **Sensorimotor closure (real):** proboscis reaching the sugar changes the
  contact, which changes the GRN clamp next tick. This is legitimate — the loop
  goes through the world, exactly like the fly.
- **What we are NOT claiming:** internal learning/adaptation. There's no
  plasticity in the model, so repeated trials won't "train" anything. The loop is
  reflexive, not adaptive. Say so plainly.

### 8.3 Per-frame glue (render thread)

```c
// each display frame
float strength = world_sugar_contact(&proboscis_tip); // 0..1
flysim_clamp_modality(s, MOD_GUSTATORY_SUGAR, strength * SUGAR_MAX_HZ);

int substeps = (int)(frame_dt / SIM_DT);   // e.g. 16 ticks for 60fps @1ms
flysim_run(s, SIM_DT, substeps);

float r = flysim_mn9_rate(s);
drive_proboscis(r, frame_dt);              // §8.1 mapping
render_fly();
```

---

## 9. Scope, limits, and the wall (read before over-reaching)

- **v0 (days):** sugar → MN9 → proboscis, open loop, CPU. Diff vs Shiu. *Works.*
- **v1 (weeks):** water + bitter (suppression), antennal grooming
  (mechanosensory → foreleg), closed sensorimotor loop, GPU backend, rigged head.
- **The wall — full body (walking/flight/escape):** the leg and wing motor
  neurons are **not in the FAFB brain connectome**. The brain's output to the
  body is the ~1,276 descending neurons, which terminate at the neck connective.
  To reach a leg muscle you need **BANC / Male CNS** (brain+cord) *and* a
  biomechanical body with ground contact and physics. That's an open research
  problem, not a wiring problem. Don't let v0 success bait us straight into it.

Other honest limits baked into the crude model: no real synaptic weights (only
synapse counts as proxy), no plasticity/learning, no neuromodulation, no gap
junctions, identical biophysics per neuron, single static individual's wiring.
It predicts *which neurons light up and which outputs fire* from a stimulus —
and does that well — not a fully autonomous virtual animal.

---

## 10. Build order (checklist)

1. **Download** v783 connections + cell types + annotations (§1).
2. **Write `flypack`** → emit `flysim.bin` (CSC, signs baked) (§3).
3. **CPU LIF core** with Shiu's exact params (§2.1, §5). 1 s sugar clamp.
4. **Validate**: reproduce sugar-GRN → MN9 firing; diff against Shiu repo.
   *Gate: do not proceed until this matches.*
5. **C interface** `flysim_*` (§4); minimal driver prints MN9 Hz.
6. **Wire to Metal**: MN9 rate → proboscis joint; static sugar drop in scene.
7. **Close the loop**: contact test re-stimulates GRNs (§8.2).
8. **GPU backend**: CSC gather kernel, unified-memory shared buffers (§6).
   Diff GPU vs CPU output bit-for-bit (regular clamp) before trusting it.
9. **v1 behaviors**: water/bitter, antennal grooming, rigged head.
10. (Optional, much later) BANC brain+cord for body motion.

---

## 11. Key references

- Shiu et al., *A Drosophila computational brain model reveals sensorimotor
  processing*, Nature 2024 — <https://www.nature.com/articles/s41586-024-07763-9>
- Model code — <https://github.com/philshiu/Drosophila_brain_model>
- Dorkenwald et al., *Neuronal wiring diagram of an adult brain*, Nature 2024
  — <https://www.nature.com/articles/s41586-024-07558-y>
- Schlegel et al., *Whole-brain annotation…*, Nature 2024
  — <https://www.nature.com/articles/s41586-024-07686-5>
- Connectivity data (Zenodo v783) — <https://zenodo.org/records/10676866>
- Codex — <https://codex.flywire.ai>
- Annotations — <https://github.com/flyconnectome/flywire_annotations>
