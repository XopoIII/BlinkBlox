--!strict
--- Specs for the CLI itself rather than for what it emits.
---
--- Both are really about `stdio.prompt`, which does not degrade when stdin is not a terminal -- it
--- throws, or under some runners blocks with nothing printed. So the suite checks both halves: that
--- the prompt still happens when a terminal is attached, and that `--yes` gets past it. A regression
--- in either shows up as a hung CI job rather than as a failed assertion, which is exactly why they
--- are asserted here.
local Harness = require("./Harness")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Assertions = require("./Assertions")

local Compiler = Harness.Compiler
local COMPILE_TEST_FILE = Harness.TestSchema

local RunClosure = Assertions.RunClosure

RunClosure("CLI compile prompt", function()
	pcall(function()
		fs.removeDir("../Network")
	end)

	local Result: process.ExecResult
	local Thread = task.spawn(function()
		Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE }, { cwd = "../src/CLI" })
	end)

	if coroutine.status(Thread) ~= "suspended" then
		error(Result and Result.stderr or "CLI didn't prompt")
	end

	task.cancel(Thread)
end)

RunClosure("CLI compile --yes", function()
	local Result = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
end)

--> `--version` returned without printing anything of its own; a version only ever appeared because
--> an unconditional banner was the first statement in the file. So the flag looked implemented from
--> the outside while having no implementation, and `--quiet` could not suppress a banner printed
--> before the flags were parsed. Both halves are asserted, because either one alone still passes if
--> the other regresses.
RunClosure("CLI --version prints a version", function()
	local Result = process.exec("lune", { "run", Compiler, "--", "--version" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
	assert(string.find(Result.stdout, "BlinkBlox", 1, true), `--version printed no version: {Result.stdout}`)
end)

--> The usage line named `blinkblox.exe` on every platform, although only the Windows release has the
--> extension.
RunClosure("CLI --help names the executable for this platform", function()
	local Result = process.exec("lune", { "run", Compiler, "--", "--help" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
	local Named = string.find(Result.stdout, "blinkblox.exe", 1, true) ~= nil
	assert(Named == (process.os == "windows"), `--help named the wrong executable: {Result.stdout}`)
end)

RunClosure("CLI --version answers even when quiet", function()
	local Result = process.exec("lune", { "run", Compiler, "--", "--version", "--quiet" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
	assert(
		string.find(Result.stdout, "BlinkBlox", 1, true),
		`--version was silenced by --quiet, which is the one thing it was asked for: {Result.stdout}`
	)
end)

RunClosure("CLI --quiet prints no banner", function()
	local Result = process.exec(
		"lune",
		{ "run", Compiler, COMPILE_TEST_FILE, "--", "--yes", "--quiet" },
		{ cwd = "../src/CLI" }
	)
	assert(Result.ok, Result.stderr)
	assert(not string.find(Result.stdout, "BlinkBlox", 1, true), `--quiet still printed the banner: {Result.stdout}`)
end)

--> `--profile` is the one flag with a value, so both orders are tried: the value must never be taken
--> for the config path. A build without the flag is release, and leaves the dev event out.
local GATED = "../../test/Sources/Profiles/Gated"
local GATED_OUTPUT = "Network/ProfileServer.luau"

local function CompileGated(...: string): (boolean, string)
	local Result = process.exec("lune", { "run", Compiler, ... }, { cwd = "../src/CLI" })
	if not Result.ok then
		return false, Result.stdout .. Result.stderr
	end

	return true, fs.readFile(GATED_OUTPUT)
end

RunClosure("CLI builds release without --profile", function()
	local Ok, Output = CompileGated(GATED, "--", "--yes")
	assert(Ok, Output)
	assert(not string.find(Output, "DevOnlyGiveMoney", 1, true), "a build without --profile kept a dev event")
	assert(string.find(Output, "Ping", 1, true), "a build without --profile lost an unmarked event")
end)

RunClosure("CLI --profile dev after the path", function()
	local Ok, Output = CompileGated(GATED, "--", "--yes", "--profile", "dev")
	assert(Ok, Output)
	assert(string.find(Output, "DevOnlyGiveMoney", 1, true), "--profile dev left the dev event out")
end)

RunClosure("CLI -p dev before the path", function()
	local Ok, Output = CompileGated("--", "-p", "dev", GATED, "--yes")
	assert(Ok, Output)
	assert(string.find(Output, "DevOnlyGiveMoney", 1, true), "-p dev before the path left the dev event out")
end)

RunClosure("CLI refuses an unknown profile", function()
	local Ok = CompileGated(GATED, "--", "--yes", "--profile", "prod")
	assert(not Ok, "an unknown profile compiled")
end)

--> `--check` runs the whole compile and writes nothing, so its one observable promise is a file that
--> is not there afterwards.
RunClosure("CLI --check writes nothing", function()
	pcall(fs.removeFile, GATED_OUTPUT)
	local Result = process.exec("lune", { "run", Compiler, GATED, "--", "--check" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stdout .. Result.stderr)
	assert(not fs.isFile(GATED_OUTPUT), "--check wrote the server module")
end)

--> `--json` is read by programs, so standard output has to be one document and nothing else -- a
--> banner or a progress line in front of it fails the decode here before any field is looked at.
local function CompileJson(Schema: string, ...: string): (process.ExecResult, any)
	local Result = process.exec("lune", { "run", Compiler, Schema, "--", "--json", ... }, { cwd = "../src/CLI" })
	local Decoded, Document = pcall(serde.decode, "json" :: "json", Result.stdout)
	assert(Decoded, `--json printed something that is not JSON: {Result.stdout}{Result.stderr}`)
	return Result, Document
end

RunClosure("CLI --json reports a clean compile", function()
	local Result, Document = CompileJson(GATED)
	assert(Result.ok, Result.stderr)
	assert(Document.version == 1 and Document.success == true, Result.stdout)
	--> An empty list, not an empty object: `@lune/serde` would have printed `{}`.
	assert(string.find(Result.stdout, '"diagnostics":[]', 1, true), Result.stdout)
	assert(#Document.outputs == 2, `expected the two modules in "outputs": {Result.stdout}`)
end)

RunClosure("CLI --json reports an error with its position", function()
	local Result, Document = CompileJson("../../test/Sources/Invalid/MissingRateLimit", "--check")
	assert(not Result.ok, "an error exited 0")
	assert(Document.success == false and #Document.diagnostics == 1, Result.stdout)

	local Diagnostic = Document.diagnostics[1]
	assert(Diagnostic.severity == "error" and Diagnostic.code == "E3020", Result.stdout)
	assert(Diagnostic.name == "AnalyzeMissingRateLimit", Result.stdout)
	assert(string.find(Diagnostic.file, "Invalid/MissingRateLimit.blink$"), `wrong file: {Diagnostic.file}`)
	assert(Diagnostic.range.start.line == 8 and Diagnostic.range.start.column == 7, Result.stdout)
	assert(Diagnostic.labels[1].primary == true and #Diagnostic.notes == 1, Result.stdout)
end)

--> A warning does not fail the compile, and is reported rather than printed around the document.
RunClosure("CLI --json reports a warning without failing", function()
	local Result, Document = CompileJson("../../test/Sources/Invalid/UnboundedUnreliable", "--check")
	assert(Result.ok, Result.stdout .. Result.stderr)
	assert(Document.success == true and Document.diagnostics[1].code == "W3019", Result.stdout)
	assert(#Document.outputs == 0, "--check reported outputs it did not write")
end)

--> Not a diagnostic, and still JSON: the run that failed before the schema was even read is the one
--> a caller most needs to be able to parse.
RunClosure("CLI --json reports a missing schema", function()
	local Result, Document = CompileJson("../../test/Sources/DoesNotExist")
	assert(not Result.ok, "a missing schema exited 0")
	assert(Document.success == false and Document.diagnostics[1].code == nil, Result.stdout)
end)

RunClosure("CLI refuses --json with --watch", function()
	local Result = process.exec("lune", { "run", Compiler, GATED, "--", "--json", "--watch" }, { cwd = "../src/CLI" })
	assert(not Result.ok, "--json --watch was accepted")
end)

return {}
