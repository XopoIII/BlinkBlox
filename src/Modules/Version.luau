--!strict
--- The version of BlinkBlox that is running: what the CLI prints, what `Library.VERSION` holds and
--- what the header of every generated module names.
---
--- darklua replaces `_G.VERSION` with a literal when it bundles a release (`build/.darklua.json`), so
--- a run from source has none and reports `0.0.0`, a version no release carries. That is deliberate,
--- not a placeholder: it is how an unbundled run says it is unbundled. The CLI printed `DEBUG` there
--- while the library and the generated headers said `0.0.0`; this is the one place that decides.
return (_G.VERSION or "0.0.0") :: string
