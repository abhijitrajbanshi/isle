// MediaRemoteBridge — system-wide Now Playing for Isle.
//
// Since macOS 15.4 MediaRemote only answers Apple-signed clients. Isle runs
// this library inside /usr/bin/perl (an Apple platform binary) via
// Helpers/mediaremote.pl. It streams the Now Playing state to stdout as one
// JSON object per line and accepts commands on stdin:
//   toggle | play | pause | next | prev | seek <seconds>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (^MRInfoBlock)(CFDictionaryRef info);
typedef void (^MRPidBlock)(int pid);
typedef void (^MRPlayingBlock)(Boolean playing);

static void (*MRGetNowPlayingInfo)(dispatch_queue_t, MRInfoBlock);
static void (*MRGetNowPlayingPID)(dispatch_queue_t, MRPidBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, MRPlayingBlock);
static void (*MRRegisterForNotifications)(dispatch_queue_t);
static Boolean (*MRSendCommand)(int command, CFDictionaryRef options);
static void (*MRSetElapsedTime)(double seconds);

static NSString *lastArtworkKey = nil;
static BOOL refreshPending = NO;

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *bundleIDForPID(int pid) {
    if (pid <= 0) return nil;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app.bundleIdentifier;
}

static void refreshNow(void) {
    MRGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef ref) {
        NSDictionary *info = [(__bridge NSDictionary *)ref copy];
        MRGetNowPlayingPID(dispatch_get_main_queue(), ^(int pid) {
            MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                if (info.count == 0 || !info[@"kMRMediaRemoteNowPlayingInfoTitle"]) {
                    lastArtworkKey = nil;
                    emit(@{ @"type": @"info", @"empty": @YES });
                    return;
                }
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"type"] = @"info";
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
                out[@"playing"] = playing ? @YES : @NO; // Boolean is a C char: box as a real BOOL so JSON gets true/false
                NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = @((timestamp ?: [NSDate date]).timeIntervalSince1970);
                NSString *bundleID = bundleIDForPID(pid);
                if (bundleID) out[@"bundleID"] = bundleID;

                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:NSData.class] && artwork.length > 0) {
                    NSString *key = [NSString stringWithFormat:@"%@|%@|%lu",
                                     out[@"title"], out[@"album"], (unsigned long)artwork.length];
                    out[@"artworkKey"] = key;
                    if (![key isEqualToString:lastArtworkKey]) {
                        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        lastArtworkKey = key;
                    }
                } else {
                    lastArtworkKey = nil; // resend in full when it comes back
                }
                emit(out);
            });
        });
    });
}

// MediaRemote posts several notifications per change; coalesce them.
static void scheduleRefresh(void) {
    if (refreshPending) return;
    refreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshPending = NO;
        refreshNow();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    // MRMediaRemoteCommand values: play 0, pause 1, toggle 2, next 4, previous 5
    if ([verb isEqualToString:@"play"]) MRSendCommand(0, NULL);
    else if ([verb isEqualToString:@"pause"]) MRSendCommand(1, NULL);
    else if ([verb isEqualToString:@"toggle"]) MRSendCommand(2, NULL);
    else if ([verb isEqualToString:@"next"]) MRSendCommand(4, NULL);
    else if ([verb isEqualToString:@"prev"]) MRSendCommand(5, NULL);
    else if ([verb isEqualToString:@"seek"] && parts.count > 1) MRSetElapsedTime(parts[1].doubleValue);
    else if ([verb isEqualToString:@"refresh"]) {
        lastArtworkKey = nil;
        refreshNow();
        return;
    }
    scheduleRefresh();
}

static void listenToStdin(void) {
    static NSMutableString *buffer;
    buffer = [NSMutableString string];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char chunk[1024];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof(chunk));
        if (n <= 0) exit(0); // Isle quit: stdin closed
        [buffer appendString:[[NSString alloc] initWithBytes:chunk length:n encoding:NSUTF8StringEncoding] ?: @""];
        NSRange newline;
        while ((newline = [buffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [buffer substringToIndex:newline.location];
            [buffer deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length) handleCommand(line);
        }
    });
    dispatch_resume(source);
    // keep the source alive for the lifetime of the process
    static dispatch_source_t retained;
    retained = source;
}

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) return NO;
    MRGetNowPlayingInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    MRGetNowPlayingPID = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetIsPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRRegisterForNotifications = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSendCommand = dlsym(handle, "MRMediaRemoteSendCommand");
    MRSetElapsedTime = dlsym(handle, "MRMediaRemoteSetElapsedTime");
    return MRGetNowPlayingInfo && MRGetNowPlayingPID && MRGetIsPlaying
        && MRRegisterForNotifications && MRSendCommand && MRSetElapsedTime;
}

// Entry point, installed by perl as an XSUB. Never returns.
__attribute__((visibility("default")))
void isle_main(void *interpreter, void *cv) {
    @autoreleasepool {
        if (!loadMediaRemote()) {
            emit(@{ @"type": @"error", @"message": @"MediaRemote unavailable" });
            exit(2);
        }
        MRRegisterForNotifications(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                        usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }
        listenToStdin();
        emit(@{ @"type": @"ready" });
        refreshNow();
    }
    CFRunLoopRun();
    exit(0);
}
