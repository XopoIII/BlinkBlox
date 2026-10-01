--!strict
--!native
--!optimize 2

--- The receiving side of one `event`: the branch that decodes it, and the `On` and `Predict` or the
--- `Iter` the game hears it through. Event.luau works out what both sides share -- the `Shape` -- and
--- calls in here on the side that does not send.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Listeners = require("./Listeners")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Queues = require("./Queue")
local Stamps = require("./Stamp")
local State = require("./State")
local Streams = require("./Stream")
local Traffic = require("./Traffic")
local Util = require("./Util")

local Types = Prefabs.Types
local RateGuardExpression = Decode.RateGuardExpression
local OrderGuardExpression = Decode.OrderGuardExpression

local Receive = {}

--- What one event is, whichever side is being generated and whichever way it is heard or sent.
export type Shape = {
	Declaration: Parser.Event,
	Identifier: string,
	Index: number,
	--> Ordered events ride the unreliable channel, so they share its queue and listener tables --
	--> naming those after the declared reliability would index a third table that does not exist.
	ChannelName: string,
	Queue: string,
	Connection: string,
	IsReliable: boolean,
	IsUnreliable: boolean,
	IsSequenced: boolean,
	Counters: number?,
	--> Two spellings of the payload: with the schema's names, for what the game sees, and positional
	--> (`Inner`), for the decode branch, where a name like `Player` or `Index` would shadow the loop's own.
	DataTypes: string,
	Values: string,
	Arguments: string,
	InnerValues: string,
	InnerArguments: string,
	Body: Builder.Builder,
	Indent: number,
}

--> Binding the listener. A Single event keeps one, and a second `.On()` replaces it -- which
--> is the documented behaviour and stays that way. What it did not do is say so, and the
--> silence hides a second-order effect: the FIRST listener's returned disconnect function is
--> guarded by `Events[n] == Listener`, so once it has been replaced that disconnect quietly
--> stops doing anything. Two systems that each connect and later disconnect therefore leave a
--> listener attached that neither of them believes it owns. Upstream #167.
local function BindListener(Shape: Shape, IsSingle: boolean, Target: Blocks.Block): Blocks.Block
	local Connection = Shape.Connection
	local Declaration = Shape.Declaration

	--> A Many event's list is replaced, never edited in place: a dispatch in progress iterates
	--> the list it started with. Removing from that list shifted the next listener into an index
	--> the loop had already passed, so a listener that disconnected itself -- a "once" -- made
	--> the one after it miss the event. Copying costs an allocation per connect and disconnect,
	--> and nothing per event.
	if not IsSingle then
		return Target:Line(`local Listeners = table.clone({Connection})`)
			:Line("table.insert(Listeners, Listener)")
			:Line(`{Connection} = Listeners`)
	end

	return Target:Line(`if {Connection} ~= nil then`)
		:Line(
			`\twarn("[BlinkBlox]: \\"{Declaration.Name}\\" already has a listener. {Declaration.Value.Call} keeps only the newest one, and the replaced listener's disconnect stops working.")`
		)
		:Line("end")
		:Line(`{Connection} = Listener`)
end

--> The function `On` returns, which takes the listener back out.
local function Disconnector(Shape: Shape, IsSingle: boolean): Blocks.Block
	local Connection = Shape.Connection
	local Disconnect = Blocks.Function("", "", "()")
	if IsSingle then
		Disconnect = Disconnect:Compare(Connection, "Listener", "Equals"):Line(`{Connection} = nil`):End()
	else
		Disconnect = Disconnect:Line(`local Index = table.find({Connection}, Listener)`)
		Disconnect = Disconnect:Compare("Index", "nil", "Not")
			:Line(`local Listeners = table.clone({Connection})`)
			:Line("table.remove(Listeners, Index)")
			:Line(`{Connection} = Listeners`)
			:Line("ListenerEpoch += 1")
			:End()
	end

	return Disconnect:End():Wrap("return ", "")
end

--> Hands the event to its listeners, or -- for a reliable event with none bound -- queues it for
--> the listener to come. The receive branch and Predict both go through this, so an event
--> predicted locally is delivered exactly as one received from the network would be.
--> A Single event's listener is read once, into a local, rather than looked up through two tables
--> for the check and again for the call.
--> `Received` is the decode loop's delivery, whose Single listener goes without a pcall of its own;
--> see Listeners.Call.
local function Deliver(
	Shape: Shape,
	Event: Listeners.Event,
	IsSingle: boolean,
	Target: Blocks.Block,
	Payload: string,
	Received: boolean
)
	local Connection = Shape.Connection
	local Sender = if State.Context == "Server" then "Player, " else ""
	local ListenerArguments = `{Sender}{Payload}`
	local Call = Listeners.Call(Event, "BOUND_LISTENER", ListenerArguments, "Player", true, Received and IsSingle)
	if IsSingle then
		--> Typed as what it holds: read out of the untyped Events table, the new type solver
		--> refines it against nil into an error type it refuses to call. A cast is erased before
		--> bytecode, so it costs nothing.
		Target:Line(`local BOUND_LISTENER = {Connection} :: ((...any) -> ())?`)
	end

	if not Shape.IsReliable then
		if IsSingle then
			Target:Compare("BOUND_LISTENER", "nil", "Not"):Lines(Call.Content, Target.Indent):End()
		else
			Listeners.Each(Target, Event, ListenerArguments)
		end

		return
	end

	local Bound: Blocks.Block
	if IsSingle then
		Bound = Target:Compare("BOUND_LISTENER", "nil", "Not"):Lines(Call.Content, Target.Indent)
	else
		Bound = Listeners.Each(Target:Compare(`#{Connection}`, "0", "Greater"), Event, ListenerArguments)
	end

	Queues.Enqueue(Bound:Branch("Default"), State.Context, Shape.Queue, ListenerArguments, Shape.Declaration.Name):End()
end

--> Reads the event out of the packet, and yields the stamp a stream's packet carried.
local function Decoded(Shape: Shape, Block: Blocks.Block): string?
	local Value = Shape.Declaration.Value

	--> Read before the payload, because that is the order it was written in. The DECISION comes
	--> after the payload is decoded, for the same reason the rate limit's does: a variable-length
	--> payload cannot be skipped without reading it.
	if Shape.IsSequenced then
		Types.u16.Read("OrderIdentifier", Block)
	end

	Traffic.Start(Block, Shape.Counters, Shape.IsSequenced)
	Block:Line(`local {Shape.InnerValues} = {Util.GetPath(Shape.Identifier, false, State.Scope)}()`)
	Traffic.Received(Block, Shape.Counters)
	if Value.Stream then
		return Streams.Unwrap(Block, Shape.InnerArguments)
	elseif Value.Stamp then
		Stamps.Unwrap(Block, Shape.InnerArguments, Value.Stamp)
	end

	return nil
end

--> Opens the checks a decoded event has to pass before anything hears it, and yields the block
--> inside them with how many it opened.
-->
--> The decode has to happen either way: payloads are variable length, so skipping an
--> event without reading it would leave the cursor mid-event and turn the rest of the packet
--> into garbage. What the limit saves is the listener and everything behind it.
local function Guarded(Shape: Shape, Block: Blocks.Block, StreamStamp: string?): (Blocks.Block, number)
	local Depth = 0
	local RateGuard = RateGuardExpression(Shape.Declaration.Value, Shape.Declaration.Name)
	if RateGuard then
		Block = Block:Compare(RateGuard, "true", "Equals")
		Depth += 1
	end

	local OrderGuard = if StreamStamp
		then Decode.StreamGuardExpression(Shape.Index, StreamStamp)
		else OrderGuardExpression(Shape.IsSequenced, Shape.Index)
	if OrderGuard then
		Block = Block:Compare(OrderGuard, "true", "Equals")
		Depth += 1
	end

	return Block, Depth
end

--> Predict (upstream issue #59, and the other half of #81).
-->
--> Delivers an event to this side's own listeners without going near a remote, so a test or a
--> story can drive receiving code directly. It mirrors the receive path deliberately, queue
--> included: a Predict that skipped the queue would behave differently from the network
--> whenever no listener is attached yet, which is exactly the case tests hit most.
local function Publish(Shape: Shape, Event: Listeners.Event, IsSingle: boolean, Listener: Blocks.Block)
	local Body, Indent = Shape.Body, Shape.Indent
	if not State.Options.Predict then
		State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
		Body.PushLines(Listener.Content, 0, Indent + 1)
		return
	end

	local PredictArguments = `{State.Context == "Server" and "Player: Player, " or ""}{Shape.Values}`
	local Predict = Blocks.Function(State.Casing.Predict, PredictArguments, "()", true)

	--> A Many event with no listener used to be dropped here while the network queued it, and a
	--> Single one was queued past the cap the network stops at. Both now share the receive path.
	Deliver(Shape, Event, IsSingle, Predict, Shape.Arguments, false)
	Predict:End()

	State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING,`, 0, Indent + 1)
	State.Noop.Push(`{State.Casing.Predict} = NOOP`, 0, Indent + 1)
	Body.PushLines(Listener:Wrap("", ",").Content, 0, Indent + 1)
	Body.PushLines(Predict.Content, 0, Indent + 1)
end

--- An event this side hears through listeners: `On`, and `Predict` where the schema asks for it.
function Receive.Listening(Shape: Shape)
	local Declaration = Shape.Declaration
	local Value = Declaration.Value
	local Connection, Queue, Index = Shape.Connection, Shape.Queue, Shape.Index

	local IsSync = (Value.Call == "SingleSync" or Value.Call == "ManySync")
	local IsSingle = (Value.Call == "SingleSync" or Value.Call == "SingleAsync")

	--> Create queue and event branch
	if not IsSingle then
		State.Events.Push(`{Connection} = \{}`)
	end

	State.Events.Push(`{Queue} = table.create(256)`)
	State.Events.Push(`EventNames.{Shape.ChannelName}[{Index}] = "{Declaration.Name}"`)
	local Block = Decode.Open(Shape.IsUnreliable, Index)

	--> Event recieve body
	local Listener: Blocks.Block
	local ContextArguments = `Listener: ({State.Context == "Server" and "Player: Player, " or ""}{Shape.Values}) -> ()`

	local Event: Listeners.Event = {
		Name = Declaration.Name,
		Context = State.Context,
		Connection = Connection,
		IsSync = IsSync,
		Validating = State.Options.SyncValidation == true,
	}

	local StreamStamp = Decoded(Shape, Block)
	local Inner, Depth = Guarded(Shape, Block, StreamStamp)
	local Disconnect = Disconnector(Shape, IsSingle)

	Deliver(Shape, Event, IsSingle, Inner, Shape.InnerArguments, true)

	local On = BindListener(Shape, IsSingle, Blocks.Function(State.Casing.On, ContextArguments, `() -> ()`, true))
	if Shape.IsReliable then
		Listener = Listeners.Replay(On, Event, Queue):Lines(Disconnect.Content, 1):End()
	else
		Listener = On:Lines(Disconnect.Content, 1):End()
	end

	for _ = 1, Depth do
		Inner = Inner:End()
	end

	Publish(Shape, Event, IsSingle, Listener)
end

--- An event this side hears by polling: `Iter`, and `Next`, its deprecated name.
function Receive.Polling(Shape: Shape)
	local Declaration = Shape.Declaration
	local Value = Declaration.Value
	local Queue, Index = Shape.Queue, Shape.Index
	local Body, Indent = Shape.Body, Shape.Indent

	State.Events.Push(`{Queue} = CreateQueue()`)
	State.Events.Push(`EventNames.{Shape.ChannelName}[{Index}] = "{Declaration.Name}"`)
	local Block = Decode.Open(Shape.IsUnreliable, Index)

	if Shape.IsSequenced then
		Types.u16.Read("OrderIdentifier", Block)
	end

	local PollArguments = `table.pack({State.Context == "Server" and "Player, " or ""}{Util.GetPath(
		Shape.Identifier,
		false,
		State.Scope
	)}())`
	local PollOrderGuard = OrderGuardExpression(Shape.IsSequenced, Index)
	local PollRateGuard = RateGuardExpression(Value, Declaration.Name)

	--> On the server the queue is filled by clients, so it stops at a cap; see MAX_POLLED in the
	--> server template. Every check gates the same enqueue, so they combine into one condition.
	local Checks = {}
	if State.Context == "Server" then
		table.insert(Checks, `{Queue}.count < MAX_POLLED`)
	end

	if PollRateGuard then
		table.insert(Checks, PollRateGuard)
	end

	if PollOrderGuard then
		table.insert(Checks, PollOrderGuard)
	end

	PollRateGuard = if #Checks > 0 then table.concat(Checks, " and ") else nil

	Traffic.Start(Block, Shape.Counters, Shape.IsSequenced)
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
	Traffic.Received(Block, Shape.Counters)

	local IterTypes = `number, {State.Context == "Server" and "Player, " or ""}{Shape.DataTypes}`

	local Next = Blocks.Function("", "", `({IterTypes})`)
		:Line("index += 1")
		:Line("local arguments = Pop(queue)")
		:Compare("arguments", "nil", "Not")
		:Return("index, unpack(arguments :: any, 1, arguments.n)")
		:End()
		:Return(Util.ExhaustedValues(Value.Data :: any, State.Context))
		:End()
		:Wrap("return ", "")

	--> `Next` is the deprecated name of `Iter`, and the two are the same function.
	local function Iterator(Name: string): Blocks.Block
		return Blocks.Function(Name, "", `() -> ({IterTypes})`, true)
			:Line(`local index = 0`)
			:Line(`local queue = {Queue}`)
			:Lines(Next.Content, 1)
			:End()
	end

	local Deprecated = Iterator(State.Casing.Next)
	local Iter = Iterator(State.Casing.Iter):Wrap("", ",")

	State.Noop.Push(`{State.Casing.Iter} = NOOP_RETURNING,`, 0, Indent + 1)
	State.Noop.Push(`{State.Casing.Next} = NOOP_RETURNING`, 0, Indent + 1)

	Body.PushLines(Iter.Content, 0, Indent + 1)
	Body.Push("--- @deprecated v0.14.1 -- Use `Iter` instead.", 0, Indent + 1)
	Body.PushLines(Deprecated.Content, 0, Indent + 1)
end

return Receive
