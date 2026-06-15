// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FSWidgets.m

#import "FSWidgets.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *RGB(double r, double g, double b) {
    return [NSColor colorWithSRGBRed:r/255 green:g/255 blue:b/255 alpha:1];
}

@implementation FSStyle
+ (NSColor *)windowTop    { return RGB(46, 47, 51); }
+ (NSColor *)windowBottom { return RGB(28, 29, 32); }
+ (NSColor *)panelFill    { return RGB(36, 37, 41); }
+ (NSColor *)panelStroke  { return [NSColor colorWithWhite:1 alpha:0.07]; }
+ (NSColor *)label        { return RGB(214, 216, 222); }
+ (NSColor *)labelDim     { return RGB(130, 133, 142); }
+ (NSColor *)sugar        { return RGB(255, 179, 64);  }
+ (NSColor *)water        { return RGB(56, 199, 255);  }
+ (NSColor *)bitter       { return RGB(255, 86, 86);   }
+ (NSColor *)output       { return RGB(60, 230, 130);  }
+ (NSFont *)mono:(CGFloat)size weight:(NSFontWeight)w {
    return [NSFont monospacedSystemFontOfSize:size weight:w];
}
@end

// ===========================================================================
@implementation FSPanel
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1, 1)
                                                      xRadius:8 yRadius:8];
    [[FSStyle panelFill] setFill];
    [p fill];
    // top highlight
    NSGradient *g = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1 alpha:0.05], [NSColor colorWithWhite:1 alpha:0.0]]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2,2,b.size.width-4,28)
                                                        xRadius:7 yRadius:7] angle:90];
    [[FSStyle panelStroke] setStroke];
    p.lineWidth = 1; [p stroke];

    if (_title.length) {
        NSDictionary *a = @{ NSFontAttributeName: [FSStyle mono:10 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: [FSStyle labelDim],
                             NSKernAttributeName: @1.5 };
        [[_title uppercaseString] drawAtPoint:NSMakePoint(14, 10) withAttributes:a];
    }
}
- (void)setTitle:(NSString *)t { _title = [t copy]; self.needsDisplay = YES; }
@end

// ===========================================================================
@implementation FSButton
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) { _tint = [FSStyle output]; _glow = 0; }
    return self;
}
- (void)mouseDown:(NSEvent *)e {
    if (_momentary) { _isOn = YES; [self sendAction:self.action to:self.target];
        self.needsDisplay = YES; return; }
    _isOn = !_isOn; self.needsDisplay = YES;
    [self sendAction:self.action to:self.target];
}
- (void)mouseUp:(NSEvent *)e {
    if (_momentary) { _isOn = NO; [self sendAction:self.action to:self.target];
        self.needsDisplay = YES; }
}
- (void)setIsOn:(BOOL)on { _isOn = on; self.needsDisplay = YES; }
- (void)setGlow:(CGFloat)g { _glow = g; if (_isOn) self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect b = NSInsetRect(self.bounds, 2, 2);
    CGFloat rad = 9;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:rad yRadius:rad];

    if (_isOn) {
        CGFloat lit = 0.45 + 0.55 * MIN(1.0, _glow);
        NSColor *c0 = [_tint blendedColorWithFraction:0.55 ofColor:[NSColor blackColor]];
        NSColor *c1 = [_tint colorWithAlphaComponent:1.0];
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:
            [c0 colorWithAlphaComponent:1.0] endingColor:c1];
        [g drawInBezierPath:p angle:90];
        // inner glow proportional to firing
        [[_tint colorWithAlphaComponent:0.25 + 0.4*lit] setStroke];
        p.lineWidth = 2 + 2*lit; [p stroke];
    } else {
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
            RGB(58,60,66), 0.0, RGB(40,42,47), 1.0, nil];
        [g drawInBezierPath:p angle:90];
        [[NSColor colorWithWhite:0 alpha:0.4] setStroke];
        p.lineWidth = 1; [p stroke];
    }

    // LED dot
    NSRect led = NSMakeRect(b.origin.x+10, b.origin.y+b.size.height/2-4, 8, 8);
    NSBezierPath *lp = [NSBezierPath bezierPathWithOvalInRect:led];
    [(_isOn ? [_tint blendedColorWithFraction:0.1 ofColor:NSColor.whiteColor]
            : RGB(30,31,35)) setFill];
    [lp fill];

    NSColor *txt = _isOn ? [NSColor colorWithWhite:0.06 alpha:1]
                         : [FSStyle label];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    if (_label.length) {
        NSDictionary *a = @{ NSFontAttributeName:[FSStyle mono:13 weight:NSFontWeightBold],
                             NSForegroundColorAttributeName:txt,
                             NSParagraphStyleAttributeName:ps };
        CGFloat ty = _sublabel.length ? b.origin.y+b.size.height/2-13
                                      : b.origin.y+b.size.height/2-9;
        [_label drawInRect:NSMakeRect(b.origin.x+18, ty, b.size.width-24, 20)
            withAttributes:a];
    }
    if (_sublabel.length) {
        NSDictionary *a = @{ NSFontAttributeName:[FSStyle mono:9 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName:
                                [txt colorWithAlphaComponent:0.7],
                             NSParagraphStyleAttributeName:ps };
        [_sublabel drawInRect:NSMakeRect(b.origin.x+18, b.origin.y+b.size.height/2+4,
                                         b.size.width-24, 14) withAttributes:a];
    }
}
@end

// ===========================================================================
@implementation FSMeter {
    CGFloat _peak; NSDate *_peakAt;
}
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) _tint = [FSStyle output];
    return self;
}
- (void)setValue:(CGFloat)v {
    v = MAX(0, MIN(1, v));
    _value = v;
    if (v >= _peak) { _peak = v; _peakAt = [NSDate date]; }
    else if (_peakAt && [[NSDate date] timeIntervalSinceDate:_peakAt] > 0.8)
        _peak = MAX(v, _peak - 0.02);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    CGFloat capH = _caption.length ? 14 : 0;
    NSRect track = NSMakeRect(0, capH, b.size.width, b.size.height - capH);

    [[NSColor colorWithWhite:0 alpha:0.35] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3] fill];

    int segs = (int)(track.size.width / 5);
    CGFloat segW = track.size.width / segs;
    int lit = (int)(_value * segs + 0.5);
    int peakSeg = (int)(_peak * segs + 0.5);
    for (int i = 0; i < segs; i++) {
        NSRect s = NSMakeRect(track.origin.x + i*segW + 1, track.origin.y + 2,
                              segW - 2, track.size.height - 4);
        CGFloat frac = (CGFloat)i / segs;
        NSColor *c;
        if (frac < 0.6)      c = [FSStyle output];
        else if (frac < 0.85) c = [FSStyle sugar];
        else                  c = [FSStyle bitter];
        if (i < lit)        [[c colorWithAlphaComponent:0.95] setFill];
        else if (i==peakSeg)[[c colorWithAlphaComponent:0.6] setFill];
        else                [[c colorWithAlphaComponent:0.10] setFill];
        [[NSBezierPath bezierPathWithRect:s] fill];
    }
    if (_caption.length) {
        NSDictionary *a = @{ NSFontAttributeName:[FSStyle mono:9 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName:[FSStyle labelDim] };
        [[_caption uppercaseString] drawAtPoint:NSMakePoint(1,1) withAttributes:a];
    }
}
@end

// ===========================================================================
// inferno-ish colormap: t in 0..1 -> rgb
static void heat(float t, uint8_t *r, uint8_t *g, uint8_t *b) {
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    // piecewise: black -> deep purple -> magenta -> orange -> yellow-white
    const float stops[6][3] = {
        {  0,  0,  4},{ 40, 11, 84},{120, 28,109},
        {190, 55, 80},{236,121, 35},{252,255,164}};
    float x = t * 5.0f; int i = (int)x; if (i > 4) i = 4;
    float f = x - i;
    *r = (uint8_t)(stops[i][0] + f*(stops[i+1][0]-stops[i][0]));
    *g = (uint8_t)(stops[i][1] + f*(stops[i+1][1]-stops[i][1]));
    *b = (uint8_t)(stops[i][2] + f*(stops[i+1][2]-stops[i][2]));
}

@implementation FSActivityView {
    int     _cols, _rows;
    float  *_hist;     // _cols * _rows, column-major ring
    int     _head;     // next column to write
    uint8_t *_rgba;    // _cols * _rows * 4 scratch
    NSArray<NSDictionary *> *_marks;   // per-sense row markers
}
- (void)setSenseMarks:(NSArray<NSDictionary *> *)marks { _marks = marks; }
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _cols = 600; _rows = 128;
        _hist = calloc(_cols*_rows, sizeof(float));
        _rgba = calloc(_cols*_rows, 4);
        self.wantsLayer = YES;
    }
    return self;
}
- (void)dealloc { free(_hist); free(_rgba); }
- (void)clearHistory {
    memset(_hist, 0, _cols*_rows*sizeof(float));
    self.needsDisplay = YES;
}
- (void)pushBins:(const float *)bins count:(int)n ceiling:(float)ceilHz {
    if (ceilHz <= 0) ceilHz = 1;
    for (int y = 0; y < _rows; y++) {
        int src = (int)((long)y * n / _rows);
        float v = bins[src] / ceilHz;
        _hist[y*_cols + _head] = v;
    }
    _head = (_head + 1) % _cols;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [[NSColor colorWithWhite:0 alpha:1] setFill];
    NSRectFill(b);

    // build RGBA image: oldest column on the left, newest on the right
    for (int x = 0; x < _cols; x++) {
        int col = (_head + x) % _cols;     // x=0 -> oldest
        for (int y = 0; y < _rows; y++) {
            float v = _hist[y*_cols + col];
            // gamma for punchier lows
            float t = powf(v, 0.6f);
            uint8_t r,g,bb; heat(t, &r,&g,&bb);
            uint8_t *px = &_rgba[(y*_cols + x)*4];
            px[0]=r; px[1]=g; px[2]=bb; px[3]=255;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bmp = CGBitmapContextCreate(_rgba, _cols, _rows, 8, _cols*4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(bmp);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    // flipped view: draw with vertical flip so bin 0 sits at the bottom
    CGContextTranslateCTM(ctx, 0, b.size.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0,0,b.size.width,b.size.height), img);
    CGContextRestoreGState(ctx);

    CGImageRelease(img); CGContextRelease(bmp); CGColorSpaceRelease(cs);

    // ---- per-sense row markers: a colored wedge + tag on the left gutter at the
    //      heat-bin where that sense's neurons sit; it glows when the sense fires,
    //      so you can see exactly which rows of the brain light up. ------------
    for (NSDictionary *m in _marks) {
        CGFloat f = [m[@"y"] doubleValue];                 // 0..1, bin 0 at bottom
        CGFloat glow = [m[@"glow"] doubleValue];
        NSColor *c = m[@"color"];
        CGFloat y = b.size.height * (1.0 - f);             // flipped: y down from top
        BOOL active = glow > 0.15;
        // wedge tab on the left gutter — bright when the sense is firing
        NSBezierPath *wedge = [NSBezierPath bezierPath];
        [wedge moveToPoint:CGPointMake(0, y-5)];
        [wedge lineToPoint:CGPointMake(10 + 8*glow, y)];
        [wedge lineToPoint:CGPointMake(0, y+5)];
        [wedge closePath];
        [[c colorWithAlphaComponent:0.35 + 0.65*glow] setFill]; [wedge fill];
        if (active) {                                      // full-width band + label chip
            [[c colorWithAlphaComponent:0.22 + 0.45*glow] setStroke];
            NSBezierPath *ln = [NSBezierPath bezierPath];
            [ln moveToPoint:CGPointMake(0,y)]; [ln lineToPoint:CGPointMake(b.size.width,y)];
            ln.lineWidth = 1.5; [ln stroke];
            NSString *lbl = m[@"label"];
            NSDictionary *attr = @{ NSFontAttributeName:[FSStyle mono:10 weight:NSFontWeightHeavy],
                                    NSForegroundColorAttributeName:c,
                                    NSStrokeColorAttributeName:[NSColor colorWithWhite:0 alpha:0.9],
                                    NSStrokeWidthAttributeName:@(-4.0) };   // dark outline for contrast
            NSSize ls = [lbl sizeWithAttributes:attr];
            [lbl drawAtPoint:CGPointMake(22, y - ls.height/2) withAttributes:attr];
        }
    }

    // subtle scanline frame
    [[FSStyle panelStroke] setStroke];
    NSBezierPath *fr = [NSBezierPath bezierPathWithRect:NSInsetRect(b,0.5,0.5)];
    fr.lineWidth = 1; [fr stroke];
}
@end

// ===========================================================================
//  FSFlyView — anatomical lateral fly head doing the Proboscis Extension Reflex
// ===========================================================================
#define DEG (M_PI/180.0)

static inline CGFloat lrp(CGFloat a, CGFloat b, CGFloat t) { return a + (b-a)*t; }
static inline CGPoint padd(CGPoint p, CGFloat ang, CGFloat len) {
    return CGPointMake(p.x + len*cos(ang), p.y + len*sin(ang));
}

// Resolved layout + kinematics for the whole fly, one frame.
typedef struct {
    CGFloat W, H, ground;
    CGPoint abdC;     CGFloat abdRx, abdRy;
    CGPoint thoraxC;  CGFloat thoraxRx, thoraxRy;
    CGPoint headC;    CGFloat headR;
    CGPoint eyeC;     CGFloat eyeR;
    CGPoint antBase;
    CGPoint P0, j1, tip;     CGFloat a1, a2, spread;  // proboscis (2 segments)
    CGPoint foodC;    CGFloat foodR;
    BOOL    contact;
} FlyPose;

// round-cap line segment (used for the proboscis: dark outline + lighter core)
static void seg(CGPoint a, CGPoint b, CGFloat w, NSColor *c) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:a]; [p lineToPoint:b];
    p.lineWidth = w; p.lineCapStyle = NSLineCapStyleRound;
    [c setStroke]; [p stroke];
}
static NSBezierPath *hexAt(CGPoint c, CGFloat r) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    for (int i = 0; i < 6; i++) {
        CGFloat a = (M_PI/3.0)*i + M_PI/6.0;
        CGPoint v = CGPointMake(c.x + r*cos(a), c.y + r*sin(a));
        if (i == 0) [p moveToPoint:v]; else [p lineToPoint:v];
    }
    [p closePath]; return p;
}

@implementation FSFlyView {
    CGFloat _ingest;   // 0..1 smoothed "tongue is on the food" → opens lobes, ripples
    double  _phase;    // idle animation clock (advanced each setExtension)
    CGFloat _bodyX;    // horizontal walk offset (strides toward the food)
    BOOL    _walking;  // currently striding (drives the leg gait)
    CGFloat _facing;   // +1 faces right, -1 faces left (turns toward the food)
    CGFloat _foodX;    // world x of the food (draggable); <0 = use default
    BOOL    _dragFood; // mouse is dragging the droplet
    CGFloat _lastOdor; // previous perceived odor (for klinotaxis: warmer/colder)
    BOOL    _onFood;   // latched once it reaches the drop (hysteresis, so it stays)
    CGFloat _veto, _touchR, _heatR, _lightR, _humidR;  // smoothed reaction levels 0..1
    CGFloat _startle;   // brief decaying touch-startle impulse (habituates when held)
    CGFloat _touchPrev; // for rising-edge detection
    double  _wingPh;   // wing-buzz phase, sped up by the light reaction
}
- (void)setReactBitterVeto:(CGFloat)veto touch:(CGFloat)touch
                      heat:(CGFloat)heat light:(CGFloat)light humid:(CGFloat)humid {
    #define FSCL(v) ((v)<0?0:((v)>1?1:(v)))
    CGFloat t = FSCL(touch);
    if (t > _touchPrev + 0.12) _startle = 1.0;     // a fresh touch → one startle jolt
    _touchPrev += (t - _touchPrev) * 0.15;          // slow track so a held touch habituates
    _veto   += (FSCL(veto)  - _veto)   * 0.25;
    _touchR += (t           - _touchR) * 0.30;
    _heatR  += (FSCL(heat)  - _heatR)  * 0.20;
    _lightR += (FSCL(light) - _lightR) * 0.30;
    _humidR += (FSCL(humid) - _humidR) * 0.20;
    #undef FSCL
}
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _foodPresent = NO; _showLabels = YES; _ingest = 0; _phase = 0;
        _bodyX = 0; _walking = NO; _facing = 1; _foodX = -1; _dragFood = NO;
        self.wantsLayer = YES;
    }
    return self;
}
// food's default drop spot (right) and the fly's home head (left), so there's a
// gap to cross — the fly has to find the food, not start on it.
static CGFloat FoodWorldX(CGFloat W) { return W*0.84; }
static CGFloat BodyHomeHeadX(CGFloat W) { return W*0.50; }

- (void)setFoodPresent:(BOOL)f {
    _foodPresent = f;
    if (f && _foodX < 0) _foodX = FoodWorldX(self.bounds.size.width);  // drop on the right
    self.needsDisplay = YES;
}

// --- grab & move the food anywhere along the ground; the fly re-finds it ------
- (CGFloat)_foodGroundY { return self.bounds.size.height * 0.80; }
- (void)mouseDown:(NSEvent *)e {
    if (!_foodPresent) return;
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat fx = _foodX < 0 ? FoodWorldX(self.bounds.size.width) : _foodX;
    if (hypot(pt.x - fx, pt.y - [self _foodGroundY]) < self.bounds.size.height*0.13)
        _dragFood = YES;
}
- (void)mouseDragged:(NSEvent *)e {
    if (!_dragFood) return;
    NSPoint pt = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat m = self.bounds.size.width * 0.06;
    _foodX = MAX(m, MIN(self.bounds.size.width - m, pt.x));
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)e { (void)e; _dragFood = NO; }

// --- the odor field the food gives off, and where the fly's nose is ----------
- (CGFloat)_centerX { return self.bounds.size.width*0.335 + _bodyX; }
- (CGFloat)_foodWorldX { return _foodX < 0 ? FoodWorldX(self.bounds.size.width) : _foodX; }
- (CGFloat)_noseX {                                   // world x of the antennae
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat headFront = BodyHomeHeadX(W) + _bodyX + H*0.125;   // facing-right local
    return _facing > 0 ? headFront : 2*[self _centerX] - headFront;
}
- (CGFloat)_concAt:(CGFloat)x {                        // Gaussian odor plume, 0..1
    if (!_foodPresent) return 0;
    CGFloat lam = self.bounds.size.width * 0.20;       // plume width
    CGFloat d = (x - [self _foodWorldX]) / lam;
    return exp(-d*d);
}
- (CGFloat)perceivedOdor { return [self _concAt:[self _noseX]]; }

// The controller pushes `extension` every UI frame, so this doubles as the
// animation clock. The fly does NOT know where the food is — it smells the odor
// at its antennae and climbs the gradient (klinotaxis): keep striding while the
// scent strengthens, turn around when it weakens. Drag the food behind it and it
// notices the smell fade, turns, and chases it.
- (void)setExtension:(CGFloat)e {
    _extension = e < 0 ? 0 : (e > 1 ? 1 : e);
    _phase += 1.0;
    _wingPh += 0.8 + 4.2*_lightR;          // light reaction → faster wing buzz
    _startle *= 0.86;                       // startle jolt decays (habituates)
    NSRect bb = self.bounds; CGFloat W = bb.size.width, H = bb.size.height;
    CGFloat drive = _smellDrive < 0 ? 0 : (_smellDrive > 1 ? 1 : _smellDrive);

    if (_foodPresent) {
        CGFloat fx   = [self _foodWorldX];
        CGFloat cx   = [self _centerX];
        CGFloat cast = W*0.0016;
        // sample the odor either side of the fly's CENTRE (facing-independent) —
        // bilateral tropotaxis. Sensing at the centre, not the nose, means a turn
        // doesn't move the sensor, so it can't flip-flop.
        CGFloat samp  = W*0.05;
        CGFloat oL    = [self _concAt:cx - samp];
        CGFloat oR    = [self _concAt:cx + samp];
        CGFloat cOdor = [self _concAt:cx];

        // hysteresis latch: strong scent = it has "found" the food (stops the
        // flip-flop when the food is right under it); only resume searching if
        // the food is dragged well away.
        if (cOdor > 0.60) _onFood = YES;
        if (cOdor < 0.30) _onFood = NO;

        if (_onFood) {
            // settle the mouth onto the drop, facing whichever way the food is
            _facing = (fx >= cx) ? 1 : -1;
            CGFloat mouthLocal  = BodyHomeHeadX(W) + _bodyX + H*0.0275;
            CGFloat mouthScreen = _facing > 0 ? mouthLocal : 2*cx - mouthLocal;
            CGFloat err = fx - mouthScreen;
            _bodyX += (fabs(err) <= cast) ? err : (err > 0 ? 1 : -1)*cast;
            _walking = fabs(err) > 1.5;
            _arrivedAtFood = !_walking;
        } else if (cOdor < 0.04) {
            // can't smell it yet → cast back and forth to pick up the scent
            _bodyX += _facing * cast*0.8;
            _walking = YES; _arrivedAtFood = NO;
        } else {
            // climb the gradient: turn toward the stronger-smelling side
            _facing = (oR >= oL) ? 1 : -1;
            _bodyX += _facing * cast*(0.4 + 0.9*drive);
            _walking = YES; _arrivedAtFood = NO;
        }
        // keep the fly on stage; bounce (and cast back) at the edges
        CGFloat lo = -W*0.15, hi = W*0.50;
        if (_bodyX < lo) { _bodyX = lo; _facing =  1; }
        if (_bodyX > hi) { _bodyX = hi; _facing = -1; }
    } else {                                            // no food: stroll home
        _facing = 1;
        CGFloat sp = W*0.0016, err = -_bodyX;
        _bodyX += (fabs(err) <= sp) ? err : (err > 0 ? 1 : -1)*sp;
        _walking = fabs(_bodyX) > 0.5; _arrivedAtFood = NO;
    }

    FlyPose ps = [self poseFor:bb];
    _labellumContact = ps.contact;
    CGFloat itarget = (_foodPresent && _labellumContact) ? 1.0 : 0.0;
    _ingest += (itarget - _ingest) * 0.12;
    self.needsDisplay = YES;
}

- (FlyPose)poseFor:(NSRect)b {
    FlyPose p; memset(&p, 0, sizeof p);
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat e = _walking ? 0.0 : _extension;           // tongue stays in while striding
    e *= (1.0 - 0.92*_veto);                           // bitter veto retracts the proboscis
    e = e*e*(3.0 - 2.0*e);                             // smoothstep ease
    p.W = W; p.H = H; p.ground = H*0.80;
    CGFloat dx = _bodyX;                       // the fly's walk offset

    // whole fly in profile, facing right, standing on the ground (home = left)
    p.abdC    = CGPointMake(W*0.135 + dx, H*0.45); p.abdRx = H*0.215; p.abdRy = H*0.150;
    p.thoraxC = CGPointMake(W*0.335 + dx, H*0.45); p.thoraxRx = H*0.150; p.thoraxRy = H*0.140;
    p.headC   = CGPointMake(BodyHomeHeadX(W) + dx, H*0.44); p.headR = H*0.125;
    p.eyeC    = CGPointMake(W*0.525 + dx, H*0.415); p.eyeR = H*0.082;
    p.antBase = CGPointMake(p.headC.x + p.headR*0.55, p.headC.y - p.headR*0.55);

    // live reactions displace the whole body: touch → startle bob, heat → recoil
    // (rears back and up). Applied before the proboscis so the tongue follows.
    CGFloat bob  = _startle * H*0.028 * sin(_phase*0.9);  // brief startle jolt, then settles
    CGFloat lean = _heatR  * H*0.030;                     // gentle heat recoil
    CGFloat sdx  = -_facing*lean;                 // shrink away from the heat
    CGFloat sdy  = -lean*0.5 + bob;               // flipped view: −y = up (rear up)
    p.abdC.x+=sdx; p.abdC.y+=sdy; p.thoraxC.x+=sdx; p.thoraxC.y+=sdy;
    p.headC.x+=sdx; p.headC.y+=sdy; p.eyeC.x+=sdx; p.eyeC.y+=sdy;
    p.antBase.x+=sdx; p.antBase.y+=sdy;

    // proboscis ("tongue"): from the head's ventral-front down to the food.
    // At rest it's tucked short under the head; MN9 firing swings it straight
    // down to the surface.
    p.P0 = CGPointMake(p.headC.x + p.headR*0.22, p.headC.y + p.headR*0.86);
    CGFloat L1 = H*0.072, L2 = H*0.072;
    p.a1 = lrp(118, 82, e) * DEG;
    p.a2 = lrp(40,  97, e) * DEG;
    p.j1  = padd(p.P0, p.a1, L1);
    p.tip = padd(p.j1, p.a2, L2);
    // lobes fan out near-horizontal when drinking, so they dab the drop's top
    p.spread = (lrp(6, 14, e) + 40*_ingest) * DEG;

    // food droplet sits at a FIXED spot in the world (not on the fly!), resting
    // on the ground. The fly walks until its mouth is over it, then the
    // fully-extended tongue lands on the drop's top surface.
    p.foodR = H*0.060;
    p.foodC = CGPointMake([self _foodWorldX], p.ground - p.foodR*0.90);

    // the tongue is drawn in facing-right local coords; mirror its tip to screen
    // space (when facing left) before testing whether it reached the food.
    CGFloat tipScreenX = _facing > 0 ? p.tip.x : (2*p.thoraxC.x - p.tip.x);
    CGFloat reach = p.foodR + H*0.05;
    p.contact = _foodPresent &&
                fabs(tipScreenX - p.foodC.x) < reach &&
                fabs(p.tip.y - p.foodC.y)    < reach*1.6;
    return p;
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect b = self.bounds;
    CGFloat H = b.size.height, W = b.size.width;
    FlyPose p = [self poseFor:b];

    // fly palette — desaturated charcoal cuticle (housefly), warm-tinted
    NSColor *bodyDk = [NSColor colorWithSRGBRed:0.16 green:0.17 blue:0.21 alpha:1];
    NSColor *bodyMid= [NSColor colorWithSRGBRed:0.31 green:0.33 blue:0.39 alpha:1];
    NSColor *bodyHi = [NSColor colorWithSRGBRed:0.48 green:0.50 blue:0.57 alpha:1];
    NSColor *legCol = [NSColor colorWithSRGBRed:0.09 green:0.08 blue:0.09 alpha:1];
    NSColor *legFar = [NSColor colorWithSRGBRed:0.09 green:0.08 blue:0.09 alpha:0.40];
    NSColor *lab    = [NSColor colorWithSRGBRed:0.92 green:0.68 blue:0.62 alpha:1];

    // --- reusable drawing blocks ---------------------------------------------
    void (^fillOval)(NSColor*,NSColor*,CGPoint,CGFloat,CGFloat,NSPoint) =
      ^(NSColor *c0, NSColor *c1, CGPoint c, CGFloat rx, CGFloat ry, NSPoint gc) {
        NSRect r = NSMakeRect(c.x-rx, c.y-ry, rx*2, ry*2);
        NSBezierPath *o = [NSBezierPath bezierPathWithOvalInRect:r];
        NSGradient *g = [[NSGradient alloc] initWithStartingColor:c0 endingColor:c1];
        [g drawInBezierPath:o relativeCenterPosition:gc];
        [[NSColor colorWithWhite:0 alpha:0.45] setStroke]; o.lineWidth = 1; [o stroke];
      };
    // a bent insect leg: coxa → (raised knee) → foot on the ground → tarsus
    void (^drawLeg)(CGPoint,CGPoint,CGFloat,NSColor*) =
      ^(CGPoint coxa, CGPoint foot, CGFloat outSign, NSColor *col) {
        CGPoint knee = CGPointMake(lrp(coxa.x,foot.x,0.55) + outSign*H*0.02,
                                   lrp(coxa.y,foot.y,0.40) - H*0.060);
        seg(coxa, knee, H*0.022, col);                   // femur
        seg(knee, foot, H*0.017, col);                   // tibia
        seg(foot, CGPointMake(foot.x+outSign*H*0.05, foot.y), H*0.012, col); // tarsus
      };
    // a foot planted relative to the body; while walking it swings (lifts +
    // strides) on a staggered phase so the six legs read as a gait.
    CGPoint (^foot)(CGFloat,CGFloat) = ^CGPoint(CGFloat footDX, CGFloat legPh) {
        CGFloat fx = p.thoraxC.x + footDX, fy = p.ground;
        if (_walking) {
            CGFloat sw = sin(_phase*0.24 + legPh);
            fx += sw * H*0.035;                          // fore-aft stride
            fy -= MAX(0, sw) * H*0.055;                  // lift during swing
        } else {
            fy += sin(_phase*0.05 + legPh) * H*0.003;    // gentle idle settle
        }
        return CGPointMake(fx, fy);
    };
    // a translucent veined wing as a curved blade swept back over the abdomen.
    // `beat` (degrees) rotates the whole wing about its hinge — the wingbeat, so
    // the LIGHT reaction buzzes these real wings instead of drawing extra lines.
    void (^drawWing)(CGPoint,CGFloat,CGFloat,CGFloat) =
      ^(CGPoint root, CGFloat len, CGFloat alpha, CGFloat beat) {
        NSAffineTransform *xf = [NSAffineTransform transform];
        [xf translateXBy:root.x yBy:root.y];
        [xf rotateByDegrees:beat];
        [xf translateXBy:-root.x yBy:-root.y];
        CGPoint tip = CGPointMake(root.x - len, root.y - H*0.05);
        NSBezierPath *wp = [NSBezierPath bezierPath];
        [wp moveToPoint:root];
        [wp curveToPoint:tip
           controlPoint1:CGPointMake(root.x - len*0.30, root.y - H*0.34)
           controlPoint2:CGPointMake(tip.x  + len*0.20, tip.y  - H*0.18)];
        [wp curveToPoint:root
           controlPoint1:CGPointMake(tip.x  + len*0.18, tip.y  + H*0.10)
           controlPoint2:CGPointMake(root.x - len*0.20, root.y + H*0.10)];
        [wp transformUsingAffineTransform:xf];
        [[NSColor colorWithSRGBRed:0.86 green:0.90 blue:0.98 alpha:alpha] setFill];
        [wp fill];
        [[NSColor colorWithWhite:1 alpha:alpha*0.9] setStroke]; wp.lineWidth = 1; [wp stroke];
        NSBezierPath *veins = [NSBezierPath bezierPath];
        for (int v = 0; v < 3; v++) {                    // a few wing veins
            [veins moveToPoint:CGPointMake(lrp(root.x,tip.x,0.1), lrp(root.y,tip.y,0.1)+H*0.01*v)];
            [veins lineToPoint:CGPointMake(lrp(root.x,tip.x,0.92), lrp(root.y,tip.y,0.92)+H*0.02*v)];
        }
        [veins transformUsingAffineTransform:xf];
        [[NSColor colorWithWhite:1 alpha:alpha*1.4] setStroke]; veins.lineWidth = 0.7; [veins stroke];
      };

    // ---- stage backdrop + ground --------------------------------------------
    NSBezierPath *stage = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b,1,1)
                                                          xRadius:7 yRadius:7];
    [[NSColor colorWithSRGBRed:0.08 green:0.085 blue:0.10 alpha:1] setFill];
    [stage fill];
    [NSGraphicsContext saveGraphicsState];
    [stage addClip];
    NSGradient *bg = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1 alpha:0.05], [NSColor clearColor]]];
    [bg drawInRect:b relativeCenterPosition:NSMakePoint(0.1,-0.4)];
    // ground surface
    NSRect gr = NSMakeRect(0, p.ground, W, H - p.ground);
    [[NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:1] setFill];
    NSRectFill(gr);
    [[NSColor colorWithWhite:1 alpha:0.12] setStroke];
    NSBezierPath *gl = [NSBezierPath bezierPath];
    [gl moveToPoint:CGPointMake(0,p.ground)]; [gl lineToPoint:CGPointMake(W,p.ground)];
    gl.lineWidth = 1.2; [gl stroke];

    // ---- food droplet: a fixed world object on the ground, drawn before the
    //      fly and never mirrored with the body --------------------------------
    if (_foodPresent) {
        if (_ingest > 0.02) {                              // feeding glow
            NSRect hl = NSMakeRect(p.foodC.x-p.foodR*2.4, p.foodC.y-p.foodR*2.4,
                                   p.foodR*4.8, p.foodR*4.8);
            NSGradient *hg2 = [[NSGradient alloc] initWithColors:@[
                [[FSStyle sugar] colorWithAlphaComponent:0.30*_ingest], [NSColor clearColor]]];
            [hg2 drawInRect:hl relativeCenterPosition:NSMakePoint(0,0)];
        }
        NSRect fr = NSMakeRect(p.foodC.x-p.foodR, p.foodC.y-p.foodR*0.95,
                               p.foodR*2, p.foodR*1.85);
        NSBezierPath *drop = [NSBezierPath bezierPathWithOvalInRect:fr];
        NSGradient *dg = [[NSGradient alloc] initWithColorsAndLocations:
            [NSColor colorWithSRGBRed:1.0 green:0.86 blue:0.50 alpha:0.97], 0.0,
            [NSColor colorWithSRGBRed:0.98 green:0.66 blue:0.22 alpha:0.97], 0.6,
            [NSColor colorWithSRGBRed:0.72 green:0.44 blue:0.12 alpha:0.97], 1.0, nil];
        [dg drawInBezierPath:drop relativeCenterPosition:NSMakePoint(-0.3,-0.4)];
        [[NSColor colorWithSRGBRed:0.5 green:0.3 blue:0.05 alpha:0.5] setStroke];
        drop.lineWidth = 1; [drop stroke];
        [[NSColor colorWithWhite:1 alpha:0.6] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(p.foodC.x-p.foodR*0.45, p.foodC.y-p.foodR*0.66,
                       p.foodR*0.5, p.foodR*0.34)] fill];
        if (_ingest > 0.02)
            for (int i = 0; i < 3; i++) {
                CGFloat phh = fmod(_phase*0.04 + i*0.9, 1.0);
                CGFloat rr = p.foodR*(0.3 + 0.9*phh);
                NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
                    NSMakeRect(p.foodC.x-rr, p.foodC.y-rr*0.55, rr*2, rr*1.1)];
                [[NSColor colorWithWhite:1 alpha:0.30*_ingest*(1.0-phh)] setStroke];
                ring.lineWidth = 1.2; [ring stroke];
            }
    }

    // ---- the fly body — mirrored horizontally when it faces left -------------
    [NSGraphicsContext saveGraphicsState];
    if (_facing < 0) {
        NSAffineTransform *mir = [NSAffineTransform transform];
        [mir translateXBy:2*p.thoraxC.x yBy:0];
        [mir scaleXBy:-1 yBy:1];
        [mir concat];
    }

    // wingbeat: a gentle idle flutter, buzzing hard when the LIGHT reaction fires
    CGFloat beatF = (1.5 + 16.0*_lightR) * sin(_wingPh);
    CGFloat beatN = (1.5 + 18.0*_lightR) * sin(_wingPh + 0.5);

    // ---- far (offside) wing + legs, dimmed, drawn behind the body ------------
    drawWing(CGPointMake(p.thoraxC.x - H*0.02, p.thoraxC.y - p.thoraxRy*0.35),
             W*0.30, 0.10, beatF);
    drawLeg(CGPointMake(p.thoraxC.x + H*0.08, p.thoraxC.y + p.thoraxRy*0.6),
            foot(+H*0.20, M_PI),  1, legFar);
    drawLeg(CGPointMake(p.thoraxC.x - H*0.02, p.thoraxC.y + p.thoraxRy*0.7),
            foot(-H*0.02, 0),     1, legFar);
    drawLeg(CGPointMake(p.thoraxC.x - H*0.11, p.thoraxC.y + p.thoraxRy*0.6),
            foot(-H*0.24, M_PI), -1, legFar);

    // ---- abdomen (striped) ---------------------------------------------------
    fillOval(bodyMid, bodyDk, p.abdC, p.abdRx, p.abdRy, NSMakePoint(0.2,-0.4));
    NSRect ar = NSMakeRect(p.abdC.x-p.abdRx, p.abdC.y-p.abdRy, p.abdRx*2, p.abdRy*2);
    NSBezierPath *abd = [NSBezierPath bezierPathWithOvalInRect:ar];
    [NSGraphicsContext saveGraphicsState]; [abd addClip];
    for (int i = 1; i <= 4; i++) {
        CGFloat x = p.abdC.x - p.abdRx + (p.abdRx*2)*i/5.0;
        [[NSColor colorWithWhite:0 alpha:0.22] setFill];
        NSRectFill(NSMakeRect(x-H*0.012, ar.origin.y, H*0.024, ar.size.height));
    }
    [NSGraphicsContext restoreGraphicsState];

    // ---- thorax (with dorsal stripes + bristles) -----------------------------
    fillOval(bodyHi, bodyDk, p.thoraxC, p.thoraxRx, p.thoraxRy, NSMakePoint(0.25,-0.45));
    for (int i = -1; i <= 1; i++)        // 3 short dorsal stripes
        seg(CGPointMake(p.thoraxC.x + i*H*0.045, p.thoraxC.y - p.thoraxRy*0.7),
            CGPointMake(p.thoraxC.x + i*H*0.045, p.thoraxC.y + p.thoraxRy*0.1),
            H*0.012, [NSColor colorWithWhite:0 alpha:0.22]);

    // ---- near wing (translucent, over the abdomen) ---------------------------
    drawWing(CGPointMake(p.thoraxC.x + H*0.01, p.thoraxC.y - p.thoraxRy*0.55),
             W*0.30, 0.20, beatN);

    // ---- head ----------------------------------------------------------------
    fillOval(bodyHi, bodyDk, p.headC, p.headR, p.headR, NSMakePoint(0.3,-0.4));
    // a hint of the offside eye peeking over the top of the head
    fillOval([NSColor colorWithSRGBRed:0.45 green:0.10 blue:0.12 alpha:1],
             [NSColor colorWithSRGBRed:0.25 green:0.05 blue:0.07 alpha:1],
             CGPointMake(p.headC.x - p.headR*0.25, p.headC.y - p.headR*0.55),
             p.headR*0.42, p.headR*0.5, NSMakePoint(0.2,-0.3));

    // ---- compound eye with ommatidia ----------------------------------------
    NSRect er = NSMakeRect(p.eyeC.x-p.eyeR, p.eyeC.y-p.eyeR*1.05,
                           p.eyeR*2, p.eyeR*2.1);
    NSBezierPath *eye = [NSBezierPath bezierPathWithOvalInRect:er];
    [[NSColor colorWithSRGBRed:0.34 green:0.05 blue:0.07 alpha:1] setFill]; [eye fill];
    [NSGraphicsContext saveGraphicsState]; [eye addClip];
    CGFloat fr2 = p.eyeR*0.20, dx = fr2*1.732, dy = fr2*1.5; int row = 0;
    for (CGFloat y = er.origin.y-dy; y <= NSMaxY(er)+dy; y += dy, row++) {
        CGFloat ox = (row & 1) ? dx*0.5 : 0;
        for (CGFloat x = er.origin.x-dx+ox; x <= NSMaxX(er)+dx; x += dx) {
            CGFloat sh = 0.60 + 0.40*(0.5 + 0.5*sin(x*0.7 + y*0.4));
            [[NSColor colorWithSRGBRed:0.82*sh green:0.16*sh blue:0.18*sh alpha:1] setFill];
            NSBezierPath *hx = hexAt(CGPointMake(x,y), fr2*0.94); [hx fill];
            [[NSColor colorWithWhite:0 alpha:0.25] setStroke]; hx.lineWidth = 0.5; [hx stroke];
        }
    }
    NSGradient *spec = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1 alpha:0.55], [NSColor clearColor]]];
    [spec drawInRect:er relativeCenterPosition:NSMakePoint(0.35,-0.5)];
    [NSGraphicsContext restoreGraphicsState];

    // ---- two antennae (near + far), with feathery aristae --------------------
    CGFloat tw = sin(_phase*0.06) * 3.0 * DEG;
    for (int k = 0; k < 2; k++) {
        CGFloat off = k * H*0.022;                        // the pair, slightly apart
        CGFloat al  = (k ? 0.55 : 1.0);                   // far one dimmer
        CGPoint base = CGPointMake(p.antBase.x - off, p.antBase.y + off*0.4);
        CGFloat up = -62*DEG + tw;
        CGPoint s1 = padd(base, up, H*0.05);
        CGPoint s2 = padd(s1, up - 8*DEG, H*0.045);
        seg(base, s1, H*0.022, [bodyDk colorWithAlphaComponent:al]);
        seg(s1, s2, H*0.018, [bodyDk colorWithAlphaComponent:al]);
        NSBezierPath *fn = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(s2.x-H*0.022, s2.y-H*0.026, H*0.044, H*0.052)];
        [[bodyMid colorWithAlphaComponent:al] setFill]; [fn fill];
        CGPoint a0 = padd(s2, up, H*0.01), a1 = padd(a0, up + 18*DEG, H*0.13);
        seg(a0, a1, 1.2, [bodyHi colorWithAlphaComponent:al]);
        for (int i = 1; i <= 3; i++) {                    // arista branches
            CGPoint bp = CGPointMake(lrp(a0.x,a1.x,i/4.0), lrp(a0.y,a1.y,i/4.0));
            seg(bp, padd(bp, up + 75*DEG, H*0.028), 0.8, [bodyHi colorWithAlphaComponent:al]);
        }
    }

    // ---- near (foreground) legs ----------------------------------------------
    drawLeg(CGPointMake(p.thoraxC.x + H*0.10, p.thoraxC.y + p.thoraxRy*0.6),
            foot(+H*0.24, 0),     1, legCol);
    drawLeg(CGPointMake(p.thoraxC.x,          p.thoraxC.y + p.thoraxRy*0.75),
            foot(+H*0.03, M_PI),  1, legCol);
    drawLeg(CGPointMake(p.thoraxC.x - H*0.10, p.thoraxC.y + p.thoraxRy*0.6),
            foot(-H*0.20, 0),    -1, legCol);

    // ---- proboscis ("tongue"): two segments + spreading labellar lobes -------
    seg(p.P0, p.j1, H*0.040, [NSColor colorWithSRGBRed:0.55 green:0.40 blue:0.38 alpha:1]);
    seg(p.P0, p.j1, H*0.026, lab);
    seg(p.j1, p.tip, H*0.034, [NSColor colorWithSRGBRed:0.55 green:0.40 blue:0.38 alpha:1]);
    seg(p.j1, p.tip, H*0.022, lab);
    for (int s = -1; s <= 1; s += 2) {
        CGFloat la2 = p.a2 + s*p.spread;
        CGPoint lt = padd(p.tip, la2, H*0.030 + H*0.012*_ingest);
        seg(p.tip, lt, H*0.022, lab);
        NSBezierPath *pad = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(lt.x-H*0.018, lt.y-H*0.015, H*0.036, H*0.030)];
        [lab setFill]; [pad fill];
        [[NSColor colorWithSRGBRed:0.5 green:0.3 blue:0.3 alpha:0.7] setStroke];
        pad.lineWidth = 0.8; [pad stroke];
    }

    [NSGraphicsContext restoreGraphicsState];   // pop facing mirror
    [NSGraphicsContext restoreGraphicsState];   // pop stage clip

    // ---- live sensory reactions — each sense drives a visible behaviour -------
    CGFloat cx = p.thoraxC.x;
    if (_lightR > 0.02) {                        // LIGHT → the real wings buzz (above) + a flash
        NSGradient *fl = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithWhite:1 alpha:0.14*_lightR], [NSColor clearColor]]];
        [fl drawInRect:b relativeCenterPosition:NSMakePoint(0.0,-0.3)];
    }
    if (_heatR > 0.02) {                         // HEAT → recoil (pose) + rising shimmer
        NSGradient *wg = [[NSGradient alloc] initWithColors:@[
            [NSColor clearColor],
            [NSColor colorWithSRGBRed:1 green:0.4 blue:0.1 alpha:0.16*_heatR]]];
        [wg drawInRect:b relativeCenterPosition:NSMakePoint(0,0)];
        [[NSColor colorWithSRGBRed:1 green:0.6 blue:0.2 alpha:0.5*_heatR] setStroke];
        for (int i = -1; i <= 1; i++) {
            NSBezierPath *w = [NSBezierPath bezierPath];
            CGFloat bx = cx + i*H*0.12;
            [w moveToPoint:CGPointMake(bx, p.ground)];
            for (CGFloat t = 0; t <= 1.01; t += 0.2)
                [w lineToPoint:CGPointMake(bx + sin(_phase*0.2 + t*6 + i)*H*0.03,
                                           p.ground - t*H*0.5)];
            w.lineWidth = 1.2; [w stroke];
        }
    }
    if (_touchR > 0.05) {                        // TOUCH → startle (pose bob) + a spark
        CGFloat hx = _facing > 0 ? p.headC.x : 2*cx - p.headC.x;
        CGPoint sp = CGPointMake(hx + _facing*H*0.12, p.headC.y - p.headR*1.2);
        for (int i = 0; i < 6; i++) {
            CGFloat a = i*60*DEG + _phase*0.4;
            seg(padd(sp, a, H*0.02), padd(sp, a, H*0.05*(0.6+0.4*sin(_phase))), 1.4,
                [NSColor colorWithSRGBRed:1 green:0.9 blue:0.3 alpha:0.8*_touchR]);
        }
    }
    if (_veto > 0.05 && _foodPresent) {          // BITTER → GABA veto collapses feeding
        CGFloat mx = _facing > 0 ? p.P0.x : 2*cx - p.P0.x;
        CGPoint mc = CGPointMake(mx + _facing*H*0.06, p.P0.y + H*0.06);
        CGFloat r = H*0.05;
        NSColor *vc = [[FSStyle bitter] colorWithAlphaComponent:0.9*_veto];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(mc.x-r, mc.y-r, r*2, r*2)];
        [vc setStroke]; ring.lineWidth = 2.2; [ring stroke];
        seg(padd(mc, 135*DEG, r), padd(mc, -45*DEG, r), 2.2, vc);
    }

    // ---- friendly part labels ------------------------------------------------
    if (_showLabels) {
        NSDictionary *la = @{ NSFontAttributeName:[FSStyle mono:8 weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName:[FSStyle labelDim] };
        void (^tag)(NSString*,CGPoint) = ^(NSString *t, CGPoint at) {
            NSSize sz = [t sizeWithAttributes:la];
            [t drawAtPoint:CGPointMake(at.x - sz.width/2, at.y) withAttributes:la]; };
        // part labels are anchored in facing-right coords, so only show them in
        // the settled, right-facing pose (not while searching / facing left)
        if (_facing > 0 && !_walking) {
            tag(@"eye",      CGPointMake(p.eyeC.x, p.headC.y - p.headR - H*0.06));
            tag(@"antenna",  CGPointMake(p.antBase.x + W*0.02, p.antBase.y - H*0.22));
            tag(@"wing",     CGPointMake(p.abdC.x - p.abdRx*0.3, p.thoraxC.y - p.thoraxRy*1.7));
            tag(@"abdomen",  CGPointMake(p.abdC.x - p.abdRx*0.7, p.abdC.y));
            tag(@"thorax",   CGPointMake(p.thoraxC.x, p.thoraxC.y + p.thoraxRy + H*0.02));
            tag(@"leg",      CGPointMake(p.thoraxC.x + W*0.12, p.ground - H*0.07));
            tag(@"tongue",   CGPointMake(p.j1.x + W*0.06, p.j1.y));
        }
        if (_foodPresent) tag(@"sugar", CGPointMake(p.foodC.x, p.foodC.y + p.foodR + H*0.03));
    }

    // ---- overlay captions ----------------------------------------------------
    NSDictionary *ti = @{ NSFontAttributeName:[FSStyle mono:9 weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName:[FSStyle labelDim],
                          NSKernAttributeName:@1.2 };
    [@"THE FLY — SMELL & FEED" drawAtPoint:NSMakePoint(10,8) withAttributes:ti];
    NSDictionary *sub = @{ NSFontAttributeName:[FSStyle mono:9 weight:NSFontWeightRegular],
                           NSForegroundColorAttributeName:
                               [[FSStyle labelDim] colorWithAlphaComponent:0.7] };
    [@"smells the odor → climbs the gradient · taste → tongue out (MN9)"
        drawAtPoint:NSMakePoint(10,22) withAttributes:sub];

    BOOL feeding = _foodPresent && _labellumContact;
    BOOL vetoed  = _veto > 0.3 && _foodPresent;
    NSString *state = vetoed ? @"BITTER — aversive taste, the fly rejects the food"
                   : (feeding ? @"DRINKING — tongue on the sugar!"
                   : (_walking ? [NSString stringWithFormat:@"SEARCHING — scent %.0f%%",
                                  [self perceivedOdor]*100.0]
                   : (_extension > 0.06 ? @"tasting — tongue out…"
                   : (_foodPresent ? @"on the food…" : @"at rest"))));
    NSColor *sc = vetoed ? [FSStyle bitter]
                : (feeding ? [FSStyle output]
                : (_walking ? [FSStyle water]
                : (_extension > 0.06 ? [FSStyle sugar] : [FSStyle labelDim])));
    NSDictionary *stA = @{ NSFontAttributeName:[FSStyle mono:11 weight:NSFontWeightBold],
                           NSForegroundColorAttributeName:sc };
    NSString *st = [NSString stringWithFormat:@"MN9 %.0f Hz   ·   tongue out %.0f°   ·   %@",
                    _mn9Hz, _extension*42.0, state];
    [st drawAtPoint:NSMakePoint(10, H-20) withAttributes:stA];
}
@end
