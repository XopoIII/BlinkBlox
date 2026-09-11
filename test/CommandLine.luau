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

return {}
