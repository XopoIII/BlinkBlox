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

Neither protects a live server from its own clients. That is the gap this fork fills: **the
generated server module should be safe to point at the open internet** — without giving up the
TypeScript output, the Studio plugin or the docs. Bandwidth parity is a second-order goal.

What that means concretely, as of 0.20.0: per-player per-event token buckets (`Rate` / `Burst`,
`option DefaultRate`, `option RequireRates`), compile-time size analysis that refuses unreliable
events which cannot fit and warns about the ones that might not, argument-type checks before a
client's remote arguments are read, a decode loop that stops when the player leaves, class checks on
both remotes, and a bitset that recycles invocation slots. 0.21.0 added the wire-format work that had
been held back — the shared bitfield, offset-encoded lengths, `OrderedUnreliable` — released
together, as one format change rather than three. 0.22.0 checks a decoded length before the read it
authorises, so a hostile length prefix buys neither a read nor an allocation.

0.23.0 is the devforum release: it works through the announcement thread, where several years of
reports had accumulated without answers. A schema signature on both modules, so a client and server
built from different schemas refuse each other instead of decoding one event as another. The client's
decode loop guarded the way the server's already was. `SyncValidation` saying that it discards the
rest of the packet, which it always did silently. A warning when a second `.On` displaces the first
on a `Single` event, and with it the fact that the displaced listener's disconnect stops working.
Map keys that can never be looked up refused at compile time. A timeout on invocations, which had
none and leaked a slot per lost call. `From` on functions, so the server can invoke a client. Named
type-pack elements. A thread pool for Async dispatch, kept only because it measured.

And the Studio plugin, which no release had touched: an editor that no longer rebuilds one frame per
line on every keystroke (39ms at line 800, measured, now constant), no longer paints the document
twice, no longer crashes past 2000 lines, and no longer deletes whatever else you kept in the output
folder.

0.24.0 came out of reviewing upstream's `v1.0.0-pre.8` and concluding there was nothing in it to
take — every one of its eight items is internal to `rewrite` or describes a bug this fork does not
have, usually because 0.18.x already did the right thing and `rewrite` had regressed away from it.
Auditing our own tree against those reports is what found the release.

All of it is one fault: every serialiser allocates its bytes up front and writes the event id before
it validates a field, and nothing undid that when validation threw. A reliable fire left a phantom
event in the batch, delivered to the listener as a value nobody sent. An unreliable fire never
reached its `Load(Previous)`, so the scratch buffer stayed installed and the next reliable flush sent
that instead of everything already queued. An invocation had already claimed its slot, and the caller
is parked — and the timeout armed — only after the write, so a throw in between stranded a slot with
nothing outstanding and nothing for the timeout to reclaim; thirty-two of those and every later
invocation fails for the session. And the return serialiser ran outside the pcall guarding the
listener, so a listener returning the wrong type answered nobody and the caller waited out the full
timeout. Upstream has the first of these open as #91 and the invocation half as #107, both unfixed
there.

Then the things that only turned up because we went looking: two files importing each other recursed
until the path outgrew the filesystem, a type naming itself reported "Unknown reference", and the
plugin's version had sat five minor releases behind the compiler's with nothing to notice, so
everything it generated went out mis-stamped.

0.24.2 came out of the next week of upstream's tracker, a batch of reports against `rewrite` pre.7.
Most described bugs this fork does not have; one did not, and it was the thesis again. An event
arriving with no listener bound is queued for the listener to come, and on the server a client
decided how long that queue got -- an event the game declared and never handled grew server memory
for as long as the client kept sending, with a warning per event past 256. The server's queue now
stops at 256 and says nothing, and an invocation past it is answered with a failure. Found while
checking: a range check written `x < Min` passes NaN, since NaN compares false both ways, so ranged
floats accepted NaN from clients. Upstream #102 is taken as well: `SetDecodeErrorHandler` tells the
game which player sent a packet that failed to decode and what event it claimed to be, and the
server stays silent without one. And invoking a player who had already left no longer waits out the
timeout.

0.25.0 came out of upstream's v0.18.9 and v1.0.0-pre.10. Their headline fix, NaN passing a float
range, this fork had shipped in 0.24.2. Next to it was one we had not: an open side of a float range
was filled with the exact-integer limit, 2^24 for `f32`, so `f32(0..)` refused 2e7 at runtime. The
vector magnitude check had never been run by any test, because Lune has no global `Vector3`. And
`@profile`, from upstream issue #110, taken because it serves the thesis: a debug remote marked
`@profile("dev")` is left out of every build that did not ask for it. Upstream defaults to `dev`; this
fork defaults to `release`, so forgetting the flag leaves the remote out rather than shipping it. An
excluded declaration is still parsed and registered, and a compiled one naming it is refused -- the
logic lives in `src/Modules/Attributes.luau`, since `src/Parser.luau` is at its size cap.

0.26.0 came out of a downstream game, and both halves are the thesis again. A channel the server
receives nothing on -- every event `From: Server`, or none unreliable -- has no index to branch on,
so the unknown-index guard was never emitted there and the loop read one byte at a time up to
`MaxEventsPerPacket` without ever failing or reporting. It now fails at the index read, once, through
`SetDecodeErrorHandler` with the event `nil`. The connection itself is kept: a remote with nothing
connected queues what is sent to it. And the rate-limit handler was spawned on every refusal while
the warning beside it was limited to once a second, so a flood of refused events became a flood of
handler threads. Both now share the once-a-second schedule, and the handler takes
`(Player, Event, Refused)`, with `Refused` the refusals that call stands for -- a fourth number per
rate-bucket entry.

0.27.0 came out of reading three neighbouring libraries -- ByteNet-Max, Warp and satset -- for
anything worth taking. Almost everything in them this fork already did, and did more carefully; their
bugs read like this fork's changelog run backwards (an allocation sized by a client's length prefix, an
invocation reply any client can forge, a rate limit enforced on the client). Two ideas were worth
having. Each server connection now charges a per-player token bucket before it decodes anything,
`option InboundBytesPerSecond` and `option InboundBurst`, a packet costing its size and never less than
128 bytes: every earlier limit was per packet or per event, so a client firing hundreds of well-formed
packets a frame passed all of them. The burst is a whole second, because after a hitch Roblox delivers
the backlog at once and a refused reliable packet takes every event in it along. Refusals share the
rate-limit handler with `Event` nil, which is why its type widened to `string?`. The other idea was
bandwidth: `boolean[]` is packed eight to a byte where every element had been one, and the capacity
guard had to learn that or it would have refused honest arrays -- `WIRE_VERSION` went to 2 because no
schema changed. `CFrame<quat>` encodes a rotation in 7 bytes instead of 12, opt-in because it is lossy;
writing it turned up that the docs had described CFrame's two components backwards since upstream.
Color3 wrapped HDR channels (2.0 arrived as 254/255), and each flush threw away the buffer it had just
grown -- keeping it measured 35 to 52 percent off the flush path, so it was kept.

0.28.0 renamed the fork to BlinkBlox and took its long files apart. The size cap came down from 900
lines to 500 with no exceptions, and splitting the parser, the generator, the prefabs and the plugin
editor put the copies of the same logic side by side, where the drift between them showed. Seven bugs
came out of it. A length prefix wrapped on send: with a lower bound of 0 and WriteValidations off --
the default -- a 300-byte value in `string(0..64)` went out with a length of 44 and all 300 bytes
behind it, and the receiver decoded the rest of the packet from the wrong offset; the same held for
buffers, arrays, unbounded lengths and a map's count, and the upper bound is now checked on send
whatever the options say. `Predict` on a reliable Many event dropped the event with no listener bound,
where the network queues it. A field, flag or tag named after a Luau keyword emitted a module that
did not load. The plugin editor never showed a warning -- the same parse set it and cleared it --
while printing each one to Output per keystroke. Smaller: a map's size diagnostic had nothing to
underline, the plugin's file search took its query as a pattern, and exact-bound errors read "to
equal to". The rename changes what the tools print and what the release artifacts are called, not
what a game depends on: the remotes, `_G._BLINK`, the plugin's `Blink` output folder and
`BLINK_CONFIGURATION_FILES`, and the `.blink` extension all keep their names, so builds either side
of the rename still talk to each other.

0.29.0 audited the runtime, once the split had left it in pieces small enough to read whole. The
worst of what turned up was a reply: a refused or failed invocation is answered in three bytes, and the
caller's reader took the success flag inside the payload's block, so it had stepped the payload's size
forward before it learnt there was none -- and a pcall around the read hid it, so everything batched
after a refusal was decoded from the wrong offset, in both directions. Calls were known by their id
alone. Ids went lowest-free first, so an earlier call's timer failed a later one from the same thread,
a late or cancelled reply resumed the next call, and a reply for one function resumed a caller of
another -- on the server, a client choosing the type of a value the game was promised. Ids now go round
the u8, each records its function, and a timer is cancelled with its call. A failed server fire left
its Instance in the player's batch, shifting every instance after it; a failed exported Write lost the
queued batch. A queued event lost its values after a trailing nil (`#{1, nil, nil, 4, nil}` is 1). A
listener that disconnected itself cost the next one the event. A Sync listener's error was reported as
the sender's decode failure. OrderedUnreliable accepted a stale packet across the wrap, starved a
player left out of the server's sends -- the server now counts per player -- and never freed what it
kept. The thesis again: a polled event's queue had no cap on the server, and a client could put a line
in the output or a call into the game's decode handler per packet; both are bounded now. The
serialisers: an optional array's holes closed up, f16 NaN decoded as -65600 and a subnormal lost its
carry, a float range refused its own bounds once narrowed on receipt, a pack element named `Length`
shadowed the string writer's local -- elements now travel under positional names inside the module --
and an enum past 256 values wrapped. Before it, the parser cleanup: repeated flags, values and variants
are refused, the TypeScript tag is quoted, and a trailing comma is accepted in every list. The wire
does not change.

0.30.0 is for the programs that read the compiler rather than the games that run its output. Talking
through editor support settled what not to build: no VS Code extension -- upstream never had one of its
own, the third-party ones know 0.18's syntax and guess at errors with regular expressions -- and no MCP
server, which the docs had promised, since an assistant that can run a command needs only the
command. What both wanted was the compiler's diagnostics in a form a program can read, so that is what
was built. `--check` runs the whole compile and writes nothing; `--json` prints one JSON document,
every diagnostic with its code, file, line, column and labels, and still a document when the failure
is a missing file. The released CLI had never handed an error to `Error.OnEmit` -- it printed and
exited -- so it does now whenever a handler is installed. Doing it turned up that diagnostics could not
say where they were: the schema was named by its bare file name, an import by the string that
imported it, and the lexer's one error by `input.blink` whatever the file was called. The docs'
TextMate grammar, the one thing kept of editor support, learnt the fork's syntax.

Still deferred, and deliberately: delta compression. It would require BlinkBlox to hold per-player state
on the server and a mirror on the client, and it fights `OrderedUnreliable` — a packet discarded as
stale takes its delta with it and the two caches diverge for good. That is a change of
responsibility, not an optimisation.

## Commands

| Task | Command |
|---|---|
| Install the toolchain | `rokit install` |
| Run the test suite | `sh scripts/run-tests.sh` |
| Re-record the output snapshots | `cd test && lune run Test --yes --update-goldens` |
| Type-check everything | `sh scripts/type-check.sh` |
| Lint | `selene src test plugin/src .lune` |
| Check type-checking modes | `sh scripts/check-strict.sh` |
| Check file sizes | `sh scripts/check-file-size.sh` |
| Check recorded versions agree | `sh scripts/check-versions.sh` |
| Check formatting | `stylua --check src test plugin .lune` |
| Format | `stylua src test plugin .lune` |
| Install git hooks | `lefthook install` |
| Compile a schema | `lune run init <path-to-.blink> -- --yes` (from `src/CLI`) |
| Check a schema, diagnostics as JSON | `lune run init <path-to-.blink> -- --check --json` (from `src/CLI`) |
| Build release binaries | `lune run build` |
| Docs, locally | `cd docs && npm install && npm run dev` |
| Build the docs (dead links fail it) | `cd docs && npm run build` |

The same gates run in CI (`.github/workflows/checks.yaml`) and before each commit (`lefthook.yml`).

**The tree is at zero.** No lint warnings, no type errors, no formatting drift. Keep it there — a
warning that is tolerated once stops being read.

The version is recorded in two files -- `build/.darklua.json` and `pesde.toml` -- and
`lune run bump <version>` writes both. `scripts/check-versions.sh` fails the build if they disagree.
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

`dibby-roblox` was the only consumer, and it is archived. Nothing outside this repository
post-processes the generated text any more, so **the emitted output shape is no longer frozen** —
the old warning about an anchor-matching patch script no longer applies.

What replaced it as the safety net is `test/Golden/`: a committed copy of every test schema's
generated modules. Any change to the emitter shows up there as a reviewable diff instead of as
silence. Regenerate with `lune run Test --yes --update-goldens` from `test/`, and read the diff
before committing it — that diff IS the review.
