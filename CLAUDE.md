# Blink — working notes

An IDL compiler for ROBLOX buffer networking, written in Luau. A schema (`.blink`) compiles to
server, client and shared Luau modules that serialise events into buffers.

A maintained fork, `XopoIII/blink`, forked from the upstream project at `v0.18.8` and released from
`0.19.0` onward. MIT licensed, and the upstream copyright stays in LICENSE — a fork is a derivative
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

Still deferred, and deliberately: delta compression. It would require blink to hold per-player state
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
| Check formatting | `stylua --check src test plugin .lune` |
| Format | `stylua src test plugin .lune` |
| Install git hooks | `lefthook install` |
| Compile a schema | `lune run init <path-to-.blink> -- --yes` (from `src/CLI`) |
| Build release binaries | `lune run build` |
| Docs, locally | `cd docs && npm install && npm run dev` |

The same gates run in CI (`.github/workflows/checks.yaml`) and before each commit (`lefthook.yml`).

**The tree is at zero.** No lint warnings, no type errors, no formatting drift. Keep it there — a
warning that is tolerated once stops being read.

Luau files are capped at 900 lines by `scripts/check-file-size.sh`. Four files are already past that
and are recorded at their current size: they may shrink, never grow. A recorded number makes every
addition to a long file a deliberate decision, where a plain exclusion list would just become
permission.

Every `.luau` file declares its type-checking mode on line 1, and `scripts/check-strict.sh` enforces
it. This is not cosmetic: Luau defaults to `nonstrict`, so a file without a directive is *unchecked*
rather than merely unannotated — the lexer, the generator, `Settings` and the diagnostics renderer
all ran that way while the type gate reported the tree as clean.

## Architecture

```
src/CLI/init.luau          argument parsing, help, watch mode
src/CLI/Utility/Compile    the pipeline: read -> parse -> generate -> write
src/Lexer.luau             tokeniser, pattern table + transformers
src/Parser.luau            recursive descent, semantic analysis, AST (types live here)
src/Generator/init.luau    the Luau emitter
src/Generator/Blocks.luau  code-emitting DSL (Block / Function / Connection)
src/Generator/Prefabs.luau read/write prefabs per primitive, plus range and type asserts
src/Templates/*.luau       runtime fragments spliced into generated output
plugin/src/                the Studio plugin: editor, syntax highlighting, autocomplete
```

There is no separate IR — the generator walks the AST directly.

### `src/` is dual-target, and the layout hides it

The same lexer, parser and error modules run **on Lune** for the CLI *and* **inside Roblox** for the
Studio plugin, which requires them through the `@compiler` alias in `.luaurc`. They branch at
runtime: `src/Parser.luau` tests `task ~= nil`, `src/Modules/Error.luau` tests `game ~= nil`.

Consequences worth remembering:

- `selene.toml` sets `std = "luau+roblox"` at the root; `plugin/selene.toml` sets `std = "roblox"`.
- `scripts/type-check.sh` analyses the compiler and the plugin as two separate contours.
- The compiler's range type is `Settings.NumberRange` (a plain `{ Min, Max }` table), deliberately
  **not** Roblox's `NumberRange` userdata, which does not exist on Lune. All three of Settings,
  Parser and Prefabs refer to the one definition.

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

## Downstream

`dibby-roblox` was the only consumer, and it is archived. Nothing outside this repository
post-processes the generated text any more, so **the emitted output shape is no longer frozen** —
the old warning about an anchor-matching patch script no longer applies.

What replaced it as the safety net is `test/Golden/`: a committed copy of every test schema's
generated modules. Any change to the emitter shows up there as a reviewable diff instead of as
silence. Regenerate with `lune run Test --yes --update-goldens` from `test/`, and read the diff
before committing it — that diff IS the review.
