//
//  MOBFIOConsumer.h
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>

@class MOBFWebSocket;

typedef size_t (^stream_scanner)(NSData *collected_data);
typedef void (^data_callback)(MOBFWebSocket *webSocket,  NSData *data);

//消费者对象
@interface MOBFIOConsumer : NSObject

@property (nonatomic, copy, readonly) stream_scanner consumer; // 如果!=nil 以consumer返回值作为当前读取了字节数 如果==nil 任务目标为bytesNeeded
@property (nonatomic, copy, readonly) data_callback handler; // 读取bytesNeeded字节数据完成回调
@property (nonatomic, assign, readonly) BOOL readToCurrentFrame; // 是否将读取的数据存入当前帧中
@property (nonatomic, assign) size_t bytesNeeded; // 读取多少字节数据
@property (nonatomic, assign, readonly) BOOL unmaskBytes; // 是否是掩码

- (void)setupWithScanner:(stream_scanner)scanner handler:(data_callback)handler bytesNeeded:(size_t)bytesNeeded readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes;

@end
