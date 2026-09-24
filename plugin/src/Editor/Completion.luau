--!strict
--- What the editor offers to complete at the cursor: a keyword at the start of a line, and after a
--- `:` or `=` a primitive or a name the schema declares.
---
--- A pure function of the text, the cursor and the declared names, so it can be checked outside
--- Studio; the popup that shows the result stays in init.luau.
local Settings = require("@compiler/Settings")
local Utility = require("./Utility")

export type Item = {
	Icon: string,
	Label: string,
	Insert: string,
}

type Symbol = { Label: string, Insert: string }

local ICONS = {
	Event = "rbxassetid://16506730516",
	Field = "rbxassetid://16506725096",
	Snippet = "rbxassetid://16506712161",
	Keyword = "rbxassetid://16506695241",
	Variable = "rbxassetid://16506719167",
	Primitive = "rbxassetid://16506695241",
}

local PRIMITIVES: { Symbol } = {}
for Primitive in Settings.Primtives do
	table.insert(PRIMITIVES, { Label = Primitive, Insert = Primitive })
end

--> `%s` in an insert marks where the cursor lands once it is expanded.
local KEYWORDS: { Symbol } = {
	{ Label = "set", Insert = "set %s = {}" },
	{ Label = "map", Insert = "map %s = {[]: }" },
	{ Label = "type", Insert = "type %s = " },
	{ Label = "enum", Insert = "enum %s = {}" },
	{ Label = "struct", Insert = "struct %s {}" },
	{ Label = "event", Insert = "event %s {}" },
	{ Label = "function", Insert = "function %s {}" },
	{ Label = "import", Insert = "import %s as " },
	{ Label = "scope", Insert = "scope %s {}" },
	{ Label = "export", Insert = "export " },
}

--> Shortest first, so the closest match to what has been typed is at the top.
for _, List in { PRIMITIVES, KEYWORDS } do
	table.sort(List, function(a, b)
		return #a.Label < #b.Label
	end)
end

--- Whether `Label` extends `Typed` -- and is not merely equal to it, which has nothing left to add.
local function Extends(Label: string, Typed: string): boolean
	local Stub = string.sub(Label, 1, #Typed)
	return Stub == Typed and Stub ~= Label
end

local Completion = {}

--- The items to offer with the cursor at `Cursor` in `Text`. `Symbols` are the names the last
--- successful parse declared, if there was one.
function Completion.Match(Text: string, Cursor: number, Symbols: { [string]: true }?): { Item }
	local Line = Utility.GetLineRangeAtPosition(Text, Cursor)
	local Items: { Item } = {}

	local Word = Utility.GetWordRangeAtPosition(Line.Text, Cursor - Line.Start)
	local Typed = Word.Text
	if #Typed == 0 then
		return Items
	end

	--> A keyword opens a line.
	if Word.Index == 1 then
		for _, Symbol in KEYWORDS do
			if Extends(Symbol.Label, Typed) then
				table.insert(Items, { Icon = ICONS.Keyword, Label = Symbol.Label, Insert = Symbol.Insert })
			end
		end
	end

	--> A type follows a field's `:` or a declaration's `=`.
	local Previous = Utility.GetWordRangeBeforePosition(Line.Text, Word.Start - 1)
	if Previous.Text == "" then
		return Items
	end

	if string.match(Previous.Text, ":$") or Previous.Text == "=" then
		for _, Symbol in PRIMITIVES do
			if Extends(Symbol.Label, Typed) then
				table.insert(Items, { Icon = ICONS.Primitive, Label = Symbol.Label, Insert = Symbol.Label })
			end
		end

		if Symbols then
			for Symbol in Symbols do
				if Extends(Symbol, Typed) then
					table.insert(Items, { Icon = ICONS.Variable, Label = Symbol, Insert = Symbol })
				end
			end
		end
	end

	return Items
end

--- Expands `Item` over the word before a Tab just typed at `Tab`: the word and the tab are replaced
--- by the item's insert. Returns the new text and where the cursor goes -- at the insert's `%s` if
--- it has one, otherwise after it.
function Completion.Expand(Text: string, Tab: number, Item: Item): (string, number)
	local Insert = Item.Insert
	local Offset = (#Insert + 1)

	local Start, End = string.find(Insert, "%s", 1, true)
	if Start and End then
		Offset = Start
		Insert = string.sub(Insert, 1, Start - 1) .. string.sub(Insert, End + 1)
	end

	--> Move behind the tab character, then back over the word it completes.
	local Cursor = Tab - 1
	local Line = Utility.GetLineRangeAtPosition(Text, Cursor)
	local Word = Utility.GetWordRangeAtPosition(Line.Text, Cursor - Line.Start + 1)
	local Length = #Word.Text
	Cursor -= Length

	--> Match characters before replacement and after tab (2)
	return string.sub(Text, 1, Cursor) .. Insert .. string.sub(Text, Cursor + Length + 2), Cursor + Offset
end

local function LineAt(Text: string, Position: number): number
	local _, Count = string.gsub(string.sub(Text, 1, Position - 1), "\n", "")
	return Count + 1
end

--- Whether moving the cursor from `Previous` to `Cursor` was an arrow key moving through the popup
--- rather than through the text: exactly one line up or down, landing more than one character away.
--- Returns the direction to step the selection, or nil.
function Completion.Navigation(Text: string, Cursor: number, Previous: number): number?
	local Line, PriorLine = LineAt(Text, Cursor), LineAt(Text, Previous)
	if math.abs(Line - PriorLine) == 1 and math.abs(Cursor - Previous) > 1 then
		return if Line > PriorLine then 1 else -1
	end

	return nil
end

--- The selection after stepping `Direction` through `Count` items, wrapping at both ends.
function Completion.Step(Index: number, Count: number, Direction: number): number
	return if Direction == -1 then ((Index - 2) % Count) + 1 else (Index % Count) + 1
end

return Completion
