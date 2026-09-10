#!/usr/bin/env sh
# Pre-commit gate: every artefact in this repository is written in English.
#
# Code, comments, documentation, schema files, commit bodies, skill and agent instructions, prompts,
# descriptions — all of it. The rule is enforced rather than agreed because a stray non-English word
# is invisible to a reviewer who does not read that language, and it is permanent once it lands.
#
# WHAT IT LOOKS FOR: a LETTER outside ASCII — Cyrillic, Greek, CJK, Hebrew, Arabic, or a Latin letter
# carrying a diacritic. Not "any byte above 127": the diagnostics renderer in src/Modules/Error.luau
# draws its gutters with box-drawing characters (─ │ ┆ ╭ ╯), an em dash is ordinary English
# punctuation, and both must keep working. `\p{L}` matches neither.
#
# `-CSD` is load-bearing. Without it perl reads bytes rather than UTF-8, and every multi-byte
# character decodes into Latin-1 bytes that ARE letters — so box-drawing characters and em dashes
# all report as violations. Measured here: the naive version flagged nine clean lines.
#
# Usage: check-english.sh <file> ...   (staged files from lefthook)
set -e

status=0
for file in "$@"; do
	[ -f "$file" ] || continue
	case "$file" in
		# Build artifacts: the compiler writes these, and the syntax theme is upstream data.
		test/Network/* | release/* | build/sourcemap*.json) continue ;;
		docs/public/syntax/*) continue ;;
		globalTypes.d.luau) continue ;;
		# Lock files and dependency manifests are not prose.
		*.lock | */pnpm-lock.yaml | */package-lock.json) continue ;;
	esac

	hits=$(perl -CSD -ne 'if (/(?=\P{ASCII})\p{L}/) { print "  $ARGV:$.: $_" }' "$file" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		echo "check-english: non-English text in $file" >&2
		echo "$hits" >&2
		status=1
	fi
done

if [ "$status" -ne 0 ]; then
	echo "" >&2
	echo "Everything in this repository is written in English. Rewrite the lines above." >&2
fi

exit "$status"
