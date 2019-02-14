//
//  NSRunLoop+MOBFWebSocket.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "NSRunLoop+MOBFWebSocket.h"
#import "MOBFRunLoopThread.h"

static MOBFRunLoopThread *networkThread = nil;
static NSRunLoop *networkRunLoop = nil;

@implementation NSRunLoop (MOBFWebSocket)

+ (NSRunLoop *)mobf_networkRunLoop
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        networkThread = [[MOBFRunLoopThread alloc] init];
        networkThread.name = @"com.mob.webSocket.NetworkThread";
        [networkThread start];
        networkRunLoop = networkThread.runLoop;
    });
    return networkRunLoop;
}

@end
