//  AppDelegate.m
#import "AppDelegate.h"
#import "MainWindowController.h"

@implementation AppDelegate {
    MainWindowController *_main;
}

- (void)buildMenu {
    NSMenu *menuBar = [[NSMenu alloc] init];
    [NSApp setMainMenu:menuBar];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"Hide FlySim" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit FlySim" action:@selector(terminate:) keyEquivalent:@"q"];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    _main = [[MainWindowController alloc] init];
    [_main showWindow:nil];
    [_main.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }
@end
