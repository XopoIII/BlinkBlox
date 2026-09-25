--!strict
--> Sets the version used by the build. Run as:
-->     lune run bump 0.19.0
-->
--> The version lives in two places that must agree: build/.darklua.json, which darklua injects as
--> `_G.VERSION` when bundling both the CLI and the Studio plugin, and pesde.toml, which carries it as
--> the package version. The docs print it too -- the rokit pin and the CLI's banner -- and are
--> rewritten beside them (see libs/docs_version).
-->
--> The plugin once had a config of its own, and it was missed for five minor versions with nothing
--> saying so. Everything the plugin generated went out stamped with a version the compiler had not
--> been for a year. It now bundles with the CLI's config, so there is no copy to miss. Hence still a
--> list rather than a constant: adding a target is an edit to one line, and check-versions.sh fails
--> the build if any of them drift apart.
-->
--> Taking it as an argument matters beyond convenience: `stdio.prompt` throws
--> "IO error: not a terminal" when stdin is not a TTY, so the prompt-only version could not run from
--> a release script or a CI job at all. It still prompts when no version is given and a terminal is
--> there to answer.

local darklua_version = require("./libs/darklua_version")
local docs_version = require("./libs/docs_version")
local pesde_version = require("./libs/pesde_version")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local PESDE_CONFIG = "pesde.toml"
local DARKLUA_CONFIGS = { "build/.darklua.json" }

--> The first is the reference: it is the one the CLI reports and the one a release is cut from.
local curr_version = darklua_version.read_from(DARKLUA_CONFIGS[1])
local new_version: string? = process.args[1]

if not new_version then
	local Asked, Answer =
		pcall(stdio.prompt, "text" :: "text", `What version is being built? (Current version is {curr_version})`)

	if not Asked then
		stdio.ewrite("bump: no version given, and no terminal to ask on.\n")
		stdio.ewrite("Usage: lune run bump <version>   (for example: lune run bump 0.19.0)\n")
		process.exit(2)
	end

	new_version = Answer
end

assert(new_version, "bump: no version to write")
for _, config in DARKLUA_CONFIGS do
	darklua_version.write_to(config, new_version)
end

pesde_version.write_to(PESDE_CONFIG, new_version)
docs_version.write_to(new_version)

stdio.write(`bump: {curr_version} -> {new_version}\n`)
