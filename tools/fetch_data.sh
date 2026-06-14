#!/usr/bin/env bash
# FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
# Educational & academic research use only — commercial use prohibited.  See LICENSE.
#
# fetch_data.sh — download the FlyWire v783 connectome + annotations and pack
# them into data/flysim_real.bin (the file the app/tools load).
#
# Downloads ~0.85 GB. The data is NOT covered by the FlySim license; it is
# FlyWire / FAFB and carries its own terms + citation requirements (see below).
#
#   ./tools/fetch_data.sh

set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data

# Connectivity: per-pair edge list (pre, post, syn_count, NT probabilities).
# Open Zenodo mirror of the v783 release used by the Nature 2024 papers.
ZENODO="https://zenodo.org/records/10676866/files/proofread_connections_783.feather?download=1"
# Per-neuron annotations: flow / super_class / cell_class / cell_sub_class /
# cell_type / nt / side (Schlegel et al. 2024).
ANNOT="https://raw.githubusercontent.com/flyconnectome/flywire_annotations/main/supplemental_files/Supplemental_file1_neuron_annotations.tsv"

echo "==> [1/3] connections feather (~852 MB, resumable)"
curl -L --fail --retry 3 -C - \
     -o data/proofread_connections_783.feather "$ZENODO"

echo "==> [2/3] annotations TSV (~25 MB)"
curl -L --fail --retry 3 -o data/annotations.tsv "$ANNOT"

echo "==> [3/3] packing -> data/flysim_real.bin"
python3 -c "import pyarrow, pandas" 2>/dev/null || \
    python3 -m pip install --user --quiet pyarrow pandas
python3 tools/convert_flywire.py \
        data/proofread_connections_783.feather \
        data/annotations.tsv \
        data/flysim_real.bin

echo
echo "done: data/flysim_real.bin  (139,266 neurons / 16.8M synapses)"
echo "the app and tools prefer this file automatically; 'make -C app run' to launch."
echo
echo "Please cite FlyWire when using the connectome:"
echo "  Dorkenwald et al., Nature 2024 (neuronal wiring diagram of an adult brain)"
echo "  Schlegel et al., Nature 2024 (whole-brain annotation)"
