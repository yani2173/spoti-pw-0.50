#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <string.h>

// Expected arguments exclude self/_cmd. BOOL is 'B' on arm64 and can be 'c' on macOS test hosts.
static inline BOOL SGPerfTypeMatches(char actual, char expected) {
    return actual == expected || (expected == 'B' && actual == 'c');
}

static inline BOOL SGPerfHasMethod(Class cls, SEL selector, char result, const char *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != strlen(arguments) + 2) return NO;
    char type[64] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (!SGPerfTypeMatches(type[0], result)) return NO;
    for (unsigned int i = 0; arguments[i]; i++) {
        method_getArgumentType(method, i + 2, type, sizeof(type));
        if (!SGPerfTypeMatches(type[0], arguments[i])) return NO;
    }
    return YES;
}

static inline void SGPerfReplaceMethod(Class cls, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(cls, selector);
    // Override an inherited method on this class instead of replacing its superclass's method.
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)))
        method_setImplementation(method, implementation);
}
