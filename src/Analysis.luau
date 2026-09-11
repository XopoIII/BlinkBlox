--!strict
--- Semantic checks that run once the whole file is parsed, when every declaration is available and
--- every generic has been substituted.
---
--- They live apart from the parser because they are not parsing: nothing here consumes a token or
--- advances the lexer. They take the finished declarations and say what is wrong with them.
---
--- ONLY THIS FILE'S DECLARATIONS ARE WALKED. An imported scope holds nodes whose spans index the
--- imported source, so that file's own parse raises its diagnostics -- underlining those offsets
--- against this source would point at whatever text happens to sit there.

local Error = require("./Modules/Error")
local Lexer = require("./Lexer")
local Size = require("./Modules/Size")

type Token = Lexer.Token

--- The checks take the source text and file name directly rather than the parser itself: requiring
--- the parser from here would close a cycle, since the parser is what calls them.
--- Structural stand-ins for the parser's AST nodes, for the same reason.
type Declaration = any
type Options = any
type Event = any
type ScopeNode = any

--- Roblox drops an UnreliableRemoteEvent payload past roughly this many bytes. It does so silently
--- and intermittently, which is why the compiler refuses a schema that cannot fit instead of leaving
--- it to be discovered in production.
local DEFAULT_MAX_UNRELIABLE_SIZE = 900

--- Checks the rate limiting fields. Same file-scoping rule as AnalyzeUnreliableSizes: imported
--- declarations are diagnosed by the parse of the file they came from.
local function RateLimits(Source: string, File: string?, Declarations: { Declaration }, Options: Options)
	for _, Declaration in Declarations do
		if Declaration.Type == "Scope" then
			local Scope = Declaration :: ScopeNode
			if not Scope.Value.Imported then
				RateLimits(Source, File, Scope.Value.Values, Options)
			end

			continue
		end

		if Declaration.Type ~= "Event" and Declaration.Type ~= "Function" then
			continue
		end

		local Value = Declaration.Value
		local Identifier: Token = Declaration.Tokens.Identifier

		--> Inbound means "sent to the server". Nothing limits the server itself: it is the party being
		--> protected, and throttling its own traffic would drop what the game meant to send.
		-->
		--> This used to read `if IsEvent then ... else true`, because a function could only ever go
		--> client to server. Now that one can go the other way, treating every function as inbound
		--> would say nothing about a pointless Rate and -- worse -- demand one under RequireRates for
		--> traffic the server itself sends.
		local Inbound = Value.From == "Client"

		if not Inbound then
			if Value.Rate or Value.Burst then
				Error.new(
					Error.AnalyzeMissingRateLimit,
					Source,
					`Rate limiting a Server {string.lower(Declaration.Type)} has no effect`,
					File,
					"Warning"
				)
					:Primary(Identifier, `This {string.lower(Declaration.Type)} is sent BY the server, not to it`)
					:Note("Rate limits apply to inbound traffic only. Remove the field.")
					:Warn()
			end

			continue
		end

		local Effective = Value.Rate or Options.DefaultRate

		--> A burst without a sustained rate has nothing to refill it: the bucket would empty once and
		--> stay empty, which is never what anyone means.
		if Value.Burst and not Effective then
			Error.new(Error.AnalyzeMissingRateLimit, Source, `"Burst" was set without a "Rate"`, File)
				:Primary(Identifier, "Add a Rate, or remove the Burst")
				:Note("Burst is the bucket's capacity; Rate is what refills it.")
				:Emit()
		end

		if Options.RequireRates and not Effective then
			Error.new(Error.AnalyzeMissingRateLimit, Source, `Inbound "{Declaration.Name}" has no rate limit`, File)
				:Primary(Identifier, "Add a Rate, in events per second")
				:Note("option RequireRates is set, so every inbound event and function must declare one.")
				:Emit()
		end
	end
end

--- Refuses unreliable events that cannot fit in a single unreliable packet, and warns about the ones
--- that merely might not.
---
--- Only declarations from THIS file are walked. An imported scope holds nodes whose spans index the
--- imported source, so the parse of that file raises its own diagnostics -- underlining those offsets
--- here would point at unrelated text.
local function UnreliableSizes(Source: string, File: string?, Declarations: { Declaration }, Options: Options)
	local Limit = Options.MaxUnreliableSize or DEFAULT_MAX_UNRELIABLE_SIZE

	for _, Declaration in Declarations do
		if Declaration.Type == "Scope" then
			local Scope = Declaration :: ScopeNode
			if not Scope.Value.Imported then
				UnreliableSizes(Source, File, Scope.Value.Values, Options)
			end

			continue
		end

		if Declaration.Type ~= "Event" then
			continue
		end

		local Event = Declaration :: Event
		local Reliability = Event.Value.Type
		if Reliability ~= "Unreliable" and Reliability ~= "OrderedUnreliable" then
			continue
		end

		local Data = Event.Value.Data
		local Measured = if Data then Size.Sealed(Data :: any) else nil

		--> The event index is one byte, written ahead of the payload, and an ordered event adds its
		--> sequence number on top of that.
		local Header = 1 + (if Reliability == "OrderedUnreliable" then Size.OrderingBytes else 0)
		local Minimum = Header + (if Measured then Measured.Min else 0)
		local Maximum = Header + (if Measured then Measured.Max else 0)
		local Identifier = Event.Tokens.Identifier

		if Minimum > Limit then
			Error.new(
				Error.AnalyzeOversizeUnreliable,
				Source,
				`Unreliable event "{Event.Name}" cannot fit in one packet`,
				File
			)
				:Primary(Identifier, `Always at least {Minimum} bytes, the limit is {Limit}`)
				:Note("Roblox drops unreliable payloads past this size. Send it as a Reliable event instead.")
				:Emit()
		end

		if Maximum <= Limit then
			continue
		end

		--> An unbounded type reports a real but absurd maximum -- a map of structs measures in the
		--> gigabytes -- and quoting that number reads as a compiler bug rather than as advice.
		local Bound = if (Measured and Measured.Unbounded)
			then `Unbounded, and the limit is {Limit} bytes`
			else `Up to {Maximum} bytes, the limit is {Limit}`

		local Diagnostic = Error.new(
			Error.AnalyzePotentiallyOversizeUnreliable,
			Source,
			`Unreliable event "{Event.Name}" may exceed the packet limit`,
			File,
			"Warning"
		):Primary(Identifier, Bound)

		local Culprit = if Measured then Measured.Culprit else nil
		if Culprit then
			Diagnostic:Secondary(Culprit, "This has no upper bound")
		end

		Diagnostic:Note("Bound the variable-length fields -- `string(0..64)`, `u8[..16]` -- or send it reliably.")
			:Warn()
	end
end

--- Best token to underline for a repetition: the brackets say more than the type name does.
local function TokenOf(Node: Declaration): Token?
	local Tokens = Node.Tokens
	if not Tokens then
		return nil
	end

	return Tokens.Range or Tokens.Primitive
end

--- Whether one element of a repetition costs nothing to decode -- no buffer bytes, no bits, and no
--- slot in the instance table.
local function Costless(Node: Declaration): boolean
	local Measured = Size.Sealed(Node :: any)
	return Measured.Max == 0 and Measured.Refs == 0
end

--- Refuses a repetition whose element count is read off the wire but whose elements cost nothing to
--- decode.
---
--- A decode loop is bounded by what its body consumes. An element that reads buffer bytes can only
--- repeat until the packet runs out, and MaxPacketSize caps that. An element that takes a slot in
--- the instance table runs out of instances, which the reader checks. An element that does NEITHER
--- gives the loop nothing to exhaust: `struct {}[]` turns a two-byte count into 65535 iterations and
--- 65535 table allocations, and 64 such events fit in a couple of hundred bytes.
---
--- A bound the author writes settles it: twenty costless elements are twenty iterations, and the
--- ceiling is visible in the schema. What is refused is the ceiling nobody chose -- a bare `[]`,
--- which inherits what its u16 prefix holds, and a map, which takes no range in the language at all.
---
--- Same file-scoping rule as the checks above: imported declarations are diagnosed by the parse of
--- the file they came from.
local function CostlessRepetitions(Source: string, File: string?, Declarations: { Declaration })
	local function Report(Node: Declaration, What: string)
		local Diagnostic =
			Error.new(Error.AnalyzeCostlessRepetition, Source, `{What} of a type that costs nothing to decode`, File)

		local Culprit = TokenOf(Node)
		if Culprit then
			Diagnostic:Primary(Culprit, "The element count is read from the packet")
		end

		Diagnostic:Note(
			"Each element reads no bytes and takes no instance slot, so nothing stops the decode "
				.. "loop: a two-byte count is worth 65535 iterations to a hostile client."
		)
			:Note("Bound it -- `[..16]` -- or give the element a field that is actually sent.")
			:Emit()
	end

	local function Inspect(Node: Declaration)
		if type(Node) ~= "table" or not Node.Type then
			return
		end

		local Kind = Node.Type
		local Value = Node.Value

		if Kind == "Array" then
			local Range = Value.Range
			local RangeToken: Token? = Node.Tokens.Range
			local Written = if RangeToken then RangeToken.Value ~= "[]" else false

			--> A fixed-length array is unrolled against a count the schema wrote, and a bounded one
			--> states its own ceiling -- twenty costless elements are twenty iterations. A bare `[]`
			--> inherits whatever its u16 prefix can hold, which nobody chose.
			if Range and Range.Min ~= Range.Max and not Written and Costless(Value.Of) then
				Report(Node, "Array")
			end

			Inspect(Value.Of)
		elseif Kind == "Map" then
			local Values = Value.Values
			if Costless(Values[1]) and Costless(Values[2]) then
				Report(Node, "Map")
			end

			Inspect(Values[1])
			Inspect(Values[2])
		elseif Kind == "Optional" then
			Inspect(Value.Of)
		elseif Kind == "Struct" or Kind == "Tuple" then
			for _, Field in Value.Values do
				Inspect(Field)
			end
		elseif Kind == "TagEnum" then
			for _, Variant in Value.Values do
				for _, Field in (Variant :: Declaration).Value.Values do
					Inspect(Field)
				end
			end
		end
	end

	for _, Declaration in Declarations do
		if Declaration.Type == "Scope" then
			local Scope = Declaration :: ScopeNode
			if not Scope.Value.Imported then
				CostlessRepetitions(Source, File, Scope.Value.Values)
			end

			continue
		end

		--> A generic template is not a payload. Its parameters are unresolved here, so every one of
		--> them would measure as costing nothing; it is the substituted copies that reach the wire,
		--> and those are ordinary declarations by the time this runs.
		if Declaration.Value and Declaration.Value.Generics then
			continue
		end

		if Declaration.Type == "Event" then
			Inspect(Declaration.Value.Data)
		elseif Declaration.Type == "Function" then
			Inspect(Declaration.Value.Data)
			Inspect(Declaration.Value.Return)
		else
			--> A standalone `type` declaration carries its node kind directly, and it is exported
			--> with a public reader of its own, so it is reachable whether an event names it or not.
			Inspect(Declaration)
		end
	end
end

--- Which decoded types can serve as a map key, and which produce a value the receiver can never
--- look anything up by.
---
--- A key has to survive the round trip AS A KEY. A string, a number, a boolean and a plain `enum`
--- all decode to the same value the sender had, so they do. Everything else decodes to a FRESH
--- TABLE per entry, and in Luau a table is its own identity: the receiver ends up with
--- `[Table(0x...)] = value`, which nothing it constructs will ever match. The map is not corrupt --
--- every byte round-trips -- it is simply unusable, which is worse, because it looks like it worked.
local UNUSABLE_KEYS: { [string]: string } = {
	Struct = "a struct",
	TagEnum = "a tagged enum",
	Map = "a map",
	Set = "a set",
	Array = "an array",
	Tuple = "a type pack",
}

--- Refuses map keys of a type that cannot be looked up.
---
--- Runs here rather than in the parser because generics are already substituted by the time this
--- walks: `GenericMap<u8[], f64>` is an ordinary map with an array key at this point, and checking
--- where the map is written would not see it.
local function MapKeys(Source: string, File: string?, Declarations: { Declaration })
	local function Inspect(Node: Declaration)
		if type(Node) ~= "table" or not Node.Type then
			return
		end

		local Kind = Node.Type
		local Value = Node.Value

		if Kind == "Map" then
			local Key = Value.Values[1]
			local Unusable = Key and UNUSABLE_KEYS[Key.Type]
			if Unusable then
				local Diagnostic =
					Error.new(Error.AnalyzeReferenceInvalidType, Source, `A map cannot be keyed by {Unusable}`, File)

				local Culprit = (Node.Tokens and Node.Tokens.Key) or TokenOf(Key) or TokenOf(Node)
				if Culprit then
					Diagnostic:Primary(Culprit, "This key decodes to a new table for every entry")
				end

				Diagnostic:Note(
					"Each decoded key is a table with its own identity, so nothing the receiving side "
						.. "builds will ever index the map -- every entry is reachable only by iterating it."
				)
					:Note("Key it by a string, a number, a boolean or an enum, and move the rest into the value.")
					:Emit()
			end

			Inspect(Value.Values[1])
			Inspect(Value.Values[2])
		elseif Kind == "Array" or Kind == "Optional" then
			Inspect(Value.Of)
		elseif Kind == "Struct" or Kind == "Tuple" then
			for _, Field in Value.Values do
				Inspect(Field)
			end
		elseif Kind == "TagEnum" then
			for _, Variant in Value.Values do
				for _, Field in (Variant :: Declaration).Value.Values do
					Inspect(Field)
				end
			end
		end
	end

	for _, Declaration in Declarations do
		if Declaration.Type == "Scope" then
			local Scope = Declaration :: ScopeNode
			if not Scope.Value.Imported then
				MapKeys(Source, File, Scope.Value.Values)
			end

			continue
		end

		--> An uninstantiated generic is not a concrete type yet; its instantiations are walked where
		--> they are used, with the substitution already made.
		if Declaration.Value and Declaration.Value.Generics then
			continue
		end

		if Declaration.Type == "Event" then
			Inspect(Declaration.Value.Data)
		elseif Declaration.Type == "Function" then
			Inspect(Declaration.Value.Data)
			Inspect(Declaration.Value.Return)
		else
			Inspect(Declaration)
		end
	end
end

return {
	RateLimits = RateLimits,
	UnreliableSizes = UnreliableSizes,
	CostlessRepetitions = CostlessRepetitions,
	MapKeys = MapKeys,
}
