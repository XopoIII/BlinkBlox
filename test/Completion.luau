--!strict
--- Specs for the editor's completion: what it offers at the cursor, how Tab expands the choice, and
--- how the arrow keys move through the list.
---
--- These were inline in plugin/src/Editor/init.luau, bound to the TextBox, and could only be tried by
--- typing in Studio. They are pure functions of the text now, like the highlighter beside them.
local Assertions = require("./Assertions")
local Completion = require("@compiler/../plugin/src/Editor/Completion")
local Harness = require("./Harness")

local ErrorPrint = Harness.ErrorPrint
local RunClosure = Assertions.RunClosure

local function Labels(Items: { Completion.Item }): string
	local Result = {}
	for _, Item in Items do
		table.insert(Result, Item.Label)
	end
	return table.concat(Result, ",")
end

RunClosure("Completion offers keywords, primitives and declared names where each belongs", function()
	local Cases: { { Text: string, Cursor: number, Symbols: { [string]: true }?, Expect: string } } = {
		--> A keyword opens a line, shortest first.
		{ Text = "str", Cursor = 4, Expect = "struct" },
		{ Text = "e", Cursor = 2, Expect = "enum,event,export" },
		--> A type follows `=` or a field's `:`.
		{ Text = "type A = u", Cursor = 11, Expect = "u8,u16,u32,unknown" },
		{ Text = "event X {\n  Data: st", Cursor = 20, Expect = "string" },
		{ Text = "type A = Po", Cursor = 12, Symbols = { Position = true, Other = true }, Expect = "Position" },
		--> A word already complete has nothing left to add.
		{ Text = "type A = u8", Cursor = 12, Expect = "" },
		--> Nor does a keyword in the middle of a line.
		{ Text = "type A str", Cursor = 11, Expect = "" },
	}

	for _, Case in Cases do
		local Got = Labels(Completion.Match(Case.Text, Case.Cursor, Case.Symbols))
		if Got ~= Case.Expect then
			ErrorPrint(
				`Failed "Completion": {string.format("%q", Case.Text)} offered "{Got}", expected "{Case.Expect}".`
			)
		end
	end
end)

RunClosure("Tab expands the chosen item over the word it completes", function()
	--> The `%s` of a snippet is where the cursor lands; without one it lands after the insert. The tab
	--> itself is consumed, and whatever followed it is kept.
	local Cases = {
		{ Text = "str\t", Tab = 4, Insert = "struct %s {}", Expect = "struct  {}", Cursor = 8 },
		{ Text = "type A = u\tx", Tab = 11, Insert = "u16", Expect = "type A = u16x", Cursor = 13 },
	}

	for _, Case in Cases do
		local Text, Cursor =
			Completion.Expand(Case.Text, Case.Tab, { Icon = "", Label = Case.Insert, Insert = Case.Insert })
		if Text ~= Case.Expect or Cursor ~= Case.Cursor then
			ErrorPrint(
				`Failed "Tab expansion": got {string.format("%q", Text)} at {Cursor}, `
					.. `expected {string.format("%q", Case.Expect)} at {Case.Cursor}.`
			)
		end
	end
end)

RunClosure("The arrow keys step through the list, wrapping at both ends", function()
	--> A move of exactly one line that lands more than one character away is an arrow key.
	if Completion.Navigation("a\nbcdef\ng", 8, 2) ~= 1 then
		ErrorPrint(`Failed "Navigation": a move one line down was not read as stepping down.`)
	end

	if Completion.Navigation("abc", 2, 3) ~= nil then
		ErrorPrint(`Failed "Navigation": a move along the line was read as stepping through the list.`)
	end

	if Completion.Step(1, 3, -1) ~= 3 or Completion.Step(3, 3, 1) ~= 1 or Completion.Step(1, 3, 1) ~= 2 then
		ErrorPrint(`Failed "Navigation": stepping past either end of the list did not wrap.`)
	end
end)
