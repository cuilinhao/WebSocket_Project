//
//  SocketBase.m
//  WebSocketDemo
//
//  Created by wukx on 2018/9/6.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "SocketBase.h"
#import "MOBFWebSocket.h"

#define dispatch_main_async_safe(block)\
if ([NSThread isMainThread]) {\
block();\
} else {\
dispatch_async(dispatch_get_main_queue(), block);\
}

static  NSString * testUrl = @"http://127.0.0.1:8080";

@interface SocketBase() <MOBFWebSocketDelegate>
{
    MOBFWebSocket * _webSocket;
    NSTimer * _heartBeat;
    NSTimeInterval _reConnecTime;
}
@end

@implementation SocketBase

+(instancetype)share
{
    static dispatch_once_t onceToken;
    static SocketBase * instance = nil;
    dispatch_once(&onceToken,^{
        instance=[[self alloc] init];
        [instance initSocket];
    });
    return instance;
}

-(void)initSocket
{
    if (_webSocket) {
        return;
    }
    _webSocket = [[MOBFWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:testUrl]]];
    _webSocket.delegate= self;
    //  设置代理线程queue
    dispatch_queue_t queue = dispatch_queue_create("com.test.queue", DISPATCH_QUEUE_CONCURRENT);
    [_webSocket setDelegateDispatchQueue:queue];
    
    //  连接
    [_webSocket open];
}

//   初始化心跳
-(void)initHearBeat
{
    dispatch_main_async_safe(^{
        [self destoryHeartBeat];
        
        __weak typeof (self) weakSelf=self;
        //心跳设置为3分钟，NAT超时一般为5分钟
        self->_heartBeat=[NSTimer scheduledTimerWithTimeInterval:3*60 repeats:YES block:^(NSTimer * _Nonnull timer) {
            NSLog(@"heart");
            //和服务端约定好发送什么作为心跳标识，尽可能的减小心跳包大小
            [weakSelf sendMsg:@"heart"];
        }];
        [[NSRunLoop currentRunLoop] addTimer:self->_heartBeat forMode:NSRunLoopCommonModes];
    })
}

//   取消心跳
-(void)destoryHeartBeat
{
    dispatch_main_async_safe(^{
        if (self->_heartBeat) {
            [self->_heartBeat invalidate];
            self->_heartBeat=nil;
        }
    })
}

//   建立连接
-(void)connect
{
    [self initSocket];
}
//   断开连接
-(void)disConnect
{
    if (_webSocket) {
        [_webSocket close];
        _webSocket=nil;
    }
}

//   发送消息
-(void)sendMsg:(NSString *)msg
{
    [_webSocket send:msg];
}
//  重连机制
-(void)reConnect
{
    [self disConnect];
    
    //  超过一分钟就不再重连   之后重连5次  2^5=64
    if (_reConnecTime > 64) {
        return;
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_reConnecTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_webSocket = nil;
        [self initSocket];
    });
    
    //   重连时间2的指数级增长
    if (_reConnecTime == 0) {
        _reConnecTime = 2;
    }else{
        _reConnecTime *= 2;
    }
}
// pingpong
-(void)ping{
    [_webSocket sendPing:nil];
}


#pragma mark - MOBFWebScokerDelegate
-(void)webSocket:(MOBFWebSocket *)webSocket didReceiveMessage:(id)message
{
    NSLog(@"服务器返回的信息:%@",message);
}
-(void)webSocketDidOpen:(MOBFWebSocket *)webSocket
{
    NSLog(@"连接成功");
    //   连接成功 开始发送心跳
    [self initHearBeat];
}
//  open失败时调用
-(void)webSocket:(MOBFWebSocket *)webSocket didFailWithError:(NSError *)error
{
    NSLog(@"连接失败。。。。。%@",error);
    //  失败了去重连
    [self reConnect];
}
//  网络连接中断被调用
-(void)webSocket:(MOBFWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    
    NSLog(@"被关闭连接，code:%ld,reason:%@,wasClean:%d",code,reason,wasClean);
    
    //如果是被用户自己中断的那么直接断开连接，否则开始重连
    if (code == DisConnectByClient) {
        [self disConnect];
    }else{
        
        [self reConnect];
    }
    //断开连接时销毁心跳
    [self destoryHeartBeat];
}
//sendPing的时候，如果网络通的话，则会收到回调，但是必须保证ScoketOpen，否则会crash
- (void)webSocket:(MOBFWebSocket *)webSocket didReceivePong:(NSData *)pongPayload
{
    NSLog(@"收到pong回调");
    
}

@end
