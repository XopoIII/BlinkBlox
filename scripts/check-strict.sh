#!/usr/bin/env sh
# Every Luau file in this repository declares its type-checking mode on the first line.
#
# WHY IT IS ENFORCED RATHER THAN AGREED: Luau's default is `nonstrict`, which silently accepts what
# strict mode would reject. A file that arrives without a directive is not "unannotated", it is
# unchecked -- and the type gate then reports the tree as clean while whole modules go unexamined.
# That is exactly what had happened here: the lexer, the generator, the settings table and the
# diagnostics renderer all ran unchecked, and `scripts/type-check.sh` said "clean" every time.
#
# `--!strict` is the expected mode. `--!nonstrict` and `--!nocheck` are accepted so a file can opt
# out deliberately and visibly, which is the point -- a reviewer sees the line.
#
# Usage: check-strict.sh <file> ...   (staged files from lefthook)
#        check-strict.sh             (no arguments: the whole tree)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
		# Generated or committed compiler output: the generator writes its own directives.
		test/Golden/* | test/Network/* | Network/* | release/* | build/*) continue ;;
		benchmark/*) continue ;;
	esac

	first=$(head -1 "$file")
	case "$first" in
		"--!strict" | "--!nonstrict" | "--!nocheck") ;;
		*)
			echo "check-strict: $file does not declare a type-checking mode on line 1" >&2
			status=1
			;;
	esac
done

if [ "$status" -ne 0 ]; then
	echo "" >&2
	echo "Add '--!strict' as the first line. Use '--!nonstrict' or '--!nocheck' only deliberately." >&2
fi

exit "$status"
