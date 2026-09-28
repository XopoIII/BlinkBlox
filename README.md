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
- **Mismatched builds refuse each other.** A client and a server built from different schemas stop
  at startup instead of decoding one event as another.
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
  modules pass their own `--!strict`. You also get TypeScript definitions and a Studio plugin with
  live diagnostics.

## Performance

Each tool fires 1000 events a frame from client to server. Blink is the original project BlinkBlox
forked from, at its last release, 0.18.9. The runs were made on an Apple M1: in Studio on BlinkBlox
0.36.2, on Lune on 0.40.0.

In Studio, the numbers are the median frame rate and the milliseconds a frame's thousand fires took.

| Payload | Roblox remotes | BlinkBlox | Blink | zap | ByteNet | Packet |
|---|---|---|---|---|---|---|
| 1000 booleans | 16 FPS, 29.2 ms | **60 FPS**\*, **4.2 ms** | 53 FPS, 8.4 ms | 35 FPS, 25.9 ms | 17 FPS, 41.3 ms | 15 FPS, 67.3 ms |
| 1000 booleans, each different | 16 FPS, 29.4 ms | **60 FPS**\*, **8.7 ms** | 36 FPS, 20.5 ms | 26 FPS, 34.4 ms | 15 FPS, 44.7 ms | 15 FPS, 77.5 ms |
| 100 entities | 16 FPS, 110.1 ms | **56 FPS**, **4.0 ms** | 22 FPS, 4.6 ms | 22 FPS, 20.5 ms | 18 FPS, 37.8 ms | 15 FPS, 50.3 ms |
| 100 entities, each different | 15 FPS, 115.6 ms | **51 FPS**, 5.1 ms | 22 FPS, **5.0 ms** | 22 FPS, 20.4 ms | 17 FPS, 38.3 ms | 15 FPS, 53.1 ms |

\* Studio caps the frame rate at 60.

On Lune, without Roblox, the numbers are the milliseconds a frame's thousand fires took
interpreted, as most players' clients run them, then the milliseconds the server took to decode
them natively, and the bytes one event takes before compression. Each is the median of three runs.

| Payload | BlinkBlox | Blink | zap | ByteNet | Packet |
|---|---|---|---|---|---|
| 1000 booleans | **37.7 / 4.2 ms, 128 B** | 68.8 / 11.9 ms, 1003 B | 174.0 / 13.3 ms, 1003 B | 126.6 / 122.4 ms, 1003 B | 124.3 / 116.7 ms, 1003 B |
| 100 entities | **33.5** / **12.2 ms**, **602 B** | **33.5** / 73.2 ms, 603 B | 83.9 / 74.1 ms, 603 B | 109.1 / 110.6 ms, 603 B | 100.6 / 162.5 ms, 603 B |

A game also sends the other way. Natively, on the same run, with fifty players:

| Scenario | BlinkBlox | Blink | zap | ByteNet | Packet |
|---|---|---|---|---|---|
| 100 structs a frame to everyone, `FireAll` | **0.037 ms, 1 remote call** | 2.10 ms, 50 calls | 2.46 ms, 50 calls | 0.099 ms, 1 call | 0.209 ms, 1 call |
| Decoding them on a client | **0.024 ms** | 0.081 ms | 0.077 ms | 0.268 ms | 0.452 ms |
| 8 unreliable inputs a frame, with [`BatchUnreliable`](https://xopoiii.github.io/BlinkBlox/language/options/#batchunreliable) | **0.004 ms, 1 remote call** | 0.009 ms, 8 calls | 0.006 ms, 8 calls | 0.006 ms, 1 call | none |

A client receiving 100 events a frame spread over 128 declarations decodes them in 0.053 ms
interpreted, from 0.086 ms in 0.40.0: the event an index names is found by halving the range rather than one comparison
after another.

The methodology, the bandwidth, the random payloads, streams and the full percentiles are in
[Benchmarks](https://xopoiii.github.io/BlinkBlox/guides/benchmarks/) and
[`benchmark/Benchmarks.md`](benchmark/Benchmarks.md). What 0.40.0 changed is in
[What's new in 0.40](https://xopoiii.github.io/BlinkBlox/guides/whats-new/).

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
