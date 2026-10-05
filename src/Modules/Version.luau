--!strict
--- The version of BlinkBlox that is running: what the CLI prints, what `Library.VERSION` holds and
--- what the header of every generated module names -- and whether this is a bundled build at all.
---
--- darklua replaces `_G.VERSION` with a literal when it bundles a release (`build/.darklua.json`), so
--- a run from source has none and reports `0.0.0`, a version no release carries. That is deliberate,
--- not a placeholder: it is how an unbundled run says it is unbundled. The CLI printed `DEBUG` there
--- while the library and the generated headers said `0.0.0`; this is the one place that decides.
---
--- It is also the one place that reads `_G.VERSION`. Code that needs to know whether it runs from a
--- bundle asks `Bundled` rather than testing the global again, so the two answers cannot disagree.
local Injected: string? = _G.VERSION

return {
	--- The version as it is printed: the bundle's, or `0.0.0` from source.
	Current = Injected or "0.0.0",
	--- Whether darklua injected a version, which is to say whether this is a release bundle.
	Bundled = Injected ~= nil,
}
