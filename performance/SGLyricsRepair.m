#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#ifndef SG_LYRICS_REPAIR_TEST
#import <MediaPlayer/MediaPlayer.h>
#endif

// All offsets refer to the original, UUID-pinned 0.51.0 arm64 image, not Spotify.
static uintptr_t coreBase;
static const uintptr_t bytesReturn = 0x257a34, jsonReturn = 0x257a58, restoreReturn = 0x24fcc4;
static const uintptr_t selectorOffsets[] = {0x5040a8, 0x5038a0, 0x507d30};
static double (*originalElapsed)(id, double, double);

static id safeLyricsJSON(id root) {
    if (![root isKindOfClass:NSDictionary.class]) return root;
    id lyrics = root[@"lyrics"];
    if (![lyrics isKindOfClass:NSDictionary.class]) return root;
    id sync = lyrics[@"syncType"];
    if (![sync isEqual:@"LINE_SYNCED"] && ![sync isEqual:@"UNSYNCED"]) return root;
    id lines = lyrics[@"lines"];
    // Missing lines already behaves like an empty list in the core.
    if (!lines) return root;
    NSMutableArray *safe = nil;
    if (![lines isKindOfClass:NSArray.class]) safe = [NSMutableArray array];
    else {
        NSUInteger index = 0;
        for (id line in lines) {
            id time = [line isKindOfClass:NSDictionary.class] ? line[@"startTimeMs"] : nil;
            // Preserve the core's nil -> 0 and NSString/NSNumber conversion semantics.
            BOOL valid = !time || [time isKindOfClass:NSString.class] || [time isKindOfClass:NSNumber.class];
            if (!valid && !safe) safe = [[lines subarrayWithRange:NSMakeRange(0, index)] mutableCopy];
            if (safe && valid) [safe addObject:line];
            index++;
        }
    }
    if (!safe) return root; // Valid data keeps its identity and all original fields.
    NSMutableDictionary *updatedLyrics = [lyrics mutableCopy];
    updatedLyrics[@"lines"] = [safe copy];
    NSMutableDictionary *updatedRoot = [root mutableCopy];
    updatedRoot[@"lyrics"] = [updatedLyrics copy];
    return [updatedRoot copy];
}

static const void *bytesForCaller(id receiver, const void *bytes, uintptr_t caller) {
    if (caller != coreBase + bytesReturn || ![receiver isKindOfClass:NSData.class] || !bytes) return bytes;
    const unsigned char *p = bytes;
    NSUInteger count = [(NSData *)receiver length], i = 0;
    while (i < count && (p[i] == ' ' || p[i] == '\t' || p[i] == '\r' || p[i] == '\n')) i++;
    // Only the guarded single-byte format sniff sees this pointer. Full reads retain
    // the original pointer/length, including protobuf and JSON deserialization.
    return i < count && p[i] == '{' ? p + i : bytes;
}

static id jsonForCaller(id root, uintptr_t caller) {
    return caller == coreBase + jsonReturn ? safeLyricsJSON(root) : root;
}

static id restoreForCaller(id info, uintptr_t caller) {
    if (caller != coreBase + restoreReturn || !NSThread.isMainThread ||
        ![info isKindOfClass:NSDictionary.class] || !originalElapsed) return info;
    id elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    id rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    if (![elapsed isKindOfClass:NSNumber.class] || ![rate isKindOfClass:NSNumber.class]) return info;
    id lock = (__bridge id)*(void **)(coreBase + 0x53fca8);
    if (!lock) return info;
    double reportedAt;
    @synchronized (lock) {
        // A track/metadata change after the timer's snapshot must not borrow the
        // newer snapshot's clock. The core uses this same lock for these globals.
        if ((__bridge void *)info != *(void **)(coreBase + 0x53fcc8)) return info;
        memcpy(&reportedAt, (void *)(coreBase + 0x53fce8), sizeof(reportedAt));
    }
    double now = CFAbsoluteTimeGetCurrent();
    if (!isfinite(reportedAt) || reportedAt <= 0 || reportedAt > now ||
        !isfinite([elapsed doubleValue]) || !isfinite([rate doubleValue])) return info;
    // Reuse 0.51.0's own player-clock/seek/rate-aware computation, outside its lock.
    double current = originalElapsed(info, reportedAt, now);
    if (!isfinite(current) || current < 0) return info;
    NSMutableDictionary *updated = [info mutableCopy];
    updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(current);
    return [updated copy];
}

static const void *lyricsBytes(id self, SEL cmd) {
    (void)cmd;
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    const void *bytes = ((const void *(*)(id, SEL))objc_msgSend)(self, @selector(bytes));
    return bytesForCaller(self, bytes, caller);
}

static id lyricsJSON(id self, SEL cmd, NSData *data, NSJSONReadingOptions options, NSError **error) {
    (void)cmd;
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    id root = ((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))objc_msgSend)
        (self, @selector(JSONObjectWithData:options:error:), data, options, error);
    return jsonForCaller(root, caller);
}

static void lyricsRestore(id self, SEL cmd, NSDictionary *info) {
    (void)cmd;
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    id restored = restoreForCaller(info, caller);
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setNowPlayingInfo:), restored);
}

static BOOL verifiedImage(const struct mach_header_64 *header) {
    static const unsigned char uuid[] = {0x2a,0x5b,0x5c,0x1f,0xda,0xea,0x35,0xbe,0xba,0x16,0x86,0x61,0xa6,0xc6,0xf2,0x4e};
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->sizeofcmds > 0x10000 || header->ncmds > 256) return NO;
    const unsigned char *base = (const void *)header, *p = base + sizeof(*header);
    const unsigned char *end = p + header->sizeofcmds;
    BOOL identity = NO, text = NO, data = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end - p) < sizeof(struct load_command)) return NO;
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - p)) return NO;
        if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command))
            identity = memcmp(((const struct uuid_command *)lc)->uuid, uuid, sizeof(uuid)) == 0;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *s = (const void *)lc;
            if (!strncmp(s->segname, "__TEXT", sizeof(s->segname)) && s->vmaddr == 0 && s->vmsize == 0x480000 &&
                s->initprot == (VM_PROT_READ | VM_PROT_EXECUTE)) text = YES;
            if (!strncmp(s->segname, "__DATA", sizeof(s->segname)) && s->vmaddr == 0x4d8000 && s->vmsize == 0xb4000 &&
                s->initprot == (VM_PROT_READ | VM_PROT_WRITE)) data = YES;
        }
        p += lc->cmdsize;
    }
    if (!identity || !text || !data || p != end) return NO;
    // BL bytes; LDRB; CMP '{'. The rebased pointer must ONLY feed this one-byte read.
    static const unsigned char sniff[] = {0xcc,0xf8,0x02,0x94,0x08,0x00,0x40,0x39,0x1f,0xed,0x01,0x71};
    static const unsigned char json[] = {0xbb,0xf0,0x02,0x94};
    static const unsigned char restore[] = {0xb0,0x54,0x03,0x94};
    static const unsigned char helper[] = {0xff,0xc3,0x01,0xd1,0xeb,0x2b,0x01,0x6d,0xe9,0x23,0x02,0x6d,0xf8,0x5f,0x03,0xa9};
    return !memcmp(base + 0x257a30, sniff, sizeof(sniff)) &&
           !memcmp(base + 0x257a54, json, sizeof(json)) &&
           !memcmp(base + 0x24fcc0, restore, sizeof(restore)) &&
           !memcmp(base + 0x24ff38, helper, sizeof(helper));
}

static BOOL bindLyricsSelectors(const struct mach_header_64 *header) {
    if (!verifiedImage(header)) return NO;
    SEL old[] = {@selector(bytes), @selector(JSONObjectWithData:options:error:), @selector(setNowPlayingInfo:)};
    SEL replacement[] = {sel_registerName("sgp051_lyricsBytes"),
        sel_registerName("sgp051_lyricsJSONObjectWithData:options:error:"), sel_registerName("sgp051_lyricsSetNowPlayingInfo:")};
    Class targets[] = {NSObject.class, object_getClass(NSJSONSerialization.class), NSClassFromString(@"MPNowPlayingInfoCenter")};
    Method methods[] = {class_getInstanceMethod(NSData.class, old[0]),
        class_getInstanceMethod(targets[1], old[1]), class_getInstanceMethod(targets[2], old[2])};
    const char *types[] = {"^v", "@", "v"};
    const unsigned int counts[] = {2, 5, 3};
    uintptr_t base = (uintptr_t)header;
    for (unsigned int i = 0; i < 3; i++) {
        if (!targets[i] || !methods[i] || class_getInstanceMethod(targets[i], replacement[i]) ||
            !sel_isEqual(*(SEL *)(base + selectorOffsets[i]), old[i]) ||
            method_getNumberOfArguments(methods[i]) != counts[i]) return NO;
        char result[32] = {0};
        method_getReturnType(methods[i], result, sizeof(result));
        // NSData.bytes may encode its const qualifier as r^v.
        const char *arguments = i == 1 ? "@Q^" : (i == 2 ? "@" : "");
        for (unsigned int j = 0; arguments[j]; j++) {
            char argument[32] = {0};
            method_getArgumentType(methods[i], j + 2, argument, sizeof(argument));
            const char *type = argument;
            while (*type && strchr("rnNoORV", *type)) type++;
            if (*type != arguments[j]) return NO;
        }
        if (strcmp(result[0] == 'r' ? result + 1 : result, types[i])) return NO;
    }
    IMP implementations[] = {(IMP)lyricsBytes, (IMP)lyricsJSON, (IMP)lyricsRestore};
    for (unsigned int i = 0; i < 3; i++)
        if (!class_addMethod(targets[i], replacement[i], implementations[i], method_getTypeEncoding(methods[i]))) return NO;
    coreBase = base;
    originalElapsed = (double (*)(id, double, double))(base + 0x24ff38);
    // Aligned pointer stores only in the core's writable selector table. No code
    // patching, executable memory allocation or global Foundation swizzling.
    for (unsigned int i = 0; i < 3; i++)
        __atomic_store_n((SEL *)(base + selectorOffsets[i]), replacement[i], __ATOMIC_RELEASE);
    return YES;
}

#ifndef SG_LYRICS_REPAIR_TEST
__attribute__((constructor)) static void installLyricsRepairs(void) {
    @autoreleasepool {
        Method tick = class_getInstanceMethod(NSClassFromString(@"SGRKaraokeView"), sel_registerName("tick"));
        Dl_info image = {0};
        if (tick && dladdr((void *)method_getImplementation(tick), &image) &&
            bindLyricsSelectors(image.dli_fbase))
            NSLog(@"[spoti-perf] 0.51.0: guarded lyrics parsing and progress restoration installed");
    }
}
#endif
