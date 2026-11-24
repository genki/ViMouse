//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <Carbon/Carbon.h>
#import "TrackpadMonitor.h"

CGEventRef VMCreateMouseWheelEvent(NSInteger wv, NSInteger wh);
CGDirectDisplayID vm_pointer_display(void);
void vm_swipe_to_adjacent_space(NSInteger offset, CGDirectDisplayID display);
int vm_mission_control_action(NSInteger mode);
