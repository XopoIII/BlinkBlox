#!/usr/bin/env sh
# Run the compiler test suite. Run by hand with:  sh scripts/run-tests.sh
#
# The suite recompiles every schema in test/Sources through the CLI, then executes the generated
# modules against mocked Roblox globals (test/Shared.luau, Client.luau, Server.luau). That makes it
# the only gate that checks the compiler's OUTPUT rather than its source.
#
# `--yes` skips the "Compile files?" prompt. `stdio.prompt` throws "IO error: not a terminal" when
# stdin is not a TTY, which once aborted the suite before a single spec ran whenever a hook, a pipe
# or CI drove it. The runner now catches that and compiles, so the flag only says so out loud.
set -e

export PATH="$HOME/.rokit/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/test"

luneblox run Test --yes
