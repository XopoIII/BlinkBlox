--!strict
--!native
--!optimize 2

local Parser = require("./Parser")
local Settings = require("./Settings")

local Builder = require("./Modules/Builder")
local Table = require("./Modules/Table")

local Blocks = require("@self/Blocks")
local Fragments = require("@self/Fragments")
local GenerateTypescript = require("@self/Typescript")
local Prefabs = require("@self/Prefabs")
local Serde = require("@self/Serde")
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
local DEFAULT_MAX_UNRELIABLE_SIZE = Fragments.DEFAULT_MAX_UNRELIABLE_SIZE

local Sources = {
	Base = require("./Templates/Base"),
	Shared = { "", "" },
	Client = string.split(require("./Templates/Client"), "-- SPLIT --"),
	Server = string.split(require("./Templates/Server"), "-- SPLIT --"),
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
	State.Noop.Push(`if not RunService:IsRunning() then`)
	State.Noop.Push(`local NOOP = function() end`, 0, 1)
	State.Noop.Push(`local NOOP_RETURNING = function() return NOOP end`, 0, 1)
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

	if State.Options.SyncValidation then
		State.Reliables:Lines(EVENT_SYNC_VALIDATION, 1)
		State.Unreliables:Lines(EVENT_SYNC_VALIDATION, 1)
	end

	--> The size cap alone does not bound the work: a packet of single-byte event tags decodes one
	--> event per byte, so an 8 KB packet still means thousands of listener dispatches. Counting the
	--> decoded events bounds that directly.
	local MaxEvents = State.Options.MaxEventsPerPacket or DEFAULT_MAX_EVENTS_PER_PACKET
	if State.Context == "Server" then
		State.Reliables:Line("local DecodedEvents = 0", 1)
		State.Unreliables:Line("local DecodedEvents = 0", 1)
	end

	--> A player who leaves mid-packet is not worth decoding the rest for: every listener that runs
	--> from here on receives a Player already detached from the DataModel, and anything they do with
	--> it -- a leaderstats write, a save -- is work aimed at nobody.
	local Condition = if State.Context == "Server"
		then "RecieveCursor < Size and Player.Parent ~= nil"
		else "RecieveCursor < Size"

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
	--> Each event is decoded by one call of `DecodeEvent` under its own pcall. The function is made
	--> once per packet, ahead of the loop. It used to be a closure written inside the loop, so every
	--> event allocated a fresh closure and the upvalues it captured before a byte of it was read --
	--> a quarter of what a one-byte event cost the server to decode. `Decoding` carries the index
	--> out of the pcall, so a failure can name the event it happened in.
	local function OpenDecode(Channel: Blocks.Block): Blocks.Block
		Channel:Line("local Decoding = -1")
		local Decoder = Channel:Scope("local function DecodeEvent()")
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
	local Source = Sources[State.Context]

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
	local function CloseIndex(Channel: Blocks.Block, Listening: boolean): Blocks.Block
		if not Listening then
			return Channel:Line(`error("[BlinkBlox]: This channel receives no events.")`)
		end

		return Channel:Branch("Default"):Line(UNKNOWN_EVENT):End()
	end

	State.Reliables = CloseIndex(State.Reliables, State.Channels.Reliable.Listening)
	State.Unreliables = CloseIndex(State.Unreliables, State.Channels.Unreliable.Listening)

	--> Close the decode function opened above, then decode the packet one event at a time and act on
	--> each result. What is said about a failure, and to whom, is ReportDecodeFailure's business: the
	--> server is silent unless the game installed a handler, the client warns. See the two templates.
	local function CloseDecode(Channel: Blocks.Block, Name: string): Blocks.Block
		local Connection = Channel:End()
		local Loop = Connection:While(Condition)

		--> The event cap; see MaxEvents above.
		if State.Context == "Server" then
			Loop:Line("DecodedEvents += 1")
			Loop:Line(`if DecodedEvents > {MaxEvents} then`)
			Loop:Line(
				`\tif ShouldReport(Player, "Events") then warn(\`[BlinkBlox]: Dropped the rest of a packet from \{Player.Name\}, too many events.\`) end`
			)
			Loop:Line("\tbreak")
			Loop:Line("end")
		end

		local Sender = if State.Context == "Server" then `Player, "{Name}", ` else ""
		Loop:Line("Decoding = -1")
		Loop:Line("local Parsed: boolean, Failure: any = pcall(DecodeEvent)")
		Loop:Line("if not Parsed then")
		Loop:Line(`\tReportDecodeFailure({Sender}EventNames.{Name}[Decoding], Failure)`)
		Loop:Line("\tbreak")
		Loop:Line("end")
		return Loop:End()
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

	--> Sequence bookkeeping for OrderedUnreliable, emitted only where the schema uses it.
	-->
	--> Incoming is the last sequence seen per event, per SOURCE -- which on the server means per
	--> player, since each client runs its own. Outgoing is per event on a client, which has one
	--> recipient, and per event PER PLAYER on the server: one counter shared by every player told a
	--> player left out of 32768 sends that each later packet was older than the last one it had seen,
	--> until the counter came round again. The server's serialiser writes a placeholder and each send
	--> stamps the recipient's own number over it.
	-->
	--> A sequence is newer when it is less than half the counter's range AHEAD of the last one, the
	--> usual serial-number comparison, which is what makes the wrap at 65536 harmless. The earlier
	--> check refused only what was below the last sequence, so a packet from just before the wrap
	--> arriving just after it was taken as newer and delivered out of order.
	local OrderingBody = {}
	if State.UsesOrdering then
		local Newer = {
			"\tlocal Last = State[Slot]\n",
			"\tif Last ~= nil then\n",
			"\t\tlocal Ahead = (Identifier - Last) % 65536\n",
			"\t\tif Ahead == 0 or Ahead >= 32768 then\n",
			"\t\t\treturn false\n",
			"\t\tend\n",
			"\tend\n",
			"\n",
			"\tState[Slot] = Identifier\n",
			"\treturn true\n",
			"end\n",
		}

		if State.Context == "Server" then
			OrderingBody = {
				"\n",
				"--> Sequence numbers for ordered unreliable events, per player and per event, both ways.\n",
				"local OrderOut: { [Player]: { number } } = {}\n",
				"local OrderIn: { [Player]: { number } } = {}\n",
				"\n",
				"Players.PlayerRemoving:Connect(function(Player)\n",
				"\tOrderOut[Player] = nil\n",
				"\tOrderIn[Player] = nil\n",
				"end)\n",
				"\n",
				"--> The next sequence number this player is sent for this event. A player who has already left\n",
				"--> gets a number and keeps no state, which PlayerRemoving would have nothing left to clear.\n",
				"local function NextOrder(Player: Player, Slot: number): number\n",
				"\tlocal State = OrderOut[Player]\n",
				"\tif not State then\n",
				"\t\tif Player.Parent == nil then\n",
				"\t\t\treturn 0\n",
				"\t\tend\n",
				"\t\tState = {}\n",
				"\t\tOrderOut[Player] = State\n",
				"\tend\n",
				"\n",
				"\tlocal Identifier = ((State[Slot] or 0) + 1) % 65536\n",
				"\tState[Slot] = Identifier\n",
				"\treturn Identifier\n",
				"end\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one this player sent for this event.\n",
				"local function OrderAccept(Player: Player, Slot: number, Identifier: number): boolean\n",
				"\tif Player.Parent == nil then\n",
				"\t\tOrderIn[Player] = nil\n",
				"\t\treturn false\n",
				"\tend\n",
				"\n",
				"\tlocal State = OrderIn[Player]\n",
				"\tif not State then\n",
				"\t\tState = {}\n",
				"\t\tOrderIn[Player] = State\n",
				"\tend\n",
				"\n",
			}
		else
			OrderingBody = {
				"\n",
				"--> Sequence numbers for ordered unreliable events, one counter per event each way.\n",
				"local OrderOut: { number } = {}\n",
				"local OrderIn: { number } = {}\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one seen for this event.\n",
				"local function OrderAccept(Slot: number, Identifier: number): boolean\n",
				"\tlocal State = OrderIn\n",
			}
		end

		table.move(Newer, 1, #Newer, #OrderingBody + 1, OrderingBody)
	end

	--> Emitted only when the schema actually has unreliable events -- most do not, and a helper
	--> nothing calls is noise in a file people read when debugging their own traffic.
	local UnreliableGuardBody = {}
	if State.Channels.Unreliable.Count > 0 then
		local MaxUnreliableSize = State.Options.MaxUnreliableSize or DEFAULT_MAX_UNRELIABLE_SIZE
		UnreliableGuardBody = {
			"\n",
			"--> Roblox drops an unreliable payload past this size and tells nobody. The compiler\n",
			"--> refuses schemas that can never fit; this catches the ones that merely overflow at\n",
			"--> runtime, and says which event did it.\n",
			`local MAX_UNRELIABLE_SIZE = {MaxUnreliableSize}\n`,
			"local function CheckUnreliableSize(Name: string): boolean\n",
			"\tif SendCursor <= MAX_UNRELIABLE_SIZE then\n",
			"\t\treturn true\n",
			"\tend\n",
			"\n",
			'\twarn(`[BlinkBlox]: Dropped unreliable event "{Name}", {SendCursor} bytes exceeds the {MAX_UNRELIABLE_SIZE} byte limit.`)\n',
			"\treturn false\n",
			"end\n",
		}
	end

	--> Initial contents of a player's rate bucket: tokens, refill clock, report clock, refusals since
	--> that report, per limited declaration. Cloned per player on first use, so one allocation per player per session rather
	--> than a table per event.
	local RateTemplateBody = {}
	if State.Context == "Server" then
		local Entries = {}
		for _, Slot in State.RateSlots do
			table.insert(Entries, `{Slot.Burst}, 0, 0, 0`)
		end

		RateTemplateBody = { `local RATE_TEMPLATE = table.freeze(\{{table.concat(Entries, ", ")}\})\n` }
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
		(if Prefabs.Required.Rotation then Fragments.ROTATION_HELPERS else {}),
		RateTemplateBody,
		OrderingBody,
		UnreliableGuardBody,
		(if State.Options.SyncValidation then SYNC_VALIDATION_BODY else {}),
		State.Events.DumpLines(),
		State.LuauTypes.DumpLines(),
		State.UserTypes.DumpLines(),
		State.Noop.DumpLines(),
		string.split(Source[2], "\r"),
		Replication.DumpLines(),
		State.Reliables.Content,
		State.Unreliables.Content,
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

	--> Parse declarations
	Generators.AbstractSyntaxTree(AbstractSyntaxTree.Value.Declarations)

	--> Generate context source
	local Source = Sources[State.Context]
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
