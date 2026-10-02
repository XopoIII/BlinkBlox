--!strict
--- Specs for `--from zap`: src/Convert/Zap reading a zap config, src/Convert/Print writing the draft.
---
--- Each config is converted and held to three things. The draft is the committed golden, so a change
--- to the converter is a diff someone reads. The draft compiles, and its modules load as Luau: a
--- converter whose output the compiler refuses has only moved the work. And nothing zap wrote goes
--- missing without the checklist saying so.
---
--- Two of the configs are the benchmark's own, so editing those re-records a golden here. That is
--- meant: they are the definitions a zap user would recognise.
local Assertions = require("./Assertions")
local Harness = require("./Harness")
local Library = require("@compiler/Library")
local Print = require("@compiler/Convert/Print")
local Zap = require("@compiler/Convert/Zap")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local CONFIGS = {
	Scenarios = "../benchmark/definitions/Scenarios.zap",
	Definition = "../benchmark/definitions/Definition.zap",
	Everything = "./Sources/Convert/Everything.zap",
}

local function Check(Name: string, Condition: boolean, Detail: string)
	if not Condition then
		ErrorPrint(`{Name}: {Detail}`)
	end
end

local function Convert(Source: string): (string, { string })
	return Print.Render(Zap.Parse(Source))
end

--- Whether the checklist has an item holding `Text`.
local function Lists(Checklist: { string }, Text: string): boolean
	for _, Item in Checklist do
		if string.find(Item, Text, 1, true) then
			return true
		end
	end

	return false
end

for Name, Path in CONFIGS do
	RunClosure(`zap {Name} converts to its golden, and the draft compiles`, function()
		local Text = Convert(fs.readFile(Path))
		Harness.Golden(`./Golden/Convert/zap/{Name}.blink`, Text)

		local Output = Library.Compile(Text)
		for _, Side in { Output.Server, Output.Client } do
			Check(Name, (pcall(luau.compile, Side)), "a generated module does not load as Luau")
		end
	end)
end

RunClosure("zap: an event a client fires is marked for a Rate, and one the server fires is not", function()
	local Text, Checklist = Convert([[
		event Up = { from: Client, type: Reliable, call: SingleSync, data: u8 }
		event Down = { from: Server, type: Reliable, call: SingleSync, data: string[] }
	]])

	Check("Rate", Lists(Checklist, "1 event(s) a client fires with no Rate: Up"), table.concat(Checklist, "\n"))
	local _, Marks = string.gsub(Text, "TODO%(convert%)", "")
	--> One in the header's explanation, one for Up's rate. Down's unbounded array is the server's own.
	Check("Marks", Marks == 2, `{Marks} TODO(convert) marks:\n{Text}`)
end)

RunClosure("zap: a length a client sends unbounded is marked where it is declared", function()
	local Text, Checklist = Convert([[
		type Item = struct { name: string, tags: string(..8)[] }
		type Quiet = struct { name: string }
		event Give = { from: Client, data: Item }
		event Tell = { from: Server, data: Quiet }
	]])

	Check("Item", string.find(Text, "bound name (string length), tags (array length)", 1, true) ~= nil, Text)
	Check("Count", Lists(Checklist, "2 length(s) or value(s)"), table.concat(Checklist, "\n"))
end)

RunClosure("zap: what has no equivalent is said, never left out quietly", function()
	local Text, Checklist = Convert([[
		opt tooling = true
		type Either = (string | u32)
		type Flags = set { string }
		event Send = { from: Server, data: Either }
	]])

	Check("Union", string.find(Text, "zap wrote (string | u32) where this says unknown", 1, true) ~= nil, Text)
	Check("Union", Lists(Checklist, "a union has no equivalent"), "the checklist does not name the union")
	Check("Set", Lists(Checklist, "a set became a map to boolean"), "the checklist does not name the set")
	Check("Option", Lists(Checklist, "opt tooling has no equivalent"), "the checklist does not name the option")
end)

RunClosure("zap: a type a schema cannot name is written out where it was used", function()
	local Text = Convert([[
		namespace Shop = {
			type Item = struct { id: u16 }
			type Items = Item[..8]
		}
		event Stock = { from: Server, data: Shop.Items? }
	]])

	Check("Use", string.find(Text, "Data: Shop.Item[..8]?", 1, true) ~= nil, Text)
	Check("Declaration", not string.find(Text, "type Items", 1, true), Text)
	Library.Compile(Text)
end)

RunClosure("zap: zap's defaults are written into the draft", function()
	local Text = Convert([[
		opt call_default = "Polling"
		event Quiet = { from: Server }
	]])

	Check("Call", string.find(Text, "Call: Polling", 1, true) ~= nil, Text)
	Check("Type", string.find(Text, "Type: Reliable", 1, true) ~= nil, Text)
	Check("Checks", string.find(Text, "option WriteValidations = true", 1, true) ~= nil, Text)
end)

RunClosure("zap: a config zap would refuse fails with its line", function()
	local Success, Failure = pcall(Convert, "type A = u8\nevent B = { from: Client, speed: u8 }")
	Check("Refusal", not Success, "a config with an unknown field converted")
	Check("Line", string.find(tostring(Failure), "line 2", 1, true) ~= nil, tostring(Failure))
end)

return {}
