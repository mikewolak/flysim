//  MainWindowController.m — the Logic-Pro-styled FlySim panel.

#import "MainWindowController.h"
#import "FlyController.h"
#import "FSWidgets.h"
#import "FSControlServer.h"

// proboscis mapping (§8.1) — synthetic MN9 runs hot, so scale to its range
#define R_LO   8.0f
#define R_HI   180.0f
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

    FSButton *_sugarBtn, *_waterBtn, *_bitterBtn;
    NSSlider *_strength;
    NSTextField *_strengthLabel;

    FSActivityView *_activity;
    FSMeter *_mn9Meter, *_sugarMeter, *_l2Meter, *_proboscisMeter;
    NSTextField *_mn9Hz, *_proboscisDeg;

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
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 940, 624);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                  backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:win])) return nil;

    win.title = @"FlySim — Connectome Reflex";
    win.titlebarAppearsTransparent = YES;
    win.titleVisibility = NSWindowTitleHidden;
    win.minSize = NSMakeSize(860, 560);
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

    CGFloat top = 64, pad = 16, botH = 132;

    // ---- stimulus panel (left) -------------------------------------------
    _stimPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad, top, 224, H - top - botH - pad)];
    _stimPanel.title = @"Stimulus  ·  Afferent clamp";
    _stimPanel.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    [root addSubview:_stimPanel];
    [self _fillStimPanel:_stimPanel];

    // ---- activity heatmap (center, fills) --------------------------------
    _brainPanel = [[FSPanel alloc] initWithFrame:
        NSMakeRect(pad+224+12, top, W - (pad+224+12) - pad, H - top - botH - pad)];
    _brainPanel.title = @"Population activity  ·  firing rate";
    _brainPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_brainPanel];

    _activity = [[FSActivityView alloc] initWithFrame:
        NSMakeRect(10, 30, _brainPanel.bounds.size.width-20,
                   _brainPanel.bounds.size.height-40)];
    _activity.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_brainPanel addSubview:_activity];

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
        _sugarBtn.isOn = YES; [self _applyStim];
    }
    if (getenv("FLYSIM_SHOW_SETTINGS")) [self _toggleSettings:nil];
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

- (void)_fillStimPanel:(FSPanel *)p {
    CGFloat w = p.bounds.size.width - 28, x = 14, y = 38;

    _sugarBtn  = [self _stim:@"SUGAR"  sub:@"gustatory · appetitive"
                        tint:[FSStyle sugar]  at:NSMakeRect(x,y,w,52)];
    _waterBtn  = [self _stim:@"WATER"  sub:@"gustatory · shares path"
                        tint:[FSStyle water]  at:NSMakeRect(x,y+62,w,52)];
    _bitterBtn = [self _stim:@"BITTER" sub:@"aversive · GABA veto"
                        tint:[FSStyle bitter] at:NSMakeRect(x,y+124,w,52)];
    [p addSubview:_sugarBtn]; [p addSubview:_waterBtn]; [p addSubview:_bitterBtn];

    NSTextField *sl = [NSTextField labelWithString:@"CLAMP RATE"];
    sl.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    sl.textColor = [FSStyle labelDim];
    sl.frame = NSMakeRect(x, y+196, w, 14);
    [p addSubview:sl];

    _strength = [NSSlider sliderWithValue:150 minValue:0 maxValue:200
                                    target:self action:@selector(_strengthChanged:)];
    _strength.frame = NSMakeRect(x, y+212, w, 22);
    [p addSubview:_strength];

    _strengthLabel = [NSTextField labelWithString:@"150 Hz"];
    _strengthLabel.font = [FSStyle mono:11 weight:NSFontWeightMedium];
    _strengthLabel.textColor = [FSStyle label];
    _strengthLabel.frame = NSMakeRect(x, y+236, w, 16);
    [p addSubview:_strengthLabel];
}

- (FSButton *)_stim:(NSString *)label sub:(NSString *)sub tint:(NSColor *)tint
                 at:(NSRect)f {
    FSButton *b = [[FSButton alloc] initWithFrame:f];
    b.label = label; b.sublabel = sub; b.tint = tint;
    b.target = self; b.action = @selector(_stimToggled:);
    return b;
}

- (void)_fillOutputPanel:(FSPanel *)p {
    CGFloat W = p.bounds.size.width;

    // three non-overlapping columns:
    //   col1 (left, fixed)   MN9 meter + big Hz
    //   col2 (center, flex)  proboscis meter + degrees
    //   col3 (right, fixed)  small input meters
    const CGFloat C1 = 14;          // col1 left
    const CGFloat C1W = 300;        // col1 width
    const CGFloat C3W = 240;        // col3 width
    const CGFloat C3 = W - 14 - C3W;// col3 left (sticks to right edge)
    const CGFloat C2 = C1 + C1W + 28;
    const CGFloat C2W = C3 - 24 - C2;

    // --- col1: MN9 ---
    NSTextField *mn9cap = [NSTextField labelWithString:@"MN9 FIRING RATE"];
    mn9cap.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    mn9cap.textColor = [FSStyle labelDim];
    mn9cap.frame = NSMakeRect(C1, 34, 200, 14);
    [p addSubview:mn9cap];

    _mn9Meter = [[FSMeter alloc] initWithFrame:NSMakeRect(C1, 52, C1W, 26)];
    _mn9Meter.tint = [FSStyle output];
    _mn9Meter.autoresizingMask = NSViewMaxXMargin;     // fixed width, left-anchored
    [p addSubview:_mn9Meter];

    _mn9Hz = [NSTextField labelWithString:@"0.0 Hz"];
    _mn9Hz.font = [FSStyle mono:22 weight:NSFontWeightBold];
    _mn9Hz.textColor = [FSStyle output];
    _mn9Hz.frame = NSMakeRect(C1, 80, C1W, 26);
    _mn9Hz.autoresizingMask = NSViewMaxXMargin;
    [p addSubview:_mn9Hz];

    // --- col2: proboscis (absorbs window resize) ---
    NSTextField *pcap = [NSTextField labelWithString:@"PROBOSCIS EXTENSION"];
    pcap.font = [FSStyle mono:9 weight:NSFontWeightSemibold];
    pcap.textColor = [FSStyle labelDim];
    pcap.frame = NSMakeRect(C2, 34, 220, 14);
    pcap.autoresizingMask = NSViewWidthSizable;
    [p addSubview:pcap];

    _proboscisMeter = [[FSMeter alloc] initWithFrame:NSMakeRect(C2, 52, C2W, 26)];
    _proboscisMeter.tint = [FSStyle sugar];
    _proboscisMeter.autoresizingMask = NSViewWidthSizable;
    [p addSubview:_proboscisMeter];

    _proboscisDeg = [NSTextField labelWithString:@"0°"];
    _proboscisDeg.font = [FSStyle mono:22 weight:NSFontWeightBold];
    _proboscisDeg.textColor = [FSStyle sugar];
    _proboscisDeg.frame = NSMakeRect(C2, 80, 120, 26);
    _proboscisDeg.autoresizingMask = NSViewWidthSizable;
    [p addSubview:_proboscisDeg];

    // --- col3: small input meters (fixed width, right-anchored) ---
    _sugarMeter = [[FSMeter alloc] initWithFrame:NSMakeRect(C3, 52, C3W, 16)];
    _sugarMeter.tint = [FSStyle sugar]; _sugarMeter.caption = @"sugar in";
    _sugarMeter.autoresizingMask = NSViewMinXMargin;
    [p addSubview:_sugarMeter];

    _l2Meter = [[FSMeter alloc] initWithFrame:NSMakeRect(C3, 86, C3W, 16)];
    _l2Meter.tint = [FSStyle water]; _l2Meter.caption = @"feeding interneurons";
    _l2Meter.autoresizingMask = NSViewMinXMargin;
    [p addSubview:_l2Meter];
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
- (void)_stimToggled:(id)s { [self _applyStim]; }

- (void)_applyStim {
    if (!_fly) return;
    float hz = (float)_strength.doubleValue;
    _fly.sugarHz  = _sugarBtn.isOn  ? hz : 0;
    _fly.waterHz  = _waterBtn.isOn  ? hz : 0;
    _fly.bitterHz = _bitterBtn.isOn ? hz : 0;
}

// ---------------------------------------------------------------------------
#pragma mark - 30 Hz UI sampler

- (void)_tick {
    if (!_fly) return;
    FlySnapshot s = [_fly snapshot];

    [_activity pushBins:s.bins count:FS_BINS ceiling:120.0f];

    _mn9Meter.value   = MIN(1.0, s.mn9Rate / 200.0f);
    _sugarMeter.value = MIN(1.0, s.sugarRate / 200.0f);
    _l2Meter.value    = MIN(1.0, s.l2Rate / 200.0f);
    _mn9Hz.stringValue = [NSString stringWithFormat:@"%.1f Hz", s.mn9Rate];

    // rate -> proboscis extension (§8.1), critically-damped follow
    float ext = (s.mn9Rate - R_LO) / (R_HI - R_LO);
    ext = ext < 0 ? 0 : (ext > 1 ? 1 : ext);
    float target = ext * MAX_EXT_DEG;
    _proboscisAngle += (target - _proboscisAngle) * 0.18f;   // damp
    _proboscisMeter.value = _proboscisAngle / MAX_EXT_DEG;
    _proboscisDeg.stringValue = [NSString stringWithFormat:@"%.0f°", _proboscisAngle];

    // illuminate stim buttons by how hard their circuit is actually firing
    _sugarBtn.glow  = MIN(1.0, s.sugarRate  / 150.0f);
    _waterBtn.glow  = MIN(1.0, s.waterRate  / 150.0f);
    _bitterBtn.glow = MIN(1.0, s.bitterRate / 150.0f);

    _statusRight.stringValue = [NSString stringWithFormat:
        @"%@   sim %.2fs   %.0f steps/s   %.2f× realtime   %u spk/step",
        _fly.usingGPU ? @"GPU" : @"CPU",
        s.simTime, s.stepsPerSec, s.realtimeFactor, s.lastSpikes];
}

// ---------------------------------------------------------------------------
#pragma mark - UI sync (so MCP-driven changes reflect in the panel)

- (void)_syncStimUI {
    _sugarBtn.isOn  = _fly.sugarHz  > 0;
    _waterBtn.isOn  = _fly.waterHz  > 0;
    _bitterBtn.isOn = _fly.bitterHz > 0;
}
- (void)_syncTransportUI {
    _runBtn.title = _fly.running ? @"■  STOP" : @"▶  RUN";
}

// ---------------------------------------------------------------------------
#pragma mark - Settings tab

- (void)_toggleSettings:(id)s {
    BOOL show = _settingsPanel.hidden;
    _settingsPanel.hidden = !show;
    _stimPanel.hidden = _brainPanel.hidden = _outPanel.hidden = show;
    _settingsBtn.title = show ? @"⚙ CLOSE" : @"⚙ SETTINGS";
    if (show) [self _refreshMCPStatus];
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
      @"curl 127.0.0.1:7777/data                        # all live outputs\n"
      @"curl -XPOST 127.0.0.1:7777/tool/run             # start the clock\n"
      @"curl -XPOST 127.0.0.1:7777/tool/clamp -d '{\"modality\":\"sugar\",\"hz\":150}'\n"
      @"curl -XPOST 127.0.0.1:7777/tool/step  -d '{\"k\":200}'   # paused, deterministic\n"
      @"curl 127.0.0.1:7777/data/regions                # sugar/feeding/MN9 Hz\n"
      @"curl -N 127.0.0.1:7777/stream?hz=60             # watch outputs live (SSE)";
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(x, y, w, 150)];
    tv.string = ex; tv.editable = NO; tv.drawsBackground = YES;
    tv.backgroundColor = [NSColor colorWithWhite:0 alpha:0.35];
    tv.textColor = [FSStyle water];
    tv.font = [FSStyle mono:11 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewWidthSizable;
    [p addSubview:tv];
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
    [_mcp registerTool:@"release_all" doc:@"Release every stimulus clamp." handler:^id(NSDictionary *p, NSString **e){
        (void)p;(void)e; STRONG; s->_fly.sugarHz=s->_fly.waterHz=s->_fly.bitterHz=0; [s _syncStimUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"step" doc:@"Advance k 1ms steps while paused (deterministic). params: {k:int}" handler:^id(NSDictionary *p, NSString **e){
        STRONG; if (s->_fly.running) { *e = @"cannot step while running; call stop first"; return nil; }
        [s->_fly stepK:(int)[p[@"k"] integerValue]]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"clamp" doc:@"Clamp one modality to a rate. params: {modality:'sugar'|'water'|'bitter', hz:float}" handler:^id(NSDictionary *p, NSString **e){
        STRONG; NSString *m = p[@"modality"]; float hz = [p[@"hz"] floatValue];
        if ([m isEqualToString:@"sugar"]) s->_fly.sugarHz = hz;
        else if ([m isEqualToString:@"water"]) s->_fly.waterHz = hz;
        else if ([m isEqualToString:@"bitter"]) s->_fly.bitterHz = hz;
        else { *e = @"modality must be sugar|water|bitter"; return nil; }
        [s _syncStimUI]; return [s->_fly telemetry]; }];
    [_mcp registerTool:@"stimulus" doc:@"Toggle modalities at the current clamp rate. params: {sugar:bool,water:bool,bitter:bool}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; float hz = (float)s->_strength.doubleValue;
        if (p[@"sugar"])  s->_fly.sugarHz  = [p[@"sugar"] boolValue]  ? hz : 0;
        if (p[@"water"])  s->_fly.waterHz  = [p[@"water"] boolValue]  ? hz : 0;
        if (p[@"bitter"]) s->_fly.bitterHz = [p[@"bitter"] boolValue] ? hz : 0;
        [s _syncStimUI]; return [s->_fly telemetry]; }];
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
    [_mcp registerTool:@"sample_rate" doc:@"Set UI sampler rate (does not affect 1ms sim tick). params: {hz:60|90|120}" handler:^id(NSDictionary *p, NSString **e){
        (void)e; STRONG; s->_sampleHz = [p[@"hz"] doubleValue] ?: 60; [s _installTimer];
        [s->_rateSel selectItemWithTitle:[NSString stringWithFormat:@"%.0f Hz", s->_sampleHz]];
        return @{@"sample_hz":@(s->_sampleHz)}; }];

    // ---- DATA (every output, realtime) ----
    [_mcp registerData:@"/data" doc:@"Full telemetry frame: all scalar outputs + region rates + clamps." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly telemetry]; }];
    [_mcp registerData:@"/data/model" doc:@"Model facts: neuron/edge counts, named sets, LIF params." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly modelInfo]; }];
    [_mcp registerData:@"/data/regions" doc:@"Mean firing rate (Hz) per labelled circuit: sugar/water/bitter/feeding/mn9." provider:^id(NSDictionary *q){ (void)q; STRONG; return [s->_fly regionRates]; }];
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
