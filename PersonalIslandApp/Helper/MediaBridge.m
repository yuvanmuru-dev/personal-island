/*
 * Personal Island — media bridge (helper library).
 * Written for this personal project; no upstream file copied.
 *
 * Loaded only by MediaBridge.pl under Apple's /usr/bin/perl, which macOS
 * still lets read Now Playing; the app itself is blocked. Uses the private
 * MediaRemote framework (function signatures determined by disassembly on
 * macOS 27) to list every app with a Now Playing session and its track,
 * and to send play/pause, skip and seek to one of them.
 *
 * Protocol (one line each):
 *   out: {"players":[{"id","name","title","artist","album","duration",
 *         "elapsed","rate","timestamp"}...]}   whenever something changes
 *   out: {"error":"unavailable"}                MediaRemote missing
 *   in:  "toggle|next|previous <TAB> app-id"     or "seek <TAB> app-id <TAB> seconds"
 * It exits when standard input closes (the app quit or stopped it). Nothing
 * is stored or sent anywhere else.
 */

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (^ArrayBlock)(CFArrayRef);
typedef void (^DictBlock)(CFDictionaryRef);
typedef void (*GetClientsFn)(dispatch_queue_t, ArrayBlock);
typedef CFStringRef (*ClientStringFn)(const void *);
typedef const void *(*LocalOriginFn)(void);
typedef void (*InfoForClientFn)(const void *client, const void *origin, const void *option, dispatch_queue_t, DictBlock);
typedef void (*SendToClientFn)(unsigned int command, CFDictionaryRef options, const void *origin, const void *client,
                               const void *appOptions, dispatch_queue_t, const void *completion);
typedef void (*RegisterFn)(dispatch_queue_t);

static GetClientsFn getClients;
static ClientStringFn clientBundle, clientName;
static InfoForClientFn infoForClient;
static SendToClientFn sendToClient;
static const void *localOrigin;
static NSArray *currentClients;          // retained MediaRemote clients
static NSString *lastLine;
static BOOL refreshing, refreshAgain;

enum { CommandTogglePlayPause = 2, CommandNextTrack = 4, CommandPreviousTrack = 5, CommandSeek = 24 };

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return;
    lastLine = line;
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static id number(id value) { return [value isKindOfClass:NSNumber.class] ? value : NSNull.null; }
static id text(id value) { return [value isKindOfClass:NSString.class] ? value : NSNull.null; }

static void refresh(void) {
    if (refreshing) { refreshAgain = YES; return; }
    refreshing = YES;
    getClients(dispatch_get_main_queue(), ^(CFArrayRef list) {
        NSArray *clients = (__bridge NSArray *)list ?: @[];
        currentClients = [clients copy];
        NSMutableArray *players = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (id client in clients) {
            NSString *bundle = (__bridge NSString *)clientBundle((__bridge const void *)client);
            NSString *name = (__bridge NSString *)clientName((__bridge const void *)client);
            if (!bundle.length) continue;
            NSMutableDictionary *player = [@{ @"id": bundle, @"name": name ?: bundle } mutableCopy];
            [players addObject:player];
            dispatch_group_enter(group);
            infoForClient((__bridge const void *)client, localOrigin, NULL, dispatch_get_main_queue(), ^(CFDictionaryRef info) {
                NSDictionary *d = (__bridge NSDictionary *)info;
                player[@"title"] = text(d[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                player[@"artist"] = text(d[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                player[@"album"] = text(d[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                player[@"duration"] = number(d[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                player[@"elapsed"] = number(d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                player[@"rate"] = number(d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                id stamp = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                player[@"timestamp"] = [stamp isKindOfClass:NSDate.class] ? @([stamp timeIntervalSince1970]) : NSNull.null;
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            emit(@{ @"players": players });
            refreshing = NO;
            if (refreshAgain) { refreshAgain = NO; refresh(); }
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@"\t"];
    if (parts.count < 2) return;
    NSString *command = parts[0], *target = parts[1];
    id client = nil;
    for (id candidate in currentClients) {
        if ([(__bridge NSString *)clientBundle((__bridge const void *)candidate) isEqualToString:target]) { client = candidate; break; }
    }
    if (!client) return;
    unsigned int code;
    NSDictionary *options = nil;
    if ([command isEqualToString:@"toggle"]) code = CommandTogglePlayPause;
    else if ([command isEqualToString:@"next"]) code = CommandNextTrack;
    else if ([command isEqualToString:@"previous"]) code = CommandPreviousTrack;
    else if ([command isEqualToString:@"seek"] && parts.count >= 3) {
        double seconds = [parts[2] doubleValue];
        if (!isfinite(seconds) || seconds < 0) return;
        code = CommandSeek;
        options = @{ @"kMRMediaRemoteOptionPlaybackPosition": @(seconds) };
    } else return;
    sendToClient(code, (__bridge CFDictionaryRef)options, localOrigin, (__bridge const void *)client, NULL,
                 dispatch_get_main_queue(), NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ refresh(); });
}

__attribute__((constructor)) static void start(void) {
    // Only when started by Personal Island through MediaBridge.pl.
    const char *flag = getenv("PERSONAL_ISLAND_MEDIA_BRIDGE");
    if (!flag || strcmp(flag, "1") != 0) return;
    @autoreleasepool {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        getClients = mr ? dlsym(mr, "MRMediaRemoteGetNowPlayingClients") : NULL;
        clientBundle = mr ? dlsym(mr, "MRNowPlayingClientGetBundleIdentifier") : NULL;
        clientName = mr ? dlsym(mr, "MRNowPlayingClientGetDisplayName") : NULL;
        infoForClient = mr ? dlsym(mr, "MRMediaRemoteGetNowPlayingInfoForClient") : NULL;
        sendToClient = mr ? dlsym(mr, "MRMediaRemoteSendCommandToClient") : NULL;
        LocalOriginFn local = mr ? dlsym(mr, "MRMediaRemoteGetLocalOrigin") : NULL;
        RegisterFn registerForChanges = mr ? dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
        if (!getClients || !clientBundle || !clientName || !infoForClient || !sendToClient || !local || !registerForChanges) {
            emit(@{ @"error": @"unavailable" });
            exit(2);
        }
        localOrigin = local();
        registerForChanges(dispatch_get_main_queue());
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) { refresh(); }];
        }
        // A slow safety refresh, and exit if Personal Island has gone away.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{
            if (getppid() == 1) exit(0);
            refresh();
        });
        dispatch_resume(timer);
        // Commands from Personal Island; end of input means it stopped us.
        NSFileHandle *input = NSFileHandle.fileHandleWithStandardInput;
        __block NSMutableString *buffer = [NSMutableString string];
        input.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *data = handle.availableData;
            if (data.length == 0) exit(0);
            NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                [buffer appendString:chunk];
                NSRange newline;
                while ((newline = [buffer rangeOfString:@"\n"]).location != NSNotFound) {
                    NSString *line = [buffer substringToIndex:newline.location];
                    [buffer deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
                    if (buffer.length > 4096) [buffer setString:@""];
                    handleCommand(line);
                }
            });
        };
        CFRunLoopRun();
        exit(0);
    }
}
