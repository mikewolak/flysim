// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
// flyevent.c — validate event-driven scatter against the dense gather across
// CPU and GPU (all must be bit-for-bit identical) and measure throughput.
//
//   flyevent <flysim.bin> [hz] [warmup] [measure]

#include "../src/flysim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }

typedef struct { const char* name; double sps; float mn9; float* rate; uint32_t N; double active; } Run;

static Run run(const char* bin, const char* name, FlyBackend be, int event,
               float hz, int warmup, int measure) {
    Run r; memset(&r,0,sizeof(r)); r.name = name;
    FlySim* s = flysim_open(bin, be);
    flysim_set_eventdriven(s, event);
    FlySet sugar = flysim_set_by_modality(s, MOD_GUSTATORY_SUGAR, -1);
    FlySet m9    = flysim_set_by_celltype(s, "MN9");
    flysim_clamp(s, sugar, hz);
    flysim_run(s, 0.001f, warmup);
    double best=1e30, spk=0;
    for (int b=0;b<5;++b){ double t0=now_s(); flysim_run(s,0.001f,measure);
        double dt=now_s()-t0; if(dt<best)best=dt; spk+=flysim_last_spike_count(s); }
    r.sps = measure/best; r.mn9 = flysim_set_rate(s,m9);
    r.active = (spk/5.0)/flysim_neuron_count(s);
    uint32_t n; const float* rr=flysim_rate_buffer(s,&n); r.N=n;
    r.rate=malloc(n*sizeof(float)); memcpy(r.rate,rr,n*sizeof(float));
    flysim_close(s);
    return r;
}
static double maxdiff(const float*a,const float*b,uint32_t N){ double m=0; for(uint32_t i=0;i<N;i++){double d=fabs(a[i]-b[i]); if(d>m)m=d;} return m; }

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s <bin> [hz] [warmup] [measure]\n",argv[0]);return 2;}
    const char*bin=argv[1]; float hz=argc>2?atof(argv[2]):150;
    int wu=argc>3?atoi(argv[3]):200, ms=argc>4?atoi(argv[4]):300;

    Run cg=run(bin,"CPU gather",     FLYSIM_CPU,0,hz,wu,ms);
    Run ce=run(bin,"CPU event",      FLYSIM_CPU,1,hz,wu,ms);
    Run gg=run(bin,"GPU gather",     FLYSIM_GPU,0,hz,wu,ms);
    Run ge=run(bin,"GPU event",      FLYSIM_GPU,1,hz,wu,ms);

    printf("\nN=%u  active fraction ~%.2f%%\n", cg.N, ce.active*100);
    printf("%-12s %9s %12s   %s\n","config","steps/s","MN9(Hz)","max|Δrate| vs CPU-gather");
    Run* all[4]={&cg,&ce,&gg,&ge};
    for(int i=0;i<4;i++){
        double d=maxdiff(cg.rate, all[i]->rate, cg.N);
        printf("%-12s %9.0f %12.5f   %.4g %s\n", all[i]->name, all[i]->sps, all[i]->mn9, d,
               d==0?"BIT-EXACT":"");
    }
    printf("\nrealtime (1000 steps/s): CPU-event %.2fx  GPU-event %.2fx\n",
           ce.sps/1000.0, ge.sps/1000.0);
    return 0;
}
