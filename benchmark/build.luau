--!strict
--- Builds the benchmark place. Run from this directory:
---
---     lune run build              compile the definitions and build Benchmark.rbxl
---     lune run build --download   fetch the tools and packages first
---     lune run build --run        then run the place and write Benchmarks.md
---
--- Replaces build.bat, which only ran on Windows. It takes flags rather than asking: a prompt throws
--- when no terminal is attached, which is every script and CI runner.
local fs = require("@lune/fs")
local process = require("@lune/process")

local EXECUTABLE = if process.os == "windows" then ".exe" else ""

local Download = table.find(process.args, "--download") ~= nil
local Run = table.find(process.args, "--run") ~= nil

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
for _, Directory in { "./src/shared/zap", "./src/shared/blink" } do
	if not fs.isDir(Directory) then
		fs.writeDir(Directory)
	end
end
Step(`./tools/zap{EXECUTABLE}`, { "./definitions/Definition.zap" })
Step(`./tools/blinkblox{EXECUTABLE}`, { "./definitions/Definition.blink", "--yes" })

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
