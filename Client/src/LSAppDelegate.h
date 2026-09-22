//
//  LSAppDelegate.h
//
#import <Cocoa/Cocoa.h>

/// Borderless windows refuse key status unless you say otherwise, and we need
/// key events for the fullscreen and diagnostics shortcuts.
@interface LSWindow : NSWindow
@property (nonatomic, assign) id keyTarget;   // unretained
@end

@interface LSAppDelegate : NSObject <NSApplicationDelegate>
@end
