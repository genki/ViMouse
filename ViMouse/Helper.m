//
//  Helper.m
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/27.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

#import "ViMouse-Bridging-Header.h"

CGEventRef VMCreateMouseWheelEvent(NSInteger wv, NSInteger wh){
    return CGEventCreateScrollWheelEvent(nil, kCGScrollEventUnitPixel, 2, (int32_t)wv, (int32_t)wh);
}

// see also https://github.com/asmagill/hs._asm.undocumented.spaces/blob/master/CGSSpace.h

typedef int CGSConnection;
typedef int CGSWindow;
typedef int CGSValue;
extern CGSConnection _CGSDefaultConnection(void);
extern OSStatus CGSGetWindowCount(const CGSConnection cid, CGSConnection targetCID, int* outCount);
extern OSStatus CGSGetWindowList(const CGSConnection cid, CGSConnection targetCID, int count, int* list, int* outCount);
extern OSStatus CGSGetOnScreenWindowCount(const CGSConnection cid, CGSConnection targetCID, int* outCount);
extern OSStatus CGSGetOnScreenWindowList(const CGSConnection cid, CGSConnection targetCID, int count, int* list, int* outCount);
extern OSStatus CGSGetWindowLevel(const CGSConnection cid, CGSWindow wid,  int *level);
extern OSStatus CGSGetScreenRectForWindow(const CGSConnection cid, CGSWindow wid, CGRect *outRect);
extern OSStatus CGSGetWindowOwner(const CGSConnection cid, const CGSWindow wid, CGSConnection *ownerCid);
extern OSStatus CGSConnectionGetPID(const CGSConnection cid, pid_t *pid, const CGSConnection ownerCid);
extern OSStatus CGSGetConnectionIDForPSN(const CGSConnection cid, ProcessSerialNumber *psn, CGSConnection *out);
typedef uint64_t CGSSpace;
typedef enum _CGSSpaceType {
    kCGSSpaceUser,
    kCGSSpaceFullscreen,
    kCGSSpaceSystem,
    kCGSSpaceUnknown
} CGSSpaceType;
typedef enum _CGSSpaceSelector {
    kCGSSpaceCurrent = 5,
    kCGSSpaceOther = 6,
    kCGSSpaceAll = 7
} CGSSpaceSelector;

extern CFArrayRef CGSCopySpaces(const CGSConnection cid, CGSSpaceSelector type);
extern CFArrayRef CGSCopySpacesForWindows(const CGSConnection cid, CGSSpaceSelector type, CFArrayRef windows);
extern CGSSpaceType CGSSpaceGetType(const CGSConnection cid, CGSSpace space);

extern CFNumberRef CGSWillSwitchSpaces(const CGSConnection cid, CFArrayRef a);
extern void CGSHideSpaces(const CGSConnection cid, NSArray* spaces);
extern void CGSShowSpaces(const CGSConnection cid, NSArray* spaces);

extern void CGSAddWindowsToSpaces(const CGSConnection cid, CFArrayRef windows, CFArrayRef spaces);
extern void CGSRemoveWindowsFromSpaces(const CGSConnection cid, CFArrayRef windows, CFArrayRef spaces);
extern OSStatus CGSMoveWorkspaceWindowList(const CGSConnection connection, CGSWindow *wids, int count, int toWorkspace);

typedef uint64_t CGSManagedDisplay;
extern CGSManagedDisplay kCGSPackagesMainDisplayIdentifier;
extern void CGSManagedDisplaySetCurrentSpace(const CGSConnection cid, CGSManagedDisplay display, CGSSpace space);
extern int CGSSpaceGetCompatID(const CGSConnection cid, CGSSpace space);
extern void CGSSpaceSetCompatID(const CGSConnection cid, CGSSpace space, int compatID);
extern CFStringRef CGSSpaceCopyName(const CGSConnection cid, CGSSpace space);
extern int CGSSpaceGetAbsoluteLevel(const CGSConnection cid, CGSSpace space);
extern void CGSSpaceSetAbsoluteLevel(const CGSConnection cid, CGSSpace space, int level);
extern CFArrayRef CGSCopyManagedDisplaySpaces(const CGSConnection cid);
extern bool CGSManagedDisplayIsAnimating(const CGSConnection cid, CGSManagedDisplay display);
extern void CGSManagedDisplaySetIsAnimating(const CGSConnection cid, CGSManagedDisplay display, bool isAnimating);
extern void CGSSpaceSetFrontPSN(const CGSConnection cid, CGSSpace space, ProcessSerialNumber *psn);
/************************************************************************************************/


/// === spaces ===
///
/// Experimental API for Spaces support.


NSNumber* getcurrentspace(void) {
    NSArray* spaces = (__bridge_transfer NSArray*)CGSCopySpaces(_CGSDefaultConnection(), kCGSSpaceCurrent);
    return [spaces objectAtIndex:0];
}

NSArray* getspaces(void) {
    //NSArray* spaces = (__bridge_transfer NSArray*)CGSCopySpaces(_CGSDefaultConnection(), kCGSSpaceAll);
    NSArray* spaces = (__bridge_transfer NSArray*)CGSCopyManagedDisplaySpaces(_CGSDefaultConnection());
    NSMutableArray *spaceIds = [NSMutableArray array];
    for(NSDictionary *dic in spaces[0][@"Spaces"]){
        [spaceIds addObject:dic[@"ManagedSpaceID"]];
    }
    return spaceIds;
}

int spaces_movetospace(NSInteger dx) {
    NSArray* spaces = getspaces();
    NSNumber *cur = getcurrentspace();
    NSInteger fromidx = [spaces indexOfObject:cur];
    NSInteger toidx = fromidx + dx;
    
    if (toidx < 0 || fromidx == NSNotFound || toidx == fromidx || toidx >= [spaces count])
        goto finish;
    
    NSUInteger from = [[spaces objectAtIndex:fromidx] unsignedLongLongValue];
    NSUInteger to = [[spaces objectAtIndex:toidx] unsignedLongLongValue];
    
    //CGSManagedDisplaySetIsAnimating(_CGSDefaultConnection(), kCGSPackagesMainDisplayIdentifier, YES);
    CGSWillSwitchSpaces(_CGSDefaultConnection(), (__bridge CFArrayRef)(@[@(from)]));
    CGSShowSpaces(_CGSDefaultConnection(), @[@(to)]);
    CGSHideSpaces(_CGSDefaultConnection(), @[@(from)]);
    CGSManagedDisplaySetCurrentSpace(_CGSDefaultConnection(), kCGSPackagesMainDisplayIdentifier, to);
    //CGSManagedDisplaySetIsAnimating(_CGSDefaultConnection(), kCGSPackagesMainDisplayIdentifier, NO);

    ProcessSerialNumber psn = {kNoProcess, kNoProcess};
    CGSSpaceSetFrontPSN(_CGSDefaultConnection(), to, &psn);
finish:
    return 1;
}
