--!strict
--!native
--!optimize 2

local Parser = require("./Parser")
local Settings = require("./Settings")

local Builder = require("./Modules/Builder")
local Table = require("./Modules/Table")

local Batches = require("@self/Batches")
local Blocks = require("@self/Blocks")
local Bodies = require("@self/Bodies")
local Decode = require("@self/Decode")
local Fragments = require("@self/Fragments")
local GenerateTypescript = require("@self/Typescript")
local Lifecycle = require("@self/Lifecycle")
local Limits = require("@self/Limits")
local Outbound = require("@self/Outbound")
local Prefabs = require("@self/Prefabs")
local Serde = require("@self/Serde")
--> `option TrafficStats`; every call below emits nothing when it is off.
local Traffic = require("@self/Traffic")
--> Everything one generation run builds up, shared with the generator's other files. See State.luau.
local State = require("@self/State")
local Util = require("@self/Util")

local EVENTS_TYPE = Fragments.EVENTS_TYPE
local DIRECTIVES = Fragments.DIRECTIVES
local VERSION_HEADER = Fragments.VERSION_HEADER
local EVENT_BODY = Fragments.EVENT_BODY
local SYNC_VALIDATION_BODY = Fragments.SYNC_VALIDATION_BODY
local EVENT_SYNC_VALIDATION = Fragments.EVENT_SYNC_VALIDATION

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

local Types = Prefabs.Types

local Generator = {}

function Generator.Reset()
	State.Reset()
	Traffic.Reset()
end

function Generator.Generate(FileContext: Context, AbstractSyntaxTree: Parser.Body): string
	local Imports = Builder.new()

	Generator.Reset()
	State.Context = FileContext
	State.Options = AbstractSyntaxTree.Value.Options
	State.Casing = Settings.GetCasing((State.Options.Casing :: Settings.Case) or "Pascal")

	--> Setup noop
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
	local Preamble, StubCondition = Lifecycle.Stubs(State.Context, State.Options)
	State.Noop.Push(StubCondition)
	State.Noop.Push(`local NOOP = function() end`, 0, 1)
	State.Noop.Push(`local NOOP_RETURNING = function() return NOOP end`, 0, 1)
	if Lifecycle.InvokeStub(State.Context, State.Options) ~= "NOOP" then
		State.Noop.Push(Lifecycle.NOOP_INVOKE, 0, 1)
	end
	State.Noop.Push(`local Returns = table.freeze(\{`, 0, 1)

	--> Setup remote events
	local Signal = State.Context == "Client" and "OnClientEvent" or "OnServerEvent"
	local Arguments = (State.Context == "Server" and "Player: Player, " or "")
		.. "Buffer: buffer, Instances: {Instance}"

	State.Reliables = Blocks.Connection(`Reliable.{Signal}`, Arguments)
	State.Unreliables = Blocks.Connection(`Unreliable.{Signal}`, Arguments)

	--> Reject a hostile packet before any of it is parsed; see Fragments.InboundGuard.
	if State.Context == "Server" then
		local Guard = Fragments.InboundGuard(State.Options)
		State.Reliables:Lines(Guard, 1)
		State.Unreliables:Lines(Guard, 1)
	end

	State.Reliables:Lines(EVENT_BODY, 1)
	State.Unreliables:Lines(EVENT_BODY, 1)
	Traffic.Packet(State.Reliables, false)
	Traffic.Packet(State.Unreliables, true)

	if State.Options.SyncValidation then
		State.Reliables:Lines(EVENT_SYNC_VALIDATION, 1)
		State.Unreliables:Lines(EVENT_SYNC_VALIDATION, 1)
	end

	--> The size cap alone does not bound the work: a packet of single-byte event tags decodes one
	--> event per byte, so an 8 KB packet still means thousands of listener dispatches. Counting the
	--> decoded events bounds that directly.
	local MaxEvents = State.Options.MaxEventsPerPacket or DEFAULT_MAX_EVENTS_PER_PACKET

	--> The loop over one packet's events, made once for the module and handed each packet's
	--> DecodeEvent; see CloseDecode below. A player who leaves mid-packet is not worth decoding the
	--> rest for: every listener that runs from there on receives a Player already detached from the
	--> DataModel, and anything they do with it -- a leaderstats write, a save -- is work aimed at nobody.
	local DecodeLoop = if State.Context == "Server"
		then {
			"local function DecodeLoop(DecodeEvent: () -> (), Player: Player, Size: number)\n",
			"\tlocal DecodedEvents = 0\n",
			"\twhile RecieveCursor < Size and Player.Parent ~= nil do\n",
			"\t\tDecodedEvents += 1\n",
			`\t\tif DecodedEvents > {MaxEvents} then\n`,
			`\t\t\tReportDrop(Player, "Events", {MaxEvents})\n`,
			"\t\t\tbreak\n",
			"\t\tend\n",
			"\t\tDecodeEvent()\n",
			"\tend\n",
			"end\n",
		}
		else {
			"local function DecodeLoop(DecodeEvent: () -> (), Size: number)\n",
			"\twhile RecieveCursor < Size do\n",
			"\t\tDecodeEvent()\n",
			"\tend\n",
			"end\n",
		}

	--> A TRUNCATED packet defeats every limit above, because it is SMALLER than a legitimate one: two
	--> bytes tagged as a five-byte event make `buffer.readu16` throw from inside the remote's
	--> connection, where no user pcall can reach it. `Read` advances the cursor without a bounds
	--> check, so the only place to contain that is around the decode itself. The cursor is wherever
	--> the throw left it afterwards, so the packet cannot be resumed -- hence `break` rather than
	--> `continue`.
	-->
	--> BOTH sides, not just the server. The client cannot be attacked this way, but it can still be
	--> handed a packet it cannot parse: a listener that yields in a Sync call leaves the module-level
	--> cursor pointing mid-event, and a client built from a different schema than the server decodes
	--> every index one event out. Without this the user gets a raw `buffer access out of bounds` from
	--> inside OnClientEvent, which is what upstream issue #26 and the devforum report were.
	-->
	--> Each event is decoded by one call of `DecodeEvent`, and the loop making those calls runs under
	--> one pcall for the whole packet. The function is made once per packet, ahead of the loop. It
	--> used to be a closure written inside the loop, so every event allocated a fresh closure and the
	--> upvalues it captured before a byte of it was read -- a quarter of what a one-byte event cost
	--> the server to decode. `Decoding` carries the index out of the pcall, so a failure can name the
	--> event it happened in; it is reset first, so a failure to read the index names none.
	local function OpenDecode(Channel: Blocks.Block): Blocks.Block
		Channel:Line("local Decoding = -1")
		local Decoder = Channel:Scope("local function DecodeEvent()")
		Decoder:Line("Decoding = -1")
		Types.u8.Read("Index", Decoder)
		Decoder:Line("Decoding = Index")
		return Decoder
	end

	State.Reliables = OpenDecode(State.Reliables)
	State.Unreliables = OpenDecode(State.Unreliables)

	--> Replication
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
		Replication.Push("RunService.Heartbeat:Connect(StepReplication)")
	end

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

	--> An unknown event index means the packet is not what it claims to be: the byte came from a
	--> client, and the cursor is no longer at an event boundary, so nothing after it can be trusted.
	--> Without this branch the loop silently fell through and kept reading, which is how a buffer of
	--> unrecognised tags turned into a full-length parse.
	--> `error` and not `break`: this branch sits inside the pcall'd decode function opened above, and
	--> Luau cannot break out of a loop across a function boundary. Raising here lands in that pcall,
	--> which turns into the `break` below — the same stop, expressed where it is legal.
	local UNKNOWN_EVENT = `error("[BlinkBlox]: Unknown event index.")`

	--> A channel this side receives nothing on has no branch to hang that on, and its index read
	--> alone never failed: junk was consumed byte by byte up to MaxEventsPerPacket, unreported. The
	--> connection itself stays, since a remote nobody connects to queues whatever is sent to it.
	local function CloseIndex(Channel: Blocks.Block, Branches: { State.Branch }): Blocks.Block
		if #Branches == 0 then
			return Channel:Line(`error("[BlinkBlox]: This channel receives no events.")`)
		end

		return Decode.Close(Channel, Branches, UNKNOWN_EVENT)
	end

	State.Reliables = CloseIndex(State.Reliables, State.Channels.Reliable.Branches)
	State.Unreliables = CloseIndex(State.Unreliables, State.Channels.Unreliable.Branches)

	--> Close the decode function opened above, then decode the packet one event at a time. What is
	--> said about a failure, and to whom, is ReportDecodeFailure's business: the server is silent
	--> unless the game installed a handler, the client warns. See the two templates.
	-->
	--> The pcall is around the loop rather than around each event. A failure stops the packet either
	--> way -- the cursor is wherever the throw left it -- so one pcall a packet stops it at the same
	--> event, and a pcall an event had cost a one-byte event more than its decode did. A listener's
	--> own error never reaches it: each listener is called under a pcall of its own. `return` inside
	--> an event's branch still leaves only that event, because it returns from `DecodeEvent`.
	local function CloseDecode(Channel: Blocks.Block, Name: string): Blocks.Block
		local Connection = Channel:End()
		local Sender = if State.Context == "Server" then `Player, "{Name}", ` else ""
		local LoopArguments = if State.Context == "Server" then "DecodeEvent, Player, Size" else "DecodeEvent, Size"
		Connection:Line(`local Parsed: boolean, Failure: any = pcall(DecodeLoop, {LoopArguments})`)
		Connection:Line("if not Parsed then")
		Connection:Line(`\tReportDecodeFailure({Sender}EventNames.{Name}[Decoding], Failure)`)
		Connection:Line("end")
		return Connection
	end

	State.Reliables = CloseDecode(State.Reliables, "Reliable"):End()
	State.Unreliables = CloseDecode(State.Unreliables, "Unreliable"):End()

	State.Noop.Push(`\})`, 0, 1)
	State.Noop.Push(`return Returns :: {EVENTS_TYPE}`, 0, 1)
	State.Noop.Push(`end`, 0, 0)

	State.Return.PushFront(`\nlocal Returns = table.freeze(\{`)
	State.Return.Push(`})`)

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

	local MergedOutput = Table.Merge(
		DIRECTIVES,
		VERSION_HEADER,
		ScopeValidationBody,
		string.split(Source[1], "\r"),
		Imports.DumpLines(),
		{ "local SerdesFunctions = {}\n" },
		Util.Constants(State.Options.RemoteScope, AbstractSyntaxTree),
		string.split(Sources.Base, "\r"),
		Traffic.Body(),
		(if Prefabs.Required.Rotation then Fragments.ROTATION_HELPERS else {}),
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
			Table.Merge(DecodeLoop, Replication.DumpLines(), State.Reliables.Content, State.Unreliables.Content)
		),
		State.Return.DumpLines(),
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
		(if Prefabs.Required.Rotation then Fragments.ROTATION_HELPERS else {}),
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
