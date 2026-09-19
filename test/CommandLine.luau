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
	assert(string.find(Result.stdout, "Blink", 1, true), `--version printed no version: {Result.stdout}`)
end)

RunClosure("CLI --version answers even when quiet", function()
	local Result = process.exec("lune", { "run", Compiler, "--", "--version", "--quiet" }, { cwd = "../src/CLI" })
	assert(Result.ok, Result.stderr)
	assert(
		string.find(Result.stdout, "Blink", 1, true),
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
	assert(not string.find(Result.stdout, "Blink", 1, true), `--quiet still printed the banner: {Result.stdout}`)
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

return {}
