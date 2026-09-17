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
local Util = require("@self/Util")

local EVENTS_TYPE = Fragments.EVENTS_TYPE
local DIRECTIVES = Fragments.DIRECTIVES
local VERSION_HEADER = Fragments.VERSION_HEADER
local EVENT_BODY = Fragments.EVENT_BODY
local SYNC_VALIDATION_BODY = Fragments.SYNC_VALIDATION_BODY
local EVENT_SYNC_VALIDATION = Fragments.EVENT_SYNC_VALIDATION
local RELIABLE_BODY = Fragments.RELIABLE_BODY
local UNRELIABLE_BODY = Fragments.UNRELIABLE_BODY
local IGNORED_TYPES_IN_SHARED = Fragments.IGNORED_TYPES_IN_SHARED

local DEFAULT_MAX_PACKET_SIZE = Fragments.DEFAULT_MAX_PACKET_SIZE
local DEFAULT_MAX_EVENTS_PER_PACKET = Fragments.DEFAULT_MAX_EVENTS_PER_PACKET
local DEFAULT_MAX_INSTANCES_PER_PACKET = Fragments.DEFAULT_MAX_INSTANCES_PER_PACKET
local DEFAULT_MAX_UNRELIABLE_SIZE = Fragments.DEFAULT_MAX_UNRELIABLE_SIZE
local DEFAULT_INVOCATION_TIMEOUT = Fragments.DEFAULT_INVOCATION_TIMEOUT

local Sources = {
	Base = require("./Templates/Base"),
	Shared = { "", "" },
	Client = string.split(require("./Templates/Client"), "-- SPLIT --"),
	Server = string.split(require("./Templates/Server"), "-- SPLIT --"),
}

type Type = Parser.TypeNode
type Scope = Parser.Scope
type Context = "Client" | "Server" | "Shared"
--> One definition shared with Settings, Parser and Prefabs, not Roblox NumberRange userdata.
type NumberRange = Parser.NumberRange

local Scope: Scope
local Context: Context
local Casing: Settings.Cases
local Noop: Builder.Builder
local Events: Builder.Builder
local UserTypes: Builder.Builder
local LuauTypes: Builder.Builder
local Reliables: Blocks.Block
local Unreliables: Blocks.Block
local Return: Builder.Builder
local Options: Parser.Options

local Generators = {}

--> The serde half -- how each kind of type is read from and written to a buffer -- lives in
--> Serde.luau, and the rest of this file adds to the same table. What stays here is the half that
--> needs the generator's own state: events, functions, and the API surface around them.
local Declarations = Serde

--> Set when the schema declares at least one OrderedUnreliable event, so the sequence bookkeeping
--> is emitted only where something uses it.
local UsesOrdering = false

--> One entry per rate-limited event or function, in the order they were generated. Each takes three
--> consecutive numbers in the per-player bucket, so the entry at index N starts at slot (N - 1) * 3 + 1.
local RateSlots: { { Rate: number, Burst: number } } = {}

local Channels: { [string]: { Count: number, Listening: boolean } } = {
	Reliable = { Count = 0, Listening = false },
	Unreliable = { Count = 0, Listening = false },
}

local FormatKey = Util.FormatKey

local Types = Prefabs.Types
local Primitives = Prefabs.Primitives

--- Claims a bucket slot for an inbound declaration that declares a rate, and returns the call that
--- spends a token from it. Returns nil when nothing limits this declaration, in which case no guard
--- is emitted at all -- an unlimited schema produces exactly the code it always did.
---
--- Server-only: the client trusts the server, and the bucket state lives in the server template.
local function RateGuardExpression(Value: { Rate: number?, Burst: number? }, Name: string): string?
	if Context ~= "Server" then
		return nil
	end

	local Rate = Value.Rate or Options.DefaultRate
	if not Rate then
		return nil
	end

	--> A burst of one would refuse the very first event of a frame whenever the previous frame used
	--> its budget, so the floor is one whole token.
	local Burst = Value.Burst or math.max(math.ceil(Rate), 1)

	table.insert(RateSlots, { Rate = Rate, Burst = Burst })
	local Slot = ((#RateSlots - 1) * 3) + 1

	return `RateAccept(Player, {Slot}, {Rate}, {Burst}, "{Name}")`
end

--- The call that decides whether an ordered packet is newer than the last one seen. Nil when the
--- event is not ordered, in which case no check is emitted at all.
---
--- The server keys by player: sixty clients each run their own sequence, and one client's counter
--- says nothing about another's.
local function OrderGuardExpression(IsOrdered: boolean, Index: number): string?
	if not IsOrdered then
		return nil
	end

	if Context == "Server" then
		return `OrderAccept(Player, {Index}, OrderIdentifier)`
	end

	return `OrderAccept({Index}, OrderIdentifier)`
end

--> Declaration functions

function Declarations.Event(Declaration: Parser.Event)
	local Value = Declaration.Value

	local Identifier = `EVENT_{Declaration.Name}`
	local Reliability = Value.Type

	local IsReliable = (Reliability == "Reliable")
	--> Ordered events travel the unreliable channel; the ordering is a sequence number on top of it.
	local IsOrdered = (Reliability == "OrderedUnreliable")
	local IsUnreliable = (Reliability == "Unreliable" or IsOrdered)

	if IsOrdered then
		UsesOrdering = true
	end
	local IsPolling = (Value.Call == "Polling" or Options.UsePolling)
	local IsSameContext = Value.From == Context

	local Block = IsUnreliable and Unreliables or Reliables
	local Channel = IsUnreliable and Channels.Unreliable or Channels.Reliable

	local Index = Channel.Count
	--> Ordered events ride the unreliable channel, so they share its queue and listener tables --
	--> naming those after the declared reliability would index a third table that does not exist.
	local ChannelName = if IsUnreliable then "Unreliable" else "Reliable"
	local Queue = `Queue.{ChannelName}[{Index}]`
	local Connection = `Events.{ChannelName}[{Index}]`

	--> Data body
	local DataTypes, Values, Arguments, _ = "nil", "Value: nil", "Value", nil
	local Read, Write = Generators.Event(Value.Data, Index, Identifier, nil, IsOrdered)

	if Value.Data then
		DataTypes, Values, _, Arguments = Generators.LuauType(Value.Data :: Type, true)
	end

	if IsSameContext then
		UserTypes.PushLines(Write, 1, 0)
	else
		UserTypes.PushLines(Read, 1, 0)
	end

	--> Return body
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(Scope)
	local WriteEvent = `{Util.GetPath(Identifier, true, Scope)}({Arguments})`
	--> The same call, protected. Only the CLIENT needs it: every server fire begins with its own
	--> `Load`, so a write that throws is confined to scratch state the next `Load` replaces, while
	--> the client writes straight into the batch it is still accumulating.
	local TryWriteEvent = `pcall({Util.GetPath(Identifier, true, Scope)}, {Arguments})`

	Body.Push(`{Declaration.Name} = \{`, 0, Indent)
	Noop.Push(`{Declaration.Name} = \{`, 0, Indent)

	if Value.From ~= Context and IsPolling ~= true then
		local IsSync = (Value.Call == "SingleSync" or Value.Call == "ManySync")
		local IsSingle = (Value.Call == "SingleSync" or Value.Call == "SingleAsync")

		--> Binding the listener. A Single event keeps one, and a second `.On()` replaces it -- which
		--> is the documented behaviour and stays that way. What it did not do is say so, and the
		--> silence hides a second-order effect: the FIRST listener's returned disconnect function is
		--> guarded by `Events[n] == Listener`, so once it has been replaced that disconnect quietly
		--> stops doing anything. Two systems that each connect and later disconnect therefore leave a
		--> listener attached that neither of them believes it owns. Upstream #167.
		local function BindListener(Target: Blocks.Block): Blocks.Block
			if not IsSingle then
				return Target:Line(`table.insert({Connection}, Listener)`)
			end

			return Target:Line(`if {Connection} ~= nil then`)
				:Line(
					`\twarn("[Blink]: \\"{Declaration.Name}\\" already has a listener. {Value.Call} keeps only the newest one, and the replaced listener's disconnect stops working.")`
				)
				:Line("end")
				:Line(`{Connection} = Listener`)
		end

		--> Create queue and event branch
		if not IsSingle then
			Events.Push(`{Connection} = \{}`)
		end

		Events.Push(`{Queue} = table.create(256)`)
		Block = (Channel.Listening == false) and Block:Compare("Index", Index, "Equals")
			or Block:Branch("Conditional", "Index", Index, "Equals")

		--> Update event block to branch block
		if IsUnreliable then
			Unreliables = Block
		else
			Reliables = Block
		end

		--> Update channel status
		Channel.Listening = true

		--> Event recieve body
		local Listener: Blocks.Block
		local ContextArguments = `Listener: ({Context == "Server" and "Player: Player, " or ""}{Values}) -> ()`
		local ListenerArguments = `{Context == "Server" and "Player, " or ""}{Arguments}`

		local CallListener = Blocks.Block()
		do
			if IsSync and Options.SyncValidation then
				CallListener = CallListener:Line(`SerdesEvent = "{Declaration.Name}"`)
			end

			local PathExpr = IsSingle and Connection or "Listener"
			local CallExpr = IsSync and `{PathExpr}({ListenerArguments})` or `Spawn({PathExpr}, {ListenerArguments})`
			CallListener = CallListener:Line(CallExpr)
		end

		--> Read before the payload, because that is the order it was written in. The DECISION comes
		--> after the payload is decoded, for the same reason the rate limit's does: a variable-length
		--> payload cannot be skipped without reading it.
		if IsOrdered then
			Types.u16.Read("OrderIdentifier", Block)
		end

		Block:Line(`local {Values} = {Util.GetPath(Identifier, false, Scope)}()`)

		--> The decode above has to happen either way: payloads are variable length, so skipping an
		--> event without reading it would leave the cursor mid-event and turn the rest of the packet
		--> into garbage. What the limit saves is the listener and everything behind it.
		local RateGuard = RateGuardExpression(Value, Declaration.Name)
		if RateGuard then
			Block = Block:Compare(RateGuard, "true", "Equals")
		end

		local OrderGuard = OrderGuardExpression(IsOrdered, Index)
		if OrderGuard then
			Block = Block:Compare(OrderGuard, "true", "Equals")
		end

		local Disconnect = Blocks.Function("", "", "()")
		if IsSingle then
			Disconnect = Disconnect:Compare(Connection, "Listener", "Equals"):Line(`{Connection} = nil`):End()
		else
			Disconnect = Disconnect:Line(`local Index = table.find({Connection}, Listener)`)
			Disconnect = Disconnect:Compare("Index", "nil", "Not"):Line(`table.remove({Connection}, Index)`):End()
		end

		Disconnect = Disconnect:End():Wrap("return ", "")

		if IsReliable then
			local ListenerBound: Blocks.Block
			if IsSingle then
				ListenerBound = Block:Compare(Connection, "nil", "Not"):Lines(CallListener.Content, Block.Indent)
			else
				ListenerBound = Block:Compare(`#{Connection}`, "0", "Greater")
					:Iterator("_", "Listener", Connection)
					:Lines(CallListener.Content, Block.Indent + 1)
					:End()
			end

			ListenerBound:Branch("Default")
				:Compare(`#{Queue}`, "256", "Greater")
				:Line(
					`warn("[Blink]: Event queue of \\"{Declaration.Name}\\" exceeded 256, did you forget to implement a listener?")`
				)
				:End()
				:Line(`table.insert({Queue}, \{{ListenerArguments}\} :: \{any\})`)
				:End()

			Listener = BindListener(Blocks.Function(Casing.On, ContextArguments, `() -> ()`, true))
				:Iterator("Index", "Arguments", Queue)
				:Line(IsSync and `Listener(table.unpack(Arguments))` or `Spawn(Listener, table.unpack(Arguments))`)
				:End()
				:Line(`{Queue} = \{}`)
				:Lines(Disconnect.Content, 1)
				:End()
		else
			if IsSingle then
				Block:Compare(Connection, "nil", "Not"):Lines(CallListener.Content, Block.Indent):End()
			else
				Block:Iterator("_", "Listener", Connection):Lines(CallListener.Content, Block.Indent):End()
			end

			Listener = BindListener(Blocks.Function(Casing.On, ContextArguments, `() -> ()`, true))
				:Lines(Disconnect.Content, 1)
				:End()
		end

		if OrderGuard then
			Block = Block:End()
		end

		if RateGuard then
			Block = Block:End()
		end

		--> Predict (upstream issue #59, and the other half of #81).
		-->
		--> Delivers an event to this side's own listeners without going near a remote, so a test or a
		--> story can drive receiving code directly. It mirrors the receive path deliberately, queue
		--> included: a Predict that skipped the queue would behave differently from the network
		--> whenever no listener is attached yet, which is exactly the case tests hit most.
		if Options.Predict then
			local PredictArguments = `{Context == "Server" and "Player: Player, " or ""}{Values}`
			local Predict = Blocks.Function(Casing.Predict, PredictArguments, "()", true)

			if IsSingle then
				local Bound = Predict:Compare(Connection, "nil", "Not"):Lines(CallListener.Content, Predict.Indent)
				if IsReliable then
					Bound:Branch("Default"):Line(`table.insert({Queue}, \{{ListenerArguments}\} :: \{any\})`):End()
				else
					Bound:End()
				end
			else
				Predict:Iterator("_", "Listener", Connection):Lines(CallListener.Content, Predict.Indent):End()
			end

			Predict:End()

			Noop.Push(`{Casing.On} = NOOP_RETURNING,`, 0, Indent + 1)
			Noop.Push(`{Casing.Predict} = NOOP`, 0, Indent + 1)
			Body.PushLines(Listener:Wrap("", ",").Content, 0, Indent + 1)
			Body.PushLines(Predict.Content, 0, Indent + 1)
		else
			Noop.Push(`{Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
			Body.PushLines(Listener.Content, 0, Indent + 1)
		end
	elseif Value.From ~= Context and IsPolling then
		Events.Push(`{Queue} = CreateQueue()`)
		Block = (Channel.Listening == false) and Block:Compare("Index", Index, "Equals")
			or Block:Branch("Conditional", "Index", Index, "Equals")

		if IsUnreliable then
			Unreliables = Block
		else
			Reliables = Block
		end

		Channel.Listening = true

		if IsOrdered then
			Types.u16.Read("OrderIdentifier", Block)
		end

		local PollArguments =
			`table.pack({Context == "Server" and "Player, " or ""}{Util.GetPath(Identifier, false, Scope)}())`
		local PollOrderGuard = OrderGuardExpression(IsOrdered, Index)
		local PollRateGuard = RateGuardExpression(Value, Declaration.Name)

		--> Both gate the same enqueue, so they combine into one condition rather than nesting.
		if PollRateGuard and PollOrderGuard then
			PollRateGuard = `{PollRateGuard} and {PollOrderGuard}`
		elseif PollOrderGuard then
			PollRateGuard = PollOrderGuard
		end

		if PollRateGuard then
			--> Split because the one-liner decodes and enqueues at once, and only the enqueue may be
			--> skipped.
			Block:Line(`local Arguments = {PollArguments}`)
			Block:Line(`if {PollRateGuard} then`)
			Block:Line(`\tPush({Queue}, Arguments)`)
			Block:Line("end")
		else
			Block:Line(`Push({Queue}, {PollArguments})`)
		end

		local IterTypes = `number, {Context == "Server" and "Player, " or ""}{DataTypes}`

		local Next = Blocks.Function("", "", `({IterTypes})`)
			:Line("index += 1")
			:Line("local arguments = Pop(queue)")
			:Compare("arguments", "nil", "Not")
			:Return("index, unpack(arguments, 1, arguments.n)")
			:End()
			:Return("")
			:End()
			:Wrap("return ", "")

		local Deprecated = Blocks.Function(Casing.Next, "", `() -> ({IterTypes})`, true)
			:Line(`local index = 0`)
			:Line(`local queue = {Queue}`)
			:Lines(Next.Content, 1)
			:End()

		local Iter = Blocks.Function(Casing.Iter, "", `() -> ({IterTypes})`, true)
			:Line(`local index = 0`)
			:Line(`local queue = {Queue}`)
			:Lines(Next.Content, 1)
			:End()
			:Wrap("", ",")

		Noop.Push(`{Casing.Iter} = NOOP_RETURNING,`, 0, Indent + 1)
		Noop.Push(`{Casing.Next} = NOOP_RETURNING`, 0, Indent + 1)

		Body.PushLines(Iter.Content, 0, Indent + 1)
		Body.Push("--- @deprecated v0.14.1 -- Use `Iter` instead.", 0, Indent + 1)
		Body.PushLines(Deprecated.Content, 0, Indent + 1)
	elseif Context == "Client" then
		local Fire = Blocks.Function(Casing.Fire, Values, "()", true)
		if IsReliable then
			--> Rolled back rather than left, because this write lands in the batch every other event
			--> is queued in. Half an event in there is not one bad send: the receiver reads the
			--> truncated event and then decodes the REST of the batch from the wrong offset.
			Fire:Line("local Cursor, Instances = Mark()")
			Fire:Line(`local Sent, Failure = {TryWriteEvent}`)
			Fire:Compare("Sent", "true", "Not"):Line("Rollback(Cursor, Instances)"):Line("error(Failure, 0)"):End()
		else
			Fire:Line(`local Previous = Save()`)
			Fire:Line(`Load()`)
			Fire:Line(`local Sent, Failure = {TryWriteEvent}`)
			--> Wrapped rather than returned out of: the saved buffer has to be restored either way,
			--> and an early return here would leave the caller's outgoing state swapped out.
			-->
			--> Which is exactly why the write is protected. A throw used to skip `Load(Previous)`
			--> entirely, leaving this temporary buffer installed as the outgoing one -- so the next
			--> RELIABLE flush sent the scratch buffer and dropped everything already batched.
			Fire:Line(`if Sent and CheckUnreliableSize("{Declaration.Name}") then`)
			Fire:Line("\tlocal Buffer = buffer.create(SendCursor)")
			Fire:Line("\tbuffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)")
			Fire:Line("\tUnreliable:FireServer(Buffer, SendInstances)")
			Fire:Line("end")
			Fire:Line("Load(Previous)")
			Fire:Compare("Sent", "true", "Not"):Line("error(Failure, 0)"):End()
		end
		Fire:End()

		Noop.Push(`{Casing.Fire} = NOOP`, 0, Indent + 1)
		Body.PushLines(Fire.Content, 0, Indent + 1)
	else
		local Fire = Blocks.Function(Casing.Fire, `Player: Player, {Values}`, "()", true)
		if IsReliable then
			Fire:Line("Load(PlayersMap[Player])")
			Fire:Line(WriteEvent)
			Fire:Line("SavePlayerBuffer(Player)")
		else
			Fire:Line("Load()")
			Fire:Line(WriteEvent)
			Fire:Line(`if not CheckUnreliableSize("{Declaration.Name}") then return end`)
			Fire:Lines(UNRELIABLE_BODY, 1)
			Fire:Line("Unreliable:FireClient(Player, Buffer, SendInstances)")
		end
		Fire:End()

		local FireAll = Blocks.Function(Casing.FireAll, Values, "()", true)
		if IsReliable then
			FireAll:Line("Load()")
			FireAll:Line(WriteEvent)
			FireAll:Line(RELIABLE_BODY.Header)
			FireAll:Iterator("_", "Player", "Players:GetPlayers()"):Lines(RELIABLE_BODY.Body, 2):End()
		else
			FireAll:Line("Load()")
			FireAll:Line(WriteEvent)
			FireAll:Line(`if not CheckUnreliableSize("{Declaration.Name}") then return end`)
			FireAll:Lines(UNRELIABLE_BODY, 1)
			FireAll:Line("Unreliable:FireAllClients(Buffer, SendInstances)")
		end
		FireAll:End()

		local FireList = Blocks.Function(Casing.FireList, `List: \{Player\}, {Values}`, "()", true)
		if IsReliable then
			FireList:Line("Load()")
			FireList:Line(WriteEvent)
			FireList:Line(RELIABLE_BODY.Header)
			FireList:Iterator("_", "Player", "List"):Lines(RELIABLE_BODY.Body, 2):End()
		else
			FireList:Line("Load()")
			FireList:Line(WriteEvent)
			FireList:Line(`if not CheckUnreliableSize("{Declaration.Name}") then return end`)
			FireList:Lines(UNRELIABLE_BODY, 1)
			FireList:Iterator("_", "Player", "List"):Line("Unreliable:FireClient(Player, Buffer, SendInstances)"):End()
		end
		FireList:End()

		local FireExcept = Blocks.Function(Casing.FireExcept, `Except: Player, {Values}`, "()", true)
		if IsReliable then
			FireExcept:Line("Load()")
			FireExcept:Line(WriteEvent)
			FireExcept:Line(RELIABLE_BODY.Header)
			FireExcept:Iterator("_", "Player", "Players:GetPlayers()")
				:Compare("Player", "Except", "Equals")
				:Line("continue")
				:End()
				:Lines(RELIABLE_BODY.Body, 2)
				:End()
		else
			FireExcept:Line("Load()")
			FireExcept:Line(WriteEvent)
			FireExcept:Line(`if not CheckUnreliableSize("{Declaration.Name}") then return end`)
			FireExcept:Lines(UNRELIABLE_BODY, 1)
			FireExcept:Iterator("_", "Player", "Players:GetPlayers()")
				:Compare("Player", "Except", "Equals")
				:Line("continue")
				:End()
				:Line("Unreliable:FireClient(Player, Buffer, SendInstances)")
				:End()
		end
		FireExcept:End()

		Noop.PushLines({
			`{Casing.Fire} = NOOP,\n`,
			`{Casing.FireAll} = NOOP,\n`,
			`{Casing.FireList} = NOOP,\n`,
			`{Casing.FireExcept} = NOOP\n`,
		}, 0, Indent + 1)

		Body.PushLines(Fire:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireAll:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireList:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireExcept:Wrap("", ",").Content, 0, Indent + 1)
	end

	Channel.Count += 1

	Body.Push(`\},`, 0, Indent)
	Noop.Push(`\},`, 0, Indent)
	Return.PushLines(Body.DumpLines(), 0)
end

function Declarations.Function(Declaration: Parser.Function)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local DataIdentifier = `FUNCTION_DATA_{Name}`
	local ReturnIdentifier = `FUNCTION_RETURN_{Name}`

	local Yield = Value.Yield
	local IsFuture = (Yield == "Future")
	local IsPromise = (Yield == "Promise")

	if IsFuture and not Options.FutureLibrary then
		error(`Cannot use yield type: "Future", without providing a path to the future library.`)
	end

	if IsPromise and not Options.PromiseLibrary then
		error(`Cannot use yield type: "Promise", without providing a path to the promise library.`)
	end

	local Block = Reliables
	local Channel = Channels.Reliable

	local Index = Channel.Count
	local Queue = `Queue.Reliable[{Index}]`
	local Connection = `Events.Reliable[{Index}]`

	--> WHICH SIDE IS WHICH. `From` names the side that INVOKES; the other side listens. Until this
	--> existed the answer was always "the client invokes", and the fork below was written as
	--> `Context == "Server"` -- true only because that meant the same thing.
	local IsCaller = (Value.From == Context)
	local OnServer = (Context == "Server")

	--> A server calling a client needs per-player invocation state, because the id is a u8 the client
	--> sends back and one shared id space would let a client answer a call made to somebody else. See
	--> Templates/Server.luau.
	local ServerCalls = OnServer and IsCaller
	local ClaimSlot = if ServerCalls then "InvokePlayer(Player)" else "Invoke()"
	local ReleaseSlot = if ServerCalls
		then "ReleasePlayerInvocation(Player, InvocationIdentifier)"
		else "ReleaseInvocation(InvocationIdentifier)"
	local ParkCaller = if ServerCalls
		then "ParkInvocation(Player, InvocationIdentifier, coroutine.running())"
		else "Calls[InvocationIdentifier] = coroutine.running()"
	local TakeCaller = if ServerCalls
		then "TakeInvocation(Player, InvocationIdentifier)"
		else "Calls[InvocationIdentifier]"
	local ForgetCaller = if ServerCalls then "" else "Calls[InvocationIdentifier] = nil"
	local ArmTimeout = if ServerCalls
		then `TimeoutPlayerInvocation(Player, InvocationIdentifier, {Options.InvocationTimeout or DEFAULT_INVOCATION_TIMEOUT}, "{Name}")`
		else `TimeoutInvocation(InvocationIdentifier, {Options.InvocationTimeout or DEFAULT_INVOCATION_TIMEOUT}, "{Name}")`

	--> Data and return body
	local DataTypes, DataValues, _, DataArguments = "nil", "Value: nil", nil, "Value"
	local ReturnTypes, ReturnValues, _, ReturnArguments = "nil", "ReturnValue: nil", nil, "ReturnValue"

	if Value.Data then
		DataTypes, DataValues, _, DataArguments = Generators.LuauType(Value.Data :: Type, true)
	end

	if Value.Return then
		ReturnTypes, ReturnValues, _, ReturnArguments = Generators.LuauType(Value.Return :: Type, true, "Return")
	end

	do
		local DataRead, DataWrite = Generators.Event(Value.Data :: Type, Index, DataIdentifier, "Data")
		local ReturnRead, ReturnWrite = Generators.Event(Value.Return :: Type, Index, ReturnIdentifier, "Return")

		--> By DIRECTION, not by context. The caller writes the arguments and reads the answer; the
		--> listener reads the arguments and writes the answer. Keying this on `Context == "Client"`
		--> was correct only while the client was always the caller.
		if IsCaller then
			UserTypes.PushLines(DataWrite, 1, 0)
			UserTypes.PushLines(ReturnRead, 1, 0)
		else
			UserTypes.PushLines(DataRead, 1, 0)
			UserTypes.PushLines(ReturnWrite, 1, 0)
		end
	end

	--> Main
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(Scope)

	Noop.Push(`{Name} = \{`, 0, Indent)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> Create queue and event branch
	Events.Push(`{Queue} = table.create(256)`)
	Block = (Channel.Listening == false) and Block:Compare("Index", Index, "Equals")
		or Block:Branch("Conditional", "Index", Index, "Equals")

	--> Update event block to branch block
	Reliables = Block

	if not IsCaller then
		--> Data recieve body
		Types.u8.Read("InvocationIdentifier", Block)
		Block:Line(`local {DataValues} = {Util.GetPath(DataIdentifier, false, Scope)}()`)

		--> A refused invocation still has to be ANSWERED. The caller is suspended on `Calls[id]` with
		--> no timeout, so dropping the call silently leaks that entry and hangs the coroutine until
		--> the slot is reused by an unrelated call -- which then resumes the wrong thread. This is
		--> the same three-byte failure reply the error path writes, so the caller rejects promptly.
		-->
		--> `return` rather than `continue`: this sits inside the per-event `pcall(function()`, and
		--> returning from it lands back in the decode loop exactly as continuing would.
		local RateGuard = RateGuardExpression(Value, Name)
		if RateGuard then
			Block:Line(`if not {RateGuard} then`)
			Block:Line("\tLoad(PlayersMap[Player])")
			Block:Line("\tlocal Position = Allocate(3)")
			Block:Line(`\tbuffer.writeu8(SendBuffer, Position, {Index})`)
			Block:Line("\tbuffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)")
			Block:Line("\tbuffer.writeu8(SendBuffer, Position + 2, 0)")
			Block:Line("\tSavePlayerBuffer(Player)")
			Block:Line("\treturn")
			Block:Line("end")
		end

		--> The listening side passes a Player only when it IS the server. A client listening to a
		--> function the server invokes has no player to name: the caller is the server.
		local Caller = if OnServer then "Player, " else ""
		Block:Compare(Connection, "nil", "Not")
			:Line(`Spawn({Connection}, {Caller}{DataArguments}, InvocationIdentifier)`)
			:Branch("Default")
			:Compare(`#{Queue}`, "256", "Greater")
			:Line(`warn("[Blink]: Event queue of \\"{Name}\\" exceeded 256, did you forget to implement a listener?")`)
			:End()
			:Line(`table.insert({Queue}, \{{Caller}{DataArguments}, InvocationIdentifier\} :: \{any\})`)
			:End()

		--> Data listener body
		local FlushQueue = Blocks.Function("", "", "()")
			:Line(`local EventQueue = {Queue} or \{\}`)
			:Line(`{Queue} = nil`)
			:Iterator("Index", "Arguments", "EventQueue")
			:Line(`{Connection}(table.unpack(Arguments))`)
			:End()
			:End()
			:Wrap("Spawn(", ")")

		local Serialize = Blocks.Function("", "")
			:Line(`{ReturnArguments} = Listener({if OnServer then "Player, " else ""}{DataArguments})`)
			:End()
			:Wrap("local Success, Error = pcall(", ")")

		--> Writing the reply. The server holds one send buffer per player and has to swap the right one
		--> in first; the client has a single buffer aimed at the server and nothing to select.
		local TrueListener = Blocks.Function(
			Connection,
			`{if OnServer then "Player: Player, " else ""}{DataValues}, InvocationIdentifier: number`,
			"()",
			true
		)
			:Line(`local {ReturnValues};`)
			:Lines(Serialize.Content, 1)

		if OnServer then
			TrueListener:Line("Load(PlayersMap[Player])")
		end

		--> Serialising the reply is protected for the same reason calling the listener is.
		-->
		--> It was not, and the gap was the worst shape a gap can take: the return serialiser carries
		--> the same hard type asserts every write does, so a listener returning the wrong type threw
		--> from OUTSIDE the pcall above. That skipped the reply and the save both, and the caller --
		--> who is owed exactly one answer -- got none, waiting out the full invocation timeout for
		--> what is really an immediate, local, reportable mistake.
		-->
		--> Failing the write folds into the failure reply below instead of adding a second path,
		--> which is also what keeps "exactly one reply, always" true by construction.
		TrueListener:Compare("Success", "true", "Equals")
			:Line("local Cursor, Instances = Mark()")
			:Line(
				`Success, Error = pcall({Util.GetPath(ReturnIdentifier, true, Scope)}, {ReturnArguments}, InvocationIdentifier)`
			)
			:Compare("Success", "true", "Not")
			:Line("Rollback(Cursor, Instances)")
			:End()
			:End()

		TrueListener:Compare("Success", "true", "Not")
			:Line("local Position = Allocate(3)")
			:Line(`buffer.writeu8(SendBuffer, Position, {Index})`)
			:Line(`buffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)`)
			:Line(`buffer.writeu8(SendBuffer, Position + 2, 0)`)
			:Line(`warn(\`"{Name}" encountered an error, \{Error\}\`)`)
			:End()

		if OnServer then
			TrueListener:Line("SavePlayerBuffer(Player)")
		end

		TrueListener:End()

		local ListenerSignature = `Listener: ({if OnServer then "Player, " else ""}{DataTypes}) -> ({ReturnTypes})`
		local Listener = Blocks.Function(Casing.On, ListenerSignature, "()", true)
			:Lines(TrueListener.Content, 1)
			:Lines(FlushQueue.Content, 1)
			:End()

		Noop.Push(`{Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
		Body.PushLines(Listener.Content, 0, 2)
	else
		--> Return recieve body
		local Deserialize = Blocks.Function("", "")
			:Return(`{Util.GetPath(ReturnIdentifier, false, Scope)}()`)
			:End()
			:Wrap(`local Success, {ReturnArguments} = pcall(`, ")")

		Types.u8.Read("InvocationIdentifier", Block)
		Block:Lines(Deserialize.Content, Block.Indent + 1)
		--> The slot is freed before the thread is resumed, so a caller that immediately invokes again
		--> from inside its own continuation gets a slot rather than an exhaustion error.
		-->
		--> The status check is not paranoia: a Promise that was cancelled, or a Future that already
		--> completed, leaves a thread that is dead or running. `task.spawn` on either of those throws
		--> from inside the remote handler, where no user pcall can reach it.
		--> A server looks the reply up in the REPLYING PLAYER's own table, so an id belonging to a call
		--> made to somebody else simply is not there. That is the check, and it is structural.
		local Forget = if ForgetCaller ~= "" then { ForgetCaller } else {}
		Block:Compare(TakeCaller, "nil", "Not")
			:Line(`local Thread = {TakeCaller}`)
			:Lines(Forget, 0)
			:Line(ReleaseSlot)
			:Compare("coroutine.status(Thread)", `"suspended"`, "Equals")
			:Line(`task.spawn(Thread, Success, {ReturnArguments})`)
			:End()
			:End()

		local Error = `"There was an exception while processing \\"{Name}\\"."`
		--> A server invoking has to say WHICH client it is asking.
		local InvokeValues = `{if ServerCalls then "Player: Player, " else ""}{DataValues}`
		--> Sending the call. Again the server has to select the target player's buffer around the write.
		local Send = Blocks.Block():Line(`local InvocationIdentifier = {ClaimSlot}`)
		if ServerCalls then
			Send:Line("Load(PlayersMap[Player])")
		end

		--> Releasing the slot when the ARGUMENTS fail to serialise.
		-->
		--> The slot is claimed before the write and the caller is parked after it, so a throw in
		--> between used to strand the slot with nothing outstanding: no entry in `Calls`, so nothing
		--> for the timeout to find and reclaim. Thirty-two rejected calls -- the same wrong argument
		--> thirty-two times -- and every later invocation fails for the lifetime of the session.
		--> This is the one leak the timeout cannot cover, because the timeout is armed after it.
		Send:Line("local Cursor, Instances = Mark()")
		Send:Line(
			`local Sent, Failure = pcall({Util.GetPath(DataIdentifier, true, Scope)}, {DataArguments}, InvocationIdentifier)`
		)
		Send:Compare("Sent", "true", "Not")
			:Line("Rollback(Cursor, Instances)")
			:Line(ReleaseSlot)
			:Line("error(Failure, 0)")
			:End()

		if ServerCalls then
			Send:Line("SavePlayerBuffer(Player)")
		end

		local Contents = Send:Line(ParkCaller)
			:Line(ArmTimeout)
			:Line(`local Success, {ReturnValues} = coroutine.yield()`)
			:Compare("Success", "true", "Not")
			:Line(`error({Error})`)
			:End()
			:Return(ReturnArguments).Content

		local Invoke
		if IsFuture then
			local Wrapper = Blocks.Function("", ""):Lines(Contents):End():Wrap("return Future.Try(", ")")

			Invoke = Blocks.Function(Casing.Invoke, InvokeValues, `Future.Future<boolean, {ReturnTypes}>`, true)
			Invoke:Lines(Wrapper.Content, 1)
		elseif IsPromise then
			--> A cancelled promise gives its slot back too, otherwise cancelling enough calls would
			--> exhaust the bitset with nothing outstanding.
			local Cancel = Blocks.Function("", "")
			if ForgetCaller ~= "" then
				Cancel:Line(ForgetCaller)
			end

			local OnCancel = Cancel:Line(ReleaseSlot):End():Wrap("OnCancel(", ")")

			local Promise = Blocks.Function("", "Resolve, Reject, OnCancel")
				:Line(`local InvocationIdentifier = {ClaimSlot}`)
			if ServerCalls then
				Promise:Line("Load(PlayersMap[Player])")
			end

			Promise:Line("local Cursor, Instances = Mark()")
			Promise:Line(
				`local Sent, Failure = pcall({Util.GetPath(DataIdentifier, true, Scope)}, {DataArguments}, InvocationIdentifier)`
			)
			Promise:Compare("Sent", "true", "Not")
				:Line("Rollback(Cursor, Instances)")
				:Line(ReleaseSlot)
				:Line("error(Failure, 0)")
				:End()

			if ServerCalls then
				Promise:Line("SavePlayerBuffer(Player)")
			end

			Promise:Line(ParkCaller)
				:Line(ArmTimeout)
				:Lines(OnCancel.Content, 1)
				:Line(`local Success, {ReturnValues} = coroutine.yield()`)
				:Compare("Success", "true", "Not")
				:Line(`Reject({Error})`)
				:Return("")
				:End()
				:Line(`Resolve({ReturnArguments})`)
				:End()
				:Wrap(`return Promise.new(`, ")")

			Invoke = Blocks.Function(Casing.Invoke, InvokeValues, nil, true)
			Invoke:Lines(Promise.Content, 1)
		else
			Invoke = Blocks.Function(Casing.Invoke, InvokeValues, `({ReturnTypes})`, true)
			Invoke:Lines(Contents, 0)
		end

		Invoke:End()
		Noop.Push(`{Casing.Invoke} = NOOP`, 0, Indent + 1)
		Body.PushLines(Invoke.Content, 0, Indent + 1)
	end

	Channel.Count += 1
	Channel.Listening = true

	Noop.Push(`\},`, 0, Indent)
	Body.Push(`\},`, 0, Indent)
	Return.PushLines(Body.DumpLines(), 0)
end

--> Generator functions
--- Dispatches a node to the serde function for its kind. Serde.Emit points back here so that a
--- struct, an array or a map can emit whatever it contains without either file requiring the other.
function Generators.UserType(Declaration: Type, Read: Blocks.Block, Write: Blocks.Block, Variable: string?)
	local Name = Declaration.Name
	local Target = Variable or "Value"

	if not _G.RELEASE then
		Read:Comment(`{Target}: {Name}`)
		Write:Comment(`{Target}: {Name}`)
	end

	if Declaration.Type == "Primitive" then
		local Kind = (Declaration :: Parser.Primitive).Tokens.Primitive.Value
		if Kind == "Instance" then
			Read:Line("RecieveInstanceCursor += 1")
		end

		Declarations.Primitive(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Set" then
		Declarations.Set(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Map" then
		Declarations.Map(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Enum" then
		Declarations.Enum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Struct" then
		Declarations.Struct(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Tuple" then
		Declarations.Tuple(Declaration, Read, Write)
	elseif Declaration.Type == "TagEnum" then
		Declarations.TagEnum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Array" then
		Declarations.Array(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Optional" then
		Declarations.Optional(Declaration, Read, Write, Target)
	end
end

function Generators.LuauType(
	Declaration: Type,
	UseTypeAsValue: boolean?,
	Prefix: string?
): (string, string, string, string)
	Prefix = Prefix or ""

	local Type = "nil"
	local Values = "Value: nil"
	local Export = Util.GetExportName(Declaration.Name, Scope)
	local Returns = `{Prefix}Value`

	if Declaration.Type == "Primitive" then
		local Tokens = (Declaration :: Parser.Primitive).Tokens
		local Primitive = Primitives[Tokens.Primitive.Value]
		if type(Primitive.Type) == "function" then
			Type = Primitive.Type(Declaration :: Parser.Primitive)
		else
			Type = Primitive.Type
		end
	elseif Declaration.Type == "Set" then
		local Value = (Declaration :: Parser.Set).Value
		local Entries: { string } = {}

		for _, Flag in Value.Values do
			table.insert(Entries, `{FormatKey(Flag)}: boolean,`)
		end

		Type = `\{{table.concat(Entries)}\}`
	elseif Declaration.Type == "Enum" then
		local Value = (Declaration :: Parser.Enum).Value
		Type = `({Util.GenerateEnumLiterals(Value.Values)})`
	elseif Declaration.Type == "TagEnum" then
		local Value = (Declaration :: Parser.TagEnum).Value
		local Literals = {}

		for _, Variant in Value.Values do
			local TagField = `{FormatKey(Value.Tag)}: "{Variant.Name}"`
			local ValueType = Generators.LuauType(Variant)
			table.insert(Literals, `\{ {TagField},{string.sub(ValueType, 2)}`)
		end

		Type = table.concat(Literals, " | ")
	elseif Declaration.Type == "Map" then
		local MapValue = (Declaration :: Parser.Map).Value
		local Key = Generators.LuauType(MapValue.Values[1])
		local Value = Generators.LuauType(MapValue.Values[2])
		Type = `\{[{Key}]: {Value}\}`
	elseif Declaration.Type == "Struct" then
		local Value = Declaration.Value
		local Fields = {}

		for _, Field in Value.Values do
			local Name = Field.Name
			local FieldType = Generators.LuauType(Field)
			table.insert(Fields, `{FormatKey(Name)}: {FieldType}`)
		end

		Type = `\{ {table.concat(Fields, ", ")}\ }`
	elseif Declaration.Type == "Generic" then
		Type = `{Declaration.Value.Generic}`
	elseif Declaration.Type == "Tuple" then
		local Value = (Declaration :: Parser.Tuple).Value

		local TupleTypes = { "nil" }
		local Variables = { "Value" }
		local AnnotatedVariables = { "Value: nil" }

		--> The prefix applies to a named element too: a function's Data and Return packs share a scope
		--> in the generated body, so it is what keeps `(id: u8)` and `(id: string)` from colliding.
		for Index, TupleValue in Value.Values do
			local Variable = `{Prefix}{Value.Names[Index] or `Value{Index}`}`
			local ValueType = Generators.LuauType(TupleValue)

			TupleTypes[Index] = ValueType
			Variables[Index] = Variable
			AnnotatedVariables[Index] = `{Variable}: {ValueType}`
		end

		Type = table.concat(TupleTypes, ", ")
		Values = table.concat(AnnotatedVariables, ", ")
		Returns = table.concat(Variables, ", ")
	elseif Declaration.Type == "Array" then
		local Value = Declaration.Value
		Type = `\{ {Generators.LuauType(Value.Of)} }`
	elseif Declaration.Type == "Optional" then
		local Value = Declaration.Value
		Type = `{Generators.LuauType(Value.Of)}?`
	end

	local Value = Declaration.Value

	if Value.Parameters then
		local Parameters = {}

		--> Generate luau types for parameters
		for _, Parameter in Value.Parameters do
			local ParameterType = Generators.LuauType(Parameter)
			table.insert(Parameters, ParameterType)
		end

		--> Wrap in chevrons
		Type = `{Type}<{table.concat(Parameters, ",")}>`
	end

	--> Generalized type generation, works for everything except tuples
	if Declaration.Type ~= "Tuple" then
		Values = `{Prefix}Value: {UseTypeAsValue and Type or Export}`
	end

	return Type, Values, Export, Returns
end

function Generators.Type(Declaration: Type)
	local Value = Declaration.Value
	local Type, _, Export = Generators.LuauType(Declaration)

	local Generics = ""
	if Value.Generics then
		local GenericNames = {}
		for _, Generic in Value.Generics.List do
			table.insert(GenericNames, Generic)
		end

		Generics = `<{table.concat(GenericNames, ",")}>`
	end

	--> Write luau export
	LuauTypes.PushMultiline(`export type {Export}{Generics} = {Type}`, 1, 0)
end

function Generators.Export(Declaration: Type)
	local Name = Declaration.Name
	local _, Values, Export, Returns = Generators.LuauType(Declaration)

	local Read = Blocks.Function(Casing.Read, "Buffer: buffer", `({Export})`, true)
	local Write = Blocks.Function(Casing.Write, `{Values}`, `(buffer)`, true)

	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(Scope)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> Overwrite buffer
	Read:Comment("Buffer overwrite")
	Write:Comment("Buffer overwrite")

	Read:Lines({
		"local PreviousCursor = RecieveCursor\n",
		"local PreviousBuffer = RecieveBuffer\n",
		"local PreviousInstanceCursor = RecieveInstanceCursor\n",
		"RecieveCursor = 0\n",
		"RecieveBuffer = Buffer\n",
	}, 1)

	Write:Lines({
		"local Previous = Save()\n",
		"Load()\n",
	}, 1)

	Read:Advance(#Read.Content - 1)
	Write:Advance(#Write.Content - 1)

	--> Write to buffer
	Read:Comment("Buffer read")
	Write:Comment("Buffer write")

	Generators.UserType(Declaration, Read, Write)

	--> The payload is complete, so any half-filled bitfield has to reach the buffer BEFORE the trim
	--> and the return below. Left to `End`, it would be emitted after the return.
	Read:FlushBits()
	Write:FlushBits()

	--> Restore buffer
	Read:Comment("Buffer restore")
	Write:Comment("Buffer restore")

	Read:Lines({
		"RecieveCursor = PreviousCursor\n",
		"RecieveBuffer = PreviousBuffer\n",
		"RecieveInstanceCursor = PreviousInstanceCursor\n",
	}, 1)

	--> Trim buffer
	Write:Line("local Result = buffer.create(SendCursor)")
	Write:Line("buffer.copy(Result, 0, SendBuffer, 0, SendCursor)")

	Write:Line(`Load(Previous)`)

	--> End export
	Read:Return(Returns)
	Write:Return("Result")

	Read:End():Wrap("", ",")
	Write:End()

	Body.PushLines(Read.Content, 0, Indent + 1)
	Body.PushLines(Write.Content, 0, Indent + 1)
	Body.Push(`\},`, 0, Indent)

	local BodyLines = Body.DumpLines()

	Noop.PushLines(table.clone(BodyLines), 0, 0)
	Return.PushLines(BodyLines, 0, 0)
end

function Generators.Event(
	Data: Type?,
	Index: number,
	Identifier: string,
	Function: ("Data" | "Return")?,
	Ordered: boolean?
): ({ string }, { string })
	local Type, Values, _, Returns = "nil", "Value: nil", nil, "nil"
	if Data then
		Type, Values, _, Returns = Generators.LuauType(Data, true)
	end

	local Arguments = `{Values}{Function and ", InvocationIdentifier: number" or ""}`
	local Read = Blocks.Function(Util.GetPath(Identifier, false, Scope), "", `({Type})`)
	local Write = Blocks.Function(Util.GetPath(Identifier, true, Scope), Arguments, "()")

	if not _G.RELEASE then
		Write:Comment(`{Identifier} ({Index})`)
	end

	--> The event index is a literal in the generated code; the writers take the text form.
	Types.u8.Write(tostring(Index), Write)

	--> An ordered event carries a per-event sequence number after its index. It wraps at 65536, and
	--> the receiver's comparison is written to tolerate that.
	if Ordered then
		Write:Line(`local OrderIdentifier = ((OrderOut[{Index}] or 0) + 1) % 65536`)
		Write:Line(`OrderOut[{Index}] = OrderIdentifier`)
		Types.u16.Write("OrderIdentifier", Write)
	end
	if Function then
		Types.u8.Write("InvocationIdentifier", Write)
		if Function == "Return" then
			Types.u8.Write("1", Write)
			Types.u8.Read("Success", Read)
			Read:Compare("Success", "1", "Not"):Line('error("Server encountered an error.")'):End()
		end
	end

	if Data then
		Generators.UserType(Data, Read, Write)
	end

	Read:FlushBits()
	Write:FlushBits()

	return Read:Return(Returns):End().Content, Write:End().Content
end

function Generators.Scope(Declaration: Parser.ScopeNode)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local Parent = Scope
	local NewScope = Value.Scope

	local Path = Util.GetScopePrefix(NewScope, true, Scope)
	local Indent = (#string.split(Path, ".") - 1)
	Path = string.sub(Path, 1, #Path - 1)

	Scope = NewScope
	Noop.Push(`{Name} = \{`, 0, Indent)
	Return.Push(`{Name} = \{`, 0, Indent)

	Generators.AbstractSyntaxTree(Value.Values)

	Noop.Push(`},`, 0, Indent)
	Return.Push(`},`, 0, Indent)
	Scope = Parent
end

function Generators.AbstractSyntaxTree(Tree: { Parser.Declaration })
	for _, Declaration in Tree do
		if Context == "Shared" and IGNORED_TYPES_IN_SHARED[Declaration.Type] then
			continue
		end

		if Declaration.Type == "Scope" then
			Generators.Scope(Declaration :: Parser.ScopeNode)
		elseif Declaration.Type == "Event" then
			Declarations.Event(Declaration :: Parser.Event)
		elseif Declaration.Type == "Function" then
			Declarations.Function(Declaration :: Parser.Function)
		else
			if Declaration.Value.Export then
				Generators.Export(Declaration :: Type)
			end

			Generators.Type(Declaration :: Type)
		end
	end
end

local Generator = {}

function Generator.Reset()
	--> Setup new builders
	Noop = Builder.new()
	Events = Builder.new()
	UserTypes = Builder.new()
	LuauTypes = Builder.new()
	Return = Builder.new()

	table.clear(RateSlots)
	UsesOrdering = false

	--> Reset channels
	Channels.Reliable.Count = 0
	Channels.Unreliable.Count = 0
	Channels.Reliable.Listening = false
	Channels.Unreliable.Listening = false
end

function Generator.Generate(FileContext: Context, AbstractSyntaxTree: Parser.Body): string
	local Imports = Builder.new()

	Generator.Reset()
	Context = FileContext
	Options = AbstractSyntaxTree.Value.Options
	Serde.Options = Options
	Casing = Settings.GetCasing((Options.Casing :: Settings.Case) or "Pascal")

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
	Noop.Push(`if not RunService:IsRunning() then`)
	Noop.Push(`local NOOP = function() end`, 0, 1)
	Noop.Push(`local NOOP_RETURNING = function() return NOOP end`, 0, 1)
	Noop.Push(`local Returns = table.freeze(\{`, 0, 1)

	--> Setup remote events
	local Signal = Context == "Client" and "OnClientEvent" or "OnServerEvent"
	local Arguments = (Context == "Server" and "Player: Player, " or "") .. "Buffer: buffer, Instances: {Instance}"

	Reliables = Blocks.Connection(`Reliable.{Signal}`, Arguments)
	Unreliables = Blocks.Connection(`Unreliable.{Signal}`, Arguments)

	--> Reject a hostile packet before any of it is parsed. Both checks read the arguments the remote
	--> handed us, so they must come before EVENT_BODY copies them into the module-level cursors.
	if Context == "Server" then
		local MaxPacketSize = Options.MaxPacketSize or DEFAULT_MAX_PACKET_SIZE
		local MaxInstances = Options.MaxInstancesPerPacket or DEFAULT_MAX_INSTANCES_PER_PACKET

		local function EmitInboundGuard(Channel: Blocks.Block)
			--> Nothing stops a client from calling FireServer with arguments of its own choosing, and
			--> the signature is a promise the client never made. `buffer.len` on a string throws from
			--> inside the connection itself, where no listener's pcall can reach it, so the types have
			--> to be established before any other guard reads them.
			Channel:Line(`if typeof(Buffer) ~= "buffer" or type(Instances) ~= "table" then`, 1)
			Channel:Line(`\twarn(\`[Blink]: Dropped a malformed packet from \{Player.Name\}.\`)`, 1)
			Channel:Line("\treturn", 1)
			Channel:Line("end", 1)
			Channel:Line(`if buffer.len(Buffer) > {MaxPacketSize} then`, 1)
			Channel:Line(`\twarn(\`[Blink]: Dropped an oversized packet from \{Player.Name\}.\`)`, 1)
			Channel:Line("\treturn", 1)
			Channel:Line("end", 1)
			Channel:Line(`if #Instances > {MaxInstances} then`, 1)
			Channel:Line(`\twarn(\`[Blink]: Dropped a packet with too many instances from \{Player.Name\}.\`)`, 1)
			Channel:Line("\treturn", 1)
			Channel:Line("end", 1)
		end

		EmitInboundGuard(Reliables)
		EmitInboundGuard(Unreliables)
	end

	Reliables:Lines(EVENT_BODY, 1)
	Unreliables:Lines(EVENT_BODY, 1)

	if Options.SyncValidation then
		Reliables:Lines(EVENT_SYNC_VALIDATION, 1)
		Unreliables:Lines(EVENT_SYNC_VALIDATION, 1)
	end

	--> The size cap alone does not bound the work: a packet of single-byte event tags decodes one
	--> event per byte, so an 8 KB packet still means thousands of listener dispatches. Counting the
	--> decoded events bounds that directly.
	local MaxEvents = Options.MaxEventsPerPacket or DEFAULT_MAX_EVENTS_PER_PACKET
	if Context == "Server" then
		Reliables:Line("local DecodedEvents = 0", 1)
		Unreliables:Line("local DecodedEvents = 0", 1)
	end

	--> A player who leaves mid-packet is not worth decoding the rest for: every listener that runs
	--> from here on receives a Player already detached from the DataModel, and anything they do with
	--> it -- a leaderstats write, a save -- is work aimed at nobody.
	local Condition = if Context == "Server"
		then "RecieveCursor < Size and Player.Parent ~= nil"
		else "RecieveCursor < Size"

	Reliables = Reliables:While(Condition)
	Unreliables = Unreliables:While(Condition)

	if Context == "Server" then
		local function EmitEventCap(Channel: Blocks.Block)
			Channel:Line("DecodedEvents += 1")
			Channel:Line(`if DecodedEvents > {MaxEvents} then`)
			Channel:Line(`\twarn(\`[Blink]: Dropped the rest of a packet from \{Player.Name\}, too many events.\`)`)
			Channel:Line("\tbreak")
			Channel:Line("end")
		end

		EmitEventCap(Reliables)
		EmitEventCap(Unreliables)
	end

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
	--> Measured at +109ns per decoded event, against ~20ns for the buffer read it guards -- real, and
	--> irrelevant next to the listener dispatch that follows it.
	Reliables:Line("local Parsed = pcall(function()")
	Unreliables:Line("local Parsed = pcall(function()")

	Types.u8.Read("Index", Reliables)
	Types.u8.Read("Index", Unreliables)

	--> Import async libraries
	if Options.FutureLibrary then
		Imports.Push(`local Future = require({Options.FutureLibrary})`)
	end

	if Options.PromiseLibrary then
		Imports.Push(`local Promise = require({Options.PromiseLibrary})`)
	end

	--> Replication
	local Replication = Builder.new()
	Return.Push(`{Casing.StepReplication} = StepReplication,`, 1, 1)
	--> The stub table has to expose it too. Under ManualReplication a story calls StepReplication
	--> itself, and its absence here made that a nil call rather than a no-op.
	Noop.Push(`{Casing.StepReplication} = NOOP,`, 0, 2)

	Return.Push(`{Casing.SetRateLimitHandler} = SetRateLimitHandler,`, 1, 1)
	Noop.Push(`{Casing.SetRateLimitHandler} = NOOP,`, 0, 2)

	if not Options.ManualReplication then
		Replication.Push("RunService.Heartbeat:Connect(StepReplication)")
	end

	--> Parse declarations
	Generators.AbstractSyntaxTree(AbstractSyntaxTree.Value.Declarations)

	--> Generate context source
	local Source = Sources[Context]

	--> An unknown event index means the packet is not what it claims to be: the byte came from a
	--> client, and the cursor is no longer at an event boundary, so nothing after it can be trusted.
	--> Without this branch the loop silently fell through and kept reading, which is how a buffer of
	--> unrecognised tags turned into a full-length parse.
	--> `error` and not `break`: this branch sits inside the pcall'd decode function opened above, and
	--> Luau cannot break out of a loop across a function boundary. Raising here lands in that pcall,
	--> which turns into the `break` below — the same stop, expressed where it is legal.
	local UNKNOWN_EVENT = `error("[Blink]: Unknown event index.")`

	if Channels.Reliable.Listening then
		Reliables = Reliables:Branch("Default"):Line(UNKNOWN_EVENT):End()
	end

	if Channels.Unreliable.Listening then
		Unreliables = Unreliables:Branch("Default"):Line(UNKNOWN_EVENT):End()
	end

	--> Close the decode function opened above and act on its result.
	-->
	--> The server says nothing: the packet came from a client, and letting one fill a server's output
	--> window is its own denial of service. The client says so once, because a packet it cannot parse
	--> is a bug in the game rather than an attack, and silence there is what made the original report
	--> so hard to diagnose -- events simply stopped arriving.
	local function EmitDecodeResult(Channel: Blocks.Block)
		Channel:Line("end)")
		if Context == "Client" then
			Channel:Line("if not Parsed then")
			Channel:Line(`\twarn("[Blink]: Dropped a packet that could not be decoded.")`)
			Channel:Line("\tbreak")
			Channel:Line("end")
		else
			Channel:Line("if not Parsed then break end")
		end
	end

	EmitDecodeResult(Reliables)
	EmitDecodeResult(Unreliables)

	Reliables = Reliables:End():End()
	Unreliables = Unreliables:End():End()

	Noop.Push(`\})`, 0, 1)
	Noop.Push(`return Returns :: {EVENTS_TYPE}`, 0, 1)
	Noop.Push(`end`, 0, 0)

	Return.PushFront(`\nlocal Returns = table.freeze(\{`)
	Return.Push(`})`)

	local ScopeValidationBody = {}
	if Context ~= "Shared" then
		local RemoteScope = Options.RemoteScope or "BLINK"
		ScopeValidationBody = {
			"_G._BLINK = _G._BLINK or {}\n",
			`if _G._BLINK["{RemoteScope}"] then\n`,
			`\terror("[Blink]: An instance of blink is already running with the remote scope \\"{RemoteScope}\\". Change the remote scope of either instance to avoid conflicts.")\n`,
			"end\n",
			`_G._BLINK["{RemoteScope}"] = true\n`,
		}
	end

	--> Sequence bookkeeping for OrderedUnreliable, emitted only where the schema uses it.
	-->
	--> Outgoing is a counter per event; incoming is the last sequence seen per event, per SOURCE --
	--> which on the server means per player, since sixty clients each have their own sequence.
	local OrderingBody = {}
	if UsesOrdering then
		local Shared = {
			"\n",
			"--> Sequence numbers for ordered unreliable events, one counter per event.\n",
			"local OrderOut: { number } = {}\n",
		}

		if Context == "Server" then
			table.move({
				"local OrderIn: { [Player]: { number } } = {}\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one seen from this player for\n",
				"--> this event. The comparison tolerates the counter wrapping at 65536: a sequence far\n",
				"--> BELOW the last one is not stale, it is the counter having gone round.\n",
				"local function OrderAccept(Player: Player, Slot: number, Identifier: number): boolean\n",
				"\tlocal State = OrderIn[Player]\n",
				"\tif not State then\n",
				"\t\tState = {}\n",
				"\t\tOrderIn[Player] = State\n",
				"\tend\n",
				"\n",
				"\tlocal Last = State[Slot]\n",
				"\tif Last ~= nil and Identifier <= Last and (Last - Identifier) < 32767 then\n",
				"\t\treturn false\n",
				"\tend\n",
				"\n",
				"\tState[Slot] = Identifier\n",
				"\treturn true\n",
				"end\n",
			}, 1, 20, #Shared + 1, Shared)
		else
			table.move({
				"local OrderIn: { number } = {}\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one seen for this event. The\n",
				"--> comparison tolerates the counter wrapping at 65536.\n",
				"local function OrderAccept(Slot: number, Identifier: number): boolean\n",
				"\tlocal Last = OrderIn[Slot]\n",
				"\tif Last ~= nil and Identifier <= Last and (Last - Identifier) < 32767 then\n",
				"\t\treturn false\n",
				"\tend\n",
				"\n",
				"\tOrderIn[Slot] = Identifier\n",
				"\treturn true\n",
				"end\n",
			}, 1, 13, #Shared + 1, Shared)
		end

		OrderingBody = Shared
	end

	--> Emitted only when the schema actually has unreliable events -- most do not, and a helper
	--> nothing calls is noise in a file people read when debugging their own traffic.
	local UnreliableGuardBody = {}
	if Channels.Unreliable.Count > 0 then
		local MaxUnreliableSize = Options.MaxUnreliableSize or DEFAULT_MAX_UNRELIABLE_SIZE
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
			'\twarn(`[Blink]: Dropped unreliable event "{Name}", {SendCursor} bytes exceeds the {MAX_UNRELIABLE_SIZE} byte limit.`)\n',
			"\treturn false\n",
			"end\n",
		}
	end

	--> Initial contents of a player's rate bucket: tokens, refill clock, report clock, per limited
	--> declaration. Cloned per player on first use, so one allocation per player per session rather
	--> than a table per event.
	local RateTemplateBody = {}
	if Context == "Server" then
		local Entries = {}
		for _, Slot in RateSlots do
			table.insert(Entries, `{Slot.Burst}, 0, 0`)
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
		Util.Constants(Options.RemoteScope, AbstractSyntaxTree),
		string.split(Sources.Base, "\r"),
		RateTemplateBody,
		OrderingBody,
		UnreliableGuardBody,
		(if Options.SyncValidation then SYNC_VALIDATION_BODY else {}),
		Events.DumpLines(),
		LuauTypes.DumpLines(),
		UserTypes.DumpLines(),
		Noop.DumpLines(),
		string.split(Source[2], "\r"),
		Replication.DumpLines(),
		Reliables.Content,
		Unreliables.Content,
		Return.DumpLines(),
		{ `type {EVENTS_TYPE} = typeof(Returns)\n`, `return Returns :: {EVENTS_TYPE}` }
	)

	return table.concat(MergedOutput)
end

function Generator.GenerateShared(AbstractSyntaxTree: Parser.Body): string
	Generator.Reset()
	Context = "Shared"
	Options = AbstractSyntaxTree.Value.Options
	Serde.Options = Options
	Casing = Settings.GetCasing((Options.Casing :: Settings.Case) or "Pascal")

	--> Parse declarations
	Generators.AbstractSyntaxTree(AbstractSyntaxTree.Value.Declarations)

	--> Generate context source
	local Source = Sources[Context]
	local MergedOutput = Table.Merge(
		DIRECTIVES,
		VERSION_HEADER,
		string.split(Source[1], "\r"),
		string.split(Sources.Base, "\r"),
		LuauTypes.DumpLines(),
		{ "\n" },
		UserTypes.DumpLines(),
		string.split(Source[2], "\r"),
		{ "\n" },
		{ `\nreturn \{\n` },
		Return.DumpLines(),
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
