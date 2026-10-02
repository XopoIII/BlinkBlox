--!strict
--- A Draft as schema text, and the list of what its reader still has to decide.
---
--- The text always compiles. What another tool's definitions cannot say -- how often a client may
--- fire an event, how long an array may be -- is written as a `TODO(convert)` comment where the answer
--- belongs, never as a guess that would compile into a limit nobody chose. The same gaps are counted
--- into the checklist the CLI prints, so they are seen once without opening the file.
local Aliases = require("./Aliases")
local Draft = require("./Draft")
local Inbound = require("./Inbound")

type Type = Draft.Type
type Field = Draft.Field
type Declaration = Draft.Declaration

--- What one render counts on its way through, for the checklist.
type State = {
	Draft: Draft.Draft,
	Lines: { string },
	Inbound: { [Declaration]: true },
	MissingRates: { string },
	MissingLimits: { string },
	Unbounded: number,
	Directions: { string },
	Reliabilities: { string },
}

local GUIDES = "https://xopoiii.github.io/BlinkBlox/guides"
local TODO = "-- TODO(convert):"

local Print = {}

local TypeText: (Type: Type, Indent: string) -> string

local function RangeText(Range: Draft.Range?): string
	if not Range or (Range.Min == nil and Range.Max == nil) then
		return ""
	elseif Range.Min == Range.Max then
		return Range.Min :: string
	end

	return `{Range.Min or ""}..{Range.Max or ""}`
end

--- Whether a type reads well on the line of the field that holds it.
local function IsSimple(Type: Type): boolean
	if Type.Kind == "Optional" or Type.Kind == "Array" then
		return IsSimple(Type.Of :: Type)
	end

	return Type.Kind == "Primitive" or Type.Kind == "Reference" or Type.Kind == "Unmapped"
end

local function FieldText(Field: Field, Indent: string): string
	local Text = TypeText(Field.Type, Indent)
	return if Field.Name then `{Field.Name}: {Text}` else Text
end

--- A struct's braces and fields: on one line when the fields are few and plain.
local function Braces(Fields: { Field }, Indent: string): string
	if #Fields == 0 then
		return "{}"
	end

	local Inline = #Fields <= 4
	for _, Field in Fields do
		Inline = Inline and IsSimple(Field.Type)
	end

	local Inner = if Inline then Indent else `{Indent}\t`
	local Texts: { string } = {}
	for _, Field in Fields do
		table.insert(Texts, FieldText(Field, Inner))
	end

	if Inline then
		return `\{ {table.concat(Texts, ", ")} }`
	end

	return `\{\n{Inner}{table.concat(Texts, `,\n{Inner}`)}\n{Indent}}`
end

local function VariantsText(Type: Type, Indent: string): string
	local Inner = `{Indent}\t`
	local Texts: { string } = {}
	for _, Variant in Type.Variants :: { Draft.Variant } do
		table.insert(Texts, `{Variant.Name} {Braces(Variant.Fields, Inner)}`)
	end

	return `"{Type.Tag}" \{\n{Inner}{table.concat(Texts, `,\n{Inner}`)}\n{Indent}}`
end

function TypeText(Type: Type, Indent: string): string
	if Type.Kind == "Primitive" then
		local Range = RangeText(Type.Range)
		return if Range == "" then Type.Name :: string else `{Type.Name}({Range})`
	elseif Type.Kind == "Reference" then
		return Type.Name :: string
	elseif Type.Kind == "Struct" then
		return `struct {Braces(Type.Fields :: { Field }, Indent)}`
	elseif Type.Kind == "Array" then
		return `{TypeText(Type.Of :: Type, Indent)}[{RangeText(Type.Range)}]`
	elseif Type.Kind == "Map" then
		return `map \{ [{TypeText(Type.Key :: Type, Indent)}]: {TypeText(Type.Of :: Type, Indent)} }`
	elseif Type.Kind == "Enum" then
		return `enum \{ {table.concat(Type.Values :: { string }, ", ")} }`
	elseif Type.Kind == "TaggedEnum" then
		return `enum {VariantsText(Type, Indent)}`
	elseif Type.Kind == "Tuple" then
		local Texts: { string } = {}
		for _, Field in Type.Fields :: { Field } do
			table.insert(Texts, FieldText(Field, Indent))
		end

		return `({table.concat(Texts, ", ")})`
	elseif Type.Kind == "Optional" then
		return `{TypeText(Type.Of :: Type, Indent)}?`
	end

	return "unknown"
end

--- The comments a payload earns above its declaration: what the source wrote where the draft says
--- `unknown`, and, when a client sends it, every length nothing bounds.
local function Remarks(State: State, Indent: string, Types: { Type }, IsInbound: boolean)
	for _, Type in Types do
		for _, Original in Inbound.Unmapped(Type) do
			table.insert(State.Lines, `{Indent}{TODO} {State.Draft.Tool} wrote {Original} where this says unknown`)
		end
	end

	if not IsInbound then
		return
	end

	local Paths: { string } = {}
	for _, Type in Types do
		Inbound.Unbounded(Type, "", Paths)
	end

	if #Paths > 0 then
		State.Unbounded += #Paths
		table.insert(State.Lines, `{Indent}{TODO} a client sends this; bound {table.concat(Paths, ", ")}`)
	end
end

local function TypeDeclaration(State: State, Declaration: Declaration, Indent: string)
	local Type = Declaration.Type :: Type
	local Name = Declaration.Name
	local Lines = State.Lines

	if Declaration.IsWrittenOut then
		local Tool = State.Draft.Tool
		table.insert(Lines, `{Indent}-- {Tool}'s {Name} is written out where it was used: a schema cannot name it.`)
		return
	end

	Remarks(State, Indent, { Type }, State.Inbound[Declaration] ~= nil)
	if Type.Kind == "Struct" then
		table.insert(Lines, `{Indent}struct {Name} {Braces(Type.Fields :: { Field }, Indent)}`)
	elseif Type.Kind == "Enum" then
		table.insert(Lines, `{Indent}enum {Name} = \{ {table.concat(Type.Values :: { string }, ", ")} }`)
	elseif Type.Kind == "TaggedEnum" then
		table.insert(Lines, `{Indent}enum {Name} = {VariantsText(Type, Indent)}`)
	elseif Type.Kind == "Map" then
		local Key = TypeText(Type.Key :: Type, Indent)
		table.insert(Lines, `{Indent}map {Name} = \{ [{Key}]: {TypeText(Type.Of :: Type, Indent)} }`)
	else
		table.insert(Lines, `{Indent}type {Name} = {TypeText(Type, Indent)}`)
	end
end

--- Writes a declaration's fields between its braces: a comma after each but the last, none after a
--- comment.
local function Block(State: State, Indent: string, Head: string, Entries: { string })
	local Last = 0
	for Index, Entry in Entries do
		if string.sub(Entry, 1, 2) ~= "--" then
			Last = Index
		end
	end

	table.insert(State.Lines, `{Indent}{Head} \{`)
	for Index, Entry in Entries do
		local Comma = if Index == Last or string.sub(Entry, 1, 2) == "--" then "" else ","
		table.insert(State.Lines, `{Indent}\t{Entry}{Comma}`)
	end
	table.insert(State.Lines, `{Indent}}`)
end

local function EventDeclaration(State: State, Declaration: Declaration, Indent: string, Path: string)
	local IsInbound = Declaration.From ~= "Server"
	Remarks(State, Indent, { Declaration.Data :: Type }, IsInbound)

	local Entries: { string } = {}
	if Declaration.From == nil then
		table.insert(State.Directions, Path)
		table.insert(Entries, `{TODO} {State.Draft.Tool} does not say which side sends this; say it here`)
	end
	table.insert(Entries, `From: {Declaration.From or "Client"}`)

	if Declaration.Reliability == nil then
		table.insert(State.Reliabilities, Path)
		table.insert(Entries, `{TODO} {State.Draft.Tool} does not say whether this is reliable; say it here`)
	end
	table.insert(Entries, `Type: {Declaration.Reliability or "Reliable"}`)
	table.insert(Entries, `Call: {Declaration.Call or "SingleSync"}`)

	if Declaration.Rate then
		table.insert(Entries, `Rate: {Declaration.Rate}`)
	elseif IsInbound then
		table.insert(State.MissingRates, Path)
		table.insert(Entries, `{TODO} Rate: ?, Burst: ?`)
	end

	if Declaration.Data then
		table.insert(Entries, `Data: {TypeText(Declaration.Data, `{Indent}\t`)}`)
	end

	Block(State, Indent, `event {Declaration.Name}`, Entries)
end

local function FunctionDeclaration(State: State, Declaration: Declaration, Indent: string, Path: string)
	--> One half of a function always comes from a client: its arguments, or what it answers with.
	Remarks(State, Indent, {
		(if Declaration.From == "Server" then Declaration.Return else Declaration.Data) :: Type,
	}, true)
	Remarks(State, Indent, {
		(if Declaration.From == "Server" then Declaration.Data else Declaration.Return) :: Type,
	}, false)

	local Entries: { string } = {}
	if Declaration.From == "Server" then
		table.insert(Entries, "From: Server")
	end
	table.insert(Entries, `Yield: {Declaration.Yield or "Coroutine"}`)

	if Declaration.From ~= "Server" then
		table.insert(State.MissingLimits, Path)
		table.insert(Entries, `{TODO} Rate: ?, Concurrency: ?`)
	end

	if Declaration.Data then
		table.insert(Entries, `Data: {TypeText(Declaration.Data, `{Indent}\t`)}`)
	end
	if Declaration.Return then
		table.insert(Entries, `Return: {TypeText(Declaration.Return, `{Indent}\t`)}`)
	end

	Block(State, Indent, `function {Declaration.Name}`, Entries)
end

local function Body(State: State, Declarations: { Declaration }, Indent: string, Prefix: string)
	--> A blank line between declarations, except between two that are a line each: a run of
	--> `type Health = u8(0..100)` reads as the list it is.
	local WasOneLine = false
	for Index, Declaration in Declarations do
		local Start = #State.Lines + 1
		if Index > 1 then
			table.insert(State.Lines, "")
		end

		for _, Comment in (Declaration.Comments or {}) :: { string } do
			table.insert(State.Lines, if Comment == "" then `{Indent}--` else `{Indent}-- {Comment}`)
		end

		local Own = #State.Lines
		local Path = `{Prefix}{Declaration.Name}`
		if Declaration.Kind == "Type" then
			TypeDeclaration(State, Declaration, Indent)
		elseif Declaration.Kind == "Event" then
			EventDeclaration(State, Declaration, Indent, Path)
		elseif Declaration.Kind == "Function" then
			FunctionDeclaration(State, Declaration, Indent, Path)
		else
			table.insert(State.Lines, `{Indent}scope {Declaration.Name} \{`)
			Body(State, Declaration.Body :: { Declaration }, `{Indent}\t`, `{Path}.`)
			table.insert(State.Lines, `{Indent}}`)
		end

		--> A struct of several fields is one entry here, with its line breaks inside it. A
		--> declaration with a comment keeps its blank line: the comment is about it alone.
		local IsOneLine = #State.Lines - Own == 1 and not string.find(State.Lines[#State.Lines], "\n", 1, true)
		if Own == Start and IsOneLine and WasOneLine then
			table.remove(State.Lines, Start)
		end
		WasOneLine = IsOneLine
	end
end

--- "3 things: A, B, C", naming at most six.
local function Counted(Names: { string }, What: string): string
	local Shown = table.move(Names, 1, math.min(#Names, 6), 1, {})
	local More = if #Names > #Shown then `, and {#Names - #Shown} more` else ""
	return `{#Names} {What}: {table.concat(Shown, ", ")}{More}`
end

--- The front end's notes. One item a message, however many places earned it: the first is named,
--- the rest counted.
local function Noted(State: State, Items: { string })
	local Repeats: { [string]: number } = {}
	for _, Note in State.Draft.Notes do
		Repeats[Note.Message] = (Repeats[Note.Message] or 0) + 1
	end

	for _, Note in State.Draft.Notes do
		local Count = Repeats[Note.Message]
		if Count == 0 then
			continue
		end
		Repeats[Note.Message] = 0

		local Where = if Note.Line then `line {Note.Line}: ` else ""
		local Subject = if Note.Subject then `{Note.Subject}: ` else ""
		local More = if Count > 1 then ` (and in {Count - 1} more place(s))` else ""
		table.insert(Items, `{Where}{Subject}{Note.Message}{More}`)
	end
end

local function Checklist(State: State): { string }
	local Items: { string } = {}
	if #State.Directions > 0 then
		table.insert(Items, Counted(State.Directions, "event(s) whose direction you must state"))
	end
	if #State.Reliabilities > 0 then
		table.insert(Items, Counted(State.Reliabilities, "event(s) whose reliability you must state"))
	end
	if #State.MissingRates > 0 then
		table.insert(Items, Counted(State.MissingRates, "event(s) a client fires with no Rate"))
	end
	if #State.MissingLimits > 0 then
		table.insert(Items, Counted(State.MissingLimits, "function(s) a client calls with no Rate or Concurrency"))
	end
	if State.Unbounded > 0 then
		table.insert(Items, `{State.Unbounded} length(s) or value(s) a client sends with no bound; each is marked`)
	end

	Noted(State, Items)

	local HasOutputs = false
	for _, Option in State.Draft.Options do
		HasOutputs = HasOutputs or Option.Name == "ServerOutput"
	end
	if not HasOutputs then
		table.insert(Items, "Add option ServerOutput and option ClientOutput: where the two modules are written.")
	end

	table.insert(Items, "Set option RequireRates = true once every event a client fires has a Rate.")
	table.insert(
		Items,
		"On the server, set SetRateLimitHandler, SetDecodeErrorHandler, SetPacketDropHandler and "
			.. "SetListenerErrorHandler: they are how the game hears of a refusal."
	)
	table.insert(
		Items,
		"Check MaxPacketSize, MaxEventsPerPacket and InboundBytesPerSecond against what the game sends."
	)
	return Items
end

--- The schema's text, and what its reader has to settle before trusting it. Settles `Source` first:
--- see Aliases.luau.
function Print.Render(Source: Draft.Draft): (string, { string })
	Aliases.Settle(Source)

	local State: State = {
		Draft = Source,
		Lines = {},
		Inbound = Inbound.Reachable(Source.Body),
		MissingRates = {},
		MissingLimits = {},
		Unbounded = 0,
		Directions = {},
		Reliabilities = {},
	}

	local Lines = State.Lines
	local Tool = Source.Tool
	table.insert(
		Lines,
		`-- Converted from {Tool} {Source.Version} definitions by BlinkBlox. A draft: read it before you use it.`
	)
	table.insert(
		Lines,
		`-- Each TODO(convert) marks what {Tool}'s definitions have no way to say. The guide explains them:`
	)
	table.insert(Lines, `-- {GUIDES}/coming-from-{string.lower(Tool)}/`)
	table.insert(Lines, "--")
	table.insert(
		Lines,
		"-- Once every event a client fires has a Rate, turn this on, so that none is added without one:"
	)
	table.insert(Lines, "-- option RequireRates = true")

	if #Source.Options > 0 then
		table.insert(Lines, "")
	end
	for _, Option in Source.Options do
		for _, Comment in (Option.Comments or {}) :: { string } do
			table.insert(Lines, if Comment == "" then "--" else `-- {Comment}`)
		end
		table.insert(Lines, `option {Option.Name} = {Option.Value}`)
	end

	if #Source.Body > 0 then
		table.insert(Lines, "")
	end
	Body(State, Source.Body, "", "")
	table.insert(Lines, "")

	return table.concat(Lines, "\n"), Checklist(State)
end

return Print
