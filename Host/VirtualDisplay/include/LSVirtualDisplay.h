//
//  LSVirtualDisplay.h
//  A headless display that exists only so the iMac has something to show.
//
//  Capturing an existing display mirrors what is already on the MacBook's
//  screen. To use the iMac as a genuine *second* monitor, macOS has to believe
//  a second monitor is plugged in. The sanctioned ways to do that are a
//  hardware dummy plug or a DriverKit display extension; the practical way is
//  CoreGraphics' private CGVirtualDisplay, which is what every third-party
//  tool in this space uses.
//
//  Because it is private API, everything here goes through NSClassFromString
//  and respondsToSelector. If a future macOS removes or renames it, this
//  returns nil and the host falls back to capturing a real display instead of
//  crashing.
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LSVirtualDisplay : NSObject

/// NO if this macOS does not expose the private classes we need.
+ (BOOL)isSupported;

/// Creates a headless display and publishes it to the window server. Returns
/// nil on failure with a description in `error`.
///
/// The display disappears when this object is deallocated.
- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                           refreshRate:(double)refreshRate
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name
                                 error:(NSError **)error;

/// The CGDirectDisplayID to hand to ScreenCaptureKit.
@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;

@end

NS_ASSUME_NONNULL_END
