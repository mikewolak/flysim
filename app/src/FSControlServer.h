// FlySim  ·  (c) 2026 mikewolak@gmail.com / Epromfoundry, Inc.  All rights reserved.
// Educational & academic research use only — commercial use prohibited.  See LICENSE.
//  FSControlServer.h — HTTP + JSON control plane for FlySim (the "MCP" surface).
//
//  Mirrors the Sluice SluiceControlServerCore design: a loopback TCP listener
//  exposing a block-based tool/data registry so an external agent (LLM bridge,
//  curl, CI) can drive every setting and read every output in real time.
//
//  Endpoints
//    GET  /health                  -> {"ok":true,"data":"running"}
//    GET  /tools                   -> {"ok":true,"data":{tools:[...],data:[...]}}
//    POST /tool/<name>   body=JSON  -> {"ok":true,"data":<result>} | {"ok":false,"error":..}
//    GET  /data/<name>  [?query]    -> {"ok":true,"data":<result>}   (realtime read)
//    GET  /stream?hz=N              -> SSE: a JSON telemetry frame N times/sec
//    GET  /log/tail?n=N             -> {"ok":true,"data":{lines:[...]}}
//    GET  /log/stream               -> SSE: every appended log line
//
//  Bind is 127.0.0.1 only (loopback) — never published on the network.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A tool mutates state. Returns a JSON-serializable dict, or sets *err and nil.
typedef NSDictionary * _Nullable (^FSToolHandler)(NSDictionary *params, NSString * _Nullable * _Nullable err);
// A data provider is a read-only query. Returns a JSON-serializable object.
typedef id _Nullable (^FSDataProvider)(NSDictionary *query);

@interface FSControlServer : NSObject

@property (readonly) BOOL running;
@property (readonly) uint16_t port;

- (instancetype)initWithPort:(uint16_t)port;

// Registry (call before or after start; thread-safe-enough for setup).
- (void)registerTool:(NSString *)name doc:(NSString *)doc handler:(FSToolHandler)h;
- (void)registerData:(NSString *)path doc:(NSString *)doc provider:(FSDataProvider)p;

// The /stream telemetry frame: sampled hz times/sec for SSE watchers.
- (void)setTelemetryProvider:(FSDataProvider)p;

// Lifecycle. start binds the port; returns NO + *err on failure (e.g. in use).
- (BOOL)startOnError:(NSString * _Nullable * _Nullable)err;
- (void)stop;
- (void)setPort:(uint16_t)port;     // takes effect on next start

- (void)log:(NSString *)line;       // append to ring buffer + fan out to SSE

@property (readonly) NSString *baseURL;     // e.g. http://127.0.0.1:7777

@end

NS_ASSUME_NONNULL_END
