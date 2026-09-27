# Zap vs z-blink benchmark

Compares [Zap](https://github.com/red-blox/zap) 0.6.29 with z-blink on the same contract. Each library's generated server and client run over the test suite's mock Roblox data model, so every event is encoded, sent, decoded and delivered to a handler.

## Run it

```bash
rokit install
```

```bash
lute run bench/run.luau
```

The runner generates Zap's output with the pinned `zap` binary and compiles z-blink in process. Contracts are in `bench/contracts/`.

## What is measured

| Scenario | Direction | Per flush |
|---|---|---|
| input: `(u16, vector)` | client to server | 64 events |
| chat: `string(..64)` with 48 bytes | client to server | 64 events |
| entities: 64 structs of `u32`, `vector`, `u16`, `boolean` | server to client | 1 event |

- **Encode** is the time spent in `Fire` calls.
- **Send + decode** is the time from the flush to the last handler call, including the mock remote.

Times are microseconds per event: the median and 90th percentile of 500 rounds after 50 warmup rounds. Each library runs with send checks on and off: Zap's `write_checks`, z-blink's `send_validation`.

z-blink's contract raises its rate limits so the benchmark measures serialization rather than the limiter dropping traffic. Every other z-blink check stays on, including receive validation and the per-record limit check.

## Results

Windows, lute 1.0.0, 2026-09-27. The numbers varied by about 5% between three runs.

### input: 64 small events per flush, client to server

| Library | Encode median | Encode p90 | Send + decode median | Send + decode p90 | Bytes per event |
|---|---|---|---|---|---|
| Zap (write_checks = true) | 0.26 | 0.29 | 0.24 | 0.27 | 15 |
| Zap (write_checks = false) | 0.26 | 0.28 | 0.24 | 0.27 | 15 |
| z-blink (send_validation = true) | 0.42 | 0.48 | 0.37 | 0.41 | 15 |
| z-blink (send_validation = false) | 0.37 | 0.43 | 0.37 | 0.42 | 15 |

### chat: 64 strings of 48 bytes per flush, client to server

| Library | Encode median | Encode p90 | Send + decode median | Send + decode p90 | Bytes per event |
|---|---|---|---|---|---|
| Zap (write_checks = true) | 0.21 | 0.29 | 0.19 | 0.25 | 50 |
| Zap (write_checks = false) | 0.20 | 0.23 | 0.19 | 0.25 | 50 |
| z-blink (send_validation = true) | 0.31 | 0.36 | 0.29 | 0.32 | 50 |
| z-blink (send_validation = false) | 0.29 | 0.36 | 0.30 | 0.34 | 50 |

### entities: 1 array of 64 structs per flush, server to client

| Library | Encode median | Encode p90 | Send + decode median | Send + decode p90 | Bytes per event |
|---|---|---|---|---|---|
| Zap (write_checks = true) | 20.80 | 27.30 | 27.40 | 39.70 | 1218 |
| Zap (write_checks = false) | 20.10 | 23.30 | 24.50 | 37.00 | 1218 |
| z-blink (send_validation = true) | 24.80 | 28.80 | 22.90 | 30.90 | 1218 |
| z-blink (send_validation = false) | 13.40 | 15.10 | 22.40 | 26.50 | 1218 |

## Reading the results

- **Bandwidth is identical.** Both libraries put the same number of bytes on the wire for every scenario.
- **Small events cost z-blink about 0.1 to 0.15 µs more each way.** On send, the extra cost is the rollback guard and packet-boundary check that run on every fire. On receive, it is the per-record limit check. At 64 events per frame, that is about 10 µs of a 16,667 µs frame.
- **Large payloads without send checks are faster in z-blink** than in Zap, for both encoding and decoding.
- **Send checks on 64 structs cost about 11 µs per batch in z-blink.** Most of it is the check for unknown struct fields. This is the cost `option send_validation = false` saves, and it is the main target for optimisation.

## Caveats

- **This is not Roblox.** lute runs the Luau interpreter without the native code generation Roblox uses for `--!native` scripts, so absolute numbers will differ in game. The relative comparison is the useful part.
- **The mock remote adds overhead to every send + decode figure.** It is the same for both libraries.
- **This compares work, not safety.** Zap does not validate what it receives and has no rate limits, so part of z-blink's extra cost buys protections Zap does not have.
