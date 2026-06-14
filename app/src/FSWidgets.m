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
}
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

    // subtle scanline frame
    [[FSStyle panelStroke] setStroke];
    NSBezierPath *fr = [NSBezierPath bezierPathWithRect:NSInsetRect(b,0.5,0.5)];
    fr.lineWidth = 1; [fr stroke];
}
@end
