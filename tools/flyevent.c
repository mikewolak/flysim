// flyevent.c — validate the event-driven scatter against the dense gather
// (must be bit-for-bit identical) and measure the speedup. CPU only.
//
//   flyevent <flysim.bin> [hz] [warmup] [measure]

#include "../src/flysim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }

static void run(const char* bin, int event, float hz, int warmup, int measure,
                float* rate_out, uint32_t* N_out, double* sps, float* mn9, double* active) {
    FlySim* s = flysim_open(bin, FLYSIM_CPU);
    flysim_set_eventdriven(s, event);
    FlySet sugar = flysim_set_by_modality(s, MOD_GUSTATORY_SUGAR, -1);
    FlySet m9    = flysim_set_by_celltype(s, "MN9");
    flysim_clamp(s, sugar, hz);
    flysim_run(s, 0.001f, warmup);

    double best = 1e30; double spk = 0;
    for (int burst=0; burst<5; ++burst) {
        double t0 = now_s();
        flysim_run(s, 0.001f, measure);
        double dt = now_s()-t0; if (dt<best) best=dt;
        spk += flysim_last_spike_count(s);
    }
    *sps = measure / best;
    *mn9 = flysim_set_rate(s, m9);
    *active = (spk/5.0) / flysim_neuron_count(s);
    uint32_t n; const float* r = flysim_rate_buffer(s,&n);
    memcpy(rate_out, r, n*sizeof(float)); *N_out = n;
    flysim_close(s);
}

int main(int argc, char** argv) {
    if (argc<2){ fprintf(stderr,"usage: %s <bin> [hz] [warmup] [measure]\n",argv[0]); return 2; }
    const char* bin=argv[1];
    float hz=argc>2?atof(argv[2]):150; int wu=argc>3?atoi(argv[3]):200, ms=argc>4?atoi(argv[4]):300;

    static float ra[2000000], rb[2000000];
    uint32_t Na,Nb; double sa,sb,act_a,act_b; float ma,mb;
    printf("gather...\n");        run(bin,0,hz,wu,ms,ra,&Na,&sa,&ma,&act_a);
    printf("event-driven...\n");  run(bin,1,hz,wu,ms,rb,&Nb,&sb,&mb,&act_b);

    double mxd=0; for (uint32_t i=0;i<Na;i++){ double d=fabs(ra[i]-rb[i]); if(d>mxd)mxd=d; }
    printf("\nN=%u  active fraction ~%.2f%%\n", Na, act_b*100);
    printf("gather       : %7.0f steps/s   MN9=%.6f Hz\n", sa, ma);
    printf("event-driven : %7.0f steps/s   MN9=%.6f Hz   (%.1fx)\n", sb, mb, sb/sa);
    printf("match        : max|Δrate| = %.6g Hz   %s\n", mxd,
           mxd==0?"BIT-EXACT ✓":"(differs)");
    return mxd==0?0:1;
}
