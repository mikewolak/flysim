// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FSWidgets.h — Logic-Pro-styled custom controls drawn with CoreGraphics.
//  Dark charcoal panels, illuminated toggle buttons, LED meters, and a
//  scrolling population-activity heatmap.

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
@end

NS_ASSUME_NONNULL_END
