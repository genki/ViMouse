//
//  Helper.m
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/27.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

#import "ViMouse-Bridging-Header.h"
#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <float.h>

CGEventRef VMCreateMouseWheelEvent(NSInteger wv, NSInteger wh){
    return CGEventCreateScrollWheelEvent(nil, kCGScrollEventUnitPixel, 2, (int32_t)wv, (int32_t)wh);
}

// Horizontal DockSwipe wire format adapted from joshuarli/iss (0BSD).
// Copyright (c) 2026 joshuarli. See https://github.com/joshuarli/iss
// macOS 27 consumes the serialized HID queue record when the event is posted.
#pragma pack(push, 1)
typedef struct {
    uint32_t size, type, options;
    uint8_t depth, reserved[3];
} VMHIDRecord;

typedef struct {
    uint64_t timestamp, sender;
    uint32_t options, attributesLength, count;
} VMHIDQueueHeader;

typedef struct {
    VMHIDRecord header;
    int32_t x, y, z;
    uint32_t mask;
    uint16_t motion, flavor;
    int32_t progress;
} VMFluidTouch;

typedef struct {
    VMHIDRecord header;
    int32_t x, y, z;
} VMSwipeVelocity;
#pragma pack(pop)
_Static_assert(sizeof(VMHIDQueueHeader) == 28 && sizeof(VMFluidTouch) == 40 &&
               sizeof(VMSwipeVelocity) == 28, "unexpected DockSwipe wire layout");

// DockControl uses HID phases, whose values differ from NSEventPhase.
enum { VMSwipeBegan = 1, VMSwipeChanged = 2, VMSwipeEnded = 4 };

static CGEventRef VMCreateSwipeWithHIDPayload(CGEventRef event, uint32_t phase, int sign) {
    NSData *encoded = CFBridgingRelease(CGEventCreateData(NULL, event));
    const uint8_t format[] = {0, 0, 0, 2};
    if (encoded.length < sizeof(format) || memcmp(encoded.bytes, format, sizeof(format)) != 0) return NULL;
    BOOL ended = phase == VMSwipeEnded;
    VMHIDQueueHeader queue = {.timestamp = mach_absolute_time(), .count = ended ? 2 : 1};
    VMFluidTouch touch = {
        .header = {.size = sizeof(touch), .type = 23, .options = phase << 24},
        .x = 6553, .motion = 1, .flavor = 3, .progress = sign * 65536
    };
    VMSwipeVelocity velocity = {
        .header = {.size = sizeof(velocity), .type = 9, .depth = 1},
        .x = sign * 9999 * 65536
    };
    uint16_t size = sizeof(queue) + sizeof(touch) + (ended ? sizeof(velocity) : 0);
    uint16_t field[] = {CFSwapInt16HostToBig(size), CFSwapInt16HostToBig(4205)};
    NSMutableData *data = [encoded mutableCopy];
    [data appendBytes:field length:sizeof(field)];
    [data appendBytes:&queue length:sizeof(queue)];
    [data appendBytes:&touch length:sizeof(touch)];
    if (ended) [data appendBytes:&velocity length:sizeof(velocity)];
    return CGEventCreateFromData(NULL, (__bridge CFDataRef)data);
}

static CGEventRef VMCreateHorizontalSwipe(uint32_t phase, int sign, BOOL usesHID) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return NULL;
    CGEventSetIntegerValueField(event, 55, 30);  // DockControl
    CGEventSetIntegerValueField(event, 110, 23); // DockSwipe
    CGEventSetIntegerValueField(event, 123, 1);  // Horizontal motion
    CGEventSetIntegerValueField(event, 132, phase);
    if (usesHID) {
        CGEventSetDoubleValueField(event, 124, sign);
        CGEventSetDoubleValueField(event, 125, 0.1);
        CGEventSetIntegerValueField(event, 134, phase);
        CGEventSetDoubleValueField(event, 138, 3);
        CGEventSetDoubleValueField(event, 169, (double)mach_absolute_time());
        if (phase == VMSwipeEnded) CGEventSetDoubleValueField(event, 129, sign * 9999);
        CGEventRef augmented = VMCreateSwipeWithHIDPayload(event, phase, sign);
        CFRelease(event);
        return augmented;
    }
    float hint = sign * FLT_TRUE_MIN;
    int32_t bits;
    memcpy(&bits, &hint, sizeof(bits));
    CGEventSetIntegerValueField(event, 135, bits);
    CGEventSetDoubleValueField(event, 139, FLT_TRUE_MIN);
    if (phase == VMSwipeEnded) CGEventSetDoubleValueField(event, 129, sign * 400);
    return event;
}

CGDirectDisplayID vm_pointer_display(void) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return kCGNullDirectDisplay;
    CGPoint point = CGEventGetLocation(event);
    CFRelease(event);
    CGDirectDisplayID display;
    uint32_t count = 0;
    return CGGetDisplaysWithPoint(point, 1, &display, &count) == kCGErrorSuccess && count
        ? display : kCGNullDirectDisplay;
}

extern int _CGSDefaultConnection(void) __attribute__((weak_import));
extern CFArrayRef CGSCopyManagedDisplaySpaces(int connection) __attribute__((weak_import));

static BOOL VMHasAdjacentSpace(CGDirectDisplayID display, NSInteger offset) {
    if (!_CGSDefaultConnection || !CGSCopyManagedDisplaySpaces) return NO;
    NSArray *layouts = CFBridgingRelease(CGSCopyManagedDisplaySpaces(_CGSDefaultConnection()));
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return NO;
    NSString *identifier = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    // With shared Spaces the main layout governs all displays.
    BOOL shared = ![NSScreen screensHaveSeparateSpaces];
    for (NSDictionary *layout in layouts) {
        if (![layout isKindOfClass:NSDictionary.class]) continue;
        NSString *name = layout[@"Display Identifier"];
        BOOL mainLayout = [name isEqual:@"Main"] && (display == CGMainDisplayID() || shared);
        if (![name isEqual:identifier] && !mainLayout && !(shared && layouts.count == 1)) continue;
        NSArray *spaces = layout[@"Spaces"];
        NSDictionary *current = layout[@"Current Space"];
        if (![spaces isKindOfClass:NSArray.class] || ![current isKindOfClass:NSDictionary.class]) return NO;
        NSNumber *active = current[@"ManagedSpaceID"];
        if (![active isKindOfClass:NSNumber.class]) return NO;
        BOOL seenActive = NO, hasPrevious = NO;
        for (NSDictionary *space in spaces) {
            if (![space isKindOfClass:NSDictionary.class]) continue;
            NSNumber *kind = space[@"type"];
            if (kind && ![kind isEqual:@0] && ![kind isEqual:@4]) continue; // desktops and full-screen Spaces
            NSNumber *spaceID = space[@"ManagedSpaceID"];
            if (![spaceID isKindOfClass:NSNumber.class]) continue;
            if ([active isEqual:spaceID]) {
                if (offset < 0) return hasPrevious;
                seenActive = YES;
            } else if (seenActive) {
                return YES;
            }
            hasPrevious = YES;
        }
        return NO;
    }
    return NO;
}

void vm_swipe_to_adjacent_space(NSInteger offset, CGDirectDisplayID display) {
    if ((offset != -1 && offset != 1) || !display || !CGDisplayIsActive(display) ||
        !VMHasAdjacentSpace(display, offset)) return;
    CGRect bounds = CGDisplayBounds(display);
    CGPoint target = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    BOOL usesHID = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
    int progress = (int)offset;
    if (usesHID) {
        NSNumber *natural = [NSUserDefaults.standardUserDefaults objectForKey:@"com.apple.swipescrolldirection"];
        if (!natural || natural.boolValue) progress = -progress;
    }
    CGEventRef begin = VMCreateHorizontalSwipe(VMSwipeBegan, progress, usesHID);
    CGEventRef change = VMCreateHorizontalSwipe(VMSwipeChanged, progress, usesHID);
    CGEventRef end = VMCreateHorizontalSwipe(VMSwipeEnded, progress, usesHID);
    CGEventRef companion = CGEventCreate(NULL);
    if (begin && change && end && companion) {
        CGEventSetIntegerValueField(companion, 55, 29); // Gesture companion for each DockControl event
        CGEventSetLocation(companion, target);
        CGEventRef phases[] = {begin, change, end};
        for (size_t i = 0; i < 3; ++i) {
            CGEventSetLocation(phases[i], target);
            CGEventPost(kCGSessionEventTap, phases[i]);
            CGEventPost(kCGSessionEventTap, companion);
        }
    }
    if (begin) CFRelease(begin);
    if (change) CFRelease(change);
    if (end) CFRelease(end);
    if (companion) CFRelease(companion);
}

typedef void (*VMCoreDockSendNotificationFunction)(CFStringRef notification, uint64_t argument);

static VMCoreDockSendNotificationFunction VMCoreDockSendNotification(void) {
    static VMCoreDockSendNotificationFunction function = NULL;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        void *symbol = dlsym(RTLD_DEFAULT, "CoreDockSendNotification");
        if (symbol == NULL) {
            // Keep the handle open for the lifetime of the process. This is only
            // a symbol lookup; no keyboard-event fallback is used.
            void *handle = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
                RTLD_LAZY | RTLD_LOCAL
            );
            if (handle != NULL) {
                symbol = dlsym(handle, "CoreDockSendNotification");
            }
        }
        function = (VMCoreDockSendNotificationFunction)symbol;
    });

    return function;
}

int vm_mission_control_action(NSInteger mode) {
    CFStringRef notification = NULL;
    switch (mode) {
        case 0:
            notification = CFSTR("com.apple.expose.awake");
            break;
        case 1:
            notification = CFSTR("com.apple.showdesktop.awake");
            break;
        case 2:
            notification = CFSTR("com.apple.expose.front.awake");
            break;
        default:
            return 0;
    }

    VMCoreDockSendNotificationFunction function = VMCoreDockSendNotification();
    if (function == NULL) {
        return 0;
    }

    function(notification, 0);
    return 1;
}
