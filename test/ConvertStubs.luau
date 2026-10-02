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

return {}
