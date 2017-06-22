// AFNetworkReachabilityManager.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFNetworkReachabilityManager.h"
#if !TARGET_OS_WATCH

#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

//FOUNDATION_EXPORT 和define的差别是 == 效率更高些

//网络状态发生改变的时候接收的通知
NSString * const AFNetworkingReachabilityDidChangeNotification = @"com.alamofire.networking.reachability.change";

// 网络环境发生变化是会发送一个通知，同时携带一组状态数据 根据这个key来去除网络status
NSString * const AFNetworkingReachabilityNotificationStatusItem = @"AFNetworkingReachabilityNotificationStatusItem";


/**
 定义个一网络变化的回调

 @param status 传入网络的状态 是个枚举值
 */
typedef void (^AFNetworkReachabilityStatusBlock)(AFNetworkReachabilityStatus status);


/**
 根据网络状态返回一个本地的字符串  注意这个写法是个 inline的形式  是个C语言的形式

 @param status 网络状态
 @return 返回一个描述网络状态的字符串
 */
NSString * AFStringFromNetworkReachabilityStatus(AFNetworkReachabilityStatus status) {
    switch (status) {
        case AFNetworkReachabilityStatusNotReachable:
            return NSLocalizedStringFromTable(@"Not Reachable", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWWAN:
            return NSLocalizedStringFromTable(@"Reachable via WWAN", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusReachableViaWiFi:
            return NSLocalizedStringFromTable(@"Reachable via WiFi", @"AFNetworking", nil);
        case AFNetworkReachabilityStatusUnknown:
        default:
            return NSLocalizedStringFromTable(@"Unknown", @"AFNetworking", nil);
    }
}


/**
 根据SCNetworkReachabilityFlags这个网络标记来转换成我们在开发中经常使用的网络状态

 @param flags SCNetworkReachabilityFlags 是个网络标识  标记网络的状态
 @return 返回一个我们自己的相应的网络状态的枚举值
 */
static AFNetworkReachabilityStatus AFNetworkReachabilityStatusForFlags(SCNetworkReachabilityFlags flags) {
    //是否可以到达
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    
    //在联网之前需要建立连接
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    
    //是否可以自动连接
    BOOL canConnectionAutomatically = (((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) || ((flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0));
    
    //是否可以连接在不需要用户手动设置的前提下
    BOOL canConnectWithoutUserInteraction = (canConnectionAutomatically && (flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0);
    
    //是否可以联网的条件 1 能够到达 2 不需要建立连接或者不需要用户手动设置连接
    BOOL isNetworkReachable = (isReachable && (!needsConnection || canConnectWithoutUserInteraction));

    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusUnknown;
    if (isNetworkReachable == NO) {
        status = AFNetworkReachabilityStatusNotReachable;
    }
#if	TARGET_OS_IPHONE
    else if ((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0) {
        status = AFNetworkReachabilityStatusReachableViaWWAN;
    }
#endif
    else {
        status = AFNetworkReachabilityStatusReachableViaWiFi;
    }

    return status;
}

/**
 * Queue a status change notification for the main thread.
 *
 * This is done to ensure that the notifications are received in the same order
 * as they are sent. If notifications are sent directly, it is possible that
 * a queued notification (for an earlier status condition) is processed after
 * the later update, resulting in the listener being left in the wrong state.
 //接受网络变化的方式 1 block  2通知  ----为了保证两种方式的数据统一 把这个过程封装到一个函数中
 
 */
static void AFPostReachabilityStatusChange(SCNetworkReachabilityFlags flags, AFNetworkReachabilityStatusBlock block) {
    AFNetworkReachabilityStatus status = AFNetworkReachabilityStatusForFlags(flags);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (block) {
            block(status);
        }
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        NSDictionary *userInfo = @{ AFNetworkingReachabilityNotificationStatusItem: @(status) };
        [notificationCenter postNotificationName:AFNetworkingReachabilityDidChangeNotification object:nil userInfo:userInfo];
    });
}

/**
 处理网络回调的函数 是一个函数  注意 void *  既然可以指向任何类型 所有 也可以指向block  不过需要 通过__bridge+ block类型去转化

 @param target SCNetworkReachabilityRef 根据他来获取网络状态的
 @param flags  返回的系统的网络状态
 @param info   一个描述的函数
 */
static void AFNetworkReachabilityCallback(SCNetworkReachabilityRef __unused target, SCNetworkReachabilityFlags flags, void *info) {
    AFPostReachabilityStatusChange(flags, (__bridge AFNetworkReachabilityStatusBlock)info);
}


/**
 用来返回一个block的copy

 @param info 传入的block
 @return 返回一个block
 */
static const void * AFNetworkReachabilityRetainCallback(const void *info) {
    return Block_copy(info);
}

/**
 释放一个block

 @param info 释放一个block
 */
static void AFNetworkReachabilityReleaseCallback(const void *info) {
    if (info) {
        Block_release(info);
    }
}

@interface AFNetworkReachabilityManager ()

/**
  介绍一：这里对 SCNetworkReachabilityRef 介绍下 首先SCNetworkReachabilityRef是 SystemConfiguration 中用来 测试联网状态相关的函数
 有两种创建方式 
 
 a）SCNetworkReachabilityRef SCNetworkReachabilityCreateWithAddress (
 CFAllocatorRef allocator,
 const struct sockaddr *address
 );
 根据传入的地址测试连接，第一个参数可以为NULL或kCFAllocatorDefault，第二个参数为需要测试连接的IP地址，当为0.0.0.0时则可以查询本机的网络连接状态。同时返回一个引用必须在用完后释放。
 
 
 b）SCNetworkReachabilityRef SCNetworkReachabilityCreateWithName (
 CFAllocatorRef allocator,
 const char *nodename
 );
 这个是根据传入的网址测试连接，第二个参数比如为"www.apple.com"，其他和上一个一样。
 
 
 介绍二：确定连接的状态 比如 是 WiFI WWAN 
 
 
 （2）确定连接的状态：
 Boolean SCNetworkReachabilityGetFlags (
 SCNetworkReachabilityRef target,
 SCNetworkReachabilityFlags *flags
 );
 这个函数用来获得测试连接的状态，第一个参数为之前建立的测试连接的引用，第二个参数用来保存获得的状态，如果能获得状态则返回TRUE，否则返回FALSE
 （3）主要的数据类型介绍：
 SCNetworkReachabilityRef：用来保存创建测试连接返回的引用
 （4）主要常量介绍：
 SCNetworkReachabilityFlags：保存返回的测试连接状态
 其中常用的状态有：
 kSCNetworkReachabilityFlagsReachable：能够连接网络
 kSCNetworkReachabilityFlagsConnectionRequired：能够连接网络，但是首先得建立连接过程
 kSCNetworkReachabilityFlagsIsWWAN：判断是否通过蜂窝网覆盖的连接，比如EDGE，GPRS或者目前的3G.主要是区别通过WiFi的连接。
 
 
 //上面的介绍来自 ：http://blog.csdn.net/zhibudefeng/article/details/7631230
 */
@property (readonly, nonatomic, assign) SCNetworkReachabilityRef networkReachability;///用来获取网络状态
@property (readwrite, nonatomic, assign) AFNetworkReachabilityStatus networkReachabilityStatus;
@property (readwrite, nonatomic, copy) AFNetworkReachabilityStatusBlock networkReachabilityStatusBlock;
@end

@implementation AFNetworkReachabilityManager

+ (instancetype)sharedManager {
    static AFNetworkReachabilityManager *_sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedManager = [self manager];
    });

    return _sharedManager;
}

/**
 通过 nodename  来初始化

 */
+ (instancetype)managerForDomain:(NSString *)domain {
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [domain UTF8String]);

    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];
    
    CFRelease(reachability);

    return manager;
}

/**
 通过 address 来初始化
 */
+ (instancetype)managerForAddress:(const void *)address {
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)address);
    
    AFNetworkReachabilityManager *manager = [[self alloc] initWithReachability:reachability];

    CFRelease(reachability);
    
    return manager;
}

+ (instancetype)manager
{
#if (defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && __IPHONE_OS_VERSION_MIN_REQUIRED >= 90000) || (defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 101100)
    struct sockaddr_in6 address;
    bzero(&address, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
#else
    struct sockaddr_in address;
    bzero(&address, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
#endif
    return [self managerForAddress:&address];
}


/**
 初始化自身  根据传入的SCNetworkReachabilityRef

 @param reachability 传入一个 测试网络状态的SCNetworkReachabilityRef
 @return 返回本身
 */
- (instancetype)initWithReachability:(SCNetworkReachabilityRef)reachability {
    self = [super init];
    if (!self) {
        return nil;
    }

    _networkReachability = CFRetain(reachability);
    self.networkReachabilityStatus = AFNetworkReachabilityStatusUnknown;

    return self;
}

/**
 NS_UNAVAILABLE 注意 init是不允许调用的

 */
- (instancetype)init NS_UNAVAILABLE
{
    return nil;
}

//dealloc  释放的时候 停止 和 release  _networkReachability
- (void)dealloc {
    [self stopMonitoring];
    
    if (_networkReachability != NULL) {
        CFRelease(_networkReachability);
    }
}

#pragma mark -

- (BOOL)isReachable {
    return [self isReachableViaWWAN] || [self isReachableViaWiFi];
}

- (BOOL)isReachableViaWWAN {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWWAN;
}

- (BOOL)isReachableViaWiFi {
    return self.networkReachabilityStatus == AFNetworkReachabilityStatusReachableViaWiFi;
}

#pragma mark -

- (void)startMonitoring {
    [self stopMonitoring];

    if (!self.networkReachability) {
        return;
    }

    __weak __typeof(self)weakSelf = self;
    AFNetworkReachabilityStatusBlock callback = ^(AFNetworkReachabilityStatus status) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;

        strongSelf.networkReachabilityStatus = status;
        if (strongSelf.networkReachabilityStatusBlock) {
            strongSelf.networkReachabilityStatusBlock(status);
        }

    };
/*
 SCNetworkReachabilityContext
 
 typedef struct {
	CFIndex		version;  第一个参数接受一个signed long 的参数
	void *		__nullable info; 第二个参数接受一个void * 类型的值，相当于oc的id类型，void * 可以指向任何类型的参数
	const void	* __nonnull (* __nullable retain)(const void *info); . 第三个参数 是一个函数 目的是对info做retain操作
	void		(* __nullable release)(const void *info);第四个参数是一个函数，目的是对info做release操作
	CFStringRef	__nonnull (* __nullable copyDescription)(const void *info);第五个参数是 一个函数，根据info获取Description字符串
 } SCNetworkReachabilityContext;
 */
    SCNetworkReachabilityContext context = {0, (__bridge void *)callback, AFNetworkReachabilityRetainCallback, AFNetworkReachabilityReleaseCallback, NULL};
    
    //设置回调函数
    SCNetworkReachabilitySetCallback(self.networkReachability, AFNetworkReachabilityCallback, &context);
    
    //加入runloop池中  CFRunLoopGetMain()代表主RunLoop
    SCNetworkReachabilityScheduleWithRunLoop(self.networkReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);

    //获取网络状态成功之后  在异步线程 发送一次当前的网络状态。  以后的变更都是依靠回调的
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0),^{
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.networkReachability, &flags)) {
            AFPostReachabilityStatusChange(flags, callback);
        }
    });
}

- (void)stopMonitoring {
    if (!self.networkReachability) {
        return;
    }
    //所谓的停止监听 就是从主线程池中移除
    SCNetworkReachabilityUnscheduleFromRunLoop(self.networkReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

#pragma mark -

- (NSString *)localizedNetworkReachabilityStatusString {
    return AFStringFromNetworkReachabilityStatus(self.networkReachabilityStatus);
}

#pragma mark -

- (void)setReachabilityStatusChangeBlock:(void (^)(AFNetworkReachabilityStatus status))block {
    self.networkReachabilityStatusBlock = block;
}

#pragma mark - NSKeyValueObserving  键值依赖  当reachable reachableViaWWAN reachableViaWiFi 变化的时候 就会触发networkReachabilityStatus 的监听方法

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    if ([key isEqualToString:@"reachable"] || [key isEqualToString:@"reachableViaWWAN"] || [key isEqualToString:@"reachableViaWiFi"]) {
        return [NSSet setWithObject:@"networkReachabilityStatus"];
    }

    return [super keyPathsForValuesAffectingValueForKey:key];
}

@end
#endif
