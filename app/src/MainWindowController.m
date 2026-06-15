// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  MainWindowController.m — the Logic-Pro-styled FlySim panel.

#import "MainWindowController.h"
#import "FlyController.h"
#import "FSWidgets.h"
#import "FSControlServer.h"
#import "FlightView.h"

// proboscis mapping (§8.1): MN9 firing rate (Hz) → extension fraction. Tuned so
// a real sugar response (MN9 ~40–55 Hz on the FlyWire brain) drives a full,
// visible extension that reaches the food and closes the feeding loop.
#define R_LO   5.0f
#define R_HI   55.0f
#define MAX_EXT_DEG 42.0f

@interface FSBackdrop : NSView @end
@implementation FSBackdrop
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)d {
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[FSStyle windowTop]
                                                  endingColor:[FSStyle windowBottom]];
    [g drawInRect:self.bounds angle:90];
}
@end

@implementation MainWindowController {
    FlyController *_fly;

    NSMutableDictionary<NSString *, FSButton *> *_senseBtns;   // name -> button
    NSSlider *_strength;
    NSTextField *_strengthLabel;

    FSActivityView *_activity;
    FSMeter *_mn9Meter, *_l2Meter, *_dnMeter, *_motorMeter, *_proboscisMeter;
    NSTextField *_mn9Hz, *_proboscisDeg;
    FSFlyView *_flyView;
    FSButton  *_foodBtn;
    BOOL       _feeding;          // edge-tracks arrived-at-food (closed loop)

    // generic "any population" lab control (Settings tab)
    NSPopUpButton *_genKind;
    NSTextField *_genName, *_genHz, *_genResult;

    NSButton *_runBtn, *_resetBtn;
    NSSegmentedControl *_backendSeg;
    NSTextField *_statusLeft, *_statusRight;

    NSTimer *_uiTimer;
    NSPopUpButton *_rateSel;
    NSPopUpButton *_speedSel;
    double _sampleHz;        // UI sampler rate (60 default, up to 120)
    float _proboscisAngle;   // smoothed, degrees

    // panels (toggled by the Settings tab)
    FSPanel *_stimPanel, *_brainPanel, *_outPanel, *_settingsPanel;
    NSButton *_settingsBtn;

    // MCP control plane
    FSControlServer *_mcp;
    NSButton *_mcpEnable;
    NSTextField *_portField, *_mcpStatus;

    FlightView *_flightView;             // 3D first-person flight tab
    NSSegmentedControl *_tabSeg;         // Brain | Flight tab switcher
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 1040, 820);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                  backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:win])) return nil;

    win.title = @"FlySim — Connectome Reflex";
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    win.minSize = NSMakeSize(980, 760);
    win.delegate = self;
    win.releasedWhenClosed = NO;
    if (@available(macOS 10.14, *)) win.appearance =
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [win center];

    [self _openModel];
    [self _buildUI];
    return self;
}

- (void)_openModel {
    // flysim.bin sits next to the .app bundle, or in ../data during dev
    NSArray *cands = @[
        [[[NSBundle mainBundle] bundlePath]
            stringByDeletingLastPathComponent],
        [[[NSBundle mainBundle] resourcePath] ?: @"" stringByStandardizingPath],
    ];
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *names = @[@"flysim_real.bin", @"flysim.bin"];   // prefer the real connectome
    for (NSString *d in cands) for (NSString *nm in names) {
        [paths addObject:[d stringByAppendingPathComponent:nm]];
        [paths addObject:[[d stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:nm]];
    }
    [paths addObject:[@"~/flysim/data/flysim_real.bin" stringByExpandingTildeInPath]];
    [paths addObject:[@"~/flysim/data/flysim.bin" stringByExpandingTildeInPath]];

    for (NSString *p in paths)
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            _fly = [[FlyController alloc] initWithBinPath:p];
            if (_fly) break;
        }
}

// ---------------------------------------------------------------------------
- (void)_buildUI {
    FSBackdrop *root = [[FSBackdrop alloc] initWithFrame:self.window.contentView.bounds];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = root;

    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;

    // ---- transport bar ----------------------------------------------------
    NSView *bar = [self _transportBarWithWidth:W];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [root addSubview:bar];

    CGFloat top = 64, pad = 16, botH = 340;

    // ---- stimulus panel (left) -------------------------------------------
    _stimPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad, top, 268, H - top - botH - pad)];
    _stimPanel.title = @"Stimulus  ·  the senses (afferent clamp)";
    _stimPanel.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    [root addSubview:_stimPanel];
    [self _fillStimPanel:_stimPanel];

    // ---- activity heatmap (center, fills) --------------------------------
    _brainPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad+268+12, top, W - (pad+268+12) - pad, H - top - botH - pad)];
    _brainPanel.title = @"Population activity  ·  firing rate";
    _brainPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_brainPanel];

    _activity = [[FSActivityView alloc] initWithFrame:
        NSMakeRect(10, 30, _brainPanel.bounds.size.width-20,
                   _brainPanel.bounds.size.height-40)];
    _activity.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_brainPanel addSubview:_activity];
    if (_fly) [_activity setStages:[_fly activityStages]];   // hover labels per band

    // ---- output panel (bottom, full width) -------------------------------
    _outPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad, H - botH, W - 2*pad, botH - pad)];
    _outPanel.title = @"Motor output  ·  MN9 → proboscis";
    _outPanel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [root addSubview:_outPanel];
    [self _fillOutputPanel:_outPanel];

    // ---- settings panel (hidden until the Settings tab is selected) ------
    _settingsPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad, top, W - 2*pad, H - top - pad)];
    _settingsPanel.title = @"Settings  ·  MCP control server";
    _settingsPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _settingsPanel.hidden = YES;
    [root addSubview:_settingsPanel];
    [self _fillSettingsPanel:_settingsPanel];

    // ---- 3D first-person flight view (the Flight tab; hidden by default) --
    _flightView = [[FlightView alloc] initWithFly:_fly frame:
        NSMakeRect(pad, top, W - 2*pad, H - top - pad)];
    _flightView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _flightView.hidden = YES;
    [root addSubview:_flightView];

    // ---- UI sampler (60 Hz default, up to 120 Hz) -------------------------
    _sampleHz = 60.0;
    [self _installTimer];

    if (!_fly) {
        _statusLeft.stringValue = @"⚠︎ flysim.bin not found — run: flypack synth data/flysim.bin";
    } else {
        _statusLeft.stringValue = [NSString stringWithFormat:
            @"loaded  N=%u neurons   E=%u edges", _fly.neuronCount, _fly.edgeCount];
    }

    [self _setupMCP];

    // demo hook: FLYSIM_AUTODEMO=1 auto-runs with sugar clamped (for screenshots)
    if (_fly && getenv("FLYSIM_AUTODEMO")) {
        [_fly start]; _runBtn.title = @"■  STOP";
        _foodBtn.isOn = YES; [self _foodToggled:nil];   // place food → smell → walk → feed
    }
    if (getenv("FLYSIM_SHOW_SETTINGS")) [self _toggleSettings:nil];
    if (getenv("FLYSIM_FLIGHT")) { _tabSeg.selectedSegment = 1; [self _tabChanged:nil]; }
}

- (NSView *)_transportBarWithWidth:(CGFloat)W {
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, 64)];

    NSTextField *title = [NSTextField labelWithString:@"FLYSIM"];
    title.font = [FSStyle mono:18 weight:NSFontWeightHeavy];
    title.textColor = [FSStyle output];
    title.frame = NSMakeRect(18, 20, 110, 26);
    [bar addSubview:title];

    _runBtn = [self _chromeButton:@"▶  RUN" action:@selector(_toggleRun:)];
    _runBtn.frame = NSMakeRect(150, 18, 100, 30);
    _runBtn.keyEquivalent = @" ";
    [bar addSubview:_runBtn];

    _resetBtn = [self _chromeButton:@"⟲  RESET" action:@selector(_reset:)];
    _resetBtn.frame = NSMakeRect(258, 18, 100, 30);
    [bar addSubview:_resetBtn];

    _backendSeg = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(372, 18, 168, 30)];
    _backendSeg.segmentCount = 2;
    [_backendSeg setLabel:@"CPU" forSegment:0];
    [_backendSeg setLabel:@"GPU · Metal" forSegment:1];
    _backendSeg.selectedSegment = 0;
    _backendSeg.target = self; _backendSeg.action = @selector(_backendChanged:);
    [bar addSubview:_backendSeg];

    _rateSel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(552, 18, 96, 30) pullsDown:NO];
    [_rateSel addItemsWithTitles:@[@"60 Hz", @"90 Hz", @"120 Hz"]];
    [_rateSel selectItemWithTitle:@"60 Hz"];
    _rateSel.font = [FSStyle mono:11 weight:NSFontWeightMedium];
    _rateSel.target = self; _rateSel.action = @selector(_sampleRateChanged:);
    _rateSel.toolTip = @"UI sampler rate (sim tick stays at 1 ms)";
    [bar addSubview:_rateSel];

    _speedSel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(656, 18, 92, 30) pullsDown:NO];
    [_speedSel addItemsWithTitles:@[@"1× speed", @"2×", @"4×", @"8×", @"MAX"]];
    [_speedSel selectItemAtIndex:0];
    _speedSel.font = [FSStyle mono:11 weight:NSFontWeightMedium];
    _speedSel.target = self; _speedSel.action = @selector(_speedChanged:);
    _speedSel.toolTip = @"Sim speed cap (1× = real time @ 1ms tick; MAX = unthrottled)";
    [bar addSubview:_speedSel];

    _tabSeg = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(742, 18, 152, 30)];
    _tabSeg.segmentCount = 2;
    [_tabSeg setLabel:@"🧠 Brain" forSegment:0];
    [_tabSeg setLabel:@"✈ Flight" forSegment:1];
    _tabSeg.selectedSegment = 0;
    _tabSeg.target = self; _tabSeg.action = @selector(_tabChanged:);
    _tabSeg.toolTip = @"Brain view (2D) ↔ first-person 3D flight (what the fly sees)";
    [bar addSubview:_tabSeg];

    _settingsBtn = [self _chromeButton:@"⚙ SETTINGS" action:@selector(_toggleSettings:)];
    _settingsBtn.frame = NSMakeRect(W-126, 18, 110, 30);
    _settingsBtn.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:_settingsBtn];

    // perf / sim readout lives on the bottom status line, well clear of the
    // transport buttons (right-aligned), so nothing overlaps the ⚙ button.
    _statusRight = [NSTextField labelWithString:@""];
    _statusRight.font = [FSStyle mono:10 weight:NSFontWeightRegular];
    _statusRight.textColor = [FSStyle labelDim];
    _statusRight.alignment = NSTextAlignmentRight;
    _statusRight.frame = NSMakeRect(W-540, 2, 524, 14);
    _statusRight.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:_statusRight];

    _statusLeft = [NSTextField labelWithString:@""];
    _statusLeft.font = [FSStyle mono:10 weight:NSFontWeightRegular];
    _statusLeft.textColor = [FSStyle labelDim];
    _statusLeft.frame = NSMakeRect(18, 2, 400, 14);
    _statusLeft.autoresizingMask = NSViewWidthSizable;
    [bar addSubview:_statusLeft];
    return bar;
}

- (NSButton *)_chromeButton:(NSString *)t action:(SEL)a {
    NSButton *b = [NSButton buttonWithTitle:t target:self action:a];
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [FSStyle mono:12 weight:NSFontWeightSemibold];
    return b;
}

// the full sensory repertoire (each maps to a tagged afferent population)
- (NSArray<NSDictionary *> *)_senses {
    NSColor *(^c)(int,int,int) = ^NSColor*(int r,int g,int b){
        return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1]; };
    return @[
        @{@"name":@"sugar",   @"label":@"SUGAR",   @"sub":@"taste · sweet",  @"tint":[FSStyle sugar]},
        @{@"name":@"smell",   @"label":@"SMELL",   @"sub":@"olfactory · walk",@"tint":[FSStyle output]},
        @{@"name":@"water",   @"label":@"WATER",   @"sub":@"taste · water",  @"tint":[FSStyle water]},
        @{@"name":@"touch",   @"label":@"TOUCH",   @"sub":@"mechanosensory", @"tint":c(190,193,200)},
        @{@"name":@"bitter",  @"label":@"BITTER",  @"sub":@"taste · veto",   @"tint":[FSStyle bitter]},
        @{@"name":@"heat",    @"label":@"HEAT",    @"sub":@"thermosensory",  @"tint":c(255,120,60)},
        @{@"name":@"humidity",@"label":@"HUMIDITY",@"sub":@"hygrosensory",   @"tint":c(120,180,255)},
        @{@"name":@"light",   @"label":@"LIGHT",   @"sub":@"visual · eyes",  @"tint":c(255,228,90)},
    ];
}

- (void)_fillStimPanel:(FSPanel *)p {
    CGFloat W = p.bounds.size.width, x = 12, y = 38;
    CGFloat gap = 8, colW = (W - 2*x - gap)/2, bh = 46, bv = bh + 8;

    NSArray *senses = [self _senses];
    _senseBtns = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < senses.count; i++) {
        NSDictionary *d = senses[i];
        NSInteger col = i % 2, row = i / 2;
        FSButton *b = [[FSButton alloc] initWithFrame:
            NSMakeRect(x + col*(colW+gap), y + row*bv, colW, bh)];
        b.label = d[@"label"]; b.sublabel = d[@"sub"]; b.tint = d[@"tint"];
        b.identifier = d[@"name"];
        b.target = self; b.action = @selector(_senseToggled:);
        [p addSubview:b];
        _senseBtns[d[@"name"]] = b;
    }

    CGFloat sy = y + ((senses.count + 1) / 2) * bv + 8;
    NSTextField *sl = [NSTextField labelWithString:@"CLAMP RATE  (Hz applied to whichever senses are lit)"];
    sl.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    sl.textColor = [FSStyle labelDim];
    sl.frame = NSMakeRect(x, sy, W-2*x, 14);
    [p addSubview:sl];

    _strength = [NSSlider sliderWithValue:150 minValue:0 maxValue:200
                                    target:self action:@selector(_strengthChanged:)];
    _strength.frame = NSMakeRect(x, sy+16, W-2*x, 22);
    [p addSubview:_strength];

    _strengthLabel = [NSTextField labelWithString:@"150 Hz"];
    _strengthLabel.font = [FSStyle mono:11 weight:NSFontWeightMedium];
    _strengthLabel.textColor = [FSStyle label];
    _strengthLabel.frame = NSMakeRect(x, sy+40, W-2*x, 16);
    [p addSubview:_strengthLabel];
}

- (void)_fillOutputPanel:(FSPanel *)p {
    CGFloat W = p.bounds.size.width, Hp = p.bounds.size.height;

    // left = numeric readouts (fixed width); right = the animated fly (flexes).
    const CGFloat C1 = 14, C1W = 300;

    // --- MN9 firing rate ---
    NSTextField *mn9cap = [NSTextField labelWithString:@"MN9 FIRING RATE"];
    mn9cap.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    mn9cap.textColor = [FSStyle labelDim];
    mn9cap.frame = NSMakeRect(C1, 34, 200, 14);
    [p addSubview:mn9cap];

    _mn9Meter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 52, C1W, 24)];
    _mn9Meter.tint = [FSStyle output];
    _mn9Meter.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_mn9Meter];

    _mn9Hz = [NSTextField labelWithString:@"0.0 Hz"];
    _mn9Hz.font = [FSStyle mono:22 weight:NSFontWeightBold];
    _mn9Hz.textColor = [FSStyle output];
    _mn9Hz.frame = NSMakeRect(C1, 80, C1W, 26);
    _mn9Hz.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_mn9Hz];

    // --- proboscis extension ---
    NSTextField *pcap = [NSTextField labelWithString:@"PROBOSCIS EXTENSION"];
    pcap.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    pcap.textColor = [FSStyle labelDim];
    pcap.frame = NSMakeRect(C1, 118, 220, 14);
    [p addSubview:pcap];

    _proboscisMeter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 136, C1W, 24)];
    _proboscisMeter.tint = [FSStyle sugar];
    _proboscisMeter.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_proboscisMeter];

    _proboscisDeg = [NSTextField labelWithString:@"0°"];
    _proboscisDeg.font = [FSStyle mono:22 weight:NSFontWeightBold];
    _proboscisDeg.textColor = [FSStyle sugar];
    _proboscisDeg.frame = NSMakeRect(C1, 164, 160, 26);
    _proboscisDeg.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_proboscisDeg];

    // --- motor-output bank: the brain's actual outputs ---
    _l2Meter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 200, C1W, 16)];
    _l2Meter.tint = [FSStyle water]; _l2Meter.caption = @"feeding interneurons";
    _l2Meter.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_l2Meter];

    _dnMeter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 224, C1W, 16)];
    _dnMeter.tint = [FSStyle output]; _dnMeter.caption = @"descending neurons (brain→body)";
    _dnMeter.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_dnMeter];

    _motorMeter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 248, C1W, 16)];
    _motorMeter.tint = [FSStyle sugar]; _motorMeter.caption = @"all motor neurons";
    _motorMeter.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_motorMeter];

    // --- FOOD toggle: places a sugar droplet in reach (closes the loop) ---
    _foodBtn = [[FSButton alloc] initWithFrame:NSMakeRect(C1, Hp-48, C1W, 36)];
    _foodBtn.label = @"PLACE FOOD"; _foodBtn.sublabel = @"sugar droplet · closes the loop";
    _foodBtn.tint = [FSStyle sugar];
    _foodBtn.target = self; _foodBtn.action = @selector(_foodToggled:);
    _foodBtn.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
    [p addSubview:_foodBtn];

    // --- the animated fly (the star: MN9 → real proboscis motion) ---
    CGFloat fx = C1 + C1W + 24;
    _flyView = [[FSFlyView alloc] initWithFrame:
        NSMakeRect(fx, 30, W - fx - 14, Hp - 40)];
    _flyView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [p addSubview:_flyView];
}

// ---------------------------------------------------------------------------
#pragma mark - actions

- (void)_toggleRun:(id)s {
    if (!_fly) return;
    if (_fly.running) { [_fly stop]; _runBtn.title = @"▶  RUN"; }
    else { [_fly start]; _runBtn.title = @"■  STOP"; }
}
- (void)_reset:(id)s {
    if (!_fly) return;
    [_fly reset];
    [_activity clearHistory];
    _proboscisAngle = 0;
}
- (void)_tabChanged:(id)s {
    BOOL flight = (_tabSeg.selectedSegment == 1);
    if (!_settingsPanel.hidden) {            // leave Settings if it was open
        _settingsPanel.hidden = YES; _settingsBtn.title = @"⚙ SETTINGS";
    }
    _stimPanel.hidden = _brainPanel.hidden = _outPanel.hidden = flight;
    _flightView.hidden = !flight;
    [_flightView setActive:flight];
}
- (void)_backendChanged:(NSSegmentedControl *)seg {
    if (!_fly) return;
    if (seg.selectedSegment == 1) {
        [_fly setUseGPU:YES];
        if (!_fly.usingGPU) {        // Metal backend not wired yet — be honest
            seg.selectedSegment = 0;
            _statusLeft.stringValue =
                @"GPU · Metal backend pending (§6) — CSC gather kernel next; running CPU";
        }
    } else {
        [_fly setUseGPU:NO];
    }
}
- (void)_installTimer {
    [_uiTimer invalidate];
    _uiTimer = [NSTimer timerWithTimeInterval:1.0/_sampleHz target:self
                                     selector:@selector(_tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_uiTimer forMode:NSRunLoopCommonModes];
}
- (void)_sampleRateChanged:(NSPopUpButton *)sel {
    _sampleHz = sel.titleOfSelectedItem.doubleValue;   // "60 Hz" -> 60
    if (_sampleHz < 1) _sampleHz = 60;
    [self _installTimer];
}
- (void)_speedChanged:(NSPopUpButton *)sel {
    static const double mult[] = { 1, 2, 4, 8, -1 };   // -1 == unthrottled (MAX)
    NSInteger i = sel.indexOfSelectedItem;
    if (i < 0 || i > 4) i = 0;
    _fly.speed = mult[i];
}
- (void)_strengthChanged:(NSSlider *)s {
    _strengthLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", s.doubleValue];
    [self _applyStim];
}
- (void)_senseToggled:(id)s { [self _applyStim]; }

- (void)_foodToggled:(id)s {
    _flyView.foodPresent = _foodBtn.isOn;
    [self _applyStim];   // food emits odor (smell) + releases feeding clamp when removed
}

// push every lit sense's clamp into the model. Two reflex couplings: placing
// food makes it *smell* (drives the walk), and arriving on the food makes it
// *taste* (sustains sugar → MN9 → tongue), so the loop runs hands-free.
- (void)_applyStim {
    if (!_fly) return;
    float hz = (float)_strength.doubleValue;
    BOOL feeding = _foodBtn.isOn && _flyView.arrivedAtFood;
    for (NSString *name in _senseBtns) {
        if ([name isEqualToString:@"smell"]) continue;     // odor-driven; set in _tick
        BOOL on = _senseBtns[name].isOn;
        float v = on ? hz : 0;
        if ([name isEqualToString:@"sugar"] && feeding) v = hz;   // taste on arrival
        [_fly setValue:@(v) forKey:[name stringByAppendingString:@"Hz"]];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - 30 Hz UI sampler

- (void)_tick {
    if (!_fly) return;
    FlySnapshot s = [_fly snapshot];

    [_activity pushBins:s.bins count:FS_BINS ceiling:120.0f];

    // motor-output bank (the brain's actual outputs)
    _mn9Meter.value   = MIN(1.0, s.mn9Rate / 200.0f);
    _l2Meter.value    = MIN(1.0, s.l2Rate / 200.0f);
    _dnMeter.value    = MIN(1.0, s.dnRate / 60.0f);
    _motorMeter.value = MIN(1.0, s.motorRate / 60.0f);
    _mn9Hz.stringValue = [NSString stringWithFormat:@"%.1f Hz", s.mn9Rate];

    // rate -> proboscis extension (§8.1), critically-damped follow
    float ext = (s.mn9Rate - R_LO) / (R_HI - R_LO);
    ext = ext < 0 ? 0 : (ext > 1 ? 1 : ext);
    float target = ext * MAX_EXT_DEG;
    _proboscisAngle += (target - _proboscisAngle) * 0.18f;   // damp
    _proboscisMeter.value = _proboscisAngle / MAX_EXT_DEG;
    _proboscisDeg.stringValue = [NSString stringWithFormat:@"%.0f°", _proboscisAngle];

    // drive the animated fly: ORN firing → search speed; the search updates the
    // fly's position, then we clamp the olfactory ORNs to the odor it now smells
    // (real proximity signal); taste (MN9) → tongue.
    _flyView.smellDrive = MIN(1.0, s.smellRate / 120.0f);
    _flyView.foodPresent = _foodBtn.isOn;
    _flyView.mn9Hz = s.mn9Rate;
    _flyView.extension = _proboscisAngle / MAX_EXT_DEG;     // runs the search step

    float manualSmell = _senseBtns[@"smell"].isOn ? (float)_strength.doubleValue : 0;
    float odorSmell   = _foodBtn.isOn ? (float)(_flyView.perceivedOdor * 200.0) : 0;
    _fly.smellHz = MAX(manualSmell, odorSmell);            // ORNs fire by what it smells

    // closed loop: arriving on the food makes it taste → sustains sugar. Edge-
    // triggered so we don't fight the clamp every frame.
    BOOL feeding = _foodBtn.isOn && _flyView.arrivedAtFood;
    if (feeding != _feeding) { _feeding = feeding; [self _applyStim]; }
    _foodBtn.glow = feeding ? 1.0 : (_flyView.smellDrive > 0.1 && _foodBtn.isOn ? 0.5 : 0.0);

    // illuminate each sense button by how hard its afferent population is firing
    NSDictionary *srate = @{ @"sugar":@(s.sugarRate), @"water":@(s.waterRate),
        @"bitter":@(s.bitterRate), @"smell":@(s.smellRate), @"touch":@(s.touchRate),
        @"heat":@(s.heatRate), @"humidity":@(s.humidRate), @"light":@(s.lightRate) };
    for (NSString *name in _senseBtns)
        _senseBtns[name].glow = MIN(1.0, [srate[name] floatValue] / 150.0f);

    // each sense → a visible reaction on the fly: bitter is an aversive taste the
    // fly rejects (behavioural — our connectome subset has cholinergic bitter GRNs
    // and no measurable feeding veto), touch startles, heat makes it recoil, light
    // buzzes the wings. Keyed off the *applied* stimulus (the lit sense buttons),
    // so the fly stays calm until you actually stimulate a sense.
    [_flyView setReactBitterVeto:MIN(1.0, _fly.bitterHz   / 150.0)
                           touch:MIN(1.0, _fly.touchHz    / 150.0)
                            heat:MIN(1.0, _fly.heatHz     / 150.0)
                           light:MIN(1.0, _fly.lightHz    / 150.0)
                           humid:MIN(1.0, _fly.humidityHz / 150.0)];

    _statusRight.stringValue = [NSString stringWithFormat:
        @"%@   sim %.2fs   %.0f steps/s   %.2f× realtime   %u spk/step",
        _fly.usingGPU ? @"GPU" : @"CPU",
        s.simTime, s.stepsPerSec, s.realtimeFactor, s.lastSpikes];
}

// ---------------------------------------------------------------------------
#pragma mark - UI sync (so MCP-driven changes reflect in the panel)

- (void)_syncStimUI {
    for (NSString *name in _senseBtns) {
        float hz = [[_fly valueForKey:[name stringByAppendingString:@"Hz"]] floatValue];
        _senseBtns[name].isOn = hz > 0;
    }
}
- (void)_syncTransportUI {
    _runBtn.title = _fly.running ? @"■  STOP" : @"▶  RUN";
}

// ---------------------------------------------------------------------------
#pragma mark - Settings tab

- (void)_toggleSettings:(id)s {
    BOOL show = _settingsPanel.hidden;            // about to show settings?
    _settingsPanel.hidden = !show;
    if (show) {                                  // opening: hide everything else
        _stimPanel.hidden = _brainPanel.hidden = _outPanel.hidden = YES;
        _flightView.hidden = YES; [_flightView setActive:NO];
        [self _refreshMCPStatus];
    } else {                                     // closing: restore the active tab
        BOOL flight = (_tabSeg.selectedSegment == 1);
        _stimPanel.hidden = _brainPanel.hidden = _outPanel.hidden = flight;
        _flightView.hidden = !flight; [_flightView setActive:flight];
    }
    _settingsBtn.title = show ? @"⚙ CLOSE" : @"⚙ SETTINGS";
}

- (void)_fillSettingsPanel:(FSPanel *)p {
    CGFloat x = 18, y = 44, w = p.bounds.size.width - 36;

    NSTextField *(^lab)(NSString*,CGFloat,CGFloat,CGFloat,NSColor*,CGFloat) =
      ^NSTextField*(NSString*t,CGFloat lx,CGFloat ly,CGFloat lw,NSColor*c,CGFloat fs){
        NSTextField *l = [NSTextField labelWithString:t];
        l.frame = NSMakeRect(lx,ly,lw,fs+6); l.font = [FSStyle mono:fs weight:NSFontWeightRegular];
        l.textColor = c; [p addSubview:l]; return l; };

    lab(@"MCP CONTROL SERVER", x, y, w, [FSStyle output], 13);
    y += 26;
    lab(@"Every setting is a tool; every output is a queryable / streamable endpoint.",
        x, y, w, [FSStyle labelDim], 11);
    y += 30;

    _mcpEnable = [NSButton checkboxWithTitle:@"  Enable MCP server (loopback only)"
                                      target:self action:@selector(_toggleMCPEnabled:)];
    _mcpEnable.frame = NSMakeRect(x, y, w, 22);
    _mcpEnable.font = [FSStyle mono:12 weight:NSFontWeightMedium];
    [p addSubview:_mcpEnable];
    y += 34;

    lab(@"PORT", x, y, 60, [FSStyle labelDim], 10);
    _portField = [NSTextField textFieldWithString:@"7777"];
    _portField.frame = NSMakeRect(x+58, y-4, 90, 24);
    _portField.font = [FSStyle mono:13 weight:NSFontWeightMedium];
    [p addSubview:_portField];

    NSButton *apply = [self _chromeButton:@"Apply / Restart" action:@selector(_applyPort:)];
    apply.frame = NSMakeRect(x+158, y-5, 140, 26);
    [p addSubview:apply];
    y += 36;

    _mcpStatus = lab(@"", x, y, w, [FSStyle label], 12);
    y += 30;

    lab(@"QUICK START", x, y, w, [FSStyle labelDim], 10); y += 18;
    NSString *ex =
      @"curl 127.0.0.1:7777/tools                       # discover everything\n"
      @"curl 127.0.0.1:7777/data/sensory                # all senses in (Hz)\n"
      @"curl 127.0.0.1:7777/data/motor                  # all outputs (mn9/motor/descending)\n"
      @"curl 127.0.0.1:7777/data/populations            # every clampable population + size\n"
      @"curl -XPOST 127.0.0.1:7777/tool/clamp -d '{\"modality\":\"smell\",\"hz\":150}'\n"
      @"curl -XPOST 127.0.0.1:7777/tool/clamp_set -d '{\"kind\":\"superclass\",\"name\":\"descending\",\"hz\":0}'\n"
      @"curl -N 127.0.0.1:7777/stream?hz=60             # watch outputs live (SSE)";
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(x, y, w, 150)];
    tv.string = ex; tv.editable = NO; tv.drawsBackground = YES;
    tv.backgroundColor = [NSColor colorWithWhite:0 alpha:0.35];
    tv.textColor = [FSStyle water];
    tv.font = [FSStyle mono:11 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewWidthSizable;
    [p addSubview:tv];
    y += 162;

    // ---- generic lab: clamp / read ANY population ------------------------
    lab(@"LAB · drive or read ANY population (modality / superclass / cell-type)",
        x, y, w, [FSStyle output], 12); y += 24;

    _genKind = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y, 132, 24) pullsDown:NO];
    [_genKind addItemsWithTitles:@[@"modality", @"superclass", @"celltype"]];
    _genKind.font = [FSStyle mono:11 weight:NSFontWeightMedium];
    [p addSubview:_genKind];

    _genName = [NSTextField textFieldWithString:@"smell"];
    _genName.frame = NSMakeRect(x+142, y, 188, 24);
    _genName.font = [FSStyle mono:12 weight:NSFontWeightMedium];
    _genName.placeholderString = @"name (smell · descending · MN9 …)";
    [p addSubview:_genName];

    _genHz = [NSTextField textFieldWithString:@"150"];
    _genHz.frame = NSMakeRect(x+340, y, 56, 24);
    _genHz.font = [FSStyle mono:12 weight:NSFontWeightMedium];
    _genHz.toolTip = @"clamp rate (Hz)";
    [p addSubview:_genHz];

    NSButton *cb = [self _chromeButton:@"Clamp" action:@selector(_genClamp:)];
    cb.frame = NSMakeRect(x+404, y-1, 78, 26); [p addSubview:cb];
    NSButton *rb = [self _chromeButton:@"Read" action:@selector(_genRead:)];
    rb.frame = NSMakeRect(x+488, y-1, 78, 26); [p addSubview:rb];
    y += 32;
    _genResult = lab(@"resolve any of the 139,266 neurons by population and clamp or read it",
                     x, y, w, [FSStyle labelDim], 11);
}

- (void)_genShow:(NSDictionary *)r {
    if ([r[@"ok"] boolValue]) {
        _genResult.stringValue = [NSString stringWithFormat:
            @"✓ %@ '%@'  —  %@ neurons  ·  %.1f Hz",
            r[@"kind"], r[@"name"], r[@"size"], [r[@"rate"] floatValue]];
        _genResult.textColor = [FSStyle output];
    } else {
        _genResult.stringValue = [NSString stringWithFormat:@"⚠︎ %@", r[@"error"]];
        _genResult.textColor = [FSStyle bitter];
    }
}
- (void)_genClamp:(id)sender {
    if (!_fly) return;
    [self _genShow:[_fly clampKind:_genKind.titleOfSelectedItem
                              name:_genName.stringValue side:-1 hz:_genHz.floatValue]];
}
- (void)_genRead:(id)sender {
    if (!_fly) return;
    [self _genShow:[_fly readKind:_genKind.titleOfSelectedItem
                             name:_genName.stringValue side:-1]];
}

- (void)_toggleMCPEnabled:(NSButton *)b {
    if (b.state == NSControlStateValueOn) {
        [self _startMCP];
    } else {
        [_mcp stop];
    }
    [self _refreshMCPStatus];
    [[NSUserDefaults standardUserDefaults] setBool:(b.state==NSControlStateValueOn)
                                            forKey:@"mcpEnabled"];
}

- (void)_applyPort:(id)s {
    int port = _portField.stringValue.intValue;
    if (port < 1024 || port > 65535) {
        _mcpStatus.stringValue = @"⚠︎ port must be 1024–65535";
        _mcpStatus.textColor = [FSStyle bitter];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:port forKey:@"mcpPort"];
    [_mcp stop];
    [_mcp setPort:(uint16_t)port];
    if (_mcpEnable.state == NSControlStateValueOn) [self _startMCP];
    [self _refreshMCPStatus];
}

- (void)_startMCP {
    NSString *err = nil;
    if (![_mcp startOnError:&err]) {
        _mcpStatus.stringValue = [NSString stringWithFormat:@"⚠︎ %@", err];
        _mcpStatus.textColor = [FSStyle bitter];
    }
}

- (void)_refreshMCPStatus {
    if (_mcp.running) {
        _mcpStatus.stringValue = [NSString stringWithFormat:
            @"● listening on %@   —  %@/tools", _mcp.baseURL, _mcp.baseURL];
        _mcpStatus.textColor = [FSStyle output];
    } else {
        _mcpStatus.stringValue = @"○ stopped";
        _mcpStatus.textColor = [FSStyle labelDim];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - MCP registration (every setting + every output)

- (void)_setupMCP {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    int port = (int)[ud integerForKey:@"mcpPort"]; if (port == 0) port = 7777;
    BOOL enabled = [ud objectForKey:@"mcpEnabled"] ? [ud boolForKey:@"mcpEnabled"] : YES;

    _mcp = [[FSControlServer alloc] initWithPort:(uint16_t)port];
    _portField.stringValue = [NSString stringWithFormat:@"%d", port];
    _mcpEnable.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;

    __weak typeof(self) ws = self;
    #define STRONG MainWindowController *s = ws; if (!s) return @{};

    // ---- telemetry frame (the /stream SSE + /data) ----
    [_mcp setTelemetryProvider:^id(NSDictionary *q) { (void)q;
        STRONG; return s->_fly ? [s->_fly telemetry] : @{}; }];

    // ---- TOOLS (every option) ----
    [_mcp registerTool:@"run" doc:@"Start the 1 ms biological clock." handler:^id(NSDictionary *p, NSString **e){
        (void)p;(void)e; STRONG; [s->_fly start]; [s _syncTransportUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"stop" doc:@"Pause the clock (state retained)." handler:^id(NSDictionary *p, NSString **e){
        (void)p;(void)e; STRONG; [s->_fly stop]; [s _syncTransportUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"reset" doc:@"Zero membrane state and release all clamps." handler:^id(NSDictionary *p, NSString **e){
        (void)p;(void)e; STRONG; [s _reset:nil]; [s _syncStimUI]; [s _syncTransportUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"release_all" doc:@"Release every sensory clamp." handler:^id(NSDictionary *p, NSString **e){
        (void)p;(void)e; STRONG;
        for (NSString *nm in s->_senseBtns) [s->_fly setValue:@0 forKey:[nm stringByAppendingString:@"Hz"]];
        [s _syncStimUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"step" doc:@"Advance k 1ms steps while paused (deterministic). params: {k:int}" handler:^id(NSDictionary *p, NSString **e){
        STRONG; if (s->_fly.running) { *e = @"cannot step while running; call stop first"; return nil; }
        [s->_fly stepK:(int)[p[@"k"] integerValue]]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"clamp" doc:@"Clamp one sense to a rate (Hz). params: {modality:'sugar'|'water'|'bitter'|'smell'|'touch'|'heat'|'humidity'|'light', hz:float}" handler:^id(NSDictionary *p, NSString **e){
        STRONG; NSString *m = [p[@"modality"] lowercaseString]; float hz = [p[@"hz"] floatValue];
        FSButton *btn = s->_senseBtns[m ?: @""];
        if (!btn) { *e = @"modality must be one of: sugar water bitter smell touch heat humidity light"; return nil; }
        [s->_fly setValue:@(hz) forKey:[m stringByAppendingString:@"Hz"]];
        btn.isOn = hz > 0; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"stimulus" doc:@"Toggle senses on/off at the master clamp rate. params: any of {sugar,water,bitter,smell,touch,heat,humidity,light}:bool" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG;
        for (NSString *nm in s->_senseBtns) if (p[nm]) s->_senseBtns[nm].isOn = [p[nm] boolValue];
        [s _applyStim]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"clamp_set" doc:@"Clamp ANY population by name to a rate (Hz, 0 releases). params: {kind:'modality'|'superclass'|'celltype', name:string, side:-1|0|1, hz:float}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; int side = p[@"side"] ? [p[@"side"] intValue] : -1;
        return [s->_fly clampKind:(p[@"kind"]?:@"modality") name:(p[@"name"]?:@"")
                              side:side hz:[p[@"hz"] floatValue]]; }];
    [_mcp registerTool:@"read_set" doc:@"Mean firing rate (Hz) of ANY population. params: {kind:'modality'|'superclass'|'celltype', name:string, side:-1|0|1}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; int side = p[@"side"] ? [p[@"side"] intValue] : -1;
        return [s->_fly readKind:(p[@"kind"]?:@"modality") name:(p[@"name"]?:@"") side:side]; }];
    [_mcp registerTool:@"strength" doc:@"Set the master clamp rate (Hz) applied by stimulus toggles. params: {hz:float}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; double hz = [p[@"hz"] doubleValue];
        s->_strength.doubleValue = hz; [s _strengthChanged:s->_strength]; return @{@"hz":@(hz)}; }];
    [_mcp registerTool:@"backend" doc:@"Select compute backend. params: {use:'cpu'|'gpu'}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; BOOL gpu = [p[@"use"] isEqualToString:@"gpu"];
        s->_backendSeg.selectedSegment = gpu ? 1 : 0; [s _backendChanged:s->_backendSeg];
        return @{@"backend": s->_fly.usingGPU ? @"gpu" : @"cpu",
                 @"note": gpu && !s->_fly.usingGPU ? @"Metal backend pending; running CPU" : @""}; }];
    [_mcp registerTool:@"speed" doc:@"Set sim speed cap. params: {x:float}  (1.0=real time @1ms tick; <=0 or 'max'=unthrottled)" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; id xv = p[@"x"];
        double x = [xv isKindOfClass:[NSString class]] ? ([xv isEqualToString:@"max"] ? -1 : [xv doubleValue]) : [xv doubleValue];
        s->_fly.speed = x;
        NSInteger idx = (x<=0)?4 : (x>=8?3 : (x>=4?2 : (x>=2?1:0)));
        [s->_speedSel selectItemAtIndex:idx];
        return @{@"speed": x<=0 ? @"max" : @(x)}; }];
    [_mcp registerTool:@"eventdriven" doc:@"Toggle event-driven scatter (bit-exact, faster on the sparse real brain). params: {on:bool}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_fly.eventDriven = [p[@"on"] boolValue];
        return @{@"eventdriven": @(s->_fly.eventDriven)}; }];
    [_mcp registerTool:@"food" doc:@"Place/remove a sugar droplet in front of the proboscis. When the labellum reaches it, the fly self-sustains the sugar clamp (closed feeding loop). params: {on:bool}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_foodBtn.isOn = [p[@"on"] boolValue]; [s _foodToggled:nil];
        return @{@"food": @(s->_foodBtn.isOn)}; }];
    [_mcp registerTool:@"smell_lr" doc:@"Clamp the LEFT and RIGHT olfactory ORNs separately (Hz) — bilateral input for the 3D flight loop. params: {left:float, right:float}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_fly.smellLeftHz = [p[@"left"] floatValue]; s->_fly.smellRightHz = [p[@"right"] floatValue];
        return @{@"left":@(s->_fly.smellLeftHz), @"right":@(s->_fly.smellRightHz)}; }];
    [_mcp registerTool:@"light_lr" doc:@"Clamp the LEFT and RIGHT eye photoreceptors separately (Hz) — bilateral visual target fixation. params: {left:float, right:float}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_fly.lightLeftHz = [p[@"left"] floatValue]; s->_fly.lightRightHz = [p[@"right"] floatValue];
        return @{@"left":@(s->_fly.lightLeftHz), @"right":@(s->_fly.lightRightHz)}; }];
    [_mcp registerTool:@"sample_rate" doc:@"Set UI sampler rate (does not affect 1ms sim tick). params: {hz:60|90|120}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_sampleHz = [p[@"hz"] doubleValue] ?: 60; [s _installTimer];
        [s->_rateSel selectItemWithTitle:[NSString stringWithFormat:@"%.0f Hz", s->_sampleHz]];
        return @{@"sample_hz":@(s->_sampleHz)}; }];

    // ---- DATA (every output, realtime) ----
    [_mcp registerData:@"/data" doc:@"Full telemetry frame: all scalar outputs + region rates + clamps." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly telemetry]; }];
    [_mcp registerData:@"/data/model" doc:@"Model facts: neuron/edge counts, named sets, LIF params." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly modelInfo]; }];
    [_mcp registerData:@"/data/regions" doc:@"Mean firing rate (Hz) per labelled circuit: sugar/water/bitter/feeding/mn9." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly regionRates]; }];
    [_mcp registerData:@"/data/sensory" doc:@"Every sensory input, mean Hz: sugar/water/bitter/smell/touch/heat/humidity/light." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly sensoryRates]; }];
    [_mcp registerData:@"/data/motor" doc:@"Every motor output, mean Hz: mn9/feeding/motor/descending." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly motorRates]; }];
    [_mcp registerData:@"/data/populations" doc:@"Discovery: every named clampable/readable population + size." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly populations]; }];
    [_mcp registerData:@"/data/steering" doc:@"Bilateral descending-neuron output (the brain's steering command): left/right mean Hz + turn signal (right-left)." provider:^id(NSDictionary *q){ (void)q; STRONG;
        float dl=0, dr=0; [s->_fly descendingLeft:&dl right:&dr];
        FlySnapshot sn = [s->_fly snapshot];
        return @{ @"dn_left_hz":@(dl), @"dn_right_hz":@(dr), @"turn":@(dr-dl),
                  @"thrust":@((dl+dr)*0.5f), @"dn_left_n":@(s->_fly.dnLeftSize), @"dn_right_n":@(s->_fly.dnRightSize),
                  @"steer_left_hz":@(sn.steerLeftRate), @"steer_right_hz":@(sn.steerRightRate),
                  @"steer_turn":@(sn.steerLeftRate - sn.steerRightRate),
                  @"escape_left_hz":@(sn.escLeftRate), @"escape_right_hz":@(sn.escRightRate),
                  @"escape_turn":@(sn.escLeftRate - sn.escRightRate) }; }];
    [_mcp registerData:@"/data/behavior" doc:@"The animated fly's visible state: MN9 Hz, proboscis deg + extension, walking, arrived-at-food, labellum contact, food, feeding." provider:^id(NSDictionary *q){ (void)q; STRONG;
        BOOL feeding = s->_foodBtn.isOn && s->_flyView.arrivedAtFood;
        return @{ @"mn9_hz": @(s->_fly ? [s->_fly snapshot].mn9Rate : 0),
                  @"proboscis_deg": @(s->_proboscisAngle),
                  @"extension": @(s->_proboscisAngle / MAX_EXT_DEG),
                  @"smell_drive": @(s->_flyView.smellDrive),
                  @"walking": @(!s->_flyView.arrivedAtFood && s->_foodBtn.isOn && s->_flyView.smellDrive > 0.1),
                  @"arrived": @(s->_flyView.arrivedAtFood),
                  @"contact": @(s->_flyView.labellumContact),
                  @"food": @(s->_foodBtn.isOn),
                  @"feeding": @(feeding) }; }];
    [_mcp registerData:@"/data/bins" doc:@"128-bin spatial firing-rate histogram (the activity strip)." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly bins]; }];
    [_mcp registerData:@"/data/rates" doc:@"Per-neuron smoothed rate (Hz). query: ?from&to&stride (to=0=>all)." provider:^id(NSDictionary *q){
        STRONG; return [s->_fly ratesFrom:[q[@"from"] integerValue] to:[q[@"to"] integerValue]
                            stride:[q[@"stride"] integerValue]]; }];
    [_mcp registerData:@"/data/spikes" doc:@"Per-neuron spike flags (last step). query: ?from&to&stride." provider:^id(NSDictionary *q){
        STRONG; return [s->_fly spikesFrom:[q[@"from"] integerValue] to:[q[@"to"] integerValue]
                             stride:[q[@"stride"] integerValue]]; }];
    #undef STRONG

    if (enabled) [self _startMCP];
    [self _refreshMCPStatus];
}

- (void)windowWillClose:(NSNotification *)n {
    [_uiTimer invalidate]; _uiTimer = nil;
    [_mcp stop];
    [_fly stop];
}
@end
