// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FSWidgets.h — custom controls drawn with CoreGraphics: panels, toggle
//  buttons, meters, and a scrolling population-activity heatmap.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Shared palette.
@interface FSStyle : NSObject
+ (NSColor *)windowTop;
+ (NSColor *)windowBottom;
+ (NSColor *)panelFill;
+ (NSColor *)panelStroke;
+ (NSColor *)label;
+ (NSColor *)labelDim;
+ (NSColor *)sugar;     // amber
+ (NSColor *)water;     // cyan
+ (NSColor *)bitter;    // red
+ (NSColor *)output;    // green
+ (NSFont  *)mono:(CGFloat)size weight:(NSFontWeight)w;
@end

// A rounded dark panel with a subtle top highlight and a section title.
@interface FSPanel : NSView
@property (nonatomic, copy) NSString *title;
@end

// An illuminated push-on/push-off button tinted by `tint`. `glow` (0..1),
// set live from activity, makes it pulse when its circuit is firing.
@interface FSButton : NSControl
@property (nonatomic, strong) NSColor *tint;
@property (nonatomic, copy)   NSString *label;
@property (nonatomic, copy)   NSString *sublabel;
@property (nonatomic) BOOL isOn;
@property (nonatomic) CGFloat glow;       // 0..1 illumination level
@property (nonatomic) BOOL momentary;     // YES: on only while pressed
@end

// Horizontal LED meter, value 0..1, tinted, with a slow-decay peak tick.
@interface FSMeter : NSView
@property (nonatomic) CGFloat value;      // 0..1
@property (nonatomic, strong) NSColor *tint;
@property (nonatomic, copy) NSString *caption;
@end

// Scrolling heatmap: each pushed column is a vertical slice of per-bin firing
// rate; the strip scrolls left as time advances. This is the "brain" view.
@interface FSActivityView : NSView
- (void)pushBins:(const float *)bins count:(int)n ceiling:(float)ceilHz;
- (void)clearHistory;
// Labeled processing-stage bands for hover tooltips. Each entry:
// @{ @"lo":0..1, @"hi":0..1, @"label":NSString } (0 == bottom of the strip).
- (void)setStages:(NSArray<NSDictionary *> *)stages;
@end

// Animated, anatomically-styled lateral view of the fly head performing the
// Proboscis Extension Reflex. `extension` (0..1, from MN9 → angle) unfolds the
// segmented proboscis (rostrum → haustellum → labellum). With `foodPresent`, a
// sugar droplet sits in reach; when the labellum touches it, `labellumContact`
// goes YES, the labellar lobes spread, and ripples spread through the drop —
// the closed feeding loop. Pure CoreGraphics; no assets.
@interface FSFlyView : NSView
@property (nonatomic) CGFloat extension;            // 0..1 proboscis pose
@property (nonatomic) CGFloat mn9Hz;                // for the overlay caption
@property (nonatomic) CGFloat smellDrive;           // 0..1 olfactory firing → walk
@property (nonatomic) BOOL    foodPresent;          // draw the sugar droplet
@property (nonatomic) BOOL    showLabels;           // anatomical part labels
@property (nonatomic, readonly) BOOL labellumContact; // tip is touching food
@property (nonatomic, readonly) BOOL arrivedAtFood;   // walked over & standing on the food
// Live sensory reactions (0..1), pushed each frame from the afferent firing rates.
// bitterVeto retracts the proboscis (taste veto); touch startles; heat recoils;
// light buzzes the wings — so every sense produces a visible behaviour.
- (void)setReactBitterVeto:(CGFloat)veto touch:(CGFloat)touch
                      heat:(CGFloat)heat light:(CGFloat)light humid:(CGFloat)humid;
// Odor concentration (0..1) the fly's antennae currently sense at its position —
// the controller clamps the olfactory ORNs to this, so smell = real proximity.
@property (nonatomic, readonly) CGFloat perceivedOdor;
@end

NS_ASSUME_NONNULL_END
