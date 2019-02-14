//
//  MOBFWebSocket.h
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Security/SecCertificate.h>


typedef NS_ENUM(unsigned int, MOBFWebSocketReadyState) {
    MOBFWebSocketStateConnecting        = 0,
    MOBFWebSocketStateOpen              = 1,
    MOBFWebSocketStateClosing           = 2,
    MOBFWebSocketStateClosed            = 3,
};

typedef NS_ENUM(NSInteger, MOBFStatusCode) {
    MOBFStatusCodeNormal                = 1000,
    MOBFStatusCodeGoingAway             = 1001,
    MOBFStatusCodeProtocolError         = 1002,
    MOBFStatusCodeUnhandledType         = 1003,
    // 1004 reserved.
    MOBFStatusNoStatusReceived          = 1005,
    // 1004-1006 reserved.
    MOBFStatusCodeInvalidUTF8           = 1007,
    MOBFStatusCodePolicyViolated        = 1008,
    MOBFStatusCodeMessageTooBig         = 1009,
};

typedef NS_ENUM(NSInteger, MOBFOpCode)
{
    MOBFOpCodeTextFrame = 0x1,
    MOBFOpCodeBinaryFrame = 0x2,
    // 3-7 reserved.
    MOBFOpCodeConnectionClose = 0x8,
    MOBFOpCodePing = 0x9,
    MOBFOpCodePong = 0xA,
    // B-F reserved.
};

@class MOBFWebSocket;

extern NSString *const MOBFWebSocketErrorDomain;
extern NSString *const MOBFHTTPResponseErrorKey;


#pragma mark - MOBFWebSocketDelegate

@protocol MOBFWebSocketDelegate <NSObject>

// 接收消息， 'UTF8 String' or 'NSData'
- (void)webSocket:(MOBFWebSocket *)webSocket didReceiveMessage:(id)message;

@optional

- (void)webSocketDidOpen:(MOBFWebSocket *)webSocket;
- (void)webSocket:(MOBFWebSocket *)webSocket didFailWithError:(NSError *)error;
- (void)webSocket:(MOBFWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;


- (void)webSocket:(MOBFWebSocket *)webSocket didReceivePong:(NSData *)pongPayload;

@end


#pragma mark - MOBFWebSocket

@interface MOBFWebSocket : NSObject <NSStreamDelegate>

@property (nonatomic, weak) id <MOBFWebSocketDelegate> delegate;

@property (nonatomic, readonly)  MOBFWebSocketReadyState readyState;
@property (nonatomic, readonly, retain) NSURL *url;

@property (nonatomic, readonly) CFHTTPMessageRef receivedHTTPHeaders;

// Optional array of cookies (NSHTTPCookie objects) to apply to the connections
@property (nonatomic, readwrite) NSArray * requestCookies;

// webSocket协议
// 完成握手后赋值
@property (nonatomic, readonly, copy) NSString *protocol;


// 值为string类型的协议数组 Sec-WebSocket-Protocol.
- (instancetype)initWithURLRequest:(NSURLRequest *)request protocols:(NSArray *)protocols;
- (instancetype)initWithURLRequest:(NSURLRequest *)request;

// 线程队列 如果不设置OperationQueue/dispatch_queue 默认使用dispatch_main_queue
//- (void)setDelegateOperationQueue:(NSOperationQueue*) queue;
- (void)setDelegateDispatchQueue:(dispatch_queue_t) queue;

//- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode;
//- (void)unscheduleFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode;

// MOBFWebSocket 仅调用一次.
- (void)open;

- (void)close;
- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;

// 数据发送(类型：UTF8 String or Data).
- (void)send:(id)data;

// Send Data (can be nil) in a ping message.
- (void)sendPing:(NSData *)data;

@end



#pragma mark - NSRunLoop (MOBFWebSocket)

@interface NSRunLoop (MOBFWebSocket)

+ (NSRunLoop *)mobf_networkRunLoop;

@end












