// flydrive.c — headless driver / smoke test for the LIF core. C99.
// Reproduces the v0 contract: clamp sugar GRNs, run 1 s of bio time, read MN9.
//
//   flydrive <flysim.bin> [sugar_hz] [seconds]

#include "../src/flysim.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <flysim.bin> [hz] [sec]\n", argv[0]); return 2; }
    float hz  = argc > 2 ? atof(argv[2]) : 150.0f;
    float sec = argc > 3 ? atof(argv[3]) : 1.0f;

    FlySim* s = flysim_open(argv[1], FLYSIM_CPU);
    if (!s) return 1;

    FlySet sugar  = flysim_set_by_modality(s, MOD_GUSTATORY_SUGAR, -1);
    FlySet water  = flysim_set_by_modality(s, MOD_GUSTATORY_WATER, -1);
    FlySet bitter = flysim_set_by_modality(s, MOD_GUSTATORY_BITTER, -1);
    FlySet mn9    = flysim_set_by_celltype(s, "MN9");
    FlySet motor  = flysim_set_by_superclass(s, SC_MOTOR, -1);

    printf("sets: sugar=%u water=%u bitter=%u MN9=%u motor=%u\n",
           flysim_set_size(s, sugar), flysim_set_size(s, water),
           flysim_set_size(s, bitter), flysim_set_size(s, mn9),
           flysim_set_size(s, motor));

    const float dt = 0.001f;
    const int steps = (int)(sec / dt);

    // baseline (no stimulus)
    flysim_run(s, dt, 200);
    printf("baseline   MN9 = %6.2f Hz  (spikes/step ~%u)\n",
           flysim_set_rate(s, mn9), flysim_last_spike_count(s));

    // present sugar
    flysim_clamp(s, sugar, hz);
    printf("\nclamping sugar GRNs @ %.0f Hz for %.2f s ...\n", hz, sec);
    for (int t = 0; t < steps; ++t) {
        flysim_step(s, dt);
        if ((t % 100) == 0 || t == steps - 1)
            printf("  t=%4dms  MN9=%6.2f Hz  L-path spikes/step=%u  simT=%.3f\n",
                   t, flysim_set_rate(s, mn9), flysim_last_spike_count(s),
                   flysim_sim_time(s));
    }
    float sugar_mn9 = flysim_set_rate(s, mn9);
    printf("\nRESULT  sugar -> MN9 = %.2f Hz\n", sugar_mn9);

    // bitter override: keep sugar, add bitter, expect MN9 suppressed
    flysim_clamp(s, bitter, hz);
    for (int t = 0; t < steps; ++t) flysim_step(s, dt);
    printf("RESULT  sugar+bitter -> MN9 = %.2f Hz (expect suppressed)\n",
           flysim_set_rate(s, mn9));

    // release everything, let it settle
    flysim_release_all(s);
    for (int t = 0; t < steps; ++t) flysim_step(s, dt);
    printf("RESULT  released -> MN9 = %.2f Hz (expect ~baseline)\n",
           flysim_set_rate(s, mn9));

    flysim_close(s);
    return sugar_mn9 > 1.0f ? 0 : 3;   // nonzero exit if the reflex didn't fire
}
