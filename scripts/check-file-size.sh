#!/usr/bin/env sh
# Keeps Luau files at a size a person can hold in their head, and keeps the ones that are already
# past it from getting worse.
#
# The limit is 500 lines. Files that already exceed it are listed below WITH THEIR CURRENT SIZE, and
# each is allowed to shrink but never to grow. That is deliberate: a plain exclusion list rots into
# permission, while a recorded number turns every addition to a long file into a decision someone has
# to make on purpose. Shrink one and lower its number in the same commit.
#
# The limit was 900 and came down to 500 to force the long files apart: the parser and the
# generator had grown to hold the same logic in several copies, and a copy nobody can see next to
# the other one is where the two drift. Every file below is scheduled to be split, and its entry goes
# away in the commit that does it -- the list is meant to end empty.
#
# Usage: check-file-size.sh [<file> ...]   (no arguments: the whole tree)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIMIT=500

# path:maximum-lines
GRANDFATHERED="src/Parser.luau:1768
src/Generator/init.luau:1568
plugin/src/Editor/init.luau:921
test/Test.luau:777
src/Generator/Prefabs.luau:792
test/Guards.luau:721
plugin/src/init.server.luau:579
test/Assertions.luau:559"

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
	allowed=$(echo "$GRANDFATHERED" | grep "^$file:" | cut -d: -f2 || true)

	if [ -n "$allowed" ]; then
		if [ "$lines" -gt "$allowed" ]; then
			echo "check-file-size: $file is $lines lines, and was recorded at $allowed" >&2
			echo "  This file is already over the limit. Do not add to it -- extract instead." >&2
			status=1
		fi

		continue
	fi

	if [ "$lines" -gt "$LIMIT" ]; then
		echo "check-file-size: $file is $lines lines, over the $LIMIT line limit" >&2
		echo "  Split it, or add it to GRANDFATHERED in this script with a reason." >&2
		status=1
	fi
done

exit "$status"
