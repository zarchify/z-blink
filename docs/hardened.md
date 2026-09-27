# Hardened Blink

This fork of Blink treats every client as hostile. A contract that could be abused is rejected when it is compiled, and every packet a client sends is bounded, validated and rate limited before a handler sees it.

Everything here is on by default. Upstream behaviour is one option away: see [Turning the policy off](#turning-the-policy-off).

## Contract policy

The compiler rejects a contract that breaks any of these rules. The error names the exact field, for example `e.data.entries[].value`.

| Rule | Example that passes |
|---|---|
| Strings and buffers need a byte bound | `string(..64)`, `buffer(..512)` |
| Arrays need a length cap | `u8[..32]` |
| Maps need an entry cap | `map {[u16]: item}(..64)` |
| `unknown` is not allowed | Declare the shape instead |
| Containers nest at most 8 deep | Arrays, maps, structs and tagged unions count |
| Recursive types are not allowed | A client could send unbounded depth |

The rules apply to every event, every function and every `@export` type. Types that nothing uses are not checked.

### Opaque data and `@opaque`

A buffer is opaque: the server cannot know what is inside it.

- Anything a client sends can never contain a buffer. This covers `from: Client`, `from: Both` and function arguments.
- A server event or function return value can contain a buffer only with `@opaque`:

```blink
@opaque
event replicate = { from: Server, type: Reliable, call: SingleSync, data: buffer(..16384) }
```

`@opaque` on a client event, on a type, or on a declaration that sends no buffer is an error.

## Validation

Receiving, always on:

- Numbers outside a declared range are rejected. In strict contracts, NaN and infinity are rejected in every float, vector and CFrame.
- A boolean byte must be 0 or 1.
- A map must not contain the same key twice, and must stay within its entry cap.
- Unknown union variants are rejected.

Sending, on in the `dev` and `test` profiles:

- An integer must be a whole number within its type's range, even without a declared range. Without this check, 300 sent as `u8` arrives as 44.
- A struct must be a table and must not have fields the contract does not declare.
- An array must not have gaps or keys other than 1 to n.
- In strict contracts, a float must be finite and must fit its type.

A send that fails validation is undone, so a bad call never corrupts the next packet.

## Transport limits

The server checks every client packet against per-player limits before it decodes anything.

| Option | Strict default | What it bounds |
|---|---|---|
| `max_packet_bytes` | 32768 | Bytes in one packet |
| `max_packet_instances` | 256 | Instances referenced by one packet |
| `max_packets_per_second` | 600 | Packets per player per second |
| `max_records_per_packet` | 256 | Events and calls in one packet |
| `max_records_per_second` | 3000 | Events and calls per player per second |
| `max_queue_size` | 1024 | Events waiting in a queue that no listener drains |
| `max_active_invocations` | 16 | Function calls one player can have running at once |

These defaults are conservative estimates, not measured Roblox limits. Tune them for your game:

```blink
option max_records_per_second = 6000
```

The client splits its outgoing packets at a record boundary before they would break a limit, so normal traffic never trips these limits. A single event too large for any packet errors on the client.

Server-to-client traffic has no limits, because the client trusts the server.

### Handling violations

When a limit is broken or a packet fails to decode, the rest of that packet is dropped and the violation handler runs:

```luau
local network = require(path.to.server)

network.set_violation_handler(function(player: Player, reason: string)
	warn(player, reason)
end)
```

Without a handler, violations are logged with `warn`.

An error thrown by your own event handler is not a violation. It is raised as a normal error with its traceback, even if the handler yielded first, so a bug in your code cannot get a player kicked.

## Remote names

The compiler derives remote names from the contract's source files. The same contract always compiles to the same output, and a client and a server built from different contracts cannot talk to each other.

Set `option remote_scope = "game_v2"` to force a new set of names without changing the contract.

## Project driver

List every contract in a `blink.toml` at the project root:

```toml
[[contract]]
entry = "remotes/network.blink"
profile = "release"
```

Output paths come from each contract's `client_output`, `server_output` and `types_output` options. The profile defaults to `dev`.

### `blink generate`

Compiles every contract, then publishes the outputs:

1. If any contract fails to compile, nothing is written.
2. Each output is written to a temporary file next to its target, and the plan is recorded in `blink.journal.toml`.
3. The temporary files replace their targets, and outputs no contract produces any more are removed.
4. `blink.manifest.toml` records the hash of every output, and the journal is deleted.

If a run is interrupted, the next `generate` finds the journal, cleans up, and publishes again. An orphaned output that was edited by hand is kept and reported rather than deleted.

Files that did not change are not rewritten, so file watchers only see real changes.

### `blink check`

Compiles in memory and compares the result with the files on disk. It exits with status 1 when an output is:

- missing
- out of date
- edited by hand
- no longer produced by any contract
- not recorded in the manifest

It also fails when a journal shows that the last `generate` was interrupted. Run it in CI.

Both commands take `--config <path>`, which defaults to `blink.toml`.

## Turning the policy off

`option strict = false` in the entry file restores upstream behaviour: no contract rules, no finite-number checks, and no transport limits unless you set a `max_*` option.

An imported file cannot set `strict = false` when the file importing it is strict. The `strict` option cannot carry attributes such as `@profile`, so every build of a contract shares one policy.
