--!strict
--- Specs for what a REJECTED write leaves behind.
---
--- Every serialiser allocates its bytes up front and writes the event id before it validates a
--- single field, so an assert fires with the id already in the batch and the cursor already past
--- the payload. Nothing used to undo that. The consequences were three, and none of them looked
--- like the mistake that caused them:
---
--- a reliable fire left a phantom event behind, delivered to the listener as an ordinary value
--- nobody sent; an unreliable fire never reached its `Load(Previous)`, so the scratch buffer stayed
--- installed as the outgoing one and the next flush shipped it INSTEAD of everything already
--- batched; and an invocation had already claimed its slot, which it then never gave back, because
--- the caller is parked -- and the timeout armed -- only after the write it did not survive.
---
--- The last one is the one that compounds. Thirty-two rejected calls and every later invocation on
--- that module fails for the lifetime of the session, and the timeout cannot reclaim a slot it was
--- never told about.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local Client = Modules.Client
local Server = Modules.Server

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

--> Every fire below happens without yielding in between, so all of them share one batch and one
--> flush. That is the whole point: the corruption is only observable between events.
local FLUSH = 1 / 30

local function Describe(Values: { number }): string
	local Parts = table.create(#Values)
	for Index, Value in Values do
		Parts[Index] = tostring(Value)
	end

	return `\{{table.concat(Parts, ", ")}\}`
end

local function Matches(Got: { number }, Want: { number }): boolean
	if #Got ~= #Want then
		return false
	end

	for Index, Value in Want do
		if Got[Index] ~= Value then
			return false
		end
	end

	return true
end

do
	local Name = "A rejected fire leaves no phantom event in the batch it shared"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Seen: { number } = {}
	local Disconnect = Server.PlainFromClient.On(function(_Player, Value: number)
		table.insert(Seen, Value)
	end)

	Client.PlainFromClient.Fire(15)
	--> A string where a u8 belongs. The type assert throws AFTER the id byte is written, which is
	--> exactly the window this spec exists for.
	local Rejected = pcall(Client.PlainFromClient.Fire, "not a number" :: any)
	Client.PlainFromClient.Fire(12)

	task.wait(FLUSH)
	Disconnect()

	if Rejected ~= false then
		ErrorPrint(`Failed "{Name}": the bad fire was accepted instead of rejected.`)
		return {}
	end

	if not Matches(Seen, { 15, 12 }) then
		ErrorPrint(`Failed "{Name}": expected {Describe({ 15, 12 })}, got {Describe(Seen)}.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	local Name = "A rejected unreliable fire does not discard the batch already queued"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Seen: { number } = {}
	local Disconnect = Server.PlainFromClient.On(function(_Player, Value: number)
		table.insert(Seen, Value)
	end)

	Shared.DrainWarnings()

	Client.PlainFromClient.Fire(7)
	--> Unreliable, so the failing write happens against a scratch buffer swapped in for the call.
	--> Restoring the real one is what a throw used to skip.
	local Rejected = pcall(Client.RangedUnreliableFromClient.Fire, 200)

	task.wait(FLUSH)
	Disconnect()

	if Rejected ~= false then
		ErrorPrint(`Failed "{Name}": the out-of-range unreliable fire was accepted.`)
		return {}
	end

	if not Matches(Seen, { 7 }) then
		ErrorPrint(`Failed "{Name}": the queued reliable event was lost, got {Describe(Seen)}.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	local Name = "A rejected invocation gives its slot back"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	--> More than the bitset holds, all failing on the ARGUMENT write and all without yielding, so
	--> no timeout can intervene and reclaim anything. If the slot is not returned on the spot the
	--> thirty-third call is refused outright, and every one after it.
	local Exhausted: string?
	for _ = 1, 40 do
		local _, Thrown = pcall(Client.BadlyAnswered.Invoke, "not a number" :: any)
		if Thrown and string.find(tostring(Thrown), "already awaiting", 1, true) then
			Exhausted = tostring(Thrown)
			break
		end
	end

	if Exhausted then
		ErrorPrint(`Failed "{Name}": the slots ran out, so a rejected call is not returning one: {Exhausted}`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	local Name = "A reply that cannot be serialised still answers the caller"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	--> The listener succeeds and returns the wrong TYPE, so the throw happens inside the return
	--> serialiser -- outside the pcall that guards the listener itself. The caller is owed exactly
	--> one answer either way; before this it got none and waited out the full invocation timeout.
	Server.BadlyAnswered.On(function(_Player, _Value: number): number
		return "not a number" :: any
	end)

	Shared.DrainWarnings()

	local Finished, Ok = false, nil
	task.spawn(function()
		Ok = pcall(Client.BadlyAnswered.Invoke, 1)
		Finished = true
	end)

	--> Well under `option InvocationTimeout = 3`: the point is that the answer is immediate, not
	--> that it eventually arrives by timeout.
	local Waited = 0
	while not Finished and Waited < 1.5 do
		Waited += task.wait(0.05)
	end

	if not Finished then
		ErrorPrint(`Failed "{Name}": the caller was still suspended after {Waited} seconds.`)
		return {}
	end

	if Ok ~= false then
		ErrorPrint(`Failed "{Name}": the caller was told the call succeeded.`)
		return {}
	end

	local Reported = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "encountered an error", 1, true) then
			Reported = true
			break
		end
	end

	if not Reported then
		ErrorPrint(`Failed "{Name}": it failed the caller without reporting why.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	local Name = "A range on client data is enforced against the bytes, not the sender"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Seen: { number } = {}
	local Disconnect = Server.RangedFromClient.On(function(_Player, Value: number)
		table.insert(Seen, Value)
	end)

	--> Captured from an honest fire and replayed with the payload byte overwritten, because the
	--> client refuses to send an out-of-range value in the first place. A real attacker has no
	--> client-side assert to get past -- which is why the read-side bound is the one that counts,
	--> and why it needed a spec that does not go through Fire.
	local Remote = require("./Server").Instances.BLINK_RELIABLE_REMOTE
	local Captured: buffer?
	local Spy = Remote.OnServerEvent:Connect(function(_Player, Packet: buffer)
		Captured = Packet
	end)

	Client.RangedFromClient.Fire(15)
	task.wait(FLUSH)
	Spy.Disconnect()

	local Packet = Captured
	if not Packet then
		Disconnect()
		ErrorPrint(`Failed "{Name}": the client sent no packet to tamper with.`)
		return {}
	end

	if not Matches(Seen, { 15 }) then
		Disconnect()
		ErrorPrint(`Failed "{Name}": the honest fire did not arrive, got {Describe(Seen)}.`)
		return {}
	end

	buffer.writeu8(Packet, buffer.len(Packet) - 1, 200)
	Remote.OnServerEvent:Fire(Shared.Player, Packet, {})
	task.wait(FLUSH)
	Disconnect()

	if not Matches(Seen, { 15 }) then
		ErrorPrint(`Failed "{Name}": a value outside 10..20 reached the listener, got {Describe(Seen)}.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

--> A flush keeps the buffer it grew, so the next frame writes over whatever the last one left past
--> the cursor. Only the exact-size copy goes out; a frame after a large one must carry its own
--> bytes and nothing of its predecessor's.
do
	local Name = "A frame after a larger one carries none of its bytes"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Remote = require("./Client").Instances.BLINK_RELIABLE_REMOTE
	local Original = Remote.FireServer
	local Sent: { buffer } = {}
	Remote.FireServer = function(_self, Buffer)
		table.insert(Sent, Buffer)
	end

	task.wait(FLUSH)
	table.clear(Sent)

	for Value = 1, 40 do
		Client.ReliableClient.Fire(Value)
	end
	task.wait(FLUSH)
	Client.ReliableClient.Fire(7)
	task.wait(FLUSH)
	Remote.FireServer = Original

	local Large, Small = Sent[1], Sent[2]
	if #Sent ~= 2 or not Large or not Small then
		ErrorPrint(`Failed "{Name}": {#Sent} packet(s) sent over two frames, expected 2.`)
		return {}
	end

	--> One event is its index and its u8: the second packet is exactly one fortieth of the first.
	if buffer.len(Small) * 40 ~= buffer.len(Large) or buffer.readu8(Small, buffer.len(Small) - 1) ~= 7 then
		ErrorPrint(`Failed "{Name}": the second frame was {buffer.len(Small)} bytes after {buffer.len(Large)}.`)
	end

	OkPrint(`Test "{Name}" passed!`)
end

return {}
