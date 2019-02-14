//
//  MOBFWebSocket.m
//  MOBFWebSocket
//
//  Created by wukx on 2018/8/29.
//  Copyright © 2018年 Mob. All rights reserved.
//

#import "MOBFWebSocket.h"
#import "MOBFIOConsumer.h"
#import "MOBFIOConsumerPool.h"
#import "NSURLRequest+MOBFWebSocket.h"
#import "NSURL+MOBFWebSocket.h"
#import "NSData+MOBFWebSocket.h"

#if TARGET_OS_IPHONE
#define HAS_ICU
#endif

#ifdef HAS_ICU
#import <unicode/utf8.h>
#endif


#if TARGET_OS_IPHONE
#import <Endian.h>
#else
#import <CoreServices/CoreServices.h>
#endif

//6.0以上的宏，ARC GCD
#if OS_OBJECT_USE_OBJC_RETAIN_RELEASE
#define mobf_dispatch_retain(x)
#define mobf_dispatch_release(x)
#define maybe_bridge(x) ((__bridge void *) x)
#else
#define mobf_dispatch_retain(x) dispatch_retain(x)
#define mobf_dispatch_release(x) dispatch_release(x)
#define maybe_bridge(x) (x)
#endif

typedef struct {
    BOOL fin;
    //  BOOL rsv1;
    //  BOOL rsv2;
    //  BOOL rsv3;
    uint8_t opcode;
    BOOL masked;
    uint64_t payload_length;
} frame_header;

NSString *const MOBFWebSocketErrorDomain = @"MOBFWebSocketErrorDomain";
NSString *const MOBFHTTPResponseErrorKey = @"MOBFHTTPResponseStatusCode";

//RFC规定的4122
//https://tools.ietf.org/html/rfc4122
//连接后的结果使用 SHA-1（160数位）FIPS.180-3 进行一个哈希操作，对哈希操作的结果，采用 base64 进行编码，然后作为服务端响应握手的一部分返回给浏览器。
static NSString *const MOBFWebSocketAppendToSecKeyString = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static inline int32_t validate_dispatch_data_partial_string(NSData *data);

@interface MOBFWebSocket ()
{
    //webSocket版本 握手请求报文中 Sec-WebSocket-Version
    NSInteger _webSocketVersion;
    
    //任务队列
    dispatch_queue_t _workQueue;
    //预或正在处理的消费任务数组 ["我要从_readBuffer中读取2个字节数据，不将读取到的数据存入_currentFrameData","我要从_readBuffer中读取8个字节数据，将读取到的数据存入_currentFrameData","我要从_readBuffer中读取4个字节数据，将读取到的数据存入_currentFrameData"] 这样的数组
    NSMutableArray<MOBFIOConsumer *> *_consumers;
    
    //输入输出流
    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
    
    
    //+-------+-------+-------+-------+-------+-----------------------+
    //|010110110001001101010000011110000010100101......010100000000001| ->_readBuffer
    //+-------+-------+-------+-------+-------+-----------------------+
    //                ^(_readBufferOffset)
    //读数据缓存区
    NSMutableData *_readBuffer;
    //已读取偏移量
    NSUInteger _readBufferOffset;
    
    //写数据缓存区
    NSMutableData *_outputBuffer;
    //已写偏移量
    NSUInteger _outputBufferOffset;
    
    //当前帧的 Opcode
    uint8_t _currentFrameOpcode;
    //记录一个消息帧数
    size_t _currentFrameCount;
    //记录一个消息 消费者执行次数
    size_t _readOpCount;
    uint32_t _currentStringScanPosition;
    //一个消息数据是一个或多帧组成
    NSMutableData *_currentFrameData;
    
    NSString *_closeReason;
    
    //对称密钥
    NSString *_secKey;
    NSString *_basicAuthorizationString;
    
    BOOL _pinnedCertFound;
    
    uint8_t _currentReadMaskKey[4];
    size_t _currentReadMaskOffset;
    
    BOOL _consumerStopped;
    
    BOOL _closeWhenFinishedWriting;
    BOOL _failed;
    
    //是否为安全请求 wss/https
    BOOL _secure;
    NSURLRequest *_urlRequest;
    
    CFHTTPMessageRef _receivedHTTPHeaders;
    
    BOOL _sentClose;
    BOOL _didFail;
    BOOL _cleanupScheduled;
    int _closeCode;
    
    BOOL _isPumping;
    
    NSMutableSet<NSArray *>  *_scheduledRunloops;
    
    // We use this to retain ourselves.
    __strong MOBFWebSocket *_selfRetain;
    
    //协议数组
    NSArray<NSString *>  *_requestedProtocols;
    
    // consumer model(消费者任务对象) 任务执行完后存入该 pool 中，避免下次重新创建对象
    MOBFIOConsumerPool *_consumerPool;
}

@property (nonatomic, assign, readwrite) MOBFWebSocketReadyState readyState;

//@property (nonatomic, strong) NSOperationQueue *delegateOperationQueue;
@property (nonatomic, strong) dispatch_queue_t delegateDispatchQueue;

@end


@implementation MOBFWebSocket

@synthesize readyState = _readyState;

//static __strong NSData *CRLFCRLF;

#pragma mark - Init 初始化

+ (void)initialize
{
    //CRLFCRLF = [[NSData alloc] initWithBytes:@"\r\n\r\n" length:4];
}

- (instancetype)initWithURLRequest:(NSURLRequest *)request
{
    return [self initWithURLRequest:request protocols:nil];
}

// protocols e.g ["chat","game"]
- (instancetype)initWithURLRequest:(NSURLRequest *)request protocols:(NSArray *)protocols
{
    self = [super init];
    if (self)
    {
        assert(request.URL);
        _url = request.URL;
        _urlRequest = request;
        
        //协议数组
        _requestedProtocols = [protocols copy];
        
        [self commonInit];
    }
    return self;
}

- (void)commonInit
{
    //得到url schem小写
    NSString *scheme = _url.scheme.lowercaseString;
    //如果不是这几种，则断言错误
    assert([scheme isEqualToString:@"ws"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]);
    
    //ssl
    if ([scheme isEqualToString:@"wss"] || [scheme isEqualToString:@"https"]) {
        _secure = YES;
    }
    
    //标识状态为正在连接
    _readyState = MOBFWebSocketStateConnecting;
    
    //消费停止
    _consumerStopped = YES;
    
    //webSocket 标识版本
    _webSocketVersion = 13;
    
    //初始化队列，串行
    _workQueue = dispatch_queue_create(NULL,DISPATCH_QUEUE_SERIAL);
    
    //给队列设置一个标识,标识为指向自己的，上下文对象为这个队列
    dispatch_queue_set_specific(_workQueue, (__bridge void *)self, maybe_bridge(_workQueue), NULL);
    
    //设置代理queue为主队列
    _delegateDispatchQueue = dispatch_get_main_queue();
    //retain主队列
    mobf_dispatch_retain(_delegateDispatchQueue);
    
    //读取Buffer
    _readBuffer = [[NSMutableData alloc] init];
    //输出Buffer
    _outputBuffer = [[NSMutableData alloc] init];
    //当前帧数据
    _currentFrameData = [[NSMutableData alloc] init];
    
    //消费者数组
    _consumers = [[NSMutableArray alloc] init];
    //消费池
    _consumerPool = [[MOBFIOConsumerPool alloc] init];
    
    //注册的runloop
    _scheduledRunloops = [[NSMutableSet alloc] init];
    
    [self _initalizeStreams];
}

- (void)_initalizeStreams
{
    //断言 port值小于UINT32_MAX
    assert(_url.port.unsignedIntValue <= UINT32_MAX);
    //拿到端口
    uint32_t port = _url.port.unsignedIntValue;
    //如果端口号为0，给个默认值，http 80 https 443;
    if (port == 0) {
        if (!_secure) {
            port = 80;
        } else {
            port = 443;
        }
    }
    NSString *host = _url.host;
    
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    //用host创建读写stream,Host和port就绑定在一起了
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
    
    //绑定生命周期给ARC  _outputStream = __bridge transfer
    _outputStream = CFBridgingRelease(writeStream);
    _inputStream = CFBridgingRelease(readStream);
    
    //代理设为自己 NSStreamDelegate
    _inputStream.delegate = self;
    _outputStream.delegate = self;
}

//断言当前是_workQueue
- (void)assertOnWorkQueue;
{
    //因为设置了上下文对象，所以这里如果是在当前队列调用，则返回的是_workQueue
    //dispatch_get_specific((__bridge void *)self) 拿到当前queue的指针  判断和后者是不是相同
    assert(dispatch_get_specific((__bridge void *)self) == maybe_bridge(_workQueue));
}

- (void)dealloc
{
    _inputStream.delegate = nil;
    _outputStream.delegate = nil;
    
    [_inputStream close];
    [_inputStream close];
    if (_workQueue)
    {
        mobf_dispatch_release(_workQueue);
        _workQueue = NULL;
    }
    
    if (_receivedHTTPHeaders) {
        CFRelease(_receivedHTTPHeaders);
        _receivedHTTPHeaders = NULL;
    }
    
    if (_delegateDispatchQueue) {
        mobf_dispatch_release(_delegateDispatchQueue);
        _delegateDispatchQueue = NULL;
    }
}

#ifndef NDEBUG

- (void)setReadyState:(MOBFWebSocketReadyState)aReadyState;
{
    //[self willChangeValueForKey:@"readyState"];
    assert(aReadyState > _readyState);
    _readyState = aReadyState;
    //[self didChangeValueForKey:@"readyState"];
}

#endif


#pragma mark - 开始连接

- (void)open
{
    assert(_url);
    //如果状态是正在连接，直接断言出错
    NSAssert(_readyState == MOBFWebSocketStateConnecting, @"Cannot call -(void)open on WebSocket more than once");
    
    //自己持有自己
    _selfRetain = self;
    //判断超时时长
    if (_urlRequest.timeoutInterval > 0)
    {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, _urlRequest.timeoutInterval * NSEC_PER_SEC);
        //在超时时间执行
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            //如果还在连接，报错
            if (self.readyState == MOBFWebSocketStateConnecting)
                [self _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:504 userInfo:@{NSLocalizedDescriptionKey: @"Timeout Connecting to Server"}]];
        });
    }
    //开始建立连接
    [self openConnection];
}

//开始连接
- (void)openConnection
{
    //更新安全、流配置
    //[self _updateSecureStreamOptions];
    
    //判断有没有runloop
    if (!_scheduledRunloops.count) {
        //mobf_networkRunLoop会创建一个带runloop的常驻线程，模式为NSDefaultRunLoopMode。
        [self scheduleInRunLoop:[NSRunLoop mobf_networkRunLoop] forMode:NSDefaultRunLoopMode];
    }
    
    //开启输入输出流
    [_outputStream open];
    [_inputStream open];
}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode;
{
    [_outputStream scheduleInRunLoop:aRunLoop forMode:mode];
    [_inputStream scheduleInRunLoop:aRunLoop forMode:mode];
    
    //添加到集合里，数组
    [_scheduledRunloops addObject:@[aRunLoop, mode]];
}

- (void)unscheduleFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSString *)mode;
{
    [_outputStream removeFromRunLoop:aRunLoop forMode:mode];
    [_inputStream removeFromRunLoop:aRunLoop forMode:mode];
    
    //移除
    [_scheduledRunloops removeObject:@[aRunLoop, mode]];
}


#pragma mark - 关闭

//关闭
- (void)close
{
    [self closeWithCode:MOBFStatusCodeNormal reason:nil];
}

//用code来关闭
- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason;
{
    assert(code);
    dispatch_async(_workQueue, ^{
        if (self.readyState == MOBFWebSocketStateClosing || self.readyState == MOBFWebSocketStateClosed) {
            return;
        }
        
        BOOL wasConnecting = self.readyState == MOBFWebSocketStateConnecting;
        
        self.readyState = MOBFWebSocketStateClosing;
        
        NSLog(@"Closing with code %ld reason %@", code, reason);
        
        if (wasConnecting) {
            [self closeConnection];
            return;
        }
        
        size_t maxMsgSize = [reason maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *mutablePayload = [[NSMutableData alloc] initWithLength:sizeof(uint16_t) + maxMsgSize];
        NSData *payload = mutablePayload;
        
        ((uint16_t *)mutablePayload.mutableBytes)[0] = EndianU16_BtoN(code);
        
        if (reason) {
            NSRange remainingRange = {0};
            
            NSUInteger usedLength = 0;
            
            BOOL success = [reason getBytes:(char *)mutablePayload.mutableBytes + sizeof(uint16_t) maxLength:payload.length - sizeof(uint16_t) usedLength:&usedLength encoding:NSUTF8StringEncoding options:NSStringEncodingConversionExternalRepresentation range:NSMakeRange(0, reason.length) remainingRange:&remainingRange];
#pragma unused (success)
            
            assert(success);
            assert(remainingRange.length == 0);
            
            if (usedLength != maxMsgSize) {
                payload = [payload subdataWithRange:NSMakeRange(0, usedLength + sizeof(uint16_t))];
            }
        }
        
        
        [self _sendFrameWithOpcode:MOBFOpCodeConnectionClose data:payload];
    });
}

//因为协议的错误，关闭
- (void)closeWithProtocolError:(NSString *)message;
{
    // Need to shunt this on the _callbackQueue first to see if they received any messages
    __weak typeof(self)weakSelf = self;
    [self _performDelegateBlock:^{
        [weakSelf closeWithCode:MOBFStatusCodeProtocolError reason:message];
        dispatch_async(self->_workQueue, ^{
            [weakSelf closeConnection];
        });
    }];
}

- (void)closeConnection
{
    [self assertOnWorkQueue];
    NSLog(@"Trying to disconnect");
    _closeWhenFinishedWriting = YES;
    [self _pumpWriting];
}


//写数据
- (void)_writeData:(NSData *)data
{
    //断言当前queue
    [self assertOnWorkQueue];
    //如果标记为写完成关闭，则直接返回
    if (_closeWhenFinishedWriting) {
        return;
    }
    [_outputBuffer appendData:data];
    
    //开始写
    [self _pumpWriting];
}

//发送数据
- (void)send:(id)data
{
    NSAssert(self.readyState != MOBFWebSocketStateConnecting, @"Invalid State: Cannot call send: until connection is open");
    data = [data copy];
    dispatch_async(_workQueue, ^{
        //根据类型给帧类型 MOBFOpCodeTextFrame文本，MOBFOpCodeBinaryFrame二进制类型
        if ([data isKindOfClass:[NSString class]]) {
            [self _sendFrameWithOpcode:MOBFOpCodeTextFrame data:[(NSString *)data dataUsingEncoding:NSUTF8StringEncoding]];
        } else if ([data isKindOfClass:[NSData class]]) {
            [self _sendFrameWithOpcode:MOBFOpCodeBinaryFrame data:data];
        } else if (data == nil) {
            [self _sendFrameWithOpcode:MOBFOpCodeTextFrame data:data];
        } else {
            assert(NO);
        }
    });
}

//心跳
- (void)sendPing:(NSData *)data;
{
    NSAssert(self.readyState == MOBFWebSocketStateOpen, @"Invalid State: Cannot call send: until connection is open");
    // TODO: maybe not copy this for performance
    data = [data copy] ?: [NSData data]; // It's okay for a ping to be empty
    __weak typeof(self)weakSelf = self;
    dispatch_async(_workQueue, ^{
        [weakSelf _sendFrameWithOpcode:MOBFOpCodePing data:data];
    });
}

- (void)handlePing:(NSData *)pingData
{
    __weak typeof(self) weakSelf = self;
    [self _performDelegateBlock:^{
        dispatch_async(self->_workQueue, ^{
            [weakSelf _sendFrameWithOpcode:MOBFOpCodePong data:pingData];
        });
    }];
}

- (void)handlePong:(NSData *)pongData
{
    __weak typeof(self) weakSelf = self;
    [self _performDelegateBlock:^{
        if ([weakSelf.delegate respondsToSelector:@selector(webSocket:didReceivePong:)])
        {
            [weakSelf.delegate webSocket:self didReceivePong:pongData];
        }
    }];
}

//回调收到消息代理
- (void)_handleMessage:(id)message
{
    NSLog(@"Received message");
    __weak typeof(self)weakSelf = self;
    [self _performDelegateBlock:^{
        [weakSelf.delegate webSocket:self didReceiveMessage:message];
    }];
}

- (void)handleCloseWithData:(NSData *)data
{
    size_t dataSize = data.length;
    __block uint16_t closeCode = 0;
    
    NSLog(@"Received close frame");
    
    if (dataSize == 1)
    {
        [self closeWithProtocolError:@"Payload for close must be larger than 2 bytes"];
        return;
    }
    else if (dataSize >= 2)
    {
        [data getBytes:&closeCode length:sizeof(closeCode)];
        _closeCode = EndianU16_BtoN(closeCode);
        if (!closeCodeIsValid(_closeCode))
        {
            [self closeWithProtocolError:[NSString stringWithFormat:@"Cannot have close code of %d", _closeCode]];
            return;
        }
        if (dataSize > 2)
        {
            _closeReason = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(2, dataSize - 2)] encoding:NSUTF8StringEncoding];
            if (!_closeReason)
            {
                [self closeWithProtocolError:@"Close reason MUST be valid UTF-8"];
                return;
            }
        }
    }
    else
    {
        _closeCode = MOBFStatusNoStatusReceived;
    }
    
    [self assertOnWorkQueue];
    
    if (self.readyState == MOBFWebSocketStateOpen)
    {
        [self closeWithCode:1000 reason:nil];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_workQueue, ^{
        [weakSelf closeConnection];
    });
    
}

static inline BOOL closeCodeIsValid(int closeCode)
{
    if (closeCode < 1000) {
        return NO;
    }
    
    if (closeCode >= 1000 && closeCode <= 1011) {
        if (closeCode == 1004 ||
            closeCode == 1005 ||
            closeCode == 1006) {
            return NO;
        }
        return YES;
    }
    
    if (closeCode >= 3000 && closeCode <= 3999) {
        return YES;
    }
    
    if (closeCode >= 4000 && closeCode <= 4999) {
        return YES;
    }
    
    return NO;
}

//当前帧读取完成
- (void)_handleFrameWithData:(NSData *)frameData opCode:(NSInteger)opcode
{
    // Check that the current data is valid UTF8
    
    BOOL isControlFrame = (opcode == MOBFOpCodePing || opcode == MOBFOpCodePong || opcode == MOBFOpCodeConnectionClose);
    //如果不是控制帧，就去读下一帧
    if (!isControlFrame)
    {
        [self _readFrameNew];
    }
    else
    {
        //继续读当前帧
        dispatch_async(_workQueue, ^{
            [self _readFrameContinue];
        });
    }
    
    //frameData will be copied before passing to handlers
    //otherwise there can be misbehaviours when value at the pointer is changed
    switch (opcode) {
            //文本类型
        case MOBFOpCodeTextFrame:
        {
            //给string
            NSString *str = [[NSString alloc] initWithData:frameData encoding:NSUTF8StringEncoding];
            //string转出错，关闭连接
            if (str == nil && frameData) {
                [self closeWithCode:MOBFStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                dispatch_async(_workQueue, ^{
                    [self closeConnection];
                });
                return;
            }
            //回调
            [self _handleMessage:str];
            
            break;
        }
        case MOBFOpCodeBinaryFrame:
            //回调data
            [self _handleMessage:[frameData copy]];
            break;
        case MOBFOpCodeConnectionClose:
            //关闭data
            [self handleCloseWithData:[frameData copy]];
            break;
        case MOBFOpCodePing:
            [self handlePing:[frameData copy]];
            break;
        case MOBFOpCodePong:
            [self handlePong:[frameData copy]];
            break;
        default:
            //关闭
            [self closeWithProtocolError:[NSString stringWithFormat:@"Unknown opcode %ld", (long)opcode]];
            // TODO: Handle invalid opcode
            break;
    }
}


//处理数据帧
- (void)_handleFrameHeader:(frame_header)frame_header curData:(NSData *)curData
{
     assert(frame_header.opcode != 0);
    if (self.readyState == MOBFWebSocketStateClosed)
    {
        return;
    }
    
    BOOL isControlFrame = (frame_header.opcode == MOBFOpCodePing || frame_header.opcode == MOBFOpCodePong || frame_header.opcode == MOBFOpCodeConnectionClose);
    
    if (isControlFrame && !frame_header.fin)
    {
        [self closeWithProtocolError:@"Fragmented control frames not allowed"];
        return;
    }
    
    if (isControlFrame && frame_header.payload_length >= 126)
    {
        [self closeWithProtocolError:@"Control frames cannot have payloads larger than 126 bytes"];
        return;
    }
    //如果不是控制帧
    if (!isControlFrame)
    {
        //等于头部的opcode
        _currentFrameOpcode = frame_header.opcode;
        _currentFrameCount += 1;
    }
    //如果数据长度为0
    if (frame_header.payload_length == 0)
    {
        if (isControlFrame)
        {
            //读完回调
            [self _handleFrameWithData:curData opCode:frame_header.opcode];
        }
        else
        {
            if (frame_header.fin)
            {
                //读完回调
                [self _handleFrameWithData:_currentFrameData opCode:frame_header.opcode];
            }
            else
            {
                // TODO add assert that opcode is not a control;
                //开始读取数据
                [self _readFrameContinue];
            }
        }
    }
    else
    {
        //断言帧长度小于 SIZE_T_MAX
        assert(frame_header.payload_length <= SIZE_T_MAX);
        //添加consumer ,去读payload长度
        [self _addConsumerWithDataLength:(size_t)frame_header.payload_length callback:^(MOBFWebSocket *self, NSData *newData) {
            //读完回调
            if (isControlFrame)
            {
                [self _handleFrameWithData:newData opCode:frame_header.opcode];
            }
            else
            {
                //如果有fin,读完回调
                if (frame_header.fin)
                {
                    [self _handleFrameWithData:self->_currentFrameData opCode:frame_header.opcode];
                }
                else
                {
                    // TODO add assert that opcode is not a control;
                    //继续读消息帧
                    [self _readFrameContinue];
                }
            }
        } readToCurrentFrame:!isControlFrame unmaskBytes:frame_header.masked];
    }
}






/* From RFC:
 
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-------+-+-------------+-------------------------------+
 |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 |I|S|S|S| (4bit)|A|   (7bit)    |          (16bit/64bit)        |
 |N|V|V|V|       |S|             |  (if payload len == 126/127)  |
 | |1|2|3|       |K|             |                               |
 |·······························|                               |
 |     frame_header(2byte)       |                               |
 +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +    4byte
 |     Extended payload length continued, if payload len == 127  |
 + - - - - - - - - - - - - - - - +-------------------------------+    8btye
 |                               |Masking-key, if MASK set to 1  |
 +-------------------------------+-------------------------------+    12btye
 | Masking-key (continued)       |          Payload Data         |
 +-------------------------------- - - - - - - - - - - - - - - - +    16btye
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +    20byte
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +    24byte
 |                                ...                            |
 +---------------------------------------------------------------+    .....
 */

/*
 FIN      1bit 表示信息的最后一帧(数据包)，flag，也就是标记符，1表示结束，0表示还有下一帧
 RSV 1-3  1bit each 以后备用的/扩展 默认都为 0
 Opcode   4bit 帧(数据包)类型
            0x0：表示一个连续的帧
            0x1：表示一个text类型帧
            0x2：表示一个binary类型帧
            0x3-7：保留
            0x8：表示一个断开连接类型帧
            0x9：表示一个ping类型帧
            0xA：表示一个pong类型帧
            0xB-F：保留
 Mask     1bit 掩码，用于标识PayloadData是否经过掩码处理，如果是1，Masking-key域的数据即是掩码密钥，用于解码PayloadData，客户端发出的数据帧需要进行掩码处理，所以此位是1。
 Masking-key      1 or 4 bytes 掩码
 Payload length   7bit (Payload data的长度)，占7bits，7+16bits，7+64bits
                      如果其值在0-125，则是payload的真实长度。
                      如果值是126，则后面2个字节形成的16bits无符号整型数的值是payload的真实长度。注意，网络字节序，需要转换。
                      如果值是127，则后面8个字节形成的64bits无符号整型数的值是payload的真实长度。注意，网络字节序，需要转换。
 Payload data     (x + y) bytes 应用层数据(扩展数据+程序数据)
 Extension data   x bytes  扩展数据
 Application data y bytes  程序数据
 
 1byte
     1bit: frame-fin，x0表示该message后续还有frame；x1表示是message的最后一个frame
     3bit: 分别是frame-rsv1、frame-rsv2和frame-rsv3，通常都是x0
     4bit: frame-opcode，x0表示是延续frame；x1表示文本frame；x2表示二进制frame；x3-7保留给非控制frame；x8表示关 闭连接；x9表示ping；xA表示pong；xB-F保留给控制frame
 2byte
     1bit: Mask，1表示该frame包含掩码；0表示无掩码
     7bit、7bit+2byte、7bit+8byte: 7bit取整数值，若在0-125之间，则是负载数据长度；若是126表示，后两个byte取无符号16位整数值，是负载长度；127表示后8个 byte，取64位无符号整数值，是负载长度
     3-6byte: 这里假定负载长度在0-125之间，并且Mask为1，则这4个byte是掩码
     7-end byte: 长度是上面取出的负载长度，包括扩展数据和应用数据两部分，通常没有扩展数据；若Mask为1，则此数据需要解码，解码规则为- 1-4byte掩码循环和数据byte做异或操作。
 */



static const uint8_t MOBFFinMask          = 0x80;//1000 0000
static const uint8_t MOBFOpCodeMask       = 0x0F;//0000 1111
static const uint8_t MOBFRsvMask          = 0x70;//0111 0000
static const uint8_t MOBFMaskMask         = 0x80;//1000 0000
static const uint8_t MOBFPayloadLenMask   = 0x7F;//0111 1111


//开始读取当前消息帧
- (void)_readFrameContinue
{
    //断言要么都为空，要么都有值
    assert((_currentFrameCount == 0 && _currentFrameOpcode == 0) || (_currentFrameCount > 0 && _currentFrameOpcode > 0));
    //添加一个consumer，数据长度为2字节 frame_header 2个字节
    //10000001 10001000 00000000
    //^
    //                  ^
    [self _addConsumerWithDataLength:2 callback:^(MOBFWebSocket *self, NSData *data) {
        
        //
        __block frame_header header = {0};
        
        const uint8_t *headerBuffer = data.bytes;
        assert(data.length >= 2);
        
        //判断第一帧 FIN
        if (headerBuffer[0] & MOBFRsvMask) {
            [self closeWithProtocolError:@"Server used RSV bits"];
            return;
        }
        //得到Qpcode
        uint8_t receivedOpcode = (MOBFOpCodeMask & headerBuffer[0]);
        
        //判断帧类型，是否是指定的控制帧
        BOOL isControlFrame = (receivedOpcode == MOBFOpCodePing || receivedOpcode == MOBFOpCodePong || receivedOpcode == MOBFOpCodeConnectionClose);
        
        //如果不是控制帧，而且receivedOpcode不等于0，而且_currentFrameCount消息帧大于0，错误关闭
        if (!isControlFrame && receivedOpcode != 0 && self->_currentFrameCount > 0) {
            [self closeWithProtocolError:@"all data frames after the initial data frame must have opcode 0"];
            return;
        }
        // 没消息
        if (receivedOpcode == 0 && self->_currentFrameCount == 0) {
            [self closeWithProtocolError:@"cannot continue a message"];
            return;
        }
        
        //正常读取
        //得到opcode
        header.opcode = receivedOpcode == 0 ? self->_currentFrameOpcode : receivedOpcode;
        //得到fin
        header.fin = !!(MOBFFinMask & headerBuffer[0]);
        
        //得到Mask
        header.masked = !!(MOBFMaskMask & headerBuffer[1]);
        //得到数据长度
        header.payload_length = MOBFPayloadLenMask & headerBuffer[1];
        
        headerBuffer = NULL;
        
        //如果是带掩码的，则报错，因为客户端是无法得知掩码的值得。
        if (header.masked)
        {
            [self closeWithProtocolError:@"Client must receive unmasked data"];
        }
        
        size_t extra_bytes_needed = header.masked ? sizeof(self->_currentReadMaskKey) : 0;
        //得到长度
        if (header.payload_length == 126)
        {
            extra_bytes_needed += sizeof(uint16_t);
        }
        else if (header.payload_length == 127)
        {
            extra_bytes_needed += sizeof(uint64_t);
        }
        
        //如果多余的需要的bytes为0
        if (extra_bytes_needed == 0)
        {
            //
            [self _handleFrameHeader:header curData:self->_currentFrameData];
        }
        else
        {
            //读取payload
            [self _addConsumerWithDataLength:extra_bytes_needed callback:^(MOBFWebSocket *self, NSData *data) {
                
                size_t mapped_size = data.length;
#pragma unused (mapped_size)
                const void *mapped_buffer = data.bytes;
                size_t offset = 0;
                
                if (header.payload_length == 126)
                {
                    assert(mapped_size >= sizeof(uint16_t));
                    uint16_t newLen = EndianU16_BtoN(*(uint16_t *)(mapped_buffer));
                    header.payload_length = newLen;
                    offset += sizeof(uint16_t);
                }
                else if (header.payload_length == 127)
                {
                    assert(mapped_size >= sizeof(uint64_t));
                    header.payload_length = EndianU64_BtoN(*(uint64_t *)(mapped_buffer));
                    offset += sizeof(uint64_t);
                }
                else
                {
                    assert(header.payload_length < 126 && header.payload_length >= 0);
                }
                
                if (header.masked)
                {
                    assert(mapped_size >= sizeof(self->_currentReadMaskOffset) + offset);
                    memcpy(self->_currentReadMaskKey, ((uint8_t *)mapped_buffer) + offset, sizeof(self->_currentReadMaskKey));
                }
                //把已读到的数据，和header传出去
                [self _handleFrameHeader:header curData:self->_currentFrameData];
            } readToCurrentFrame:NO unmaskBytes:NO];
        }
    } readToCurrentFrame:NO unmaskBytes:NO];
}

//读取新的消息帧
- (void)_readFrameNew
{
    dispatch_async(_workQueue, ^{
        //清除上一帧
        [self->_currentFrameData setLength:0];
        
        self->_currentFrameOpcode = 0;
        self->_currentFrameCount = 0;
        self->_readOpCount = 0;
        self->_currentStringScanPosition =0;
        //继续读取
        [self _readFrameContinue];
    });
}

//开始写
- (void)_pumpWriting
{
    //断言queue
    [self assertOnWorkQueue];
    
    //得到输出的buffer长度
    NSUInteger dataLength = _outputBuffer.length;
    //如果有没写完的数据而且输出流还有空间
    if (dataLength - _outputBufferOffset > 0 && _outputStream.hasSpaceAvailable) {
        
        //写入，并获取长度
        //写入进去，就会直接发送给对方了！这一步send
        NSInteger bytesWritten = [_outputStream write:_outputBuffer.bytes + _outputBufferOffset maxLength:dataLength - _outputBufferOffset];
        //写入错误
        if (bytesWritten == -1) {
            [self _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:2145 userInfo:[NSDictionary dictionaryWithObject:@"Error writing to stream" forKey:NSLocalizedDescriptionKey]]];
            return;
        }
        //加上写入长度
        _outputBufferOffset += bytesWritten;
        
        //释放掉一部分已经写完的内存
        if (_outputBufferOffset > 4096 && _outputBufferOffset > (_outputBuffer.length >> 1)) {
            _outputBuffer = [[NSMutableData alloc] initWithBytes:(char *)_outputBuffer.bytes + _outputBufferOffset length:_outputBuffer.length - _outputBufferOffset];
            _outputBufferOffset = 0;
        }
    }
    //如果关闭当完成写，输出的bufeer - 偏移量 = 0，
    if (_closeWhenFinishedWriting &&
        _outputBuffer.length - _outputBufferOffset == 0 &&
        (_inputStream.streamStatus != NSStreamStatusNotOpen &&
         _inputStream.streamStatus != NSStreamStatusClosed) &&
        !_sentClose)
    {
        
        ///发送关闭
        _sentClose = YES;
        
        //关闭输入输出流
        @synchronized(self) {
            [_outputStream close];
            [_inputStream close];
            
            //移除runloop
            for (NSArray *runLoop in [_scheduledRunloops copy]) {
                [self unscheduleFromRunLoop:[runLoop objectAtIndex:0] forMode:[runLoop objectAtIndex:1]];
            }
        }
        
        if (!_failed) {
            //调用关闭代理
            __weak typeof(self)weakSelf = self;
            [self _performDelegateBlock:^{
                if ([weakSelf.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
                    [weakSelf.delegate webSocket:self didCloseWithCode:self->_closeCode reason:self->_closeReason wasClean:YES];
                }
            }];
        }
        //清除注册
        [self _scheduleCleanup];
    }
}


//指定数据读取
- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback;
{
    [self assertOnWorkQueue];
    [self _addConsumerWithScanner:consumer callback:callback dataLength:0];
}

- (void)_addConsumerWithScanner:(stream_scanner)consumer callback:(data_callback)callback dataLength:(size_t)dataLength;
{
    [self assertOnWorkQueue];
    [_consumers addObject:[_consumerPool consumerWithScanner:consumer handler:callback bytesNeeded:dataLength readToCurrentFrame:NO unmaskBytes:NO]];
    [self _pumpScanner];
}

//添加消费者，用一个指定的长度，是否读到当前帧
- (void)_addConsumerWithDataLength:(size_t)dataLength callback:(data_callback)callback readToCurrentFrame:(BOOL)readToCurrentFrame unmaskBytes:(BOOL)unmaskBytes
{
    [self assertOnWorkQueue];
    assert(dataLength);
    //添加到消费者队列去
    [_consumers addObject:[_consumerPool consumerWithScanner:nil handler:callback bytesNeeded:dataLength readToCurrentFrame:readToCurrentFrame unmaskBytes:unmaskBytes]];
    [self _pumpScanner];
}

- (void)_pumpScanner
{
    [self assertOnWorkQueue];
    //判断是否在扫描
    if (!_isPumping)
    {
        _isPumping = YES;
    }
    else
    {
        return;
    }
    
    //只有为NO能走到这里，开始循环检测，可读可写数据
    while ([self _innerPumpScanner])
    {
        
    }
    
    _isPumping = NO;
}


//判断当前是否正在工作
- (BOOL)_innerPumpScanner
{
    //正在工作的标记
    BOOL didWork = NO;
    //如果就绪状态为已关闭 返回NO
    if (self.readyState >= MOBFWebSocketStateClosed) {
        return didWork;
    }
    //如果消费者为空，返回NO
    if (!_consumers.count) {
        return didWork;
    }
    
    //读取的buffer长度 - 偏移量  =  未读数据长
    size_t curSize = _readBuffer.length - _readBufferOffset;
    //如果未读为空，返回NO
    if (!curSize) {
        return didWork;
    }
    //拿到第一个消费者
    MOBFIOConsumer *consumer = [_consumers objectAtIndex:0];
    //得到需要的字节数
    size_t bytesNeeded = consumer.bytesNeeded;
    //
    size_t foundSize = 0;
    
    //得到本次需要读取大小
    //判断有没有consumer，来获取实际消费的数据大小
    if (consumer.consumer)
    {
        //把未读数据从readBuffer中赋值到tempView里，直接持有，非copy
        NSData *tempView = [NSData dataWithBytesNoCopy:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset freeWhenDone:NO];
        //得到消费的大小
        foundSize = consumer.consumer(tempView);
    }
    else
    {
        //断言需要字节
        assert(consumer.bytesNeeded);
        //如果未读字节大于需要字节，直接等于需要字节
        if (curSize >= bytesNeeded) {
            
            foundSize = bytesNeeded;
        }
        //如果为读取当前帧
        else if (consumer.readToCurrentFrame)
        {
            //消费大小等于当前未读字节
            foundSize = curSize;
        }
    }
    
    //得到需要读取的数据，并且释放已读的空间
    //切片
    NSData *slice = nil;
    //如果读取当前帧或者foundSize大于0
    if (consumer.readToCurrentFrame || foundSize)
    {
        //从已读偏移到要读的字节处
        NSRange sliceRange = NSMakeRange(_readBufferOffset, foundSize);
        //得到data
        slice = [_readBuffer subdataWithRange:sliceRange];
        //增加已读偏移
        _readBufferOffset += foundSize;
        //如果读取偏移的大小大于4096，或者读取偏移大于 1/2的buffer大小
        if (_readBufferOffset > 4096 && _readBufferOffset > (_readBuffer.length >> 1)) {
            //重新创建，释放已读那部分的data空间
            _readBuffer = [[NSMutableData alloc] initWithBytes:(char *)_readBuffer.bytes + _readBufferOffset length:_readBuffer.length - _readBufferOffset];
            _readBufferOffset = 0;
        }
        
        //如果用户未掩码的数据
        if (consumer.unmaskBytes)
        {
            //copy切片
            NSMutableData *mutableSlice = [slice mutableCopy];
            //得到长度字节数
            NSUInteger len = mutableSlice.length;
            uint8_t *bytes = mutableSlice.mutableBytes;
            
            for (NSUInteger i = 0; i < len; i++) {
                //得到一个读取掩码key，为偏移量_currentReadMaskOffset取余_currentReadMaskKey，当前掩码key，
                //再和字节异或运算（相同为0，不同为1）
                bytes[i] = bytes[i] ^ _currentReadMaskKey[_currentReadMaskOffset % sizeof(_currentReadMaskKey)];
                //偏移量+1
                _currentReadMaskOffset += 1;
            }
            //把数据改成掩码后的
            slice = mutableSlice;
        }
        
        //如果读取当前帧
        if (consumer.readToCurrentFrame)
        {
            //拼接数据
            [_currentFrameData appendData:slice];
            //+1
            _readOpCount += 1;
            //判断Opcode，如果是文本帧
            if (_currentFrameOpcode == MOBFOpCodeTextFrame)
            {
                // Validate UTF8 stuff.
                //得到当前帧数据的长度
                size_t currentDataSize = _currentFrameData.length;
                //如果currentDataSize 大于0
                if (_currentFrameOpcode == MOBFOpCodeTextFrame && currentDataSize > 0)
                {
                    // TODO: Optimize the crap out of this.  Don't really have to copy all the data each time
                    //判断需要scan的大小
                    size_t scanSize = currentDataSize - _currentStringScanPosition;
                    //得到要scan的data
                    NSData *scan_data = [_currentFrameData subdataWithRange:NSMakeRange(_currentStringScanPosition, scanSize)];
                    //验证数据
                    int32_t valid_utf8_size = validate_dispatch_data_partial_string(scan_data);
                    
                    //-1为错误，关闭连接
                    if (valid_utf8_size == -1) {
                        [self closeWithCode:MOBFStatusCodeInvalidUTF8 reason:@"Text frames must be valid UTF-8"];
                        dispatch_async(_workQueue, ^{
                            [self closeConnection];
                        });
                        return didWork;
                    }
                    else
                    {
                        //扫描的位置+上合法数据的size
                        _currentStringScanPosition += valid_utf8_size;
                    }
                }
                
            }
            //需要的size - 已操作的size
            consumer.bytesNeeded -= foundSize;
            //如果还需要的字节数 = 0，移除消费者
            if (consumer.bytesNeeded == 0) {
                [_consumers removeObjectAtIndex:0];
                //回调读取完成
                consumer.handler(self, nil);
                //把要返回的consumer，先放在_consumerPool缓冲池中
                [_consumerPool returnConsumer:consumer];
                //已经工作为YES
                didWork = YES;
            }
        }
        else if (foundSize)
        {
            //移除消费者
            [_consumers removeObjectAtIndex:0];
            //回调回去当前接受到的数据
            consumer.handler(self, slice);
            
            [_consumerPool returnConsumer:consumer];
            didWork = YES;
        }
    }
    return didWork;
}

static const size_t MOBFFrameHeaderOverhead = 32;

//发送帧数据
- (void)_sendFrameWithOpcode:(MOBFOpCode)opcode data:(id)data
{
    [self assertOnWorkQueue];
    
    if (nil == data)
    {
        return;
    }
    
    NSAssert([data isKindOfClass:[NSData class]] || [data isKindOfClass:[NSString class]], @"NSString or NSData");
    //得到发送数据长度
    size_t payloadLength = [data isKindOfClass:[NSString class]] ? [(NSString *)data lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : [data length];
    //+外层包裹的帧长度 32个字节？
    NSMutableData *frame = [[NSMutableData alloc] initWithLength:payloadLength + MOBFFrameHeaderOverhead];
    //如果没数据，则报数据太大出错
    if (!frame)
    {
        [self closeWithCode:MOBFStatusCodeMessageTooBig reason:@"Message too big"];
        return;
    }
    //得到帧指针
    uint8_t *frame_buffer = (uint8_t *)[frame mutableBytes];
    
    // set fin
    //写fin,还有opcode
    frame_buffer[0] = MOBFFinMask | opcode;// 1000 0000 | 0000 1001 = 1000 1001
    
    BOOL useMask = YES;
#ifdef NOMASK
    useMask = NO;
#endif
    
    if (useMask)
    {
        // set the mask and header
        //设置mask
        frame_buffer[1] |= MOBFMaskMask;// 0000 0000 | 1000 0000 = 1000 0000
    }
    
    size_t frame_buffer_size = 2;
    
    //得到未掩码数据
    const uint8_t *unmasked_payload = NULL;
    if ([data isKindOfClass:[NSData class]])
    {
        unmasked_payload = (uint8_t *)[data bytes];
    }
    else if ([data isKindOfClass:[NSString class]])
    {
        unmasked_payload =  (const uint8_t *)[data UTF8String];
    }
    else
    {
        return;
    }
    
    //赋值长度
    if (payloadLength < 126)
    {
        //取或
        frame_buffer[1] |= payloadLength;
    }
    else if (payloadLength <= UINT16_MAX)
    {
        frame_buffer[1] |= 126;
        //再加上2个字节来存储长度
        *((uint16_t *)(frame_buffer + frame_buffer_size)) = EndianU16_BtoN((uint16_t)payloadLength);
        frame_buffer_size += sizeof(uint16_t);
    }
    else
    {
        //第一位与127取或
        frame_buffer[1] |= 127;
        //再加上 8个字节来存储长度
        *((uint64_t *)(frame_buffer + frame_buffer_size)) = EndianU64_BtoN((uint64_t)payloadLength);
        frame_buffer_size += sizeof(uint64_t);
    }
    
    //如果没用掩码，直接填充数据
    if (!useMask)
    {
        for (size_t i = 0; i < payloadLength; i++)
        {
            frame_buffer[frame_buffer_size] = unmasked_payload[i];
            frame_buffer_size += 1;
        }
    }
    else
    {
        //先创建mask_key
        uint8_t *mask_key = frame_buffer + frame_buffer_size;
        SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), (uint8_t *)mask_key);
        frame_buffer_size += sizeof(uint32_t);
        
        // TODO: could probably optimize this with SIMD
        //存mask_key
        for (size_t i = 0; i < payloadLength; i++)
        {
            //加上带掩码的数据
            frame_buffer[frame_buffer_size] = unmasked_payload[i] ^ mask_key[i % sizeof(uint32_t)];
            frame_buffer_size += 1;
        }
    }
    
    assert(frame_buffer_size <= [frame length]);
    //设置帧长度
    frame.length = frame_buffer_size;
    
    [self _writeData:frame];
}

// Calls block on delegate queue
- (void)_performDelegateBlock:(dispatch_block_t)block;
{
    assert(_delegateDispatchQueue);
    dispatch_async(_delegateDispatchQueue, block);
}

- (void)_scheduleCleanup
{
    //用@synchronized来同步？
    @synchronized(self) {
        if (_cleanupScheduled) {
            return;
        }
        
        _cleanupScheduled = YES;
        
        // Cleanup NSStream delegate's in the same RunLoop used by the streams themselves:
        // This way we'll prevent race conditions between handleEvent and SRWebsocket's dealloc
        NSTimer *timer = [NSTimer timerWithTimeInterval:(0.0f) target:self selector:@selector(_cleanupSelfReference:) userInfo:nil repeats:NO];
        [[NSRunLoop mobf_networkRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    }
}

- (void)_cleanupSelfReference:(NSTimer *)timer
{
    @synchronized(self) {
        //清除代理和流
        // Nuke NSStream delegate's
        _inputStream.delegate = nil;
        _outputStream.delegate = nil;
        
        // Remove the streams, right now, from the networkRunLoop
        [_inputStream close];
        [_outputStream close];
    }
    
    // Cleanup selfRetain in the same GCD queue as usual
    // 断开对自己的引用
    dispatch_async(_workQueue, ^{
        self->_selfRetain = nil;
    });
}

//报错的方法
- (void)_failWithError:(NSError *)error;
{
    dispatch_async(_workQueue, ^{
        if (self.readyState != MOBFWebSocketStateClosed)
        {
            self->_failed = YES;
            __weak typeof(self) weakSelf = self;
            
            [self _performDelegateBlock:^{
                if ([weakSelf.delegate respondsToSelector:@selector(webSocket:didFailWithError:)])
                {
                    [weakSelf.delegate webSocket:self didFailWithError:error];
                }
            }];
            
            self.readyState = MOBFWebSocketStateClosed;
            
            NSLog(@"Failing with error %@", error.localizedDescription);
            
            [self closeConnection];
            [self _scheduleCleanup];
        }
    });
}

- (void)setDelegateDispatchQueue:(dispatch_queue_t)queue;
{
    if (queue)
    {
        mobf_dispatch_retain(queue);
    }
    
    if (_delegateDispatchQueue)
    {
        mobf_dispatch_release(_delegateDispatchQueue);
    }
    
    _delegateDispatchQueue = queue;
}


#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    __weak typeof(self) weakSelf = self;
    
    // 如果是ssl,而且_pinnedCertFound 为NO，而且事件类型是有可读数据未读，或者事件类型是还有空余空间可写
    if (_secure && !_pinnedCertFound && (eventCode == NSStreamEventHasBytesAvailable || eventCode == NSStreamEventHasSpaceAvailable))
    {
        
        //拿到证书
        NSArray *sslCerts = [_urlRequest mobf_SSLPinnedCertificates];
        if (sslCerts)
        {
            //拿到流中SSL信息结构体
            SecTrustRef secTrust = (__bridge SecTrustRef)[aStream propertyForKey:(__bridge id)kCFStreamPropertySSLPeerTrust];
            if (secTrust)
            {
                //得到数量
                NSInteger numCerts = SecTrustGetCertificateCount(secTrust);
                
                for (NSInteger i = 0; i < numCerts && !_pinnedCertFound; i++)
                {
                    //拿到证书链上的证书
                    SecCertificateRef cert = SecTrustGetCertificateAtIndex(secTrust, i);
                    //得到data
                    NSData *certData = CFBridgingRelease(SecCertificateCopyData(cert));
                    
                    //从request中拿到SSL去匹配流中的
                    for (id ref in sslCerts)
                    {
                        SecCertificateRef trustedCert = (__bridge SecCertificateRef)ref;
                        NSData *trustedCertData = CFBridgingRelease(SecCertificateCopyData(trustedCert));
                        //如果有一对匹配了，就设置为YES
                        if ([trustedCertData isEqualToData:certData])
                        {
                            _pinnedCertFound = YES;
                            break;
                        }
                    }
                }
            }
            //如果为NO，则验证失败，报错关闭
            if (!_pinnedCertFound)
            {
                dispatch_async(_workQueue, ^{
                    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey : @"Invalid server cert" };
                    [weakSelf _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:23556 userInfo:userInfo]];
                });
                return;
            }
            else if (aStream == _outputStream)
            {
                //如果流是输出流，则打开流成功
                dispatch_async(_workQueue, ^{
                    [self didConnect];
                });
            }
        }
    }
    dispatch_async(_workQueue, ^{
        [weakSelf safeHandleEvent:eventCode stream:aStream];
    });
}

//流打开成功后的操作，开始发送http请求建立连接
- (void)didConnect
{
    NSLog(@"Connected");
    //创建一个http request  url
    CFHTTPMessageRef request = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
    
    // Set host first so it defaults
    //设置head, host:  url+port
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Host"), (__bridge CFStringRef)(_url.port ? [NSString stringWithFormat:@"%@:%@", _url.host, _url.port] : _url.host));
    //密钥数据（生成对称密钥）
    NSMutableData *keyBytes = [[NSMutableData alloc] initWithLength:16];
    //生成随机密钥
    SecRandomCopyBytes(kSecRandomDefault, keyBytes.length, keyBytes.mutableBytes);
    
    //根据版本用base64转码
    if ([keyBytes respondsToSelector:@selector(base64EncodedStringWithOptions:)])
    {
        _secKey = [keyBytes base64EncodedStringWithOptions:0];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _secKey = [keyBytes base64Encoding];
#pragma clang diagnostic pop
    }
    
    //断言编码后长度为24
    assert([_secKey length] == 24);
    
    // Apply cookies if any have been provided
    //提供cookies
    NSDictionary * cookies = [NSHTTPCookie requestHeaderFieldsWithCookies:[self requestCookies]];
    for (NSString * cookieKey in cookies)
    {
        //拿到cookie值
        NSString * cookieValue = [cookies objectForKey:cookieKey];
        if ([cookieKey length] && [cookieValue length])
        {
            //设置到request的 head里
            CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)cookieKey, (__bridge CFStringRef)cookieValue);
        }
    }
    
    // set header for http basic auth
    //设置http的基础auth,用户名密码认证
    if (_url.user.length && _url.password.length)
    {
        NSData *userAndPassword = [[NSString stringWithFormat:@"%@:%@", _url.user, _url.password] dataUsingEncoding:NSUTF8StringEncoding];
        NSString *userAndPasswordBase64Encoded;
        if ([keyBytes respondsToSelector:@selector(base64EncodedStringWithOptions:)]) {
            userAndPasswordBase64Encoded = [userAndPassword base64EncodedStringWithOptions:0];
        }
        else
        {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            userAndPasswordBase64Encoded = [userAndPassword base64Encoding];
#pragma clang diagnostic pop
        }
        //编码后用户名密码
        _basicAuthorizationString = [NSString stringWithFormat:@"Basic %@", userAndPasswordBase64Encoded];
        //设置head Authorization
        CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Authorization"), (__bridge CFStringRef)_basicAuthorizationString);
    }
    //web socket规范head
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Upgrade"), CFSTR("websocket"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Connection"), CFSTR("Upgrade"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Key"), (__bridge CFStringRef)_secKey);
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Version"), (__bridge CFStringRef)[NSString stringWithFormat:@"%ld", (long)_webSocketVersion]);
    
    //设置request的原始 Url
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Origin"), (__bridge CFStringRef)_url.mobf_origin);
    
    //用户初始化的协议数组，可以约束websocket的一些行为
    if (_requestedProtocols)
    {
        CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Sec-WebSocket-Protocol"), (__bridge CFStringRef)[_requestedProtocols componentsJoinedByString:@", "]);
    }
    
    //吧 _urlRequest中原有的head 设置到request中去
    [_urlRequest.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop)
    {
        
        CFHTTPMessageSetHeaderFieldValue(request, (__bridge CFStringRef)key, (__bridge CFStringRef)obj);
    }];
    
    //返回一个序列化 , CFBridgingRelease和 __bridge transfer一个意思， CFHTTPMessageCopySerializedMessage copy一份新的并且序列化，返回CFDataRef
    NSData *message = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(request));
    
    //释放request
    CFRelease(request);
    
    //把这个request当成data去写
    [self _writeData:message];
    //读取http的头部
    [self _readHTTPHeader];
}

//读取http头部
- (void)_readHTTPHeader
{
    if (_receivedHTTPHeaders == NULL)
    {
        //序列化的http消息
        _receivedHTTPHeaders = CFHTTPMessageCreateEmpty(NULL, NO);
    }
    
    //不停的add consumer去读数据
    __weak typeof(self) weakSelf = self;
    [self _readUntilHeaderCompleteWithCallback:^(MOBFWebSocket *self,  NSData *data){
        //拼接数据，拼到头部
        CFHTTPMessageAppendBytes(self->_receivedHTTPHeaders, (const UInt8 *)data.bytes, data.length);
        
        //判断是否接受完
        if (CFHTTPMessageIsHeaderComplete(self->_receivedHTTPHeaders))
        {
            NSLog(@"Finished reading headers %@", CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(self->_receivedHTTPHeaders)));
            [weakSelf _HTTPHeadersDidFinish];
        }
        else
        {
            //没读完递归调
            [weakSelf _readHTTPHeader];
        }
    }];
}

static const char CRLFCRLFBytes[] = {'\r', '\n', '\r', '\n'};

//读取CRLFCRLFBytes,直到回调回来
- (void)_readUntilHeaderCompleteWithCallback:(data_callback)dataHandler;
{
    [self _readUntilBytes:CRLFCRLFBytes length:sizeof(CRLFCRLFBytes) callback:dataHandler];
}

//读取数据 CRLFCRLFBytes，边界符
- (void)_readUntilBytes:(const void *)bytes length:(size_t)length callback:(data_callback)dataHandler;
{
    // TODO optimize so this can continue from where we last searched
    
    //消费者需要消费的数据大小
    stream_scanner consumer = ^size_t(NSData *data) {
        __block size_t found_size = 0;
        __block size_t match_count = 0;
        //得到数据长度
        size_t size = data.length;
        //得到数据指针
        const unsigned char *buffer = data.bytes;
        for (size_t i = 0; i < size; i++ ) {
            //匹配字符
            if (((const unsigned char *)buffer)[i] == ((const unsigned char *)bytes)[match_count]) {
                //匹配数+1
                match_count += 1;
                //如果匹配了
                if (match_count == length) {
                    //读取数据长度等于 i+ 1
                    found_size = i + 1;
                    break;
                }
            } else {
                match_count = 0;
            }
        }
        //返回要读取数据的长度，没匹配成功就是0
        return found_size;
    };
    [self _addConsumerWithScanner:consumer callback:dataHandler];
}

//读完数据处理
- (void)_HTTPHeadersDidFinish;
{
    //得到resonse code
    NSInteger responseCode = CFHTTPMessageGetResponseStatusCode(_receivedHTTPHeaders);
    
    //失败code
    if (responseCode >= 400)
    {
        NSLog(@"Request failed with response code %ld", responseCode);
        [self _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:2132 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"received bad response code from server %ld", (long)responseCode], MOBFHTTPResponseErrorKey:@(responseCode)}]];
        return;
    }
    
    //检查握手信息
    if(![self _checkHandshake:_receivedHTTPHeaders])
    {
        [self _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:2133 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Invalid Sec-WebSocket-Accept response"] forKey:NSLocalizedDescriptionKey]]];
        return;
    }
    
    //得到协议
    NSString *negotiatedProtocol = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(_receivedHTTPHeaders, CFSTR("Sec-WebSocket-Protocol")));
    if (negotiatedProtocol)
    {
        // Make sure we requested the protocol
        //如果请求的协议里没找到，服务端要求的协议，则失败
        if ([_requestedProtocols indexOfObject:negotiatedProtocol] == NSNotFound)
        {
            [self _failWithError:[NSError errorWithDomain:MOBFWebSocketErrorDomain code:2133 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Server specified Sec-WebSocket-Protocol that wasn't requested"] forKey:NSLocalizedDescriptionKey]]];
            return;
        }
        
        _protocol = negotiatedProtocol;
    }
    //修改状态，open
    self.readyState = MOBFWebSocketStateOpen;
    //开始读取新的消息帧
    if (!_didFail)
    {
        [self _readFrameNew];
    }
    //调用已经连接的代理
    [self _performDelegateBlock:^{
        if ([self.delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
            [self.delegate webSocketDidOpen:self];
        };
    }];
}

//检查握手信息
- (BOOL)_checkHandshake:(CFHTTPMessageRef)httpMessage;
{
    //是否是允许的header
    NSString *acceptHeader = CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(httpMessage, CFSTR("Sec-WebSocket-Accept")));
    
    //为空则被服务器拒绝
    if (acceptHeader == nil) {
        return NO;
    }
    
    //得到
    NSString *concattedString = [_secKey stringByAppendingString:MOBFWebSocketAppendToSecKeyString];
    //期待accept的字符串
    
    NSString *expectedAccept = [[NSData mobf_SHA1HashFromString:concattedString] mobf_Base64EncodedString];
    
    //判断是否相同，相同就握手信息对了
    return [acceptHeader isEqualToString:expectedAccept];
}


//安全的处理事件
- (void)safeHandleEvent:(NSStreamEvent)eventCode stream:(NSStream *)aStream
{
    switch (eventCode) {
            //连接完成
        case NSStreamEventOpenCompleted:
        {
            NSLog(@"NSStreamEventOpenCompleted %@", aStream);
            //如果就绪状态为关闭或者正在关闭，直接返回
            if (self.readyState >= MOBFWebSocketStateClosing)
            {
                return;
            }
            //断言_readBuffer
            assert(_readBuffer);
            
            // didConnect fires after certificate verification if we're using pinned certificates.
            
            BOOL usingPinnedCerts = [[_urlRequest mobf_SSLPinnedCertificates] count] > 0;
            //如果是http，或者无自签证书，而且是正准备连接，而且aStream是输入流
            if ((!_secure || !usingPinnedCerts) && self.readyState == MOBFWebSocketStateConnecting && aStream == _inputStream)
            {
                //连接
                [self didConnect];
            }
            //开始写(http握手)
            [self _pumpWriting];
            //开始扫描读写
            [self _pumpScanner];
            break;
        }
            //流事件错误
        case NSStreamEventErrorOccurred:
        {
            NSLog(@"NSStreamEventErrorOccurred %@ %@", aStream, [[aStream streamError] copy]);
            /// TODO specify error better!
            [self _failWithError:aStream.streamError];
            _readBufferOffset = 0;
            [_readBuffer setLength:0];
            break;
            
        }
            //流读到末尾
        case NSStreamEventEndEncountered:
        {
            //扫描下，防止有未操作完的数据
            [self _pumpScanner];
            NSLog(@"NSStreamEventEndEncountered %@", aStream);
            //出错的话直接关闭
            if (aStream.streamError)
            {
                [self _failWithError:aStream.streamError];
            }
            else
            {
                
                dispatch_async(_workQueue, ^{
                    if (self.readyState != MOBFWebSocketStateClosed) {
                        self.readyState = MOBFWebSocketStateClosed;
                        [self _scheduleCleanup];
                    }
                    //如果是正常关闭
                    if (!self->_sentClose && !self->_failed) {
                        self->_sentClose = YES;
                        // If we get closed in this state it's probably not clean because we should be sending this when we send messages
                        [self _performDelegateBlock:^{
                            if ([self.delegate respondsToSelector:@selector(webSocket:didCloseWithCode:reason:wasClean:)]) {
                                [self.delegate webSocket:self didCloseWithCode:MOBFStatusCodeGoingAway reason:@"Stream end encountered" wasClean:NO];
                            }
                        }];
                    }
                });
            }
            
            break;
        }
            //正常读取数据
        case NSStreamEventHasBytesAvailable:
        {
            NSLog(@"NSStreamEventHasBytesAvailable %@", aStream);
            const int bufferSize = 2048;
            uint8_t buffer[bufferSize];
            //如果有可读字节
            while (_inputStream.hasBytesAvailable) {
                //读取数据，一次读2048
                NSInteger bytes_read = [_inputStream read:buffer maxLength:bufferSize];
                
                if (bytes_read > 0) {
                    //拼接数据
                    [_readBuffer appendBytes:buffer length:bytes_read];
                } else if (bytes_read < 0) {
                    //读取错误
                    [self _failWithError:_inputStream.streamError];
                }
                //如果读取的不等于最大的，说明读完了，跳出循环
                if (bytes_read != bufferSize) {
                    break;
                }
            };
            //开始扫描，看消费者什么时候消费数据
            [self _pumpScanner];
            break;
        }
            //有可写空间，一直会回调，除非写满了
        case NSStreamEventHasSpaceAvailable:
        {
            NSLog(@"NSStreamEventHasSpaceAvailable %@", aStream);
            //开始写数据
            [self _pumpWriting];
            break;
        }
            
        default:
            NSLog(@"(default)  %@", aStream);
            break;
    }
}

@end


#ifdef HAS_ICU

//iphone的处理
//验证data合法性
static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    //大于32的最大数
    if ([data length] > INT32_MAX) {
        // INT32_MAX is the limit so long as this Framework is using 32 bit ints everywhere.
        return -1;
    }
    //得到长度
    int32_t size = (int32_t)[data length];
    //得到内容指针
    const void * contents = [data bytes];
    const uint8_t *str = (const uint8_t *)contents;
    
    UChar32 codepoint = 1;
    int32_t offset = 0;
    int32_t lastOffset = 0;
    while(offset < size && codepoint > 0)  {
        //
        lastOffset = offset;
        //wtf? 指针验证差错么？
        U8_NEXT(str, offset, size, codepoint);
    }
    
    //判断 codepoint
    if (codepoint == -1) {
        // Check to see if the last byte is valid or whether it was just continuing
        if (!U8_IS_LEAD(str[lastOffset]) || U8_COUNT_TRAIL_BYTES(str[lastOffset]) + lastOffset < (int32_t)size) {
            
            size = -1;
        } else {
            uint8_t leadByte = str[lastOffset];
            U8_MASK_LEAD_BYTE(leadByte, U8_COUNT_TRAIL_BYTES(leadByte));
            
            for (int i = lastOffset + 1; i < offset; i++) {
                if (U8_IS_SINGLE(str[i]) || U8_IS_LEAD(str[i]) || !U8_IS_TRAIL(str[i])) {
                    size = -1;
                }
            }
            
            if (size != -1) {
                size = lastOffset;
            }
        }
    }
    
    if (size != -1 && ![[NSString alloc] initWithBytesNoCopy:(char *)[data bytes] length:size encoding:NSUTF8StringEncoding freeWhenDone:NO]) {
        size = -1;
    }
    
    return size;
}

#else

//非iphone的处理

// This is a hack, and probably not optimal
static inline int32_t validate_dispatch_data_partial_string(NSData *data) {
    static const int maxCodepointSize = 3;
    
    for (int i = 0; i < maxCodepointSize; i++) {
        NSString *str = [[NSString alloc] initWithBytesNoCopy:(char *)data.bytes length:data.length - i encoding:NSUTF8StringEncoding freeWhenDone:NO];
        if (str) {
            return (int32_t)data.length - i;
        }
    }
    
    return -1;
}

#endif



