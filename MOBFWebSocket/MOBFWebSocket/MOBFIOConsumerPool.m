//
//  MOBFIOConsumerPool.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "MOBFIOConsumerPool.h"

@interface MOBFIOConsumerPool ()
{
    NSUInteger _poolSize;
    NSMutableArray *_bufferedConsumers;
}
@end

@implementation MOBFIOConsumerPool

- (instancetype)initWithBufferCapacity:(NSUInteger)poolSize;
{
    self = [super init];
    if (self) {
        _poolSize = poolSize;
        _bufferedConsumers = [NSMutableArray arrayWithCapacity:poolSize];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithBufferCapacity:8];
}

- (MOBFIOConsumer *)consumerWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;
{
    MOBFIOConsumer *consumer = nil;
    if (_bufferedConsumers.count)
    {
        consumer = _bufferedConsumers.lastObject;
        [_bufferedConsumers removeLastObject];
    }
    else
    {
        consumer = [[MOBFIOConsumer alloc] init];
    }
    
    [consumer setupWithScanner:scanner handler:handler bytesNeeded:bytesNeeded readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes];
    
    return consumer;
}

- (void)returnConsumer:(MOBFIOConsumer *)consumer
{
    if (_bufferedConsumers.count < _poolSize) {
        [_bufferedConsumers addObject:consumer];
    }
}

@end
