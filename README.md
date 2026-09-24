<div align="center">
  <img src="./docs/src/assets/bb_logo.jpg" alt="BlinkBlox" width="640">

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
  the whole schema. Refused events go to a handler you provide, and nobody is kicked automatically.
- **Hostile input costs the attacker, not the server.** Every length is checked before the read and
  the allocation it pays for. A malformed event drops only itself.
- **Mismatched builds refuse each other.** A client and a server built from different schemas stop
  at startup instead of decoding one event as another.
- **Small on the wire.** Booleans and optional flags share a bitfield, and `boolean[]` packs eight
  to a byte. A length is sent relative to its range, and `CFrame<quat>` fits a rotation in 7 bytes.
  An unreliable event that cannot fit is refused at compile time.
- **Tooling.** The CLI has watch mode and `@profile` builds that keep debug remotes out of release.
  You also get TypeScript definitions and a Studio plugin with live diagnostics.

BlinkBlox is a maintained fork of [Blink](https://github.com/1Axen/blink). Upstream froze this line
of the compiler and began a rewrite. It left reported defects open, including an unbounded parse of
a hostile client buffer. This fork fixes them and continues from `v0.18.8`. See
[Migrating from Blink](https://xopoiii.github.io/BlinkBlox/guides/migrating-from-blink/).

## Install

```sh
rokit add XopoIII/BlinkBlox blinkblox   # CLI through Rokit
pesde add xopoiii/blinkblox             # or through pesde
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
