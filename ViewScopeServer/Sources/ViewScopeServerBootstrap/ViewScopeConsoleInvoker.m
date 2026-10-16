#import "ViewScopeServerBootstrap.h"
#import <TargetConditionals.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

/// 去掉 ObjC 类型编码前的修饰符（const / in / out / bycopy 等）。
static const char *ViewScopeStrippedTypeEncoding(const char *encoding) {
    while (encoding != NULL && *encoding != '\0' && strchr("rnNoORV", *encoding) != NULL) {
        encoding++;
    }
    return encoding;
}

/// 结构体名称，例如 "{CGRect={CGPoint=dd}{CGSize=dd}}" → "CGRect"。
static NSString *ViewScopeStructName(const char *encoding) {
    if (encoding == NULL || encoding[0] != '{') {
        return nil;
    }
    const char *start = encoding + 1;
    const char *end = strchr(start, '=');
    if (end == NULL) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:start length:(NSUInteger)(end - start) encoding:NSUTF8StringEncoding];
}

/// 结构体展开后的成员类型序列，例如 CGRect → "dddd"、NSRange → "QQ"。
static NSString *ViewScopeStructMemberTypes(const char *encoding) {
    if (encoding == NULL || encoding[0] != '{') {
        return nil;
    }
    NSMutableString *members = [NSMutableString string];
    const char *cursor = strchr(encoding, '=');
    if (cursor == NULL) {
        return nil;
    }
    cursor++;
    while (*cursor != '\0') {
        char current = *cursor;
        if (current == '{') {
            // 跳过嵌套结构体的名称部分。
            const char *equal = strchr(cursor, '=');
            if (equal == NULL) {
                return nil;
            }
            cursor = equal + 1;
            continue;
        }
        if (current == '}') {
            cursor++;
            continue;
        }
        [members appendFormat:@"%c", current];
        cursor++;
    }
    return members;
}

static BOOL ViewScopeMembersAreAll(NSString *members, unichar type) {
    if (members.length == 0) {
        return NO;
    }
    for (NSUInteger index = 0; index < members.length; index++) {
        if ([members characterAtIndex:index] != type) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary<NSString *, id> *ViewScopeErrorResult(NSString *message) {
    return @{ @"error": message ?: @"Unknown error" };
}

static NSString *ViewScopeFormatDouble(double value) {
    return [NSString stringWithFormat:@"%g", value];
}

@implementation ViewScopeConsoleInvoker

+ (BOOL)isMemoryManagementSelector:(NSString *)name {
    static NSSet<NSString *> *denied;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        denied = [NSSet setWithArray:@[@"dealloc", @"release", @"retain", @"autorelease", @"retainCount", @"zone"]];
    });
    return [denied containsObject:name];
}

+ (NSDictionary<NSString *, id> *)invokeSelectorNamed:(NSString *)selectorName
                                             onTarget:(id)target
                                            arguments:(NSArray<NSDictionary<NSString *, id> *> *)arguments {
    if (target == nil) {
        return ViewScopeErrorResult(@"Target is nil.");
    }
    if (selectorName.length == 0) {
        return ViewScopeErrorResult(@"Empty selector.");
    }
    // 兜底：Swift 侧已有完整的拒绝列表，这里再拦截一次内存管理方法。
    if ([self isMemoryManagementSelector:selectorName]) {
        return ViewScopeErrorResult([NSString stringWithFormat:@"'%@' is not allowed.", selectorName]);
    }

    SEL selector = NSSelectorFromString(selectorName);
    NSMethodSignature *signature = nil;
    @try {
        if (![target respondsToSelector:selector]) {
            return ViewScopeErrorResult([NSString stringWithFormat:@"%@ does not respond to '%@'.", NSStringFromClass(object_getClass(target)), selectorName]);
        }
        signature = [target methodSignatureForSelector:selector];
    } @catch (NSException *exception) {
        return ViewScopeErrorResult([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]);
    }
    if (signature == nil) {
        return ViewScopeErrorResult([NSString stringWithFormat:@"No method signature for '%@'.", selectorName]);
    }

    NSUInteger expectedArgumentCount = signature.numberOfArguments - 2;
    if (expectedArgumentCount != arguments.count) {
        return ViewScopeErrorResult([NSString stringWithFormat:@"'%@' expects %lu argument(s), got %lu.", selectorName, (unsigned long)expectedArgumentCount, (unsigned long)arguments.count]);
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    // 参数里的临时对象（字符串、颜色、CGColor 等）需要在调用期间保持存活。
    NSMutableArray *keepAlive = [NSMutableArray array];

    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString *error = nil;
        const char *type = ViewScopeStrippedTypeEncoding([signature getArgumentTypeAtIndex:index + 2]);
        if (![self setArgument:arguments[index] type:type atIndex:index + 2 invocation:invocation keepAlive:keepAlive error:&error]) {
            return ViewScopeErrorResult([NSString stringWithFormat:@"Argument %lu: %@", (unsigned long)(index + 1), error ?: @"unsupported value"]);
        }
    }
    [invocation retainArguments];

    @try {
        [invocation invokeWithTarget:target];
    } @catch (NSException *exception) {
        return ViewScopeErrorResult([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]);
    }

    return [self boxReturnValueOfInvocation:invocation signature:signature];
}

#pragma mark - 参数

+ (BOOL)setArgument:(NSDictionary<NSString *, id> *)argument
               type:(const char *)type
            atIndex:(NSUInteger)index
         invocation:(NSInvocation *)invocation
          keepAlive:(NSMutableArray *)keepAlive
              error:(NSString **)error {
    NSString *kind = argument[@"kind"];
    id value = argument[@"value"];
    char code = type[0];

    // 对象 / block。
    if (code == '@') {
        BOOL isBlock = type[1] == '?';
        id object = nil;
        if ([kind isEqualToString:@"nil"]) {
            object = nil;
        } else if (isBlock) {
            *error = @"block arguments only accept nil";
            return NO;
        } else if ([kind isEqualToString:@"string"] || [kind isEqualToString:@"number"] || [kind isEqualToString:@"object"]) {
            object = value;
        } else if ([kind isEqualToString:@"bool"]) {
            object = @([value boolValue]);
        } else if ([kind isEqualToString:@"color"]) {
            object = [self platformColorFromComponents:value];
            if (object == nil) {
                *error = @"invalid color";
                return NO;
            }
        } else {
            *error = [NSString stringWithFormat:@"cannot pass %@ as an object", kind];
            return NO;
        }
        if (object != nil) {
            [keepAlive addObject:object];
        }
        __unsafe_unretained id unretained = object;
        [invocation setArgument:&unretained atIndex:(NSInteger)index];
        return YES;
    }

    // Class。
    if (code == '#') {
        Class cls = Nil;
        if ([kind isEqualToString:@"string"]) {
            cls = NSClassFromString(value);
            if (cls == Nil) {
                *error = [NSString stringWithFormat:@"unknown class %@", value];
                return NO;
            }
        } else if ([kind isEqualToString:@"object"] && object_isClass(value)) {
            cls = value;
        } else if (![kind isEqualToString:@"nil"]) {
            *error = @"expected a class name string";
            return NO;
        }
        [invocation setArgument:&cls atIndex:(NSInteger)index];
        return YES;
    }

    // SEL。
    if (code == ':') {
        SEL selector = NULL;
        if ([kind isEqualToString:@"string"]) {
            selector = NSSelectorFromString(value);
        } else if (![kind isEqualToString:@"nil"]) {
            *error = @"expected a selector string";
            return NO;
        }
        [invocation setArgument:&selector atIndex:(NSInteger)index];
        return YES;
    }

    // C 字符串。
    if (code == '*') {
        const char *cString = NULL;
        if ([kind isEqualToString:@"string"]) {
            NSString *string = [value copy];
            [keepAlive addObject:string];
            cString = string.UTF8String;
        } else if (![kind isEqualToString:@"nil"]) {
            *error = @"expected a string";
            return NO;
        }
        [invocation setArgument:&cString atIndex:(NSInteger)index];
        return YES;
    }

    // CGColorRef。
    if (strncmp(type, "^{CGColor", 9) == 0) {
        CGColorRef color = NULL;
        if ([kind isEqualToString:@"color"]) {
            color = [self newCGColorFromComponents:value];
            if (color == NULL) {
                *error = @"invalid color";
                return NO;
            }
            [keepAlive addObject:(__bridge_transfer id)color];
        } else if (![kind isEqualToString:@"nil"]) {
            *error = @"expected a color (#RRGGBB)";
            return NO;
        }
        [invocation setArgument:&color atIndex:(NSInteger)index];
        return YES;
    }

    // 结构体：按成员类型逐个填充。
    if (code == '{') {
        if (![kind isEqualToString:@"struct"] || ![value isKindOfClass:[NSArray class]]) {
            *error = @"expected a struct literal such as {x, y, w, h}";
            return NO;
        }
        return [self setStructArgument:value type:type atIndex:index invocation:invocation error:error];
    }

    // 标量。
    if (strchr("cCsSiIlLqQBfd", code) != NULL) {
        if (!([kind isEqualToString:@"number"] || [kind isEqualToString:@"bool"]) || ![value isKindOfClass:[NSNumber class]]) {
            *error = @"expected a number or YES/NO";
            return NO;
        }
        double number = [value doubleValue];
        if (!isfinite(number)) {
            *error = @"number must be finite";
            return NO;
        }
        return [self setScalar:number code:code atIndex:index invocation:invocation error:error];
    }

    *error = [NSString stringWithFormat:@"unsupported parameter type %s", type];
    return NO;
}

+ (BOOL)setScalar:(double)number code:(char)code atIndex:(NSUInteger)index invocation:(NSInvocation *)invocation error:(NSString **)error {
    BOOL isUnsigned = strchr("CSILQ", code) != NULL;
    if (code != 'f' && code != 'd') {
        if (isUnsigned && number < 0) {
            *error = @"value must not be negative";
            return NO;
        }
        // 超出 64 位整数范围的值直接拒绝，避免未定义行为。
        if (number >= 9.2233720368547758e18 || number < -9.2233720368547758e18) {
            *error = @"value is out of range";
            return NO;
        }
    }
    switch (code) {
        case 'c': {
            char v = (char)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'C': {
            unsigned char v = (unsigned char)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'B': {
            bool v = number != 0;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 's': {
            short v = (short)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'S': {
            unsigned short v = (unsigned short)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'i': {
            int v = (int)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'I': {
            unsigned int v = (unsigned int)(long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'l': {
            long v = (long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'L': {
            unsigned long v = (unsigned long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'q': {
            long long v = (long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'Q': {
            unsigned long long v = (unsigned long long)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'f': {
            float v = (float)number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'd': {
            double v = number;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        default:
            *error = @"unsupported scalar type";
            return NO;
    }
    return YES;
}

+ (BOOL)setStructArgument:(NSArray *)components
                     type:(const char *)type
                  atIndex:(NSUInteger)index
               invocation:(NSInvocation *)invocation
                    error:(NSString **)error {
    NSString *members = ViewScopeStructMemberTypes(type);
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    if (members.length == 0 || members.length != components.count) {
        *error = [NSString stringWithFormat:@"%@ needs %lu numbers", ViewScopeStructName(type) ?: @"struct", (unsigned long)members.length];
        return NO;
    }
    for (id component in components) {
        if (![component isKindOfClass:[NSNumber class]] || !isfinite([component doubleValue])) {
            *error = @"struct members must be finite numbers";
            return NO;
        }
    }

    if (ViewScopeMembersAreAll(members, 'd') && size == members.length * sizeof(double)) {
        double *buffer = calloc(members.length, sizeof(double));
        for (NSUInteger i = 0; i < members.length; i++) {
            buffer[i] = [components[i] doubleValue];
        }
        [invocation setArgument:buffer atIndex:(NSInteger)index];
        free(buffer);
        return YES;
    }
    if (ViewScopeMembersAreAll(members, 'f') && size == members.length * sizeof(float)) {
        float *buffer = calloc(members.length, sizeof(float));
        for (NSUInteger i = 0; i < members.length; i++) {
            buffer[i] = [components[i] floatValue];
        }
        [invocation setArgument:buffer atIndex:(NSInteger)index];
        free(buffer);
        return YES;
    }
    BOOL unsignedMembers = ViewScopeMembersAreAll(members, 'Q') || ViewScopeMembersAreAll(members, 'L');
    BOOL signedMembers = ViewScopeMembersAreAll(members, 'q') || ViewScopeMembersAreAll(members, 'l');
    if ((unsignedMembers || signedMembers) && size == members.length * sizeof(long long)) {
        long long *buffer = calloc(members.length, sizeof(long long));
        for (NSUInteger i = 0; i < members.length; i++) {
            double number = [components[i] doubleValue];
            if ((unsignedMembers && number < 0) || fabs(number) >= 9.2233720368547758e18) {
                free(buffer);
                *error = @"struct member is out of range";
                return NO;
            }
            buffer[i] = (long long)number;
        }
        [invocation setArgument:buffer atIndex:(NSInteger)index];
        free(buffer);
        return YES;
    }

    *error = [NSString stringWithFormat:@"unsupported struct type %s", type];
    return NO;
}

#pragma mark - 颜色

+ (BOOL)readColorComponents:(id)value red:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha {
    if (![value isKindOfClass:[NSArray class]] || [value count] != 4) {
        return NO;
    }
    NSArray *components = value;
    CGFloat values[4];
    for (NSUInteger i = 0; i < 4; i++) {
        if (![components[i] isKindOfClass:[NSNumber class]]) {
            return NO;
        }
        double component = [components[i] doubleValue];
        if (!isfinite(component)) {
            return NO;
        }
        values[i] = (CGFloat)MAX(0.0, MIN(1.0, component));
    }
    *red = values[0];
    *green = values[1];
    *blue = values[2];
    *alpha = values[3];
    return YES;
}

+ (id)platformColorFromComponents:(id)value {
    CGFloat red = 0;
    CGFloat green = 0;
    CGFloat blue = 0;
    CGFloat alpha = 0;
    if (![self readColorComponents:value red:&red green:&green blue:&blue alpha:&alpha]) {
        return nil;
    }
#if TARGET_OS_OSX
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
#else
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
#endif
}

+ (CGColorRef)newCGColorFromComponents:(id)value CF_RETURNS_RETAINED {
    CGFloat components[4] = {0, 0, 0, 0};
    if (![self readColorComponents:value red:&components[0] green:&components[1] blue:&components[2] alpha:&components[3]]) {
        return NULL;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace == NULL) {
        return NULL;
    }
    CGColorRef color = CGColorCreate(colorSpace, components);
    CGColorSpaceRelease(colorSpace);
    return color;
}

#pragma mark - 返回值

+ (NSDictionary<NSString *, id> *)boxReturnValueOfInvocation:(NSInvocation *)invocation signature:(NSMethodSignature *)signature {
    const char *rawType = signature.methodReturnType;
    const char *type = ViewScopeStrippedTypeEncoding(rawType);
    NSString *typeString = [NSString stringWithUTF8String:rawType] ?: @"?";
    char code = type[0];

    if (code == 'v') {
        return @{ @"returnType": typeString, @"isVoid": @YES };
    }

    if (code == '@' || code == '#') {
        __unsafe_unretained id unretained = nil;
        [invocation getReturnValue:&unretained];
        id object = unretained;
        if (object == nil) {
            return @{ @"returnType": typeString, @"isNil": @YES };
        }
        return @{ @"returnType": typeString, @"object": object };
    }

    // CGColorRef / CGImageRef 等 CF 对象：作为对象返回，便于继续在 console 中引用。
    if (strncmp(type, "^{CGColor", 9) == 0 || strncmp(type, "^{CGImage", 9) == 0 || strncmp(type, "^{CGPath", 8) == 0) {
        void *pointer = NULL;
        [invocation getReturnValue:&pointer];
        if (pointer == NULL) {
            return @{ @"returnType": typeString, @"isNil": @YES };
        }
        id object = (__bridge id)pointer;
        return @{ @"returnType": typeString, @"object": object };
    }

    if (code == ':') {
        SEL selector = NULL;
        [invocation getReturnValue:&selector];
        return @{ @"returnType": typeString, @"description": selector != NULL ? NSStringFromSelector(selector) : @"nil" };
    }

    if (code == '*') {
        const char *cString = NULL;
        [invocation getReturnValue:&cString];
        NSString *string = cString != NULL ? [NSString stringWithUTF8String:cString] : nil;
        return @{ @"returnType": typeString, @"description": string != nil ? [NSString stringWithFormat:@"\"%@\"", string] : @"NULL" };
    }

    NSString *description = [self describeScalarReturnOfInvocation:invocation code:code];
    if (description != nil) {
        return @{ @"returnType": typeString, @"description": description };
    }

    if (code == '{') {
        NSString *structDescription = [self describeStructReturnOfInvocation:invocation type:type length:signature.methodReturnLength];
        if (structDescription != nil) {
            return @{ @"returnType": typeString, @"description": structDescription };
        }
    }

    return ViewScopeErrorResult([NSString stringWithFormat:@"Unsupported return type %@.", typeString]);
}

+ (NSString *)describeScalarReturnOfInvocation:(NSInvocation *)invocation code:(char)code {
    switch (code) {
        case 'B': {
            bool value = false;
            [invocation getReturnValue:&value];
            return value ? @"YES" : @"NO";
        }
        case 'c': {
            // x86_64 上 BOOL 编码为 'c'：0/1 按 BOOL 显示，其他值按数字显示。
            char value = 0;
            [invocation getReturnValue:&value];
            if (value == 0 || value == 1) {
                return value ? @"YES" : @"NO";
            }
            return [NSString stringWithFormat:@"%d", value];
        }
        case 'C': {
            unsigned char value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%u", value];
        }
        case 's': {
            short value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%d", value];
        }
        case 'S': {
            unsigned short value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%u", value];
        }
        case 'i': {
            int value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%d", value];
        }
        case 'I': {
            unsigned int value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%u", value];
        }
        case 'l': {
            long value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%ld", value];
        }
        case 'L': {
            unsigned long value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%lu", value];
        }
        case 'q': {
            long long value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%lld", value];
        }
        case 'Q': {
            unsigned long long value = 0;
            [invocation getReturnValue:&value];
            return [NSString stringWithFormat:@"%llu", value];
        }
        case 'f': {
            float value = 0;
            [invocation getReturnValue:&value];
            return ViewScopeFormatDouble(value);
        }
        case 'd': {
            double value = 0;
            [invocation getReturnValue:&value];
            return ViewScopeFormatDouble(value);
        }
        default:
            return nil;
    }
}

+ (NSString *)describeStructReturnOfInvocation:(NSInvocation *)invocation type:(const char *)type length:(NSUInteger)length {
    NSString *name = ViewScopeStructName(type);
    NSString *members = ViewScopeStructMemberTypes(type);
    if (length == 0 || members.length == 0) {
        return nil;
    }
    void *buffer = calloc(1, length);
    [invocation getReturnValue:buffer];
    NSString *description = nil;

    if (ViewScopeMembersAreAll(members, 'd') && length == members.length * sizeof(double)) {
        double *values = buffer;
        if ([name isEqualToString:@"CGRect"] && members.length == 4) {
            description = [NSString stringWithFormat:@"{{%@, %@}, {%@, %@}}", ViewScopeFormatDouble(values[0]), ViewScopeFormatDouble(values[1]), ViewScopeFormatDouble(values[2]), ViewScopeFormatDouble(values[3])];
        } else if ([name isEqualToString:@"CGAffineTransform"] && members.length == 6) {
            description = [NSString stringWithFormat:@"[a: %@, b: %@, c: %@, d: %@, tx: %@, ty: %@]", ViewScopeFormatDouble(values[0]), ViewScopeFormatDouble(values[1]), ViewScopeFormatDouble(values[2]), ViewScopeFormatDouble(values[3]), ViewScopeFormatDouble(values[4]), ViewScopeFormatDouble(values[5])];
        } else {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSUInteger i = 0; i < members.length; i++) {
                [parts addObject:ViewScopeFormatDouble(values[i])];
            }
            description = [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
        }
    } else if ((ViewScopeMembersAreAll(members, 'Q') || ViewScopeMembersAreAll(members, 'L')) && length == members.length * sizeof(unsigned long long)) {
        unsigned long long *values = buffer;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSUInteger i = 0; i < members.length; i++) {
            [parts addObject:[NSString stringWithFormat:@"%llu", values[i]]];
        }
        description = [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    } else if ((ViewScopeMembersAreAll(members, 'q') || ViewScopeMembersAreAll(members, 'l')) && length == members.length * sizeof(long long)) {
        long long *values = buffer;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSUInteger i = 0; i < members.length; i++) {
            [parts addObject:[NSString stringWithFormat:@"%lld", values[i]]];
        }
        description = [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    free(buffer);
    if (description != nil && name.length > 0) {
        return [NSString stringWithFormat:@"(%@) %@", name, description];
    }
    return description;
}

@end
