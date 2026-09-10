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

		local IsEvent = (Declaration.Type == "Event")
		if not IsEvent and Declaration.Type ~= "Function" then
			continue
		end

		local Value = Declaration.Value
		local Identifier: Token = Declaration.Tokens.Identifier

		--> Functions are always client to server; only an event can go the other way. Nothing limits
		--> the server: it is the party being protected, and throttling its own replication would drop
		--> traffic the game meant to send.
		local Inbound = if IsEvent then Value.From == "Client" else true

		if not Inbound then
			if Value.Rate or Value.Burst then
				Error.new(
					Error.AnalyzeMissingRateLimit,
					Source,
					`Rate limiting a Server event has no effect`,
					File,
					"Warning"
				)
					:Primary(Identifier, "This event is sent BY the server, not to it")
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

return {
	RateLimits = RateLimits,
	UnreliableSizes = UnreliableSizes,
}
