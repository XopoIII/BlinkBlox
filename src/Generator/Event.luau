--!strict
--!native
--!optimize 2

--- Emits one `event`: its serialisers, the branch that receives it, and the API the game calls --
--- `On`, `Iter` or `Fire` and its variants, depending on which side this is and which side sends.
---
--- Adds `Event` to the Serde table, which the declaration walk in Generators.luau dispatches through.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Fragments = require("./Fragments")
local Generators = require("./Generators")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Queues = require("./Queue")
local Serde = require("./Serde")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode

local RELIABLE_BODY = Fragments.RELIABLE_BODY
local UNRELIABLE_BODY = Fragments.UNRELIABLE_BODY
local Types = Prefabs.Types
local RateGuardExpression = Decode.RateGuardExpression
local OrderGuardExpression = Decode.OrderGuardExpression
local Declarations = Serde

function Declarations.Event(Declaration: Parser.Event)
	local Value = Declaration.Value

	local Identifier = `EVENT_{Declaration.Name}`
	local Reliability = Value.Type

	local IsReliable = (Reliability == "Reliable")
	--> Ordered events travel the unreliable channel; the ordering is a sequence number on top of it.
	local IsOrdered = (Reliability == "OrderedUnreliable")
	local IsUnreliable = (Reliability == "Unreliable" or IsOrdered)

	if IsOrdered then
		State.UsesOrdering = true
	end
	local IsPolling = (Value.Call == "Polling" or State.Options.UsePolling)
	local IsSameContext = Value.From == State.Context

	local Block = IsUnreliable and State.Unreliables or State.Reliables
	local Channel = IsUnreliable and State.Channels.Unreliable or State.Channels.Reliable

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
		State.UserTypes.PushLines(Write, 1, 0)
	else
		State.UserTypes.PushLines(Read, 1, 0)
	end

	--> Return body
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)
	local WriteEvent = `{Util.GetPath(Identifier, true, State.Scope)}({Arguments})`
	--> The same call, protected. Only the CLIENT needs it: every server fire begins with its own
	--> `Load`, so a write that throws is confined to scratch state the next `Load` replaces, while
	--> the client writes straight into the batch it is still accumulating.
	local TryWriteEvent = `pcall({Util.GetPath(Identifier, true, State.Scope)}, {Arguments})`

	Body.Push(`{Declaration.Name} = \{`, 0, Indent)
	State.Noop.Push(`{Declaration.Name} = \{`, 0, Indent)

	if Value.From ~= State.Context and IsPolling ~= true then
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
			State.Events.Push(`{Connection} = \{}`)
		end

		State.Events.Push(`{Queue} = table.create(256)`)
		State.Events.Push(`EventNames.{ChannelName}[{Index}] = "{Declaration.Name}"`)
		Block = (Channel.Listening == false) and Block:Compare("Index", Index, "Equals")
			or Block:Branch("Conditional", "Index", Index, "Equals")

		--> Update event block to branch block
		if IsUnreliable then
			State.Unreliables = Block
		else
			State.Reliables = Block
		end

		--> Update channel status
		Channel.Listening = true

		--> Event recieve body
		local Listener: Blocks.Block
		local ContextArguments = `Listener: ({State.Context == "Server" and "Player: Player, " or ""}{Values}) -> ()`
		local ListenerArguments = `{State.Context == "Server" and "Player, " or ""}{Arguments}`

		local CallListener = Blocks.Block()
		do
			if IsSync and State.Options.SyncValidation then
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

		Block:Line(`local {Values} = {Util.GetPath(Identifier, false, State.Scope)}()`)

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

			Queues.Enqueue(ListenerBound:Branch("Default"), State.Context, Queue, ListenerArguments, Declaration.Name)
				:End()

			Listener = BindListener(Blocks.Function(State.Casing.On, ContextArguments, `() -> ()`, true))
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

			Listener = BindListener(Blocks.Function(State.Casing.On, ContextArguments, `() -> ()`, true))
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
		if State.Options.Predict then
			local PredictArguments = `{State.Context == "Server" and "Player: Player, " or ""}{Values}`
			local Predict = Blocks.Function(State.Casing.Predict, PredictArguments, "()", true)

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

			State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING,`, 0, Indent + 1)
			State.Noop.Push(`{State.Casing.Predict} = NOOP`, 0, Indent + 1)
			Body.PushLines(Listener:Wrap("", ",").Content, 0, Indent + 1)
			Body.PushLines(Predict.Content, 0, Indent + 1)
		else
			State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
			Body.PushLines(Listener.Content, 0, Indent + 1)
		end
	elseif Value.From ~= State.Context and IsPolling then
		State.Events.Push(`{Queue} = CreateQueue()`)
		State.Events.Push(`EventNames.{ChannelName}[{Index}] = "{Declaration.Name}"`)
		Block = (Channel.Listening == false) and Block:Compare("Index", Index, "Equals")
			or Block:Branch("Conditional", "Index", Index, "Equals")

		if IsUnreliable then
			State.Unreliables = Block
		else
			State.Reliables = Block
		end

		Channel.Listening = true

		if IsOrdered then
			Types.u16.Read("OrderIdentifier", Block)
		end

		local PollArguments = `table.pack({State.Context == "Server" and "Player, " or ""}{Util.GetPath(
			Identifier,
			false,
			State.Scope
		)}())`
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

		local IterTypes = `number, {State.Context == "Server" and "Player, " or ""}{DataTypes}`

		local Next = Blocks.Function("", "", `({IterTypes})`)
			:Line("index += 1")
			:Line("local arguments = Pop(queue)")
			:Compare("arguments", "nil", "Not")
			:Return("index, unpack(arguments, 1, arguments.n)")
			:End()
			:Return("")
			:End()
			:Wrap("return ", "")

		local Deprecated = Blocks.Function(State.Casing.Next, "", `() -> ({IterTypes})`, true)
			:Line(`local index = 0`)
			:Line(`local queue = {Queue}`)
			:Lines(Next.Content, 1)
			:End()

		local Iter = Blocks.Function(State.Casing.Iter, "", `() -> ({IterTypes})`, true)
			:Line(`local index = 0`)
			:Line(`local queue = {Queue}`)
			:Lines(Next.Content, 1)
			:End()
			:Wrap("", ",")

		State.Noop.Push(`{State.Casing.Iter} = NOOP_RETURNING,`, 0, Indent + 1)
		State.Noop.Push(`{State.Casing.Next} = NOOP_RETURNING`, 0, Indent + 1)

		Body.PushLines(Iter.Content, 0, Indent + 1)
		Body.Push("--- @deprecated v0.14.1 -- Use `Iter` instead.", 0, Indent + 1)
		Body.PushLines(Deprecated.Content, 0, Indent + 1)
	elseif State.Context == "Client" then
		local Fire = Blocks.Function(State.Casing.Fire, Values, "()", true)
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

		State.Noop.Push(`{State.Casing.Fire} = NOOP`, 0, Indent + 1)
		Body.PushLines(Fire.Content, 0, Indent + 1)
	else
		local Fire = Blocks.Function(State.Casing.Fire, `Player: Player, {Values}`, "()", true)
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

		local FireAll = Blocks.Function(State.Casing.FireAll, Values, "()", true)
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

		local FireList = Blocks.Function(State.Casing.FireList, `List: \{Player\}, {Values}`, "()", true)
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

		local FireExcept = Blocks.Function(State.Casing.FireExcept, `Except: Player, {Values}`, "()", true)
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

		State.Noop.PushLines({
			`{State.Casing.Fire} = NOOP,\n`,
			`{State.Casing.FireAll} = NOOP,\n`,
			`{State.Casing.FireList} = NOOP,\n`,
			`{State.Casing.FireExcept} = NOOP\n`,
		}, 0, Indent + 1)

		Body.PushLines(Fire:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireAll:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireList:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireExcept:Wrap("", ",").Content, 0, Indent + 1)
	end

	Channel.Count += 1

	Body.Push(`\},`, 0, Indent)
	State.Noop.Push(`\},`, 0, Indent)
	State.Return.PushLines(Body.DumpLines(), 0)
end

return Declarations
