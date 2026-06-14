//  FSControlServer.m

#import "FSControlServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <os/lock.h>
#import <math.h>

// Recursively replace non-finite numbers (NaN/Inf) with 0 — NSJSONSerialization
// throws an uncaught exception on them, which would crash the app. A model that
// hammers these endpoints must never be able to take the process down.
static id FSSanitizeJSON(id o) {
    if ([o isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[o count]];
        for (id x in o) [a addObject:FSSanitizeJSON(x)];
        return a;
    }
    if ([o isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[o count]];
        [o enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            (void)stop; d[k] = FSSanitizeJSON(v);
        }];
        return d;
    }
    if ([o isKindOfClass:[NSNumber class]]) {
        double v = [o doubleValue];
        if (!isfinite(v)) return @0;
    }
    return o ?: [NSNull null];
}

@implementation FSControlServer {
    int       _listenFD;
    uint16_t  _port;
    BOOL      _running;
    NSThread *_acceptThread;

    NSMutableDictionary<NSString *, FSToolHandler> *_tools;
    NSMutableDictionary<NSString *, NSString *>    *_toolDocs;
    NSMutableDictionary<NSString *, FSDataProvider>*_data;
    NSMutableDictionary<NSString *, NSString *>    *_dataDocs;
    FSDataProvider _telemetry;

    // log ring + SSE subscribers (fd set)
    os_unfair_lock _logLock;
    NSMutableArray<NSString *> *_logRing;
    NSMutableArray<NSNumber *> *_logSubs;   // socket fds streaming the log
}

- (instancetype)initWithPort:(uint16_t)port {
    if (!(self = [super init])) return nil;
    _listenFD = -1;
    _port = port ?: 7777;
    _tools = [NSMutableDictionary dictionary];
    _toolDocs = [NSMutableDictionary dictionary];
    _data = [NSMutableDictionary dictionary];
    _dataDocs = [NSMutableDictionary dictionary];
    _logLock = OS_UNFAIR_LOCK_INIT;
    _logRing = [NSMutableArray array];
    _logSubs = [NSMutableArray array];
    return self;
}

- (uint16_t)port { return _port; }
- (BOOL)running  { return _running; }
- (NSString *)baseURL {
    return [NSString stringWithFormat:@"http://127.0.0.1:%u", _port];
}

- (void)setPort:(uint16_t)port { if (port) _port = port; }

- (void)registerTool:(NSString *)name doc:(NSString *)doc handler:(FSToolHandler)h {
    _tools[name] = [h copy];
    _toolDocs[name] = doc ?: @"";
}
- (void)registerData:(NSString *)path doc:(NSString *)doc provider:(FSDataProvider)p {
    _data[path] = [p copy];
    _dataDocs[path] = doc ?: @"";
}
- (void)setTelemetryProvider:(FSDataProvider)p { _telemetry = [p copy]; }

// ---------------------------------------------------------------------------
#pragma mark - lifecycle

- (BOOL)startOnError:(NSString **)err {
    if (_running) return YES;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (err) *err = @"socket() failed"; return NO; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // 127.0.0.1 only

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        if (err) *err = [NSString stringWithFormat:@"port %u in use (%s)",
                         _port, strerror(errno)];
        close(fd); return NO;
    }
    if (listen(fd, 16) != 0) {
        if (err) *err = @"listen() failed"; close(fd); return NO;
    }

    _listenFD = fd;
    _running = YES;
    _acceptThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(_acceptLoop) object:nil];
    _acceptThread.name = @"flysim.mcp.accept";
    [_acceptThread start];
    [self log:[NSString stringWithFormat:@"[mcp] listening on 127.0.0.1:%u", _port]];
    return YES;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }
    // close any log stream subscribers
    os_unfair_lock_lock(&_logLock);
    for (NSNumber *n in _logSubs) close(n.intValue);
    [_logSubs removeAllObjects];
    os_unfair_lock_unlock(&_logLock);
    [self log:@"[mcp] stopped"];
}

- (void)_acceptLoop {
    while (_running) {
        struct sockaddr_in cli; socklen_t cl = sizeof(cli);
        int c = accept(_listenFD, (struct sockaddr *)&cli, &cl);
        if (c < 0) { if (_running) usleep(1000); continue; }
        int one = 1; setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        // one detached thread per connection (low-volume control traffic)
        NSThread *t = [[NSThread alloc] initWithTarget:self
                                              selector:@selector(_handleConn:)
                                                object:@(c)];
        [t start];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - request handling

static BOOL send_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf; size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, p + off, len - off, 0);
        if (n <= 0) return NO;
        off += (size_t)n;
    }
    return YES;
}

- (void)_handleConn:(NSNumber *)fdNum {
    @autoreleasepool {
        int fd = fdNum.intValue;

        // read headers (until \r\n\r\n), then body by Content-Length
        NSMutableData *acc = [NSMutableData data];
        char buf[8192];
        NSRange hdrEnd = NSMakeRange(NSNotFound, 0);
        NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        while (hdrEnd.location == NSNotFound) {
            ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) { close(fd); return; }
            [acc appendBytes:buf length:(NSUInteger)n];
            hdrEnd = [acc rangeOfData:sep options:0 range:NSMakeRange(0, acc.length)];
            if (acc.length > 1<<20) { close(fd); return; }   // 1 MB header cap
        }
        NSString *header = [[NSString alloc] initWithData:
            [acc subdataWithRange:NSMakeRange(0, hdrEnd.location)]
            encoding:NSUTF8StringEncoding];
        NSUInteger bodyStart = hdrEnd.location + sep.length;

        NSInteger contentLength = 0;
        for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                contentLength = [[line substringFromIndex:15]
                    stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]].integerValue;
            }
        }
        NSMutableData *body = [[acc subdataWithRange:
            NSMakeRange(bodyStart, acc.length - bodyStart)] mutableCopy];
        while ((NSInteger)body.length < contentLength) {
            ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) break;
            [body appendBytes:buf length:(NSUInteger)n];
        }

        // request line: METHOD PATH HTTP/1.1
        NSString *firstLine = [header componentsSeparatedByString:@"\r\n"].firstObject ?: @"";
        NSArray *parts = [firstLine componentsSeparatedByString:@" "];
        if (parts.count < 2) { [self _respond:fd code:400 text:@"bad request"]; return; }
        NSString *method = parts[0];
        NSString *rawPath = parts[1];

        // split path / query
        NSString *path = rawPath; NSMutableDictionary *query = [NSMutableDictionary dictionary];
        NSRange q = [rawPath rangeOfString:@"?"];
        if (q.location != NSNotFound) {
            path = [rawPath substringToIndex:q.location];
            for (NSString *kv in [[rawPath substringFromIndex:q.location+1]
                                  componentsSeparatedByString:@"&"]) {
                NSArray *pair = [kv componentsSeparatedByString:@"="];
                if (pair.count == 2) query[pair[0]] =
                    [pair[1] stringByRemovingPercentEncoding] ?: pair[1];
            }
        }

        [self _route:fd method:method path:path query:query body:body];
    }
}

- (void)_route:(int)fd method:(NSString *)method path:(NSString *)path
         query:(NSDictionary *)query body:(NSData *)body {

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/health"]) {
        [self _respondJSON:fd obj:@{@"ok":@YES, @"data":@"running"}]; return;
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/tools"]) {
        NSMutableArray *tools = [NSMutableArray array];
        for (NSString *n in [_toolDocs.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [tools addObject:@{@"name":n, @"doc":_toolDocs[n],
                               @"endpoint":[@"POST /tool/" stringByAppendingString:n]}];
        NSMutableArray *data = [NSMutableArray array];
        for (NSString *p in [_dataDocs.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [data addObject:@{@"path":p, @"doc":_dataDocs[p],
                              @"endpoint":[@"GET " stringByAppendingString:p]}];
        [self _respondJSON:fd obj:@{@"ok":@YES, @"data":@{
            @"tools":tools, @"data":data,
            @"streams":@[@"GET /stream?hz=N (telemetry SSE)",
                         @"GET /log/stream (log SSE)"]}}];
        return;
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/stream"]) {
        [self _telemetryStream:fd hz:(query[@"hz"] ? [query[@"hz"] doubleValue] : 30.0)];
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/log/stream"]) {
        [self _logStream:fd]; return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/log/tail"]) {
        NSInteger n = query[@"n"] ? [query[@"n"] integerValue] : 200;
        os_unfair_lock_lock(&_logLock);
        NSUInteger k = (NSUInteger)MAX(0, MIN(n, (NSInteger)_logRing.count));
        NSArray *lines = [_logRing subarrayWithRange:
            NSMakeRange(_logRing.count - k, k)];
        os_unfair_lock_unlock(&_logLock);
        [self _respondJSON:fd obj:@{@"ok":@YES, @"data":@{@"lines":lines,
                                     @"count":@(lines.count)}}];
        return;
    }

    // data providers (GET, read-only) — run on main for snapshot consistency
    if ([method isEqualToString:@"GET"] && _data[path]) {
        FSDataProvider p = _data[path];
        __block id result = nil; __block NSString *ex = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try { result = p(query); } @catch (NSException *x) { ex = x.reason; } });
        if (ex) [self _respondJSON:fd obj:@{@"ok":@NO, @"error":ex}];
        else    [self _respondJSON:fd obj:@{@"ok":@YES, @"data":result ?: [NSNull null]}];
        return;
    }

    // tools (POST) — run on main (may touch sim lifecycle + UI)
    if ([method isEqualToString:@"POST"] && [path hasPrefix:@"/tool/"]) {
        NSString *name = [path substringFromIndex:@"/tool/".length];
        FSToolHandler h = _tools[name];
        if (!h) { [self _respondJSON:fd obj:@{@"ok":@NO,
                    @"error":[@"unknown tool: " stringByAppendingString:name]}]; return; }
        NSDictionary *params = @{};
        if (body.length) {
            id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) params = j;
        }
        __block NSDictionary *result = nil; __block NSString *errStr = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try { NSString *e = nil; result = h(params, &e); errStr = e; }
            @catch (NSException *x) { errStr = x.reason ?: @"handler exception"; }
        });
        if (errStr) {
            [self log:[NSString stringWithFormat:@"[mcp] %@ -> FAIL: %@", name, errStr]];
            [self _respondJSON:fd obj:@{@"ok":@NO, @"error":errStr}];
        } else {
            [self log:[NSString stringWithFormat:@"[mcp] %@ -> ok", name]];
            [self _respondJSON:fd obj:@{@"ok":@YES, @"data":result ?: @{}}];
        }
        return;
    }

    [self _respond:fd code:404 text:@"not found"];
}

// ---------------------------------------------------------------------------
#pragma mark - SSE streams

- (void)_telemetryStream:(int)fd hz:(double)hz {
    if (hz <= 0) hz = 30; if (hz > 120) hz = 120;
    NSString *headers = @"HTTP/1.1 200 OK\r\n"
        "Content-Type: text/event-stream\r\n"
        "Cache-Control: no-cache\r\nConnection: keep-alive\r\n"
        "Access-Control-Allow-Origin: *\r\n\r\n";
    if (!send_all(fd, headers.UTF8String, strlen(headers.UTF8String))) { close(fd); return; }

    useconds_t interval = (useconds_t)(1e6 / hz);
    while (_running) {
        __block id frame = nil;
        FSDataProvider p = _telemetry;
        if (p) dispatch_sync(dispatch_get_main_queue(), ^{
            @try { frame = p(@{}); } @catch (NSException *x) { frame = nil; } });
        NSData *jd = nil;
        @try {
            if (frame) jd = [NSJSONSerialization dataWithJSONObject:FSSanitizeJSON(frame)
                                                           options:0 error:nil];
        } @catch (NSException *ex) { jd = nil; }
        if (!jd) jd = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *out = [@"data: " dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
        [out appendData:jd];
        [out appendData:[@"\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
        if (!send_all(fd, out.bytes, out.length)) break;
        usleep(interval);
    }
    close(fd);
}

- (void)_logStream:(int)fd {
    NSString *headers = @"HTTP/1.1 200 OK\r\n"
        "Content-Type: text/event-stream\r\n"
        "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    if (!send_all(fd, headers.UTF8String, strlen(headers.UTF8String))) { close(fd); return; }
    os_unfair_lock_lock(&_logLock);
    NSArray *backfill = [_logRing copy];
    [_logSubs addObject:@(fd)];
    os_unfair_lock_unlock(&_logLock);
    NSUInteger from = backfill.count > 200 ? backfill.count - 200 : 0;
    for (NSUInteger i = from; i < backfill.count; i++)
        [self _sseLine:fd text:backfill[i]];
    // the subscriber list keeps fd; writes happen in -log:. Park here until peer
    // closes (recv returns 0) so the thread/fd stay alive for fan-out.
    char tmp[64];
    while (_running) { ssize_t n = recv(fd, tmp, sizeof(tmp), 0); if (n <= 0) break; }
    os_unfair_lock_lock(&_logLock);
    [_logSubs removeObject:@(fd)];
    os_unfair_lock_unlock(&_logLock);
    close(fd);
}

- (void)_sseLine:(int)fd text:(NSString *)line {
    NSString *s = [NSString stringWithFormat:@"data: %@\n\n",
        [line stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]];
    send_all(fd, s.UTF8String, strlen(s.UTF8String));
}

- (void)log:(NSString *)line {
    os_unfair_lock_lock(&_logLock);
    NSString *stamped = [NSString stringWithFormat:@"%@ %@",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], line];
    [_logRing addObject:stamped];
    if (_logRing.count > 2000) [_logRing removeObjectsInRange:NSMakeRange(0, _logRing.count - 2000)];
    NSArray *subs = [_logSubs copy];
    os_unfair_lock_unlock(&_logLock);
    for (NSNumber *n in subs) [self _sseLine:n.intValue text:stamped];
}

// ---------------------------------------------------------------------------
#pragma mark - response helpers

- (void)_respond:(int)fd code:(int)code text:(NSString *)text {
    NSData *bodyData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *h = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\nContent-Type: text/plain\r\n"
        "Content-Length: %lu\r\nConnection: close\r\n\r\n",
        code, (unsigned long)bodyData.length];
    NSMutableData *out = [[h dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:bodyData];
    send_all(fd, out.bytes, out.length);
    close(fd);
}

- (void)_respondJSON:(int)fd obj:(id)obj {
    NSData *bodyData = nil;
    @try {
        bodyData = [NSJSONSerialization dataWithJSONObject:FSSanitizeJSON(obj)
            options:NSJSONWritingPrettyPrinted error:nil];
    } @catch (NSException *ex) {
        bodyData = [[NSString stringWithFormat:
            @"{\"ok\":false,\"error\":\"serialization: %@\"}", ex.reason]
            dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!bodyData) bodyData = [NSData data];
    NSString *h = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        "Content-Length: %lu\r\nConnection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n\r\n",
        (unsigned long)bodyData.length];
    NSMutableData *out = [[h dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:bodyData];
    send_all(fd, out.bytes, out.length);
    close(fd);
}

@end
