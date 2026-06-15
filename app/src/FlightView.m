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

// translucent first-person framing — the fly's own antennae + forelegs at the
// edges of view, like looking out from inside its head.
@interface FlightCockpit : NSView @end
@implementation FlightCockpit
- (BOOL)isFlipped { return NO; }
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }   // pass mouse through
- (void)drawRect:(NSRect)d {
    (void)d;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSColor *dk = [NSColor colorWithWhite:0.015 alpha:0.55];
    NSGradient *vg = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor clearColor], 0.0, [NSColor colorWithWhite:0 alpha:0.0], 0.66,
        [NSColor colorWithWhite:0 alpha:0.34], 1.0, nil];
    [vg drawInRect:self.bounds relativeCenterPosition:NSZeroPoint];   // edge vignette
    for (int s = -1; s <= 1; s += 2) {                                // two antennae
        CGFloat bx = W*0.5 + s*W*0.03, tx = W*0.5 + s*W*0.17, ty = H*0.42;
        NSBezierPath *a = [NSBezierPath bezierPath];
        [a moveToPoint:NSMakePoint(bx, -4)];
        [a curveToPoint:NSMakePoint(tx, ty)
           controlPoint1:NSMakePoint(bx + s*W*0.02, H*0.15)
           controlPoint2:NSMakePoint(tx - s*W*0.02, ty - H*0.12)];
        a.lineWidth = 9; a.lineCapStyle = NSLineCapStyleRound; [dk setStroke]; [a stroke];
        [dk setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tx-8, ty-8, 16, 16)] fill];
        for (int k = 1; k <= 4; k++) {                               // arista hairs
            CGFloat t = k/5.0; NSPoint p0 = NSMakePoint(tx + s*t*W*0.05, ty + t*H*0.10);
            NSBezierPath *h = [NSBezierPath bezierPath];
            [h moveToPoint:p0]; [h lineToPoint:NSMakePoint(p0.x + s*15, p0.y + 9)];
            h.lineWidth = 2; [h stroke];
        }
    }
    for (int s = -1; s <= 1; s += 2) {                               // forelegs (corners)
        CGFloat cx = (s < 0) ? 0 : W;
        NSBezierPath *leg = [NSBezierPath bezierPath];
        [leg moveToPoint:NSMakePoint(cx, 0)];
        [leg lineToPoint:NSMakePoint(cx - s*W*0.12, H*0.17)];
        [leg lineToPoint:NSMakePoint(cx - s*W*0.03, H*0.31)];
        leg.lineWidth = 12; leg.lineCapStyle = NSLineCapStyleRound; [dk setStroke]; [leg stroke];
    }
}
@end

@interface FlightView () <SCNSceneRendererDelegate>
@end

@implementation FlightView {
    FlyController *_fly;
    SCNView   *_scn, *_mini;
    SCNNode   *_flyNode, *_foodNode, *_camNode, *_lookNode, *_miniCam;
    NSTextField *_hud;
    FlightCockpit *_cockpit;
    BOOL _active;

    SCNVector3 _pos, _foodPos;
    double _yaw, _pitch, _lastT, _castPhase;
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
    // depth: fog fades distance into the horizon (good first-person cue)
    scene.fogColor = [NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.10 alpha:1];
    scene.fogStartDistance = 18; scene.fogEndDistance = 95;

    // ground grid
    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0.04;
    floor.firstMaterial.diffuse.contents = [self _gridImage];
    floor.firstMaterial.diffuse.wrapS = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.wrapT = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(70,70,0);
    [scene.rootNode addChildNode:[SCNNode nodeWithGeometry:floor]];

    // scattered glowing landmark pillars — depth + motion reference as you fly
    for (int i = 0; i < 14; i++) {
        CGFloat px = ((double)arc4random_uniform(1000)/1000.0*2-1) * WORLD*0.95;
        CGFloat pz = ((double)arc4random_uniform(1000)/1000.0*2-1) * WORLD*0.95;
        CGFloat h  = 6 + arc4random_uniform(14);
        SCNCylinder *cyl = [SCNCylinder cylinderWithRadius:0.25 height:h];
        cyl.firstMaterial.diffuse.contents  = [NSColor colorWithSRGBRed:0.10 green:0.30 blue:0.45 alpha:1];
        cyl.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:0.10 green:0.35 blue:0.55 alpha:1];
        SCNNode *pn = [SCNNode nodeWithGeometry:cyl];
        pn.position = V3(px, h/2, pz);
        [scene.rootNode addChildNode:pn];
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
    SCNSphere *halo = [SCNSphere sphereWithRadius:2.0];
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

    // first-person camera: rides the fly's eye, wide fly-like field of view
    _camNode = [SCNNode node]; _camNode.camera = [SCNCamera camera];
    _camNode.camera.fieldOfView = 95; _camNode.camera.zFar = 300; _camNode.camera.zNear = 0.3;
    _lookNode = [SCNNode node];
    [scene.rootNode addChildNode:_lookNode];
    [scene.rootNode addChildNode:_camNode];
    _camNode.constraints = @[[SCNLookAtConstraint lookAtConstraintWithTarget:_lookNode]];

    // external 3/4 camera for the minimap — the old third-person view of the arena
    _miniCam = [SCNNode node]; _miniCam.camera = [SCNCamera camera];
    _miniCam.camera.fieldOfView = 52; _miniCam.camera.zFar = 300;
    _miniCam.position = V3(0, 46, 34);
    SCNNode *mc = [SCNNode node]; mc.position = V3(0, 6, 0);
    [scene.rootNode addChildNode:mc];
    _miniCam.constraints = @[[SCNLookAtConstraint lookAtConstraintWithTarget:mc]];
    [scene.rootNode addChildNode:_miniCam];

    _scn = [[SCNView alloc] initWithFrame:self.bounds];
    _scn.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scn.scene = scene;
    _scn.backgroundColor = [NSColor colorWithSRGBRed:0.05 green:0.07 blue:0.10 alpha:1];
    _scn.pointOfView = _camNode;
    _scn.delegate = self;
    _scn.rendersContinuously = NO;
    [self addSubview:_scn];

    // cockpit framing (over the scene, under the overlays)
    _cockpit = [[FlightCockpit alloc] initWithFrame:self.bounds];
    _cockpit.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_cockpit];

    // minimap — a second view of the SAME scene from the external camera, inset
    // top-right with a border (the old third-person view, as a 3D map)
    CGFloat mw = 230, mh = 158;
    _mini = [[SCNView alloc] initWithFrame:
        NSMakeRect(self.bounds.size.width-mw-12, self.bounds.size.height-mh-12, mw, mh)];
    _mini.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    _mini.scene = _scn.scene; _mini.pointOfView = _miniCam;
    _mini.backgroundColor = [NSColor colorWithSRGBRed:0.03 green:0.04 blue:0.06 alpha:1];
    _mini.rendersContinuously = NO;
    _mini.wantsLayer = YES; _mini.layer.borderWidth = 1.0; _mini.layer.cornerRadius = 6;
    _mini.layer.borderColor = [NSColor colorWithSRGBRed:0.3 green:0.7 blue:0.5 alpha:0.85].CGColor;
    [self addSubview:_mini];
    NSTextField *ml = [NSTextField labelWithString:@"MAP  ·  ● fly   ◆ food"];
    ml.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightSemibold];
    ml.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:0.9];
    ml.frame = NSMakeRect(7, mh-15, mw-12, 12);
    ml.autoresizingMask = NSViewMaxXMargin;
    [_mini addSubview:ml];

    // HUD (top, above everything)
    _hud = [NSTextField labelWithString:@""];
    _hud.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _hud.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:1];
    _hud.frame = NSMakeRect(14, self.bounds.size.height-76, 560, 62);
    _hud.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    _hud.maximumNumberOfLines = 4;
    [self addSubview:_hud];
}

- (void)setActive:(BOOL)active {
    _active = active;
    _scn.rendersContinuously = active;
    _mini.rendersContinuously = active;
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
- (NSImage *)_gridImage {
    CGFloat S = 256; NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(S,S)];
    [img lockFocus];
    [[NSColor colorWithSRGBRed:0.05 green:0.06 blue:0.08 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,S,S));
    [[NSColor colorWithSRGBRed:0.12 green:0.20 blue:0.18 alpha:1] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 3;
    [p moveToPoint:NSMakePoint(1,0)]; [p lineToPoint:NSMakePoint(1,S)];
    [p moveToPoint:NSMakePoint(0,1)]; [p lineToPoint:NSMakePoint(S,1)];
    [p stroke]; [img unlockFocus]; return img;
}

- (void)_resetFlight {
    _pos = V3(-WORLD*0.7, 9, -WORLD*0.7);
    _yaw = 0.6; _pitch = 0; _lastT = 0; _calib = 0; _baseline = 0;
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

    // READ descending command
    FlySnapshot s = [_fly snapshot];
    double asym = s.dnLeftRate - s.dnRightRate;
    if (_calib == 0) { _baseline = asym; _calib = 1; }

    if (visible) {
        if (fabs(bearing) < 0.15) _baseline += (asym - _baseline) * 0.02;
        double turn = asym - _baseline;
        if (fabs(turn) < YAW_DEAD) turn = 0;
        double yawRate = turn * YAW_GAIN;
        if (yawRate >  YAW_MAX) yawRate =  YAW_MAX;
        if (yawRate < -YAW_MAX) yawRate = -YAW_MAX;
        _yaw += yawRate * dt;
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

    // FIRST-PERSON camera: at the eye (led ahead of the body so the fly itself
    // stays out of frame here but still shows on the map), looking along heading
    _camNode.position  = V3(_pos.x + fwd.x*1.8, _pos.y + 0.12, _pos.z + fwd.z*1.8);
    _lookNode.position = V3(_pos.x + fwd.x*20,  _pos.y + fwd.y*20, _pos.z + fwd.z*20);

    if (vdist(_pos, _foodPos) < CATCH) { _caught++; [self _placeFood]; _calib = 0; }

    static int hk = 0; if ((hk++ % 6) == 0) {
        NSString *txt = [NSString stringWithFormat:
            @"FIRST-PERSON FLIGHT — what the fly sees, steered by its brain\n"
            @"descending  L %5.1f  R %5.1f   (L−R %+5.1f Hz → yaw)\n"
            @"eyes  L %3.0f%%  R %3.0f%%   ·   smell %3.0f%%   ·   caught: %d\n"
            @"%@",
            s.dnLeftRate, s.dnRightRate, (s.dnLeftRate - s.dnRightRate),
            _fly.lightLeftHz/MAXVIS*100, _fly.lightRightHz/MAXVIS*100, odorHead*100, _caught,
            visible ? @"vision: fixating the food → descending → turn toward it"
                    : @"food out of view — casting to find it"];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_hud.stringValue = txt; });
    }
}
@end
