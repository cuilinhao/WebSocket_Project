//
//  MOBFRunLoopThread.h
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MOBFRunLoopThread : NSThread

@property (nonatomic, readonly) NSRunLoop *runLoop;

@end
