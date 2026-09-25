--!strict
--- What the editor offers to complete at the cursor: a keyword or `@profile` at the start of a line,
--- an option's name and value, an event's or function's field and the values it takes, and where a
--- type goes, a primitive or a name the schema declares.
---
--- A pure function of the text, the cursor and the declared names, so it can be checked outside
--- Studio; the popup that shows the result stays in init.luau.
local Attributes = require("@compiler/Modules/Attributes")
local Grammar = require("@compiler/Modules/Grammar")
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
	{ Label = "option", Insert = "option %s = " },
}

--> Every option but the deprecated `UseColon`, in name order.
local OPTIONS: { Symbol } = {}
for Name in Grammar.OPTIONS do
	if Name ~= "UseColon" then
		table.insert(OPTIONS, { Label = Name, Insert = `{Name} = ` })
	end
end
table.sort(OPTIONS, function(a, b)
	return a.Label < b.Label
end)

--> What an option's value can be, where the language fixes it.
local BOOLEANS = { "true", "false" }
local OPTION_VALUES: { [string]: { string } } = {
	Casing = { "Pascal", "Camel", "Snake" },
}
for Name, Type in Grammar.OPTIONS do
	if Type == "Boolean" then
		OPTION_VALUES[Name] = BOOLEANS
	end
end

--> The fields of an `event` and of a `function`, in the order the docs write them.
local FIELDS: { [string]: { Grammar.EventOption } } = {
	event = Grammar.EVENT,
	["function"] = Grammar.FUNCTION,
}

local FIELD_KEYS: { [string]: true } = {}
for _, Fields in FIELDS do
	for _, Field in Fields do
		FIELD_KEYS[Field.Key] = true
	end
end

--> Shortest first, so the closest match to what has been typed is at the top. Labels of one length go
--> in name order: `Settings.Primtives` is a map, so without it their order was whatever the table's
--> layout happened to be, and adding `u24` put it after `u32`.
for _, List in { PRIMITIVES, KEYWORDS } do
	table.sort(List, function(a, b)
		if #a.Label ~= #b.Label then
			return #a.Label < #b.Label
		end

		return a.Label < b.Label
	end)
end

--- Whether `Label` extends `Typed` -- and is not merely equal to it, which has nothing left to add.
local function Extends(Label: string, Typed: string): boolean
	local Stub = string.sub(Label, 1, #Typed)
	return Stub == Typed and Stub ~= Label
end

--- Whether the `Keyword` at `At` opens a declaration: first on its line, after any attribute, and
--- followed by a name.
local function Declares(Text: string, At: number, Keyword: string): boolean
	if not string.match(Text, "^[ \t]+[%a_]", At + #Keyword) then
		return false
	end

	local LineStart = At
	while LineStart > 1 and string.sub(Text, LineStart - 1, LineStart - 1) ~= "\n" do
		LineStart -= 1
	end

	local Prefix = string.sub(Text, LineStart, At - 1)
	return string.match(Prefix, "^%s*$") ~= nil or string.match(Prefix, "^%s*@%a+%b()%s*$") ~= nil
end

--> How much text `NearestBlock` reads at a time, walking back from the cursor.
local CHUNK = 4096

--- The nearest `event` or `function` declaration before `Position`, and where its keyword is.
---
--- Runs on every keystroke, so it reads the schema from the cursor back, a chunk at a time, and only as
--- far as the nearest one, finding the keywords with plain `string.find` at memory speed. A pattern
--- search or a walk in Luau costs about a millisecond per 30 KB, and so does `string.reverse`.
local function NearestBlock(Text: string, Position: number): (string?, number)
	local Upper = Position - 1
	while Upper >= 1 do
		local From = math.max(1, Upper - CHUNK + 1)
		local Slice = string.sub(Text, From, Upper)

		--> Each keyword's occurrences in the chunk, checked from the last: the first that opens a
		--> declaration is its nearest.
		local Found: string?, Best = nil, 0
		for Keyword in FIELDS do
			local Occurrences: { number } = {}
			local Index = 1
			while true do
				local At = string.find(Slice, Keyword, Index, true)
				if not At then
					break
				end

				table.insert(Occurrences, From + At - 1)
				Index = At + 1
			end

			for Nth = #Occurrences, 1, -1 do
				local At = Occurrences[Nth]
				if At <= Best then
					break
				elseif Declares(Text, At, Keyword) then
					Found, Best = Keyword, At
					break
				end
			end
		end

		if Found then
			return Found, Best
		elseif From == 1 then
			break
		end

		--> Overlapping by a keyword's length, so one split across two chunks is still found.
		Upper = From + #"function" - 2
	end

	return nil, 0
end

--- The declaration whose braces hold `Position`, if it is an `event` or a `function`, and the text of
--- its body up to there. Braces are counted from the nearest such declaration, skipping comments and
--- strings, and only until its block closes: its body is short, whatever the schema's length.
local function Enclosing(Text: string, Position: number): (string?, string)
	local Keyword, Start = NearestBlock(Text, Position)
	if not Keyword then
		return nil, ""
	end

	--> The cursor is in the body only at depth one; deeper is a nested struct.
	local Depth, Brace = 0, 0
	local Index = Start
	while true do
		local At = string.find(Text, '[{}"%-]', Index)
		if not At or At >= Position then
			break
		end

		local Character = string.sub(Text, At, At)
		if Character == "-" and string.sub(Text, At + 1, At + 1) == "-" then
			local Level = string.match(Text, "^%-%-%[(=*)%[", At)
			local Close = if Level then `]{Level}]` else "\n"
			local _, End = string.find(Text, Close, At + 2, true)
			Index = (End or #Text) + 1
		elseif Character == '"' then
			local _, End = string.find(Text, '"', At + 1, true)
			Index = (End or #Text) + 1
		else
			if Character == "{" then
				Depth += 1
				if Depth == 1 then
					Brace = At
				end
			elseif Character == "}" then
				Depth -= 1
				if Depth == 0 then
					--> The declaration closed before the cursor.
					return nil, ""
				end
			end
			Index = At + 1
		end
	end

	if Depth ~= 1 then
		return nil, ""
	end

	--> A nested struct's own fields are not the declaration's.
	local Body = string.gsub(string.sub(Text, Brace + 1, Position - 1), "%b{}", "")
	return Keyword, Body
end

local function Offer(Items: { Item }, Icon: string, Typed: string, Label: string, Insert: string)
	if Extends(Label, Typed) then
		table.insert(Items, { Icon = Icon, Label = Label, Insert = Insert })
	end
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

	--> A profile inside `@profile("`: the whole word is replaced, so the insert is the whole attribute.
	local Profile = string.match(Typed, '^@profile%("(%a*)$')
	if Profile and Word.Index == 1 then
		for _, Name in Attributes.PROFILES do
			Offer(Items, ICONS.Keyword, Profile, Name, `@profile("{Name}")`)
		end

		return Items
	end

	local WordStart = Line.Start + Word.Start - 1
	if Word.Index == 1 then
		local Block, Body = Enclosing(Text, WordStart)
		if Block then
			--> A field opens a line in an event or a function, once each.
			for _, Field in FIELDS[Block] do
				local Written = string.find(Body, `%f[%w_]{Field.Key}%s*:`)
				if not Written then
					Offer(Items, ICONS.Field, Typed, Field.Key, `{Field.Key}: `)
				end
			end
		else
			--> A keyword or an attribute opens a line everywhere else.
			for _, Symbol in KEYWORDS do
				Offer(Items, ICONS.Keyword, Typed, Symbol.Label, Symbol.Insert)
			end
			Offer(Items, ICONS.Snippet, Typed, "@profile", '@profile("%s")')
		end

		return Items
	end

	local Previous = Utility.GetWordRangeBeforePosition(Line.Text, Word.Start - 1)
	if Previous.Text == "" then
		return Items
	end

	--> `saturate` goes in a number's brackets, first or after a scale: `u16<sat`, `u16<0.1, sat`. It is
	--> an identifier rather than a keyword, so this is the one place it is offered.
	local Number, Partial = string.match(Typed, "^([%a_][%w_]*)<(%a*)$")
	if not Number and string.match(Typed, "^%a+$") then
		Number, Partial = string.match(Previous.Text, "^([%a_][%w_]*)<[^>]*,$"), Typed
	end
	local Primitive = if Number then Settings.Primtives[Number] else nil
	if Primitive and Primitive.Component and Primitive.Bounds and Partial then
		local Head = string.sub(Typed, 1, #Typed - #Partial)
		Offer(Items, ICONS.Keyword, Partial, "saturate", `{Head}saturate`)
		return Items
	end

	--> `option` is followed by the option's name, and `option Name =` by its value.
	local Leading = Utility.GetWordRangeAtPosition(Line.Text, 1)
	if Leading.Text == "option" then
		if Word.Index == 2 then
			for _, Symbol in OPTIONS do
				Offer(Items, ICONS.Keyword, Typed, Symbol.Label, Symbol.Insert)
			end
		elseif Word.Index == 4 and Previous.Text == "=" then
			local Name = Utility.GetWordRangeBeforePosition(Line.Text, Previous.Start - 1).Text
			local Values: { string } = OPTION_VALUES[Name] or {}
			for _, Value in Values do
				Offer(Items, ICONS.Keyword, Typed, Value, Value)
			end
		end

		return Items
	end

	--> A field of an event or a function takes its own values, and `Data` and `Return` a type. Only a
	--> key one of them has is worth finding the enclosing declaration for.
	local Key = string.match(Previous.Text, "^([%a_][%w_]*):$")
	local Block = if Key and FIELD_KEYS[Key] then Enclosing(Text, WordStart) else nil
	if Block and Key then
		for _, Field in FIELDS[Block] do
			if Field.Key == Key and #Field.Values > 0 then
				for _, Value in Field.Values do
					Offer(Items, ICONS.Keyword, Typed, tostring(Value), tostring(Value))
				end

				return Items
			elseif Field.Key == Key and Field.Numeric then
				return Items
			end
		end
	end

	--> A type follows a field's `:` or a declaration's `=`.
	if string.match(Previous.Text, ":$") or Previous.Text == "=" then
		for _, Symbol in PRIMITIVES do
			Offer(Items, ICONS.Primitive, Typed, Symbol.Label, Symbol.Label)
		end

		if Symbols then
			for Symbol in Symbols do
				Offer(Items, ICONS.Variable, Typed, Symbol, Symbol)
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
