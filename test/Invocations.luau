--!strict
--- Specs for invocations: the one nobody answers, and the one that goes the other way.
---
--- There was no timeout at all until now, and the failure it left behind was quiet: the caller hung
--- forever and its slot in the invocation bitset stayed claimed, so after thirty-two of them `Invoke`
--- refused every further call for the lifetime of the session. Nothing reported either half.
---
--- This was survivable while the callee was always the SERVER, because the server always answers --
--- every refusal path writes a three-byte failure reply for exactly that reason. It stops being
--- survivable the moment a client can be the callee, since a client that never replies is ordinary:
--- it left, it crashed, it was exploited.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

--> Test.blink sets `option InvocationTimeout = 3`, and nothing anywhere listens to NeverAnswered.
local TIMEOUT = 3

--> Runs a call on its own thread and waits out its answer, so a spec never blocks the suite on the
--> thing it is testing for hanging.
local function Await(Call: () -> any, Seconds: number): (boolean, any)
	local Finished, Ok, Result = false, nil, nil
	task.spawn(function()
		Ok, Result = pcall(Call)
		Finished = true
	end)

	local Waited = 0
	while not Finished and Waited < Seconds do
		Waited += task.wait(0.05)
	end

	if not Finished then
		return false, `still suspended after {Waited} seconds`
	end

	return Ok :: any, Result
end

do
	local Name = "An invocation nobody answers fails its caller instead of hanging"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	Shared.DrainWarnings()

	local Ok, Result = Await(function()
		return Client.NeverAnswered.Invoke(1)
	end, TIMEOUT + 2)

	if Ok ~= false then
		ErrorPrint(`Failed "{Name}": expected the call to fail, got {tostring(Result)}.`)
		return {}
	end

	local Warned = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "never answered", 1, true) then
			Warned = true
			break
		end
	end

	if not Warned then
		ErrorPrint(`Failed "{Name}": it failed the caller without saying why.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> The half that actually bites: the slot has to come back. Without it the bitset leaks a bit per
	--> lost call and the thirty-third is refused outright.
	local Name = "A timed-out invocation returns its slot"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	--> More calls than the bitset holds (32), spaced so earlier ones time out while later ones are
	--> still being made. One per 0.15s against a 3s timeout leaves twenty outstanding at any moment:
	--> comfortably inside the bitset IF slots come back, and past it at the thirty-third if they do
	--> not. Exhaustion surfaces as an ERROR out of Invoke, not a warning, so that is what this reads.
	local Exhausted: string?
	for _ = 1, 40 do
		task.spawn(function()
			local _, Thrown = pcall(function()
				return Client.NeverAnswered.Invoke(1)
			end)

			if Thrown and string.find(tostring(Thrown), "already awaiting", 1, true) then
				Exhausted = tostring(Thrown)
			end
		end)

		task.wait(0.15)
	end

	if Exhausted then
		ErrorPrint(`Failed "{Name}": the invocation slots ran out, so they are not being returned: {Exhausted}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> The other direction, which is devforum #154. The server names the client it is asking; the
	--> client's listener takes no Player, because the caller is the server.
	local Name = "A function the server invokes reaches the client and comes back"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Seen: number?
	Client.AskClient.On(function(Value: number): number
		Seen = Value
		return Value * 2
	end)

	local Ok, Result = Await(function()
		return Server.AskClient.Invoke(Shared.Player, 21)
	end, 3)

	if Ok ~= true then
		ErrorPrint(`Failed "{Name}": the call did not come back: {tostring(Result)}`)
		return {}
	end

	if Seen ~= 21 then
		ErrorPrint(`Failed "{Name}": the client listener saw {tostring(Seen)}, expected 21.`)
		return {}
	end

	if Result ~= 42 then
		ErrorPrint(`Failed "{Name}": the server got {tostring(Result)} back, expected 42.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> A failure reply is three bytes -- index, id, a zero flag -- where a success carries its payload
	--> after the flag. The reader used to take the flag inside the payload's block, so on a failure it
	--> had already stepped the payload's size forward before it learnt there was none, and its error
	--> was swallowed by the pcall around the read. The decode loop carried on from inside the NEXT
	--> event, and whatever the server had batched behind a refusal was lost or misread.
	local Name = "A failure reply leaves the events batched after it intact"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Reliable = require("./Client").Instances.BLINK_RELIABLE_REMOTE

	--> Real bytes for both halves: a failure reply from a listener that returns the wrong type, and
	--> an ordinary event. Captured on the way to the client rather than written by hand.
	Server.BadlyAnswered.On(function(_Player, _Value: number): number
		return "not a number" :: any
	end)

	local Packets: { buffer } = {}
	local Spy = Reliable.OnClientEvent:Connect(function(Buffer: buffer)
		table.insert(Packets, Buffer)
	end)

	Await(function()
		return Client.BadlyAnswered.Invoke(1)
	end, 1.5)
	local Reply = Packets[#Packets]

	Server.ReliableServer.FireAll(1)
	task.wait(1 / 30)
	local Event = Packets[#Packets]
	Spy:Disconnect()
	Shared.DrainWarnings()

	if not Reply or buffer.len(Reply) ~= 3 or not Event or buffer.len(Event) ~= 2 then
		ErrorPrint(`Failed "{Name}": could not capture a failure reply and an event to combine.`)
		return {}
	end

	--> [failure reply][ReliableServer 77], as one flush would carry them.
	local Combined = buffer.create(5)
	buffer.copy(Combined, 0, Reply, 0, 3)
	buffer.writeu8(Combined, 3, buffer.readu8(Event, 0))
	buffer.writeu8(Combined, 4, 77)

	local Seen: number?
	local Disconnect = Client.ReliableServer.On(function(Value: number)
		Seen = Value
	end)

	Reliable.OnClientEvent:Fire(Combined, {})
	task.wait(1 / 30)
	Disconnect()

	if Seen ~= 77 then
		ErrorPrint(`Failed "{Name}": the event after the failure reply arrived as {tostring(Seen)}, expected 77.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> Ids used to be handed out lowest free first, so the id a reply had just released was the next
	--> one claimed, and a sequential caller claimed it from the same thread. Its timer identified the
	--> call by exactly that pair, so call 1's timer, firing at call 1's deadline, failed call 2 -- a
	--> call still well inside its own timeout, with the other side busy answering it.
	local Name = "A call's timer cannot fail a later call from the same thread"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	Server.RemoteFunction.On(function(_Player, Value: number): number
		if Value == 2 then
			task.wait(TIMEOUT - 0.5)
		end

		return Value
	end)

	Shared.DrainWarnings()

	--> Call 1 is answered at once; call 2 starts a second later and is answered at TIMEOUT + 0.5,
	--> half a second after call 1's timer comes due.
	local Ok, Result = Await(function()
		Client.RemoteFunction.Invoke(1)
		task.wait(1)
		return Client.RemoteFunction.Invoke(2)
	end, TIMEOUT + 2)

	if Ok ~= true or Result ~= 2 then
		ErrorPrint(`Failed "{Name}": the second call ended with {tostring(Result)}, expected its answer, 2.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

--> Reads the id out of the next call a client sends: the packet is [function index][id][argument].
--> It reaches the server only when `Deliver` says so; otherwise the call stays outstanding.
local function CaptureCall(Call: () -> (), Deliver: boolean?): (number?, number?)
	local Remote = require("./Client").Instances.BLINK_RELIABLE_REMOTE
	local Original = Remote.FireServer
	local Sent: buffer?
	Remote.FireServer = function(self, Buffer: buffer, ...)
		Sent = Buffer
		if Deliver then
			Original(self, Buffer, ...)
		end
	end

	task.spawn(Call)
	task.wait(1 / 30)
	Remote.FireServer = Original

	if not Sent or buffer.len(Sent) < 2 then
		return nil, nil
	end

	return buffer.readu8(Sent, 0), buffer.readu8(Sent, 1)
end

--> Hands the client a reply as if the server had sent it: [function index][id][1][u8 value].
local function Reply(Index: number, Identifier: number, Value: number)
	local Packet = buffer.create(4)
	buffer.writeu8(Packet, 0, Index)
	buffer.writeu8(Packet, 1, Identifier)
	buffer.writeu8(Packet, 2, 1)
	buffer.writeu8(Packet, 3, Value)
	require("./Client").Instances.BLINK_RELIABLE_REMOTE.OnClientEvent:Fire(Packet, {})
end

do
	--> Two ways a reply used to reach a caller it was not for. Every function shares one set of ids,
	--> and the reply branch checked only that the id was outstanding -- not that it was outstanding
	--> for the function the reply belongs to, so a caller typed one way could be resumed with
	--> another function's values. And a reply arriving after its call had timed out found the same id
	--> already handed to the next call, since the lowest free one went first.
	local Name = "A reply resumes only the call it answers"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	--> An index belonging to a function other than NeverAnswered, taken from a real call to it, which
	--> is answered and so leaves nothing outstanding: the second half depends on which ids are free.
	local OtherIndex = CaptureCall(function()
		pcall(Client.RemoteFunction.Invoke, 1)
	end, true)
	task.wait(0.2)

	local First: { Ok: boolean?, Result: any } = {}
	local Index, FirstIdentifier = CaptureCall(function()
		First.Ok, First.Result = pcall(Client.NeverAnswered.Invoke, 1)
	end)

	if not OtherIndex or not Index or not FirstIdentifier then
		ErrorPrint(`Failed "{Name}": could not capture the calls to answer.`)
		return {}
	end

	--> Another function's reply, carrying the pending call's id.
	Reply(OtherIndex, FirstIdentifier, 5)
	task.wait(1 / 30)
	if First.Ok ~= nil then
		ErrorPrint(`Failed "{Name}": another function's reply resumed the call, with {tostring(First.Result)}.`)
		return {}
	end

	--> Let the first call time out, then make a second and answer the FIRST one late.
	task.wait(TIMEOUT + 0.2)
	local Second: { Ok: boolean?, Result: any } = {}
	CaptureCall(function()
		Second.Ok, Second.Result = pcall(Client.NeverAnswered.Invoke, 1)
	end)

	Reply(Index, FirstIdentifier, 9)
	task.wait(1 / 30)
	Shared.DrainWarnings()

	if Second.Ok ~= nil then
		ErrorPrint(
			`Failed "{Name}": a late reply to the first call resumed the second, with {tostring(Second.Result)}.`
		)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

return {}
