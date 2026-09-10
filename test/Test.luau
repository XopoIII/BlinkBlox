--!strict
local Format = require("../src/Modules/Format")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
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

	local Repeat = process.exec("lune", { "run", Compiler, COMPILE_TEST_FILE, "--", "--yes" }, { cwd = "../src/CLI" })
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

local Shared = require("./Shared")
local BaseEnvironment = Shared.GetEnvironment()
local ClientEnvironment = require("./Client")
local ServerEnvironment = require("./Server")

local function MockTypeof(a: any)
	local TypeofA = typeof(a)
	if TypeofA == "table" and a.__typeof then
		return a.__typeof
	end

	return TypeofA
end

local function MockRequire(Path: string, Environment)
	local Source = fs.readFile(Path)
	local Bytecode = luau.compile(Source, {
		optimizationLevel = 1,
		debugLevel = 2,
	})

	Environment._G = {}
	Environment.os = Shared.Os
	Environment.task = task
	Environment.typeof = MockTypeof
	Environment.require = function()
		error("require is not supported")
	end

	local Execute = luau.load(Bytecode, {
		debugName = Path,
		environment = Environment,
	})

	return Execute()
end

local Client: typeof(require("../Network/Client")) = MockRequire("../Network/Client.luau", {
	game = ClientEnvironment.game,
	Color3 = ClientEnvironment.Color3,
	DateTime = ClientEnvironment.DateTime,
	BrickColor = ClientEnvironment.BrickColor,
})

local Server: typeof(require("../Network/Server")) = MockRequire("../Network/Server.luau", {
	game = ServerEnvironment.game,
	Color3 = ServerEnvironment.Color3,
	DateTime = ServerEnvironment.DateTime,
	BrickColor = ServerEnvironment.BrickColor,
})

--> Helper functions
local function GetFlags(Amount: number): { [string]: boolean }
	local Flags = {}
	for Index = 1, Amount do
		Flags[`F{Index}`] = (math.random(1, 2) == 2)
	end
	return Flags
end

local function Fail(Name: string, Expect: any, Got: any)
	ErrorPrint(`Failed "{Name}"\nExpected: {Format(Expect)}\nGot: {Format(Got)}.`)
end

local function Equals(a: any, b: any)
	local Cyclic = {}
	local function Compare(Left: any, Right: any)
		local TypeA = type(Left)
		local TypeB = type(Right)

		if TypeA ~= TypeB then
			return false
		end

		if TypeA == "table" then
			if Cyclic[Left] then
				return Cyclic[Left] == Right
			end

			Cyclic[Left] = Right

			local KeysB = {}
			local TableKeysB = {}

			for Key in Right do
				if type(Key) == "table" then
					table.insert(TableKeysB, Key)
				end

				KeysB[Key] = true
			end

			for KeyA, ValueA in pairs(Left) do
				local ValueB = Right[KeyA]
				if type(KeyA) == "table" then
					local Match = false
					for Index, Key in TableKeysB do
						if Equals(KeyA, Key) and Compare(ValueA, Right[Key]) then
							Match = true
							KeysB[Key] = nil
							table.remove(TableKeysB, Index)
							break
						end
					end

					if Match == false then
						return false
					end
				else
					if ValueB == nil then
						return false
					end

					KeysB[KeyA] = nil

					if not Compare(ValueA, ValueB) then
						return false
					end
				end
			end

			if next(KeysB) then
				return false
			end

			return true
		elseif TypeA == "buffer" then
			return buffer.tostring(Left) == buffer.tostring(Right)
		end

		return Left == Right
	end

	return Compare(a, b)
end

local function FireAndFail(Name: string, OutgoingEvent: any, IncomingEvent: any, Data: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	local Success = pcall(function()
		if OutgoingEvent.FireAll then
			OutgoingEvent.FireAll(Data)
		else
			OutgoingEvent.Fire(Data)
		end
	end)

	if not Success then
		OkPrint(`Event "{Name}" passed!`)
		return
	end

	--> Wait for replication
	task.wait(1 / 30)

	if Result ~= nil then
		ErrorPrint(`Failed "{Name}", expected it to fail, got "{Result}" instead.`)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpect(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: any,
	Return: boolean?,
	YieldFor: number?
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: unknown
	ServerFunction.On(function(Player, Recieve: any)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = Recieve
		if not Return then
			error("Expects fail")
		end

		if YieldFor then
			task.wait(YieldFor)
		end

		return Recieve
	end)

	local Success, Result = pcall(function()
		return ClientFunction.Invoke(Data)
	end)

	if not Return and Success then
		ErrorPrint(`Expected {Name} to encounter an error but it succeeded.`)
	elseif not Success and Return then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Result}.`)
	elseif Success and Return then
		if ServerRecieve ~= Data then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(Result, Data) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {Result} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function QueueAndExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	if OutgoingEvent.FireAll then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Let it sit in queue
	task.wait(0.5)

	local Disconnect = IncomingEvent.On(function(First, Second)
		Result = if Second ~= nil then Second else First
	end)

	--> Wait for queue to empty
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectAll(Name: string, OutgoingEvent: any, IncomingEvent: any, Values: { any })
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Events = 0
	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(First, Second)
		local Value = (if Second ~= nil then Second else First)

		Events += 1
		Results[Events] = Value
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	for Index = 1, table.maxn(Values) do
		Method(Values[Index])
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in Values do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			Fail(Name, Expect, Result)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function FireAllAndExpectAll(
	Name: string,
	Times: number,
	Events: { [string]: { Outgoing: any, Incoming: any, Data: { any } } }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { { unknown } } = {}
	local Disconnects: { () -> () } = {}

	--> Connect to events
	for Index, Event in Events do
		local EventResults = {}
		Results[Index] = EventResults
		table.insert(
			Disconnects,
			Event.Incoming.On(function(...)
				table.insert(EventResults, { ... })
			end)
		)
	end

	--> Fire events
	for _, Event in Events do
		local Outgoing = Event.Outgoing
		local Method = Outgoing.FireAll or Outgoing.Fire
		for _ = 1, Times do
			Method(table.unpack(Event.Data))
		end
	end

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Event in Events do
		local Data = Event.Data
		local EventResults = Results[Index]
		for ResultIndex = 1, Times do
			local Result = EventResults[ResultIndex]
			if not Equals(Data, Result) then
				ErrorPrint(`Failed "{Name}" at {Index}, mismatched value at {ResultIndex}.`)
			end
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectTuple(Name: string, OutgoingEvent: any, IncomingEvent: any, ...: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnect = IncomingEvent.On(function(...)
		Results = { ... }
	end)

	local Method = OutgoingEvent.FireAll or OutgoingEvent.Fire
	Method(...)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, Expect in { ... } do
		local Result = Results[Index]
		if not Equals(Expect, Result) then
			ErrorPrint(`Failed "{Name}", mismatched value at {Index}. Expected {Expect}, got {Result} instead.`)
		end
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function InvokeAndExpectTuple(
	Name: string,
	ClientFunction: any,
	ServerFunction: any,
	Data: { any },
	Return: { any }
)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local ServerRecieve: { unknown }
	ServerFunction.On(function(Player, ...)
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to {Name} to be Player, got {Player} instead.`)
		end

		ServerRecieve = { ... }
		return table.unpack(Return)
	end)

	local ClientRecieve: { unknown }
	local Success, Error = pcall(function()
		ClientRecieve = { ClientFunction.Invoke(table.unpack(Data)) }
	end)

	if not Success then
		ErrorPrint(`Expected {Name} to succeed but it encountered an error, {Error}.`)
	elseif Success and Return then
		if not Equals(ServerRecieve, Data) then
			ErrorPrint(`Expected server {Name} to recieve {Data}, got {ServerRecieve} instead.`)
		end

		if not Equals(ClientRecieve, Return) then
			ErrorPrint(`Expected client {Name} to recieve {Data}, got {ClientRecieve} instead.`)
		end
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireManyAndExpectMany(Name: string, Count: number, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Results: { unknown } = {}
	local Disconnects: { () -> () } = {}

	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	for _ = 1, Count do
		table.insert(
			Disconnects,
			IncomingEvent.On(function(First, Second)
				local Value: unknown
				if IsServerRecieving then
					if tostring(First) ~= "Player" then
						ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
					end

					Value = Second
				else
					Value = First
				end

				table.insert(Results, Value)
			end)
		)
	end

	if IsServerSending then
		OutgoingEvent.FireAll(Expect)
	else
		OutgoingEvent.Fire(Expect)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if #Results ~= Count then
		ErrorPrint(`Failed "{Name}", expected to recieve {Count} events, got {#Results} instead.`)
	end

	for _, Result in Results do
		if not Equals(Result, Expect) then
			Fail(Name, Expect, Result)
		end
	end

	for _, Disconnect in Disconnects do
		Disconnect()
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndPollExpect(Name: string, OutgoingEvent: any, IncomingEvent: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result = "this is wrong"
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)
	local FireEvent = IsServerSending and OutgoingEvent.FireAll or OutgoingEvent.Fire

	FireEvent(Expect)

	--> Wait for replication
	task.wait(1 / 30)

	for Index, First, Second in IncomingEvent.Iter() do
		if Index ~= 1 then
			ErrorPrint(`Failed "{Name}", expected only 1 event in the queue.`)
		end

		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	OkPrint(`Test "{Name}" passed!`)
end

local function FireAndExpectSeparate(Name: string, OutgoingEvent: any, IncomingEvent: any, Value: any, Expect: any)
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Result: unknown
	local IsServerSending = (OutgoingEvent.FireAll ~= nil)
	local IsServerRecieving = (OutgoingEvent.FireAll == nil)

	local Disconnect = IncomingEvent.On(function(First, Second)
		if IsServerRecieving then
			if tostring(First) ~= "Player" then
				ErrorPrint(`Expected argument #1 to {Name} to be Player, got {First} instead.`)
			end

			Result = Second
		else
			Result = First
		end
	end)

	if IsServerSending then
		OutgoingEvent.FireAll(Value)
	else
		OutgoingEvent.Fire(Value)
	end

	--> Wait for replication
	task.wait(1 / 30)

	if not Equals(Result, Expect) then
		Fail(Name, Expect, Result)
	end

	Disconnect()
	OkPrint(`Test "{Name}" passed!`)
end

local function RunClosure(Name: string, Closure: () -> ())
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Trace: string?
	local Success = xpcall(Closure, function(Error)
		Trace = debug.traceback(`Failed "{Name}": {Error}`, 2)
	end)

	if not Success then
		ErrorPrint(Trace or `Failed "{Name}"`)
	end

	OkPrint(`Test "{Name}" passed!`)

	-- cleanup
	pcall(function()
		Client.StepReplication()
		Server.StepReplication()
	end)
end

--> Tests
local Instance = setmetatable({
	__typeof = "Instance",
	IsA = function(_self)
		return true
	end,
}, {
	__tostring = function()
		return "Instance"
	end,
})

local InstanceNeverIsA = setmetatable({
	__typeof = "Instance",
	ClassName = "Never",
	IsA = function(_self)
		return false
	end,
}, {
	__tostring = function()
		return "Instance (Invalid)"
	end,
})

local Example: Client.Example = {
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
}

PrettyPrint("blue", "Running output tests...")

FireAndExpect("Reliable Server", Server.ReliableServer, Client.ReliableServer, 1)
FireAndExpect("Unreliable Server", Server.UnreliableServer, Client.UnreliableServer, 1)
FireAndExpect("Empty Reliable Server", Server.EmptyEvent, Client.EmptyEvent, nil)
FireAndExpect("Empty Unreliable Server", Server.EmptyUnreliableEvent, Client.EmptyUnreliableEvent, nil)

FireAndExpect("Reliable Client", Client.ReliableClient, Server.ReliableClient, 1)
FireAndExpect("Unreliable Client", Client.UnreliableClient, Server.UnreliableClient, 1)
FireAndExpect("Empty Reliable Client", Client.ClientEmptyEvent, Server.ClientEmptyEvent, nil)
FireAndExpect("Empty Unreliable Client", Client.ClientEmptyUnreliableEvent, Server.ClientEmptyUnreliableEvent, nil)

FireManyAndExpectMany("Many Reliable Sync Server", 8, Server.ManyReliableSync, Client.ManyReliableSync, 1)
FireManyAndExpectMany("Many Reliable Async Server", 8, Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
FireManyAndExpectMany("Many Unreliable Sync Server", 8, Server.ManyUnreliableSync, Client.ManyUnreliableSync, 1)
FireManyAndExpectMany("Many Unreliable Async Server", 8, Server.ManyUnreliableAsync, Client.ManyUnreliableAsync, 1)

FireAndExpect("Unknown", Server.Unknown, Client.Unknown, newproxy())
FireAndExpect("Unknown (false)", Server.Unknown, Client.Unknown, false)
FireAndExpectAll("Unknown (nil mixed)", Server.Unknown, Client.Unknown, { "a", nil, "b", nil, nil, nil, "c" })

FireAndExpect(
	"Generic",
	Server.Generic,
	Client.Generic,
	{ Data = 0, Array = { 0 }, Optional = nil, Nested = { Value = 0 } }
)

FireAndExpect("Set 8", Server.Flags8, Client.Flags8, GetFlags(8))
FireAndExpect("Set 16", Server.Flags16, Client.Flags16, GetFlags(16))
FireAndExpect("Set 32", Server.Flags32, Client.Flags32, GetFlags(32))
FireAndExpect("Set >32", Server.Flags33, Client.Flags33, GetFlags(33))

FireAndExpect("Map", Server.MapEvent, Client.MapEvent, { ["string"] = 1 })
FireAndExpect("Map Struct", Server.MapStructEvent, Client.MapStructEvent, { Map = { string = 1 } })
FireAndExpect("Map Complex", Server.MapComplexEvent, Client.MapComplexEvent, { string = table.create(8, 1) })
FireAndExpect("Map Reference", Server.MapReferenceEvent, Client.MapReferenceEvent, { A = "A" })

FireAndExpect("Struct", Server.Reference, Client.Reference, Example)
FireAndExpect("Array", Server.ArrayPrimitive, Client.ArrayPrimitive, { 1, 2, 3, 4, 5, 6, 7, 8 })
FireAndExpect("Optional", Server.OptionalPrimitive, Client.OptionalPrimitive, 1)
FireAndExpect("Optional (nil)", Server.OptionalPrimitive, Client.OptionalPrimitive, nil)

FireAndExpect("Instance Any", Server.InstanceAny, Client.InstanceAny, Instance)
FireAndExpect("Instance Type", Server.InstanceOfType, Client.InstanceOfType, Instance)
FireAndFail("Instance Type (Fail)", Server.InstanceOfType, Client.InstanceOfType, nil)
FireAndExpect("Instance Optional", Server.InstanceOptional, Client.InstanceOptional, Instance)
FireAndExpectSeparate(
	"Instance Optional (nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	Shared.ServerOnlyInstance,
	nil
)

local Array = table.create(8, Example)
FireAndExpect("Reference", Server.Reference, Client.Reference, Example)
FireAndExpect("Referency Array", Server.ReferenceArray, Client.ReferenceArray, Array)
FireAndExpect("Referency Optional", Server.ReferenceOptional, Client.ReferenceOptional, Example)
FireAndExpect("Referency Optional (nil)", Server.ReferenceOptional, Client.ReferenceOptional, nil)

InvokeAndExpect("Remote Function", Client.RemoteFunction, Server.RemoteFunction, 1, true)
InvokeAndExpect("Remote Function (yield)", Client.RemoteFunction, Server.RemoteFunction, 1, true, 1)
InvokeAndExpect("Remote Function (error)", Client.RemoteFunction, Server.RemoteFunction, 1, false)
InvokeAndExpect("Empty Remote Function", Client.EmptyFunction, Server.EmptyFunction, nil, true)
InvokeAndExpect("Unit Remote Function", Client.UnitFunction, Server.UnitFunction, nil, true)

QueueAndExpect("Reliable Queue", Server.ReliableServer, Client.ReliableServer, 1)
QueueAndExpect("Many Reliable Sync Queue", Server.ManyReliableSync, Client.ManyReliableSync, 1)
QueueAndExpect("Many Reliable Async Queue", Server.ManyReliableAsync, Client.ManyReliableAsync, 1)
--QueueAndExpect("Unreliable Queue", Server.UnreliableServer, Client.UnreliableServer, 1)

FireAndFail("Invalid Instance Any", Server.InstanceAny, Client.InstanceAny, true)
FireAndFail("Invalid Instance Type", Server.InstanceOfType, Client.InstanceOfType, InstanceNeverIsA)

FireAndExpectAll("Correct order", Server.ReliableServer, Client.ReliableServer, { 1, 2, 3, 4 })
FireAndExpectAll(
	"Multiple instances (nil and non nil)",
	Server.InstanceOptional,
	Client.InstanceOptional,
	{ nil, Instance, nil, Instance, Instance }
)

FireAndExpectAll("Many primitive", Server.ReliableServer, Client.ReliableServer, table.create(255, 1))
FireAndExpectAll("Many structs", Server.Reference, Client.Reference, table.create(255, Example))

FireAndExpectTuple(
	"Reliable Tuple",
	Server.Tuple,
	Client.Tuple,
	255,
	"A",
	65535,
	Instance,
	Instance,
	table.create(8, 0)
)
FireAndExpectTuple(
	"Unreliable Tuple",
	Server.TupleUnreliable,
	Client.TupleUnreliable,
	255,
	"A",
	65535,
	Instance,
	Instance
)
InvokeAndExpectTuple(
	"Function Tuple",
	Client.TupleFunction,
	Server.TupleFunction,
	{ 255, "A", 65535, Instance, Instance },
	{ Instance, Instance, 65535, "A", 255 }
)

FireAllAndExpectAll("Many events", 32, {
	Reliable = {
		Data = { 0 },
		Outgoing = Server.ReliableServer,
		Incoming = Client.ReliableServer,
	},
	Unreliable = {
		Data = { 0 },
		Outgoing = Server.UnreliableServer,
		Incoming = Client.UnreliableServer,
	},
	Reference = {
		Data = { Example },
		Outgoing = Server.Reference,
		Incoming = Client.Reference,
	},
	ReliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance, table.create(8, 0) },
		Outgoing = Server.Tuple,
		Incoming = Client.Tuple,
	},
	UnreliableTuple = {
		Data = { 255, "A", 65535, Instance, Instance },
		Outgoing = Server.TupleUnreliable,
		Incoming = Client.TupleUnreliable,
	},
})

FireAndExpect("TagEnum Join", Server.PlayerEvent, Client.PlayerEvent, { Type = "Join", Name = "Player", UserId = 5 })
FireAndExpect("TagEnum Chat", Server.PlayerEvent, Client.PlayerEvent, { Type = "Chat", UserId = 5, Message = "Hello" })
FireAndExpect("TagEnum Leave", Server.PlayerEvent, Client.PlayerEvent, { Type = "Leave", UserId = 5 })

RunClosure("Color3", function()
	local Color = BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

	local Serialized = Server.Color.Write(Color)
	local Deserialized = Server.Color.Read(Serialized)

	assert(Color.R == Deserialized.R, `Expected {Color.R}, got {Deserialized.R}`)
	assert(Color.G == Deserialized.G, `Expected {Color.G}, got {Deserialized.G}`)
	assert(Color.B == Deserialized.B, `Expected {Color.B}, got {Deserialized.B}`)
end)

RunClosure("Color3 Array", function()
	local Colors = {}
	for _ = 1, 32 do
		table.insert(
			Colors,
			BaseEnvironment.Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))
		)
	end

	local Serialized = Server.ColorArray.Write(Colors)
	local Deserialized = Server.ColorArray.Read(Serialized)

	assert(#Colors == #Deserialized, `Expected {#Colors} elements`)

	for Index, Got in Deserialized do
		local Expected = Colors[Index]
		assert(Expected.R == Got.R, `Expected {Expected.R}, got {Got.R}`)
		assert(Expected.G == Got.G, `Expected {Expected.G}, got {Got.G}`)
		assert(Expected.B == Got.B, `Expected {Expected.B}, got {Got.B}`)
	end
end)

RunClosure("DateTime", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestamp(2 ^ n)
		local Serialized = Server.DateSeconds.Write(DateTime)
		local Deserialized = Server.DateSeconds.Read(Serialized)
		assert(
			DateTime.UnixTimestamp == Deserialized.UnixTimestamp,
			`Expected timestamp {DateTime.UnixTimestamp}, got {Deserialized.UnixTimestamp}`
		)
	end
end)

RunClosure("DateTimeMillis", function()
	for n = 1, 30 do
		local DateTime = BaseEnvironment.DateTime.fromUnixTimestampMillis(2 ^ n)
		local Serialized = Server.DateMilliseconds.Write(DateTime)
		local Deserialized = Server.DateMilliseconds.Read(Serialized)
		assert(
			DateTime.UnixTimestampMillis == Deserialized.UnixTimestampMillis,
			`Expected timestamp {DateTime.UnixTimestampMillis}, got {Deserialized.UnixTimestampMillis}`
		)
	end
end)

RunClosure("BrickColor", function()
	local BrickColor = BaseEnvironment.BrickColor.new(373)
	local Serialized = Server.BrickkColor.Write(BrickColor)
	local Deserialized = Server.BrickkColor.Read(Serialized)

	assert(
		BrickColor.Number == Deserialized.Number,
		`Expected BrickColor number to be {BrickColor.Number}, got {Deserialized.Number}`
	)
end)

RunClosure("Nested Map", function()
	local Map = { string = 1 }
	local Serialized = Server.MapNested.Write({ [Map] = Map })
	local Deserialized = Server.MapNested.Read(Serialized)

	local Elements = 0
	for KeyMap, ValueMap in Deserialized do
		if Elements >= 1 then
			error("Deserialized doesn't match original")
		end

		Elements += 1
		assert(type(KeyMap) == "table", "Deserialized doesn't match original")
		assert(type(ValueMap) == "table", "Deserialized doesn't match original")
		assert(type(KeyMap.string) == "number", "Deserialized doesn't match original")
		assert(type(ValueMap.string) == "number", "Deserialized doesn't match original")
	end
end)

RunClosure("Standalone", function()
	local Original = {
		One = 1,
		Two = 2,
		Three = 3,
		Event = { Type = "Join", Name = "JohnDoe", UserId = 1 },
		Nested = {
			Four = "ABC",
			Five = "DEF",
		},
	}

	local Serialized = Server.Standalone.Write(Original)
	local Deserialized = Server.Standalone.Read(Serialized)

	assert(Equals(Original, Deserialized), "Deserialized doesn't match original")
end)

RunClosure("Disconnect & Queue", function()
	local Expect = 1
	local Events = {
		"ReliableServer",
		"UnreliableServer",
		"ManyReliableSync",
		"ManyReliableAsync",
		"ManyUnreliableSync",
		"ManyUnreliableAsync",
	}

	for _, Event in Events do
		local Outgoing = Server[Event]
		local Incoming = Client[Event]

		local NeverRecieve: never
		Incoming.On(function(Value: never)
			NeverRecieve = Value
		end)()

		local Recieve: typeof(Expect)
		local RecieveDisconnect = Incoming.On(function(Value: typeof(Expect))
			Recieve = Value
		end)

		Outgoing.FireAll(Expect)

		task.wait(0.5)

		if Recieve ~= Expect then
			error(`Failed queue test on {Event}, expected "{Expect}", got "{Recieve}"`)
		end

		if NeverRecieve ~= nil then
			error(`Failed disconnect test on {Event}, disconnected listener still recieving.`)
		end

		RecieveDisconnect()
	end
end)

local Element = { Static = 0, Dynamic = buffer.create(64) }

FireAndExpect("Dynamic Array Data Integrity", Server.DynamicArray, Client.DynamicArray, table.create(12, Element))
FireAndExpect("Dynamic Map Data Integrity", Server.DynamicMap, Client.DynamicMap, table.create(64, Element))

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

local MergeStruct: Server.MergeStruct = {
	Data = 1,
	Field = 0,
	Float16Field = 0,
	Enum = "A",
	Nested = {
		Guh = 1,
		Array = table.create(10, 0),
	},
	AnotherNested = {
		Value = 1,
	},
	Map = {
		[{ 0 }] = 0,
	},
	Struct = {
		Data = 0,
		Array = { 0 },
		Nested = {
			Value = "hi",
		},
	},
}

FireAndPollExpect("Poll Reliable Client", Client.ClientPollEvent, Server.ClientPollEvent, MergeStruct)
FireAndPollExpect("Poll Reliable Server", Server.ServerPollEvent, Client.ServerPollEvent, MergeStruct)
FireAndPollExpect(
	"Poll Unreliable Client",
	Client.ClientUnreliablePollEvent,
	Server.ClientUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect(
	"Poll Unreliable Server",
	Server.ServerUnreliablePollEvent,
	Client.ServerUnreliablePollEvent,
	MergeStruct
)
FireAndPollExpect("Poll Empty Reliable Client", Client.ClientEmptyPollEvent, Server.ClientEmptyPollEvent, nil)
FireAndPollExpect("Poll Empty Reliable Server", Server.ServerEmptyPollEvent, Client.ServerEmptyPollEvent, nil)
FireAndPollExpect(
	"Poll Empty Unreliable Client",
	Client.ClientEmptyUnreliablePollEvent,
	Server.ClientEmptyUnreliablePollEvent,
	nil
)
FireAndPollExpect(
	"Poll Empty Unreliable Server",
	Server.ServerEmptyUnreliablePollEvent,
	Client.ServerEmptyUnreliablePollEvent,
	nil
)

RunClosure("Queue up and poll", function()
	local Expect = 10
	local Results = {
		Client = {},
		Server = {},
	}

	for _ = 1, Expect do
		Client.ClientPollEvent.Fire(MergeStruct)
		Server.ServerPollEvent.FireAll(MergeStruct)
	end

	task.wait(1 / 30)

	for _, Value in Client.ServerPollEvent.Iter() do
		table.insert(Results.Client, Value)
	end

	for _, Player, Value in Server.ClientPollEvent.Iter() do
		if tostring(Player) ~= "Player" then
			ErrorPrint(`Expected argument #1 to be Player, got {Player} instead.`)
		end

		table.insert(Results.Server, Value)
	end

	for _, Context in Results do
		if #Context ~= Expect then
			ErrorPrint(`Expected to poll {Expect} events, got {#Results.Client} instead`)
		end

		for _, Result in Context do
			if not Equals(Result, MergeStruct) then
				Fail("Closure", Expect, Result)
			end
		end
	end
end)

RunClosure("Ranges should be enforced", function()
	do
		local UpperSuccess = pcall(function()
			Client.NegativeRange.Write(11)
		end)

		local LowerSuccess = pcall(function()
			Client.NegativeRange.Write(-6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected integer range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.DecimalRange.Write(10.6)
		end)

		local LowerSuccess = pcall(function()
			Client.DecimalRange.Write(-5.6)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected decimal range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundUpper.Write(2 ^ 53 + 1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundUpper.Write(-1)
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	do
		local UpperSuccess = pcall(function()
			Client.UnboundLower.Write(1)
		end)

		local LowerSuccess = pcall(function()
			Client.UnboundLower.Write(-(2 ^ 53 + 1))
		end)

		if UpperSuccess or LowerSuccess then
			ErrorPrint("Expected unbound upper range to be enforced.")
		end
	end

	Client.ExactRange.Write(0)

	Client.DecimalRange.Write(-5.5)
	Client.DecimalRange.Write(10)

	Client.NegativeRange.Write(-5)
	Client.NegativeRange.Write(10)

	Client.UnboundUpper.Write(0)
	Client.UnboundUpper.Write(16777216)

	Client.UnboundLower.Write(-16777216)
	Client.UnboundLower.Write(0)
end)

RunClosure("Multi Dimensional Array", function()
	local Nested = { { { 1, 2, 3, 4, 5, 6 } } }
	local Serialized = Client.MultiDimensionalArray.Write(Nested)
	local Deserialized = Client.MultiDimensionalArray.Read(Serialized)

	if not Equals(Nested, Deserialized) then
		ErrorPrint(`Expected: {Format(Nested)}, got: {Format(Deserialized)} instead`)
	end
end)

do
	local foo: Client.Issue33_Foo = "One"
	local map: Client.Issue33_Map<number> = { [foo] = 0 }
	local enum: Client.Issue33_Enum<number> = { Tag = "Variant", field = foo }
	local struct: Client.Issue33_Struct<number> = { field = foo }

	FireAndExpectTuple(
		"Generics containing a unit enum value",
		Server.Issue33.Event,
		Client.Issue33.Event,
		map,
		enum,
		struct
	)
end

RunClosure("Static size analysis matches the emitter", function()
	--> src/Modules/Size.luau predicts how many bytes a type occupies; src/Generator/Prefabs.luau
	--> decides it. Nothing links the two, so the analysis can drift out of agreement with the
	--> compiler it describes and the only symptom would be a wrong diagnostic -- either a schema
	--> refused for no reason, or an oversize unreliable event let through.
	-->
	--> Every exported type carries a `.Write` that returns the exact bytes it produced, so the
	--> prediction can simply be checked against reality.
	local Parser = require("../src/Parser")
	local Size = require("../src/Modules/Size")

	local Source = fs.readFile("./Sources/Test.blink")
	local Tree = Parser.new("./Sources/", "Test.blink"):Parse(Source)

	local ByName = {}
	for _, Declaration in Tree.Value.Declarations do
		ByName[Declaration.Name] = Declaration
	end

	local Samples: { { Name: string, Value: any } } = {
		{ Name = "SizeByte", Value = 7 },
		{ Name = "SizeFixedString", Value = "abcdefgh" },
		{ Name = "SizeBoundedString", Value = "hello" },
		{ Name = "SizeBoundedString", Value = "" },
		{ Name = "SizeFixedArray", Value = { 1, 2, 3, 4 } },
		{ Name = "SizeBoundedArray", Value = { 1, 2, 3 } },
		{ Name = "SizeBoundedArray", Value = {} },
		{ Name = "SizeOptionalByte", Value = nil },
		{ Name = "SizeOptionalByte", Value = 5 },
		{ Name = "SizeStruct", Value = { A = 1, B = true, C = 2 } },
		{ Name = "SizeEnum", Value = "B" },
		{ Name = "SizeFlags", Value = { F1 = true, F3 = true } },
		{ Name = "SizeMap", Value = { [1] = 2, [3] = 4 } },
		{ Name = "Buffer", Value = buffer.create(10) },
		{ Name = "ExactBuffer", Value = buffer.create(9) },
		{ Name = "BoundedBuffer", Value = buffer.create(256) },
		{ Name = "MultiDimensionalArray", Value = { { { 1, 2 }, { 3 } }, { { 4 } } } },
	}

	for _, Sample in Samples do
		local Declaration = ByName[Sample.Name]
		if not Declaration then
			ErrorPrint(`Failed "Static size analysis": Test.blink has no exported type "{Sample.Name}".`)
		end

		local Measured = Size.Sealed(Declaration)
		local Length = buffer.len(Client[Sample.Name].Write(Sample.Value))

		if Length < Measured.Min or Length > Measured.Max then
			ErrorPrint(
				`Failed "Static size analysis": {Sample.Name} serialised to {Length} bytes, `
					.. `outside the predicted {Measured.Min}..{Measured.Max}.`
			)
		end
	end
end)

RunClosure("Export buffer trimming", function()
	local Buffer = Client.Byte.Write(0)
	if buffer.len(Buffer) ~= 1 then
		ErrorPrint(`Expected buffer to be trimmed to 1 byte`)
	end
end)

do
	local enum: Client.Indexers_TestEnums = "b b"
	local flags: Client.Indexers_TestFlags = { ["a a"] = true }
	local struct: Client.Indexers_TestStruct = {
		["z z"] = 0,
		["1 1"] = 1,
		["2 2"] = 2,
		["3 3"] = 3,
	}
	local tagged: Client.Indexers_TestTaggedEnums = {
		Type = "c c",
		Test = 1,
	}

	FireAndExpectTuple("Indexers", Server.Indexers.TestEvent, Client.Indexers.TestEvent, struct, flags, enum, tagged)
end

RunClosure("Buffer (Default, Fixed, Bounded)", function()
	local ExactBuffer = buffer.create(9)
	local BoundedBuffer = buffer.create(256)

	-- write some random bytes
	for offset = 0, 8, 4 do
		buffer.writeu8(ExactBuffer, offset, math.random(0, 2 ^ 30))
	end

	for offset = 0, 255, 4 do
		buffer.writeu8(BoundedBuffer, offset, math.random(0, 2 ^ 30))
	end

	-- test serdes
	do
		local Serialised = Client.Buffer.Write(BoundedBuffer)
		local Deserialised = Client.Buffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Default buffer serdes failed`)
	end

	do
		local Serialised = Client.ExactBuffer.Write(ExactBuffer)
		local Deserialised = Client.ExactBuffer.Read(Serialised)
		assert(Equals(ExactBuffer, Deserialised), `Fixed buffer serdes failed`)
	end

	do
		local Serialised = Client.BoundedBuffer.Write(BoundedBuffer)
		local Deserialised = Client.BoundedBuffer.Read(Serialised)
		assert(Equals(BoundedBuffer, Deserialised), `Bounded buffer serdes failed`)
	end
end)

RunClosure("Firing at a player who left does not resurrect their buffer", function()
	--> Upstream issue #84. A remote function's listener may yield, and the player can leave while it
	--> is suspended. PlayerRemoving clears their PlayersMap entry, but the resumed listener then
	--> wrote it straight back -- and nothing removes it a second time, so StepReplication allocated
	--> a buffer and fired a remote at a player who was gone on every Heartbeat, for ever.
	local Received = 0
	local Disconnect = Client.ReliableServer.On(function()
		Received += 1
	end)

	--> The player leaves.
	Shared.SetPlayerInGame(false)
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	--> This is the write a resumed listener performs. It must be dropped, not stored.
	Server.ReliableServer.Fire(Shared.Player, 1)

	--> Long enough for several Heartbeats, so a resurrected entry would replicate at least once.
	task.wait(0.5)

	Disconnect()
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(
			`Failed "Firing at a player who left": the client received {Received} event(s) after the player left.`
		)
	end

	--> And the map must be usable again for a player who is present.
	local ReceivedAfter = 0
	local DisconnectAfter = Client.ReliableServer.On(function()
		ReceivedAfter += 1
	end)

	Server.ReliableServer.Fire(Shared.Player, 1)
	task.wait(0.5)
	DisconnectAfter()

	if ReceivedAfter == 0 then
		ErrorPrint(`Failed "Firing at a player who left": a present player stopped receiving events.`)
	end
end)

RunClosure("Inbound packets are bounded", function()
	--> Upstream issue #45. The server parses a client's buffer in an unbounded loop, one event per
	--> iteration, so `buffer.create(1000000)` used to buy a million listener dispatches inside one
	--> remote callback. Three limits now bound that, and each is checked here.
	local MaxEventsPerPacket = 64

	--> 1. An oversized buffer is refused outright, before anything is parsed.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(64 * 1024), {})

		task.wait(0.2)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": an oversized packet was parsed ({Received} events).`)
		end
	end

	--> 2. A packet carrying more events than the cap is truncated, not parsed whole. Sent through
	--> the real client API so this exercises the same path a legitimate flood would take.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		for _ = 1, MaxEventsPerPacket * 2 do
			Client.ReliableClient.Fire(1)
		end

		task.wait(0.5)
		Disconnect()

		if Received > MaxEventsPerPacket then
			ErrorPrint(
				`Failed "Inbound packets are bounded": {Received} events decoded from one packet, cap is {MaxEventsPerPacket}.`
			)
		end

		if Received == 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": the cap swallowed legitimate traffic entirely.`)
		end
	end

	--> 3. The guard's shape, asserted against the emitted code.
	-->
	--> The remaining protections cannot be observed through these mocks: `Signal:Fire` dispatches via
	--> `task.spawn`, so a throw inside the remote handler lands in another thread and never reaches a
	--> pcall here — a behavioural test would pass whether or not the guard exists, which is worse
	--> than no test. What matters is that the generator still emits them, and that is checkable.
	-->
	--> A TRUNCATED packet is why the pcall is there: one byte tagging an event that carries data
	--> makes the reader run off the end of the buffer, and `Read` advances the cursor with no bounds
	--> check. That packet is SMALLER than a legitimate one, so no size cap can catch it.
	do
		local Source = fs.readFile("../Network/Server.luau")
		local Required = {
			["argument type check"] = `if typeof(Buffer) ~= "buffer" or type(Instances) ~= "table" then`,
			["departed player stops the loop"] = "Player.Parent ~= nil",
			["reliable remote class check"] = `assert(Reliable:IsA("RemoteEvent")`,
			["unreliable remote class check"] = `assert(Unreliable:IsA("UnreliableRemoteEvent")`,
			["oversized packet check"] = "if buffer.len(Buffer) >",
			["instance count check"] = "if #Instances >",
			["decoded event counter"] = "DecodedEvents += 1",
			["decode pcall"] = "local Parsed = pcall(function()",
			["decode failure stops the packet"] = "if not Parsed then break end",
			["unknown event id stops the packet"] = `error("[Blink]: Unknown event index.")`,
		}

		for Name, Fragment in Required do
			if not string.find(Source, Fragment, 1, true) then
				ErrorPrint(`Failed "Inbound packets are bounded": generated server code has no {Name}.`)
			end
		end
	end

	--> 4. Ordinary traffic still arrives untouched — a cap that breaks the normal path is worse than
	--> the hole it closes.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		Client.ReliableClient.Fire(1)
		task.wait(0.3)
		Disconnect()

		if Received ~= 1 then
			ErrorPrint(`Failed "Inbound packets are bounded": a single legitimate event arrived {Received} time(s).`)
		end
	end

	--> 5. Arguments of the wrong type are dropped rather than dispatched. A client picks what it
	--> passes to FireServer; the generated signature is a promise it never made.
	do
		local Received = 0
		local Disconnect = Server.ReliableClient.On(function()
			Received += 1
		end)

		local Remote = ServerEnvironment.Instances.BLINK_RELIABLE_REMOTE
		Remote.OnServerEvent:Fire(Shared.Player, "not a buffer", {})
		Remote.OnServerEvent:Fire(Shared.Player, buffer.create(8), "not a table")
		Remote.OnServerEvent:Fire(Shared.Player)

		task.wait(0.3)
		Disconnect()

		if Received ~= 0 then
			ErrorPrint(`Failed "Inbound packets are bounded": malformed arguments dispatched {Received} event(s).`)
		end
	end
end)

RunClosure("Edit mode stubs keep the shape of the real API", function()
	--> Upstream issue #81. With `RunService:IsRunning()` false — edit mode, and therefore every
	--> Roblox story framework — the module returns a frozen stub table instead of touching remotes.
	--> A stub whose entries have the wrong SHAPE does not degrade quietly, it raises: `On` returning
	--> nil breaks `local Disconnect = ...On(...)`, and `Iter` returning nil breaks `for ... in`.
	local StubEnvironment = Shared.GetEnvironment()
	StubEnvironment.Services.RunService.IsRunning = function()
		return false
	end

	local Stub = MockRequire("../Network/Server.luau", {
		game = StubEnvironment.game,
		Color3 = StubEnvironment.Color3,
		DateTime = StubEnvironment.DateTime,
		BrickColor = StubEnvironment.BrickColor,
	})

	local Disconnect = Stub.ReliableClient.On(function() end)
	if type(Disconnect) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": On returned {type(Disconnect)}, expected a disconnect function.`)
	end
	Disconnect()

	for _ in Stub.ClientPollEvent.Iter() do
		ErrorPrint(`Failed "Edit mode stubs": Iter yielded a value in edit mode.`)
	end

	if type(Stub.StepReplication) ~= "function" then
		ErrorPrint(`Failed "Edit mode stubs": StepReplication is {type(Stub.StepReplication)}, expected a function.`)
	end
	Stub.StepReplication()

	--> Firing is a no-op rather than an error: a story that pushes state outward should not crash.
	Stub.ReliableServer.FireAll(1)
end)

RunClosure("Predict delivers to local listeners", function()
	--> Upstream issue #59. Predict hands an event to this side's own listeners without touching a
	--> remote, so receiving code can be driven directly from a test or a story.
	local Received: number?
	local Disconnect = Server.ReliableClient.On(function(_Player, Value)
		Received = Value
	end)

	Server.ReliableClient.Predict(Shared.Player, 42)

	if Received ~= 42 then
		ErrorPrint(`Failed "Predict": listener received {tostring(Received)}, expected 42.`)
	end

	Disconnect()

	--> It mirrors the receive path rather than only calling listeners: with none attached the event
	--> waits in the queue, exactly as a networked one would, and arrives when a listener connects.
	Server.ReliableClient.Predict(Shared.Player, 7)

	local Queued: number?
	local DisconnectQueued = Server.ReliableClient.On(function(_Player, Value)
		Queued = Value
	end)

	if Queued ~= 7 then
		ErrorPrint(`Failed "Predict": a queued event arrived as {tostring(Queued)}, expected 7.`)
	end

	DisconnectQueued()

	--> And it stays local: nothing may reach the wire.
	local Delivered = 0
	local Watch = Shared.Bridge:Connect(function()
		Delivered += 1
	end)

	Server.ReliableClient.Predict(Shared.Player, 1)
	task.wait(0.2)
	Watch.Disconnect()

	if Delivered ~= 0 then
		ErrorPrint(`Failed "Predict": {Delivered} packet(s) went over the wire.`)
	end
end)

RunClosure("Rate limiting", function()
	--> Neither zap nor upstream's rewrite has this, and it is the axis the packet caps cannot cover:
	--> MaxEventsPerPacket bounds one packet, while 200 well-formed packets a second pass every check
	--> there is. The bucket bounds events per second, per player, per event.
	-->
	--> The clock is the mock one from Shared, so "a second passes" is an exact statement rather than
	--> a race with the machine running the suite.

	--> Two things have to be settled before anything is counted.
	-->
	--> Earlier tests reach this event with raw buffers, and events that arrive with no listener bound
	--> are QUEUED and replayed the moment one is -- so attaching a listener and immediately counting
	--> credits this test with traffic it never sent. Attach first, let the replay land, then zero.
	-->
	--> The bucket those earlier events already spent from is cleared through PlayerRemoving, which
	--> dispatches via task.spawn, so it needs a moment of its own.
	ServerEnvironment.Services.Players.PlayerRemoving:Fire(Shared.Player)

	local Received = 0
	local Disconnect = Server.RateLimited.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> An event with Rate 5 and Burst 10: ten arrive at once, the rest are refused.
	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)

	if Received ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Received} of 15 events arrived, expected the burst of 10.`)
	end

	--> One second of clock buys exactly five more tokens.
	Shared.AdvanceClock(1)

	for _ = 1, 15 do
		Client.RateLimited.Fire(1)
	end

	task.wait(0.4)
	Disconnect()

	if Received ~= 15 then
		ErrorPrint(`Failed "Rate limiting": {Received - 10} events arrived after a second, expected 5.`)
	end

	--> The polling path enqueues instead of dispatching, and is gated in the same place.
	Shared.AdvanceClock(10)

	for _ = 1, 15 do
		Client.RateLimitedPoll.Fire(1)
	end

	task.wait(0.4)

	local Polled = 0
	for _ in Server.RateLimitedPoll.Iter() do
		Polled += 1
	end

	if Polled ~= 10 then
		ErrorPrint(`Failed "Rate limiting": {Polled} of 15 polled events were queued, expected 10.`)
	end

	--> A refused INVOCATION still has to be answered. The caller is suspended with no timeout, so a
	--> silently dropped call would hang that coroutine until its slot was reused by an unrelated
	--> call -- which would then resume the wrong thread.
	Shared.AdvanceClock(10)
	Server.RateLimitedCall.On(function(_Player, Value)
		return Value
	end)

	local Succeeded, Refused = 0, 0
	for _ = 1, 4 do
		local Ok = pcall(function()
			return Client.RateLimitedCall.Invoke(1)
		end)

		if Ok then
			Succeeded += 1
		else
			Refused += 1
		end
	end

	if Succeeded ~= 2 or Refused ~= 2 then
		ErrorPrint(
			`Failed "Rate limiting": {Succeeded} invocations succeeded and {Refused} were refused, expected 2 and 2.`
		)
	end
end)

RunClosure("Invocation slots are recycled", function()
	--> The old allocator was a counter that wrapped at 255 and released a slot only on the error
	--> path, never on success. Two calls in flight across the wrap collided: the reused id was still
	--> occupied, so the collision check refused a legitimate call. A bitset hands out the first free
	--> slot instead, and a reply gives it straight back.

	Server.RemoteFunction.On(function(_Player, Value)
		task.wait(0.4)
		return Value
	end)

	local Completed, Refused = 0, 0
	for _ = 1, 40 do
		task.spawn(function()
			local Ok = pcall(function()
				return Client.RemoteFunction.Invoke(1)
			end)

			if Ok then
				Completed += 1
			else
				Refused += 1
			end
		end)
	end

	task.wait(1.5)

	--> Thirty-two slots exist, so eight of the forty must be turned away with an error rather than
	--> silently handed an id that belongs to another call.
	if Completed ~= 32 then
		ErrorPrint(`Failed "Invocation slots": {Completed} of 40 concurrent calls completed, expected 32.`)
	end

	if Refused ~= 8 then
		ErrorPrint(`Failed "Invocation slots": {Refused} calls were refused, expected 8.`)
	end

	--> And the slots came back: a call after the storm must simply work.
	local Success = pcall(function()
		return Client.RemoteFunction.Invoke(1)
	end)

	if not Success then
		ErrorPrint(`Failed "Invocation slots": a call after the burst was refused, so slots leaked.`)
	end
end)

RunClosure("Oversized unreliable payloads are dropped, not sent", function()
	--> Roblox drops an unreliable payload past ~900 bytes silently. The compiler refuses schemas that
	--> can never fit and warns about the ones that might not, but a bounded schema can still overflow
	--> at runtime -- a string longer than the game assumed -- and that packet would vanish with
	--> nobody told which event lost it.
	local Received = 0
	local Disconnect = Server.UnreliableOversize.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	--> Well under the limit: ordinary traffic must be untouched.
	Client.UnreliableOversize.Fire(string.rep("a", 32))
	task.wait(0.3)

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": a small payload arrived {Received} time(s), expected 1.`)
	end

	--> Past the limit: dropped at the send, with a warning naming the event.
	Client.UnreliableOversize.Fire(string.rep("a", 2000))
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Oversized unreliable": an oversized payload was sent anyway.`)
	end
end)

RunClosure("Decoding stops when the player leaves", function()
	--> Every listener that runs past this point is handed a Player already detached from the
	--> DataModel, and anything it does with them -- a leaderstats write, a save -- is work aimed at
	--> nobody. The loop condition now checks, so the rest of that packet is not decoded.
	local Received = 0
	local Disconnect = Server.ReliableClient.On(function()
		Received += 1
	end)

	task.wait(0.2)
	Received = 0

	Shared.SetPlayerInGame(false)
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Shared.SetPlayerInGame(true)

	if Received ~= 0 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": {Received} event(s) were still dispatched.`)
	end

	--> And a present player is unaffected -- a guard that broke the normal path would be worse than
	--> the case it closes.
	Client.ReliableClient.Fire(1)
	task.wait(0.3)
	Disconnect()

	if Received ~= 1 then
		ErrorPrint(`Failed "Decoding stops when the player leaves": a present player received {Received}, expected 1.`)
	end
end)

RunClosure("Offset-encoded lengths", function()
	--> A length is written relative to the declared minimum, in the smallest numeral that holds the
	--> SPAN. `u8[300..400]` has a hundred possible lengths, so one byte carries it -- where encoding
	--> 400 directly would have needed two.

	local Bounded = table.create(300, 7)
	local ArrayBuffer = Client.OffsetArray.Write(Bounded)

	if buffer.len(ArrayBuffer) ~= 301 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 300-element array took {buffer.len(ArrayBuffer)} bytes, expected 301.`
		)
	end

	if not Equals(Client.OffsetArray.Read(ArrayBuffer), Bounded) then
		ErrorPrint(`Failed "Offset-encoded lengths": the array did not survive the round trip.`)
	end

	--> The far end of the range must round-trip too: that is where the offset is largest.
	local Full = table.create(400, 3)
	if not Equals(Client.OffsetArray.Read(Client.OffsetArray.Write(Full)), Full) then
		ErrorPrint(`Failed "Offset-encoded lengths": a full-length array did not survive the round trip.`)
	end

	local Text = string.rep("a", 320)
	local TextBuffer = Client.OffsetString.Write(Text)

	if buffer.len(TextBuffer) ~= 321 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 320-character string took {buffer.len(TextBuffer)} bytes, expected 321.`
		)
	end

	if Client.OffsetString.Read(TextBuffer) ~= Text then
		ErrorPrint(`Failed "Offset-encoded lengths": the string did not survive the round trip.`)
	end

	local Bytes = buffer.create(350)
	local BytesBuffer = Client.OffsetBuffer.Write(Bytes)

	if buffer.len(BytesBuffer) ~= 351 then
		ErrorPrint(
			`Failed "Offset-encoded lengths": a 350-byte buffer took {buffer.len(BytesBuffer)} bytes, expected 351.`
		)
	end

	--> Below the minimum the offset would go negative and wrap. It has to be refused by the SENDER,
	--> not discovered by the receiver as an unattributable length violation.
	local Refused = pcall(function()
		return Client.OffsetArray.Write(table.create(10, 1))
	end)

	if Refused then
		ErrorPrint(`Failed "Offset-encoded lengths": an array below the minimum was encoded anyway.`)
	end
end)

RunClosure("Bit packing", function()
	--> Booleans and optional presence flags take one BIT of a shared byte rather than a byte each.
	--> The numbers that matter are the ones either side of a byte boundary, and the round trip
	--> matters more than the size: a packing that loses a bit is worse than one that saves nothing.

	local function Booleans(Count: number): { [string]: boolean }
		local Value = {}
		for Index = 1, Count do
			--> Alternating rather than uniform, so a mask applied to the wrong bit shows up.
			Value[string.char(64 + Index)] = (Index % 2 == 1)
		end

		return Value
	end

	local Cases = {
		{ Name = "BitsOne", Count = 1, Bytes = 1 },
		{ Name = "BitsSeven", Count = 7, Bytes = 1 },
		{ Name = "BitsEight", Count = 8, Bytes = 1 },
		{ Name = "BitsNine", Count = 9, Bytes = 2 },
		{ Name = "BitsSeventeen", Count = 17, Bytes = 3 },
	}

	for _, Case in Cases do
		local Value = Booleans(Case.Count)
		local Buffer = Client[Case.Name].Write(Value)

		if buffer.len(Buffer) ~= Case.Bytes then
			ErrorPrint(
				`Failed "Bit packing": {Case.Count} booleans serialised to {buffer.len(Buffer)} bytes, `
					.. `expected {Case.Bytes}.`
			)
		end

		if not Equals(Client[Case.Name].Read(Buffer), Value) then
			ErrorPrint(`Failed "Bit packing": {Case.Count} booleans did not survive the round trip.`)
		end
	end

	--> Flags and booleans draw from the same byte, and an absent optional costs its bit and nothing
	--> else: four flags is one byte, plus one byte for the present u8.
	local Mixed = { A = true, B = 7, C = false }
	local MixedBuffer = Client.BitsMixed.Write(Mixed)

	if buffer.len(MixedBuffer) ~= 2 then
		ErrorPrint(`Failed "Bit packing": mixed flags serialised to {buffer.len(MixedBuffer)} bytes, expected 2.`)
	end

	if not Equals(Client.BitsMixed.Read(MixedBuffer), Mixed) then
		ErrorPrint(`Failed "Bit packing": mixed flags and optionals did not survive the round trip.`)
	end

	--> All four optionals absent: one byte of flags, nothing else.
	local Sparse = { A = false, C = true }
	local SparseBuffer = Client.BitsMixed.Write(Sparse)

	if buffer.len(SparseBuffer) ~= 1 then
		ErrorPrint(`Failed "Bit packing": absent optionals cost {buffer.len(SparseBuffer)} bytes, expected 1.`)
	end

	if not Equals(Client.BitsMixed.Read(SparseBuffer), Sparse) then
		ErrorPrint(`Failed "Bit packing": absent optionals did not survive the round trip.`)
	end
end)

PrettyPrint("green", `All tests passed successfully!`)

process.exit(0)
