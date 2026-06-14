<!-- FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved. -->
<!-- Educational & academic research use only — commercial use prohibited.  See LICENSE. -->
# FlySim

A connectome-driven *Drosophila* brain simulator: the FlyWire whole-brain
connectome (139,266 neurons / 16.8M synapses) run as a leaky integrate-and-fire
network on Apple Silicon, with a Logic-Pro-styled Cocoa GUI and a full MCP
control plane. See `FLYSIM_BUILD.md` for the design.

## Performance — the whole fly brain, faster than life

**3.76× biological real-time** for the entire 139k-neuron / 16.8M-synapse
connectome at a 1 ms tick, on an M1 Pro laptop.

![FlySim throughput](docs/perf.svg)

| config | steps/sec | × real-time | agreement |
|---|--:|--:|---|
| CPU · dense gather (8 threads) | 403 | 0.40× | bit-exact |
| CPU · event-driven | 769 | 0.77× | bit-exact |
| GPU · dense gather (warp) | 461 | 0.46× | bit-exact |
| **GPU · event-driven** | **3,760** | **3.76×** | **bit-exact** |

Real-time = 1,000 steps/s (1 ms tick). The event-driven path scatters only from
the ~2.5 % of neurons that spike each step instead of touching all 16.8M synapses.
Every backend accumulates in Q14 fixed-point integers, so CPU, GPU, gather and
scatter are **bit-for-bit identical** (`max|Δrate| = 0`) — order-independent and
fully reproducible. Regenerate with `build/flycompare data/flysim_real.bin`.

## Layout

- `src/` — the C99 LIF core (`flysim.c`), on-disk format, public API, and the
  Metal GPU backend (`flysim_metal.m`).
- `tools/` — `flypack` (synthetic connectome), `convert_flywire.py` (real data →
  `flysim.bin`), `flydrive` (headless smoke test), `flycompare` (CPU vs GPU
  perf+accuracy → HTML).
- `app/` — `FlySim.app`: Cocoa panel + `FlyController` (sim thread) +
  `FSControlServer` (HTTP/JSON "MCP" surface on 127.0.0.1:7777).

## Backends (all bit-for-bit identical)

The synaptic gather accumulates in **Q14 fixed-point integers**, so results are
independent of thread count / reduction order. CPU (multi-thread), GPU-scalar,
and GPU-warp all produce identical trajectories (`flycompare`: corr 1.000000).

## Getting the real connectome

The dataset is **not** in this repo (≈0.85 GB, and it carries its own license).
One command downloads it and packs `data/flysim_real.bin`:

```sh
./tools/fetch_data.sh
```

That fetches, from their public sources:

| file | what | source |
|---|---|---|
| `proofread_connections_783.feather` (~852 MB) | per-pair edges: `pre, post, syn_count`, NT probabilities | Zenodo [10676866](https://zenodo.org/records/10676866) |
| `Supplemental_file1_neuron_annotations.tsv` (~25 MB) | per-neuron `flow / super_class / cell_class / cell_sub_class / cell_type / nt / side` | [flyconnectome/flywire_annotations](https://github.com/flyconnectome/flywire_annotations) |

then runs `tools/convert_flywire.py` (needs `pyarrow` + `pandas`, auto-installed)
to transpose them into the mmap-ready CSC binary the runtime loads. Sugar/water
GRNs (gustatory `sugar/water`), bitter GRNs, and the proboscis `MN9` readout
(the motor neurons most driven by sugar) are tagged during the pack.

**No download?** A self-contained synthetic connectome reproduces the full
pipeline (sugar → MN9 reflex, all backends) offline:

```sh
clang -std=c99 -O2 tools/flypack.c -o build/flypack && build/flypack synth data/flysim.bin
```

> The FlyWire / FAFB connectome is **not** covered by the FlySim license. It is
> subject to FlyWire's terms; please cite Dorkenwald et al. (Nature 2024) and
> Schlegel et al. (Nature 2024). See `FLYSIM_BUILD.md §1` and `LICENSE §4`.

## Build & run

```sh
# 1. data — real connectome (or `build/flypack synth data/flysim.bin` for synthetic)
./tools/fetch_data.sh

# 2. the app (links Metal)
make -C app run

# 3. headless CPU-vs-GPU report
clang -std=c99 -O2 -c src/flysim.c -o build/flysim_cpu.o
clang -O2 -fobjc-arc -c src/flysim_metal.m -o build/flysim_metal.o
clang -std=c99 -O2 tools/flycompare.c build/flysim_cpu.o build/flysim_metal.o \
      -framework Metal -framework Foundation -lm -o build/flycompare
build/flycompare data/flysim_real.bin 150 200 300 build/flysim_compare.html
```

## MCP

With the app running: `curl 127.0.0.1:7777/tools` lists every control (run/stop/
step/clamp/backend/speed/…) and data endpoint (`/data`, `/data/regions`,
`/data/rates`, …). `curl -N 127.0.0.1:7777/stream?hz=60` watches outputs live.
