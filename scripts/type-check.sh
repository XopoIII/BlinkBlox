#!/usr/bin/env sh
# Full Luau type-check. Run by hand with:  sh scripts/type-check.sh
#
# THREE CONTOURS, AND THE SPLIT IS THE WHOLE POINT. This repository is not one target:
#
#   src/     the compiler — runs on Lune (the CLI), but ALSO inside Roblox, because the Studio
#            plugin requires the lexer, parser and error modules through the `@compiler` alias.
#            Those modules branch at runtime (`task ~= nil`, `game ~= nil`), so they are analysed
#            with the Roblox type defs present even though Lune is the primary host.
#   plugin/  Roblox only, and it needs a Rojo sourcemap to resolve requires across the DataModel.
#   test/Golden  what the compiler emits: strict modules that run in a game, checked as one would.
#
# `globalTypes.d.luau` is the Roblox API dump. It is downloaded once and git-ignored, so runs after
# the first are offline.
set -e

# Rokit installs the CLIs under ~/.rokit/bin; make them reachable when this runs from a git hook
# launched by a GUI client that does not source the login shell.
export PATH="$HOME/.rokit/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for arg in "$@"; do
	echo "type-check: unknown argument '$arg' (it takes none — both contours are always checked)" >&2
	exit 2
done

if [ ! -f globalTypes.d.luau ]; then
	echo "type-check: fetching Roblox global type defs (one-time)…"
	curl -sSL -o globalTypes.d.luau \
		"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
fi

# Lune's own type definitions, which `.luaurc` aliases as `@lune`. They live in the user's home
# directory rather than the repository, so a fresh checkout — a CI runner, a new machine — has none,
# and every `require("@lune/fs")` in the compiler reports as an unknown require. That is exactly how
# this gate failed the first time it ran in CI.
#
# `lune setup` is idempotent and takes under a second, so it runs unconditionally instead of guessing
# at the path, which changes with the pinned Lune version.
echo "type-check: refreshing Lune type definitions"
lune setup >/dev/null

mkdir -p build

echo "type-check: compiler (src)"
luau-lsp analyze --defs globalTypes.d.luau src

echo "type-check: Studio plugin (plugin/src)"
rojo sourcemap default.project.json --output build/sourcemap.json >/dev/null
luau-lsp analyze --sourcemap build/sourcemap.json --defs globalTypes.d.luau plugin/src

# The compiler's OUTPUT, as a game's editor sees it. Every generated module declares `--!strict`, and
# until 0.32.0 the test schemas' modules carried about 190 strict errors between them -- invisible
# here, since only the compiler's own source was analysed. test/Golden is the committed output of
# every test schema, so an emitter change that breaks strict mode fails here instead of in a game.
echo "type-check: generated modules (test/Golden)"
luau-lsp analyze --defs globalTypes.d.luau test/Golden

echo "type-check: clean"
