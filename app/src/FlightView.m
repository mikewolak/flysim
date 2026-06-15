// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlightView.m
//
//  First-person view from a fly hunting food in a 3D arena. The loop is closed
//  through the connectome: bilateral SMELL (L/R olfactory ORNs) + VISION (L/R
//  eye photoreceptors) in → the LEFT vs RIGHT DESCENDING neurons (the brain's
//  real command lines) set yaw → the fly turns. The camera rides the fly's eye,
//  so you watch the food slide to centre as the brain fixates it.

#import "FlightView.h"
#import "FlyController.h"
#import <SceneKit/SceneKit.h>

#define WORLD     20.0
#define ALT_MIN    2.5
#define ALT_MAX   24.0
#define LAMBDA    13.0
#define MAXOLF   200.0
#define MAXVIS   200.0
#define HEAD_F     0.8
#define ANT_SPR    2.4
#define V_SAMPLE   1.4
#define CRUISE     7.0
#define CATCH      5.0
#define YAW_GAIN   0.45
#define YAW_MAX    2.2
#define YAW_DEAD   0.4
#define PITCH_GAIN 5.0

static SCNVector3 V3(CGFloat x, CGFloat y, CGFloat z){ return SCNVector3Make(x,y,z); }
static CGFloat vdist(SCNVector3 a, SCNVector3 b){
    CGFloat dx=a.x-b.x, dy=a.y-b.y, dz=a.z-b.z; return sqrt(dx*dx+dy*dy+dz*dz);
}
static double angWrap(double a){ while(a>M_PI)a-=2*M_PI; while(a<-M_PI)a+=2*M_PI; return a; }

// a gyroscope / attitude indicator: artificial-horizon ball (pitch) inside a
// rotating compass ring (yaw), with a fixed fly symbol — shows the fly's attitude.
@interface FlightGyro : NSView
@property (nonatomic) CGFloat yaw, pitch, roll;
@end
@implementation FlightGyro
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }
- (void)setYaw:(CGFloat)y { _yaw = y; }
- (void)setPitch:(CGFloat)p { _pitch = p; }
- (void)drawRect:(NSRect)d {
    (void)d;
    NSRect b = self.bounds; CGFloat cx = b.size.width/2, cy = b.size.height/2;
    CGFloat R = MIN(cx,cy) - 4;
    NSBezierPath *circ = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx-R,cy-R,2*R,2*R)];
    [NSGraphicsContext saveGraphicsState]; [circ addClip];
    // roll tilts the whole horizon; pitch shifts it vertically (nose up → more sky)
    NSAffineTransform *rot = [NSAffineTransform transform];
    [rot translateXBy:cx yBy:cy]; [rot rotateByDegrees:_roll*180.0/M_PI];
    [rot translateXBy:-cx yBy:-cy]; [rot concat];
    CGFloat off = (_pitch/0.9)*R; if (off>R) off=R; if (off<-R) off=-R;
    CGFloat hy = cy - off, big = R*2.4;
    [[NSColor colorWithSRGBRed:0.16 green:0.40 blue:0.58 alpha:1] setFill];   // sky
    NSRectFill(NSMakeRect(cx-big, hy, 2*big, 2*big));
    [[NSColor colorWithSRGBRed:0.34 green:0.23 blue:0.12 alpha:1] setFill];   // ground
    NSRectFill(NSMakeRect(cx-big, hy-2*big, 2*big, 2*big));
    [[NSColor whiteColor] setStroke];
    NSBezierPath *hl = [NSBezierPath bezierPath];
    [hl moveToPoint:NSMakePoint(cx-big,hy)]; [hl lineToPoint:NSMakePoint(cx+big,hy)];
    hl.lineWidth = 1.5; [hl stroke];
    [[NSColor colorWithWhite:1 alpha:0.55] setStroke];      // pitch ladder
    for (int k=-3;k<=3;k++){ if(!k) continue; CGFloat py=hy+(k*0.26/0.9)*R, w=(k%2)?R*0.20:R*0.40;
        NSBezierPath *t=[NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(cx-w,py)]; [t lineToPoint:NSMakePoint(cx+w,py)]; t.lineWidth=1; [t stroke]; }
    [NSGraphicsContext restoreGraphicsState];
    // yaw compass ring (rotates as the fly turns)
    [[NSColor colorWithWhite:1 alpha:0.7] setStroke];
    for (int i=0;i<12;i++){ CGFloat a=(i*30.0)*M_PI/180.0 - _yaw + M_PI/2;
        CGFloat r0=R-1, r1=(i%3==0)?R-9:R-5;
        NSBezierPath *tk=[NSBezierPath bezierPath];
        [tk moveToPoint:NSMakePoint(cx+r0*cos(a),cy+r0*sin(a))];
        [tk lineToPoint:NSMakePoint(cx+r1*cos(a),cy+r1*sin(a))]; tk.lineWidth=(i%3==0)?2:1; [tk stroke]; }
    [[NSColor colorWithSRGBRed:0.3 green:0.7 blue:0.5 alpha:0.95] setStroke]; circ.lineWidth=2; [circ stroke];
    // fixed top index + centre fly symbol
    [[NSColor colorWithSRGBRed:1 green:0.85 blue:0.2 alpha:1] setFill];
    NSBezierPath *tri=[NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(cx,cy+R-13)]; [tri lineToPoint:NSMakePoint(cx-5,cy+R-3)];
    [tri lineToPoint:NSMakePoint(cx+5,cy+R-3)]; [tri closePath]; [tri fill];
    [[NSColor colorWithSRGBRed:1 green:0.9 blue:0.3 alpha:1] setStroke];
    NSBezierPath *fly=[NSBezierPath bezierPath];
    [fly moveToPoint:NSMakePoint(cx-13,cy)]; [fly lineToPoint:NSMakePoint(cx-4,cy)];
    [fly moveToPoint:NSMakePoint(cx+4,cy)];  [fly lineToPoint:NSMakePoint(cx+13,cy)];
    fly.lineWidth=2.5; [fly stroke];
    [[NSColor colorWithSRGBRed:1 green:0.9 blue:0.3 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx-2.5,cy-2.5,5,5)] fill];
}
@end

// reliable top-down schematic map (drawn from live positions, no SceneKit)
@interface FlightMap : NSView
@property (nonatomic) CGPoint flyXZ, foodXZ;
@property (nonatomic) CGFloat flyYaw;
@property (nonatomic, strong) NSArray<NSValue *> *pillars;
@end
@implementation FlightMap
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }
- (NSPoint)_xz:(CGPoint)xz {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, m = 12, R = 21.0;
    return NSMakePoint(m + (xz.x/(2*R) + 0.5)*(W-2*m),
                       m + (0.5 - xz.y/(2*R))*(H-2*m));   // world +z → map down
}
- (void)drawRect:(NSRect)d {
    (void)d; NSRect b = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:6 yRadius:6];
    [[NSColor colorWithSRGBRed:0.04 green:0.05 blue:0.07 alpha:0.92] setFill]; [bg fill];
    [[NSColor colorWithWhite:1 alpha:0.06] setStroke];
    for (int i = 1; i < 4; i++) {
        CGFloat gx = b.size.width*i/4.0, gy = b.size.height*i/4.0;
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(gx,0)]; [g lineToPoint:NSMakePoint(gx,b.size.height)];
        [g moveToPoint:NSMakePoint(0,gy)]; [g lineToPoint:NSMakePoint(b.size.width,gy)];
        g.lineWidth = 0.5; [g stroke];
    }
    [[NSColor colorWithSRGBRed:0.2 green:0.45 blue:0.65 alpha:0.8] setFill];
    for (NSValue *v in _pillars) { NSPoint p = [self _xz:v.pointValue];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x-1.5,p.y-1.5,3,3)] fill]; }
    NSPoint fp = [self _xz:_foodXZ];                       // food: amber diamond
    [[NSColor colorWithSRGBRed:1 green:0.7 blue:0.25 alpha:1] setFill];
    NSBezierPath *dia = [NSBezierPath bezierPath];
    [dia moveToPoint:NSMakePoint(fp.x,fp.y+5)]; [dia lineToPoint:NSMakePoint(fp.x+5,fp.y)];
    [dia lineToPoint:NSMakePoint(fp.x,fp.y-5)]; [dia lineToPoint:NSMakePoint(fp.x-5,fp.y)];
    [dia closePath]; [dia fill];
    NSPoint flp = [self _xz:_flyXZ];                       // fly: heading triangle
    double ang = atan2(-cos(_flyYaw), sin(_flyYaw));       // world (sin,cos)→screen (x,-y)
    [[NSColor colorWithSRGBRed:0.5 green:1 blue:0.7 alpha:1] setFill];
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(flp.x+8*cos(ang), flp.y+8*sin(ang))];
    [tri lineToPoint:NSMakePoint(flp.x+5*cos(ang+2.4), flp.y+5*sin(ang+2.4))];
    [tri lineToPoint:NSMakePoint(flp.x+5*cos(ang-2.4), flp.y+5*sin(ang-2.4))];
    [tri closePath]; [tri fill];
}
@end

@interface FlightView () <SCNSceneRendererDelegate>
@end

@implementation FlightView {
    FlyController *_fly;
    SCNView   *_scn;
    SCNNode   *_flyNode, *_foodNode, *_camNode, *_lookNode, *_camRig;
    NSTextField *_hud;
    FlightGyro *_gyro;
    FlightMap *_map;
    NSMutableArray<NSValue *> *_pillarPts;   // pillar x/z for the schematic map
    BOOL _active;

    SCNVector3 _pos, _foodPos;
    double _yaw, _pitch, _lastT, _castPhase, _turnLP;
    double _camYaw, _camPitch, _camRoll;     // smoothed camera attitude (anti-jitter)
    int    _caught, _calib;
    double _baseline;
}

- (instancetype)initWithFly:(FlyController *)fly frame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _fly = fly;
    [self _build];
    [self _resetFlight];
    return self;
}

- (void)_build {
    SCNScene *scene = [SCNScene scene];
    // sky dome — a gradient backdrop with a horizon, so it reads as a world (not a
    // black void) whichever way the fly looks
    SCNSphere *sky = [SCNSphere sphereWithRadius:150];
    sky.firstMaterial.cullMode = SCNCullModeFront;          // visible from inside
    sky.firstMaterial.lightingModelName = SCNLightingModelConstant;
    sky.firstMaterial.diffuse.contents = [self _skyImage];
    [scene.rootNode addChildNode:[SCNNode nodeWithGeometry:sky]];

    // ground grid
    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0.04;
    floor.firstMaterial.diffuse.contents = [self _gridImage];
    floor.firstMaterial.diffuse.wrapS = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.wrapT = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(70,70,0);
    [scene.rootNode addChildNode:[SCNNode nodeWithGeometry:floor]];

    // scattered glowing landmark pillars — depth + motion reference as you fly
    _pillarPts = [NSMutableArray array];
    for (int i = 0; i < 26; i++) {
        CGFloat px = ((double)arc4random_uniform(1000)/1000.0*2-1) * WORLD*1.05;
        CGFloat pz = ((double)arc4random_uniform(1000)/1000.0*2-1) * WORLD*1.05;
        CGFloat h  = 8 + arc4random_uniform(18);
        SCNCylinder *cyl = [SCNCylinder cylinderWithRadius:0.3 height:h];
        cyl.firstMaterial.diffuse.contents  = [NSColor colorWithSRGBRed:0.12 green:0.34 blue:0.50 alpha:1];
        cyl.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:0.12 green:0.40 blue:0.62 alpha:1];
        SCNNode *pn = [SCNNode nodeWithGeometry:cyl];
        pn.position = V3(px, h/2, pz);
        [scene.rootNode addChildNode:pn];
        [_pillarPts addObject:[NSValue valueWithPoint:NSMakePoint(px, pz)]];
    }

    // food: glowing amber sphere + soft odor particles
    SCNSphere *fs = [SCNSphere sphereWithRadius:0.8];
    fs.firstMaterial.diffuse.contents  = [NSColor colorWithSRGBRed:1 green:0.72 blue:0.25 alpha:1];
    fs.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:1 green:0.62 blue:0.18 alpha:1];
    _foodNode = [SCNNode nodeWithGeometry:fs];
    SCNParticleSystem *odor = [SCNParticleSystem particleSystem];
    odor.birthRate = 30; odor.particleLifeSpan = 3.4; odor.particleSize = 0.6;
    odor.particleColor = [NSColor colorWithSRGBRed:1 green:0.7 blue:0.3 alpha:0.16];
    odor.emittingDirection = V3(0,1,0); odor.spreadingAngle = 180;
    odor.particleVelocity = 1.4; odor.blendMode = SCNParticleBlendModeAdditive;
    odor.particleImage = [self _softDot];
    odor.emitterShape = [SCNSphere sphereWithRadius:0.8];
    [_foodNode addParticleSystem:odor];
    // soft halo so the food is a visible beacon across the arena
    SCNSphere *halo = [SCNSphere sphereWithRadius:3.4];
    halo.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:1 green:0.68 blue:0.28 alpha:1];
    halo.firstMaterial.transparency = 0.22;
    halo.firstMaterial.writesToDepthBuffer = NO;
    halo.firstMaterial.lightingModelName = SCNLightingModelConstant;
    [_foodNode addChildNode:[SCNNode nodeWithGeometry:halo]];
    [_foodNode runAction:[SCNAction repeatActionForever:[SCNAction sequence:@[
        [SCNAction scaleTo:1.18 duration:0.9], [SCNAction scaleTo:1.0 duration:0.9]]]]];
    [scene.rootNode addChildNode:_foodNode];

    // the fly body — behind the FP camera, but the bright marker the map shows
    SCNSphere *bs = [SCNSphere sphereWithRadius:0.5];
    bs.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:0.5 green:1 blue:0.7 alpha:1];
    _flyNode = [SCNNode nodeWithGeometry:bs];
    SCNSphere *fhalo = [SCNSphere sphereWithRadius:0.9];   // glow so it pops on the map
    fhalo.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:1];
    fhalo.firstMaterial.transparency = 0.25;
    fhalo.firstMaterial.writesToDepthBuffer = NO;
    fhalo.firstMaterial.lightingModelName = SCNLightingModelConstant;
    [_flyNode addChildNode:[SCNNode nodeWithGeometry:fhalo]];
    [scene.rootNode addChildNode:_flyNode];

    // lights
    SCNNode *amb = [SCNNode node]; amb.light = [SCNLight light];
    amb.light.type = SCNLightTypeAmbient; amb.light.color = [NSColor colorWithWhite:0.45 alpha:1];
    [scene.rootNode addChildNode:amb];

    // first-person camera on a gimbal rig: the rig points along the heading
    // (look-at), the camera child is rolled about the view axis so the world
    // horizon banks into turns. Wide fly-like field of view.
    _camRig = [SCNNode node];
    _lookNode = [SCNNode node];
    [scene.rootNode addChildNode:_lookNode];
    [scene.rootNode addChildNode:_camRig];
    _camRig.constraints = @[[SCNLookAtConstraint lookAtConstraintWithTarget:_lookNode]];
    _camNode = [SCNNode node]; _camNode.camera = [SCNCamera camera];
    _camNode.camera.fieldOfView = 95; _camNode.camera.zFar = 300; _camNode.camera.zNear = 0.3;
    [_camRig addChildNode:_camNode];

    _scn = [[SCNView alloc] initWithFrame:self.bounds];
    _scn.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scn.scene = scene;
    _scn.backgroundColor = [NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.10 alpha:1];
    _scn.pointOfView = _camNode;
    _scn.delegate = self;
    _scn.rendersContinuously = NO;
    [self addSubview:_scn];

    // minimap — a reliable top-down schematic (drawn from the live positions),
    // inset top-right. (Two SceneKit views can't share a scene without stalling
    // the main render loop, so the map is a custom view, not a second SCNView.)
    CGFloat mw = 184, mh = 184;
    _map = [[FlightMap alloc] initWithFrame:
        NSMakeRect(self.bounds.size.width-mw-12, self.bounds.size.height-mh-12, mw, mh)];
    _map.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    _map.pillars = _pillarPts;
    _map.wantsLayer = YES; _map.layer.borderWidth = 1.0; _map.layer.cornerRadius = 6;
    _map.layer.borderColor = [NSColor colorWithSRGBRed:0.3 green:0.7 blue:0.5 alpha:0.85].CGColor;
    [self addSubview:_map];
    NSTextField *ml = [NSTextField labelWithString:@"MAP  ·  ▲ fly   ◆ food"];
    ml.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightSemibold];
    ml.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:0.9];
    ml.frame = NSMakeRect(7, mh-15, mw-12, 12);
    ml.autoresizingMask = NSViewMaxXMargin;
    [_map addSubview:ml];

    // HUD (top, above everything)
    _hud = [NSTextField labelWithString:@""];
    _hud.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _hud.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:1];
    _hud.frame = NSMakeRect(14, self.bounds.size.height-76, 560, 62);
    _hud.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    _hud.maximumNumberOfLines = 4;
    [self addSubview:_hud];

    // attitude indicator (gyroscope) — fixed bottom-left
    _gyro = [[FlightGyro alloc] initWithFrame:NSMakeRect(16, 16, 124, 124)];
    _gyro.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self addSubview:_gyro];
    NSTextField *gl = [NSTextField labelWithString:@"ATTITUDE"];
    gl.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightSemibold];
    gl.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:0.85];
    gl.frame = NSMakeRect(16, 142, 124, 12); gl.alignment = NSTextAlignmentCenter;
    gl.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self addSubview:gl];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _scn.rendersContinuously = active;
    if (active) { if (!_fly.running) [_fly start]; _lastT = 0; }
    else { _fly.smellLeftHz = _fly.smellRightHz = 0; _fly.lightLeftHz = _fly.lightRightHz = 0; }
}

- (NSImage *)_softDot {
    CGFloat S = 64; NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(S,S)];
    [img lockFocus];
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:1.0], 0.0, [NSColor colorWithWhite:1 alpha:0.5], 0.45,
        [NSColor colorWithWhite:1 alpha:0.0], 1.0, nil];
    [g drawInRect:NSMakeRect(0,0,S,S) relativeCenterPosition:NSZeroPoint];
    [img unlockFocus]; return img;
}
- (NSImage *)_skyImage {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(8,256)];
    [img lockFocus];
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.13 alpha:1], 0.0,    // floor side
        [NSColor colorWithSRGBRed:0.13 green:0.26 blue:0.36 alpha:1], 0.5,    // horizon glow
        [NSColor colorWithSRGBRed:0.02 green:0.03 blue:0.08 alpha:1], 1.0,    // zenith
        nil];
    [g drawInRect:NSMakeRect(0,0,8,256) angle:90];
    [img unlockFocus]; return img;
}
- (NSImage *)_gridImage {
    CGFloat S = 256; NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(S,S)];
    [img lockFocus];
    [[NSColor colorWithSRGBRed:0.06 green:0.08 blue:0.10 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,S,S));
    [[NSColor colorWithSRGBRed:0.20 green:0.34 blue:0.30 alpha:1] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 3;
    [p moveToPoint:NSMakePoint(1,0)]; [p lineToPoint:NSMakePoint(1,S)];
    [p moveToPoint:NSMakePoint(0,1)]; [p lineToPoint:NSMakePoint(S,1)];
    [p stroke]; [img unlockFocus]; return img;
}

- (void)_resetFlight {
    _pos = V3(-WORLD*0.7, 9, -WORLD*0.7);
    _yaw = 0.6; _pitch = 0; _lastT = 0; _calib = 0; _baseline = 0; _turnLP = 0;
    _camYaw = _yaw; _camPitch = 0; _camRoll = 0;
    [self _placeFood]; _flyNode.position = _pos;
}
- (void)_placeFood {
    CGFloat x = ((double)arc4random_uniform(10000)/10000.0*2-1) * WORLD*0.78;
    CGFloat z = ((double)arc4random_uniform(10000)/10000.0*2-1) * WORLD*0.78;
    CGFloat y = 6 + (double)arc4random_uniform(10000)/10000.0 * 13;
    _foodPos = V3(x,y,z); _foodNode.position = _foodPos;
}
- (CGFloat)_concAt:(SCNVector3)p { CGFloat d = vdist(p,_foodPos)/LAMBDA; return exp(-d*d); }

- (void)renderer:(id<SCNSceneRenderer>)r updateAtTime:(NSTimeInterval)t {
    double dt = (_lastT > 0) ? (t - _lastT) : (1.0/60.0);
    _lastT = t; if (dt <= 0 || dt > 0.1) dt = 1.0/60.0;

    double cy = cos(_yaw), sy = sin(_yaw), cp = cos(_pitch), sp = sin(_pitch);
    SCNVector3 fwd = V3(sy*cp, sp, cy*cp), right = V3(cy, 0, -sy);

    SCNVector3 head = V3(_pos.x+fwd.x*HEAD_F, _pos.y+fwd.y*HEAD_F, _pos.z+fwd.z*HEAD_F);
    SCNVector3 antL = V3(head.x-right.x*ANT_SPR, head.y, head.z-right.z*ANT_SPR);
    SCNVector3 antR = V3(head.x+right.x*ANT_SPR, head.y, head.z+right.z*ANT_SPR);
    CGFloat oL = [self _concAt:antL], oR = [self _concAt:antR];
    CGFloat odorHead = [self _concAt:head];

    // SENSE 1 — smell (plume)
    _fly.smellLeftHz  = (float)(oL * MAXOLF);
    _fly.smellRightHz = (float)(oR * MAXOLF);

    // SENSE 2 — vision (target fixation): stimulate the eye the food lands on
    double tx = _foodPos.x - _pos.x, tz = _foodPos.z - _pos.z;
    double th = hypot(tx, tz); if (th < 1e-3) th = 1e-3;
    double ux = tx/th, uz = tz/th;
    double dotF = sy*ux + cy*uz, crossF = sy*uz - cy*ux;
    double bearing = atan2(crossF, dotF);
    BOOL   visible = dotF > -0.25;
    double rfrac = 0.5 - 0.5*(bearing/(M_PI*0.55));
    if (rfrac < 0) rfrac = 0; if (rfrac > 1) rfrac = 1;
    _fly.lightLeftHz  = (float)(visible ? MAXVIS*(1.0-rfrac) : 0);
    _fly.lightRightHz = (float)(visible ? MAXVIS*rfrac       : 0);
    if (visible) { _fly.smellLeftHz = 0; _fly.smellRightHz = 0; }   // vision-only when fixating

    // READ the brain's steering command — the DNa turn-descending family (L−R),
    // far cleaner than averaging all 1,303 descending cells.
    FlySnapshot s = [_fly snapshot];
    double asym = s.steerLeftRate - s.steerRightRate;
    if (_calib == 0) { _baseline = asym; _calib = 1; }

    if (visible) {
        if (fabs(bearing) < 0.15) _baseline += (asym - _baseline) * 0.02;
        double turn = asym - _baseline;
        if (fabs(turn) < YAW_DEAD) turn = 0;
        _turnLP += (turn - _turnLP) * 0.10;   // low-pass the noisy steering command
        double yawRate = _turnLP * YAW_GAIN;
        if (yawRate >  YAW_MAX) yawRate =  YAW_MAX;
        if (yawRate < -YAW_MAX) yawRate = -YAW_MAX;
        _yaw -= yawRate * dt;                 // DNa polarity: food-right → bank right
        double pitchT = atan2(_foodPos.y - _pos.y, th);
        if (pitchT >  0.7) pitchT =  0.7; if (pitchT < -0.7) pitchT = -0.7;
        _pitch += (pitchT - _pitch) * 0.10;
    } else {
        _castPhase += dt * 1.5;
        _yaw += sin(_castPhase) * 1.8 * dt;
    }

    if (fabs(_pos.x) > WORLD || fabs(_pos.z) > WORLD) {
        double toC = atan2(-_pos.x, -_pos.z), d = toC - _yaw;
        while (d >  M_PI) d -= 2*M_PI; while (d < -M_PI) d += 2*M_PI;
        _yaw += d * 1.5 * dt;
    }

    double speed = CRUISE * (1.0 - 0.72*odorHead);
    cy = cos(_yaw); sy = sin(_yaw); cp = cos(_pitch); sp = sin(_pitch);
    fwd = V3(sy*cp, sp, cy*cp);
    _pos = V3(_pos.x + fwd.x*speed*dt, _pos.y + fwd.y*speed*dt, _pos.z + fwd.z*speed*dt);
    if (_pos.y < ALT_MIN) { _pos.y = ALT_MIN; if (_pitch < 0) _pitch = 0; }
    if (_pos.y > ALT_MAX) { _pos.y = ALT_MAX; if (_pitch > 0) _pitch = 0; }
    _flyNode.position = _pos;

    // SMOOTHED camera attitude — the hysteresis that kills the seasickness. The
    // camera eases toward the (noisy) flight heading; roll comes from the SMOOTHED
    // yaw rate (deriving it from the raw yaw was the worst of the jitter).
    double prevCamYaw = _camYaw;
    _camYaw   += angWrap(_yaw - _camYaw) * 0.06;
    _camPitch += (_pitch - _camPitch)    * 0.05;
    double camYawRate = angWrap(_camYaw - prevCamYaw) / dt;
    double rollT = camYawRate * 0.32; if (rollT > 0.55) rollT = 0.55; if (rollT < -0.55) rollT = -0.55;
    _camRoll  += (rollT - _camRoll) * 0.05;

    // first-person camera from the SMOOTHED attitude
    double ccy=cos(_camYaw), csy=sin(_camYaw), ccp=cos(_camPitch), csp=sin(_camPitch);
    SCNVector3 cfwd = V3(csy*ccp, csp, ccy*ccp); (void)sp;
    _camRig.position   = V3(_pos.x + cfwd.x*1.8, _pos.y + 0.12, _pos.z + cfwd.z*1.8);
    _lookNode.position = V3(_pos.x + cfwd.x*20,  _pos.y + cfwd.y*20, _pos.z + cfwd.z*20);
    _camNode.eulerAngles = V3(0, 0, _camRoll);

    if (vdist(_pos, _foodPos) < CATCH) { _caught++; [self _placeFood]; _calib = 0; }

    static int hk = 0; if ((hk++ % 6) == 0) {
        NSString *txt = [NSString stringWithFormat:
            @"FIRST-PERSON FLIGHT — what the fly sees, steered by its brain\n"
            @"DNa steering  L %5.1f  R %5.1f   (L−R %+5.1f Hz → yaw)\n"
            @"eyes  L %3.0f%%  R %3.0f%%   ·   smell %3.0f%%   ·   caught: %d\n"
            @"%@",
            s.steerLeftRate, s.steerRightRate, (s.steerLeftRate - s.steerRightRate),
            _fly.lightLeftHz/MAXVIS*100, _fly.lightRightHz/MAXVIS*100, odorHead*100, _caught,
            visible ? @"vision: fixating the food → descending → turn toward it"
                    : @"food out of view — casting to find it"];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_hud.stringValue = txt; });
    }
    if ((hk % 2) == 0) {                          // attitude indicator + map, ~30 Hz
        CGFloat yy = _camYaw, pp = _camPitch, rr = _camRoll;   // match the (smoothed) view
        CGPoint flyXZ = CGPointMake(_pos.x, _pos.z), foodXZ = CGPointMake(_foodPos.x, _foodPos.z);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_gyro.yaw = yy; self->_gyro.pitch = pp; self->_gyro.roll = rr;
            [self->_gyro setNeedsDisplay:YES];
            self->_map.flyXZ = flyXZ; self->_map.foodXZ = foodXZ; self->_map.flyYaw = yy;
            [self->_map setNeedsDisplay:YES]; });
    }
}
@end
