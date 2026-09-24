#!/usr/bin/env sh
# Keeps Luau files at a size a person can hold in their head.
#
# The limit is 500 lines, with no exceptions.
#
# It was 900, and three files sat past it on a recorded-size ratchet that let them shrink but never
# grow. It came down to 500 to force the long files apart -- the parser and the generator had grown
# to hold the same logic in several copies, and a copy nobody can see next to the other one is where
# the two drift -- and every recorded file was split. A file that reaches the limit is split too; it
# is not listed here.
#
# Usage: check-file-size.sh [<file> ...]   (no arguments: the whole tree)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIMIT=500

if [ "$#" -eq 0 ]; then
	set -- $(find src plugin/src test .lune -name "*.luau" | sort)
fi

status=0
for file in "$@"; do
	[ -f "$file" ] || continue
	case "$file" in
		*.luau) ;;
		*) continue ;;
	esac

	case "$file" in
		# Generated or committed compiler output.
		test/Golden/* | test/Network/* | Network/* | release/* | build/*) continue ;;
		benchmark/*) continue ;;
	esac

	lines=$(wc -l < "$file" | tr -d ' ')
	if [ "$lines" -gt "$LIMIT" ]; then
		echo "check-file-size: $file is $lines lines, over the $LIMIT line limit" >&2
		echo "  Split it into modules; see how src/Parser/ or src/Generator/Prefabs/ are laid out." >&2
		status=1
	fi
done

exit "$status"
