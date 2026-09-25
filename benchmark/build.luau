--!strict
--- Builds the benchmark place. Run from this directory:
---
---     lune run build              compile the definitions and build Benchmark.rbxl
---     lune run build --download   fetch the tools and packages first
---     lune run build --run        then run the place and write Benchmarks.md
---     lune run build --local      compile with this checkout's compiler instead of the release
---
--- Replaces build.bat, which only ran on Windows. It takes flags rather than asking: a prompt throws
--- when no terminal is attached, which is every script and CI runner.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local EXECUTABLE = if process.os == "windows" then ".exe" else ""

local Download = table.find(process.args, "--download") ~= nil
local Run = table.find(process.args, "--run") ~= nil
--> The latest release lags the tree whenever a version is merged and not yet released, and the bench
--> is most often run to measure exactly that.
local Local = table.find(process.args, "--local") ~= nil

local function Step(Program: string, Arguments: { string })
	print(`> {Program} {table.concat(Arguments, " ")}`)
	local Result = process.exec(Program, Arguments, { stdio = "inherit" })
	if not Result.ok then
		error(`{Program} failed with exit code {Result.code}`, 0)
	end
end

local function Fresh(Directory: string)
	if fs.isDir(Directory) then
		fs.removeDir(Directory)
	end
	fs.writeDir(Directory)
end

if Download then
	print("Downloading dependencies...")
	Fresh("./tools")
	Fresh("./packages")
	Step("lune", { "run", "download" })
end

print("Compiling definitions")
for _, Directory in { "./src/shared/zap", "./src/shared/blink", "./src/shared/upstream" } do
	if not fs.isDir(Directory) then
		fs.writeDir(Directory)
	end
end
Step(`./tools/zap{EXECUTABLE}`, { "./definitions/Definition.zap" })

--> Upstream Blink compiles its own definition with its own compiler, run from source on Lune.
do
	local Definition = `{process.cwd}definitions/Definition.upstream.blink`
	print(`> lune run init {Definition} -- --yes (in ./tools/upstream/src/CLI)`)
	local Result = process.exec("lune", { "run", "init", Definition, "--", "--yes" }, {
		cwd = "./tools/upstream/src/CLI",
		stdio = "inherit",
	})
	if not Result.ok then
		error(`Upstream Blink's compiler failed with exit code {Result.code}`, 0)
	end
end
if Local then
	local Definition = `{process.cwd}definitions/Definition.blink`
	print(`> lune run init {Definition} -- --yes (in ../src/CLI)`)
	local Result = process.exec("lune", { "run", "init", Definition, "--", "--yes" }, {
		cwd = "../src/CLI",
		stdio = "inherit",
	})
	if not Result.ok then
		error(`The checkout's compiler failed with exit code {Result.code}`, 0)
	end

	--> Benchmarks.md names each tool's version from here, which the download wrote for the release.
	local Manifest = serde.decode("toml", fs.readFile("../pesde.toml"))
	local Versions = serde.decode("json", fs.readFile("./tools/versions.json"))
	Versions.blink = `v{Manifest.version}, compiled from this repository`
	fs.writeFile("./tools/versions.json", serde.encode("json", Versions))
else
	Step(`./tools/blinkblox{EXECUTABLE}`, { "./definitions/Definition.blink", "--yes" })
end

print("Building ROBLOX place")
if not fs.isDir("./roblox") then
	fs.writeDir("./roblox")
end
Step("rojo", { "sourcemap", "default.project.json", "--output", "sourcemap.json", "--include-non-scripts" })
--> The sourcemap luau-lsp reads for the benchmark's sources.
Step("rojo", { "sourcemap", "default.project.json", "--output", "../sourcemap.json", "--include-non-scripts" })
Step("darklua", { "process", "src", "roblox" })
Step("rojo", { "build", "build.project.json", "--output", "./Benchmark.rbxl" })

if Run then
	Step("lune", { "run", "generate" })
end
