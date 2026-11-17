## Summary

- Release BlinkBlox 1.3.9: pin LuneBlox 0.11.4 and its matching typedef alias; no compiler, generated-wire or handler API changes.
- Refresh Astro, Starlight, postcss-selector-parser and the documentation lockfile; the remaining tools and workflow action pins are already latest stable.
- Fix the truncated SHA-256 in the optional OCALE installer; verify it against the pinned Linux archive.
- Bump version metadata and documentation using `luneblox run bump 1.3.9`; add release notes.

## Validation

- Formatting, lint (zero errors/warnings), strict modes, file-size cap, version agreement, English-only check and whitespace checks.
- Full type gates (compiler, plugin, goldens and consumers under both solvers), complete test suite with unchanged goldens, all five CLI builds and plugin.
- `npm ci`, documentation build with internal-link validation, npm audit with zero vulnerabilities.
- Local OCALE codec experiment: all nine checks and self-comparison passed; no credentialed Roblox run performed.
- Runtime-change comparisons on Apple M1: three full ABBA rounds, native and interpreted, plus focused native entity retests. Measurements are recorded in the changelog; the compiler itself is unchanged.

## Release

Merge with a merge commit, publish v1.3.9 on GitHub, wait for all six release assets, then rebuild from the tagged commit before publishing pesde and Wally.

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
