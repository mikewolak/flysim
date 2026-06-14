# FlySim

A connectome-driven *Drosophila* brain simulator: the FlyWire whole-brain
connectome (139,266 neurons / 16.8M synapses) run as a leaky integrate-and-fire
network on Apple Silicon, with a Logic-Pro-styled Cocoa GUI and a full MCP
control plane. See `FLYSIM_BUILD.md` for the design.

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

## Build & run

```sh
# 1. data (not in git — large). Synthetic:
clang -std=c99 -O2 tools/flypack.c -o build/flypack
build/flypack synth data/flysim.bin
# or the real connectome (needs the FlyWire feather + annotations TSV, see §1):
python3 -m pip install --user pyarrow pandas
python3 tools/convert_flywire.py data/proofread_connections_783.feather \
        data/annotations.tsv data/flysim_real.bin

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
