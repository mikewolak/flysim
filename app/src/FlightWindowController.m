// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlightWindowController.m
//
//  A 3D arena where a dot-fly searches for food. The loop is closed through the
//  connectome: the food emits an odor; the fly's LEFT and RIGHT olfactory ORNs
//  are clamped to the odor each antenna senses; the brain runs; the LEFT vs
//  RIGHT DESCENDING NEURONS (the brain's real command lines to the body) set the
//  fly's yaw. Forward cruise + a vertical odor-gradient climb complete a minimal
//  body. So: bilateral smell in → descending output → steering.

#import "FlightWindowController.h"
#import "FlyController.h"
#import <SceneKit/SceneKit.h>

// world / flight constants (SceneKit units)
#define WORLD     20.0
#define ALT_MIN    2.5
#define ALT_MAX   24.0
#define LAMBDA    13.0      // odor plume width
#define MAXOLF   200.0      // ORN clamp at the plume centre (Hz)
#define MAXVIS   200.0      // photoreceptor clamp for a fixated target (Hz)
#define HEAD_F     0.8      // antennae forward of body
#define ANT_SPR    2.4      // antenna half-separation — wide, for a usable L/R signal
#define V_SAMPLE   1.4      // up/down odor sample for climb
#define CRUISE     7.0      // forward speed (units/s)
#define CATCH      5.0
#define YAW_GAIN   0.45     // descending asymmetry (Hz) → yaw rate (rad/s)
#define YAW_MAX    2.2      // clamp so it banks, never free-spins
#define YAW_DEAD   0.4      // deadband: fly straight when aimed (kills jitter-circling)
#define PITCH_GAIN 5.0

static SCNVector3 V3(CGFloat x, CGFloat y, CGFloat z){ return SCNVector3Make(x,y,z); }
static CGFloat vdist(SCNVector3 a, SCNVector3 b){
    CGFloat dx=a.x-b.x, dy=a.y-b.y, dz=a.z-b.z; return sqrt(dx*dx+dy*dy+dz*dz);
}

@interface FlightWindowController () <SCNSceneRendererDelegate, NSWindowDelegate>
@end

@implementation FlightWindowController {
    FlyController *_fly;
    SCNView   *_scn;
    SCNNode   *_flyNode, *_foodNode, *_camNode;
    NSTextField *_hud;

    SCNVector3 _pos, _foodPos;
    double _yaw, _pitch, _lastT, _castPhase;
    int    _caught;

    // descending-asymmetry calibration (the brain has a small left/right bias)
    int    _calib;
    double _baseAcc, _baseline;
}

- (instancetype)initWithFly:(FlyController *)fly {
    NSRect frame = NSMakeRect(0, 0, 880, 600);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                  backing:NSBackingStoreBuffered defer:NO];
    if (!(self = [super initWithWindow:win])) return nil;
    _fly = fly;
    win.title = @"FlySim — 3D Flight  ·  brain-steered odor search";
    win.releasedWhenClosed = NO;
    win.delegate = self;
    if (@available(macOS 10.14, *)) win.appearance =
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [win center];

    [self _build];
    if (!_fly.running) [_fly start];     // need the clock running for DN output
    [self _resetFlight];
    return self;
}

- (void)_build {
    SCNScene *scene = [SCNScene scene];

    // ground: dark reflective floor with a faint grid
    SCNFloor *floor = [SCNFloor floor];
    floor.reflectivity = 0.08;
    floor.firstMaterial.diffuse.contents = [self _gridImage];
    floor.firstMaterial.diffuse.wrapS = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.wrapT = SCNWrapModeRepeat;
    floor.firstMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(60,60,0);
    SCNNode *floorNode = [SCNNode nodeWithGeometry:floor];
    [scene.rootNode addChildNode:floorNode];

    // food: glowing amber sphere + slow odor particles
    SCNSphere *fs = [SCNSphere sphereWithRadius:0.7];
    fs.firstMaterial.diffuse.contents  = [NSColor colorWithSRGBRed:1 green:0.72 blue:0.25 alpha:1];
    fs.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:1 green:0.62 blue:0.18 alpha:1];
    _foodNode = [SCNNode nodeWithGeometry:fs];
    SCNParticleSystem *odor = [SCNParticleSystem particleSystem];
    odor.birthRate = 26; odor.particleLifeSpan = 3.2; odor.particleSize = 0.5;
    odor.particleColor = [NSColor colorWithSRGBRed:1 green:0.7 blue:0.3 alpha:0.18];
    odor.emittingDirection = V3(0,1,0); odor.spreadingAngle = 180;
    odor.particleVelocity = 1.2; odor.blendMode = SCNParticleBlendModeAdditive;
    odor.particleImage = [self _softDot];
    odor.emitterShape = [SCNSphere sphereWithRadius:0.7];
    [_foodNode addParticleSystem:odor];
    // gentle pulse
    SCNAction *pulse = [SCNAction sequence:@[
        [SCNAction scaleTo:1.18 duration:0.9], [SCNAction scaleTo:1.0 duration:0.9]]];
    [_foodNode runAction:[SCNAction repeatActionForever:pulse]];
    [scene.rootNode addChildNode:_foodNode];

    // fly: small bright dot + a glowing motion trail
    SCNSphere *bs = [SCNSphere sphereWithRadius:0.28];
    bs.firstMaterial.diffuse.contents  = [NSColor colorWithSRGBRed:0.8 green:1 blue:0.85 alpha:1];
    bs.firstMaterial.emission.contents = [NSColor colorWithSRGBRed:0.5 green:1 blue:0.7 alpha:1];
    _flyNode = [SCNNode nodeWithGeometry:bs];
    SCNParticleSystem *trail = [SCNParticleSystem particleSystem];
    trail.birthRate = 90; trail.particleLifeSpan = 1.6; trail.particleSize = 0.12;
    trail.particleColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:1];
    trail.blendMode = SCNParticleBlendModeAdditive; trail.particleVelocity = 0;
    trail.particleImage = [self _softDot];
    trail.local = NO;   // world-space → leaves a trail behind the moving fly
    [_flyNode addParticleSystem:trail];
    [scene.rootNode addChildNode:_flyNode];

    // lights
    SCNNode *amb = [SCNNode node]; amb.light = [SCNLight light];
    amb.light.type = SCNLightTypeAmbient;
    amb.light.color = [NSColor colorWithWhite:0.35 alpha:1];
    [scene.rootNode addChildNode:amb];
    SCNNode *key = [SCNNode node]; key.light = [SCNLight light];
    key.light.type = SCNLightTypeOmni; key.position = V3(10,30,20);
    [scene.rootNode addChildNode:key];

    // camera (user can orbit)
    _camNode = [SCNNode node]; _camNode.camera = [SCNCamera camera];
    _camNode.camera.zFar = 400;
    _camNode.position = V3(0, 26, 44);
    SCNNode *look = [SCNNode node]; look.position = V3(0, 9, 0);
    [scene.rootNode addChildNode:look];
    SCNLookAtConstraint *la = [SCNLookAtConstraint lookAtConstraintWithTarget:look];
    _camNode.constraints = @[la];
    [scene.rootNode addChildNode:_camNode];

    _scn = [[SCNView alloc] initWithFrame:self.window.contentView.bounds];
    _scn.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scn.scene = scene;
    _scn.backgroundColor = [NSColor colorWithSRGBRed:0.04 green:0.05 blue:0.07 alpha:1];
    _scn.allowsCameraControl = YES;
    _scn.rendersContinuously = YES;
    _scn.pointOfView = _camNode;
    _scn.delegate = self;
    self.window.contentView = _scn;

    // HUD
    _hud = [NSTextField labelWithString:@""];
    _hud.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _hud.textColor = [NSColor colorWithSRGBRed:0.4 green:1 blue:0.7 alpha:1];
    _hud.frame = NSMakeRect(14, self.window.contentView.bounds.size.height-78, 560, 64);
    _hud.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    _hud.maximumNumberOfLines = 4;
    [_scn addSubview:_hud];
}

// a soft radial dot, so particles glow instead of rendering as hard squares
- (NSImage *)_softDot {
    CGFloat S = 64;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(S,S)];
    [img lockFocus];
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:1.0], 0.0,
        [NSColor colorWithWhite:1 alpha:0.5], 0.45,
        [NSColor colorWithWhite:1 alpha:0.0], 1.0, nil];
    [g drawInRect:NSMakeRect(0,0,S,S) relativeCenterPosition:NSZeroPoint];
    [img unlockFocus];
    return img;
}
- (NSImage *)_gridImage {
    CGFloat S = 256;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(S,S)];
    [img lockFocus];
    [[NSColor colorWithSRGBRed:0.05 green:0.06 blue:0.08 alpha:1] setFill];
    NSRectFill(NSMakeRect(0,0,S,S));
    [[NSColor colorWithSRGBRed:0.13 green:0.18 blue:0.16 alpha:1] setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 3;
    [p moveToPoint:NSMakePoint(1,0)];   [p lineToPoint:NSMakePoint(1,S)];
    [p moveToPoint:NSMakePoint(0,1)];   [p lineToPoint:NSMakePoint(S,1)];
    [p stroke];
    [img unlockFocus];
    return img;
}

- (void)_resetFlight {
    _pos = V3(-WORLD*0.7, 9, -WORLD*0.7);
    _yaw = 0.6; _pitch = 0; _lastT = 0;
    _calib = 0; _baseAcc = 0; _baseline = 0;
    [self _placeFood];
    _flyNode.position = _pos;
}
- (void)_placeFood {
    CGFloat x = ((double)arc4random_uniform(10000)/10000.0*2-1) * WORLD*0.78;
    CGFloat z = ((double)arc4random_uniform(10000)/10000.0*2-1) * WORLD*0.78;
    CGFloat y = 6 + (double)arc4random_uniform(10000)/10000.0 * 13;   // up in the air
    _foodPos = V3(x,y,z);
    _foodNode.position = _foodPos;
}

- (CGFloat)_concAt:(SCNVector3)p {
    CGFloat d = vdist(p, _foodPos)/LAMBDA; return exp(-d*d);
}

// ---- the flight loop: bilateral smell → descending → steering ----------------
- (void)renderer:(id<SCNSceneRenderer>)r updateAtTime:(NSTimeInterval)t {
    double dt = (_lastT > 0) ? (t - _lastT) : (1.0/60.0);
    _lastT = t;
    if (dt <= 0 || dt > 0.1) dt = 1.0/60.0;

    // heading basis
    double cy = cos(_yaw), sy = sin(_yaw), cp = cos(_pitch), sp = sin(_pitch);
    SCNVector3 fwd   = V3(sy*cp, sp, cy*cp);
    SCNVector3 right = V3(cy, 0, -sy);

    // antennae positions, and the odor each one smells
    SCNVector3 head = V3(_pos.x+fwd.x*HEAD_F, _pos.y+fwd.y*HEAD_F, _pos.z+fwd.z*HEAD_F);
    SCNVector3 antL = V3(head.x-right.x*ANT_SPR, head.y, head.z-right.z*ANT_SPR);
    SCNVector3 antR = V3(head.x+right.x*ANT_SPR, head.y, head.z+right.z*ANT_SPR);
    CGFloat oL = [self _concAt:antL], oR = [self _concAt:antR];
    CGFloat odorHead = [self _concAt:head];

    // SENSE 1 — smell: each antenna's odor → its ORNs (long-range plume cue)
    _fly.smellLeftHz  = (float)(oL * MAXOLF);
    _fly.smellRightHz = (float)(oR * MAXOLF);

    // SENSE 2 — vision: where does the food fall in the visual field? Stimulate
    // the eye it lands on (left eye if it's to the left, etc.) — target fixation,
    // the strong directional cue smell can't give.
    double tx = _foodPos.x - _pos.x, tz = _foodPos.z - _pos.z;
    double th = hypot(tx, tz); if (th < 1e-3) th = 1e-3;
    double ux = tx/th, uz = tz/th;
    double dotF   = sy*ux + cy*uz;            // >0 → food ahead
    double crossF = sy*uz - cy*ux;            // signed → which side
    double bearing = atan2(crossF, dotF);     // 0 = dead ahead
    BOOL   visible = dotF > -0.25;            // wide frontal field
    double rfrac = 0.5 - 0.5*(bearing/(M_PI*0.55));   // 0 = left eye … 1 = right eye
    if (rfrac < 0) rfrac = 0; if (rfrac > 1) rfrac = 1;
    _fly.lightLeftHz  = (float)(visible ? MAXVIS*(1.0-rfrac) : 0);
    _fly.lightRightHz = (float)(visible ? MAXVIS*rfrac       : 0);
    // while fixating, steer on VISION ALONE — the diffuse plume otherwise adds a
    // big non-directional bias to the descending output and drowns the bearing.
    if (visible) { _fly.smellLeftHz = 0; _fly.smellRightHz = 0; }

    // READ the brain's descending command (now integrating smell + vision)
    FlySnapshot s = [_fly snapshot];
    double asym = s.dnLeftRate - s.dnRightRate;
    if (_calib == 0) { _baseline = asym; _calib = 1; }

    if (visible) {
        // learn the brain's L/R bias while fixated (food ahead → eyes ~equal)
        if (fabs(bearing) < 0.15) _baseline += (asym - _baseline) * 0.02;
        // steer toward the food: the descending asymmetry points the way
        double turn = asym - _baseline;
        if (fabs(turn) < YAW_DEAD) turn = 0;
        double yawRate = turn * YAW_GAIN;
        if (yawRate >  YAW_MAX) yawRate =  YAW_MAX;
        if (yawRate < -YAW_MAX) yawRate = -YAW_MAX;
        _yaw += yawRate * dt;                 // +: food-right → asym+ → bank right
        // climb/dive toward the food's elevation (visual)
        double pitchT = atan2(_foodPos.y - _pos.y, th);
        if (pitchT >  0.7) pitchT =  0.7; if (pitchT < -0.7) pitchT = -0.7;
        _pitch += (pitchT - _pitch) * 0.10;
    } else {
        // food behind → cast (turn around) to bring it back into view
        _castPhase += dt * 1.5;
        _yaw += sin(_castPhase) * 1.8 * dt;
    }

    // gentle boundary steer: bank back toward the arena centre near the edges
    if (fabs(_pos.x) > WORLD || fabs(_pos.z) > WORLD) {
        double toC = atan2(-_pos.x, -_pos.z);
        double d = toC - _yaw;
        while (d >  M_PI) d -= 2*M_PI; while (d < -M_PI) d += 2*M_PI;
        _yaw += d * 1.5 * dt;
    }

    // integrate — slow down near the source (high odor) so it spirals in and
    // catches instead of orbiting at full cruise like a moth round a bulb
    double speed = CRUISE * (1.0 - 0.72*odorHead);   // slow to a near-hover on the food
    cy = cos(_yaw); sy = sin(_yaw); cp = cos(_pitch); sp = sin(_pitch);
    fwd = V3(sy*cp, sp, cy*cp);
    _pos = V3(_pos.x + fwd.x*speed*dt, _pos.y + fwd.y*speed*dt, _pos.z + fwd.z*speed*dt);
    if (_pos.y < ALT_MIN) { _pos.y = ALT_MIN; if (_pitch < 0) _pitch = 0; }
    if (_pos.y > ALT_MAX) { _pos.y = ALT_MAX; if (_pitch > 0) _pitch = 0; }
    _flyNode.position = _pos;
    _flyNode.eulerAngles = V3(-_pitch, _yaw, 0);

    // caught it?
    if (vdist(_pos, _foodPos) < CATCH) {
        _caught++;
        [self _placeFood];
        _calib = 0; _baseAcc = 0;   // recalibrate for the new source direction
    }

    // HUD (throttled, on main)
    static int hk = 0; if ((hk++ % 6) == 0) {
        NSString *txt = [NSString stringWithFormat:
            @"3D FLIGHT — steered by the connectome\n"
            @"descending  L %5.1f   R %5.1f   (L−R %+5.1f Hz → yaw)\n"
            @"eyes  L %3.0f%%  R %3.0f%%   ·   smell %3.0f%%   ·   alt %4.1f   caught: %d\n"
            @"%@",
            s.dnLeftRate, s.dnRightRate, (s.dnLeftRate - s.dnRightRate),
            _fly.lightLeftHz/MAXVIS*100, _fly.lightRightHz/MAXVIS*100, odorHead*100,
            _pos.y, _caught,
            visible ? @"vision: fixating the food → descending → turn"
                    : @"food behind — casting to find it"];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_hud.stringValue = txt; });
    }
}

- (void)windowWillClose:(NSNotification *)n {
    _scn.delegate = nil; _scn.rendersContinuously = NO;
    _fly.smellLeftHz = _fly.smellRightHz = 0;   // hand the senses back to the 2D view
    _fly.lightLeftHz = _fly.lightRightHz = 0;
}
@end
