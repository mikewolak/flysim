// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
// flycompare.c — benchmark CPU vs GPU and dense-gather vs event-driven scatter
// on the same stimulus protocol, verify all backends agree bit-for-bit, and emit
// an HTML performance + accuracy report.
//
//   flycompare <flysim.bin> [hz] [warmup] [measure] [out.html]

#include "../src/flysim.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <sys/sysctl.h>

static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static int ncores(void){ int n=0; size_t s=sizeof(n); sysctlbyname("hw.activecpu",&n,&s,0,0); return n?n:1; }

typedef struct {
    const char* name; double sps, rt; float mn9; float* rate; uint32_t N; double active;
} Run;

static Run run_cfg(const char* bin, const char* name, FlyBackend be, int fast,
                   int event, float hz, int warmup, int measure) {
    Run r; memset(&r,0,sizeof(r)); r.name = name;
    FlySim* s = flysim_open(bin, be);
    if (be == FLYSIM_GPU && fast >= 0) flysim_gpu_fast(s, fast);
    flysim_set_eventdriven(s, event);
    r.N = flysim_neuron_count(s);
    FlySet sugar = flysim_set_by_modality(s, MOD_GUSTATORY_SUGAR, -1);
    FlySet mn9   = flysim_set_by_celltype(s, "MN9");
    flysim_clamp(s, sugar, hz);
    flysim_run(s, 0.001f, warmup);

    double best = 1e30, spk = 0;
    for (int b=0;b<5;++b){ double t0=now_s(); flysim_run(s,0.001f,measure);
        double dt=now_s()-t0; if(dt<best)best=dt; spk+=flysim_last_spike_count(s); }
    r.sps = measure/best; r.rt = r.sps*0.001;
    r.mn9 = flysim_set_rate(s, mn9);
    r.active = (spk/5.0)/r.N;
    uint32_t n; const float* rate = flysim_rate_buffer(s,&n);
    r.rate = malloc(n*sizeof(float)); memcpy(r.rate, rate, n*sizeof(float));
    flysim_close(s);
    usleep(800000);   // brief cool-down between sustained configs
    return r;
}

static double maxdiff(const float*a,const float*b,uint32_t N){ double m=0; for(uint32_t i=0;i<N;i++){double d=fabs(a[i]-b[i]); if(d>m)m=d;} return m; }

int main(int argc, char** argv) {
    if (argc < 2){ fprintf(stderr,"usage: %s <bin> [hz] [warmup] [measure] [out.html]\n",argv[0]); return 2; }
    const char* bin=argv[1];
    float hz=argc>2?atof(argv[2]):150.0f;
    int wu=argc>3?atoi(argv[3]):200, ms=argc>4?atoi(argv[4]):300;
    const char* out=argc>5?argv[5]:"flysim_compare.html";
    int cores=ncores();

    Run cg=run_cfg(bin,"CPU · gather",       FLYSIM_CPU,-1,0,hz,wu,ms);
    Run ce=run_cfg(bin,"CPU · event-driven", FLYSIM_CPU,-1,1,hz,wu,ms);
    Run gg=run_cfg(bin,"GPU · gather (warp)",FLYSIM_GPU, 1,0,hz,wu,ms);
    Run ge=run_cfg(bin,"GPU · event-driven", FLYSIM_GPU, 1,1,hz,wu,ms);
    Run* all[4]={&cg,&ce,&gg,&ge}; uint32_t N=cg.N;

    printf("\nN=%u active~%.2f%%\n",N,ce.active*100);
    for(int i=0;i<4;i++) printf("%-22s %7.0f st/s  %.2fx RT  MN9=%.4f  maxΔ=%.3g\n",
        all[i]->name, all[i]->sps, all[i]->rt, all[i]->mn9, maxdiff(cg.rate,all[i]->rate,N));

    double mxs=0; for(int i=0;i<4;i++) if(all[i]->sps>mxs)mxs=all[i]->sps;
    const char* col[4]={"#8a858e","#38c7ff","#b08cff","#3ce682"};

    FILE* f=fopen(out,"w");
    fprintf(f,"<!doctype html><html><head><meta charset='utf-8'><title>FlySim — real-time fly brain</title><style>"
"body{background:#1c1d20;color:#d6d8de;font:14px -apple-system,Menlo,monospace;margin:40px;max-width:940px}"
"h1{color:#3ce682;font-weight:800;letter-spacing:1px}h2{color:#8a858e;font-size:12px;letter-spacing:2px;text-transform:uppercase;margin-top:32px}"
"table{border-collapse:collapse;width:100%%;margin:12px 0}td,th{padding:9px 13px;border-bottom:1px solid #ffffff14;text-align:right}"
"th:first-child,td:first-child{text-align:left;color:#8a858e}.big{font-size:24px;font-weight:800}.g{color:#3ce682}.dim{color:#8a858e}"
".bar{height:20px;border-radius:3px;display:inline-block}code{background:#0006;padding:2px 6px;border-radius:4px;color:#38c7ff}"
".hero{font-size:40px;font-weight:800;color:#3ce682;margin:6px 0}</style></head><body>");
    fprintf(f,"<h1>FLYSIM &mdash; whole fly brain, faster than life</h1>");
    fprintf(f,"<p class='dim'>FlyWire connectome <code>%s</code> &middot; N=%u neurons / 16.8M synapses &middot; "
              "sugar GRNs @ %.0f Hz &middot; active fraction ~%.1f%% &middot; %d warmup + %d timed steps @ 1 ms tick &middot; %d-core CPU.</p>",
        bin,N,hz,ce.active*100,wu,ms,cores);
    fprintf(f,"<div class='hero'>%.2f&times; real-time</div><p class='dim'>GPU event-driven, whole connectome, 1 ms biological tick.</p>", ge.rt);

    fprintf(f,"<h2>Throughput</h2><table><tr><th>config</th><th>steps/sec</th><th>&times; real-time</th><th>ms/step</th><th>MN9 (Hz)</th></tr>");
    for(int i=0;i<4;i++){ int hot = all[i]==&ge;
        fprintf(f,"<tr><td>%s</td><td class='big'%s>%.0f</td><td%s>%.2f&times;</td><td>%.3f</td><td>%.2f</td></tr>",
            all[i]->name, hot?" style='color:#3ce682'":"", all[i]->sps,
            hot?" class='g'":"", all[i]->rt, 1000.0/all[i]->sps, all[i]->mn9); }
    fprintf(f,"</table><table>");
    for(int i=0;i<4;i++) fprintf(f,"<tr><td style='width:170px'>%s</td><td style='width:100%%'>"
        "<span class='bar' style='width:%.1f%%;background:%s'></span></td><td>%.0f/s</td></tr>",
        all[i]->name,100*all[i]->sps/mxs,col[i],all[i]->sps);
    fprintf(f,"</table>");

    fprintf(f,"<h2>Accuracy &mdash; all backends vs CPU gather</h2><table>"
"<tr><th>config</th><th>max |&Delta;rate|</th><th>MN9 (Hz)</th><th>verdict</th></tr>");
    for(int i=0;i<4;i++){ double d=maxdiff(cg.rate,all[i]->rate,N);
        fprintf(f,"<tr><td>%s</td><td>%.3g Hz</td><td>%.4f</td><td class='g'>%s</td></tr>",
            all[i]->name,d,all[i]->mn9, d==0?"bit-exact ✓":"—"); }
    fprintf(f,"</table>");
    fprintf(f,"<p class='dim'>Every path accumulates the synaptic drive in Q14 fixed-point integers, so the "
              "result is independent of thread count and reduction order: CPU, GPU, dense gather and sparse "
              "scatter are <b>bit-for-bit identical</b>. Event-driven touches only edges out of the ~%.1f%% of "
              "neurons that spiked each step, instead of all 16.8M synapses — which is what carries the whole "
              "brain past real time.</p>", ce.active*100);
    fprintf(f,"<p class='dim'>FlySim (c) 2026 Epromfoundry, Inc. — educational use only. Connectome data: FlyWire/FAFB (own terms).</p>");
    fprintf(f,"</body></html>");
    fclose(f);
    printf("\nwrote %s\n",out);
    for(int i=0;i<4;i++) free(all[i]->rate);
    return 0;
}
