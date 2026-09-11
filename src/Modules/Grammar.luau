--!strict
--- The tables that describe the shape of the language rather than how it is parsed: which options a
--- file accepts, which fields an `event` or a `function` declares, which keywords open a
--- declaration. They were extracted from Parser.luau, which is on the size ratchet in
--- scripts/check-file-size.sh and had no room to grow.
---
--- Data only, so this module requires nothing but the lexer's token types. Everything that reads a
--- token or raises a diagnostic stays in Parser.luau -- put behaviour here and the cycle comes back.

local Lexer = require("../Lexer")

--- Every kind of node the parser can produce. Parser.luau aliases this rather than restating it.
export type Declarations =
	"Map"
	| "Set"
	| "Enum"
	| "TagEnum"
	| "Tuple"
	| "Struct"
	| "Primitive"
	| "Generic"
	| "Array"
	| "Event"
	| "Function"
	| "Scope"
	| "Optional"

export type EventOption = {
	Key: string,
	Type: Lexer.Types,
	Values: { any },
	Optional: true?,
	--- Field whose value is a NUMBER the author chooses rather than one of a fixed set of keywords.
	--- `Values` cannot express that: it is checked with `table.find`, so a rate of 5 would have to be
	--- listed alongside every other rate anyone might want.
	Numeric: true?,
}

export type Bucket = "Types" | "Scopes"

export type Keyword = {
	Class: string,
	Type: Declarations,
	Generics: boolean,
	Exportable: boolean,
}

local Grammar = {}

Grammar.OPTIONS = {
	Casing = "Identifier",
	UseColon = "Boolean",
	UsePolling = "Boolean",
	Typescript = "Boolean",
	TypesOutput = "String",
	ClientOutput = "String",
	ServerOutput = "String",
	FutureLibrary = "String",
	PromiseLibrary = "String",
	SyncValidation = "Boolean",
	WriteValidations = "Boolean",
	ManualReplication = "Boolean",
	RemoteScope = "String",
	MaxPacketSize = "Number",
	MaxEventsPerPacket = "Number",
	MaxInstancesPerPacket = "Number",
	MaxUnreliableSize = "Number",
	DefaultRate = "Number",
	RequireRates = "Boolean",
	Predict = "Boolean",
	InvocationTimeout = "Number",
} :: { [string]: Lexer.Types }

Grammar.EVENT = {
	{ Key = "From", Type = "Identifier", Values = { "Client", "Server" } },
	{ Key = "Type", Type = "Identifier", Values = { "Reliable", "Unreliable", "OrderedUnreliable" } },
	{ Key = "Call", Type = "Identifier", Values = { "SingleSync", "SingleAsync", "ManySync", "ManyAsync", "Polling" } },
	{ Key = "Poll", Type = "Boolean", Values = { true, false }, Optional = true },
	{ Key = "Rate", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Burst", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Data", Type = "Identifier", Values = {}, Optional = true },
} :: { EventOption }

Grammar.FUNCTION = {
	{ Key = "Yield", Type = "Identifier", Values = { "Future", "Promise", "Coroutine" } },
	{ Key = "Rate", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Burst", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Data", Type = "Identifier", Values = {}, Optional = true },
	{ Key = "Return", Type = "Identifier", Values = {}, Optional = true },
} :: { EventOption }

Grammar.BUCKETS = {
	Type = "Types",
	Event = "Scopes",
	Function = "Scopes",
	Scope = "Scopes",
} :: { [string]: Bucket }

Grammar.KEYWORDS = {
	map = {
		Type = "Map",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	set = {
		Type = "Set",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	enum = {
		Type = "Enum",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	type = {
		Type = "Primitive",
		Class = "Type",
		Generics = false,
		Exportable = true,
	},
	struct = {
		Type = "Struct",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	event = {
		Type = "Event",
		Class = "Event",
		Generics = false,
		Exportable = false,
	},
	["function"] = {
		Type = "Function",
		Class = "Function",
		Generics = false,
		Exportable = false,
	},
	scope = {
		Type = "Scope",
		Class = "Scope",
		Generics = false,
		Exportable = false,
	},
} :: { [string]: Keyword }

--- The three composite types whose bodies may be written in terms of a generic parameter.
Grammar.GENERICS_TYPES = {
	Map = true,
	Struct = true,
	TagEnum = true,
}

--- Names the generated module already uses at the top level, so a declaration may not take them.
Grammar.RESERVED = {
	StepReplication = true,
	SetRateLimitHandler = true,
}

--- Luau's reserved words. A named type-pack element becomes a LOCAL VARIABLE in the generated
--- module -- unlike a struct field, which becomes a table key and is quoted by FormatKey -- so one
--- of these as a name would emit code that does not compile.
Grammar.LUAU_KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

return Grammar
