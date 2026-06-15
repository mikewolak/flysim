#!/usr/bin/env python3
# FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
# Educational & academic research use only — commercial use prohibited.  See LICENSE.
# convert_flywire.py — FlyWire v783 (feather + annotations TSV) -> flysim.bin
#
# Emits the exact on-disk layout of flysim_format.h (CSC, signs baked) so the
# C runtime mmaps it with zero parsing. Input neurons (sugar/water/bitter GRNs)
# and the proboscis readout ("MN9", computed) are tagged for the flysim_* API.
#
#   python3 convert_flywire.py connections.feather annotations.tsv out.bin

import sys, struct, numpy as np, pandas as pd
import pyarrow.feather as feather

MAGIC, VERSION = 0x53594C46, 1
W_SYN = 0.275

# enums (mirror flysim_format.h)
FLOW = {"intrinsic":0, "afferent":1, "efferent":2}
SC = {"":0,"sensory":1,"motor":2,"descending":3,"ascending":4,"endocrine":5,
      "visual_projection":6,"visual_centrifugal":7,"central":8,"optic":9,
      "sensory_ascending":1}
NT = {"acetylcholine":1,"gaba":2,"glutamate":3,"dopamine":4,"serotonin":5,"octopamine":6}
NT_SIGN = {0:0.0, 1:1.0, 2:-1.0, 3:-1.0, 4:0.0, 5:0.0, 6:0.0}  # ACh +, GABA/Glut -
SIDE = {"left":0,"right":1,"center":2,"":2}
# modality enum (mirror flysim_format.h FlyModality)
MOD_SUGAR, MOD_WATER, MOD_BITTER, MOD_MECHANO = 1,2,3,4
MOD_OLFACTORY, MOD_VISUAL, MOD_THERMO, MOD_HYGRO = 5,6,7,8

def main():
    conn_path, ann_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    print("loading connections feather ...", flush=True)
    ct = feather.read_table(conn_path, columns=["pre_pt_root_id","post_pt_root_id","syn_count"])
    pre = ct.column("pre_pt_root_id").to_numpy()
    post = ct.column("post_pt_root_id").to_numpy()
    syn = ct.column("syn_count").to_numpy().astype(np.float32)
    print(f"  {len(pre):,} edges", flush=True)

    print("loading annotations ...", flush=True)
    ann = pd.read_csv(ann_path, sep="\t", low_memory=False,
                      dtype={"root_id":np.uint64})
    ann = ann.fillna("")

    # universe of neurons = annotated ∪ edge endpoints
    print("building node universe ...", flush=True)
    ids = np.unique(np.concatenate([
        ann["root_id"].to_numpy().astype(np.uint64),
        pre.astype(np.uint64), post.astype(np.uint64)]))
    N = len(ids)
    print(f"  N = {N:,} neurons", flush=True)

    row_of = lambda arr: np.searchsorted(ids, arr.astype(np.uint64))
    pre_row = row_of(pre); post_row = row_of(post)

    # per-neuron tag arrays (defaults)
    nt   = np.zeros(N, np.uint8)
    flow = np.zeros(N, np.uint8)
    sup  = np.zeros(N, np.uint8)
    modd = np.zeros(N, np.uint8)
    side = np.full(N, 2, np.uint8)
    ctype= np.zeros(N, np.uint32)     # strtab offset

    ann_row = row_of(ann["root_id"].to_numpy())

    def nt_enum(known, top):
        s = known if known else top
        return NT.get(str(s).strip().lower(), 0)
    nt[ann_row] = [nt_enum(k,t) for k,t in zip(ann["known_nt"], ann["top_nt"])]
    flow[ann_row] = [FLOW.get(str(f).strip().lower(),0) for f in ann["flow"]]
    sup[ann_row]  = [SC.get(str(s).strip().lower(),0)   for s in ann["super_class"]]
    side[ann_row] = [SIDE.get(str(s).strip().lower(),2) for s in ann["side"]]

    # modality from sensory cell_class / sub-class — the full sensory repertoire
    sub = ann["cell_sub_class"].astype(str).str.lower()
    cls = ann["cell_class"].astype(str).str.lower()
    modv = np.zeros(len(ann), np.uint8)
    # gustatory (taste) — split by sub-class
    modv[(sub=="sugar/water").to_numpy()] = MOD_SUGAR
    modv[(sub=="bitter").to_numpy()]      = MOD_BITTER
    # the rest of each sensory class (only where not already a gustatory subtype)
    modv[((cls=="olfactory")     &(modv==0)).to_numpy()] = MOD_OLFACTORY    # smell
    modv[((cls=="mechanosensory")&(modv==0)).to_numpy()] = MOD_MECHANO      # touch
    modv[((cls=="thermosensory") &(modv==0)).to_numpy()] = MOD_THERMO       # heat
    modv[((cls=="hygrosensory")  &(modv==0)).to_numpy()] = MOD_HYGRO        # humidity
    # vision: the retinal photoreceptors (R1-6/R7/R8 + ocellar) are cell_class
    # "visual" under super_class sensory — the real light input. The ~77k "optic"
    # neurons are downstream interneurons and are left intrinsic.
    modv[((cls=="visual")        &(modv==0)).to_numpy()] = MOD_VISUAL       # light
    modd[ann_row] = modv

    # ---- string table for cell_type (+ "MN9" alias computed below) ----
    raw_ct = ann["cell_type"].astype(str).to_numpy()

    # ---- bake CSC (signed weights) ----
    print("baking CSC ...", flush=True)
    sign = np.array([NT_SIGN[int(x)] for x in range(7)], np.float32)
    w = sign[nt[pre_row]] * W_SYN * syn            # signed weight per edge
    order = np.argsort(post_row, kind="stable")
    indices = pre_row[order].astype(np.uint32)
    weights = w[order].astype(np.float32)
    counts = np.bincount(post_row, minlength=N).astype(np.uint32)
    indptr = np.zeros(N+1, np.uint32); indptr[1:] = np.cumsum(counts)

    # ---- compute the proboscis readout "MN9": motor neurons most driven
    #      (2 hops) by sugar GRNs. Tag them cell_type MN9 for the API. ----
    print("locating proboscis motor readout ...", flush=True)
    sugar_rows = np.where(modd == MOD_SUGAR)[0]
    motor_rows = np.where(sup == SC["motor"])[0]
    drive = np.zeros(N, np.float64)
    sset = np.zeros(N, bool); sset[sugar_rows] = True
    # hop 1: neurons receiving excitatory drive from sugar GRNs
    exc = weights > 0
    m1 = np.zeros(N, np.float64)
    np.add.at(m1, post_row[exc & sset[pre_row]], weights[exc & sset[pre_row]])
    hop1 = m1 > 0
    # hop 2: motor input from hop1 neurons
    sel = exc & hop1[pre_row]
    np.add.at(drive, post_row[sel], weights[sel])
    motor_score = [(r, drive[r]) for r in motor_rows]
    motor_score.sort(key=lambda x: -x[1])
    mn9_rows = [r for r,sc in motor_score[:12] if sc > 0] or list(motor_rows[:12])
    print(f"  MN9 set = {len(mn9_rows)} motor neurons (top sugar-driven)", flush=True)

    # ---- feeding interneurons: the hop-1 premotor stage — neurons excited by
    #      sugar GRNs that in turn drive MN9. These ARE the feeding command
    #      interneurons; bitter GRNs inhibit this stage (the taste veto). ----
    mn9_set = np.zeros(N, bool); mn9_set[mn9_rows] = True
    proj_mn9 = np.zeros(N, np.float64)            # excitatory weight each row sends INTO MN9
    selp = exc & mn9_set[post_row]
    np.add.at(proj_mn9, pre_row[selp], weights[selp])
    fi_score = m1 * proj_mn9                      # excited by sugar  ×  drives MN9
    fi_score[mn9_set] = 0                         # MN9 are motor, not interneurons
    fi_score[sset]    = 0                         # sugar GRNs are sensory, not interneurons
    fi_rows = [int(r) for r in np.argsort(-fi_score)[:40] if fi_score[r] > 0]
    print(f"  feeding interneurons = {len(fi_rows)} (sugar-driven, premotor to MN9)", flush=True)

    # build strtab: unique cell types + computed "MN9" / "feeding_interneuron"
    ct_for_row = np.array(["",]*N, dtype=object)
    ct_for_row[ann_row] = raw_ct
    for r in fi_rows: ct_for_row[r] = "feeding_interneuron"
    for r in mn9_rows: ct_for_row[r] = "MN9"      # MN9 wins any overlap
    strtab = bytearray(b"\x00")           # offset 0 == ""
    off_of = {"":0}
    for r in range(N):
        s = ct_for_row[r]
        if s == "" : ctype[r] = 0; continue
        if s not in off_of:
            off_of[s] = len(strtab)
            strtab += s.encode("utf-8") + b"\x00"
        ctype[r] = off_of[s]

    rootid = ids.astype(np.uint64)
    E = len(indices)

    # ---- write flysim.bin (matches FlysimHeader byte layout) ----
    print("writing bin ...", flush=True)
    HDR = 168
    off = HDR
    o_indptr = off;  off += (N+1)*4
    o_indices= off;  off += E*4
    o_weights= off;  off += E*4
    o_nt     = off;  off += N
    o_flow   = off;  off += N
    o_super  = off;  off += N
    o_mod    = off;  off += N
    o_side   = off;  off += N
    o_root   = off;  off += N*8
    o_ctype  = off;  off += N*4
    o_str    = off;  off += len(strtab)
    file_bytes = off

    hdr = struct.pack("<4I13Q6Q", MAGIC, VERSION, N, E,
        o_indptr,o_indices,o_weights,o_nt,o_flow,o_super,o_mod,o_side,
        o_root,o_ctype,o_str,len(strtab),file_bytes, 0,0,0,0,0,0)
    assert len(hdr) == HDR, len(hdr)

    with open(out_path,"wb") as f:
        f.write(hdr)
        f.write(indptr.tobytes()); f.write(indices.tobytes()); f.write(weights.tobytes())
        f.write(nt.tobytes()); f.write(flow.tobytes()); f.write(sup.tobytes())
        f.write(modd.tobytes()); f.write(side.tobytes())
        f.write(rootid.tobytes()); f.write(ctype.tobytes()); f.write(bytes(strtab))

    print(f"DONE  {out_path}  N={N:,} E={E:,}  ({file_bytes/1e6:.1f} MB)", flush=True)
    print(f"  sensory: sugar/water={int((modd==MOD_SUGAR).sum())} "
          f"bitter={int((modd==MOD_BITTER).sum())} smell={int((modd==MOD_OLFACTORY).sum())} "
          f"touch={int((modd==MOD_MECHANO).sum())} heat={int((modd==MOD_THERMO).sum())} "
          f"humidity={int((modd==MOD_HYGRO).sum())} light={int((modd==MOD_VISUAL).sum())}", flush=True)
    print(f"  motor={int((sup==SC['motor']).sum())} descending={int((sup==SC['descending']).sum())} "
          f"MN9={len(mn9_rows)} feeding_interneuron={len(fi_rows)}", flush=True)

if __name__ == "__main__":
    main()
