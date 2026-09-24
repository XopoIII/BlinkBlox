#!/usr/bin/env sh
# Keeps every recorded version in step.
#
# The version is written in two places: build/.darklua.json, which darklua injects as _G.VERSION when
# bundling both the CLI and the Studio plugin, and pesde.toml, which carries it as the package version.
# `lune run bump <version>` writes both.
#
# This exists because the plugin once had a config of its own, and its copy sat at 0.18.0 against a
# 0.23.0 tree -- five minor versions -- with nothing anywhere noticing. Every file the plugin generated
# went out stamped with a version the compiler had not been for a year. The plugin now bundles with
# the CLI's config, so there is no second copy to drift; this is what stops the next target being
# added and quietly missed.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The value of the inject_global_value rule whose identifier is VERSION.
read_darklua() {
	tr -d ' \t\n' < "$1" | sed -n 's/.*"identifier":"VERSION","rule":"inject_global_value","value":"\([^"]*\)".*/\1/p'
}

CLI="$(read_darklua build/.darklua.json)"
PESDE="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' pesde.toml | head -1)"

status=0

if [ -z "$CLI" ]; then
	echo "check-versions: could not read a version out of build/.darklua.json" >&2
	status=1
fi

if [ -z "$PESDE" ]; then
	echo "check-versions: could not read a version out of pesde.toml" >&2
	status=1
fi

if [ "$status" -eq 0 ]; then
	if [ "$CLI" != "$PESDE" ]; then
		echo "check-versions: the recorded versions disagree" >&2
		echo "  build/.darklua.json: $CLI" >&2
		echo "  pesde.toml:          $PESDE" >&2
		echo "  Run 'lune run bump <version>' rather than editing them by hand." >&2
		status=1
	fi
fi

exit "$status"
