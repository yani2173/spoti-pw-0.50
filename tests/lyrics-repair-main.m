#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
static NSString *const MPNowPlayingInfoPropertyElapsedPlaybackTime = @"elapsed";
static NSString *const MPNowPlayingInfoPropertyPlaybackRate = @"rate";
@interface MPNowPlayingInfoCenter : NSObject
@property(nonatomic, copy) NSDictionary *nowPlayingInfo;
@end
@implementation MPNowPlayingInfoCenter
@end
#define SG_LYRICS_REPAIR_TEST 1
#import "../performance/SGLyricsRepair.m"
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static int elapsedCalls;
static double elapsedResult;
static double elapsedFixture(id info, double reported, double now) {
    CHECK([info isKindOfClass:NSDictionary.class]);
    CHECK(now >= reported);
    elapsedCalls++;
    return elapsedResult;
}
static id decode(NSString *s) {
    return [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        NSData *binary = [NSData dataWithContentsOfFile:@(argv[1])];
        CHECK(binary.length > 0x520000);
        // Load original header/text/data, with zero-filled BSS, but do not execute
        // the iOS core on macOS. Objective-C selector relocation is simulated.
        void *fixture = calloc(1, 0x58c000);
        CHECK(fixture);
        memcpy(fixture, binary.bytes, 0x520000);
        CHECK(verifiedImage(fixture));
        ((unsigned char *)fixture)[0x257a34] ^= 1;
        CHECK(!verifiedImage(fixture));
        ((unsigned char *)fixture)[0x257a34] ^= 1;
        struct mach_header_64 *header = fixture;
        uint32_t cpu = header->cputype;
        header->cputype = CPU_TYPE_X86_64;
        CHECK(!verifiedImage(fixture));
        header->cputype = cpu;
        SEL originals[] = {@selector(bytes), @selector(JSONObjectWithData:options:error:), @selector(setNowPlayingInfo:)};
        for (int i = 0; i < 3; i++) *(SEL *)((uintptr_t)fixture + selectorOffsets[i]) = originals[i];
        *(SEL *)((uintptr_t)fixture + selectorOffsets[0]) = @selector(length);
        CHECK(!bindLyricsSelectors(fixture));
        *(SEL *)((uintptr_t)fixture + selectorOffsets[0]) = originals[0];
        IMP bytesBefore = class_getMethodImplementation(NSData.class, @selector(bytes));
        IMP jsonBefore = class_getMethodImplementation(object_getClass(NSJSONSerialization.class), originals[1]);
        CHECK(bindLyricsSelectors(fixture));
        CHECK(!bindLyricsSelectors(fixture)); // Idempotent: never wrap our own aliases.
        CHECK(bytesBefore == class_getMethodImplementation(NSData.class, originals[0]));
        CHECK(jsonBefore == class_getMethodImplementation(object_getClass(NSJSONSerialization.class), originals[1]));
        for (int i = 0; i < 3; i++) CHECK(!sel_isEqual(*(SEL *)(coreBase + selectorOffsets[i]), originals[i]));

        id good = decode(@"{\"lyrics\":{\"syncType\":\"LINE_SYNCED\",\"lines\":[{\"startTimeMs\":\"1200\",\"words\":\"hello\"},{\"startTimeMs\":2500,\"words\":\"world\"}]},\"other\":17}");
        CHECK(safeLyricsJSON(good) == good);
        CHECK(safeLyricsJSON(@[@1]) != nil);
        CHECK(safeLyricsJSON(nil) == nil);
        CHECK(safeLyricsJSON(@{ @"lyrics": NSNull.null }) != nil);
        for (id invalid in @[NSNull.null, @17, @"oops", @{ @"a": @1 }]) {
            id bad = @{ @"lyrics": @{ @"syncType": @"LINE_SYNCED", @"lines": invalid }, @"other": @17 };
            id repaired = jsonForCaller(bad, coreBase + jsonReturn);
            CHECK([repaired[@"lyrics"][@"lines"] isEqual:@[]]);
            CHECK([repaired[@"other"] isEqual:@17]);
            CHECK(jsonForCaller(bad, 0) == bad);
        }
        for (NSString *sync in @[@"LINE_SYNCED", @"UNSYNCED"]) {
            id first = @{ @"words": @"first", @"startTimeMs": @12 };
            id last = @{ @"words": @"last" }; // Missing timestamp remains legal.
            id bad = @{ @"lyrics": @{ @"syncType": sync, @"lines": @[
                first, @{ @"startTimeMs": NSNull.null }, @{ @"startTimeMs": @[] },
                @{ @"startTimeMs": @{} }, last] } };
            id fixed = safeLyricsJSON(bad);
            CHECK([fixed[@"lyrics"][@"lines"] isEqual:(@[first, last])]);
            CHECK([bad[@"lyrics"][@"lines"] count] == 5);
            for (NSDictionary *line in fixed[@"lyrics"][@"lines"]) (void)[line[@"startTimeMs"] integerValue];
        }
        id unrelated = @{ @"lyrics": @{ @"syncType": @"OTHER", @"lines": NSNull.null } };
        CHECK(safeLyricsJSON(unrelated) == unrelated);
        for (NSString *prefix in @[@"", @" ", @"\n", @"\r\n\t "]) {
            NSData *data = [[prefix stringByAppendingString:@"{\"lyrics\":{\"syncType\":\"UNSYNCED\",\"lines\":null}}"] dataUsingEncoding:NSUTF8StringEncoding];
            const void *original = data.bytes;
            CHECK(*(const char *)bytesForCaller(data, original, coreBase + bytesReturn) == '{');
            CHECK(bytesForCaller(data, original, 0) == original);
            CHECK(data.bytes == original);
            NSError *error = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            CHECK(parsed && !error);
            CHECK([jsonForCaller(parsed, coreBase + jsonReturn)[@"lyrics"][@"lines"] count] == 0);
            // Actual installed aliases forward unrecognized call sites unchanged.
            SEL byteAlias = *(SEL *)(coreBase + selectorOffsets[0]);
            CHECK(((const void *(*)(id, SEL))objc_msgSend)(data, byteAlias) == original);
            SEL jsonAlias = *(SEL *)(coreBase + selectorOffsets[1]);
            id forwarded = ((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))objc_msgSend)(NSJSONSerialization.class, jsonAlias, data, 0, &error);
            CHECK([forwarded isEqual:parsed]);
        }
        for (NSData *data in @[[NSData data], [@" \t\n" dataUsingEncoding:4], [@"\n\001abc" dataUsingEncoding:4], [@"[1]" dataUsingEncoding:4]])
            CHECK(bytesForCaller(data, data.bytes, coreBase + bytesReturn) == data.bytes);
        NSError *error = nil;
        SEL jsonAlias = *(SEL *)(coreBase + selectorOffsets[1]);
        CHECK(!((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))objc_msgSend)(NSJSONSerialization.class, jsonAlias, [@"{" dataUsingEncoding:4], 0, &error));
        CHECK(error != nil);

        originalElapsed = elapsedFixture;
        NSObject *lock = [NSObject new];
        *(void **)(coreBase + 0x53fca8) = (__bridge void *)lock;
        NSDictionary *info = @{ @"elapsed": @20, @"rate": @1, @"title": @"song", @"artist": @"artist" };
        *(void **)(coreBase + 0x53fcc8) = (__bridge void *)info;
        double reported = CFAbsoluteTimeGetCurrent() - 10;
        memcpy((void *)(coreBase + 0x53fce8), &reported, sizeof(reported));
        elapsedResult = 30;
        id restored = restoreForCaller(info, coreBase + restoreReturn);
        CHECK([restored[@"elapsed"] doubleValue] == 30 && elapsedCalls == 1);
        CHECK([restored[@"artist"] isEqual:info[@"artist"]] && [info[@"elapsed"] doubleValue] == 20);
        CHECK(restoreForCaller(info, 0) == info && elapsedCalls == 1);
        for (NSNumber *position in @[@5, @20, @42]) { // Seek backwards, pause, forward clock.
            elapsedResult = position.doubleValue;
            CHECK([restoreForCaller(info, coreBase + restoreReturn)[@"elapsed"] isEqual:position]);
        }
        elapsedResult = NAN;
        CHECK(restoreForCaller(info, coreBase + restoreReturn) == info);
        elapsedResult = -1;
        CHECK(restoreForCaller(info, coreBase + restoreReturn) == info);
        *(void **)(coreBase + 0x53fcc8) = NULL; // New track/snapshot: no mixing clocks.
        int calls = elapsedCalls;
        CHECK(restoreForCaller(info, coreBase + restoreReturn) == info && calls == elapsedCalls);
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter new];
        SEL restoreAlias = *(SEL *)(coreBase + selectorOffsets[2]);
        ((void (*)(id, SEL, id))objc_msgSend)(center, restoreAlias, info);
        CHECK([center.nowPlayingInfo isEqual:info]);
        free(fixture);
        puts("Lyrics parsing, scoped forwarding, original-image guards and restore regressions passed");
    }
    return 0;
}
