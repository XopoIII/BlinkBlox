#!/usr/bin/env sh
# Run the compiler test suite. Run by hand with:  sh scripts/run-tests.sh
#
# The suite recompiles every schema in test/Sources through the CLI, then executes the generated
# modules against mocked Roblox globals (test/Shared.luau, Client.luau, Server.luau). That makes it
# the only gate that checks the compiler's OUTPUT rather than its source.
#
# `--yes` skips the "Compile files?" prompt. It is not merely convenient: `stdio.prompt` throws
# "IO error: not a terminal" when stdin is not a TTY, so without it the suite aborts before running
# a single spec whenever it is driven by a hook, a pipe or CI.
set -e

export PATH="$HOME/.rokit/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/test"

lune run Test --yes
