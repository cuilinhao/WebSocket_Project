//
//  NSData+MOBFWebSocket.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "NSData+MOBFWebSocket.h"
#import <CommonCrypto/CommonDigest.h>

@implementation NSData (MOBFWebSocket)

+ (NSData *)mobf_SHA1HashFromString:(NSString *)string
{
    size_t length = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    return [NSData mobf_SHA1HashFromBytes:string.UTF8String length:length];
}

+ (NSData *)mobf_SHA1HashFromBytes:(const char *)bytes length:(size_t)length
{
    uint8_t outputLength = CC_SHA1_DIGEST_LENGTH;
    unsigned char output[outputLength];
    CC_SHA1(bytes, (CC_LONG)length, output);
    
    return [NSData dataWithBytes:output length:outputLength];
}

- (NSString *)mobf_Base64EncodedString
{
    if ([self respondsToSelector:@selector(base64EncodedStringWithOptions:)]) {
        return [self base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [self base64Encoding];
#pragma clang diagnostic pop
}

@end
