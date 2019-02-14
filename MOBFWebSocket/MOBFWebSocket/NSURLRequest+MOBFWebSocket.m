//
//  NSURLRequest+MOBFWebSocket.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "NSURLRequest+MOBFWebSocket.h"



#pragma mark - NSURLRequest (MOBFWebSocket)

@implementation NSURLRequest (MOBFWebSocket)

- (NSArray *)mobf_SSLPinnedCertificates
{
    return [NSURLProtocol propertyForKey:@"mobf_SSLPinnedCertificates" inRequest:self];
}

@end



#pragma mark - NSMutableURLRequest (MOBFWebSocket)

@implementation NSMutableURLRequest (MOBFWebSocket)

- (NSArray *)mobf_SSLPinnedCertificates
{
    return [NSURLProtocol propertyForKey:@"mobf_SSLPinnedCertificates" inRequest:self];
}

- (void)setMobf_SSLPinnedCertificates:(NSArray *)pinnedCertificates
{
    [NSURLProtocol setProperty:pinnedCertificates forKey:@"mobf_SSLPinnedCertificates" inRequest:self];
}

@end
