--!strict
--- The half of the suite that runs BEFORE anything is executed: compiling every schema, comparing
--- the result against the committed goldens, checking that recompiling is byte-identical, and
--- running the schemas that are supposed to be REJECTED.
---
--- Split out because none of it has anything to do with the specs. It talks to the filesystem and to
--- the compiler CLI; the specs talk to generated Luau through mocked Roblox globals. Keeping them in
--- one file meant every spec sat behind two hundred lines of build machinery.

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Compiler = "init"

--- Schemas to compile, in a fixed order.
---
--- `fs.readDir` returns whatever order the filesystem gives, which is alphabetical on APFS and hash
--- order on ext4. That difference used to decide the outcome of the suite: two schemas wrote to the
--- same Network modules, so on a Linux runner the wrong one landed last and half the events the
--- tests reference simply did not exist. The overlap is gone, and sorting keeps any future one from
--- depending on which machine ran it.
local Sources = fs.readDir("./Sources")
table.sort(Sources)

local COMPILE_TEST_FILE = "../../test/Sources/Test"

--- Committed copies of the compiler's OUTPUT, one directory per schema.
---
--- Every other spec here proves the generated modules still BEHAVE. None of them notice when the
--- emitted text changes shape -- a moved guard, a renamed local, a dropped comment -- which is
--- exactly what a generator change does. Regenerate them with `lune run Test --yes --update-goldens`
--- and read the diff before committing it.
local GOLDEN_DIRECTORY = "./Golden"

local function OkPrint(Message: string)
	stdio.write(`\r[{stdio.color("green")}OK{stdio.color("reset")}] {Message}\n`)
end

local function ErrorPrint(Message: string)
	stdio.write(`\r[{stdio.color("red")}ERROR{stdio.color("reset")}] {Message}\n`)
	process.exit(20)
end

local function PrettyPrint(Color: stdio.Color, Message: string, DontReturn: boolean?)
	stdio.write(`{stdio.color(Color)}{Message}{not DontReturn and "\n" or ""}{stdio.color("reset")}`)
end

--- Whether to regenerate the network modules before running the suite.
---
--- Compiling is the DEFAULT and a prompt is only ever a convenience. `stdio.prompt` throws
--- "IO error: not a terminal" when stdin is not a TTY — CI, a pipe, an editor task — and that throw
--- used to abort the whole runner before a single spec ran, which reads exactly like a broken test
--- suite. It is the same defect the compiler CLI has, and it is why the suite could never be gated
--- in CI. Pass `--no-compile` to run against the already generated modules.
local function HasArgument(Name: string): boolean
	for _, Argument in process.args do
		if Argument == Name then
			return true
		end
	end

	return false
end

local function ShouldCompile(): boolean
	for _, Argument in process.args do
		if Argument == "--yes" or Argument == "-y" or Argument == "--ci" then
			return true
		elseif Argument == "--no-compile" then
			return false
		end
	end

	local Success, Answer = pcall(stdio.prompt, "confirm" :: "confirm", "Compile files?")
	return if Success then Answer else true
end

local UpdateGoldens = HasArgument("--update-goldens")

--- Output paths a schema declares, as basenames. The compiler runs with `src/CLI` as its working
--- directory, so the paths in the schema are relative to that; the suite only needs the file name.
local function GetOutputs(Source: string): { string }
	local Outputs = {}
	for Path in string.gmatch(Source, 'option%s+%w+Output%s*=%s*"([^"]+)"') do
		local Basename = string.match(Path, "([^/]+)$")
		if Basename then
			table.insert(Outputs, Basename)
		end
	end

	return Outputs
end

--- First differing lines, capped so a wholesale regeneration does not bury the terminal.
local function Diff(Expected: string, Got: string): string
	local ExpectedLines = string.split(Expected, "\n")
	local GotLines = string.split(Got, "\n")
	local Total = math.max(#ExpectedLines, #GotLines)

	local Report = ""
	local Shown = 0

	for Line = 1, Total do
		local Left = ExpectedLines[Line]
		local Right = GotLines[Line]
		if Left == Right then
			continue
		end

		Report ..= `\n  L{Line}\n    golden: {Left or "<missing>"}\n    output: {Right or "<missing>"}`
		Shown += 1

		if Shown >= 20 then
			Report ..= `\n  ... and further differences past line {Line}.`
			break
		end
	end

	return Report
end

--- Copies this schema's freshly generated modules into its golden directory, or compares them
--- against what is already there. Called immediately after each compile because several schemas
--- write to the SAME output paths -- Test.blink and NoGenerics.blink both produce Client.luau -- so
--- the files are only that schema's output until the next one runs.
local function CaptureGoldens(File: string)
	local Stem = string.gsub(File, "%.blink$", "")
	local Directory = `{GOLDEN_DIRECTORY}/{Stem}`
	local Outputs = GetOutputs(fs.readFile(`./Sources/{File}`))

	if UpdateGoldens and not fs.isDir(Directory) then
		fs.writeDir(Directory)
	end

	for _, Basename in Outputs do
		local Generated = `../Network/{Basename}`
		if not fs.isFile(Generated) then
			ErrorPrint(`{File} declared an output "{Basename}" that was never written.`)
		end

		local Got = fs.readFile(Generated)
		local GoldenPath = `{Directory}/{Basename}`

		if UpdateGoldens then
			fs.writeFile(GoldenPath, Got)
			continue
		end

		if not fs.isFile(GoldenPath) then
			ErrorPrint(
				`No golden for {Stem}/{Basename}. Run `
					.. `"lune run Test --yes --update-goldens" and commit the result.`
			)
		end

		local Expected = fs.readFile(GoldenPath)
		if Expected ~= Got then
			ErrorPrint(
				`Generated output for {Stem}/{Basename} no longer matches its golden.{Diff(Expected, Got)}\n`
					.. `If the change is intended, rerun with --update-goldens and review the diff.`
			)
		end
	end
end

--- Compiles every schema, verifies the goldens and the diagnostics, and leaves the generated
--- modules on disk for the specs to load. Does nothing when `--no-compile` was passed.
local function Prepare()
	if ShouldCompile() then
		PrettyPrint("blue", "Clearing Network folder...")
		if fs.isDir("../Network") then
			fs.removeDir("../Network")
			fs.writeDir("../Network")
			OkPrint(`Cleared Network folder.`)
		end

		PrettyPrint("blue", "Compiling source files...")
		for _, File in Sources do
			local Metadata = fs.metadata(`./Sources/{File}`)
			if Metadata.kind ~= "file" then
				continue
			end

			local Path = `../../test/Sources/{File}`
			PrettyPrint("cyan", `Compiling: {File}...`, true)
			local Result = process.exec("lune", { "run", Compiler, Path, "--", "--yes" }, { cwd = "../src/CLI" })
			if not Result.ok then
				ErrorPrint(`{File} failed to compile!\n{Result.stderr}`)
			else
				CaptureGoldens(File)
				OkPrint(`{File} compiled successfully.`)
			end
		end

		PrettyPrint("green", `Successfully compiled {#Sources}/{#Sources} source files!`)

		--> Compiling the same schema twice must produce byte-identical output. Nothing downstream can
		--> diff a build against the last one if the compiler is free to reorder its own output, and the
		--> golden check above would turn into noise the first time something introduced a hash order or
		--> a random identifier.
		PrettyPrint("blue", "Checking output determinism...")
		local Before = {}
		for _, Basename in GetOutputs(fs.readFile("./Sources/Test.blink")) do
			Before[Basename] = fs.readFile(`../Network/{Basename}`)
		end

		local Repeat = process.exec(
			"lune",
			{ "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" },
			{ cwd = "../src/CLI" }
		)
		if not Repeat.ok then
			ErrorPrint(`Test.blink failed to recompile!\n{Repeat.stderr}`)
		end

		for Basename, Expected in Before do
			local Got = fs.readFile(`../Network/{Basename}`)
			if Expected ~= Got then
				ErrorPrint(`Recompiling Test.blink produced different output for {Basename}.{Diff(Expected, Got)}`)
			end
		end

		OkPrint("Output is deterministic across recompiles.")

		--> Schemas that must NOT compile, plus the ones that must compile while warning. Until this
		--> existed the suite could only prove that a VALID schema works; a diagnostic that stopped
		--> firing -- or fired with the wrong code -- broke nothing that anyone would notice.
		--> Each file states what it expects in its first line: `-- expect E3008`.
		PrettyPrint("blue", "Checking diagnostics...")
		for _, File in fs.readDir("./Sources/Invalid") do
			local Path = `./Sources/Invalid/{File}`
			if fs.metadata(Path).kind ~= "file" then
				continue
			end

			local Expectation = string.match(fs.readFile(Path), "^%-%-%s*expect%s+([EW]%d+)")
			if not Expectation then
				ErrorPrint(`{File} is missing its "-- expect <code>" header.`)
			end

			local Result = process.exec(
				"lune",
				{ "run", Compiler, `../../test/Sources/Invalid/{File}`, "--", "--yes", "--compact" },
				{ cwd = "../src/CLI" }
			)

			local Output = `{Result.stdout}{Result.stderr}`
			if not string.find(Output, `[{Expectation}]`, 1, true) then
				ErrorPrint(`{File} was expected to report {Expectation}. Got:\n{Output}`)
			end

			--> An error has to stop the compile and a warning has to not. Checking the code alone would
			--> pass a "warning" that quietly aborted the build.
			if string.sub(Expectation :: string, 1, 1) == "E" then
				if Result.ok then
					ErrorPrint(`{File} reported {Expectation} but still compiled successfully.`)
				end
			elseif not Result.ok then
				ErrorPrint(`{File} warns with {Expectation} but failed to compile. Got:\n{Output}`)
			end

			OkPrint(`{File} reports {Expectation}.`)
		end
	end
end

return {
	Prepare = Prepare,

	--> The CLI specs drive the compiler directly to check its argument handling, so they need the
	--> same entry point and fixture this module compiles with.
	Compiler = Compiler,
	TestSchema = COMPILE_TEST_FILE,
	OkPrint = OkPrint,
	ErrorPrint = ErrorPrint,
	PrettyPrint = PrettyPrint,
	HasArgument = HasArgument,
}
