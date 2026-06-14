// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
// flypack.c — pack a connectome into flysim.bin (CSC, signs baked). C99.
// See FLYSIM_BUILD.md §3.
//
//   flypack synth  <out.bin>                 emit a synthetic sugar->MN9 brain
//   flypack pack   <nodes.csv> <edges.csv> <out.bin>   pack real FlyWire data
//
// nodes.csv: row,root_id,flow,super,modality,side,nt,cell_type   (header line)
// edges.csv: pre_row,post_row,syn_count,pre_nt                    (header line)
// (the python converter emits these from the FlyWire feather + annotations)

#include "../src/flysim_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W_SYN 0.275f   // per-synapse weight, mV (Shiu) — §2.1

// ---------------------------------------------------------------------------
// In-memory connectome being assembled
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t N, E;
    // per-neuron tags
    uint64_t* rootid;
    uint8_t  *flow, *super, *modality, *side, *nt;
    uint32_t* celltype_off;   // offset into strtab
    // string table
    char*    strtab; uint32_t strtab_len, strtab_cap;
    // edges (coordinate form)
    uint32_t* pre; uint32_t* post; uint32_t* syn; uint32_t ecap;
} Conn;

static void conn_init(Conn* c, uint32_t N) {
    memset(c, 0, sizeof(*c));
    c->N = N;
    c->rootid       = calloc(N, sizeof(uint64_t));
    c->flow         = calloc(N, 1);
    c->super        = calloc(N, 1);
    c->modality     = calloc(N, 1);
    c->side         = calloc(N, 1);
    c->nt           = calloc(N, 1);
    c->celltype_off = calloc(N, sizeof(uint32_t));
    c->strtab_cap = 1024; c->strtab = malloc(c->strtab_cap);
    c->strtab[0] = '\0'; c->strtab_len = 1;   // offset 0 == empty string
    c->ecap = 1024;
    c->pre = malloc(c->ecap * sizeof(uint32_t));
    c->post= malloc(c->ecap * sizeof(uint32_t));
    c->syn = malloc(c->ecap * sizeof(uint32_t));
}

// intern a cell-type string, returning its strtab offset (dedups exact repeats
// only against the most recent — fine for our small label set).
static uint32_t intern(Conn* c, const char* s) {
    if (!s || !*s) return 0;
    size_t n = strlen(s) + 1;
    if (c->strtab_len + n > c->strtab_cap) {
        while (c->strtab_len + n > c->strtab_cap) c->strtab_cap *= 2;
        c->strtab = realloc(c->strtab, c->strtab_cap);
    }
    uint32_t off = c->strtab_len;
    memcpy(c->strtab + off, s, n);
    c->strtab_len += n;
    return off;
}

static void add_edge(Conn* c, uint32_t pre, uint32_t post, uint32_t syn) {
    if (c->E == c->ecap) {
        c->ecap *= 2;
        c->pre = realloc(c->pre,  c->ecap * sizeof(uint32_t));
        c->post= realloc(c->post, c->ecap * sizeof(uint32_t));
        c->syn = realloc(c->syn,  c->ecap * sizeof(uint32_t));
    }
    c->pre[c->E] = pre; c->post[c->E] = post; c->syn[c->E] = syn; c->E++;
}

// ---------------------------------------------------------------------------
// CSC build + write
// ---------------------------------------------------------------------------
static int write_bin(const Conn* c, const char* path) {
    const uint32_t N = c->N, E = c->E;

    // CSC by postsynaptic column
    uint32_t* indptr  = calloc(N + 1, sizeof(uint32_t));
    uint32_t* indices = malloc((E ? E : 1) * sizeof(uint32_t));
    float*    weights = malloc((E ? E : 1) * sizeof(float));

    for (uint32_t e = 0; e < E; ++e) indptr[c->post[e] + 1]++;
    for (uint32_t j = 0; j < N; ++j) indptr[j + 1] += indptr[j];

    uint32_t* cursor = malloc(N * sizeof(uint32_t));
    memcpy(cursor, indptr, N * sizeof(uint32_t));
    for (uint32_t e = 0; e < E; ++e) {
        uint32_t pre = c->pre[e], post = c->post[e];
        uint32_t pos = cursor[post]++;
        indices[pos] = pre;
        weights[pos] = flysim_nt_sign(c->nt[pre]) * W_SYN * (float)c->syn[e];
    }
    free(cursor);

    // layout: header, then arrays in declared order
    FlysimHeader h; memset(&h, 0, sizeof(h));
    h.magic = FLYSIM_MAGIC; h.version = FLYSIM_VERSION; h.N = N; h.E = E;

    uint64_t off = sizeof(FlysimHeader);
    h.off_indptr   = off; off += (uint64_t)(N + 1) * sizeof(uint32_t);
    h.off_indices  = off; off += (uint64_t)E * sizeof(uint32_t);
    h.off_weights  = off; off += (uint64_t)E * sizeof(float);
    h.off_nt       = off; off += N;
    h.off_flow     = off; off += N;
    h.off_super    = off; off += N;
    h.off_modality = off; off += N;
    h.off_side     = off; off += N;
    h.off_rootid   = off; off += (uint64_t)N * sizeof(uint64_t);
    h.off_celltype = off; off += (uint64_t)N * sizeof(uint32_t);
    h.off_strtab   = off; off += c->strtab_len;
    h.strtab_bytes = c->strtab_len;
    h.file_bytes   = off;

    FILE* f = fopen(path, "wb");
    if (!f) { perror("fopen"); return 1; }
    fwrite(&h, sizeof(h), 1, f);
    fwrite(indptr,  sizeof(uint32_t), N + 1, f);
    fwrite(indices, sizeof(uint32_t), E,     f);
    fwrite(weights, sizeof(float),    E,     f);
    fwrite(c->nt,       1, N, f);
    fwrite(c->flow,     1, N, f);
    fwrite(c->super,    1, N, f);
    fwrite(c->modality, 1, N, f);
    fwrite(c->side,     1, N, f);
    fwrite(c->rootid,       sizeof(uint64_t), N, f);
    fwrite(c->celltype_off, sizeof(uint32_t), N, f);
    fwrite(c->strtab, 1, c->strtab_len, f);
    fclose(f);

    free(indptr); free(indices); free(weights);
    fprintf(stderr, "flypack: wrote %s  N=%u E=%u  (%.2f MB)\n",
            path, N, E, off / 1e6);
    return 0;
}

// ---------------------------------------------------------------------------
// synthetic connectome — a feed-forward sugar/water -> MN9 reflex, plus a
// bitter -> inhibitory path that suppresses it, plus random background.
// Deterministic (seeded), so runs are reproducible and diffable.
// ---------------------------------------------------------------------------
static uint64_t rng_state = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void) {                 // xorshift64*
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return (uint32_t)((rng_state * 0x2545F4914F6CDD1Dull) >> 32);
}
static uint32_t rnd_mod(uint32_t n) { return rnd() % n; }

static int cmd_synth(const char* out) {
    // layer sizes
    enum { N_SUGAR=60, N_WATER=40, N_BITTER=40,
           N_L1=400, N_L2=300, N_INH=120, N_MN9=12, N_BG=4000 };
    const uint32_t N = N_SUGAR+N_WATER+N_BITTER+N_L1+N_L2+N_INH+N_MN9+N_BG;

    Conn c; conn_init(&c, N);

    // assign contiguous row ranges
    uint32_t off = 0;
    uint32_t SUGAR=off; off+=N_SUGAR;
    uint32_t WATER=off; off+=N_WATER;
    uint32_t BITTER=off;off+=N_BITTER;
    uint32_t L1=off;    off+=N_L1;
    uint32_t L2=off;    off+=N_L2;
    uint32_t INH=off;   off+=N_INH;
    uint32_t MN9=off;   off+=N_MN9;
    uint32_t BG=off;    off+=N_BG;

    uint32_t ct_grn = intern(&c, "GRN");
    uint32_t ct_l1  = intern(&c, "antennal_lobe_LN");
    uint32_t ct_l2  = intern(&c, "feeding_interneuron");
    uint32_t ct_inh = intern(&c, "bitter_inhibitory");
    uint32_t ct_mn9 = intern(&c, "MN9");
    uint32_t ct_bg  = intern(&c, "central_misc");

    // tag helper
    #define TAG(lo, hi, FLOW, SC, MODv, NTv, CT) \
        for (uint32_t j=(lo); j<(hi); ++j) { \
            c.rootid[j]   = 720575940000000000ull + j; \
            c.flow[j]     = (FLOW); c.super[j] = (SC); \
            c.modality[j] = (MODv); c.nt[j]    = (NTv); \
            c.side[j]     = (uint8_t)(j & 1); \
            c.celltype_off[j] = (CT); }

    TAG(SUGAR,  SUGAR+N_SUGAR,   FLOW_AFFERENT, SC_SENSORY, MOD_GUSTATORY_SUGAR,  NT_ACH,  ct_grn);
    TAG(WATER,  WATER+N_WATER,   FLOW_AFFERENT, SC_SENSORY, MOD_GUSTATORY_WATER,  NT_ACH,  ct_grn);
    TAG(BITTER, BITTER+N_BITTER, FLOW_AFFERENT, SC_SENSORY, MOD_GUSTATORY_BITTER, NT_ACH,  ct_grn);
    TAG(L1,     L1+N_L1,         FLOW_INTRINSIC,SC_CENTRAL, MOD_NONE,             NT_ACH,  ct_l1);
    TAG(L2,     L2+N_L2,         FLOW_INTRINSIC,SC_CENTRAL, MOD_NONE,             NT_ACH,  ct_l2);
    TAG(INH,    INH+N_INH,       FLOW_INTRINSIC,SC_CENTRAL, MOD_NONE,             NT_GABA, ct_inh);
    TAG(MN9,    MN9+N_MN9,       FLOW_EFFERENT, SC_MOTOR,   MOD_NONE,             NT_ACH,  ct_mn9);
    TAG(BG,     BG+N_BG,         FLOW_INTRINSIC,SC_CENTRAL, MOD_NONE,             NT_ACH,  ct_bg);
    #undef TAG

    // ---- wire the reflex (excitatory, cholinergic, strong syn counts) ----
    // each downstream neuron samples a fan-in from the upstream pool.
    #define WIRE(SRC, NSRC, DST, NDST, FANIN, SMIN, SRANGE) \
        for (uint32_t d=0; d<(NDST); ++d) \
            for (uint32_t k=0; k<(FANIN); ++k) \
                add_edge(&c, (SRC)+rnd_mod(NSRC), (DST)+d, (SMIN)+rnd_mod(SRANGE));

    WIRE(SUGAR, N_SUGAR, L1, N_L1, 6, 8, 8);    // sugar GRNs -> L1
    WIRE(WATER, N_WATER, L1, N_L1, 4, 8, 8);    // water shares L1 (~paper overlap)
    WIRE(L1,    N_L1,    L2, N_L2, 10, 6, 6);   // L1 -> L2
    WIRE(L2,    N_L2,    MN9,N_MN9,40, 6, 6);   // L2 -> MN9 (strong convergence)

    // bitter drives inhibitory interneurons that veto the L2 feeding stage
    WIRE(BITTER, N_BITTER, INH, N_INH, 6, 8, 8);
    WIRE(INH,    N_INH,    L2,  N_L2, 12, 8, 8);  // GABA: sign flips to inhibitory

    // sparse random background so the whole field isn't silent/identical
    for (uint32_t e = 0; e < N_BG * 3; ++e)
        add_edge(&c, BG + rnd_mod(N_BG), BG + rnd_mod(N_BG), 1 + rnd_mod(3));
    #undef WIRE

    int rc = write_bin(&c, out);
    if (rc == 0)
        fprintf(stderr,
            "flypack synth: SUGAR[%u..%u) WATER[%u..%u) BITTER[%u..%u) "
            "L1[%u..) L2[%u..) INH[%u..) MN9[%u..%u) BG[%u..%u)\n",
            SUGAR, SUGAR+N_SUGAR, WATER, WATER+N_WATER, BITTER, BITTER+N_BITTER,
            L1, L2, INH, MN9, MN9+N_MN9, BG, BG+N_BG);
    return rc;
}

// ---------------------------------------------------------------------------
// pack real CSVs (nodes + edges) emitted by the python converter
// ---------------------------------------------------------------------------
static int cmd_pack(const char* nodes_csv, const char* edges_csv, const char* out) {
    FILE* fn = fopen(nodes_csv, "r");
    if (!fn) { perror("open nodes"); return 1; }

    char line[1024];
    // count nodes (minus header)
    uint32_t N = 0;
    while (fgets(line, sizeof(line), fn)) N++;
    if (N) N--;
    rewind(fn);

    Conn c; conn_init(&c, N);
    fgets(line, sizeof(line), fn);   // skip header
    // row,root_id,flow,super,modality,side,nt,cell_type
    uint32_t r = 0;
    while (fgets(line, sizeof(line), fn) && r < N) {
        char ct[256] = {0};
        unsigned row, flow, super, mod, side, nt;
        unsigned long long rid;
        // cell_type is the trailing field (may be empty)
        int got = sscanf(line, "%u,%llu,%u,%u,%u,%u,%u,%255[^\n]",
                         &row, &rid, &flow, &super, &mod, &side, &nt, ct);
        if (got < 7) { r++; continue; }
        c.rootid[r]   = rid;
        c.flow[r]     = (uint8_t)flow;
        c.super[r]    = (uint8_t)super;
        c.modality[r] = (uint8_t)mod;
        c.side[r]     = (uint8_t)side;
        c.nt[r]       = (uint8_t)nt;
        c.celltype_off[r] = intern(&c, got >= 8 ? ct : "");
        r++;
    }
    fclose(fn);

    FILE* fe = fopen(edges_csv, "r");
    if (!fe) { perror("open edges"); return 1; }
    fgets(line, sizeof(line), fe);   // header
    // pre_row,post_row,syn_count,pre_nt
    unsigned pre, post, syn, pnt;
    while (fgets(line, sizeof(line), fe)) {
        if (sscanf(line, "%u,%u,%u,%u", &pre, &post, &syn, &pnt) >= 3) {
            if (pre < N && post < N) add_edge(&c, pre, post, syn);
        }
    }
    fclose(fe);

    return write_bin(&c, out);
}

int main(int argc, char** argv) {
    if (argc >= 3 && strcmp(argv[1], "synth") == 0)
        return cmd_synth(argv[2]);
    if (argc >= 5 && strcmp(argv[1], "pack") == 0)
        return cmd_pack(argv[2], argv[3], argv[4]);

    fprintf(stderr,
        "usage:\n"
        "  %s synth <out.bin>\n"
        "  %s pack  <nodes.csv> <edges.csv> <out.bin>\n", argv[0], argv[0]);
    return 2;
}
