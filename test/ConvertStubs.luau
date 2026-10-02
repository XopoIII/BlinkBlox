--!strict
--- Specs for the recording stubs: a runtime library's definitions, run against src/Convert/Stubs in
--- the sandbox of src/CLI/Utility/Sandbox.luau, and printed as a draft.
---
--- Held to what test/ConvertZap.luau holds zap to: the draft is the committed golden, it compiles
--- and its modules load, and what the definitions could not say is asked for.
---
--- Each tool is run on the benchmark's own definitions of Scenarios.blink's events, and on a file
--- under test/Sources/Convert written the way a game writes one: the library reached through
--- `game`, a module of the game's own beside it, a listener connected where the packets are defined.
local Assertions = require("./Assertions")
local ByteNet = require("@compiler/Convert/Stubs/ByteNet")
local Harness = require("./Harness")
local Library = require("@compiler/Library")
local Packet = require("@compiler/Convert/Stubs/Packet")
local Print = require("@compiler/Convert/Print")
local QuickNet = require("@compiler/Convert/Stubs/QuickNet")
local Sandbox = require("@compiler/CLI/Utility/Sandbox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

type Case = { Stub: Sandbox.Stub, Golden: string, Path: string }

local CASES: { Case } = {
	{ Stub = ByteNet, Golden = "bytenet/Scenarios", Path = "../benchmark/runtime/rivals/modes/bytenet.luau" },
	{ Stub = ByteNet, Golden = "bytenet/Packets", Path = "./Sources/Convert/ByteNet/Packets.luau" },
	{ Stub = Packet, Golden = "packet/Scenarios", Path = "../benchmark/runtime/rivals/modes/packet.luau" },
	{ Stub = Packet, Golden = "packet/Packets", Path = "./Sources/Convert/Packet/Packets.luau" },
	{ Stub = QuickNet, Golden = "quicknet/Scenarios", Path = "../benchmark/runtime/rivals/modes/quicknet.luau" },
	{ Stub = QuickNet, Golden = "quicknet/Events", Path = "./Sources/Convert/QuickNet/Events.luau" },
}

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

local function Has(Text: string, Part: string): boolean
	return string.find(Text, Part, 1, true) ~= nil
end

--- A definitions file of one spec's own, written where the sandbox can read it.
local function Definitions(Name: string, Source: string): string
	local Path = `../Network/{Name}.luau`
	fs.writeFile(Path, Source)
	return Path
end

for _, Case in CASES do
	RunClosure(`{Case.Golden} converts to its golden, and the draft compiles`, function()
		local Text = Print.Render(Sandbox.Record(Case.Path, Case.Stub))
		Harness.Golden(`./Golden/Convert/{Case.Golden}.blink`, Text)

		local Output = Library.Compile(Text)
		for _, Side in { Output.Server, Output.Client } do
			Check(Case.Golden, (pcall(luau.compile, Side)), "a generated module does not load as Luau")
		end
	end)
end

RunClosure("ByteNet: every packet's direction is asked for, and its reliability is not", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/ByteNet/Packets.luau", ByteNet))
	local List = table.concat(Checklist, "\n")

	Check("Direction", Has(List, "8 event(s) whose direction you must state"), List)
	Check("Reliability", not Has(List, "reliability you must state"), List)
	Check("Unreliable", Has(Text, "Type: Unreliable"), "the unreliable packet came out reliable")
end)

RunClosure("ByteNet: a struct built twice by one function is declared once", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/ByteNet/Packets.luau", ByteNet))
	local _, Declared = string.gsub(Text, "struct Shape1 ", "")

	Check("Shape", Declared == 1 and Has(Text, "Data: Shape1[]") and Has(Text, "item: Shape1"), Text)
	Check("Note", Has(table.concat(Checklist, "\n"), "were named Shape1 onward"), "the naming was not said")
end)

RunClosure("ByteNet: a module beside the definitions is run, and one that is missing is named", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/ByteNet/Packets.luau", ByteNet))

	--> The second namespace takes its name from Constants.luau, required through `script.Parent`.
	Check("Sibling", Has(Text, "scope World {"), Text)
	Check("Missing", Has(table.concat(Checklist, "\n"), "require of Analytics was not followed"), "not named")
end)

RunClosure("ByteNet: a name the stub does not know fails, naming the version it was written for", function()
	local Path = Definitions("ConvertUnknown", 'local ByteNet = require("@pkg/ByteNet")\nreturn ByteNet.uint64\n')
	local Success, Failure = pcall(Sandbox.Record, Path, ByteNet)

	Check("Refusal", not Success, "an unknown type was answered")
	Check(
		"Reason",
		Has(tostring(Failure), "ByteNet.uint64 is not known") and Has(tostring(Failure), "0.4.3"),
		tostring(Failure)
	)
end)

RunClosure("ByteNet: definitions that pass something else for a type fail, saying where", function()
	local Path = Definitions(
		"ConvertWrong",
		'local ByteNet = require("@pkg/bytenet")\nreturn ByteNet.struct({ id = "uint8" })\n'
	)
	local Success, Failure = pcall(Sandbox.Record, Path, ByteNet)

	Check("Refusal", not Success, "a string was taken for a type")
	Check("Reason", Has(tostring(Failure), "A struct.id is not one of the library's types"), tostring(Failure))
end)

RunClosure("The sandbox gives definitions no way to the disk, the network or a process", function()
	local Path = Definitions(
		"ConvertReach",
		'local Fs = require("@lune/fs")\nreturn { Fs.readFile, io, os.execute, loadstring }\n'
	)
	local Module, Collect = ByteNet.new()
	local Unfollowed = Sandbox.Run(Path, ByteNet.NAME, Module)

	--> `@lune/fs` is answered with a placeholder like any module that is not there.
	Check("Lune", Unfollowed[1] == "fs", `the require was answered with something: {Unfollowed[1]}`)
	Check("Draft", #Collect().Body == 0, "something was defined")
end)

RunClosure("Packet: a packet with a response is a function, and its caller is asked for", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/Packet/Packets.luau", Packet))
	local List = table.concat(Checklist, "\n")

	Check("Function", Has(Text, "function Price {") and Has(Text, "Return: (u32, boolean)"), Text)
	Check("Caller", Has(List, "2 function(s) whose caller you must state: Price, Ping"), List)
	Check("Events", Has(List, "15 event(s) whose direction you must state"), List)
end)

RunClosure("Packet: a one-byte length is kept as a bound, and a two-byte one is asked about", function()
	local Text = Print.Render(Sandbox.Record("./Sources/Convert/Packet/Packets.luau", Packet))

	Check("Short", Has(Text, "Name: string(..255)") and Has(Text, "(buffer(..255), buffer)"), Text)
	Check("Long", Has(Text, "bound #2 (buffer length)"), "the long buffer was not marked")
end)

RunClosure("Packet: types with no equivalent and a name that is not one are each said", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/Packet/Packets.luau", Packet))
	local List = table.concat(Checklist, "\n")

	Check("Name", Has(Text, "event Player_Chat {") and Has(List, '"Player Chat" is not a name'), List)
	for _, Missing in { "Packet.Region3", "Packet.Rect", "Packet.EnumItem", "Packet.Static1" } do
		Check(Missing, Has(List, Missing) and Has(Text, `Packet wrote {Missing} where this says unknown`), List)
	end
	Check("Positional", Has(List, "a table of several types with no names"), List)
end)

RunClosure("Packet: a type name the stub does not know fails, naming the version", function()
	local Path = Definitions(
		"ConvertPacketUnknown",
		'local Packet = require("@pkg/Packet")\nreturn Packet("A", Packet.NumberU64)\n'
	)
	local Success, Failure = pcall(Sandbox.Record, Path, Packet)

	Check("Refusal", not Success, "an unknown type was answered")
	Check(
		"Reason",
		Has(tostring(Failure), "Packet.NumberU64 is not known") and Has(tostring(Failure), "1.7.0"),
		tostring(Failure)
	)
end)

RunClosure("QuickNet: a rate limit is carried, the default is written, and a lifted one is asked for", function()
	local Text, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/QuickNet/Events.luau", QuickNet))
	local List = table.concat(Checklist, "\n")

	--> SetRateLimit(10, 1), then (120, 2) on Move, and no call at all on Contents.
	Check("Set", Has(Text, "Rate: 10,\n\tData: (u8, Shape1)"), Text)
	Check("Window", Has(Text, "Type: Unreliable,\n\tCall: ManyAsync,\n\tRate: 60,"), Text)
	Check("Default", Has(Text, "Rate: 60,\n\tData: Shape1[]"), Text)
	Check("Lifted", Has(List, "1 event(s) a client fires with no Rate: Flood"), List)
end)

RunClosure("QuickNet: each kind of table is the type it stands for", function()
	local Text = Print.Render(Sandbox.Record("./Sources/Convert/QuickNet/Events.luau", QuickNet))

	Check("Static array", Has(Text, "Data: f32[3]"), Text)
	Check("Uniform dictionary", Has(Text, "Data: map { [string(..255)]: u32 }"), Text)
	Check("Nested", Has(Text, "Data: struct { at: vector, tags: string(..255)[] }[]"), Text)
	Check("Literal", Has(Text, "Data: enum { Idle, Chase, Sleep }"), Text)
	Check("Optional", Has(Text, "Data: (f32?, Shape1?)"), Text)
end)

RunClosure("QuickNet: what has no equivalent is each said", function()
	local _, Checklist = Print.Render(Sandbox.Record("./Sources/Convert/QuickNet/Events.luau", QuickNet))
	local List = table.concat(Checklist, "\n")

	for _, Missing in { "a static array of different types", "a union", "a literal of values", "QuickNet.Data.Rect" } do
		Check(Missing, Has(List, Missing), List)
	end
end)

RunClosure("QuickNet: a function carries its rate and is asked for its concurrency", function()
	local Text = Print.Render(Sandbox.Record("./Sources/Convert/QuickNet/Events.luau", QuickNet))
	Check(
		"Function",
		Has(Text, "function Price {\n\tYield: Coroutine,\n\tRate: 60,\n\t-- TODO(convert): Concurrency: ?"),
		Text
	)
end)

return {}
