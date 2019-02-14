//
//  MOBFRunLoopThread.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "MOBFRunLoopThread.h"


@implementation MOBFRunLoopThread
{
    dispatch_group_t _waitGroup;
}

@synthesize runLoop = _runLoop;

- (instancetype)init
{
    self = [super init];
    if (self) {
        _waitGroup = dispatch_group_create();
        dispatch_group_enter(_waitGroup);
    }
    return self;
}

- (void)main
{
    @autoreleasepool {
        _runLoop = [NSRunLoop currentRunLoop];
        dispatch_group_leave(_waitGroup);
        
        //事件源上下文
        CFRunLoopSourceContext sourceCtx = {
            .version = 0,                //事件源上下文的版本，必须设置为0。
            .info = NULL,                //上下文中retain、release、copyDescription、equal、hash、schedule、cancel、perform这八个回调函数所有者对象的指针。
            .retain = NULL,              //
            .release = NULL,             //
            .copyDescription = NULL,     //
            .equal = NULL,               //
            .hash = NULL,                //
            .schedule = NULL,            //该回调函数的作用是将该事件源与给它发送事件消息的线程进行关联，也就是说如果主线程想要给该事件源发送事件消息，那么首先主线程得能获取到该事件源。
            .cancel = NULL,              //该回调函数的作用是使该事件源失效。
            .perform = NULL              //该回调函数的作用是执行其他线程或当前线程给该事件源发来的事件消息。
        };
        
        
        //创建事件源
        //allocator：该参数为对象内存分配器，一般使用默认的分配器kCFAllocatorDefault。
        //order：事件源优先级，当Run Loop中有多个接收相同事件的事件源被标记为待执行时，那么就根据该优先级判断，0为最高优先级别。
        //context：事件源上下文。
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceCtx);
        
        //将事件源添加至Run Loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
        
        CFRelease(source);
        
        while ([_runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {
            
        }
        assert(NO);
    }
}

- (NSRunLoop *)runLoop
{
    dispatch_group_wait(_waitGroup, DISPATCH_TIME_FOREVER);
    return _runLoop;
}

@end
