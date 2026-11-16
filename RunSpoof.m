// =====================================================================
//  RunSpoof.m —— 运动世界 iOS 全自动校园跑
//  ---------------------------------------------------------------------
//  设计原则：
//    1. 纯 Objective-C runtime swizzling，不依赖 Logos / substrate / ellekit
//    2. 编译产物是自包含 arm64 dylib，TrollFools 直接注入
//    3. 不需要越狱，不需要 PC 常连
//    4. App 内零可见框架（无 substrate、无 frida、无注入器进程）
//
//  编译（GitHub Actions macOS runner）：
//    xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
//      -dynamiclib -fobjc-arc -O2 \
//      -framework Foundation -framework CoreLocation \
//      -framework CoreMotion -framework UIKit \
//      -o RunSpoof.dylib RunSpoof.m
//    ldid -S RunSpoof.dylib
// =====================================================================
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>

// 内嵌轨迹（由 gen_route_header.py 生成，缺省为空）
#if __has_include("route_data.h")
#  include "route_data.h"
#else
static const char *kEmbeddedRoute = "";
#endif

#define RSLOG(fmt, ...) NSLog(@"[RunSpoof] " fmt, ##__VA_ARGS__)

// =====================================================================
//  轨迹状态
// =====================================================================
static NSArray      *gRoute  = nil;
static NSUInteger    gIdx    = 0;
static BOOL          gActive = NO;
static BOOL          gLoaded = NO;
static NSTimer      *gTimer  = nil;

static double gLat = 0.0, gLon = 0.0;
static double gSpeed = 3.1, gCourse = 0.0, gAcc = 8.0, gAlt = 52.0;

// =====================================================================
//  swizzling 基础设施
// =====================================================================
static void RSSwizzle(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { RSLOG(@"方法不存在: %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

static void RSSwizzleClass(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

// =====================================================================
//  轨迹加载
// =====================================================================
static NSString *RSRoutePath(void) {
    NSString *a = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/route.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:a]) return a;
    NSString *b = [NSTemporaryDirectory() stringByAppendingPathComponent:@"route.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:b]) return b;
    NSString *c = @"/var/mobile/Documents/route.json";
    if ([[NSFileManager defaultManager] fileExistsAtPath:c]) return c;
    return a;
}

static void RSLoadRoute(void) {
    if (gLoaded) return;
    gLoaded = YES;
    NSString *p = RSRoutePath();
    RSLOG(@"轨迹路径: %@", p);
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d || d.length < 10) {
        // 兜底：使用编译期内嵌的轨迹，完全不依赖外部文件
        size_t n = strlen(kEmbeddedRoute);
        if (n > 10) {
            d = [NSData dataWithBytes:kEmbeddedRoute length:n];
            RSLOG(@"外部轨迹不可用，改用内嵌轨迹 (%zu 字节)", n);
        } else {
            RSLOG(@"轨迹读取失败，且无内嵌数据");
            return;
        }
    }
    NSError *e = nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if (![o isKindOfClass:[NSArray class]]) { RSLOG(@"轨迹格式错误: %@", e); return; }
    gRoute = (NSArray *)o;
    RSLOG(@"轨迹已加载: %lu 点", (unsigned long)gRoute.count);
}

static void RSStartPlayback(void) {
    if (gTimer || gRoute.count == 0) return;
    gActive = YES;
    gIdx = 0;
    gTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (gIdx >= gRoute.count) {
            [t invalidate];
            gTimer = nil;
            gActive = NO;
            RSLOG(@"轨迹播放完成");
            return;
        }
        NSDictionary *p = gRoute[gIdx];
        gLat    = [p[@"lat"] doubleValue];
        gLon    = [p[@"lon"] doubleValue];
        gSpeed  = p[@"v"]      ? [p[@"v"] doubleValue]      : 3.1;
        gCourse = p[@"course"] ? [p[@"course"] doubleValue] : 0.0;
        gAcc    = p[@"acc"]    ? [p[@"acc"] doubleValue]    : 8.0;
        gAlt   += ((double)(arc4random_uniform(200)) - 100.0) / 100.0;
        if (gIdx % 20 == 0)
            RSLOG(@"[%lu/%lu] %.6f,%.6f v=%.2f", (unsigned long)gIdx,
                  (unsigned long)gRoute.count, gLat, gLon, gSpeed);
        gIdx++;
    }];
    RSLOG(@"轨迹播放开始");
}

// =====================================================================
//  1. CLLocation —— 位置伪造核心
// =====================================================================
static CLLocationCoordinate2D (*o_coordinate)(id, SEL);
static CLLocationCoordinate2D n_coordinate(id self, SEL _cmd) {
    if (gActive) {
        CLLocationCoordinate2D c; c.latitude = gLat; c.longitude = gLon;
        return c;
    }
    return o_coordinate(self, _cmd);
}

static CLLocationSpeed (*o_speed)(id, SEL);
static CLLocationSpeed n_speed(id self, SEL _cmd) {
    return gActive ? gSpeed : o_speed(self, _cmd);
}

static CLLocationDirection (*o_course)(id, SEL);
static CLLocationDirection n_course(id self, SEL _cmd) {
    return gActive ? gCourse : o_course(self, _cmd);
}

static CLLocationAccuracy (*o_hacc)(id, SEL);
static CLLocationAccuracy n_hacc(id self, SEL _cmd) {
    return gActive ? gAcc : o_hacc(self, _cmd);
}

static CLLocationAccuracy (*o_vacc)(id, SEL);
static CLLocationAccuracy n_vacc(id self, SEL _cmd) {
    if (!gActive) return o_vacc(self, _cmd);
    return 4.0 + (double)(arc4random_uniform(50)) / 10.0;
}

static CLLocationDistance (*o_alt)(id, SEL);
static CLLocationDistance n_alt(id self, SEL _cmd) {
    return gActive ? gAlt : o_alt(self, _cmd);
}

static NSDate *(*o_timestamp)(id, SEL);
static NSDate *n_timestamp(id self, SEL _cmd) {
    return gActive ? [NSDate date] : o_timestamp(self, _cmd);
}

// =====================================================================
//  2. CLLocationSourceInformation —— 压掉"软件模拟"标记
// =====================================================================
static BOOL (*o_simSoftware)(id, SEL);
static BOOL n_simSoftware(id self, SEL _cmd) { return NO; }

static BOOL (*o_prodAccessory)(id, SEL);
static BOOL n_prodAccessory(id self, SEL _cmd) { return NO; }

// =====================================================================
//  3. CLLocationManager —— 开始定位就自动播放轨迹
// =====================================================================
static void (*o_startUpdate)(id, SEL);
static void n_startUpdate(id self, SEL _cmd) {
    RSLoadRoute();
    o_startUpdate(self, _cmd);
    if (!gActive) RSStartPlayback();
}

static void (*o_reqLoc)(id, SEL);
static void n_reqLoc(id self, SEL _cmd) {
    RSLoadRoute();
    o_reqLoc(self, _cmd);
    if (!gActive) RSStartPlayback();
}

// =====================================================================
//  4. CMPedometer —— 计步伪造（与速度曲线严格对齐）
//     核心公式：速度 = 步频 × 步幅
//     步幅取真人区间 1.05~1.24 m，步频由当前速度反推
//     这样任何时刻 speed / cadence / stride 三者都能对上
// =====================================================================
static NSUInteger RSStepsEx(NSTimeInterval dt, double *outStride) {
    double stride = 1.05 + (double)(arc4random_uniform(20)) / 100.0;   // 1.05~1.24 m
    double v = (gActive && gSpeed > 0.5) ? gSpeed : 3.2;               // 与轨迹当前速度同步
    double cadence = v / stride;                                        // 步/秒
    if (cadence < 1.20) cadence = 1.20;                                 // 慢走下限 72 步/分
    if (cadence > 4.20) cadence = 4.20;                                 // 冲刺上限 252 步/分
    if (outStride) *outStride = stride;
    return (NSUInteger)MAX(1.0, dt * cadence);
}
static NSUInteger RSSteps(NSTimeInterval dt) { return RSStepsEx(dt, NULL); }

static CMPedometerData *RSFakePedometer(NSTimeInterval dt, NSDate *s, NSDate *e) {
    double stride = 0;
    NSUInteger steps = RSStepsEx(dt, &stride);
    double dist      = steps * stride;
    double v         = dt > 0 ? dist / dt : 3.2;
    CMPedometerData *d = [[CMPedometerData alloc] init];
    @try {
        [d setValue:@(steps)                    forKey:@"numberOfSteps"];
        [d setValue:@(dist)                     forKey:@"distance"];
        [d setValue:@(v)                        forKey:@"averageActivePace"];
        [d setValue:@(v)                        forKey:@"currentPace"];
        [d setValue:@(fmin(3.4, fmax(1.2, v / stride))) forKey:@"currentCadence"];
        [d setValue:s                            forKey:@"startDate"];
        [d setValue:e                            forKey:@"endDate"];
        [d setValue:@(steps)                    forKey:@"numberOfPaces"];
        [d setValue:@(0)                        forKey:@"numberOfFloorsAscended"];
        [d setValue:@(0)                        forKey:@"numberOfFloorsDescended"];
    } @catch (NSException *ex) {
        RSLOG(@"CMPedometerData KVC 失败: %@", ex.reason);
    }
    return d;
}

static void (*o_pedQuery)(id, SEL, NSDate *, NSDate *, CMPedometerHandler);
static void n_pedQuery(id self, SEL _cmd, NSDate *s, NSDate *e, CMPedometerHandler h) {
    NSTimeInterval dt = [e timeIntervalSinceDate:s];
    if (dt <= 0) { o_pedQuery(self, _cmd, s, e, h); return; }
    RSLOG(@"queryPedometer %.0fs", dt);
    if (h) h(RSFakePedometer(dt, s, e), nil);
}

static void (*o_pedStart)(id, SEL, NSDate *, CMPedometerHandler);
static void n_pedStart(id self, SEL _cmd, NSDate *s, CMPedometerHandler h) {
    if (h) h(RSFakePedometer(1.0, s, [NSDate date]), nil);
}

static BOOL (*o_capA)(id, SEL);
static BOOL n_capA(id self, SEL _cmd) { return YES; }
static BOOL (*o_capB)(id, SEL);
static BOOL n_capB(id self, SEL _cmd) { return YES; }
static BOOL (*o_capC)(id, SEL);
static BOOL n_capC(id self, SEL _cmd) { return YES; }
static BOOL (*o_capD)(id, SEL);
static BOOL n_capD(id self, SEL _cmd) { return YES; }

// =====================================================================
//  5. CMAltimeter —— 气压计噪声（防"气压恒定"判定）
// =====================================================================
static BOOL (*o_altAvail)(id, SEL);
static BOOL n_altAvail(id self, SEL _cmd) { return YES; }

static void (*o_altStart)(id, SEL, NSOperationQueue *, CMAltitudeHandler);
static void n_altStart(id self, SEL _cmd, NSOperationQueue *q, CMAltitudeHandler h) {
    if (!h) return;
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        double alt = 52.0 + ((double)(arc4random_uniform(200)) - 100.0) / 100.0;
        CMAltitudeData *d = [[CMAltitudeData alloc] init];
        @try {
            [d setValue:@(alt) forKey:@"relativeAltitude"];
            [d setValue:@(98.5 + (double)(arc4random_uniform(40)) / 100.0) forKey:@"pressure"];
        } @catch (NSException *ex) {}
        h(d, nil);
    }];
}

// =====================================================================
//  6. CMMotionManager —— 原始加速度波形（重力 + 步频正弦 + 噪声）
// =====================================================================
static void (*o_accStart)(id, SEL, NSOperationQueue *, CMAccelerometerHandler);
static void n_accStart(id self, SEL _cmd, NSOperationQueue *q, CMAccelerometerHandler h) {
    if (!h) return;
    __block double phase = 0.0;
    [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *t) {
        phase += 2.80 * 2.0 * M_PI * 0.02;
        double amp = 0.85;
        double ax = amp * sin(phase)        + ((double)(arc4random_uniform(200)) - 100.0) / 4000.0;
        double ay = amp * cos(phase) * 0.6  + ((double)(arc4random_uniform(200)) - 100.0) / 4000.0;
        double az = 9.81 + amp * 0.8 * sin(phase * 2.0)
                           + ((double)(arc4random_uniform(200)) - 100.0) / 4000.0;
        CMAccelerometerData *d = [[CMAccelerometerData alloc] init];
        @try {
            CMAcceleration a; a.x = ax; a.y = ay; a.z = az;
            [d setValue:[NSValue value:&a withObjCType:@encode(CMAcceleration)]
                 forKey:@"acceleration"];
        } @catch (NSException *ex) {}
        h(d, nil);
    }];
}

// =====================================================================
//  7. 越狱痕迹隐藏
// =====================================================================
static BOOL (*o_fileExists)(id, SEL, NSString *);
static BOOL n_fileExists(id self, SEL _cmd, NSString *path) {
    static NSArray *traces = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        traces = @[ @"/var/jb", @"/private/preboot", @"/Applications/Cydia.app",
                    @"/Applications/Sileo.app", @"/Applications/Zebra.app",
                    @"/usr/lib/libellekit.dylib", @"/usr/lib/libsubstrate.dylib",
                    @"/usr/lib/libhooker.dylib", @"/usr/sbin/sshd",
                    @"/etc/apt", @"/var/lib/dpkg", @"/usr/bin/cycript",
                    @"/bin/bash", @"/Library/MobileSubstrate", @"/var/lib/filza",
                    @"/usr/bin/ssh", @"/var/lib/apt", @"/var/mobile/Library/Preferences/xtweak" ];
    });
    for (NSString *t in traces)
        if ([path hasPrefix:t]) return NO;
    return o_fileExists(self, _cmd, path);
}

// =====================================================================
//  8. URL Scheme 探测拦截
// =====================================================================
static BOOL (*o_canOpen)(id, SEL, NSURL *);
static BOOL n_canOpen(id self, SEL _cmd, NSURL *url) {
    NSString *s = url.scheme.lowercaseString;
    if ([s isEqualToString:@"cydia"] || [s isEqualToString:@"sileo"] ||
        [s isEqualToString:@"zbra"]  || [s isEqualToString:@"zebra"] ||
        [s isEqualToString:@"filza"] || [s isEqualToString:@"santander"])
        return NO;
    return o_canOpen(self, _cmd, url);
}

// =====================================================================
//  9. 环境变量清理
// =====================================================================
static NSDictionary *(*o_env)(id, SEL);
static NSDictionary *n_env(id self, SEL _cmd) {
    NSMutableDictionary *d = [o_env(self, _cmd) mutableCopy];
    [d removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [d removeObjectForKey:@"_MSSafeMode"];
    [d removeObjectForKey:@"TROLLSTORE"];
    return d;
}

// =====================================================================
//  安装
// =====================================================================
__attribute__((constructor))
static void RSInit(void) {
    RSLOG(@"RunSpoof 加载中…");

    // 位置
    RSSwizzle([CLLocation class], @selector(coordinate),
              (IMP)n_coordinate, (IMP *)&o_coordinate);
    RSSwizzle([CLLocation class], @selector(speed),
              (IMP)n_speed, (IMP *)&o_speed);
    RSSwizzle([CLLocation class], @selector(course),
              (IMP)n_course, (IMP *)&o_course);
    RSSwizzle([CLLocation class], @selector(horizontalAccuracy),
              (IMP)n_hacc, (IMP *)&o_hacc);
    RSSwizzle([CLLocation class], @selector(verticalAccuracy),
              (IMP)n_vacc, (IMP *)&o_vacc);
    RSSwizzle([CLLocation class], @selector(altitude),
              (IMP)n_alt, (IMP *)&o_alt);
    RSSwizzle([CLLocation class], @selector(timestamp),
              (IMP)n_timestamp, (IMP *)&o_timestamp);

    // 模拟标记
    Class srcInfo = NSClassFromString(@"CLLocationSourceInformation");
    if (srcInfo) {
        RSSwizzle(srcInfo, @selector(isSimulatedBySoftware),
                  (IMP)n_simSoftware, (IMP *)&o_simSoftware);
        RSSwizzle(srcInfo, @selector(isProducedByAccessory),
                  (IMP)n_prodAccessory, (IMP *)&o_prodAccessory);
    }

    // 定位启动
    RSSwizzle([CLLocationManager class], @selector(startUpdatingLocation),
              (IMP)n_startUpdate, (IMP *)&o_startUpdate);
    RSSwizzle([CLLocationManager class], @selector(requestLocation),
              (IMP)n_reqLoc, (IMP *)&o_reqLoc);

    // 计步
    RSSwizzle([CMPedometer class],
              @selector(queryPedometerDataFromDate:toDate:withHandler:),
              (IMP)n_pedQuery, (IMP *)&o_pedQuery);
    RSSwizzle([CMPedometer class],
              @selector(startUpdatesFromDate:withHandler:),
              (IMP)n_pedStart, (IMP *)&o_pedStart);
    RSSwizzle([CMPedometer class], @selector(isStepCountingAvailable), (IMP)n_capA, (IMP *)&o_capA);
    RSSwizzle([CMPedometer class], @selector(isDistanceAvailable),     (IMP)n_capB, (IMP *)&o_capB);
    RSSwizzle([CMPedometer class], @selector(isPaceAvailable),         (IMP)n_capC, (IMP *)&o_capC);
    RSSwizzle([CMPedometer class], @selector(isCadenceAvailable),      (IMP)n_capD, (IMP *)&o_capD);

    // 气压
    Class altCls = NSClassFromString(@"CMAltimeter");
    if (altCls) {
        RSSwizzleClass(altCls, @selector(isRelativeAltitudeAvailable),
                       (IMP)n_altAvail, (IMP *)&o_altAvail);
        RSSwizzle(altCls, @selector(startRelativeAltitudeUpdatesToQueue:withHandler:),
                  (IMP)n_altStart, (IMP *)&o_altStart);
    }

    // 加速度
    RSSwizzle([CMMotionManager class],
              @selector(startAccelerometerUpdatesToQueue:withHandler:),
              (IMP)n_accStart, (IMP *)&o_accStart);

    // 越狱隐藏
    RSSwizzle([NSFileManager class], @selector(fileExistsAtPath:),
              (IMP)n_fileExists, (IMP *)&o_fileExists);
    RSSwizzle([UIApplication class], @selector(canOpenURL:),
              (IMP)n_canOpen, (IMP *)&o_canOpen);
    RSSwizzle([NSProcessInfo class], @selector(environment),
              (IMP)n_env, (IMP *)&o_env);

    RSLoadRoute();
    RSLOG(@"RunSpoof 就绪，轨迹 %lu 点", (unsigned long)gRoute.count);

    // 兜底：若 App 不主动 startUpdatingLocation，30 秒后自启
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30ull * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (!gActive && gRoute.count > 0) {
            RSLOG(@"兜底启动轨迹播放");
            RSStartPlayback();
        }
    });
}