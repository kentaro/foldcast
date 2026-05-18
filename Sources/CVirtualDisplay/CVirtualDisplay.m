#import "CVirtualDisplay.h"

// ---------------------------------------------------------------------------
// Private CoreGraphics (SkyLight) virtual-display interface.
// These ObjC classes ship inside CoreGraphics; they are resolved at runtime.
// We only declare the members we actually use plus the well-known layout used
// by BetterDummy/BetterDisplay so the compiler knows the selectors & types.
// ---------------------------------------------------------------------------

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id terminationHandler, CGVirtualDisplay *display);
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGPoint whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) uint32_t hiDPI;
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) uint32_t displayID;
@end

// ---------------------------------------------------------------------------

@implementation FCVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                                 hiDPI:(BOOL)hiDPI
                                  name:(NSString *)name {
    self = [super init];
    if (!self) { return nil; }

    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class setsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class dispClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descClass || !setsClass || !modeClass || !dispClass) {
        NSLog(@"[foldcast] CGVirtualDisplay private API unavailable on this macOS.");
        return nil;
    }

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    desc.name = name;
    desc.vendorID = 0x1AE5;   // arbitrary, stable across launches
    desc.productID = 0xF07D;
    desc.serialNum = 0x0001;
    desc.maxPixelsWide = (uint32_t)width;
    desc.maxPixelsHigh = (uint32_t)height;
    // ~0.1 mm/px keeps DPI sane; aspect mirrors the pixel size.
    desc.sizeInMillimeters = CGSizeMake(width * 0.12, height * 0.12);
    desc.redPrimary    = CGPointMake(0.640, 0.330);
    desc.greenPrimary  = CGPointMake(0.300, 0.600);
    desc.bluePrimary   = CGPointMake(0.150, 0.060);
    desc.whitePoint    = CGPointMake(0.3127, 0.3290);
    desc.terminationHandler = ^(id handler, CGVirtualDisplay *d) {
        NSLog(@"[foldcast] virtual display terminated.");
    };

    _display = [[dispClass alloc] initWithDescriptor:desc];
    if (!_display) {
        NSLog(@"[foldcast] failed to create CGVirtualDisplay.");
        return nil;
    }

    CGVirtualDisplayMode *mode =
        [[modeClass alloc] initWithWidth:width height:height refreshRate:60.0];
    CGVirtualDisplaySettings *settings = [[setsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[mode];

    if (![_display applySettings:settings]) {
        NSLog(@"[foldcast] applySettings failed.");
        _display = nil;
        return nil;
    }

    _displayID = _display.displayID;
    _width = width;
    _height = height;
    return self;
}

- (void)invalidate {
    _display = nil;
}

@end
