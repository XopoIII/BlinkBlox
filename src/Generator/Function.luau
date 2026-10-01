--!strict
--!native
--!optimize 2

--- Emits one `function`: the invocation on the side that calls, and the listener and its reply on the
--- side that answers.
---
--- Adds `Function` to the Serde table, which the declaration walk in Generators.luau dispatches through.
local Answer = require("./FunctionAnswer")
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Fragments = require("./Fragments")
local Generators = require("./Generators")
local Lifecycle = require("./Lifecycle")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Serde = require("./Serde")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode
type Call = Answer.Call

local DEFAULT_INVOCATION_TIMEOUT = Fragments.DEFAULT_INVOCATION_TIMEOUT
local Types = Prefabs.Types
local Declarations = Serde

--- A function this side invokes: the branch that reads the reply, and `Invoke` in the yield style the
--- schema asked for.
local function Calling(Call: Call)
	local Name = Call.Declaration.Name
	local Yield = Call.Declaration.Value.Yield
	local Index, Block = Call.Index, Call.Block
	local DataIdentifier, ReturnIdentifier = Call.DataIdentifier, Call.ReturnIdentifier
	local PublicValues, PublicArguments = Call.PublicValues, Call.PublicArguments
	local ReturnTypes, ReturnValues, ReturnArguments = Call.ReturnTypes, Call.ReturnValues, Call.ReturnArguments
	local ReturnCarriesInstances = Call.ReturnCarriesInstances
	local ServerCalls = Call.ServerCalls
	local Body, Indent = Call.Body, Call.Indent

	--> The set of outstanding calls this one is claimed in: the target player's on the server, the
	--> module's own on a client. See Templates/Base.luau for why a call is known by its id AND its
	--> function index.
	local Owner = if ServerCalls then "PlayerInvocations[Player]" else "Invocations"
	local Timeout = State.Options.InvocationTimeout or DEFAULT_INVOCATION_TIMEOUT
	local ClaimSlot = if ServerCalls then `InvokePlayer(Player, {Index})` else `ClaimInvocation(Invocations, {Index})`
	local ReleaseSlot = `ReleaseInvocation({Owner}, InvocationIdentifier)`
	local ParkCaller = `ParkInvocation({Owner}, InvocationIdentifier, coroutine.running())`
	local TakeCaller = `TakeInvocation({Owner}, InvocationIdentifier, {Index})`
	local ArmTimeout = if ServerCalls
		then `TimeoutPlayerInvocation(Player, InvocationIdentifier, {Timeout}, "{Name}")`
		else `TimeoutInvocation(Invocations, InvocationIdentifier, {Timeout}, '"{Name}" was never answered')`

	--> Return recieve body. The flag after the id says whether a payload follows at all: a failure
	--> reply stops there. The payload is only read when it is there, and a read that fails leaves
	--> the cursor inside it -- so after the caller has been told, the failure is raised again, and
	--> the packet stops and is reported like any other that cannot be decoded.
	local Deserialize = Blocks.Function("", "")
		:Compare("Answered", "1", "Not")
		:Line(`error("The call failed on the side that answered it.")`)
		:End()

	--> A reply that lost an Instance fails its caller, and the packet goes on: the payload was read
	--> to its end, so unlike a reply that cannot be decoded it is not raised again below.
	if ReturnCarriesInstances then
		Deserialize:Line(`local {ReturnArguments} = {Util.GetPath(ReturnIdentifier, false, State.Scope)}()`)
			:Compare("MissingInstance", "true", "Equals")
			:Line("MissingInstance = false")
			:Line(`error(\`The reply to "{Name}" was dropped. \{MISSING_INSTANCE}\`, 0)`)
			:End()
			:Return(ReturnArguments)
	else
		Deserialize:Return(`{Util.GetPath(ReturnIdentifier, false, State.Scope)}()`)
	end
	Deserialize = Deserialize:End():Wrap(`local Success, {ReturnArguments} = pcall(`, ")")

	Types.u8.Read("InvocationIdentifier", Block)
	Types.u8.Read("Answered", Block)
	Block:Lines(Deserialize.Content, Block.Indent + 1)
	--> Taking the caller settles the call -- its id goes back, its timer is cancelled -- before the
	--> thread is resumed, so a caller that immediately invokes again from inside its own
	--> continuation gets an id rather than an exhaustion error. It yields nothing when the id is
	--> not outstanding for THIS function. A server looks the reply up in the REPLYING PLAYER's own
	--> set, so an id belonging to a call made to somebody else simply is not there.
	-->
	--> The status check is not paranoia: a Future that already completed leaves a thread that is
	--> dead or running. `task.spawn` on either of those throws from inside the remote handler,
	--> where no user pcall can reach it.
	Block:Line(`local Thread = {TakeCaller}`)
		:Compare("Thread", "nil", "Not")
		:Compare("coroutine.status(Thread)", `"suspended"`, "Equals")
		:Line(`task.spawn(Thread, Success, {ReturnArguments})`)
		:End()
		:End()

	local Failure = string.split(ReturnArguments, ",")[1]
	if ReturnCarriesInstances then
		Block:Line(
			`if Answered == 1 and Success ~= true and not string.find(tostring({Failure}), MISSING_INSTANCE, 1, true) then error({Failure}, 0) end`
		)
	else
		Block:Line(`if Answered == 1 and Success ~= true then error({Failure}, 0) end`)
	end

	local Error = `"There was an exception while processing \\"{Name}\\"."`
	--> A server invoking has to say WHICH client it is asking.
	local InvokeValues = `{if ServerCalls then "Player: Player, " else ""}{PublicValues}`
	--> Claiming a slot and writing the call. Again the server has to select the target player's
	--> buffer around the write. Shared by every yield style: a Promise does it inside its executor.
	local function SendCall(Target: Blocks.Block): Blocks.Block
		Target:Line(`local InvocationIdentifier = {ClaimSlot}`)
		if ServerCalls then
			Target:Line("LoadPlayer(Player)")
		end

		--> Releasing the slot when the ARGUMENTS fail to serialise.
		-->
		--> The slot is claimed before the write and the caller is parked after it, so a throw in
		--> between used to strand the slot with nothing outstanding: no parked caller, so
		--> nothing for the timeout to find and reclaim. Thirty-two rejected calls -- the same wrong
		--> argument thirty-two times -- and every later invocation fails for the lifetime of the
		--> session. This is the one leak the timeout cannot cover, because it is armed after it.
		Target:Line("local Cursor, Instances = Mark()")
		Target:Line(
			`local Sent: boolean, Failure: any = pcall({Util.GetPath(DataIdentifier, true, State.Scope)}, {PublicArguments}, InvocationIdentifier)`
		)
		Target:Compare("Sent", "true", "Not")
			:Line("Rollback(Cursor, Instances)")
			:Line(ReleaseSlot)
			:Line("error(Failure, 0)")
			:End()

		if ServerCalls then
			Target:Line("SavePlayerBuffer(Player)")
		else
			Target:Line("Close(Cursor, Instances)")
		end

		return Target
	end

	local Contents = SendCall(Blocks.Block())
		:Line(ParkCaller)
		:Line(ArmTimeout)
		:Line(`local Success, {ReturnValues} = coroutine.yield()`)
		:Compare("Success", "true", "Not")
		:Line(`error({Error})`)
		:End()
		:Return(ReturnArguments).Content

	local Invoke
	if Yield == "Future" then
		State.UsesFuture = true
		local Wrapper = Blocks.Function("", ""):Lines(Contents):End():Wrap("return Future.Try(", ")")

		Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, `Future.Future<boolean, {ReturnTypes}>`, true)
		Invoke:Lines(Wrapper.Content, 1)
	elseif Yield == "Promise" then
		State.UsesPromise = true

		--> A cancelled promise gives its slot back too, otherwise cancelling enough calls would
		--> exhaust the bitset with nothing outstanding.
		local OnCancel = Blocks.Function("", ""):Line(ReleaseSlot):End():Wrap("OnCancel(", ")")

		local Promise = SendCall(Blocks.Function("", "Resolve, Reject, OnCancel"))
			:Line(ParkCaller)
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

		Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, nil, true)
		Invoke:Lines(Promise.Content, 1)
	else
		Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, `({ReturnTypes})`, true)
		Invoke:Lines(Contents, 0)
	end

	Invoke:End()
	State.Noop.Push(`{State.Casing.Invoke} = {Lifecycle.InvokeStub(State.Context, State.Options)}`, 0, Indent + 1)
	Body.PushLines(Invoke.Content, 0, Indent + 1)
end

function Declarations.Function(Declaration: Parser.Function)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local DataIdentifier = `FUNCTION_DATA_{Name}`
	local ReturnIdentifier = `FUNCTION_RETURN_{Name}`

	local Yield = Value.Yield
	local IsFuture = (Yield == "Future")
	local IsPromise = (Yield == "Promise")

	if IsFuture and (State.Options.FutureLibrary or "") == "" then
		error(`Cannot use yield type: "Future", without providing a path to the future library.`)
	end

	if IsPromise and (State.Options.PromiseLibrary or "") == "" then
		error(`Cannot use yield type: "Promise", without providing a path to the promise library.`)
	end

	local Channel = State.Channels.Reliable

	local Index = Channel.Count
	local Queue = `Queue.Reliable[{Index}]`
	local Connection = `Events.Reliable[{Index}]`

	--> WHICH SIDE IS WHICH. `From` names the side that INVOKES; the other side listens. Until this
	--> existed the answer was always "the client invokes", and the fork below was written as
	--> `Context == "Server"` -- true only because that meant the same thing.
	local IsCaller = (Value.From == State.Context)
	local OnServer = (State.Context == "Server")

	--> A server calling a client needs per-player invocation state, because the id is a u8 the client
	--> sends back and one shared id space would let a client answer a call made to somebody else. See
	--> Templates/Server.luau.
	local ServerCalls = OnServer and IsCaller
	--> Data and return body
	--> Positional names everywhere but the parameters of `Invoke`, the one place the game sees them;
	--> see `Generators.LuauType`. A pack element named `Success` or `InvocationIdentifier` used to
	--> shadow the generated code's own local of that name.
	local DataTypes, DataValues, _, DataArguments = "nil", "Value: nil", nil, "Value"
	local PublicValues, PublicArguments = DataValues, DataArguments
	local ReturnTypes, ReturnValues, _, ReturnArguments = "nil", "ReturnValue: nil", nil, "ReturnValue"

	if Value.Data then
		_, PublicValues, _, PublicArguments = Generators.LuauType(Value.Data :: Type, true)
		DataTypes, DataValues, _, DataArguments = Generators.LuauType(Value.Data :: Type, true, nil, true)
	end

	if Value.Return then
		ReturnTypes, ReturnValues, _, ReturnArguments = Generators.LuauType(Value.Return :: Type, true, "Return", true)
	end

	local DataCarriesInstances, ReturnCarriesInstances = false, false
	do
		local MissingBefore = Prefabs.Missing.Count
		local DataRead, DataWrite = Generators.Event(Value.Data :: Type, Index, DataIdentifier, "Data")
		local MissingBetween = Prefabs.Missing.Count
		local ReturnRead, ReturnWrite = Generators.Event(Value.Return :: Type, Index, ReturnIdentifier, "Return")
		--> Whether either reader can arrive at a missing Instance; see Decode.MissingGuard.
		DataCarriesInstances = MissingBetween > MissingBefore
		ReturnCarriesInstances = Prefabs.Missing.Count > MissingBetween

		--> By DIRECTION, not by context. The caller writes the arguments and reads the answer; the
		--> listener reads the arguments and writes the answer. Keying this on `Context == "Client"`
		--> was correct only while the client was always the caller.
		if IsCaller then
			State.UserTypes.PushLines(DataWrite, 1, 0)
			State.UserTypes.PushLines(ReturnRead, 1, 0)
		else
			State.UserTypes.PushLines(DataRead, 1, 0)
			State.UserTypes.PushLines(ReturnWrite, 1, 0)
		end
	end

	--> Main
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)

	State.Noop.Push(`{Name} = \{`, 0, Indent)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> Create queue and event branch
	State.Events.Push(`{Queue} = table.create(256)`)
	State.Events.Push(`EventNames.Reliable[{Index}] = "{Name}"`)

	local Call: Call = {
		Declaration = Declaration,
		Index = Index,
		Queue = Queue,
		Connection = Connection,
		DataIdentifier = DataIdentifier,
		ReturnIdentifier = ReturnIdentifier,
		ServerCalls = ServerCalls,
		DataTypes = DataTypes,
		DataValues = DataValues,
		DataArguments = DataArguments,
		PublicValues = PublicValues,
		PublicArguments = PublicArguments,
		ReturnTypes = ReturnTypes,
		ReturnValues = ReturnValues,
		ReturnArguments = ReturnArguments,
		DataCarriesInstances = DataCarriesInstances,
		ReturnCarriesInstances = ReturnCarriesInstances,
		Block = Decode.Open(false, Index),
		Body = Body,
		Indent = Indent,
	}

	if IsCaller then
		Calling(Call)
	else
		Answer.Listening(Call)
	end

	Channel.Count += 1

	State.Noop.Push(`\},`, 0, Indent)
	Body.Push(`\},`, 0, Indent)
	State.Return.PushLines(Body.DumpLines(), 0)
end

return Declarations
