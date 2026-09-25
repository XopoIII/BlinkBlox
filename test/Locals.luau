--!strict
--- Structs too wide for one function's locals.
---
--- Luau gives a function 200 locals. Every local a serialiser declared for one field of a struct -- a
--- string's `Length`, an array's cursor, a vector's components, a CFrame's parts -- used to stay live
--- until the reader or writer returned, so a struct of fifty CFrames, or two hundred strings,
--- generated a module that failed to load with "Out of local registers". Each field's locals now end
--- with the field (src/Generator/Scope.luau), while the bitfields that fields share outlive those scopes.
---
--- This builds a struct of 240 fields cycling through every kind that declares locals, with booleans
--- and optionals among them so bitfields are shared across the fields' scopes, and sends it alone, in
--- an array and in a map: loading the modules is the first check, the values arriving intact the
--- second.
local Assertions = require("./Assertions")
local Generate = require("./Generate")
local Harness = require("./Harness")
local Isolated = require("./Isolated")
local Oracle = require("./Oracle")
local Shared = require("./Shared")
local roblox = require("@lune/roblox")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local FIELDS = 240
local ROUNDS = 12

--> A Roblox type has no drawer in Generate.luau; its fields carry a value that survives the trip exactly.
local FIXED: { [string]: any } = {
	["CFrame"] = roblox.CFrame.new(1, 2, 3),
	["CFrame<quat, f24>"] = roblox.CFrame.new(4, 5, 6),
	["vector<f24>"] = roblox.Vector3.new(7, 8, 9),
	["vector<f16>"] = roblox.Vector3.new(-1, 0.5, 2),
}

local KINDS = {
	"boolean",
	"CFrame",
	"string(0..8)",
	"u8?",
	"vector<f24>",
	"Mode",
	"boolean?",
	"u16[0..3]",
	"f16",
	"CFrame<quat, f24>",
	"buffer(0..4)",
	"f24",
	"vector<f16>",
	"string(0..6)?",
}

local Fields: { string } = {}
for Index = 1, FIELDS do
	table.insert(Fields, `    F{Index}: {KINDS[(Index - 1) % #KINDS + 1]}`)
end

local SCHEMA = table.concat({
	"option MaxPacketSize = 262144",
	"option InboundBytesPerSecond = 1073741824",
	"option InboundBurst = 1073741824",
	"enum Mode = { Idle, Walk, Run }",
	`struct Wide \{\n{table.concat(Fields, ",\n")}\n}`,
	"map Wides = {[u8]: Wide}",
	"event One { From: Client, Type: Reliable, Call: SingleSync, Data: Wide }",
	"event Many { From: Client, Type: Reliable, Call: SingleSync, Data: Wide[0..3] }",
	"event Keyed { From: Client, Type: Reliable, Call: SingleSync, Data: Wides }",
}, "\n")

type Node = { Type: string, Name: string, Value: any, Tokens: any }

local Built, Pair = pcall(Isolated.Build, Isolated.Parse(SCHEMA), "LOCALS")

--- A value for a `Wide`: drawn where Generate.luau can, fixed where it cannot.
local function DrawWide(Struct: Node): { [string]: any }
	local Value = {}
	for Index, Field in Struct.Value.Values do
		local Kind = KINDS[(Index - 1) % #KINDS + 1]
		Value[Field.Name] = if FIXED[Kind] ~= nil then FIXED[Kind] else Generate.Value(Field)
	end
	return Value
end

local function SameWide(Struct: Node, Sent: { [string]: any }, Got: { [string]: any }): string?
	for Index, Field in Struct.Value.Values do
		local Kind = KINDS[(Index - 1) % #KINDS + 1]
		local Same = if FIXED[Kind] ~= nil
			then Sent[Field.Name] == Got[Field.Name]
			else Oracle.Equal(Field, Sent[Field.Name], Got[Field.Name])
		if not Same then
			return `field {Field.Name} ({Kind}) sent {Sent[Field.Name]}, got {Got[Field.Name]}`
		end
	end

	return nil
end

RunClosure("A struct wider than a function's locals loads and arrives intact", function()
	if not Built then
		ErrorPrint(`Failed: the generated modules did not load: {Pair}`)
		return
	end

	local Wide: Node
	for _, Declaration in Pair.Tree.Value.Declarations do
		if Declaration.Name == "Wide" then
			Wide = Declaration
		end
	end

	local Got: any = nil
	for _, Name in { "One", "Many", "Keyed" } do
		Pair.Server[Name].On(function(_Player, Value)
			Got = Value
		end)
	end

	local function Send(Name: string, Value: any): any
		Got = nil
		table.clear(Pair.Sent)
		Pair.Client[Name].Fire(Value)
		Pair.Client.StepReplication()
		Shared.AdvanceClock(2)
		Pair.Feed(true, Pair.Sent[1].Buffer)
		return Got
	end

	math.randomseed(71)
	for Round = 1, ROUNDS do
		local Value = DrawWide(Wide)
		local Failure = SameWide(Wide, Value, Send("One", Value) or {})
		if Failure then
			ErrorPrint(`Failed "One", round {Round}: {Failure}`)
			return
		end

		local List = {}
		for Index = 1, math.random(0, 3) do
			List[Index] = DrawWide(Wide)
		end
		local Arrived = Send("Many", List) or {}
		for Index, Item in List do
			Failure = if Arrived[Index] then SameWide(Wide, Item, Arrived[Index]) else "missing"
			if Failure then
				ErrorPrint(`Failed "Many", round {Round}, element {Index}: {Failure}`)
				return
			end
		end

		local Keyed = {}
		for _ = 1, math.random(0, 2) do
			Keyed[math.random(0, 255)] = DrawWide(Wide)
		end
		local Mapped = Send("Keyed", Keyed) or {}
		for Key, Item in Keyed do
			Failure = if Mapped[Key] then SameWide(Wide, Item, Mapped[Key]) else "missing"
			if Failure then
				ErrorPrint(`Failed "Keyed", round {Round}, key {Key}: {Failure}`)
				return
			end
		end
	end
end)
