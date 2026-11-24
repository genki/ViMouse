#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VMTrackpadFrameKind) {
    VMTrackpadFrameKindIdle,
    VMTrackpadFrameKindMultipleOrInvalid,
    VMTrackpadFrameKindBegan,
    VMTrackpadFrameKindMoved,
    VMTrackpadFrameKindEnded,
    VMTrackpadFrameKindApproaching,
};

typedef void (^VMTrackpadFrameHandler)(uintptr_t device, VMTrackpadFrameKind kind,
                                     int32_t identifier, float x, float y, double timestamp);

void VMStartTrackpadMonitoring(VMTrackpadFrameHandler handler);
void VMStopTrackpadMonitoring(void);

NS_ASSUME_NONNULL_END
