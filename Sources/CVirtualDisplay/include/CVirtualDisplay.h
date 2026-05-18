#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Swift-friendly wrapper around the private CGVirtualDisplay API.
/// Creates a headless virtual display that macOS treats as a real extended
/// monitor (its own desktop space), which we then capture and stream.
@interface FCVirtualDisplay : NSObject

@property (nonatomic, readonly) uint32_t displayID;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;

/// Returns nil if the private API is unavailable or display creation fails.
- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
