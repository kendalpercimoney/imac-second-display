#import <Cocoa/Cocoa.h>
#import "LSAppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        // NSApplication holds its delegate weakly, so the strong local has to
        // outlive -run. A static is the least surprising way to do that.
        static LSAppDelegate *delegate = nil;
        delegate = [[LSAppDelegate alloc] init];
        [application setDelegate:delegate];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
