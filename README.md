# z-blink

z-blink is a hardened fork of [Blink](https://github.com/1Axen/blink), the IDL compiler for buffer-based Roblox networking. You describe events and functions in `.blink` contracts, and z-blink generates strictly typed client and server Luau modules that check the declared shapes at runtime on every send and every receive.

It is built for games where the client is hostile. A contract that could be abused is rejected at compile time, and every packet a client sends is bounded, validated and rate limited before a handler sees it.

z-blink tracks Blink's `rewrite` branch (1.0 pre-release), so it uses the same contract syntax.

## What it adds to Blink

- **A contract policy.** Strings and buffers need byte bounds, arrays and maps need caps, `unknown` and recursive types are not allowed, and nesting is limited. Clients can never send opaque buffers; a server event that sends one must be marked `@opaque`. Errors name the exact field, such as `ledger.data.entries[].value`.
- **Validation both ways.** Receivers reject NaN and infinite numbers, out-of-range values, malformed booleans, duplicate map keys and unknown variants. Senders reject integers that would wrap, fractional integers, unknown struct fields and sparse arrays. Send checks stay on in every build profile.
- **Transport limits.** Packet bytes, instances per packet, packets and records per second, records per packet, queue sizes and active function calls are all bounded per player. Violations drop the packet and call a handler you set. The client splits large bursts at record boundaries so normal traffic never trips a limit.
- **Deterministic output.** The same contract always compiles to the same files, and remote names come from the contract itself, so a client and a server built from different versions cannot talk to each other.
- **A project driver.** `blink.toml` lists every contract. `blink generate` compiles them all and publishes the outputs atomically with a recovery journal. `blink check` fails CI when an output is missing, out of date, edited by hand or orphaned.
- **Fixes for upstream bugs** in integer encoding, array writes, function invocations and map decoding.

Every rule, option and default is documented in [docs/hardened.md](docs/hardened.md).

## Install

With [Rokit](https://github.com/rojo-rbx/rokit):

```bash
rokit add zarchify/z-blink blink
```

The binary is called `blink`.

## Quick start

`remotes/network.blink`:

```blink
option client_output = "../src/shared/network/client"
option server_output = "../src/shared/network/server"

type item = struct {
	id: u16,
	name: string(..32),
}

event buy = { from: Client, type: Reliable, call: SingleSync, data: (id: u16, amount: u8) }
event inventory = { from: Server, type: Reliable, call: SingleSync, data: item[..64] }
```

`blink.toml`:

```toml
[[contract]]
entry = "remotes/network.blink"
```

Then run:

```bash
blink generate
```

On the server, decide what happens when a client breaks the rules:

```luau
local network = require(path.to.server)

network.set_violation_handler(function(player: Player, reason: string)
	player:Kick(reason)
end)
```

## Turning it off

`option strict = false` in a contract restores Blink's upstream behaviour for that contract. Use it to migrate an existing contract step by step.

## Credits

z-blink is built on [Blink](https://github.com/1Axen/blink) by [1Axen](https://github.com/1Axen) and its contributors, and keeps its MIT license.

Blink credits [Zap](https://zap.redblox.dev/) for the range and array syntax and [ArvidSilverlock](https://github.com/ArvidSilverlock) for the float16 implementation. Studio plugin auto completion icons are sourced from [Microsoft](https://github.com/microsoft/vscode-icons) under the [CC BY 4.0](https://github.com/microsoft/vscode-icons/blob/main/LICENSE) license.
