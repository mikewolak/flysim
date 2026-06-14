// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
// flysim_format.h — on-disk binary layout shared by flypack (writer) and
// the runtime (mmap reader). C99, no dependencies. See FLYSIM_BUILD.md §3.2.
//
// The file is a flat, mmap-friendly blob: a fixed Header followed by arrays at
// the byte offsets the header records. Weights bake in the neurotransmitter
// sign so the hot loop is a plain multiply-add.

#ifndef FLYSIM_FORMAT_H
#define FLYSIM_FORMAT_H

#include <stdint.h>

#define FLYSIM_MAGIC   0x53594C46u  /* 'FLYS' little-endian */
#define FLYSIM_VERSION 1u

// ---- per-neuron enums (stored as uint8) ------------------------------------

// flow: afferent = sensory input, efferent = motor output, intrinsic = interior
typedef enum {
    FLOW_INTRINSIC = 0,
    FLOW_AFFERENT  = 1,
    FLOW_EFFERENT  = 2,
} FlyFlow;

// superclass enum (FlyWire / Schlegel et al. annotation set)
typedef enum {
    SC_UNKNOWN           = 0,
    SC_SENSORY           = 1,
    SC_MOTOR             = 2,
    SC_DESCENDING        = 3,
    SC_ASCENDING         = 4,
    SC_ENDOCRINE         = 5,
    SC_VISUAL_PROJECTION = 6,
    SC_VISUAL_CENTRIFUGAL= 7,
    SC_CENTRAL           = 8,
    SC_OPTIC             = 9,
} FlySuperclass;

// sensory modality (0 when not sensory)
typedef enum {
    MOD_NONE            = 0,
    MOD_GUSTATORY_SUGAR = 1,
    MOD_GUSTATORY_WATER = 2,
    MOD_GUSTATORY_BITTER= 3,
    MOD_MECHANO_ANTENNA = 4,
    MOD_OLFACTORY       = 5,
    MOD_VISUAL          = 6,
    MOD_THERMO          = 7,
    MOD_HYGRO           = 8,
} FlyModality;

// neurotransmitter class (for reference; sign already baked into weights)
typedef enum {
    NT_UNKNOWN = 0,
    NT_ACH     = 1,   // acetylcholine  -> excitatory (+)
    NT_GABA    = 2,   // GABA           -> inhibitory (-)
    NT_GLUT    = 3,   // glutamate      -> inhibitory (-) in fly (GluCl)
    NT_DA      = 4,   // dopamine       -> modulatory (~0)
    NT_SER     = 5,   // serotonin      -> modulatory (~0)
    NT_OCT     = 6,   // octopamine     -> modulatory (~0)
} FlyNT;

// side: which body half a neuron sits on
typedef enum { SIDE_LEFT = 0, SIDE_RIGHT = 1, SIDE_CENTER = 2 } FlySide;

// Dale's-principle sign for a neurotransmitter class. +1 / -1 / 0.
static inline float flysim_nt_sign(uint8_t nt) {
    switch (nt) {
        case NT_ACH:  return  1.0f;
        case NT_GABA: return -1.0f;
        case NT_GLUT: return -1.0f;
        default:      return  0.0f;   // modulatory / unknown -> 0, matches Shiu
    }
}

// ---- file header -----------------------------------------------------------
// All offsets are byte offsets from the start of the file. Arrays are tightly
// packed in the order the offsets are declared. Little-endian; written and read
// on the same Apple-silicon host so no byte-swap path is provided.

typedef struct {
    uint32_t magic;        // FLYSIM_MAGIC
    uint32_t version;      // FLYSIM_VERSION
    uint32_t N;            // neuron count (CSC rows/cols)
    uint32_t E;            // edge count (CSC nonzeros)

    uint64_t off_indptr;   // [N+1] uint32  CSC column pointers (by postsynaptic)
    uint64_t off_indices;  // [E]   uint32  presynaptic row index per edge
    uint64_t off_weights;  // [E]   float32 signed weight = sign(pre)*w_syn*syn_count

    uint64_t off_nt;       // [N]   uint8   NT class per neuron
    uint64_t off_flow;     // [N]   uint8   FlyFlow
    uint64_t off_super;    // [N]   uint8   FlySuperclass
    uint64_t off_modality; // [N]   uint8   FlyModality
    uint64_t off_side;     // [N]   uint8   FlySide
    uint64_t off_rootid;   // [N]   uint64  original FlyWire root_id (row -> id)

    uint64_t off_celltype; // [N]   uint32  index into string table (cell type)
    uint64_t off_strtab;   // char[]        NUL-separated cell-type strings
    uint64_t strtab_bytes; // length of the string table in bytes

    uint64_t file_bytes;   // total file size, for sanity checks
    uint64_t _reserved[6];
} FlysimHeader;

#endif // FLYSIM_FORMAT_H
