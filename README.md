<div align="center">
  <img src="./docs/src/assets/logo.png" alt="BlinkBlox logo" width="160">

# BlinkBlox

**An IDL compiler for Roblox buffer networking whose generated server is safe to point at the open internet.**

[![License](https://img.shields.io/github/license/XopoIII/BlinkBlox?style=flat-square&color=%23a350af)](LICENSE)
[![Release](https://img.shields.io/github/v/release/XopoIII/BlinkBlox?style=flat-square&color=%23a350af)](https://github.com/XopoIII/BlinkBlox/releases/latest)
[![Docs](https://img.shields.io/badge/docs-xopoiii.github.io-a350af?style=flat-square)](https://xopoiii.github.io/BlinkBlox/)

[Documentation](https://xopoiii.github.io/BlinkBlox/) ·
[Quick start](https://xopoiii.github.io/BlinkBlox/getting-started/quick-start/) ·
[Changelog](CHANGELOG.md)

</div>

You describe your events and functions, and what they carry, in a `.blink` schema. The compiler
generates a server module and a client module in plain Luau. They pack every call into one buffer
per frame, check everything a client sends before your code sees it, and keep working when a client
is hostile.

```blink
event Damage {
	From: Client,
	Type: Reliable,
	Call: SingleSync,
	Rate: 10,
	Data: struct { Target: Instance(Humanoid), Amount: u8(1..100) }
}
```

```luau
-- Server: the listener runs only after the rate limit has passed and Amount is 1..100.
Net.Damage.On(function(Player, Hit)
	Combat.Apply(Player, Hit.Target, Hit.Amount)
end)

-- Client
Net.Damage.Fire({ Target = Humanoid, Amount = 25 })
```

## Why BlinkBlox

- **Bounded inbound traffic.** Packet size, the number of events in a packet and the number of
  instance references are capped before anything is parsed. Each player also gets a byte budget.
- **Rate limits per player and per event.** Set `Rate` and `Burst` on an event, or a default for
  the whole schema, and `Concurrency` on a function to bound the calls still running. Refused events
  go to a handler you provide, and nobody is kicked automatically.
- **Hostile input costs the attacker, not the server.** Every length is checked before the read and
  the allocation it pays for. A malformed event ends its packet without throwing: the events
  before it are delivered, and the failure goes to a handler you provide.
- **A missing Instance costs one event, not the packet.** Under StreamingEnabled an Instance the
  sender had often is not there on arrival. That event alone is refused and reported; the rest of the
  packet is still read, at no cost to decoding when everything arrives.
- **Mistakes other libraries leave silent are named.** A second copy of the module in an Actor errors
  at require, a send made with `:` instead of `.` says so, a function's listener replaced by a second
  `.On` warns, a client left waiting for a server that never started says why, and a file of events
  imported twice warns at compile time. The client's queues are capped as the server's are.
- **Mismatched builds refuse each other.** A client and a server built from different schemas stop
  at startup instead of decoding one event as another.
- **The Roblox types games send.** `Vector2`, `UDim`, `UDim2`, `NumberRange`, `ColorSequence`,
  `TweenInfo`, and a Roblox enum's items as `Enum(Material)` -- sent by `Value`, never by list
  position, which can differ between client and server during an engine rollout.
- **Small on the wire.** Booleans, optional flags, enum values and tags share a bitfield, and
  `boolean[]` packs eight to a byte. A length is sent relative to its range, a short one in a single
  varint byte, `CFrame<quat>` fits a rotation in 7 bytes, and
  `u24`, `i24` and `f24` fill the gap between 16 and 32 bits, so `vector<f24>` is 9 bytes instead of
  12. A float with a step and a range is quantized: `f32<0.01>(-1..1)` is one byte. An unreliable event
  that cannot fit is refused at compile time.
- **Few remote calls.** A `FireAll` goes to every player in one `FireAllClients`, streams to
  everyone share one packet a frame, and `BatchUnreliable` gathers a frame's unreliable events the
  same way. A client cuts its batch to fit the server's limits, so an honest player is never refused,
  and sends at most 60 times a second, since every remote call costs about 11 bytes of its own.
- **An outbound budget.** Give each player a byte budget for what the server sends, and mark the
  events and streams that may wait with `Priority: Low`; nothing else is ever held back.
- **Tooling.** The CLI has watch mode and `@profile` builds that keep debug remotes out of release,
  `--check --json` reports every diagnostic as JSON for editors and AI assistants, and `--verify`
  fails a pre-commit hook or CI step when the committed modules no longer match the schema. The generated
  modules pass their own `--!strict`, and keep their types under the new type solver however many
  events the schema has. You also get TypeScript definitions and a Studio plugin with
  live diagnostics.

## Performance

Each tool fires 1000 events a frame from client to server. Blink is the original project BlinkBlox
forked from, at its last release, 0.18.9. The runs were made on 2026-09-28 on an Intel Core
i7-13700K: in Studio on BlinkBlox 0.41.2, on LuneBlox on 0.42.0.

In Studio, the numbers are the median frame rate and the milliseconds a frame's thousand fires took.
Warp's Fire only queues its value and encodes it later in the frame, where the bench cannot time it,
so only its frame rate is shown.

| Tool | 1000 booleans | 1000 booleans, each different | 100 entities | 100 entities, each different |
|---|---|---|---|---|
| Roblox remotes | 15 FPS, 26.0 ms | 15 FPS, 29.1 ms | 15 FPS, 72.7 ms | 15 FPS, 74.5 ms |
| **BlinkBlox** | **60 FPS**\*, 1.9 ms | **60 FPS**\*, 4.8 ms | **60 FPS**\*, 2.0 ms | **60 FPS**\*, 2.4 ms |
| Blink | **60 FPS**\*, 4.5 ms | **60 FPS**\*, 9.9 ms | 44 FPS, 2.8 ms | 45 FPS, 3.2 ms |
| zap | **60 FPS**\*, 12.2 ms | 46 FPS, 18.1 ms | 45 FPS, 7.4 ms | 44 FPS, 7.8 ms |
| ByteNet | 30 FPS, 17.5 ms | 23 FPS, 21.4 ms | 35 FPS, 15.8 ms | 34 FPS, 16.6 ms |
| Packet | 35 FPS, 27.3 ms | 28 FPS, 31.8 ms | 27 FPS, 19.2 ms | 27 FPS, 19.9 ms |
| QuickNet | **60 FPS**\*, 1.9 ms | **60 FPS**\*, 7.1 ms | 58 FPS, 6.2 ms | 57 FPS, 6.7 ms |
| Warp | **60 FPS**\* | 55 FPS | 33 FPS | 32 FPS |

\* Studio caps the frame rate at 60.

On [LuneBlox](https://github.com/XopoIII/LuneBlox), without Roblox -- the Luau version and flags
Roblox runs -- on an Intel Core i7-13700K with BlinkBlox 0.42.0, each figure the median of three
runs, every tool in a process of its own. "Send" is a frame's thousand fires and the flush into a
packet, interpreted, as most players' clients run it; "decode" is the server decoding them, natively
compiled, as a Roblox server runs it; bytes are one event before compression.

| Tool | 1000 booleans: send / decode | 100 entities: send / decode | Bytes, booleans / entities |
|---|---|---|---|
| **BlinkBlox** | **16.3** / **6.7 ms** | **12.1** / **3.6 ms** | **128** / **602** |
| Blink | 29.3 / 10.7 ms | 12.8 / 21.8 ms | 1003 / 603 |
| zap | 65.5 / 11.5 ms | 33.4 / 21.2 ms | 1003 / 603 |
| ByteNet | 54.2 / 51.0 ms | 42.7 / 42.5 ms | 1003 / 603 |
| Packet | 54.0 / 51.0 ms | 39.9 / 52.7 ms | 1003 / 603 |
| QuickNet | 16.8 / 7.5 ms | 21.7 / 11.4 ms | **128** / 603 |
| Warp | 38.5 / 11.5 ms | 65.7 / 26.9 ms | **128** / **602** |

A game also sends the other way. Send then decode, natively, medians of five runs; the broadcast
reaches fifty players, and the inputs go from one client to the server:

| Tool | 100 structs a frame to everyone, `FireAll` | 8 unreliable inputs a frame |
|---|---|---|
| **BlinkBlox** | **0.020 / 0.012 ms, 1 remote call** | 0.002 / 0.003 ms, 8 calls; **0.002 / 0.001 ms, 1 call** with [`BatchUnreliable`](https://xopoiii.github.io/BlinkBlox/language/options/#batchunreliable) |
| Blink | 0.711 / 0.026 ms, 50 calls | 0.002 / 0.003 ms, 8 calls |
| zap | 0.734 / 0.025 ms, 50 calls | 0.003 / 0.002 ms, 8 calls |
| ByteNet | 0.044 / 0.109 ms, 1 call | 0.003 / 0.008 ms, 1 call |
| Packet | 0.084 / 0.170 ms, 1 call | no unreliable channel |
| QuickNet | 0.306 / 0.034 ms, 50 calls | 0.002 / 0.003 ms, 1 call |
| Warp | 2.350 / 0.113 ms, 50 calls | 0.004 / 0.009 ms, 1 call |

A client receiving 100 events a frame spread over 128 declarations decodes them in 0.008 ms
natively and 0.020 ms interpreted: the event an index names is found by halving the range rather
than one comparison after another.

The methodology, the bandwidth, the random payloads, streams and the full percentiles are in
[Benchmarks](https://xopoiii.github.io/BlinkBlox/guides/benchmarks/) and
[`benchmark/Benchmarks.md`](benchmark/Benchmarks.md). What 0.42.0 changed is in
[What's new in 0.42](https://xopoiii.github.io/BlinkBlox/guides/whats-new/).

## Where it comes from

BlinkBlox is a maintained fork of [Blink](https://github.com/1Axen/blink). Upstream froze this line
of the compiler and began a rewrite. It left reported defects open, including an unbounded parse of
a hostile client buffer. This fork fixes them and continues from `v0.18.8`. See
[Migrating from Blink](https://xopoiii.github.io/BlinkBlox/guides/migrating-from-blink/).

## Install

```sh
rokit add XopoIII/BlinkBlox blinkblox             # CLI through Rokit
pesde add xopoiii/blinkblox --dev --target lune   # or through pesde
```

Binaries for every platform, and the Studio plugin (`blinkblox-plugin.rbxm`), are attached to each
[release](https://github.com/XopoIII/BlinkBlox/releases/latest). The plugin is also on the Creator
Store as **BlinkBlox Editor**. See [Installation](https://xopoiii.github.io/BlinkBlox/getting-started/installation/).

## Contributing

```sh
rokit install              # toolchain
sh scripts/run-tests.sh    # test suite
cd docs && npm install && npm run dev   # documentation site
```

`CLAUDE.md` describes the architecture and the gates that CI and the git hooks run.

## Credits

Originally written by [Axen](https://github.com/1Axen). This fork continues from v0.18.8 and remains
MIT licensed.

- [Zap](https://zap.redblox.dev/), for the range and array syntax.
- [ArvidSilverlock](https://github.com/ArvidSilverlock), for the float16 implementation.
- The Studio plugin's autocomplete icons come from [Microsoft](https://github.com/microsoft/vscode-icons),
  under the [CC BY 4.0](https://github.com/microsoft/vscode-icons/blob/main/LICENSE) license.
- <a href="https://www.flaticon.com/free-icons/speed" title="speed icons">Speed icons created by alkhalifi design - Flaticon</a>
