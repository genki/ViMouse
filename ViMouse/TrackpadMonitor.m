#import "TrackpadMonitor.h"
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <stddef.h>
#import <math.h>

typedef const void *MTDeviceRef;

// 単一接点の先頭部分だけを読む。OSごとに異なる接点配列のstrideには依存しない。
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t stage;
    int32_t fingerID;
    int32_t handID;
    float x;
    float y;
} MTContactPrefix;

_Static_assert(offsetof(MTContactPrefix, stage) == 20 && offsetof(MTContactPrefix, x) == 32,
               "Unexpected MultitouchSupport contact prefix layout");

typedef int (*MTFrameCallback)(MTDeviceRef, const MTContactPrefix *, int32_t, double, int32_t, void *);

static struct {
    CFArrayRef (*createList)(void);
    bool (*isBuiltIn)(MTDeviceRef);
    int (*getFamilyID)(MTDeviceRef, int32_t *);
    void (*registerFrame)(MTDeviceRef, MTFrameCallback, void *);
    void (*unregisterFrame)(MTDeviceRef, MTFrameCallback);
    void (*start)(MTDeviceRef, int);
    void (*stop)(MTDeviceRef);
} symbols;

static dispatch_queue_t controlQueue;
static NSObject *handlerLock;
static VMTrackpadFrameHandler frameHandler;
static uintptr_t generation;
static IONotificationPortRef notificationPort;
static io_iterator_t addedDevices, removedDevices;
static CFArrayRef deviceList;
static NSMutableArray<NSValue *> *registeredDevices;

static void initializeMonitor(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controlQueue = dispatch_queue_create("com.s21g.ViMouse.trackpad", DISPATCH_QUEUE_SERIAL);
        handlerLock = [NSObject new];
        registeredDevices = [NSMutableArray new];
    });
}

static void loadMultitouchSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                                 RTLD_LAZY | RTLD_LOCAL);
        if (!framework) return;
        symbols.createList = dlsym(framework, "MTDeviceCreateList");
        symbols.isBuiltIn = dlsym(framework, "MTDeviceIsBuiltIn");
        symbols.getFamilyID = dlsym(framework, "MTDeviceGetFamilyID");
        symbols.registerFrame = dlsym(framework, "MTRegisterContactFrameCallbackWithRefcon");
        symbols.unregisterFrame = dlsym(framework, "MTUnregisterContactFrameCallback");
        symbols.start = dlsym(framework, "MTDeviceStart");
        symbols.stop = dlsym(framework, "MTDeviceStop");
    });
}

static int handleFrame(MTDeviceRef device, const MTContactPrefix *touch, int32_t count,
                       double timestamp, int32_t frame, void *context) {
    @autoreleasepool {
        VMTrackpadFrameHandler handler;
        @synchronized (handlerLock) {
            if ((uintptr_t)context != generation) return 0;
            handler = frameHandler;
        }
        if (!handler) return 0;

        VMTrackpadFrameKind kind = VMTrackpadFrameKindMultipleOrInvalid;
        if (count == 0) {
            kind = VMTrackpadFrameKindIdle;
        } else if (count == 1 && touch) {
            // MultitouchSupportの接触状態。3は接触開始、4は接触継続。
            if (touch->stage == 3 || touch->stage == 4) {
                handler((uintptr_t)device, touch->stage == 3 ? VMTrackpadFrameKindBegan : VMTrackpadFrameKindMoved,
                        touch->identifier, touch->x, touch->y, timestamp);
                return 0;
            }
            if (touch->stage == 5) {
                handler((uintptr_t)device, VMTrackpadFrameKindEnded, touch->identifier, touch->x, touch->y, timestamp);
                return 0;
            }
            if (touch->stage == 1 || touch->stage == 2) {
                handler((uintptr_t)device, VMTrackpadFrameKindApproaching, touch->identifier,
                        touch->x, touch->y, timestamp);
                return 0;
            }
            if (touch->stage == 0) {
                handler((uintptr_t)device, VMTrackpadFrameKindApproaching, touch->identifier, NAN, NAN, timestamp);
                return 0;
            }
            if (touch->stage == 6 || touch->stage == 7) {
                // Leaving range has an ID but no reliable terminal position.
                handler((uintptr_t)device, VMTrackpadFrameKindEnded, touch->identifier, NAN, NAN, timestamp);
                return 0;
            }
        }
        handler((uintptr_t)device, kind, 0, 0, 0, timestamp);
    }
    return 0;
}

static bool isTrackpad(MTDeviceRef device) {
    if (symbols.isBuiltIn && symbols.isBuiltIn(device)) return true;
    int32_t family = 0;
    if (!symbols.getFamilyID || symbols.getFamilyID(device, &family) != 0) return false;
    // Magic Trackpadの既知のfamily。Magic Mouseはここに含まれない。
    return family == 128 || family == 129 || family == 130;
}

static void stopMonitoring(void) {
    @synchronized (handlerLock) {
        frameHandler = nil;
        generation++;
    }
    for (NSValue *value in registeredDevices) {
        MTDeviceRef device = value.pointerValue;
        symbols.unregisterFrame(device, handleFrame);
        symbols.stop(device);
    }
    [registeredDevices removeAllObjects];
    if (deviceList) {
        CFRelease(deviceList);
        deviceList = NULL;
    }
}

static void bindDevices(VMTrackpadFrameHandler handler) {
    deviceList = symbols.createList();
    @synchronized (handlerLock) {
        frameHandler = handler;
    }
    if (!deviceList) return;
    for (CFIndex index = 0; index < CFArrayGetCount(deviceList); index++) {
        MTDeviceRef device = CFArrayGetValueAtIndex(deviceList, index);
        if (!device || !isTrackpad(device)) continue;
        [registeredDevices addObject:[NSValue valueWithPointer:device]];
        symbols.registerFrame(device, handleFrame, (void *)generation);
        symbols.start(device, 0);
    }
}

// Draining each iterator also arms it for the next matching notification.
static BOOL drainIterator(io_iterator_t iterator) {
    BOOL found = NO;
    io_object_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOObjectRelease(service);
        found = YES;
    }
    return found;
}

static void devicesChanged(void *context, io_iterator_t iterator) {
    if (!drainIterator(iterator)) return;
    VMTrackpadFrameHandler handler = frameHandler;
    if (!handler) return;
    for (NSValue *value in registeredDevices) {
        handler((uintptr_t)value.pointerValue, VMTrackpadFrameKindMultipleOrInvalid, 0, 0, 0, 0);
    }
    stopMonitoring();
    bindDevices(handler);
}

static void stopDeviceNotifications(void) {
    if (addedDevices) IOObjectRelease(addedDevices);
    if (removedDevices) IOObjectRelease(removedDevices);
    if (notificationPort) IONotificationPortDestroy(notificationPort);
    notificationPort = NULL;
    addedDevices = removedDevices = IO_OBJECT_NULL;
}

void VMStartTrackpadMonitoring(VMTrackpadFrameHandler handler) {
    initializeMonitor();
    dispatch_async(controlQueue, ^{
        stopDeviceNotifications();
        stopMonitoring();
        loadMultitouchSymbols();
        if (!symbols.createList || !symbols.registerFrame || !symbols.unregisterFrame ||
            !symbols.start || !symbols.stop) return;
        notificationPort = IONotificationPortCreate(kIOMasterPortDefault);
        if (notificationPort) {
            IONotificationPortSetDispatchQueue(notificationPort, controlQueue);
            if (IOServiceAddMatchingNotification(notificationPort, kIOFirstMatchNotification,
                    IOServiceMatching("AppleMultitouchDevice"), devicesChanged, NULL, &addedDevices) == KERN_SUCCESS)
                drainIterator(addedDevices);
            if (IOServiceAddMatchingNotification(notificationPort, kIOTerminatedNotification,
                    IOServiceMatching("AppleMultitouchDevice"), devicesChanged, NULL, &removedDevices) == KERN_SUCCESS)
                drainIterator(removedDevices);
        }
        bindDevices(handler);
    });
}

void VMStopTrackpadMonitoring(void) {
    initializeMonitor();
    dispatch_async(controlQueue, ^{
        stopDeviceNotifications();
        stopMonitoring();
    });
}
