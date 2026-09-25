--!strict
--- Specs for the editor's completion: what it offers at the cursor, how Tab expands the choice, and
--- how the arrow keys move through the list.
---
--- These were inline in plugin/src/Editor/init.luau, bound to the TextBox, and could only be tried by
--- typing in Studio. They are pure functions of the text now, like the highlighter beside them.
local Assertions = require("./Assertions")
local Completion = require("@compiler/../plugin/src/Editor/Completion")
local Harness = require("./Harness")
local Utility = require("@compiler/../plugin/src/Editor/Utility")

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
		--> A keyword opens a line, shortest first and then by name.
		{ Text = "str", Cursor = 4, Expect = "struct" },
		{ Text = "e", Cursor = 2, Expect = "enum,event,export" },
		--> A type follows `=` or a field's `:`.
		{ Text = "type A = u", Cursor = 11, Expect = "u8,u16,u24,u32,unknown" },
		{ Text = "event X {\n  Data: st", Cursor = 20, Expect = "string" },
		{ Text = "type A = Po", Cursor = 12, Symbols = { Position = true, Other = true }, Expect = "Position" },
		--> A word already complete has nothing left to add.
		{ Text = "type A = u8", Cursor = 12, Expect = "" },
		--> Nor does a keyword in the middle of a line.
		{ Text = "type A str", Cursor = 11, Expect = "" },
		{ Text = "op", Cursor = 3, Expect = "option" },
		--> An option's name follows `option`, and its value `=` where the language fixes it.
		{
			Text = "option Max",
			Cursor = 11,
			Expect = "MaxEventsPerPacket,MaxInstancesPerPacket,MaxPacketSize,MaxUnreliableSize",
		},
		{ Text = "option Inb", Cursor = 11, Expect = "InboundBurst,InboundBytesPerSecond" },
		{ Text = "option Casing = S", Cursor = 18, Expect = "Snake" },
		{ Text = "option Predict = t", Cursor = 19, Expect = "true" },
		{ Text = "option MaxPacketSize = 8", Cursor = 25, Expect = "" },
		{ Text = "option ServerOutput = s", Cursor = 24, Expect = "" },
		--> An attribute opens a line, and a profile goes inside it.
		{ Text = "@p", Cursor = 3, Expect = "@profile" },
		{ Text = '@profile("de', Cursor = 13, Expect = "dev,debug" },
		--> An event or a function opens its lines with its fields, each once, and no keywords.
		{ Text = "event X {\n  R", Cursor = 14, Expect = "Rate" },
		{ Text = "function X {\n  C", Cursor = 17, Expect = "Concurrency" },
		{ Text = "event X {\n  C", Cursor = 14, Expect = "Call" },
		{ Text = "event X {\n  From: Client,\n  F", Cursor = 30, Expect = "" },
		{ Text = "event X {\n  Data: struct { Type: u8 },\n  T", Cursor = 43, Expect = "Type" },
		{ Text = '@profile("dev") event X {\n  Po', Cursor = 31, Expect = "Poll" },
		{ Text = "function X {\n  Y", Cursor = 17, Expect = "Yield" },
		--> A field takes its own values, a numeric one nothing, and `Data` a type.
		{ Text = "event X {\n  From: C", Cursor = 20, Expect = "Client" },
		{ Text = "event X {\n  Call: Many", Cursor = 23, Expect = "ManySync,ManyAsync" },
		{ Text = "function X {\n  Yield: P", Cursor = 24, Expect = "Promise" },
		{ Text = "event X {\n  Poll: t", Cursor = 20, Expect = "true" },
		{ Text = "event X {\n  Rate: 1", Cursor = 20, Expect = "" },
		{ Text = "function X {\n  Return: bo", Cursor = 26, Expect = "boolean" },
		--> A brace in a comment or a string opens nothing.
		{ Text = "-- event X {\nstr", Cursor = 17, Expect = "struct" },
		{ Text = 'option ServerOutput = "{"\nstr', Cursor = 30, Expect = "struct" },
		--> The declaration is found across blank lines and nested structs, and not after it closed.
		{ Text = "event X {\n\n  R", Cursor = 15, Expect = "Rate" },
		{ Text = "event X {\n  Data: struct {\n    A: u8,\n  },\n  R", Cursor = 47, Expect = "Rate" },
		{ Text = "event X {\n  Data: struct {\n    ty", Cursor = 34, Expect = "type" },
		{ Text = "event X {\n  From: Client,\n}\nstr", Cursor = 32, Expect = "struct" },
		{ Text = "scope S {\n  event X {\n    Ty", Cursor = 29, Expect = "Type" },
		--> An event's `Stream` block takes its own fields, each once, on its own lines or on one, and
		--> `Stream:` itself takes the block rather than a type.
		{ Text = "event X {\n  St", Cursor = 15, Expect = "Stream" },
		{ Text = "event X {\n  Stream: {\n    K", Cursor = 28, Expect = "Keepalive" },
		{ Text = "event X {\n  Stream: {\n    Rate: 10,\n    R", Cursor = 42, Expect = "" },
		{ Text = "event X {\n  Stream: { Rate: 10, E", Cursor = 34, Expect = "Epsilon" },
		{ Text = "event X {\n  Stream: { F", Cursor = 24, Expect = "Fast" },
		{ Text = "event X {\n  Stream: { Rate: 10, Fast: 2", Cursor = 40, Expect = "" },
		{ Text = "event X {\n  Stream: u", Cursor = 22, Expect = "" },
		{ Text = "event X {\n  Stream: { Rate: 10 },\n  D", Cursor = 38, Expect = "Data" },
		--> A struct in Data is not a stream block, whatever it is called.
		{ Text = "event X {\n  Data: struct {\n    Ra", Cursor = 34, Expect = "" },
		--> Inside a struct, a field's name is the author's: keywords as before.
		{ Text = "struct S {\n  Type: u", Cursor = 21, Expect = "u8,u16,u24,u32,unknown" },
		--> A number's brackets take `saturate`, first or after its scale; a vector's take none.
		{ Text = "type A = u8<sa", Cursor = 15, Expect = "saturate" },
		{ Text = "type A = u16<", Cursor = 14, Expect = "saturate" },
		{ Text = "type A = u16<0.1, s", Cursor = 20, Expect = "saturate" },
		{ Text = "type A = f32<saturate", Cursor = 22, Expect = "" },
		{ Text = "type A = vector<sa", Cursor = 19, Expect = "" },
		{ Text = "type A = Point<s", Cursor = 17, Expect = "" },
	}

	for _, Case in Cases do
		local Got = Labels(Completion.Match(Case.Text, Case.Cursor, Case.Symbols))
		if Got ~= Case.Expect then
			ErrorPrint(
				`Failed "Completion": {string.format("%q", Case.Text)} offered "{Got}", expected "{Case.Expect}".`
			)
		end
	end

	--> The whole word is replaced, so `saturate` is inserted with the number and bracket before it.
	for Text, Insert in { ["type A = u8<sa"] = "u8<saturate", ["type A = u16<0.1, s"] = "saturate" } do
		local Items = Completion.Match(Text, #Text + 1)
		local Got = if Items[1] then Items[1].Insert else "nothing"
		if Got ~= Insert then
			ErrorPrint(`Failed "Completion": {string.format("%q", Text)} inserts "{Got}", expected "{Insert}".`)
		end
	end
end)

RunClosure("Tab expands the chosen item over the word it completes", function()
	--> The `%s` of a snippet is where the cursor lands; without one it lands after the insert. The tab
	--> itself is consumed, and whatever followed it is kept.
	local Cases = {
		{ Text = "str\t", Tab = 4, Insert = "struct %s {}", Expect = "struct  {}", Cursor = 8 },
		{ Text = "type A = u\tx", Tab = 11, Insert = "u16", Expect = "type A = u16x", Cursor = 13 },
		{
			Text = '@profile("de\t',
			Tab = 13,
			Insert = '@profile("dev")',
			Expect = '@profile("dev")',
			Cursor = 16,
		},
		{ Text = "option Ca\t", Tab = 10, Insert = "Casing = ", Expect = "option Casing = ", Cursor = 17 },
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

RunClosure("The line at the cursor is the one splitting the whole text finds", function()
	--> The reference is what GetLineRangeAtPosition did before it stopped splitting the document.
	local function Reference(Source: string, Cursor: number)
		local Position = 0
		for _, Slice in string.split(Source, "\n") do
			local Start = Position
			Position += (#Slice + 1)
			if Cursor <= Position then
				return Slice, Start + 1, Position - 1
			end
		end
		return nil, nil, nil
	end

	for _, Source in { "", "a", "abc\ndef", "\n\nx\n", "event X {\n  From: Client,\n}\n" } do
		for Cursor = 1, #Source + 1 do
			local Text, Start, End = Reference(Source, Cursor)
			local Got = Utility.GetLineRangeAtPosition(Source, Cursor)
			if Got.Text ~= Text or Got.Start ~= Start or Got.End ~= End then
				ErrorPrint(
					`Failed "Line range": {string.format("%q", Source)} at {Cursor} gave `
						.. `{string.format("%q", Got.Text)} {Got.Start}..{Got.End}, expected `
						.. `{string.format("%q", Text or "")} {Start}..{End}.`
				)
			end
		end
	end
end)
