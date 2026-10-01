--!strict
--!native
--!optimize 2

--- The answering side of one `function`: the branch that decodes a call, and the `On` whose listener
--- is run for it and whose reply is written back. Function.luau works out what both sides share --
--- the `Call` -- and comes here on the side that does not invoke.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Queues = require("./Queue")
local State = require("./State")
local Util = require("./Util")

local Types = Prefabs.Types
local RateGuardExpression = Decode.RateGuardExpression

local Answer = {}

--- What one function is, whichever side is being generated.
export type Call = {
	Declaration: Parser.Function,
	Index: number,
	Queue: string,
	Connection: string,
	DataIdentifier: string,
	ReturnIdentifier: string,
	--> A server calling a client needs per-player invocation state, because the id is a u8 the client
	--> sends back and one shared id space would let a client answer a call made to somebody else. See
	--> Templates/Server.luau.
	ServerCalls: boolean,
	--> Positional names everywhere but the parameters of `Invoke`, the one place the game sees them --
	--> those are the `Public` pair; see `Generators.LuauType`. A pack element named `Success` or
	--> `InvocationIdentifier` used to shadow the generated code's own local of that name.
	DataTypes: string,
	DataValues: string,
	DataArguments: string,
	PublicValues: string,
	PublicArguments: string,
	ReturnTypes: string,
	ReturnValues: string,
	ReturnArguments: string,
	--> Whether either reader can arrive at a missing Instance; see Decode.MissingGuard.
	DataCarriesInstances: boolean,
	ReturnCarriesInstances: boolean,
	Block: Blocks.Block,
	Body: Builder.Builder,
	Indent: number,
}

--> Decodes a call and hands it to the listener, or queues it for the one to come. Yields the line
--> that releases the call's concurrency slot, where it holds one.
local function Receiving(Call: Call): string?
	local Name = Call.Declaration.Name
	local Value = Call.Declaration.Value
	local Index, Queue, Connection = Call.Index, Call.Queue, Call.Connection
	local Block = Call.Block
	local DataIdentifier, DataValues, DataArguments = Call.DataIdentifier, Call.DataValues, Call.DataArguments
	local OnServer = (State.Context == "Server")

	--> Data recieve body
	Types.u8.Read("InvocationIdentifier", Block)
	Block:Line(`local {DataValues} = {Util.GetPath(DataIdentifier, false, State.Scope)}()`)

	--> A call whose arguments lost an Instance on the way is answered with a failure, before any
	--> limit counts it: nothing will run for it.
	if Call.DataCarriesInstances then
		Decode.MissingGuard(Block, false, Name, function(Target: Blocks.Block)
			if OnServer then
				Queues.Refuse(Target, Index, Target.Indent + 1)
			else
				Queues.RefuseClient(Target, Index, Target.Indent + 1)
			end
		end)
	end

	--> A refused invocation still has to be ANSWERED; see Queue.Refuse.
	local RateGuard = RateGuardExpression(Value, Name)
	if RateGuard then
		Queues.Refuse(Block:Line(`if not {RateGuard} then`), Index, Block.Indent + 1):Line("end")
	end

	--> After the rate limit, so a refused call is not counted as running; before dispatch, so a
	--> call waiting in the queue is. Released below wherever the call is answered. The client has
	--> no such check: the server it listens to is trusted.
	local Limit = if OnServer then Value.Concurrency else nil
	local Release = if Limit then `ConcurrencyRelease(Player, {Index})` else nil
	if Limit then
		local Guard = `if not ConcurrencyAccept(Player, {Index}, {Limit}, "{Name}") then`
		Queues.Refuse(Block:Line(Guard), Index, Block.Indent + 1):Line("end")
	end

	--> The listening side passes a Player only when it IS the server. A client listening to a
	--> function the server invokes has no player to name: the caller is the server.
	local Caller = if OnServer then "Player, " else ""
	local Queued = Block:Compare(Connection, "nil", "Not")
		:Line(`Spawn({Connection}, {Caller}{DataArguments}, InvocationIdentifier)`)
		:Branch("Default")
	Queues.Enqueue(Queued, State.Context, Queue, `{Caller}{DataArguments}, InvocationIdentifier`, Name, Index, Release)
		:End()

	return Release
end

--- A function this side answers: `On`, and the reply its listener's return is written into.
function Answer.Listening(Call: Call)
	local Name = Call.Declaration.Name
	local Index, Queue, Connection = Call.Index, Call.Queue, Call.Connection
	local DataTypes, DataValues, DataArguments = Call.DataTypes, Call.DataValues, Call.DataArguments
	local ReturnTypes, ReturnValues, ReturnArguments = Call.ReturnTypes, Call.ReturnValues, Call.ReturnArguments
	local ReturnIdentifier = Call.ReturnIdentifier
	local Body, Indent = Call.Body, Call.Indent
	local OnServer = (State.Context == "Server")

	local Release = Receiving(Call)

	--> Data listener body
	local FlushQueue = Blocks.Function("", "", "()")
		:Line(`local EventQueue = {Queue} or \{\}`)
		:Line(`{Queue} = nil`)
		:Iterator("Index", "Arguments", "EventQueue")
		:Line(`{Connection}(table.unpack(Arguments, 1, Arguments.n))`)
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
		TrueListener:Line("LoadPlayer(Player)")
	else
		--> The failure reply below writes without Mark, and has to land after a Fire that threw
		--> has been undone rather than behind it.
		TrueListener:Line("Settle()")
		TrueListener:Line("local ReplyStart, ReplyInstances = SendCursor, #SendInstances")
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
			`Success, Error = pcall({Util.GetPath(ReturnIdentifier, true, State.Scope)}, {ReturnArguments}, InvocationIdentifier)`
		)
		:Compare("Success", "true", "Not")
		:Line("Rollback(Cursor, Instances)")
		:End()
		:End()

	TrueListener
		:Compare("Success", "true", "Not")
		:Line("local Position = Allocate(3)")
		:Line(`buffer.writeu8(SendBuffer, Position, {Index})`)
		:Line(`buffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)`)
		:Line(`buffer.writeu8(SendBuffer, Position + 2, 0)`)
		--> On the server the error is the game's to hear through SetListenerErrorHandler, a throwing
		--> return serialiser included; the warning is what it gets without one, as before.
		:Line(
			if OnServer
				then `if not ListenerFailed(Player, "{Name}", Error) then warn(\`"{Name}" encountered an error, \{Error\}\`) end`
				else `warn(\`"{Name}" encountered an error, \{Error\}\`)`
		)
		:End()

	--> The reply is written, success or failure: the call is no longer running.
	if Release then
		TrueListener:Line(Release)
	end

	if OnServer then
		TrueListener:Line("SavePlayerBuffer(Player)")
	else
		TrueListener:Line("Close(ReplyStart, ReplyInstances)")
	end

	TrueListener:End()

	local ListenerSignature = `Listener: ({if OnServer then "Player, " else ""}{DataTypes}) -> ({ReturnTypes})`
	--> A function answers with one listener, and a second `.On` replaces the first. That is how it
	--> works and stays, but it happened in silence, which an event's Single listener stopped doing
	--> (upstream #167): two systems that each think they answer a call leave only the last one doing it.
	local Listener = Blocks.Function(State.Casing.On, ListenerSignature, "()", true)
		:Line(`if {Connection} ~= nil then`)
		:Line(`\twarn("[BlinkBlox]: \\"{Name}\\" already has a listener. A function keeps only the newest one.")`)
		:Line("end")
		:Lines(TrueListener.Content, 1)
		:Lines(FlushQueue.Content, 1)
		:End()

	State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
	Body.PushLines(Listener.Content, 0, 2)
end

return Answer
