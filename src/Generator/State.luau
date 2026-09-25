--!strict
--- Everything one generation run builds up, in one table.
---
--- These were module-level locals of Generator/init.luau, and several of them are REASSIGNED while
--- a run is under way -- an event swaps `Reliables` for the block it just branched into. A local is
--- an upvalue of the file that declares it, so no other file could take part in generating. Held as
--- fields of one shared table, the event, function and type generators can live in files of their
--- own and still read and write the same values.
---
--- A run starts with `State.Reset`, then sets `Context`, `Options` and `Casing` from the schema.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Settings = require("../Settings")

export type Context = "Client" | "Server" | "Shared"

export type State = {
	--- The scope whose declarations are being generated; swapped on the way into a nested scope.
	Scope: Parser.Scope,
	Context: Context,
	Casing: Settings.Cases,
	Options: Parser.Options,

	--- The edit-mode stub table, the events table, the serdes of named types, their Luau types,
	--- and the public API table.
	Noop: Builder.Builder,
	Events: Builder.Builder,
	UserTypes: Builder.Builder,
	LuauTypes: Builder.Builder,
	Return: Builder.Builder,
	--- Each stream's scheduler entry and the send it calls, emitted after the stream runtime.
	Streams: Builder.Builder,

	--- The decode branch each channel's next event is added to; reassigned as events are added.
	Reliables: Blocks.Block,
	Unreliables: Blocks.Block,

	--- Set when the schema declares at least one OrderedUnreliable event, so the sequence
	--- bookkeeping is emitted only where something uses it.
	UsesOrdering: boolean,

	--- Set when the schema declares a stream, so the stream runtime (Templates/Stream.luau) is
	--- emitted only where something uses it.
	UsesStreams: boolean,

	--- Set when this side's module invokes a function whose Yield is Future or Promise -- only the
	--- invoking side does -- so the library is required only by a module that calls into it. A
	--- require nothing used was a lint warning in every listening module.
	UsesFuture: boolean,
	UsesPromise: boolean,

	--- One entry per rate-limited event or function, in the order they were generated. Each takes
	--- four consecutive numbers in the per-player bucket, so the entry at index N starts at slot
	--- (N - 1) * 4 + 1.
	RateSlots: { { Rate: number, Burst: number } },

	--- How many events each channel carries, and whether this side listens on it.
	Channels: { [string]: { Count: number, Listening: boolean } },

	Reset: () -> (),
}

local State: State = {
	Scope = nil :: any,
	Context = "Shared",
	Casing = nil :: any,
	Options = nil :: any,

	Noop = Builder.new(),
	Events = Builder.new(),
	UserTypes = Builder.new(),
	LuauTypes = Builder.new(),
	Return = Builder.new(),
	Streams = Builder.new(),

	Reliables = nil :: any,
	Unreliables = nil :: any,

	UsesOrdering = false,
	UsesStreams = false,
	UsesFuture = false,
	UsesPromise = false,
	RateSlots = {},
	Channels = {
		Reliable = { Count = 0, Listening = false },
		Unreliable = { Count = 0, Listening = false },
	},

	Reset = nil :: any,
}

function State.Reset()
	State.Noop = Builder.new()
	State.Events = Builder.new()
	State.UserTypes = Builder.new()
	State.LuauTypes = Builder.new()
	State.Return = Builder.new()
	State.Streams = Builder.new()

	table.clear(State.RateSlots)
	table.clear(Prefabs.Required)
	State.UsesOrdering = false
	State.UsesStreams = false
	State.UsesFuture = false
	State.UsesPromise = false

	for _, Channel in State.Channels do
		Channel.Count = 0
		Channel.Listening = false
	end
end

return State
