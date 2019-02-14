//
//  NSData+MOBFWebSocket.h
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSData (MOBFWebSocket)

+ (NSData *)mobf_SHA1HashFromString:(NSString *)string;

+ (NSData *)mobf_SHA1HashFromBytes:(const char *)bytes length:(size_t)length;

- (NSString *)mobf_Base64EncodedString;

@end
