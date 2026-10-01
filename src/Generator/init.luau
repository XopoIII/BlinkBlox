--!strict
--!native
--!optimize 2

local Parser = require("./Parser")
local Settings = require("./Settings")

local Builder = require("./Modules/Builder")
local Datatypes = require("./Templates/Datatypes")
local Table = require("./Modules/Table")

local Batches = require("@self/Batches")
local Bodies = require("@self/Bodies")
local Fragments = require("@self/Fragments")
local GenerateTypescript = require("@self/Typescript")
local Lifecycle = require("@self/Lifecycle")
local Limits = require("@self/Limits")
local Outbound = require("@self/Outbound")
local Packets = require("@self/Packets")
local Prefabs = require("@self/Prefabs")
local Returns = require("@self/Returns")
local Serde = require("@self/Serde")
--> `option TrafficStats`; every call below emits nothing when it is off.
local Traffic = require("@self/Traffic")
--> Everything one generation run builds up, shared with the generator's other files. See State.luau.
local State = require("@self/State")
local Util = require("@self/Util")

local EVENTS_TYPE = Fragments.EVENTS_TYPE
local DIRECTIVES = Fragments.DIRECTIVES
local VERSION_HEADER = Fragments.VERSION_HEADER
local SYNC_VALIDATION_BODY = Fragments.SYNC_VALIDATION_BODY

local DEFAULT_MAX_EVENTS_PER_PACKET = Fragments.DEFAULT_MAX_EVENTS_PER_PACKET

--> The stream runtime (the server's half, then the client's) and the stamp runtime (the unwrap both
--> share, the server's clamp, the client's stamp). Spliced only into a module that uses them.
local StreamParts = string.split(require("./Templates/Stream"), "-- SPLIT --")
local Stamps = require("@self/Stamp")

--> The client's and the server's halves depend on the options; Lifecycle assembles them.
local Sources = {
	Base = require("./Templates/Base"),
	Shared = { "", "" },
}

type Context = State.Context

local Generators = require("@self/Generators")

--> Each adds its declaration generator to the Serde table as it loads, which is where the walk in
--> Generators.luau dispatches an event or a function to; the values are not used here.
local _ = {
	require("@self/Event"),
	require("@self/Function"),
}

local Generator = {}

function Generator.Reset()
	State.Reset()
	Traffic.Reset()
end

--> The stubs.
-->
--> Required in edit mode, where `RunService:IsRunning()` is false: no remotes exist, so every
--> entry point becomes a stub. That includes Roblox "stories" (Hoarcekat, UILabs, Flipbook),
--> which is what upstream issue #81 is about.
-->
--> The stub has to keep the SHAPE of the real API, not merely exist. A bare `function() end`
--> made three things break in a story rather than degrade quietly:
--> `On` returned nil, so `local Disconnect = Net.Foo.On(...)` followed by `Disconnect()` raised;
--> `Iter` returned nil, so `for _ in Net.Foo.Iter() do` raised instead of iterating zero times;
--> and `StepReplication` was missing altogether, so it was nil under ManualReplication -- while
--> the real Returns table has always carried it.
-->
--> Under ClientConnectTimeout the same stubs are what a client that could not connect returns;
--> see Lifecycle.
local function Stubs(): { string }
	local Preamble, StubCondition = Lifecycle.Stubs(State.Context, State.Options)
	State.Noop.Push(StubCondition)
	State.Noop.Push(`local NOOP = function() end`, 0, 1)
	State.Noop.Push(`local NOOP_RETURNING = function() return NOOP end`, 0, 1)
	if Lifecycle.InvokeStub(State.Context, State.Options) ~= "NOOP" then
		State.Noop.Push(Lifecycle.NOOP_INVOKE, 0, 1)
	end
	State.Noop.Push(`local Returns = table.freeze(\{`, 0, 1)

	return Preamble
end

--> The members every module returns beside its events, stubbed alike, and the lines that replicate.
local function Members(): Builder.Builder
	local Replication = Builder.new()
	State.Return.Push(`{State.Casing.StepReplication} = StepReplication,`, 1, 1)
	--> The stub table has to expose it too. Under ManualReplication a story calls StepReplication
	--> itself, and its absence here made that a nil call rather than a no-op.
	State.Noop.Push(`{State.Casing.StepReplication} = NOOP,`, 0, 2)

	State.Return.Push(`{State.Casing.SetRateLimitHandler} = SetRateLimitHandler,`, 1, 1)
	State.Noop.Push(`{State.Casing.SetRateLimitHandler} = NOOP,`, 0, 2)
	State.Return.Push(`{State.Casing.SetDecodeErrorHandler} = SetDecodeErrorHandler,`, 1, 1)
	State.Noop.Push(`{State.Casing.SetDecodeErrorHandler} = NOOP,`, 0, 2)
	State.Return.Push(`{State.Casing.SetPacketDropHandler} = SetPacketDropHandler,`, 1, 1)
	State.Noop.Push(`{State.Casing.SetPacketDropHandler} = NOOP,`, 0, 2)
	State.Return.Push(`{State.Casing.SetListenerErrorHandler} = SetListenerErrorHandler,`, 1, 1)
	State.Noop.Push(`{State.Casing.SetListenerErrorHandler} = NOOP,`, 0, 2)

	local Returned, Stubbed = Lifecycle.Members(State.Context, State.Options, State.Casing)
	for Index, Line in Returned do
		State.Return.Push(Line, 1, 1)
		State.Noop.Push(Stubbed[Index], 0, 2)
	end
	Traffic.Members()
	if State.Options.ExportLimits then
		local Member = Limits.Words(State.Options.Casing :: Settings.Case?)("Limits")
		State.Return.Push(`{Member} = {Limits.LOCAL},`, 1, 1)
		State.Noop.Push(`{Member} = {Limits.LOCAL},`, 0, 2)
	end

	if not State.Options.ManualReplication then
		for _, Line in Fragments.Heartbeat(State.Context, State.Options) do
			Replication.Push(Line)
		end
	end

	return Replication
end

--> Refuses a second module on the same remote scope.
local function ScopeValidation(): { string }
	local ScopeValidationBody = {}
	if State.Context ~= "Shared" then
		--> `BLINK`, not BlinkBlox, for the same reason the remotes keep the name; see Util.Constants.
		local RemoteScope = State.Options.RemoteScope or "BLINK"
		ScopeValidationBody = {
			"_G._BLINK = _G._BLINK or {}\n",
			`if _G._BLINK["{RemoteScope}"] then\n`,
			`\terror("[BlinkBlox]: An instance of BlinkBlox is already running with the remote scope \\"{RemoteScope}\\". Change the remote scope of either instance to avoid conflicts.")\n`,
			"end\n",
			`_G._BLINK["{RemoteScope}"] = true\n`,
		}
	end

	return ScopeValidationBody
end

--> The helpers a prefab asked for, spliced only into a module that uses them.
local function Helpers(): { string }
	return Table.Merge(
		(if Prefabs.Required.Rotation then Fragments.ROTATION_HELPERS else {}),
		(if Prefabs.Required.PackedRows then Fragments.PACKED_ROWS else {}),
		(if Prefabs.Required.PackedCalibration then Fragments.PACKED_CALIBRATION else {}),
		(if Prefabs.Required.EnumItems then { Datatypes.EnumItems } else {}),
		(if Prefabs.Required.ColorSequences then { Datatypes.ColorSequences } else {}),
		(if Prefabs.Missing.Count > 0 then Fragments.MISSING_INSTANCE else {})
	)
end

function Generator.Generate(FileContext: Context, AbstractSyntaxTree: Parser.Body): string
	local Imports = Builder.new()

	Generator.Reset()
	State.Context = FileContext
	State.Options = AbstractSyntaxTree.Value.Options
	State.Casing = Settings.GetCasing((State.Options.Casing :: Settings.Case) or "Pascal")
	local Preamble = Stubs()
	local ReliableConnection, UnreliableConnection = Packets.Connections()

	--> The size cap alone does not bound the work: a packet of single-byte event tags decodes one
	--> event per byte, so an 8 KB packet still means thousands of listener dispatches. Counting the
	--> decoded events bounds that directly.
	local MaxEvents = State.Options.MaxEventsPerPacket or DEFAULT_MAX_EVENTS_PER_PACKET
	local DecodeLoop = Packets.DecodeLoop(MaxEvents)

	State.Reliables = Packets.OpenDecode("Reliable")
	State.Unreliables = Packets.OpenDecode("Unreliable")

	local Replication = Members()

	--> Parse declarations
	Generators.AbstractSyntaxTree(AbstractSyntaxTree.Value.Declarations)

	--> Import async libraries, once the declarations have said whether this side calls into them.
	--> Function.luau refuses a Future or Promise function when the path is missing or empty, so a
	--> flag set here always has a path to require.
	if State.UsesFuture then
		Imports.Push(`local Future = require({State.Options.FutureLibrary})`)
	end

	if State.UsesPromise then
		Imports.Push(`local Promise = require({State.Options.PromiseLibrary})`)
	end

	--> Generate context source
	local Source = Lifecycle.Sources(State.Context, State.Options)
	State.Reliables = Packets.CloseIndex(State.Reliables, State.Channels.Reliable.Branches)
	State.Unreliables = Packets.CloseIndex(State.Unreliables, State.Channels.Unreliable.Branches)

	local ReliableDecoder, UnreliableDecoder = State.Reliables, State.Unreliables
	ReliableConnection = Packets.CloseDecode(ReliableDecoder, ReliableConnection, "Reliable", MaxEvents)
	UnreliableConnection = Packets.CloseDecode(UnreliableDecoder, UnreliableConnection, "Unreliable", MaxEvents)

	State.Noop.Push(`\})`, 0, 1)
	--> Through `any`: the stub table is as large as the module's API, and a direct cast has the new type
	--> solver compare it with the module's type field by field, which it gives up on as too complex.
	State.Noop.Push(`return (Returns :: any) :: {EVENTS_TYPE}`, 0, 1)
	State.Noop.Push(`end`, 0, 0)

	local MergedOutput = Table.Merge(
		DIRECTIVES,
		VERSION_HEADER,
		ScopeValidation(),
		string.split(Source[1], "\r"),
		Imports.DumpLines(),
		{ "local SerdesFunctions = {}\n" },
		Util.Constants(State.Options.RemoteScope, AbstractSyntaxTree),
		string.split(Sources.Base, "\r"),
		Traffic.Body(),
		Helpers(),
		Bodies.RateTemplate(),
		Bodies.Ordering(),
		Bodies.UnreliableGuard(),
		Bodies.PacketLimits(),
		Outbound.Body(),
		(if State.Options.SyncValidation then SYNC_VALIDATION_BODY else {}),
		State.Events.DumpLines(),
		State.LuauTypes.DumpLines(),
		State.UserTypes.DumpLines(),
		Limits.Body(AbstractSyntaxTree),
		Preamble,
		State.Noop.DumpLines(),
		string.split(Outbound.Flush(Traffic.Template(Source[2])), "\r"),
		Batches.Body(),
		Stamps.Runtime(),
		(
			if State.UsesStreams
				then { if State.Context == "Server" then Outbound.Streams(StreamParts[1]) else StreamParts[2] }
				else {}
		),
		State.Streams.DumpLines(),
		Lifecycle.Connections(
			State.Context,
			State.Options,
			Table.Merge(
				(
					if Prefabs.Missing.Count > 0 and State.Context == "Client"
						then Fragments.MISSING_INSTANCE_CLIENT
						else {}
				),
				DecodeLoop,
				Replication.DumpLines(),
				ReliableDecoder.Content,
				UnreliableDecoder.Content,
				ReliableConnection.Content,
				UnreliableConnection.Content
			)
		),
		Returns.Assemble(State.Return.DumpLines()),
		{ `type {EVENTS_TYPE} = typeof(Returns)\n`, `return Returns :: {EVENTS_TYPE}` }
	)

	return table.concat(MergedOutput)
end
function Generator.GenerateShared(AbstractSyntaxTree: Parser.Body): string
	Generator.Reset()
	State.Context = "Shared"
	State.Options = AbstractSyntaxTree.Value.Options
	State.Casing = Settings.GetCasing((State.Options.Casing :: Settings.Case) or "Pascal")

	if State.Options.ExportLimits then
		State.Return.Push(`{Limits.Words(State.Options.Casing :: Settings.Case?)("Limits")} = {Limits.LOCAL},`, 1, 1)
	end

	--> Parse declarations
	Generators.AbstractSyntaxTree(AbstractSyntaxTree.Value.Declarations)

	--> Generate context source
	local Source = Sources.Shared
	local MergedOutput = Table.Merge(
		DIRECTIVES,
		VERSION_HEADER,
		string.split(Source[1], "\r"),
		string.split(Sources.Base, "\r"),
		Helpers(),
		State.LuauTypes.DumpLines(),
		{ "\n" },
		State.UserTypes.DumpLines(),
		string.split(Source[2], "\r"),
		Limits.Body(AbstractSyntaxTree),
		{ "\n" },
		{ `\nreturn \{\n` },
		State.Return.DumpLines(),
		{ "\n}" }
	)

	return table.concat(MergedOutput)
end

function Generator.GenerateTypescript(FileContext: Context, AbstractSyntaxTree: Parser.Body): string
	return GenerateTypescript(FileContext, AbstractSyntaxTree)
end

--> Closes the loop between the two halves. Serde emits the contents of a struct, array or map by
--> calling back into the dispatcher above, which is defined here because it needs this file's state.
Serde.Emit = Generators.UserType

return Generator
