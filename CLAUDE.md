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

Moving to `rewrite` is not an option: its Studio plugin is unported, it has no documentation, and it
still lacks TypeScript output, sync validation, bit packing and rate limiting.

So the fixes happen here.

## Commands

| Task | Command |
|---|---|
| Install the toolchain | `rokit install` |
| Run the test suite | `sh scripts/run-tests.sh` |
| Type-check everything | `sh scripts/type-check.sh` |
| Lint | `selene src test plugin/src .lune` |
| Check formatting | `stylua --check src test plugin .lune` |
| Format | `stylua src test plugin .lune` |
| Install git hooks | `lefthook install` |
| Compile a schema | `lune run init <path-to-.blink> -- --yes` (from `src/CLI`) |
| Build release binaries | `lune run build` |
| Docs, locally | `cd docs && npm install && npm run dev` |

The same gates run in CI (`.github/workflows/checks.yaml`) and before each commit (`lefthook.yml`).

**The tree is at zero.** No lint warnings, no type errors, no formatting drift. Keep it there — a
warning that is tolerated once stops being read.

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

`dibby-roblox` consumes this compiler (schema at `colony/net/Colony.blink`) and, while it still pins
`1axen/blink@0.18.8`, post-processes the generated server module with `scripts/patch-net-guard.sh` to
close the unbounded-parse hole by hand.

**As of 0.19.0 that patch is redundant** — the same guard is generated, plus a stop on unrecognised
event ids that the patch never had. Moving that repository to `XopoIII/blink@0.19.0` means it can
delete `patch-net-guard.sh` and drop the guard step from `scripts/net-build.sh`; rate limiting stays
in its own `Inbound.accept`, which needs per-player state over time.

The patch matches anchors in the emitted text, so **while it is still in use, changing the
generator's output shape breaks that build**. Check any generator change by regenerating that schema
and diffing against its committed output.
