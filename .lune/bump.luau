--> Sets the version used by the build. Run as:
-->     lune run bump 0.19.0
-->
--> The version lives in two places that must agree: darklua injects it into the compiler as
--> `_G.VERSION` when bundling a release, and pesde carries it as the package version.
-->
--> Taking it as an argument matters beyond convenience: `stdio.prompt` throws
--> "IO error: not a terminal" when stdin is not a TTY, so the prompt-only version could not run from
--> a release script or a CI job at all. It still prompts when no version is given and a terminal is
--> there to answer.

local darklua_version = require("./libs/darklua_version")
local pesde_version = require("./libs/pesde_version")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local PESDE_CONFIG = "pesde.toml"
local DARKLUA_CONFIG = "build/.darklua.json"

local curr_version = darklua_version.read_from(DARKLUA_CONFIG)
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
darklua_version.write_to(DARKLUA_CONFIG, new_version)
pesde_version.write_to(PESDE_CONFIG, new_version)

stdio.write(`bump: {curr_version} -> {new_version}\n`)
