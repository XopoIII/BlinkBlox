--!strict
--!native
--!optimize 2

--- Emits one `event`: its serialisers, the branch that receives it, and the API the game calls --
--- `On`, `Iter` or `Fire` and its variants, depending on which side this is and which side sends.
---
--- Adds `Event` to the Serde table, which the declaration walk in Generators.luau dispatches through.
local Batches = require("./Batches")
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Generators = require("./Generators")
local Outbound = require("./Outbound")
local Parser = require("../Parser")
local Receive = require("./EventReceive")
local Send = require("./Send")
local Serde = require("./Serde")
local Stamps = require("./Stamp")
local State = require("./State")
local Streams = require("./Stream")
local Traffic = require("./Traffic")
local Util = require("./Util")
local Writes = require("./Writes")

type Type = Parser.TypeNode
type Shape = Receive.Shape

local Declarations = Serde

--> The client's `Fire`.
local function ClientFire(Shape: Shape, Writer: Writes.Write, FireValues: string, TryWriteEvent: string)
	local Name = Shape.Declaration.Name
	local Counters = Shape.Counters
	local Indent = Shape.Indent

	local Fire = Blocks.Function(State.Casing.Fire, FireValues, "()", true)
	if Shape.IsReliable then
		--> Rolled back rather than left, because this write lands in the batch every other event
		--> is queued in. Half an event in there is not one bad send: the receiver reads the
		--> truncated event and then decodes the REST of the batch from the wrong offset.
		Writer.Begun(Fire)
		Traffic.Sent(Fire, Counters, "SendCursor - Cursor", false)
	else
		Fire:Line("Hold()")
		Fire:Line(`local Sent: boolean, Failure: any = {TryWriteEvent}`)
		--> Wrapped rather than returned out of: the saved buffer has to be restored either way,
		--> and an early return here would leave the caller's outgoing state swapped out.
		-->
		--> Which is exactly why the write is protected. A throw used to skip restoring the batch
		--> entirely, leaving this temporary buffer installed as the outgoing one -- so the next
		--> RELIABLE flush sent the scratch buffer and dropped everything already batched.
		Fire:Line(`if Sent and CheckUnreliableSize("{Name}") then`)
		if Batches.Events() then
			--> Gathered with the frame's other unreliable events; see Batches.luau.
			State.UsesBatches = true
			Fire:Line("\tAppendUnreliable()")
		else
			Fire:Line("\tlocal Buffer = buffer.create(SendCursor)")
			Fire:Line("\tbuffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)")
			Fire:Line("\tUnreliable:FireServer(Buffer, SendInstances)")
		end
		Traffic.Sent(Fire, Counters, "SendCursor", true, nil, "\t")
		Fire:Line("end")
		Fire:Line("Release()")
		Fire:Compare("Sent", "true", "Not"):Line("error(Failure, 0)"):End()
	end
	Fire:End()

	State.Noop.Push(`{State.Casing.Fire} = NOOP`, 0, Indent + 1)
	Shape.Body.PushLines(Fire.Content, 0, Indent + 1)
end

--> The server's `Fire` and its variants, to one player and to many.
local function ServerFire(Shape: Shape, Writer: Writes.Write, WriteEvent: string)
	local Value = Shape.Declaration.Value
	local Values = Shape.Values
	local Counters = Shape.Counters
	local Body, Indent = Shape.Body, Shape.Indent

	local Outgoing: Send.Send = {
		IsReliable = Shape.IsReliable,
		WriteEvent = WriteEvent,
		Name = Shape.Declaration.Name,
		Ordered = if Shape.IsSequenced then Shape.Index else nil,
		Instances = Writes.CarriesInstances(Value.Data),
		Traffic = Counters,
		Low = Outbound.Low(Value.Priority),
	}
	local Fire = Blocks.Function(State.Casing.Fire, `Player: Player, {Values}`, "()", true)
	if Shape.IsReliable then
		Fire:Line("LoadPlayer(Player)")
		Writer.Player(Fire)
		Traffic.Sent(Fire, Counters, "SendCursor - Cursor", false)
		Fire:Line("SavePlayerBuffer(Player)")
	else
		Send.One(Fire, Outgoing)
	end
	Fire:End()

	local FireAll = Send.Broadcast(
		Blocks.Function(State.Casing.FireAll, Values, "()", true),
		Outgoing,
		"Players:GetPlayers()",
		{ AllClients = true }
	)
	local FireList = Send.Broadcast(
		Blocks.Function(State.Casing.FireList, `List: \{Player\}, {Values}`, "()", true),
		Outgoing,
		"List",
		{}
	)
	local FireExcept = Send.Broadcast(
		Blocks.Function(State.Casing.FireExcept, `Except: Player, {Values}`, "()", true),
		Outgoing,
		"Players:GetPlayers()",
		{ SkipExcept = true }
	)

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

--> The two spellings of the payload a Shape carries, after its Luau types.
local function Spellings(Data: Type?): (string, string, string, string, string)
	if not Data then
		return "nil", "Value: nil", "Value", "Value: nil", "Value"
	end

	local DataTypes, Values, _, Arguments = Generators.LuauType(Data, true)
	local _, InnerValues, _, InnerArguments = Generators.LuauType(Data, true, nil, true)
	return DataTypes, Values, Arguments, InnerValues, InnerArguments
end

--> The side that sends: the client has one `Fire`, the server a family of them, and a stream neither.
local function Sending(Shape: Shape)
	local Declaration = Shape.Declaration
	local Value = Declaration.Value

	--> A stamped event's Fire takes the declared values, and the module writes the stamp after them.
	local FireValues, WriteArguments = Shape.Values, Shape.Arguments
	if Value.Stamp then
		FireValues, WriteArguments = Stamps.Outgoing(Value.Stamp)
	end

	local WriteEvent = `{Util.GetPath(Shape.Identifier, true, State.Scope)}({WriteArguments})`
	--> The same call, protected: an unreliable Fire writes into the scratch buffer under it, so the
	--> batch is put back whatever happens. How a Fire writes into a batch that outlives it is
	--> Writes.luau's.
	local TryWriteEvent = `pcall({Util.GetPath(Shape.Identifier, true, State.Scope)}, {WriteArguments})`
	local Writer = Writes.new(Shape.Identifier, WriteArguments, WriteEvent, Value.Data, Shape.Counters)

	if State.Context == "Client" then
		ClientFire(Shape, Writer, FireValues, TryWriteEvent)
	elseif Value.Stream then
		--> Sent by the scheduler rather than by the game, so the server has Set and its friends in
		--> place of the Fire family. See Stream.luau.
		Streams.Server(Declaration, Shape.Index, Shape.Values, WriteEvent, Shape.Body, Shape.Indent, Shape.Counters)
	else
		ServerFire(Shape, Writer, WriteEvent)
	end
end

function Declarations.Event(Declaration: Parser.Event)
	local Value = Declaration.Value

	local Identifier = `EVENT_{Declaration.Name}`
	local Reliability = Value.Type

	local IsReliable = (Reliability == "Reliable")
	--> Ordered events travel the unreliable channel; the ordering is a sequence number on top of it.
	local IsOrdered = (Reliability == "OrderedUnreliable")
	local IsUnreliable = (Reliability == "Unreliable" or IsOrdered)
	--> Whether a sequence number travels with the event. A stream is OrderedUnreliable too, but it is
	--> ordered by the server time its every packet already carries; see StreamAccept.
	local IsSequenced = IsOrdered and not Value.Stream

	if IsSequenced then
		State.UsesOrdering = true
	end
	--> A stream or a stamped event always has a listener: it hands the game the stamp unwrapped, which
	--> a poll would not.
	local IsPolling = not Value.Stream and not Value.Stamp and (Value.Call == "Polling" or State.Options.UsePolling)
	local IsSameContext = Value.From == State.Context

	local Channel = IsUnreliable and State.Channels.Unreliable or State.Channels.Reliable
	local Counters = Traffic.Register(Declaration.Name, Value.Data, IsSequenced)

	local Index = Channel.Count
	local ChannelName = if IsUnreliable then "Unreliable" else "Reliable"

	--> Data body
	local Read, Write = Generators.Event(Value.Data, Index, Identifier, nil, IsSequenced)
	local DataTypes, Values, Arguments, InnerValues, InnerArguments = Spellings(Value.Data)

	if IsSameContext then
		State.UserTypes.PushLines(Write, 1, 0)
	else
		State.UserTypes.PushLines(Read, 1, 0)
	end

	--> Return body
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)
	local Shape: Shape = {
		Declaration = Declaration,
		Identifier = Identifier,
		Index = Index,
		ChannelName = ChannelName,
		Queue = `Queue.{ChannelName}[{Index}]`,
		Connection = `Events.{ChannelName}[{Index}]`,
		IsReliable = IsReliable,
		IsUnreliable = IsUnreliable,
		IsSequenced = IsSequenced,
		Counters = Counters,
		DataTypes = DataTypes,
		Values = Values,
		Arguments = Arguments,
		InnerValues = InnerValues,
		InnerArguments = InnerArguments,
		Body = Body,
		Indent = Indent,
	}

	Body.Push(`{Declaration.Name} = \{`, 0, Indent)
	State.Noop.Push(`{Declaration.Name} = \{`, 0, Indent)

	if IsSameContext then
		Sending(Shape)
	elseif IsPolling then
		Receive.Polling(Shape)
	else
		Receive.Listening(Shape)
	end

	Channel.Count += 1

	Body.Push(`\},`, 0, Indent)
	State.Noop.Push(`\},`, 0, Indent)
	State.Return.PushLines(Body.DumpLines(), 0)
end

return Declarations
