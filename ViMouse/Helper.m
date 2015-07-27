//
//  Helper.m
//  ViMouse
//
//  Created by TakiuchiGenki on 2015/07/27.
//  Copyright © 2015年 s21g Inc. All rights reserved.
//

#import "ViMouse-Bridging-Header.h"

CGEventRef VMCreateMouseWheelEvent(NSInteger count, NSInteger wv, NSInteger wh){
    return CGEventCreateScrollWheelEvent(nil, kCGScrollEventUnitPixel,
                                         (uint32_t)count, (int32_t)wv, (int32_t)wh);
}
