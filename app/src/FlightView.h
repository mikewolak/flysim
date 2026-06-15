// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlightView.h — embeddable 3D first-person flight view. The camera sits at the
//  fly's eye and looks where it's heading, so you see what the fly sees as it
//  hunts food — steered by its own descending neurons.

#import <Cocoa/Cocoa.h>
@class FlyController;

@interface FlightView : NSView
- (instancetype)initWithFly:(FlyController *)fly frame:(NSRect)frame;
- (void)setActive:(BOOL)active;   // run the flight loop only while the tab is shown
@end
