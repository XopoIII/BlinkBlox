--!strict
--- The tables that describe the shape of the language rather than how it is parsed: which options a
--- file accepts, which fields an `event` or a `function` declares, which keywords open a
--- declaration. They were extracted from the parser when it was over its size limit and had no room
--- to grow.
---
--- Data only, so this module requires nothing but the lexer's token types. Everything that reads a
--- token or raises a diagnostic stays in src/Parser/ -- put behaviour here and the cycle comes back.

local Lexer = require("../Lexer")

--- Every kind of node the parser can produce. AST.luau aliases this rather than restating it.
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
	InboundBytesPerSecond = "Number",
	InboundBurst = "Number",
	DefaultRate = "Number",
	RequireRates = "Boolean",
	Predict = "Boolean",
	InvocationTimeout = "Number",
} :: { [string]: Lexer.Types }

--> Defaults the option checks and the generator both need. Here because this module is data only,
--> and the generator's Fragments cannot be required from the option parser.
-->
--> The inbound budget charges every packet at least `InboundFloor` bytes, so a flood of tiny packets
--> is not free, and refills at `InboundRatePackets` full-size packets a second.
Grammar.DEFAULTS = {
	MaxPacketSize = 8192,
	InboundFloor = 128,
	InboundRatePackets = 8,
}

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
	--- Optional, and defaulting to Client, because every schema written before this existed means
	--- "the client asks the server" -- which was the only direction Blink had.
	{ Key = "From", Type = "Identifier", Values = { "Client", "Server" }, Optional = true },
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
	SetDecodeErrorHandler = true,
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

--- Names the public functions of a generated module use in their own bodies. A named type-pack
--- element becomes a PARAMETER of those functions -- `Fire(chefId, dish)` -- so an element named after
--- one of these shadows it there: `Player` would be the payload rather than the recipient, `Load`
--- a number rather than the function every send begins with. Everywhere else in the module the
--- elements travel under positional names, so this is the whole list.
Grammar.WRAPPER_NAMES = {
	Player = true,
	Players = true,
	PlayersMap = true,
	Load = true,
	Save = true,
	Mark = true,
	Rollback = true,
	Cursor = true,
	Instances = true,
	Sent = true,
	Failure = true,
	Previous = true,
	SerdesFunctions = true,
	SavePlayerBuffer = true,
	CheckUnreliableSize = true,
	Buffer = true,
	Size = true,
	SendBuffer = true,
	SendCursor = true,
	SendInstances = true,
	Allocate = true,
	Position = true,
	Unreliable = true,
	Reliable = true,
	NextOrder = true,
	List = true,
	Except = true,
	InvocationIdentifier = true,
	InvokePlayer = true,
	ClaimInvocation = true,
	Invocations = true,
	PlayerInvocations = true,
	ReleaseInvocation = true,
	ParkInvocation = true,
	TimeoutInvocation = true,
	TimeoutPlayerInvocation = true,
	Success = true,
	Future = true,
	Promise = true,
	Resolve = true,
	Reject = true,
	OnCancel = true,
	Events = true,
	Queue = true,
	Listener = true,
	ListenerRan = true,
	ListenerFailure = true,
	SerdesEvent = true,
	Spawn = true,
	pcall = true,
	error = true,
	buffer = true,
	table = true,
	task = true,
	coroutine = true,
	typeof = true,
}

--- The option block's shape. Moved here from Parser.luau so that the code which PARSES it can
--- live outside the parser without requiring it back.
export type Options = {
	Casing: string?,
	UseColon: boolean?,
	UsePolling: boolean?,
	Typescript: boolean?,
	TypesOutput: string?,
	ClientOutput: string?,
	ServerOutput: string?,
	FutureLibrary: string?,
	PromiseLibrary: string?,
	SyncValidation: boolean?,
	WriteValidations: boolean?,
	ManualReplication: boolean?,
	RemoteScope: string?,

	--> Inbound limits. These bound what a hostile client can make the server do inside a single
	--> packet; see the generator's INBOUND_GUARD.
	MaxPacketSize: number?,
	MaxEventsPerPacket: number?,
	MaxInstancesPerPacket: number?,

	--> The per-player inbound budget: bytes a client's packets may cost the server each second, and
	--> the most it may bank. Checked before a packet is decoded, unlike the limits per packet.
	InboundBytesPerSecond: number?,
	InboundBurst: number?,

	--> Largest payload an unreliable event may carry. Roblox drops an UnreliableRemoteEvent past
	--> roughly 900 bytes, so this is a property of the platform rather than a preference -- it is
	--> configurable only because that ceiling has moved before.
	MaxUnreliableSize: number?,

	--> Rate limiting. `DefaultRate` applies to every inbound event and function that does not set its
	--> own `Rate`; `RequireRates` turns a missing rate into a compile error, which is how a project
	--> stops one from being forgotten.
	DefaultRate: number?,
	RequireRates: boolean?,

	--> Generates a Predict entry point on each event, which dispatches to local listeners without
	--> touching remotes. See the generator.
	Predict: boolean?,

	--> Seconds before an unanswered invocation fails its caller and gives its slot back.
	InvocationTimeout: number?,
}

return Grammar
