//
//  DaiSugarCoating.m
//  DaiMethodTracing
//
//  Created by DaidoujiChen on 2015/6/9.
//  Copyright (c) 2015年 DaidoujiChen. All rights reserved.
//

// reference https://github.com/mikeash/MABlockForwarding

#import "DaiSugarCoating.h"

#import <objc/runtime.h>
#import <objc/message.h>

#import "DaiMethodTracingType.h"
#import "DaiMethodTracingIMP.h"
#import "SFExecuteOnDeallocInternalObject.h"
#import "DaiMethodTracingLog.h"

typedef void (^BlockInterposer)(NSInvocation *invocation, NSString *deep, void (^call)(void));

typedef struct {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
} BlockDescriptor;

typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    BlockDescriptor *descriptor;
} Block;

enum {
    BLOCK_HAS_COPY_DISPOSE =  (1 << 25),
    BLOCK_HAS_CTOR =          (1 << 26),
    BLOCK_IS_GLOBAL =         (1 << 28),
    BLOCK_HAS_STRET =         (1 << 29),
    BLOCK_HAS_SIGNATURE =     (1 << 30),
};

@interface NSInvocation (PrivateAPI)

- (void)invokeUsingIMP:(IMP)imp;

@end

@interface DaiSugarCoating ()

@property (nonatomic, assign) int flags;
@property (nonatomic, assign) int reserved;
@property (nonatomic, assign) IMP invoke;
@property (nonatomic, assign) BlockDescriptor blockDescriptor;
@property (nonatomic, copy) id forwardingBlock;
@property (nonatomic, copy) BlockInterposer interposer;

@end

@implementation DaiSugarCoating

#pragma mark - private inctance method

- (const char *)blockSig:(id)blockObj
{
    Block *block = (__bridge void *)blockObj;
    BlockDescriptor *descriptor = block->descriptor;
    
    assert(block->flags & BLOCK_HAS_SIGNATURE);
    
    int index = 0;
    if (block->flags & BLOCK_HAS_COPY_DISPOSE) {
        index += 2;
    }
    return descriptor->rest[index];
}

- (void *)blockIMP:(id)blockObj
{
    return ((__bridge Block *)blockObj)->invoke;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    const char *types = [self blockSig:self.forwardingBlock];
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
    while ([signature numberOfArguments] < 2) {
        types = [[NSString stringWithFormat:@"%s%s", types, @encode(void *)] UTF8String];
        signature = [NSMethodSignature signatureWithObjCTypes:types];
    }
    return signature;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    [invocation setTarget:self.forwardingBlock];
    NSTimeInterval startTime = [[NSDate date] timeIntervalSince1970];
    NSString *deep = [DaiMethodTracingLog stackSymbol];
    [DaiMethodTracingLog tracingLog:[NSString stringWithFormat:@"<BLOCK: %p> type %@ {", self, [DaiMethodTracingLog blockFaces:invocation.methodSignature]] stack:deep logType:DaiMethodTracingLogStart];
    self.interposer(invocation, deep, ^{
        [invocation invokeUsingIMP:[self blockIMP:self.forwardingBlock]];
    });
    [DaiMethodTracingLog tracingLog:[NSString stringWithFormat:@"} <BLOCK: %p> type %@ , cost %fs", self, [DaiMethodTracingLog blockFaces:invocation.methodSignature], [[NSDate date] timeIntervalSince1970] - startTime] stack:deep logType:DaiMethodTracingLogFinish];
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

#pragma mark - private instance method

- (id)initWithBlock:(id)block interposer:(BlockInterposer)interposer
{
    self = [super init];
    if (self) {
        
        // 當目標 block 被 dealloc 時, 會回到這邊, 此時, 再對 DaiSugarCoating 做釋放, 避免過早被 dealloc 的問題
        SFExecuteOnDeallocInternalObject *internalObject = [[SFExecuteOnDeallocInternalObject alloc] initWithBlock: ^{
            [[DaiSugarCoating aliveMapping] removeObjectForKey:[NSString stringWithFormat:@"%p-%p", self, block]];
        }];
        objc_setAssociatedObject(block, _cmd, internalObject, OBJC_ASSOCIATION_RETAIN);
        
        // 轉印 data
        self.forwardingBlock = block;
        self.interposer = interposer;
        self.flags = ((__bridge Block *)block)->flags & ~0xFFFF;
        
        // 設定 BlockDescriptor
        BlockDescriptor newBlockDescriptor;
        newBlockDescriptor.size = class_getInstanceSize([self class]);
        int index = 0;
        if (_flags & BLOCK_HAS_COPY_DISPOSE) {
            index += 2;
        }
        newBlockDescriptor.rest[index] = (void *)[self blockSig:block];
        self.blockDescriptor = newBlockDescriptor;
        
        // 設定 invoke 的 function point
        if (_flags & BLOCK_HAS_STRET) {
            self.invoke = (IMP)_objc_msgForward_stret;
        } else {
            self.invoke = _objc_msgForward;
        }
    }
    
    // 保持自己活著
    [DaiSugarCoating aliveMapping][[NSString stringWithFormat:@"%p-%p", self, block]] = self;
    return self;
}

#pragma mark - private class method

+ (NSMutableDictionary *)aliveMapping
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        objc_setAssociatedObject(self, _cmd, [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    return objc_getAssociatedObject(self, _cmd);
}

#pragma mark - class method

+ (id)wrapBlock:(id)blockObj
{
    return [[DaiSugarCoating alloc] initWithBlock:blockObj interposer: ^(NSInvocation *invocation, NSString *deep, void (^call)(void)) {
        NSMethodSignature *signature = invocation.methodSignature;
        
        // 取得所有參數
        for (NSUInteger i = 1; i < signature.numberOfArguments; i++) {
            NSString *argumentType = [NSString stringWithFormat:@"%s", [signature getArgumentTypeAtIndex:i]];
            
            NSMutableString *argumentLogString = [NSMutableString string];
            [argumentLogString appendFormat:@"arg%td ", i];
            
            switch (tracingType(argumentType)) {
                case DaiMethodTracingTypeChar:
                {
                    char argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(char) %c", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeInt:
                {
                    int argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(int) %i", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeShort:
                {
                    short argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(short) %i", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeLong:
                {
                    long argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(long) %li", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeLongLong:
                {
                    long long argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(long long) %lld", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeUnsignedChar:
                {
                    unsigned char argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(unsigened char) %c", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeUnsignedInt:
                {
                    unsigned int argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(unsigned int) %i", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeUnsignedShort:
                {
                    unsigned short argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(unsigned short) %i", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeUnsignedLong:
                {
                    unsigned long argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(unsigned long) %lu", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeUnsignedLongLong:
                {
                    unsigned long long argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(unsigned long long) %llu", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeFloat:
                {
                    float argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(float) %f", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeDouble:
                {
                    double argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(double) %f", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeBool:
                {
                    BOOL argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(BOOL) %@", argument ? @"YES" : @"NO"];
                    break;
                }
                    
                case DaiMethodTracingTypeVoidPointer:
                {
                    void *argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(%@) %s", voidPointerAnalyze(argumentType), argument];
                    break;
                }
                    
                case DaiMethodTracingTypeCharPointer:
                {
                    char *argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(char *) %s", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeObject:
                {
                    __unsafe_unretained id argument;
                    [invocation getArgument:&argument atIndex:i];
                    if ([argument isKindOfClass:NSClassFromString(@"NSBlock")]) {
                        argument = [DaiSugarCoating wrapBlock:argument];
                        [invocation setArgument:&argument atIndex:i];
                    }
                    [argumentLogString appendFormat:@"(%@) %@", objectAnalyze(argumentType), [DaiMethodTracingLog simpleObject:argument]];
                    break;
                }
                    
                case DaiMethodTracingTypeClass:
                {
                    Class argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(Class) %@", argument];
                    break;
                }
                    
                case DaiMethodTracingTypeSelector:
                {
                    SEL argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(SEL) %@", NSStringFromSelector(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeCGRect:
                {
                    CGRect argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(CGRect) %@", NSStringFromCGRect(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeCGPoint:
                {
                    CGPoint argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(CGPoint) %@", NSStringFromCGPoint(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeCGSize:
                {
                    CGSize argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(CGSize) %@", NSStringFromCGSize(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeCGAffineTransform:
                {
                    CGAffineTransform argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(CGAffineTransform) %@", NSStringFromCGAffineTransform(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeUIEdgeInsets:
                {
                    UIEdgeInsets argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(UIEdgeInsets) %@", NSStringFromUIEdgeInsets(argument)];
                    break;
                }
                    
                case DaiMethodTracingTypeUIOffset:
                {
                    UIOffset argument;
                    [invocation getArgument:&argument atIndex:i];
                    [argumentLogString appendFormat:@"(UIOffset) %@", NSStringFromUIOffset(argument)];
                    break;
                }
                    
                default:
                    NSLog(@"%@, %@", NSStringFromSelector([invocation selector]), [NSString stringWithCString:[invocation.methodSignature getArgumentTypeAtIndex:i] encoding:NSUTF8StringEncoding]);
                    break;
            }
            [DaiMethodTracingLog tracingLog:argumentLogString stack:deep logType:DaiMethodTracingLogArgument];
        }
        
        // 判別回傳值型別
        NSString *returnType = [NSString stringWithFormat:@"%s", signature.methodReturnType];
        
        call();
        
        // 取得回傳值
        NSMutableString *returnLogString = [NSMutableString string];
        [returnLogString appendString:@"return "];
        switch (tracingType(returnType)) {
            case DaiMethodTracingTypeChar:
            {
                char argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(char) %c", argument];
                break;
            }
                
            case DaiMethodTracingTypeInt:
            {
                int argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(int) %i", argument];
                break;
            }
                
            case DaiMethodTracingTypeShort:
            {
                short argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(short) %i", argument];
                break;
            }
                
            case DaiMethodTracingTypeLong:
            {
                long argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(long) %li", argument];
                break;
            }
                
            case DaiMethodTracingTypeLongLong:
            {
                long long argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(long long) %lld", argument];
                break;
            }
                
            case DaiMethodTracingTypeUnsignedChar:
            {
                unsigned char argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(unsigened char) %c", argument];
                break;
            }
                
            case DaiMethodTracingTypeUnsignedInt:
            {
                unsigned int argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(unsigned int) %i", argument];
                break;
            }
                
            case DaiMethodTracingTypeUnsignedShort:
            {
                unsigned short argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(unsigned short) %i", argument];
                break;
            }
                
            case DaiMethodTracingTypeUnsignedLong:
            {
                unsigned long argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(unsigned long) %lu", argument];
                break;
            }
                
            case DaiMethodTracingTypeUnsignedLongLong:
            {
                unsigned long long argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(unsigned long long) %llu", argument];
                break;
            }
                
            case DaiMethodTracingTypeFloat:
            {
                float argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(float) %f", argument];
                break;
            }
                
            case DaiMethodTracingTypeDouble:
            {
                double argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(double) %f", argument];
                break;
            }
                
            case DaiMethodTracingTypeBool:
            {
                BOOL argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(BOOL) %@", argument ? @"YES" : @"NO"];
                break;
            }
                
            case DaiMethodTracingTypeVoidPointer:
            {
                void *argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(%@) %s", voidPointerAnalyze(returnType), argument];
                break;
            }
                
            case DaiMethodTracingTypeCharPointer:
            {
                char *argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(char *) %s", argument];
                break;
            }
                
            case DaiMethodTracingTypeObject:
            {
                id argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(%@) %@", objectAnalyze(returnType), [DaiMethodTracingLog simpleObject:argument]];
                break;
            }
                
            case DaiMethodTracingTypeClass:
            {
                Class argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(Class) %@", argument];
                break;
            }
                
            case DaiMethodTracingTypeSelector:
            {
                SEL argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(SEL) %@", NSStringFromSelector(argument)];
                break;
            }
                
            case DaiMethodTracingTypeCGRect:
            {
                CGRect argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(CGRect) %@", NSStringFromCGRect(argument)];
                break;
            }
                
            case DaiMethodTracingTypeCGPoint:
            {
                CGPoint argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(CGPoint) %@", NSStringFromCGPoint(argument)];
                break;
            }
                
            case DaiMethodTracingTypeCGSize:
            {
                CGSize argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(CGSize) %@", NSStringFromCGSize(argument)];
                break;
            }
                
            case DaiMethodTracingTypeCGAffineTransform:
            {
                CGAffineTransform argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(CGAffineTransform) %@", NSStringFromCGAffineTransform(argument)];
                break;
            }
                
            case DaiMethodTracingTypeUIEdgeInsets:
            {
                UIEdgeInsets argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(UIEdgeInsets) %@", NSStringFromUIEdgeInsets(argument)];
                break;
            }
                
            case DaiMethodTracingTypeUIOffset:
            {
                UIOffset argument;
                [invocation getReturnValue:&argument];
                [returnLogString appendFormat:@"(UIOffset) %@", NSStringFromUIOffset(argument)];
                break;
            }
                
            case DaiMethodTracingTypeVoid:
                [returnLogString appendString:@"void"];
                
            default:
                break;
        }
        [DaiMethodTracingLog tracingLog:returnLogString stack:deep logType:DaiMethodTracingLogReturn];
    }];
}

@end
