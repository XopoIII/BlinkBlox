# BlinkBlox — working notes

An IDL compiler for ROBLOX buffer networking, written in Luau. A schema (`.blink`) compiles to
server, client and shared Luau modules that serialise events into buffers.

A maintained fork, `XopoIII/BlinkBlox` -- called Blink, like upstream, until 0.28.0 -- forked from the
upstream project at `v0.18.8` and released from `0.19.0` onward. MIT licensed, and the upstream copyright stays in LICENSE — a fork is a derivative
work, so removing it is not an option.

## Everything here is written in English

Code, comments, identifiers, documentation, commit messages, pull request bodies, schema files,
agent and skill instructions, prompts, tool descriptions — **all of it, without exception**.

No other language appears anywhere in this repository. This is enforced, not merely agreed:
`scripts/check-english.sh` runs on every commit and rejects letters outside ASCII. Box-drawing
characters (`─ │ ┆ ╭ ╯`, used by the diagnostics renderer) and em dashes are punctuation, not
letters, and stay allowed.

Conversation with the user may happen in another language; nothing that lands in the repository does.

## Why the fork exists

Upstream `main` has been frozen since April 2026 — the author moved to a `rewrite` branch and stated
in issue #12 that the current version gets nothing but major bug fixes. Issue #45 (an unbounded
parse of a hostile client buffer) was explicitly declared out of scope.

Moving to `rewrite` is not an option, and this was settled rather than left open. That branch is
Blink v1.0.0-pre.7 — a from-scratch compiler on Lute with an HIR and an SSA-ish LIR, 583 commits
ahead of `main` and nothing merged back. What it costs is the whole surface people actually use: its
Studio plugin file is empty, it has no docs, no TypeScript emitter, no sync validation, no `Predict`,
no benchmarks. What it does not buy is the two things an IR is usually wanted for — its LIR
optimizer is an empty stub, `@bitpack` is parsed with zero consumers, and issue #45 is still open
there. **Adopting HIR/LIR is rejected; do not reopen it.** Individual algorithms from that branch are
worth porting (see `src/Templates/Base.luau`'s invocation slots) and are ported on their own.

So the fixes happen here.

## What this fork is for

Two other projects occupy the neighbouring ground, and neither covers this one:

- **red-blox/zap** is a bandwidth project — a shared bitfield, static size analysis, offset-encoded
  lengths. It has no rate limiting at all (its issue #219; the maintainer holds that throttling is
  the game's job) and no `pcall` around per-event decoding, so one malformed event discards the rest
  of that player's batch.
- **upstream `rewrite`** is a compiler-architecture project, described above.
- **QuickNet and Warp** are runtime-schema libraries, benchmarked beside BlinkBlox since 0.42.0.
  QuickNet rate-limits each event per player and bounds packets, but reports a decode failure only to
  the output and allocates whatever length a client names. Warp has no per-event limit and no
  protected decode.

None of them reports every refusal to the game and bounds every allocation before it happens. That is the gap this fork fills: **the
generated server module should be safe to point at the open internet** — without giving up the
TypeScript output, the Studio plugin or the docs. Bandwidth parity is a second-order goal, and speed
is held as a ratchet: a release is benchmarked against the one before it, and nothing may get slower.

`CHANGELOG.md` tells each release's story, with its measurements. What follows is only what a change
has to respect: the decisions already made, the numbers they rest on, and the invariants that are
easy to break without noticing.

## Settled decisions

- **HIR/LIR from upstream `rewrite`: rejected.** Individual algorithms are ported on their own.
- **Delta compression: deferred.** It needs per-player state on the server and a mirror on the
  client, and fights `OrderedUnreliable`: a packet discarded as stale takes its delta with it and the
  caches diverge for good. If reopened, the shape is keyframes plus deltas against the last keyframe,
  each naming it, so a receiver that missed one drops what follows until the next. A delta saves bits
  only when entropy-coded (DELUGE, arXiv 2609.19750), and an entropy coder in interpreted Luau costs
  more than it saves. netweave (2026, Roblox) built per-player deltas and found them reliable-only
  and open to resync amplification (5 to 601 bytes a frame). `Per: Player` streams are not deltas:
  each holds one current state that the next send replaces.
- **Measured and dropped:** constant offsets in array loops (slower natively), branchless boolean
  packing (no faster), packing array elements' bits into one run (dynamic bit addressing in every
  decode), a struct-of-arrays wire layout (no fewer builtin calls, one more pass).
- **`@profile` defaults to `release`**, so forgetting the flag leaves a debug remote out rather than
  shipping it. An excluded declaration is still parsed and registered, and a compiled one naming it
  is refused (`src/Modules/Attributes.luau`).
- **The 0.28 rename changed tools, not the wire.** The remotes, `_G._BLINK`, the plugin's `Blink`
  output folder, `BLINK_CONFIGURATION_FILES` and the `.blink` extension keep their names.
- **A wire change is one release.** `WIRE_VERSION` and the schema signature make modules from two
  builds refuse each other at startup; its CHANGELOG entry says "Recompile both modules".

## Numbers the code relies on

- Roblox delivers an unreliable buffer up to 994 bytes, 6 fewer per Instance beside it, both
  directions (`benchmark/Probe.luau`). `MaxUnreliableSize` defaults to 980 and counts 6 bytes per
  Instance; the figures live in `Grammar.DEFAULTS`, which both the analysis and the generator read.
- A remote call costs about 11 bytes beside its payload (Studio: 240 calls of 40 B/s went out as
  13.2 KB/s, 60 of 160 as 11.2). No loss, warning or ping rise from 60 to 480 calls a second on
  either remote, so Roblox enforces no call cap to stay under. Hence `option ClientFlushRate`, 60.
- The inbound budget charges a packet at least 128 bytes, and its burst is a whole second: after a
  hitch Roblox delivers the backlog at once, and a refused reliable packet takes its events along.
- Luau allows 200 locals a function. Each struct field is scoped (`src/Generator/Scope.luau`), or a
  struct of fifty CFrames fails to load.
- Roblox runs Luau 0.740 (September 2026) with its own fast flags, and so does LuneBlox, which every
  figure here is measured on. Among the flags is `DebugCodegenOptSize`, set in Studio as on clients,
  which skips block linearisation in native code: native timings on LuneBlox are what Roblox gets,
  slower on the thousand-event benches than Luau's defaults (`LUNE_ROBLOX_FFLAGS=0`) -- a tenth to a
  fifth on decode, over half on Entities' fire, on both the M1 and the i7. It is also why a channel's
  decoder is a function called once an event rather than a loop with the dispatch inside it: the long
  loop body compiled to slower native code (`src/Generator/init.luau`).
- Lune 0.10.5's Luau 0.709 left a whole module interpreted once one function was too large to
  compile, so past about 70 events its "native" rows were interpreted; figures published before
  LuneBlox carry that. Luau 0.740 leaves only the too-large function interpreted.
- Studio caps the frame rate at 60 and compiles LocalScripts natively where most clients do not, and
  Roblox's zstd squeezes a repeated payload to nothing: `benchmark/Runtime.luau` times on LuneBlox,
  native and interpreted, with random payloads.

## The toolchain runs on LuneBlox

`luneblox` (github.com/XopoIII/LuneBlox, pinned in `rokit.toml`) is Lune running the Luau version
Roblox runs, with Roblox's fast flags and Luau built at `-O3` -- upstream Lune 0.10.5 runs Luau 0.709,
where interpreted code measured over twice as slow on an Apple M1 and 15-35% slower on an i7-13700K.
Tests, benchmarks and release builds run on it;
`.lune/libs/runtime.luau` prints a warning when a test or benchmark runs anywhere else, the scripts
shell out through `runtime.command` so a run stays on one runtime, and a release build refuses.

The compiler's own source must still run on upstream Lune: pesde runs the bundled compiler on the
user's Lune, whatever its version. So `src/` uses no syntax or library newer than upstream Lune's Luau
-- `const`, for one, which Luau 0.740 parses and 0.709 does not; tests and benchmarks may. (`if local`
is not in Luau at all: it is an open RFC, #238.)

## Invariants that are easy to break

- **Range checks are written `not (x >= Min)`**, never `x < Min`: NaN compares false both ways. A
  float keeps both sides on receipt; a side an unmodified integer's read already meets, or a length's
  prefix already bounds, is left out (`Narrow.Readable`, `Asserts.EmitReceivedLength`).
- **A length is checked before the read or allocation it authorises**, and its upper bound is
  checked on send whatever `WriteValidations` says: a prefix is the smallest numeral for the span,
  and a value past it wraps. `Size.LengthPrefix` is the one rule for varint or fixed width.
- **A failed write leaves nothing behind.** Every serialiser allocates and writes the index before
  it validates, so a throw must undo the batch: lazily on the client (`Begin`, `Settle`), and a failed
  server fire must not leave its Instances. An invocation claims its slot only once the write is done.
- **Calls are matched by id and function**, ids go round the u8, and a timer is cancelled with its
  call; a reply for one function must never resume a caller of another.
- **Server-side queues are capped** (256 unheard events; polled queues too), and every report a
  client can trigger goes through the once-a-second schedule (`ReportDrop`, the rate-limit handler).
- **A channel's dispatch is a tree** of `Index < Middle` down to runs of eight
  (`src/Generator/Decode.luau`); every unclaimed index ends in the unknown-index error, and a channel
  this side hears nothing on fails at the index read. `test/EventIndices.luau` sends all 256 bytes.
- **A reliable `FireAll` goes to one broadcast batch** sent in one `FireAllClients`; `LoadPlayer`
  diverges a player who also has events of their own, so their order holds around it.
- **The client's batch is cut to the server's limits** (`MaxEventsPerPacket`, `MaxPacketSize`), so an
  honest player is never refused for `Events` or `Oversized`.
- **Features that cost code are spliced only when used**: the outbound budget
  (`src/Generator/Outbound.luau`), traffic counters, batches, streams, stamps. A schema without them
  compiles to what it always did, and the goldens show it.
- **Names the module reserves** are checked in the casing in force (`src/Modules/ModuleNames.luau`),
  and the runtime's own type aliases are `BLINK_*`, so a schema type cannot redefine them.

## Tests worth knowing

`test/Properties.luau` draws every exported type of `Test.blink` (`test/Generate.luau`) into a build
with `WriteValidations` and one without, judged by `test/Oracle.luau`, which reads the schema and never
the generated code; `BLINKBLOX_SEED` replays or varies the draws. `test/HalfFloats.luau` and
`test/Floats24.luau` check every pattern against independent decoders. `test/Composition.luau` checks
events side by side in one packet. `test/Isolated.luau` builds a server and client from a spec's own
schema on remotes nothing else shares. Each of these fails when the bug it is about is put back.

## Commands

| Task | Command |
|---|---|
| Install the toolchain | `rokit install` |
| Run the test suite | `sh scripts/run-tests.sh` |
| Re-record the output snapshots | `cd test && luneblox run Test --yes --update-goldens` |
| Replay or vary the property draws | `cd test && BLINKBLOX_SEED=<n> luneblox run Test --yes` |
| Type-check everything | `sh scripts/type-check.sh` |
| Lint | `selene src test plugin/src .lune` |
| Check type-checking modes | `sh scripts/check-strict.sh` |
| Check file sizes | `sh scripts/check-file-size.sh` |
| Check recorded versions agree | `sh scripts/check-versions.sh` |
| Check formatting | `stylua --check src test plugin .lune` |
| Format | `stylua src test plugin .lune` |
| Install git hooks | `lefthook install` |
| Compile a schema | `luneblox run init <path-to-.blink> -- --yes` (from `src/CLI`) |
| Check a schema, diagnostics as JSON | `luneblox run init <path-to-.blink> -- --check --json` (from `src/CLI`) |
| Build release binaries | `luneblox run build` |
| Time the generated modules | `luneblox run Runtime` (from `benchmark`) |
| Time the compiler | `luneblox run Performance` (from `benchmark`) |
| Measure the unreliable payload limit in Studio | `luneblox run Probe` (from `benchmark`) |
| Docs, locally | `cd docs && npm install && npm run dev` |
| Build the docs (dead links fail it) | `cd docs && npm run build` |

The same gates run in CI (`.github/workflows/checks.yaml`) and before each commit (`lefthook.yml`).

**The tree is at zero.** No lint warnings, no type errors, no formatting drift. Keep it there — a
warning that is tolerated once stops being read.

The version is recorded in two files -- `build/.darklua.json` and `pesde.toml` -- and
`luneblox run bump <version>` writes both. `scripts/check-versions.sh` fails the build if they disagree.
The docs print it as well, as the rokit pin `XopoIII/BlinkBlox@<version>` and as the CLI's banner on
a line of its own; they sat at 0.33.0 through three releases, so `bump` now rewrites them too
(`.lune/libs/docs_version.luau`) and `check-versions.sh` fails on a stale one.
The plugin used to have a third copy in `plugin/.darklua.json`, which sat five minor releases behind
the compiler's, so everything the Studio plugin generated went out stamped with a version the compiler had
not been for a year. The plugin now bundles with `build/.darklua.json` like the CLI, and that file is
gone. Never edit the version by hand.

Luau files are capped at 500 lines by `scripts/check-file-size.sh`, with no exceptions. The cap was
900, with three files past it on a recorded-size ratchet; it came down to 500 once the long files
turned out to hold the same logic in several copies, and every one of them was split -- the parser
into `src/Parser/`, the generator into `Event`, `Function`, `Generators` and `Prefabs/`, the plugin
editor into `Completion`, `Spans`, `Gutter` and the rest. A file that reaches the cap is split the
same way, not exempted.

Every `.luau` file declares its type-checking mode on line 1, and `scripts/check-strict.sh` enforces
it. This is not cosmetic: Luau defaults to `nonstrict`, so a file without a directive is *unchecked*
rather than merely unannotated — the lexer, the generator, `Settings` and the diagnostics renderer
all ran that way while the type gate reported the tree as clean.

## Architecture

```
src/CLI/init.luau          argument parsing, help, watch mode
src/CLI/Utility/Compile    the pipeline: read -> parse -> generate -> write
src/Lexer.luau             tokeniser, pattern table + transformers
src/AST.luau               the AST's node types, re-exported by Parser
src/Parser/                recursive descent and semantic analysis, one class across files:
                           Class.luau declares the state and every method, the rest add them
src/Generator/init.luau    the Luau emitter: assembles one module from the parts below
src/Generator/State.luau   everything one generation run builds up, shared by the files here
src/Generator/Generators   Luau types and serialisers for declarations, and the declaration walk
src/Generator/Event.luau   one `event`; Function.luau one `function`; Decode.luau their guards
src/Generator/Stream.luau  what a `Stream` event adds; Send.luau the server's sends to one and to many
src/Generator/Stamp.luau   what a `Stamp` adds: the client's stamped Fire, the server's clamp
src/Generator/Outbound.luau the per-player outbound budget and what `Priority: Low` leaves out
src/Generator/Blocks.luau  code-emitting DSL (Block / Function / Connection)
src/Generator/Prefabs/     read/write prefabs per primitive, plus range and type asserts
src/Templates/*.luau       runtime fragments spliced into generated output
plugin/src/                the Studio plugin: editor, syntax highlighting, autocomplete
```

There is no separate IR — the generator walks the AST directly.

### `src/` is dual-target, and the layout hides it

The same lexer, parser and error modules run **on Lune** for the CLI *and* **inside Roblox** for the
Studio plugin, which requires them through the `@compiler` alias in `.luaurc`. They branch at
runtime: `src/Parser/Document.luau` tests `task ~= nil`, `src/Modules/Error.luau` tests `game ~= nil`.

Consequences worth remembering:

- `selene.toml` sets `std = "luau+roblox"` at the root; `plugin/selene.toml` sets `std = "roblox"`.
- `scripts/type-check.sh` analyses the compiler and the plugin as two separate contours.
- The compiler's range type is `Settings.NumberRange` (a plain `{ Min, Max }` table), deliberately
  **not** Roblox's `NumberRange` userdata, which does not exist on Lune. Settings, AST, Parser and
  Prefabs all refer to the one definition, and `Settings.NumberRange.new` is its one constructor.

### Things that look wrong and are not

- **`src/Templates/*.luau` do not stand alone.** They are concatenated into generated output and
  reference identifiers that exist only after splicing (`RecieveBuffer`, `PlayersMap`, `Read`).
  Excluded from lint; never "fix" an undefined variable there.
- **`_G` is the build-constant channel.** `build/.darklua.json` declares `inject_global_value` for
  `_G.VERSION` and `_G.RELEASE`, so darklua replaces them with literals when bundling a release.
  Reading them through `_G` is what lets an unbundled run fall back to debug behaviour.
- **`Token.Value` is typed `string`, but `true`/`false` arrive as real booleans.** `Parser.Options`
  depends on that when storing a boolean option. The widening is confined to `TokenTransformer` and
  one cast in `Lexer.GetNextToken`.
- **A parser method is declared twice.** Its signature goes in `Methods` in `src/Parser/Class.luau`,
  its body in whichever file of `src/Parser/` it belongs to. The methods call each other through
  `self` across files, and the declaration is what lets the type checker see them there; a body
  with no declaration fails the type gate, and one that disagrees with it does too.
- **`Blocks.Emittable` is `string | number` on purpose.** Callers pass identifiers *and* numeric
  literals into the generated text; both interpolate identically.

### The prompt trap

`stdio.prompt` does not degrade when stdin is not a TTY — it throws `IO error: not a terminal`, and
under some runners simply blocks with nothing printed. Any prompt reached from a script, a git hook
or CI must therefore be guarded.

Both callers are fixed: the CLI creates a missing output directory instead of asking when no
terminal is attached, and the test runner compiles by default. `--yes` still forces it explicitly,
and flag order no longer matters — the config path is the first non-flag argument.

Keep this in mind before adding any new prompt.

## Documentation

`docs/` is an Astro Starlight site, deployed to GitHub Pages from main by `.github/workflows/docs.yml`
and built on every pull request by `checks.yaml`. It replaced Nextra 2 in 0.29.x; the old page URLs
redirect (see `redirects` in `docs/astro.config.mjs`). Pages are `docs/src/content/docs/**.mdx`,
grouped Getting Started / Language / Guides / Reference, and the sidebar order is written out in
the config.

- **Every ```` ```blink ```` block is compiled by `test/DocExamples.luau`**, README included, and both
  generated modules must load as Luau. A fence opts out with `fragment` (not a whole schema) or
  inverts with `error` (must be refused). That test exists because the old docs carried examples the
  parser had never accepted.
- Internal links are absolute and carry the base, `/BlinkBlox/...`; `starlight-links-validator`
  fails the build on a dead link or anchor.
- The Studio plugin is shown with HTML mockups in `docs/src/components/plugin/`, not screenshots:
  its colours come from `plugin/src/Editor/Theme.luau` and the `.rbxmx` layouts, so a plugin UI
  change should update them.
- `CHANGELOG.md` at the root is rendered as the site's Changelog page; add each release there.
- The site publishes `llms.txt` / `llms-full.txt` for AI assistants (`starlight-llms-txt`).

## Downstream

BlinkBlox is a standalone project for any Roblox game, and nothing in this repository names a
particular one: the CHANGELOG, the docs and the code speak of "a game". Games strike and ban on what
reaches `SetPacketDropHandler`, the rate-limit and the decode-error handlers, so a change to a
handler's signature, a `Reason`, or which refusals reach which handler is a change every such game
feels; say so in the CHANGELOG, under the release's "Upgrading" heading.

Nothing outside this repository post-processes the generated text, so **the emitted output shape is
not frozen** — the old warning about an anchor-matching patch script no longer applies.

What replaced it as the safety net is `test/Golden/`: a committed copy of every test schema's
generated modules. Any change to the emitter shows up there as a reviewable diff instead of as
silence. Regenerate with `luneblox run Test --yes --update-goldens` from `test/`, and read the diff
before committing it — that diff IS the review.
