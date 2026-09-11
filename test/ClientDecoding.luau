--!strict
--- Specs for the client's decode loop surviving a packet it cannot parse.
---
--- The server has been guarded for a while, for a different reason: it is the party under attack.
--- The client is not attacked, but it can still be handed something it cannot read. A listener that
--- yields in a Sync call leaves the module-level cursor mid-event, and a client built from a
--- different schema than the server reads every index one event out of place.
---
--- Before the guard, that produced a raw `buffer access out of bounds` from inside OnClientEvent,
--- where no user pcall can reach it -- upstream issue #26, and the devforum report where events
--- "just stopped arriving" for the rest of the round.
---
--- Note what these do NOT assert. A Roblox signal runs each handler in its own thread, so an error
--- raised inside the connection never reaches the code that fired it; the mock reproduces that
--- faithfully with task.spawn. Asserting "it did not throw" would therefore pass with the guard
--- removed, which is the definition of a test that is not testing anything. Both specs below assert
--- on something the guard changes and its absence does not.
local Harness = require("./Harness")
local Modules = require("./Modules")
local Shared = require("./Shared")
local task = require("@lune/task")

local ClientEnvironment = require("./Client")

local Client = Modules.Client
local Server = Modules.Server

local OkPrint = Harness.OkPrint
local ErrorPrint = Harness.ErrorPrint
local PrettyPrint = Harness.PrettyPrint

local Reliable = ClientEnvironment.Instances.BLINK_RELIABLE_REMOTE

--> A real packet to work from, so what follows truncates something the encoder actually produced
--> rather than a shape guessed at. ReliableServer is `From: Server` with a one-byte payload, so the
--> packet is [event index][value].
local function CapturePacket(): buffer?
	local Captured: buffer?
	local Spy = Reliable.OnClientEvent:Connect(function(Buffer: buffer)
		Captured = Buffer
	end)

	Server.ReliableServer.FireAll(1)
	task.wait(1 / 30)
	Spy:Disconnect()

	return Captured
end

local Packet = CapturePacket()
if not Packet or buffer.len(Packet) < 2 then
	ErrorPrint("Failed: the client decoding specs could not capture a packet to work from.")
	return {}
end

local EventIndex = buffer.readu8(Packet, 0)

do
	--> An index no event was generated for. This is what a client one release behind the server sees
	--> once the indices have shifted.
	-->
	--> The payload is [unknown][real index][real value]. Without the guard the unknown index falls
	--> through the if-chain, the loop goes round again, and the byte AFTER it is read as the next
	--> event index -- so the listener fires for an event nobody sent, carrying whatever the
	--> misaligned cursor pointed at. With the guard the parse stops at the unknown index, because
	--> once one is seen the cursor is no longer on an event boundary and nothing behind it can be
	--> trusted.
	local Name = "An unknown event index stops the parse instead of decoding past it"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Payload = buffer.create(3)
	buffer.writeu8(Payload, 0, 254)
	buffer.writeu8(Payload, 1, EventIndex)
	buffer.writeu8(Payload, 2, 1)

	local Delivered = 0
	local Disconnect = Client.ReliableServer.On(function()
		Delivered += 1
	end)

	--> Connecting flushes whatever the event queued while nothing was listening, including the packet
	--> captured above. Let that land and then start counting, or the queue scores the assertion.
	task.wait(1 / 30)
	Delivered = 0

	Shared.DrainWarnings()
	Reliable.OnClientEvent:Fire(Payload, {})
	task.wait(1 / 30)

	if Delivered ~= 0 then
		Disconnect()
		ErrorPrint(`Failed "{Name}": {Delivered} event(s) were decoded from behind an unknown index.`)
		return {}
	end

	--> The control. A guard that killed the connection outright would also deliver nothing.
	Server.ReliableServer.FireAll(1)
	task.wait(1 / 30)
	Disconnect()

	if Delivered ~= 1 then
		ErrorPrint(`Failed "{Name}": the packet was stopped, but so was every packet after it.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

do
	--> A valid index with fewer bytes behind it than the event declares. The read throws from inside
	--> the connection either way; what the guard adds is that the module SAYS SO. Silence is what
	--> made the original report so hard to place -- from the outside, events merely stopped.
	local Name = "A packet that cannot be decoded is reported rather than dropped in silence"
	PrettyPrint("cyan", `Testing: {Name}...`, true)

	local Truncated = buffer.create(1)
	buffer.writeu8(Truncated, 0, EventIndex)

	Shared.DrainWarnings()
	Reliable.OnClientEvent:Fire(Truncated, {})
	task.wait(1 / 30)

	local Warned = false
	for _, Warning in Shared.DrainWarnings() do
		if string.find(Warning, "could not be decoded", 1, true) then
			Warned = true
			break
		end
	end

	if not Warned then
		ErrorPrint(`Failed "{Name}": the packet was dropped without a word about it.`)
		return {}
	end

	OkPrint(`Test "{Name}" passed!`)
end

return {}
