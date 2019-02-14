//
//  SocketBase.h
//  WebSocketDemo
//
//  Created by wukx on 2018/9/6.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SocketBase : NSObject

typedef enum : NSUInteger {
    DisConnectByClient ,
    DisConnectByServer,
} DisConnectType;

+ (instancetype)share;

- (void)connect;
- (void)disConnect;

- (void)sendMsg:(NSString *)msg;

- (void)ping;

@end
