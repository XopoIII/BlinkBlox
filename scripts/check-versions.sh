#!/usr/bin/env sh
# Keeps every recorded version in step.
#
# The version is written in three places: darklua injects it as _G.VERSION when bundling a release,
# once for the CLI and once for the Studio plugin, and pesde carries it as the package version.
# `lune run bump <version>` writes all three.
#
# This exists because the plugin's copy sat at 0.18.0 against a 0.23.0 tree -- five minor versions --
# and nothing anywhere noticed. Every file the plugin generated went out stamped with a version the
# compiler had not been for a year. A bump script that writes all three is the fix; this is what
# stops the next target being added and quietly missed.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The value of the inject_global_value rule whose identifier is VERSION.
read_darklua() {
	tr -d ' \t\n' < "$1" | sed -n 's/.*"identifier":"VERSION","rule":"inject_global_value","value":"\([^"]*\)".*/\1/p'
}

CLI="$(read_darklua build/.darklua.json)"
PLUGIN="$(read_darklua plugin/.darklua.json)"
PESDE="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' pesde.toml | head -1)"

status=0

if [ -z "$CLI" ]; then
	echo "check-versions: could not read a version out of build/.darklua.json" >&2
	status=1
fi

if [ -z "$PLUGIN" ]; then
	echo "check-versions: could not read a version out of plugin/.darklua.json" >&2
	status=1
fi

if [ -z "$PESDE" ]; then
	echo "check-versions: could not read a version out of pesde.toml" >&2
	status=1
fi

if [ "$status" -eq 0 ]; then
	if [ "$CLI" != "$PLUGIN" ] || [ "$CLI" != "$PESDE" ]; then
		echo "check-versions: the recorded versions disagree" >&2
		echo "  build/.darklua.json:  $CLI" >&2
		echo "  plugin/.darklua.json: $PLUGIN" >&2
		echo "  pesde.toml:           $PESDE" >&2
		echo "  Run 'lune run bump <version>' rather than editing them by hand." >&2
		status=1
	fi
fi

exit "$status"
