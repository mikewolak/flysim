// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FlightWindowController.h — a 3D world where a dot-fly flies to find food,
//  STEERED BY THE CONNECTOME: bilateral olfactory ORNs in → descending neurons
//  out → yaw. The brain closes the loop through a minimal body.

#import <Cocoa/Cocoa.h>
@class FlyController;

@interface FlightWindowController : NSWindowController
- (instancetype)initWithFly:(FlyController *)fly;
@end
