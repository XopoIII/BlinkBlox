--!strict
--- The schema's rate limits as constants the game can read, behind `option ExportRates = true`.
---
--- A client that paces what it sends to an event's `Rate`, or holds back as many as its `Burst`,
--- otherwise repeats the two numbers by hand, and they drift the first time either changes. With the
--- option on, every module the compiler writes -- server, client, and the types module -- carries a
--- frozen `Rates` table: `Net.Rates.Report.Burst`.
---
--- Its shape mirrors the schema. A declaration is keyed by its name and a scope nests its own. What
--- sits at the bottom is what the server enforces on that declaration, not what the schema spells
--- out: `Rate` is the declaration's own or `option DefaultRate`, `Burst` its own or the default the
--- generator gives it, and a function adds `Concurrency` when it declares one.
---
--- Only what is limited is there. Limits apply to what a client sends, so a `From: Server`
--- declaration has no entry, and neither has an inbound one with nothing to limit it. A stream's
--- `Rate` is how often the server sends, not a limit, and is left out too. The structural words
--- -- Rate, Burst, Concurrency -- follow `option Casing`; names from the schema are kept as written.
local Parser = require("../Parser")
local Settings = require("../Settings")
local Util = require("./Util")

export type Rate = {
	--> The numbers: set on the leaves, each only where the server enforces it.
	Rate: number?,
	Burst: number?,
	Concurrency: number?,
	--> A table of further rates, in schema order: set on a scope and on the schema itself.
	Entries: { { Key: string, Rate: Rate } }?,
}

--> The structural keys, per casing.
local WORDS: { [string]: { string } } = {
	Rates = { "Rates", "rates", "rates" },
	Rate = { "Rate", "rate", "rate" },
	Burst = { "Burst", "burst", "burst" },
	Concurrency = { "Concurrency", "concurrency", "concurrency" },
}

--> The leaves' keys, in the order they are written.
local FIELDS = { "Rate", "Burst", "Concurrency" }

local Rates = {}

--- The rate and burst the server holds an inbound declaration to, or nothing when it has no rate.
--- The generated rate guard and the exported table both ask here, so they cannot disagree.
function Rates.Effective(
	Value: { Rate: number?, Burst: number? },
	Options: { DefaultRate: number? }
): (number?, number?)
	local Rate = Value.Rate or Options.DefaultRate
	if not Rate then
		return nil, nil
	end

	--> A burst of one would refuse the very first event of a frame whenever the previous frame used
	--> its budget, so the floor is one whole token.
	return Rate, Value.Burst or math.max(math.ceil(Rate), 1)
end

--> What limits one event or function, or nil when nothing does.
local function Of(Declaration: Parser.Declaration, Options: { DefaultRate: number? }): Rate?
	local Value = Declaration.Value :: any
	if Value.From ~= "Client" then
		return nil
	end

	local Rate, Burst = Rates.Effective(Value, Options)
	local Concurrency: number? = if Declaration.Type == "Function" then Value.Concurrency else nil
	if not Rate and not Concurrency then
		return nil
	end

	return { Rate = Rate, Burst = Burst, Concurrency = Concurrency }
end

--- The rates of a list of declarations: a schema's, or a scope's.
function Rates.Declarations(Declarations: { Parser.Declaration }, Options: { DefaultRate: number? }): Rate
	local Entries = {}
	local Seen: { [string]: true } = {}

	local function Add(Name: string, Rate: Rate?)
		if Rate and not Seen[Name] then
			Seen[Name] = true
			table.insert(Entries, { Key = Name, Rate = Rate })
		end
	end

	for _, Declaration in Declarations do
		local Kind = Declaration.Type
		if Kind == "Scope" then
			local Inner = Rates.Declarations((Declaration.Value :: any).Values, Options)
			Add(Declaration.Name, if Inner.Entries and #Inner.Entries > 0 then Inner else nil)
		elseif Kind == "Event" or Kind == "Function" then
			Add(Declaration.Name, Of(Declaration, Options))
		end
	end

	return { Entries = Entries }
end

--- The local every module declares the table under, and then returns as its `Rates` member.
Rates.LOCAL = "BLINK_RATES"

--- The lines declaring the table for a schema, or none when the option is off.
function Rates.Body(Tree: Parser.Body): { string }
	local Options = Tree.Value.Options :: any
	if not Options.ExportRates then
		return {}
	end

	local Word = Rates.Words(Options.Casing)
	local Rate = Rates.Declarations(Tree.Value.Declarations, Options)
	return {
		"\n",
		"--> The schema's rate limits, as the server enforces them (option ExportRates).\n",
		`local {Rates.LOCAL} = {Rates.Luau(Rate, Word)}\n`,
	}
end

--- The word for a structural key under a casing.
function Rates.Words(Casing: Settings.Case?): (string) -> string
	local Index = (Settings.Casings :: { [string]: number })[Casing or "Pascal"] or 1
	return function(Word: string): string
		return WORDS[Word][Index]
	end
end

--- The Luau constructor for `Rate`, frozen at every level, indented from `Depth`.
function Rates.Luau(Rate: Rate, Word: (string) -> string, Depth: number?): string
	local Indent = string.rep("\t", (Depth or 0) + 1)
	local Lines = {}

	if Rate.Entries then
		for _, Entry in Rate.Entries do
			table.insert(
				Lines,
				`{Indent}{Util.FormatKey(Entry.Key)} = {Rates.Luau(Entry.Rate, Word, (Depth or 0) + 1)},`
			)
		end
	else
		for _, Field in FIELDS do
			local Value: number? = (Rate :: any)[Field]
			if Value then
				table.insert(Lines, `{Indent}{Word(Field)} = {Value},`)
			end
		end
	end

	if #Lines == 0 then
		return "table.freeze({})"
	end

	return `table.freeze(\{\n{table.concat(Lines, "\n")}\n{string.rep("\t", Depth or 0)}\})`
end

--- The TypeScript type of `Rate`, every member readonly.
function Rates.Typescript(Rate: Rate, Word: (string) -> string, Depth: number?): string
	local Indent = string.rep("\t", (Depth or 0) + 1)
	local Lines = {}

	local function Member(Key: string, Type: string)
		local Name = if string.match(Key, "^[%a_][%w_]*$") then Key else `"{Key}"`
		table.insert(Lines, `{Indent}readonly {Name}: {Type};`)
	end

	if Rate.Entries then
		for _, Entry in Rate.Entries do
			Member(Entry.Key, Rates.Typescript(Entry.Rate, Word, (Depth or 0) + 1))
		end
	else
		for _, Field in FIELDS do
			if (Rate :: any)[Field] then
				Member(Word(Field), "number")
			end
		end
	end

	if #Lines == 0 then
		return "{}"
	end

	return `\{\n{table.concat(Lines, "\n")}\n{string.rep("\t", Depth or 0)}\}`
end

return Rates
