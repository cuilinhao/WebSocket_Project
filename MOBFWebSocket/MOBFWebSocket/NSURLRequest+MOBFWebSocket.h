//
//  NSURLRequest+MOBFWebSocket.h
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>




#pragma mark - NSURLRequest (MOBFWebSocket)

@interface NSURLRequest (MOBFWebSocket)

@property (nonatomic, retain, readonly) NSArray *mobf_SSLPinnedCertificates;

@end



#pragma mark - NSMutableURLRequest (MOBFWebSocket)

@interface NSMutableURLRequest (MOBFWebSocket)

@property (nonatomic, retain) NSArray *mobf_SSLPinnedCertificates;

@end
