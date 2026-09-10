<div align="center">
  <img src="./docs/public/Logo.png" class="center">
</div>

[![License](https://img.shields.io/github/license/XopoIII/blink?style=flat-square&color=%23a350af)](LICENSE)
[![Release](https://img.shields.io/github/v/release/XopoIII/blink?style=flat-square&color=%23a350af)](https://github.com/XopoIII/blink/releases/latest)

An IDL compiler written in Luau for ROBLOX buffer networking.

You describe your events and the shape of their data in a `.blink` schema; the compiler generates
server, client and shared Luau modules that pack them into buffers, validate what arrives, and batch
what leaves.

# This fork

This is a maintained fork. Upstream stopped taking changes on this line of the compiler and moved to
a rewrite, leaving reported defects — including an unbounded parse of hostile client input — closed
as out of scope. This fork fixes them and continues from there.

**Hardened**

- **Inbound packets are bounded.** A client used to be able to send `buffer.create(1000000)` and make
  the server decode up to a million events inside one remote callback. Packet size, decoded-event
  count and instance references are now capped, an unrecognised event id stops the parse, and a
  truncated packet — which is *smaller* than a legitimate one, so no size limit catches it — is
  contained rather than raising out of the remote handler. Tunable per schema.
- **No more resurrected players.** A remote function whose listener yielded while its player left
  wrote that player back into the replication map, where nothing removed them again: the server then
  allocated a buffer and fired a remote at someone who had gone, every Heartbeat, forever. Fixed on
  all three write paths, with a second line of defence that heals a stale entry on the next frame.

**Fixed**

- Instance classes containing a digit (`Instance(Vector3Value)`, `Instance(Motor6D)`) now parse.
- Edit-mode stubs keep the shape of the real API, so Roblox stories no longer raise on `On` returning
  nil, on `Iter` returning nil, or on a missing `StepReplication`.
- The CLI works from scripts: the schema path is the first non-flag argument in any order, and a
  missing output directory is created rather than blocking on a prompt no one can answer.
- `TypesOutput` resolves against the output path rather than the schema's, so an absolute schema path
  no longer scatters the types module into the working directory.
- Documentation code blocks are readable in light mode.

**Added**

- `Predict` delivers an event to the listening side's own handlers without touching a remote — for
  tests, and for stories where remotes do not exist. It mirrors the receive path, queue included.
- Inbound limit options: `MaxPacketSize`, `MaxEventsPerPacket`, `MaxInstancesPerPacket`.

**Kept honest**

Zero lint warnings and zero type errors across the tree, enforced by CI and git hooks that run
formatting, linting, whole-project type-checking and the test suite. None of these gates existed
before: pull requests ran no checks at all, and the test suite could not run unattended because it
aborted on an interactive prompt.

# Performance

Blink aims to generate the most performant and bandwidth-efficient code for your specific experience.
Lower bandwidth usage translates directly into **lower ping\*** for players, and the generated
serialisers cost **less CPU** than a generalised networking library.

Benchmarks are available [here](./benchmark/Benchmarks.md).

*\* Compared to standard ROBLOX networking. Not guaranteed in every case, but it should never make
ping worse.*

# Security

Two things work against bad actors:

1. Data sent by clients is **validated** on the receiving side before it reaches game code, and the
   volume of that data is now **bounded** before any of it is parsed.
2. Compression makes traffic **considerably harder to snoop on** than plain remotes.

# Getting started

```sh
rokit add XopoIII/blink
```

Then head to the [documentation](https://xopoiii.github.io/blink/getting-started/1-installation).

# Credits

Originally written by [Axen](https://github.com/1Axen); this fork continues from v0.18.8 and remains
MIT licensed.

Credits to [Zap](https://zap.redblox.dev/) for the range and array syntax.
Credits to [ArvidSilverlock](https://github.com/ArvidSilverlock) for the float16 implementation.
Studio plugin auto completion icons are sourced from [Microsoft](https://github.com/microsoft/vscode-icons)
and are under the [CC BY 4.0](https://github.com/microsoft/vscode-icons/blob/main/LICENSE) license.
<a href="https://www.flaticon.com/free-icons/speed" title="speed icons">Speed icons created by alkhalifi design - Flaticon</a>
