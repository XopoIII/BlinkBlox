--!strict
--- Specs for `--verify`, which compares what a compile would write with the files on disk.
---
--- Its promises are all about files, so every spec checks the files themselves: the exact list of
--- paths reported and how, the exit code, and -- after every run, passing or failing -- that nothing
--- was written, created or put back. A verify that quietly regenerated what it found stale would pass
--- every other assertion here and defeat the point of the flag.
local Harness = require("./Harness")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Assertions = require("./Assertions")

local Compiler = Harness.Compiler
local RunClosure = Assertions.RunClosure

local SCHEMA = "../../test/Sources/Verify/Verify"
--> As the test runner (in test/) reaches the outputs, and as the CLI (in src/CLI) names them.
local DIRECTORY = "Network/Verify"
local SHOWN = "../../test/Network/Verify"
--> The order the compiler writes them in, which is the order they are reported in.
local FILES = { "Server.luau", "Client.luau", "Types.luau", "Client.d.ts", "Server.d.ts" }

type Snapshot = { [string]: { Contents: string, Modified: number } | false }

local function Run(...: string): process.ExecResult
	return process.exec("lune", { "run", Compiler, SCHEMA, "--", ... }, { cwd = "../src/CLI" })
end

local function Build(...: string)
	local Result = Run("--yes", "--quiet", ...)
	assert(Result.ok, Result.stdout .. Result.stderr)
end

--- Every output's bytes and modification time, or false for one that is not there.
local function Snap(): Snapshot
	local Result: Snapshot = {}
	for _, File in FILES do
		local Path = `{DIRECTORY}/{File}`
		if fs.isFile(Path) then
			local Modified = fs.metadata(Path).modifiedAt
			Result[File] = {
				Contents = fs.readFile(Path),
				Modified = if Modified then Modified.unixTimestampMillis else -1,
			}
		else
			Result[File] = false
		end
	end

	return Result
end

local function AssertUntouched(Before: Snapshot, What: string)
	local After = Snap()
	for _, File in FILES do
		local Old, New = Before[File], After[File]
		if Old == false or New == false then
			assert(Old == New, `{What}: {File} was {if Old then "removed" else "created"}`)
			continue
		end

		assert(Old.Contents == New.Contents, `{What}: {File} was rewritten`)
		assert(Old.Modified == New.Modified, `{What}: {File} was touched`)
	end
end

--- The stale and missing files a rendered run printed, one "status path line" string each.
local function Listed(Output: string): { string }
	local Result: { string } = {}
	for _, Line in string.split((string.gsub(Output, "\27%[%d+m", "")), "\n") do
		local Status, Path, Rest = string.match(Line, "^(%a+): (%S+)(.*)$")
		if Status == "stale" or Status == "missing" then
			local Number = string.match(Rest :: string, "^ %(first difference on line (%d+)%)$")
			table.insert(Result, `{Status} {Path}{if Number then ` {Number}` else ""}`)
		end
	end

	return Result
end

local function AssertList(Actual: { string }, Expected: { string }, Output: string)
	local Shown = table.concat(Actual, " | ")
	assert(#Actual == #Expected, `expected {table.concat(Expected, " | ")}, got {Shown}\n{Output}`)
	for Index, Line in Expected do
		assert(Actual[Index] == Line, `expected {table.concat(Expected, " | ")}, got {Shown}\n{Output}`)
	end
end

local function Json(...: string): (process.ExecResult, any)
	local Result = Run("--verify", "--json", ...)
	local Decoded, Document = pcall(serde.decode, "json" :: "json", Result.stdout)
	assert(Decoded, `--verify --json printed something that is not JSON: {Result.stdout}{Result.stderr}`)
	return Result, Document
end

local function AssertEntries(Document: any, Expected: { { any } }, Output: string)
	assert(#Document.verify == #Expected, `expected {#Expected} compared files: {Output}`)
	for Index, Want in Expected do
		local Entry = Document.verify[Index]
		assert(Entry.file == `{SHOWN}/{Want[1]}`, `entry {Index} is {Entry.file}: {Output}`)
		assert(Entry.status == Want[2], `{Want[1]} is {Entry.status}, expected {Want[2]}: {Output}`)
		assert(Entry.line == Want[3], `{Want[1]} line {Entry.line}, expected {Want[3]}: {Output}`)
	end
end

RunClosure("CLI --verify with no outputs reports each missing and creates nothing", function()
	pcall(fs.removeDir, DIRECTORY)
	local Result = Run("--verify")
	assert(not Result.ok, "--verify passed with no generated files on disk")
	local Expected = {}
	for _, File in FILES do
		table.insert(Expected, `missing {SHOWN}/{File}`)
	end

	AssertList(Listed(Result.stdout), Expected, Result.stdout)
	assert(string.find(Result.stdout, "5 of 5 generated files do not match the schema.", 1, true), Result.stdout)
	assert(not fs.isDir(DIRECTORY), "--verify created the output directory")
end)

RunClosure("CLI --verify passes on fresh output and writes nothing", function()
	Build()
	local Before = Snap()
	for _, File in FILES do
		assert(Before[File], `the build did not write {File}`)
	end

	local Result = Run("--verify")
	assert(Result.ok, Result.stdout .. Result.stderr)
	AssertList(Listed(Result.stdout), {}, Result.stdout)
	assert(string.find(Result.stdout, "All 5 generated files match the schema.", 1, true), Result.stdout)
	AssertUntouched(Before, "a passing --verify")

	--> Quiet silences the pass, and only the pass: the exit code is the whole answer then.
	local Quiet = Run("--verify", "--quiet")
	assert(Quiet.ok and Quiet.stdout == "", `--verify --quiet printed on success: {Quiet.stdout}`)

	local Checked = Run("--verify", "--check")
	assert(Checked.ok, `--verify --check failed on fresh output: {Checked.stdout}`)
	AssertUntouched(Before, "--verify --check")
end)

RunClosure("CLI --verify --json lists every compared file", function()
	local Before = Snap()
	local Result, Document = Json()
	assert(Result.ok, Result.stdout .. Result.stderr)
	assert(Document.version == 1 and Document.success == true, Result.stdout)
	assert(#Document.diagnostics == 0 and #Document.outputs == 0, Result.stdout)
	AssertEntries(Document, {
		{ "Server.luau", "current", nil },
		{ "Client.luau", "current", nil },
		{ "Types.luau", "current", nil },
		{ "Client.d.ts", "current", nil },
		{ "Server.d.ts", "current", nil },
	}, Result.stdout)
	--> `line` is present as null, not left out, and `verify` comes after the fields it extends.
	assert(string.find(Result.stdout, '"outputs":[],"verify":[{"file":', 1, true), Result.stdout)
	assert(string.find(Result.stdout, '"status":"current","line":null}', 1, true), Result.stdout)
	AssertUntouched(Before, "--verify --json")

	--> Without --verify the field is absent, so its absence says nothing was compared.
	local Plain = process.exec("lune", { "run", Compiler, SCHEMA, "--", "--check", "--json" }, { cwd = "../src/CLI" })
	assert(Plain.ok and not string.find(Plain.stdout, '"verify"', 1, true), Plain.stdout)
end)

RunClosure("CLI --verify names a file changed by one byte", function()
	local Path = `{DIRECTORY}/Server.luau`
	local Original = fs.readFile(Path)
	local Offset = #Original // 2
	while string.sub(Original, Offset, Offset) == "\n" do
		Offset += 1
	end

	local Byte = if string.sub(Original, Offset, Offset) == "X" then "Y" else "X"
	local Tampered = string.sub(Original, 1, Offset - 1) .. Byte .. string.sub(Original, Offset + 1)
	local _, Newlines = string.gsub(string.sub(Original, 1, Offset - 1), "\n", "")
	local Line = Newlines + 1
	assert(Line > 1, "the changed byte should sit past the header")
	fs.writeFile(Path, Tampered)

	local Before = Snap()
	local Result = Run("--verify", "--quiet")
	assert(not Result.ok, "--verify passed a changed server module")
	AssertList(Listed(Result.stdout), { `stale {SHOWN}/Server.luau {Line}` }, Result.stdout)
	assert(string.find(Result.stdout, "1 of 5 generated files do not match the schema.", 1, true), Result.stdout)

	local JsonResult, Document = Json()
	assert(not JsonResult.ok and Document.success == false, JsonResult.stdout)
	assert(#Document.diagnostics == 0, JsonResult.stdout)
	AssertEntries(Document, {
		{ "Server.luau", "stale", Line },
		{ "Client.luau", "current", nil },
		{ "Types.luau", "current", nil },
		{ "Client.d.ts", "current", nil },
		{ "Server.d.ts", "current", nil },
	}, JsonResult.stdout)

	AssertUntouched(Before, "a failing --verify")
	assert(fs.readFile(Path) == Tampered, "--verify put the stale file back")
	fs.writeFile(Path, Original)
end)

RunClosure("CLI --verify reports a deleted file as missing and leaves it deleted", function()
	fs.removeFile(`{DIRECTORY}/Client.d.ts`)
	local Before = Snap()

	local Result = Run("--verify")
	assert(not Result.ok, "--verify passed with a declaration file deleted")
	AssertList(Listed(Result.stdout), { `missing {SHOWN}/Client.d.ts` }, Result.stdout)

	local JsonResult, Document = Json()
	assert(not JsonResult.ok and Document.success == false, JsonResult.stdout)
	assert(
		Document.verify[4].file == `{SHOWN}/Client.d.ts` and Document.verify[4].status == "missing",
		JsonResult.stdout
	)
	assert(Document.verify[4].line == nil and Document.verify[1].status == "current", JsonResult.stdout)

	AssertUntouched(Before, "--verify over a missing file")
	assert(not fs.isFile(`{DIRECTORY}/Client.d.ts`), "--verify recreated the deleted file")
	Build()
end)

--> The compiler never deletes in an output folder, so neither does a verify count what is there.
RunClosure("CLI --verify ignores files the compiler would not write", function()
	local Extra = `{DIRECTORY}/Extra.luau`
	fs.writeFile(Extra, "return nil\n")
	local Result = Run("--verify")
	assert(Result.ok, `an extra file in the output folder failed --verify: {Result.stdout}`)
	assert(string.find(Result.stdout, "All 5 generated files match the schema.", 1, true), Result.stdout)
	assert(fs.readFile(Extra) == "return nil\n", "--verify touched a file it does not own")
	fs.removeFile(Extra)
end)

--> A dev build carries the dev event in every module but the types one, which holds no events.
RunClosure("CLI --verify compares the outputs of the profile it is given", function()
	local Before = Snap()
	local Result, Document = Json("--profile", "dev")
	assert(not Result.ok, "a release build verified as dev")
	AssertEntries(Document, {
		{ "Server.luau", "stale", Document.verify[1].line },
		{ "Client.luau", "stale", Document.verify[2].line },
		{ "Types.luau", "current", nil },
		{ "Client.d.ts", "stale", Document.verify[4].line },
		{ "Server.d.ts", "stale", Document.verify[5].line },
	}, Result.stdout)
	for Index = 1, 5 do
		local Line = Document.verify[Index].line
		assert(Index == 3 or (type(Line) == "number" and Line > 1), `entry {Index} has no line: {Result.stdout}`)
	end
	AssertUntouched(Before, "--verify --profile dev")

	Build("--profile", "dev")
	assert(string.find(fs.readFile(`{DIRECTORY}/Server.luau`), "DevOnlyGiveMoney", 1, true), "dev build lost the event")
	assert(Run("--verify", "-p", "dev").ok, "a dev build failed --verify -p dev")
	local Release = Run("--verify")
	assert(not Release.ok, "a dev build verified as release")
	AssertList(Listed(Release.stdout), {
		`stale {SHOWN}/Server.luau {Document.verify[1].line}`,
		`stale {SHOWN}/Client.luau {Document.verify[2].line}`,
		`stale {SHOWN}/Client.d.ts {Document.verify[4].line}`,
		`stale {SHOWN}/Server.d.ts {Document.verify[5].line}`,
	}, Release.stdout)
end)

--> A schema error is reported as it is under --check, and with nothing compared.
RunClosure("CLI --verify reports a schema error before comparing", function()
	local Result = process.exec(
		"lune",
		{ "run", Compiler, "../../test/Sources/Invalid/MissingRateLimit", "--", "--verify", "--json" },
		{ cwd = "../src/CLI" }
	)
	local Document = serde.decode("json", Result.stdout)
	assert(not Result.ok and Document.success == false, Result.stdout)
	assert(Document.diagnostics[1].code == "E3020" and #Document.verify == 0, Result.stdout)
end)

RunClosure("CLI refuses --verify with --watch", function()
	local Before = Snap()
	local Result = Run("--verify", "--watch")
	assert(not Result.ok, "--verify --watch was accepted")
	assert(string.find(Result.stdout, '"--verify" cannot be combined with "--watch"', 1, true), Result.stdout)
	AssertUntouched(Before, "--verify --watch")
end)

return {}
