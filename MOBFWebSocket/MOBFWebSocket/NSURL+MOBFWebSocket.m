//
//  NSURL+MOBFWebSocket.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/30.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "NSURL+MOBFWebSocket.h"

@implementation NSURL (MOBFWebSocket)

//ws://host:port -> (http/https)://host:port
- (NSString *)mobf_origin
{
    //小写
    NSString *scheme = [self.scheme lowercaseString];
    
    if ([scheme isEqualToString:@"wss"]) {
        scheme = @"https";
    } else if ([scheme isEqualToString:@"ws"]) {
        scheme = @"http";
    }
    
    BOOL portIsDefault = !self.port ||
    ([scheme isEqualToString:@"http"] && self.port.integerValue == 80) ||
    ([scheme isEqualToString:@"https"] && self.port.integerValue == 443);
    
    if (!portIsDefault) {
        return [NSString stringWithFormat:@"%@://%@:%@", scheme, self.host, self.port];
    } else {
        return [NSString stringWithFormat:@"%@://%@", scheme, self.host];
    }
}

@end
