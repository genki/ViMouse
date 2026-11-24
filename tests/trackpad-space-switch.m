// Interactive regression test. Run in a logged-in macOS Terminal with
// Accessibility access and at least two Spaces on the pointer's display.
// With two screens it moves the cursor to the other screen during the test.
// clang -fobjc-arc -DCGEventPost=VMTestEventPost -c ViMouse/Helper.m -o /tmp/vimouse-helper.o
// clang -fobjc-arc -framework Cocoa -framework Carbon -framework ApplicationServices \
//   /tmp/vimouse-helper.o tests/trackpad-space-switch.m -o /tmp/test-space-switch && /tmp/test-space-switch
#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import "../ViMouse/ViMouse-Bridging-Header.h"

static NSUInteger postCount;
void VMTestEventPost(CGEventTapLocation tap, CGEventRef event) {
    ++postCount;
    CGEventPost(tap, event);
}

static BOOL boundaryIsQuiet(CGDirectDisplayID screen, NSInteger offset) {
    NSUInteger before = postCount;
    vm_swipe_to_adjacent_space(offset, screen);
    NSLog(@"Boundary offset %ld, display %u: %lu events", (long)offset, screen,
          (unsigned long)(postCount - before));
    return before == postCount;
}

extern int _CGSDefaultConnection(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(int connection);

static NSDictionary *spaceDisplay(CGDirectDisplayID screen) {
    NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(_CGSDefaultConnection()));
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(screen);
    if (!uuid) return nil;
    NSString *name = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    for (NSDictionary *display in displays) {
        NSString *identifier = display[@"Display Identifier"];
        if ([identifier isEqual:name] || (screen == CGMainDisplayID() && [identifier isEqual:@"Main"])) return display;
    }
    return nil;
}

int main(void) { @autoreleasepool {
    CGDirectDisplayID target = vm_pointer_display();
    if (!target) return 2;
    NSDictionary *display = spaceDisplay(target);
    NSArray *spaces = [display[@"Spaces"] valueForKey:@"ManagedSpaceID"];
    NSNumber *original = display[@"Current Space"][@"ManagedSpaceID"];
    NSUInteger index = [spaces indexOfObject:original];
    if (!AXIsProcessTrusted() || !original || spaces.count < 2 || index == NSNotFound) {
        NSLog(@"Test requires Accessibility access and two Spaces on the pointer's display.");
        return 2;
    }
    NSInteger step = index == 0 ? 1 : -1;
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return 2;
    CGPoint originalPoint = CGEventGetLocation(event);
    CFRelease(event);
    CGDirectDisplayID all[16], other = 0;
    uint32_t count = 0;
    CGGetActiveDisplayList(16, all, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (all[i] != target && !CGDisplayIsInMirrorSet(all[i])) { other = all[i]; break; }
    }
    @try {
        if (other) {
            CGRect bounds = CGDisplayBounds(other);
            CGWarpMouseCursorPosition(CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)));
            usleep(200000);
            if (vm_pointer_display() != other) return 2;
        }
        if (other && [spaceDisplay(other)[@"Spaces"] count] == 1 &&
            (!boundaryIsQuiet(other, -1) || !boundaryIsQuiet(other, 1))) return 1;
        for (int leg = 0; leg < 2; ++leg) {
            NSInteger offset = leg ? -step : step;
            NSNumber *expected = leg ? original : spaces[(NSInteger)index + step];
            NSInteger currentIndex = leg ? (NSInteger)index + step : (NSInteger)index;
            if (currentIndex == 0 && !boundaryIsQuiet(target, -1)) return 1;
            if (currentIndex == (NSInteger)spaces.count - 1 && !boundaryIsQuiet(target, 1)) return 1;
            NSUInteger before = postCount;
            vm_swipe_to_adjacent_space(offset, target);
            if (postCount == before) return 1;
            NSNumber *actual = nil;
            for (int attempt = 0; attempt < 30; ++attempt) {
                usleep(100000);
                actual = spaceDisplay(target)[@"Current Space"][@"ManagedSpaceID"];
                if ([actual isEqual:expected]) break;
            }
            NSLog(@"Offset %ld, expected Space %@, observed %@", (long)offset, expected, actual);
            if (![actual isEqual:expected]) return 1;
            usleep(900000);
        }
        if (other && vm_pointer_display() != other) return 1;
        return 0;
    } @finally {
        if (other) CGWarpMouseCursorPosition(originalPoint);
    }
} }
